const std = @import("std");
const primitives = @import("primitives");
const beacon_api = @import("beacon_api.zig");
const consensus_verifier = @import("consensus_verifier.zig");
const light_default_checkpoints = @import("light_default_checkpoints.zig");
const log = @import("log.zig");

const MAX_REQUEST_LIGHT_CLIENT_UPDATES: u8 = 128;
const DEFAULT_MAX_CHECKPOINT_AGE_SECONDS: u64 = 1_209_600;

pub const NetworkConfig = struct {
    chain_id: u64,
    genesis_time: u64,
    genesis_validators_root: [32]u8,
    fork_config: primitives.ForkConfig.ForkConfig,
    default_checkpoint: [32]u8,
    consensus_rpc: []const u8,
    max_checkpoint_age: u64,
    strict_checkpoint_age: bool,

    pub fn mainnet(rpc_url: []const u8) NetworkConfig {
        return .{
            .chain_id = 1,
            .genesis_time = 1606824023,
            .genesis_validators_root = parseHex32("4b363db94e286120d76eb905340fdd4e54bfe9f06bf33ff6cf5ad27f511bfe95"),
            .fork_config = primitives.ForkConfig.ForkConfig.mainnet(),
            .default_checkpoint = parseHex32(light_default_checkpoints.mainnet_hex),
            .consensus_rpc = rpc_url,
            .max_checkpoint_age = DEFAULT_MAX_CHECKPOINT_AGE_SECONDS,
            .strict_checkpoint_age = false,
        };
    }

    pub fn sepolia(rpc_url: []const u8) NetworkConfig {
        return .{
            .chain_id = 11155111,
            .genesis_time = 1655733600,
            .genesis_validators_root = parseHex32("d8ea171f3c94aea21ebc42a1ed61052acf3f9209c00e4efbaaddac09ed9b8078"),
            .fork_config = primitives.ForkConfig.ForkConfig.sepolia(),
            .default_checkpoint = parseHex32(light_default_checkpoints.sepolia_hex),
            .consensus_rpc = rpc_url,
            .max_checkpoint_age = DEFAULT_MAX_CHECKPOINT_AGE_SECONDS,
            .strict_checkpoint_age = false,
        };
    }

    pub fn holesky(rpc_url: []const u8) NetworkConfig {
        return .{
            .chain_id = 17000,
            .genesis_time = 1695902400,
            .genesis_validators_root = parseHex32("9143aa7c615a7f7115e2b6aac319c03529df8242ae705fba9df39b79c59fa8b1"),
            .fork_config = primitives.ForkConfig.ForkConfig.holesky(),
            .default_checkpoint = parseHex32(light_default_checkpoints.holesky_hex),
            .consensus_rpc = rpc_url,
            .max_checkpoint_age = DEFAULT_MAX_CHECKPOINT_AGE_SECONDS,
            .strict_checkpoint_age = false,
        };
    }

    pub fn hoodi(rpc_url: []const u8) NetworkConfig {
        return .{
            .chain_id = 560048,
            .genesis_time = 1742213400,
            .genesis_validators_root = parseHex32("212f13fc4df078b6cb7db228f1c8307566dcecf900867401a92023d7ba99cb5f"),
            .fork_config = primitives.ForkConfig.ForkConfig.hoodi(),
            .default_checkpoint = parseHex32(light_default_checkpoints.hoodi_hex),
            .consensus_rpc = rpc_url,
            .max_checkpoint_age = DEFAULT_MAX_CHECKPOINT_AGE_SECONDS,
            .strict_checkpoint_age = false,
        };
    }
};

pub const SyncStatus = enum { syncing, synced, err };

pub const CheckpointStartupContext = struct {
    source: []const u8,
};

pub const CheckpointAgeInfo = struct {
    checkpoint_time_seconds: u64,
    startup_time_seconds: u64,
    age_seconds: u64,
    max_checkpoint_age_seconds: u64,
    stale: bool,
};

