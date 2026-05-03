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

    pub fn init(config: NetworkConfig) ConsensusSyncEngine {
        return .{
            .store = std.mem.zeroes(primitives.LightClientUpdate.LightClientStore),
            .last_checkpoint = null,
            .config = config,
            .status = .syncing,
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

        const checkpoint_hex = std.fmt.bytesToHex(checkpoint, .lower);
        log.info(.consensus_sync, "light checkpoint resolved checkpoint=0x{s}", .{checkpoint_hex[0..]});

        try self.bootstrap(allocator, checkpoint, startup_context);

        const updates = try self.getUpdates(allocator);
        defer allocator.free(updates);

        for (updates) |update| {
            const generic_update = genericFromLightClientUpdate(update);
            try self.verifyUpdateWithTelemetry("initial_update", generic_update, allocator);
            self.applyUpdateWithTelemetry("initial_update", generic_update);
        }

        const api = beacon_api.BeaconApi{ .endpoint_url = self.config.consensus_rpc };
        const finality_update = try self.getFinalityUpdateWithTelemetry(allocator, api);

        const generic_finality_update = genericFromFinalityUpdate(finality_update);
        try self.verifyUpdateWithTelemetry("finality_update", generic_finality_update, allocator);
        self.applyUpdateWithTelemetry("finality_update", generic_finality_update);

        const optimistic_update = try self.getOptimisticUpdateWithTelemetry(allocator, api);
        const generic_optimistic_update = genericFromOptimisticUpdate(optimistic_update);
        try self.verifyUpdateWithTelemetry("optimistic_update", generic_optimistic_update, allocator);
        self.applyUpdateWithTelemetry("optimistic_update", generic_optimistic_update);

        if (self.last_checkpoint == null) {
            self.last_checkpoint = checkpoint;
        }

        self.setStatus(.synced);
    }

    pub fn bootstrap(
        self: *ConsensusSyncEngine,
        allocator: std.mem.Allocator,
        checkpoint: [32]u8,
        startup_context: CheckpointStartupContext,
    ) anyerror!void {
        const api = beacon_api.BeaconApi{ .endpoint_url = self.config.consensus_rpc };
        const age_info = try self.startupCheckpointAgeInfoWithTelemetry(allocator, api, checkpoint);
        try self.enforceStartupCheckpointAge(checkpoint, startup_context, age_info);

        const bootstrap_update = try self.getBootstrapWithTelemetry(allocator, api, checkpoint);

        try self.verifyBootstrapWithTelemetry(
            bootstrap_update,
            checkpoint,
            allocator,
        );

        consensus_verifier.applyBootstrap(&self.store, bootstrap_update);
    }

    pub fn advance(self: *ConsensusSyncEngine, allocator: std.mem.Allocator) anyerror!void {
        errdefer |err| {
            log.warn(.consensus_sync, "sync failed phase=advance error={s}", .{@errorName(err)});
            self.setStatus(.err);
        }

        const api = beacon_api.BeaconApi{ .endpoint_url = self.config.consensus_rpc };
        const finality_update = try self.getFinalityUpdateWithTelemetry(allocator, api);

        const generic_finality_update = genericFromFinalityUpdate(finality_update);
        try self.verifyUpdateWithTelemetry("finality_update", generic_finality_update, allocator);
        self.applyUpdateWithTelemetry("finality_update", generic_finality_update);

        const optimistic_update = try self.getOptimisticUpdateWithTelemetry(allocator, api);
        const generic_optimistic_update = genericFromOptimisticUpdate(optimistic_update);
        try self.verifyUpdateWithTelemetry("optimistic_update", generic_optimistic_update, allocator);
        self.applyUpdateWithTelemetry("optimistic_update", generic_optimistic_update);

        if (self.store.next_sync_committee_pubkeys == null) {
            const current_period = primitives.consensus.calcSyncPeriod(self.store.finalized_header.beacon.slot);
            const updates = try self.getUpdatesBatchWithTelemetry(allocator, api, current_period, 1);
            defer allocator.free(updates);

            if (updates.len == 1) {
                const generic_update = genericFromLightClientUpdate(updates[0]);
                if (self.verifyUpdateWithTelemetry("committee_update", generic_update, allocator)) |_| {
                    self.applyUpdateWithTelemetry("committee_update", generic_update);
                } else |_| {}
            }
        }

        self.setStatus(.synced);
    }

    pub fn getUpdates(
        self: *ConsensusSyncEngine,
        allocator: std.mem.Allocator,
    ) anyerror![]primitives.LightClientUpdate.LightClientUpdate {
        const api = beacon_api.BeaconApi{ .endpoint_url = self.config.consensus_rpc };

        const expected_current_period = primitives.consensus.calcSyncPeriod(self.expectedCurrentSlot());
        var next_update_fetch_period = primitives.consensus.calcSyncPeriod(self.store.finalized_header.beacon.slot);

        var updates = std.array_list.Managed(primitives.LightClientUpdate.LightClientUpdate).init(allocator);
        errdefer updates.deinit();

        if (expected_current_period > next_update_fetch_period and
            expected_current_period - next_update_fetch_period >= @as(u64, MAX_REQUEST_LIGHT_CLIENT_UPDATES))
        {
            while (next_update_fetch_period < expected_current_period) {
                const remaining_periods = expected_current_period - next_update_fetch_period;
                const batch_size_u64 = @min(remaining_periods, @as(u64, MAX_REQUEST_LIGHT_CLIENT_UPDATES));
                const batch_size: u8 = @intCast(batch_size_u64);

                const batch_updates = try self.getUpdatesBatchWithTelemetry(allocator, api, next_update_fetch_period, batch_size);
                defer allocator.free(batch_updates);
                try updates.appendSlice(batch_updates);

                next_update_fetch_period += batch_size_u64;
            }
        }

        const final_batch_updates = try self.getUpdatesBatchWithTelemetry(allocator, api, next_update_fetch_period, MAX_REQUEST_LIGHT_CLIENT_UPDATES);
        defer allocator.free(final_batch_updates);
        try updates.appendSlice(final_batch_updates);

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
    ) anyerror!CheckpointAgeInfo {
        const genesis = try api.getGenesis(allocator);
        const header = try api.getHeader(allocator, checkpoint);
        return self.checkpointAgeInfoFromBeaconData(genesis, header, checkpoint, currentUnixSeconds());
    }

    fn startupCheckpointAgeInfoWithTelemetry(
        self: *ConsensusSyncEngine,
        allocator: std.mem.Allocator,
        api: beacon_api.BeaconApi,
        checkpoint: [32]u8,
    ) anyerror!CheckpointAgeInfo {
        errdefer |err| log.warn(.consensus_sync, "startup checkpoint age resolution failed error={s}", .{@errorName(err)});
        return try self.startupCheckpointAgeInfo(allocator, api, checkpoint);
    }

    pub fn slotTimestamp(self: *ConsensusSyncEngine, slot: u64) u64 {
        return slot * primitives.ConsensusSpec.SECONDS_PER_SLOT + self.config.genesis_time;
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
        try consensus_verifier.verifyUpdate(
            update,
            self.expectedCurrentSlot(),
            self.store,
            self.config.genesis_validators_root,
            self.config.fork_config,
            allocator,
        );
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

fn currentUnixSeconds() u64 {
    const now = std.time.timestamp();
    if (now <= 0) return 0;
    return @intCast(now);
}

fn genericFromLightClientUpdate(
    update: primitives.LightClientUpdate.LightClientUpdate,
) primitives.LightClientUpdate.GenericUpdate {
    return primitives.LightClientUpdate.GenericUpdate.from(
        update.attested_header,
        update.sync_committee_bits,
        update.sync_committee_signature,
        update.signature_slot,
        update.next_sync_committee_pubkeys,
        update.next_sync_committee_aggregate_pubkey,
        update.next_sync_committee_branch[0..],
        update.finalized_header,
        update.finality_branch[0..],
    );
}

fn genericFromFinalityUpdate(
    update: primitives.LightClientUpdate.LightClientFinalityUpdate,
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
        update.finality_branch[0..],
    );
}

fn genericFromOptimisticUpdate(
    update: primitives.LightClientUpdate.LightClientOptimisticUpdate,
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
    var bytes: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, value) catch unreachable;
    return bytes;
}