pub const ConsensusSyncEngine = struct {
    store: primitives.LightClientUpdate.LightClientStore,
    last_checkpoint: ?[32]u8,
    config: NetworkConfig,
    status: SyncStatus,
    /// True once `sync()` has produced a fully verified store. A failed
    /// `advance()` keeps serving this store instead of latching `.err`.
    has_verified_store: bool = false,
    /// Number of `advance()` calls that failed since the last success.
    consecutive_advance_failures: u32 = 0,
    last_advance_slot: ?u64 = null,

    pub fn init(config: NetworkConfig) ConsensusSyncEngine {
        return .{
            .store = std.mem.zeroes(primitives.LightClientUpdate.LightClientStore),
            .last_checkpoint = null,
            .config = config,
            .status = .syncing,
            .has_verified_store = false,
            .consecutive_advance_failures = 0,
        };
    }

    pub fn sync(
        self: *ConsensusSyncEngine,
        allocator: std.mem.Allocator,
        checkpoint: [32]u8,
        startup_context: CheckpointStartupContext,
    ) anyerror!void {
        self.setStatus(.syncing);
        errdefer |err| {
            log.warn(.consensus_sync, "sync failed phase=initial error={s}", .{@errorName(err)});
            self.setStatus(.err);
        }

        self.store = std.mem.zeroes(primitives.LightClientUpdate.LightClientStore);
        self.last_checkpoint = null;
        self.has_verified_store = false;
        self.consecutive_advance_failures = 0;
        self.last_advance_slot = null;

        const checkpoint_hex = std.fmt.bytesToHex(checkpoint, .lower);
        log.info(.consensus_sync, "light checkpoint resolved checkpoint=0x{s}", .{checkpoint_hex[0..]});

        try self.bootstrap(allocator, checkpoint, startup_context);

        const updates = try self.getUpdates(allocator);
        defer allocator.free(updates);

        for (updates) |*update| {
            const generic_update = genericFromLightClientUpdate(update);
            try self.verifyUpdateWithTelemetry("initial_update", generic_update, allocator);
            self.applyUpdateWithTelemetry("initial_update", generic_update);
        }

        const api = beacon_api.BeaconApi{ .endpoint_url = self.config.consensus_rpc };
        try self.processLatestUpdates(allocator, api);

        self.forceUpdateIfTimedOut(self.expectedCurrentSlot());
        if (self.last_checkpoint == null) {
            self.last_checkpoint = checkpoint;
        }

        self.has_verified_store = true;
        self.setStatus(.synced);
    }

    pub fn bootstrap(
        self: *ConsensusSyncEngine,
        allocator: std.mem.Allocator,
        checkpoint: [32]u8,
        startup_context: CheckpointStartupContext,
    ) anyerror!void {
        const api = beacon_api.BeaconApi{ .endpoint_url = self.config.consensus_rpc };

        // Verify the bootstrap first so the checkpoint age is computed from a
        // slot bound to the checkpoint root, not from an unverified /headers
        // response.
        const bootstrap_update = try self.getBootstrapWithTelemetry(allocator, api, checkpoint);

        try self.verifyBootstrapWithTelemetry(
            bootstrap_update,
            checkpoint,
            allocator,
        );

        const age_info = try self.startupCheckpointAgeInfoWithTelemetry(
            allocator,
            api,
            checkpoint,
            bootstrap_update.header.beacon.slot,
        );
        try self.enforceStartupCheckpointAge(checkpoint, startup_context, age_info);

        consensus_verifier.applyBootstrap(&self.store, bootstrap_update);
    }

    /// Advances the verified store with the latest finality and optimistic
    /// updates. A failure leaves every already-verified store mutation in
    /// place. When a verified store exists the status is not latched to
    /// `.err`, so reads keep working and the next call retries.
    pub fn advance(self: *ConsensusSyncEngine, allocator: std.mem.Allocator) anyerror!void {
        const current_slot = self.expectedCurrentSlot();
        if (self.last_advance_slot == current_slot and self.consecutive_advance_failures == 0) return;
        errdefer |err| {
            self.consecutive_advance_failures +|= 1;
            log.warn(.consensus_sync, "sync failed phase=advance error={s} consecutive_failures={} verified_store={}", .{
                @errorName(err),
                self.consecutive_advance_failures,
                self.has_verified_store,
            });
            if (!self.has_verified_store) {
                self.setStatus(.err);
            }
        }

        const api = beacon_api.BeaconApi{ .endpoint_url = self.config.consensus_rpc };
        self.forceUpdateIfTimedOut(current_slot);

        // Step across sync committee periods missed while the node was idle.
        // A finality update signed in a period more than one ahead of the
        // store cannot verify until the committee chain catches up.
        const store_period = primitives.consensus.calcSyncPeriod(self.store.finalized_header.beacon.slot);
        const expected_current_period = primitives.consensus.calcSyncPeriod(current_slot);
        if (expected_current_period > store_period) {
            const updates = try self.getUpdates(allocator);
            defer allocator.free(updates);

            for (updates) |*update| {
                const generic_update = genericFromLightClientUpdate(update);
                const verify_res = self.verifyUpdateWithTelemetry("catch_up_update", generic_update, allocator);
                if (verify_res) |_| {} else |verify_err| {
                    if (verify_err == error.NotRelevant) continue;
                    return verify_res;
                }
                self.applyUpdateWithTelemetry("catch_up_update", generic_update);
            }
        }

        try self.processLatestUpdates(allocator, api);

        if (self.store.next_sync_committee_pubkeys == null) {
            const current_period = primitives.consensus.calcSyncPeriod(self.store.finalized_header.beacon.slot);
            const updates = try self.getUpdatesBatchWithTelemetry(allocator, api, current_period, 1);
            defer allocator.free(updates);

            if (updates.len == 1) {
                const generic_update = genericFromLightClientUpdate(&updates[0]);
                if (self.verifyUpdateWithTelemetry("committee_update", generic_update, allocator)) |_| {
                    self.applyUpdateWithTelemetry("committee_update", generic_update);
                } else |_| {}
            }
        }

        self.consecutive_advance_failures = 0;
        self.last_advance_slot = current_slot;
        self.setStatus(.synced);
    }

    pub fn getUpdates(
        self: *ConsensusSyncEngine,
        allocator: std.mem.Allocator,
    ) anyerror![]primitives.LightClientUpdate.LightClientUpdate {
        const api = beacon_api.BeaconApi{ .endpoint_url = self.config.consensus_rpc };

        const expected_current_period = primitives.consensus.calcSyncPeriod(self.expectedCurrentSlot());
        const start_period = primitives.consensus.calcSyncPeriod(self.store.finalized_header.beacon.slot);

        var updates = std.array_list.Managed(primitives.LightClientUpdate.LightClientUpdate).init(allocator);
        errdefer updates.deinit();

        var cursor = start_period;
        while (nextUpdatesBatchSize(cursor, expected_current_period)) |batch_size| {
            const batch_updates = try self.getUpdatesBatchWithTelemetry(allocator, api, cursor, batch_size);
            defer allocator.free(batch_updates);

            if (batch_updates.len > batch_size) return error.TooManyLightClientUpdates;
            try updates.appendSlice(batch_updates);

            // A short page means the beacon node has nothing newer yet.
            if (batch_updates.len < batch_size) break;
            cursor += batch_updates.len;
        }

        return updates.toOwnedSlice();
    }

    pub fn expectedCurrentSlot(self: *ConsensusSyncEngine) u64 {
        return primitives.consensus.expectedCurrentSlot(self.config.genesis_time);
    }

    pub fn isValidCheckpoint(self: *ConsensusSyncEngine, slot: u64) bool {
        return !self.checkpointAgeInfo(slot).stale;
    }

    pub fn checkpointAgeInfo(self: *ConsensusSyncEngine, slot: u64) CheckpointAgeInfo {
        const slot_timestamp = self.slotTimestamp(slot);
        const current_slot_timestamp = self.slotTimestamp(self.expectedCurrentSlot());

        return self.checkpointAgeInfoFromTimes(slot_timestamp, current_slot_timestamp);
    }

    pub fn checkpointAgeInfoFromTimes(
        self: *const ConsensusSyncEngine,
        checkpoint_time_seconds: u64,
        startup_time_seconds: u64,
    ) CheckpointAgeInfo {
        const age = startup_time_seconds -| checkpoint_time_seconds;
        return .{
            .checkpoint_time_seconds = checkpoint_time_seconds,
            .startup_time_seconds = startup_time_seconds,
            .age_seconds = age,
            .max_checkpoint_age_seconds = self.config.max_checkpoint_age,
            .stale = age > self.config.max_checkpoint_age,
        };
    }

    pub fn checkpointAgeInfoFromBeaconData(
        self: *const ConsensusSyncEngine,
        genesis: beacon_api.GenesisInfo,
        header: beacon_api.BeaconHeaderInfo,
        checkpoint: [32]u8,
        startup_time_seconds: u64,
    ) !CheckpointAgeInfo {
        if (!std.mem.eql(u8, &genesis.genesis_validators_root, &self.config.genesis_validators_root)) {
            return error.ConsensusNetworkMismatch;
        }
        if (!std.mem.eql(u8, &header.root, &checkpoint)) {
            return error.CheckpointRootMismatch;
        }

        const slot_seconds = std.math.mul(u64, header.slot, primitives.ConsensusSpec.SECONDS_PER_SLOT) catch return error.CheckpointTimeOverflow;
        const checkpoint_time_seconds = std.math.add(u64, genesis.genesis_time, slot_seconds) catch return error.CheckpointTimeOverflow;
        return self.checkpointAgeInfoFromTimes(checkpoint_time_seconds, startup_time_seconds);
    }

    /// Computes checkpoint age from the slot of a bootstrap that already
    /// verified against `checkpoint`. The `/headers` response must agree with
    /// that slot and root, and the age uses the trusted network genesis time.
    pub fn checkpointAgeInfoFromVerifiedBootstrap(
        self: *const ConsensusSyncEngine,
        genesis: beacon_api.GenesisInfo,
        header: beacon_api.BeaconHeaderInfo,
        checkpoint: [32]u8,
        verified_bootstrap_slot: u64,
        startup_time_seconds: u64,
    ) !CheckpointAgeInfo {
        if (!std.mem.eql(u8, &genesis.genesis_validators_root, &self.config.genesis_validators_root)) {
            return error.ConsensusNetworkMismatch;
        }
        if (!std.mem.eql(u8, &header.root, &checkpoint)) {
            return error.CheckpointRootMismatch;
        }
        if (header.slot != verified_bootstrap_slot) {
            return error.CheckpointSlotMismatch;
        }

        const slot_seconds = std.math.mul(u64, verified_bootstrap_slot, primitives.ConsensusSpec.SECONDS_PER_SLOT) catch return error.CheckpointTimeOverflow;
        const checkpoint_time_seconds = std.math.add(u64, self.config.genesis_time, slot_seconds) catch return error.CheckpointTimeOverflow;
        return self.checkpointAgeInfoFromTimes(checkpoint_time_seconds, startup_time_seconds);
    }

    pub fn enforceStartupCheckpointAge(
        self: *const ConsensusSyncEngine,
        checkpoint: [32]u8,
        startup_context: CheckpointStartupContext,
        age_info: CheckpointAgeInfo,
    ) !void {
        if (!age_info.stale) return;
        if (self.config.strict_checkpoint_age) {
            const checkpoint_hex = std.fmt.bytesToHex(checkpoint, .lower);
            log.warn(
                .consensus_sync,
                "checkpoint too old checkpoint=0x{s} checkpointSource={s} checkpointTimeSeconds={} startupTimeSeconds={} age={} maxCheckpointAgeSeconds={} strictCheckpointAge=true",
                .{
                    checkpoint_hex[0..],
                    startup_context.source,
                    age_info.checkpoint_time_seconds,
                    age_info.startup_time_seconds,
                    age_info.age_seconds,
                    age_info.max_checkpoint_age_seconds,
                },
            );
            return error.CheckpointTooOld;
        }

        const checkpoint_hex = std.fmt.bytesToHex(checkpoint, .lower);
        log.warn(
            .consensus_sync,
            "checkpoint too old checkpoint=0x{s} checkpointSource={s} checkpointTimeSeconds={} startupTimeSeconds={} age={} maxCheckpointAgeSeconds={} strictCheckpointAge=false",
            .{
                checkpoint_hex[0..],
                startup_context.source,
                age_info.checkpoint_time_seconds,
                age_info.startup_time_seconds,
                age_info.age_seconds,
                age_info.max_checkpoint_age_seconds,
            },
        );
    }

    fn startupCheckpointAgeInfo(
        self: *ConsensusSyncEngine,
        allocator: std.mem.Allocator,
        api: beacon_api.BeaconApi,
        checkpoint: [32]u8,
        verified_bootstrap_slot: u64,
    ) anyerror!CheckpointAgeInfo {
        const genesis = try api.getGenesis(allocator);
        const header = try api.getHeader(allocator, checkpoint);
        return self.checkpointAgeInfoFromVerifiedBootstrap(
            genesis,
            header,
            checkpoint,
            verified_bootstrap_slot,
            currentUnixSeconds(),
        );
    }

    fn startupCheckpointAgeInfoWithTelemetry(
        self: *ConsensusSyncEngine,
        allocator: std.mem.Allocator,
        api: beacon_api.BeaconApi,
        checkpoint: [32]u8,
        verified_bootstrap_slot: u64,
    ) anyerror!CheckpointAgeInfo {
        errdefer |err| log.warn(.consensus_sync, "startup checkpoint age resolution failed error={s}", .{@errorName(err)});
        return try self.startupCheckpointAgeInfo(allocator, api, checkpoint, verified_bootstrap_slot);
    }

    pub fn slotTimestamp(self: *ConsensusSyncEngine, slot: u64) u64 {
        return (slot *| primitives.ConsensusSpec.SECONDS_PER_SLOT) +| self.config.genesis_time;
    }

    pub fn lastCheckpoint(self: *const ConsensusSyncEngine) ?[32]u8 {
        return self.last_checkpoint;
    }

    pub fn finalizedSlot(self: *const ConsensusSyncEngine) u64 {
        return self.store.finalized_header.beacon.slot;
    }

    pub fn safeSlot(self: *const ConsensusSyncEngine) u64 {
        return self.finalizedSlot();
    }

    pub fn optimisticSlot(self: *const ConsensusSyncEngine) u64 {
        return self.store.optimistic_header.beacon.slot;
    }

    fn getBootstrapWithTelemetry(
        self: *ConsensusSyncEngine,
        allocator: std.mem.Allocator,
        api: beacon_api.BeaconApi,
        checkpoint: [32]u8,
    ) anyerror!primitives.LightClientUpdate.LightClientBootstrap {
        _ = self;
        const checkpoint_hex = std.fmt.bytesToHex(checkpoint, .lower);
        errdefer |err| log.warn(.consensus_sync, "upstream request failed operation=get_bootstrap checkpoint=0x{s} error={s}", .{ checkpoint_hex[0..], @errorName(err) });
        return try api.getBootstrap(allocator, checkpoint);
    }

    fn getUpdatesBatchWithTelemetry(
        self: *ConsensusSyncEngine,
        allocator: std.mem.Allocator,
        api: beacon_api.BeaconApi,
        start_period: u64,
        count: u8,
    ) anyerror![]primitives.LightClientUpdate.LightClientUpdate {
        _ = self;
        errdefer |err| log.warn(.consensus_sync, "upstream request failed operation=get_updates start_period={} count={} error={s}", .{ start_period, count, @errorName(err) });
        return try api.getUpdates(allocator, start_period, count);
    }

    fn getFinalityUpdateWithTelemetry(
        self: *ConsensusSyncEngine,
        allocator: std.mem.Allocator,
        api: beacon_api.BeaconApi,
    ) anyerror!primitives.LightClientUpdate.LightClientFinalityUpdate {
        _ = self;
        errdefer |err| log.warn(.consensus_sync, "upstream request failed operation=get_finality_update error={s}", .{@errorName(err)});
        return try api.getFinalityUpdate(allocator);
    }

    fn getOptimisticUpdateWithTelemetry(
        self: *ConsensusSyncEngine,
        allocator: std.mem.Allocator,
        api: beacon_api.BeaconApi,
    ) anyerror!primitives.LightClientUpdate.LightClientOptimisticUpdate {
        _ = self;
        errdefer |err| log.warn(.consensus_sync, "upstream request failed operation=get_optimistic_update error={s}", .{@errorName(err)});
        return try api.getOptimisticUpdate(allocator);
    }

    fn processLatestUpdates(self: *ConsensusSyncEngine, allocator: std.mem.Allocator, api: beacon_api.BeaconApi) !void {
        const finality = try self.getFinalityUpdateWithTelemetry(allocator, api);
        const finality_update = genericFromFinalityUpdate(&finality);
        if (self.verifyUpdateWithTelemetry("finality_update", finality_update, allocator)) |_| {
            self.applyUpdateWithTelemetry("finality_update", finality_update);
        } else |err| {
            // Recovery may have moved beyond the latest finality response.
            // Discard that update and continue to the optimistic endpoint.
            const obsolete_period = err == error.InvalidPeriod and finality.signature_slot <= self.finalizedSlot();
            if (err != error.NotRelevant and !obsolete_period) return err;
        }

        const optimistic = try self.getOptimisticUpdateWithTelemetry(allocator, api);
        const update = genericFromOptimisticUpdate(&optimistic);
        const verification = self.verifyUpdateWithTelemetry("optimistic_update", update, allocator);
        if (try self.shouldApplyOptimisticUpdate(update.attested_header.beacon.slot, verification)) {
            self.applyUpdateWithTelemetry("optimistic_update", update);
        }
    }

    pub fn shouldApplyOptimisticUpdate(self: *const ConsensusSyncEngine, attested_slot: u64, verification: anyerror!void) !bool {
        verification catch |err| {
            if ((err == error.NotRelevant or err == error.InvalidPeriod) and attested_slot <= self.optimisticSlot()) return false;
            return err;
        };
        return attested_slot > self.optimisticSlot();
    }

    fn verifyBootstrapWithTelemetry(
        self: *ConsensusSyncEngine,
        bootstrap_update: primitives.LightClientUpdate.LightClientBootstrap,
        checkpoint: [32]u8,
        allocator: std.mem.Allocator,
    ) anyerror!void {
        errdefer |err| {
            const checkpoint_hex = std.fmt.bytesToHex(checkpoint, .lower);
            log.warn(.consensus_sync, "proof verification failed kind=bootstrap checkpoint=0x{s} header_slot={} error={s}", .{
                checkpoint_hex[0..],
                bootstrap_update.header.beacon.slot,
                @errorName(err),
            });
        }
        try consensus_verifier.verifyBootstrap(
            bootstrap_update,
            checkpoint,
            self.config.fork_config,
            allocator,
        );
    }

    fn verifyUpdateWithTelemetry(
        self: *ConsensusSyncEngine,
        kind: []const u8,
        update: primitives.LightClientUpdate.GenericUpdate,
        allocator: std.mem.Allocator,
    ) anyerror!void {
        errdefer |err| {
            const finalized_slot = if (update.finalized_header) |header| header.beacon.slot else 0;
            log.warn(.consensus_sync, "proof verification failed kind={s} error={s} expected_current_slot={} attested_slot={} finalized_slot={} signature_slot={}", .{
                kind,
                @errorName(err),
                self.expectedCurrentSlot(),
                update.attested_header.beacon.slot,
                finalized_slot,
                update.signature_slot,
            });
        }
        const current_slot = self.expectedCurrentSlot();
        // During catch-up, the following period's update can arrive before
        // sync() or advance() returns. Recover the committee chain first.
        const last_known_period = primitives.consensus.calcSyncPeriod(self.finalizedSlot()) +
            @intFromBool(self.store.next_sync_committee_pubkeys != null);
        if (update.signature_slot <= current_slot and
            primitives.consensus.calcSyncPeriod(update.signature_slot) > last_known_period)
        {
            self.forceUpdateIfTimedOut(current_slot);
        }
        try consensus_verifier.verifyUpdate(
            update,
            current_slot,
            self.store,
            self.config.genesis_validators_root,
            self.config.fork_config,
            allocator,
        );
    }

    fn forceUpdateIfTimedOut(self: *ConsensusSyncEngine, current_slot: u64) void {
        if (consensus_verifier.processLightClientStoreForceUpdate(&self.store, current_slot)) |checkpoint| {
            self.last_checkpoint = checkpoint;
        }
    }

    fn applyUpdateWithTelemetry(
        self: *ConsensusSyncEngine,
        kind: []const u8,
        update: primitives.LightClientUpdate.GenericUpdate,
    ) void {
        if (consensus_verifier.applyUpdate(&self.store, update)) |new_checkpoint| {
            self.last_checkpoint = new_checkpoint;
            const checkpoint_hex = std.fmt.bytesToHex(new_checkpoint, .lower);
            log.info(.consensus_sync, "checkpoint advanced source={s} checkpoint=0x{s} finalized_slot={} optimistic_slot={}", .{
                kind,
                checkpoint_hex[0..],
                self.finalizedSlot(),
                self.optimisticSlot(),
            });
        }
    }

    fn setStatus(self: *ConsensusSyncEngine, next: SyncStatus) void {
        const previous = self.status;
        if (previous != next) {
            log.info(.consensus_sync, "sync status transition from={s} to={s}", .{
                statusText(previous),
                statusText(next),
            });
        }
        self.status = next;
    }
};

fn statusText(status: SyncStatus) []const u8 {
    return switch (status) {
        .syncing => "syncing",
        .synced => "synced",
        .err => "error",
    };
}

/// Returns the size of the next `/light_client/updates` page starting at
/// `cursor`, or null once `cursor` is past `expected_current_period`. Pages
/// never request periods beyond the expected current period.
pub fn nextUpdatesBatchSize(cursor: u64, expected_current_period: u64) ?u8 {
    if (cursor > expected_current_period) return null;
    const remaining_periods = expected_current_period - cursor +| 1;
    return @intCast(@min(remaining_periods, @as(u64, MAX_REQUEST_LIGHT_CLIENT_UPDATES)));
}

fn currentUnixSeconds() u64 {
    const now = std.time.timestamp();
    if (now <= 0) return 0;
    return @intCast(now);
}

pub fn genericFromLightClientUpdate(
    update: *const primitives.LightClientUpdate.LightClientUpdate,
) primitives.LightClientUpdate.GenericUpdate {
    return primitives.LightClientUpdate.GenericUpdate.from(
        update.attested_header,
        update.sync_committee_bits,
        update.sync_committee_signature,
        update.signature_slot,
        update.next_sync_committee_pubkeys,
        update.next_sync_committee_aggregate_pubkey,
        update.nextSyncCommitteeBranch(),
        update.finalized_header,
        update.finalityBranch(),
    );
}

pub fn genericFromFinalityUpdate(
    update: *const primitives.LightClientUpdate.LightClientFinalityUpdate,
) primitives.LightClientUpdate.GenericUpdate {
    return primitives.LightClientUpdate.GenericUpdate.from(
        update.attested_header,
        update.sync_committee_bits,
        update.sync_committee_signature,
        update.signature_slot,
        null,
        null,
        null,
        update.finalized_header,
        update.finalityBranch(),
    );
}

fn genericFromOptimisticUpdate(
    update: *const primitives.LightClientUpdate.LightClientOptimisticUpdate,
) primitives.LightClientUpdate.GenericUpdate {
    return primitives.LightClientUpdate.GenericUpdate.from(
        update.attested_header,
        update.sync_committee_bits,
        update.sync_committee_signature,
        update.signature_slot,
        null,
        null,
        null,
        null,
        null,
    );
}

fn parseHex32(comptime value: []const u8) [32]u8 {
    return comptime blk: {
        if (value.len != 64) @compileError("expected 64-character hex literal for 32-byte hash");
        var bytes: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&bytes, value) catch @compileError("invalid 32-byte hex literal");
        break :blk bytes;
    };
}

test "nextUpdatesBatchSize pages up to the expected current period and stops" {
    try std.testing.expectEqual(@as(?u8, 1), nextUpdatesBatchSize(10, 10));
    try std.testing.expectEqual(@as(?u8, 3), nextUpdatesBatchSize(8, 10));
    try std.testing.expectEqual(@as(?u8, MAX_REQUEST_LIGHT_CLIENT_UPDATES), nextUpdatesBatchSize(0, 1_000));
    try std.testing.expectEqual(@as(?u8, null), nextUpdatesBatchSize(11, 10));
    try std.testing.expectEqual(@as(?u8, MAX_REQUEST_LIGHT_CLIENT_UPDATES), nextUpdatesBatchSize(0, std.math.maxInt(u64)));

    // Paging 300 periods with full pages issues exactly three requests and no
    // trailing request past the expected period.
    var cursor: u64 = 0;
    var requests: usize = 0;
    while (nextUpdatesBatchSize(cursor, 299)) |batch_size| {
        requests += 1;
        cursor += batch_size;
    }
    try std.testing.expectEqual(@as(usize, 3), requests);
    try std.testing.expectEqual(@as(u64, 300), cursor);
}

test "checkpoint age from verified bootstrap rejects /headers slot mismatch" {
    var config = NetworkConfig.mainnet("");
    config.genesis_time = 1_000;
    config.max_checkpoint_age = 120;
    const engine = ConsensusSyncEngine.init(config);
    const checkpoint = [_]u8{0xaa} ** 32;
    const genesis = beacon_api.GenesisInfo{
        .genesis_time = 0,
        .genesis_validators_root = config.genesis_validators_root,
    };

    try std.testing.expectError(error.CheckpointSlotMismatch, engine.checkpointAgeInfoFromVerifiedBootstrap(
        genesis,
        .{ .root = checkpoint, .slot = 6 },
        checkpoint,
        5,
        1_180,
    ));

    // Age uses the verified slot and the trusted network genesis time, not
    // the genesis time the beacon node reported.
    const info = try engine.checkpointAgeInfoFromVerifiedBootstrap(
        genesis,
        .{ .root = checkpoint, .slot = 5 },
        checkpoint,
        5,
        1_180,
    );
    try std.testing.expectEqual(@as(u64, 1_060), info.checkpoint_time_seconds);
    try std.testing.expectEqual(@as(u64, 120), info.age_seconds);
    try std.testing.expect(!info.stale);

    try std.testing.expectError(error.CheckpointTimeOverflow, engine.checkpointAgeInfoFromVerifiedBootstrap(
        genesis,
        .{ .root = checkpoint, .slot = std.math.maxInt(u64) },
        checkpoint,
        std.math.maxInt(u64),
        1_180,
    ));
}

test "advance failure keeps a verified store synced and recovers on the next call" {
    // Port 1 on loopback refuses connections, so advance() fails in transport.
    var engine = ConsensusSyncEngine.init(NetworkConfig.mainnet("http://127.0.0.1:1"));
    engine.store.finalized_header.beacon.slot = primitives.consensus.expectedCurrentSlot(engine.config.genesis_time);
    engine.store.optimistic_header = engine.store.finalized_header;
    engine.has_verified_store = true;
    engine.status = .synced;

    try std.testing.expect(std.meta.isError(engine.advance(std.testing.allocator)));
    try std.testing.expectEqual(SyncStatus.synced, engine.status);
    try std.testing.expectEqual(@as(u32, 1), engine.consecutive_advance_failures);

    try std.testing.expect(std.meta.isError(engine.advance(std.testing.allocator)));
    try std.testing.expectEqual(SyncStatus.synced, engine.status);
    try std.testing.expectEqual(@as(u32, 2), engine.consecutive_advance_failures);

    var unsynced = ConsensusSyncEngine.init(NetworkConfig.mainnet("http://127.0.0.1:1"));
    try std.testing.expect(std.meta.isError(unsynced.advance(std.testing.allocator)));
    try std.testing.expectEqual(SyncStatus.err, unsynced.status);
}
