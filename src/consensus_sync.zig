const std = @import("std");
const primitives = @import("primitives");
const beacon_api = @import("beacon_api.zig");
const consensus_verifier = @import("consensus_verifier.zig");
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
            .default_checkpoint = parseHex32("9b41a80f58c52068a00e8535b8d6704769c7577a5fd506af5e0c018687991d55"),
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
            .default_checkpoint = parseHex32("4065c2509eaa15dbe60e1f80cff5205a532aa95aaa1d73c1c286f7f8535555d4"),
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
            .default_checkpoint = parseHex32("e1f575f0b691404fe82cce68a09c2c98af197816de14ce53c0fe9f9bd02d2399"),
            .consensus_rpc = rpc_url,
            .max_checkpoint_age = DEFAULT_MAX_CHECKPOINT_AGE_SECONDS,
            .strict_checkpoint_age = false,
        };
    }
};

pub const SyncStatus = enum { syncing, synced, err };

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
    ) !void {
        self.setStatus(.syncing);
        errdefer self.setStatus(.err);

        self.store = std.mem.zeroes(primitives.LightClientUpdate.LightClientStore);
        self.last_checkpoint = null;

        const checkpoint_hex = std.fmt.bytesToHex(checkpoint, .lower);
        log.info(.consensus_sync, "light checkpoint resolved checkpoint=0x{s}", .{checkpoint_hex[0..]});

        try self.bootstrap(allocator, checkpoint);

        const updates = try self.getUpdates(allocator);
        defer allocator.free(updates);

        for (updates) |update| {
            const generic_update = genericFromLightClientUpdate(update);
            try consensus_verifier.verifyUpdate(
                generic_update,
                self.expectedCurrentSlot(),
                self.store,
                self.config.genesis_validators_root,
                self.config.fork_config,
                allocator,
            );
            if (consensus_verifier.applyUpdate(&self.store, generic_update)) |new_checkpoint| {
                self.last_checkpoint = new_checkpoint;
            }
        }

        const api = beacon_api.BeaconApi{ .endpoint_url = self.config.consensus_rpc };
        const finality_update = try api.getFinalityUpdate(allocator);

        const generic_finality_update = genericFromFinalityUpdate(finality_update);
        try consensus_verifier.verifyUpdate(
            generic_finality_update,
            self.expectedCurrentSlot(),
            self.store,
            self.config.genesis_validators_root,
            self.config.fork_config,
            allocator,
        );
        if (consensus_verifier.applyUpdate(&self.store, generic_finality_update)) |new_checkpoint| {
            self.last_checkpoint = new_checkpoint;
        }

        if (self.last_checkpoint == null) {
            self.last_checkpoint = checkpoint;
        }

        self.setStatus(.synced);
    }

    pub fn bootstrap(
        self: *ConsensusSyncEngine,
        allocator: std.mem.Allocator,
        checkpoint: [32]u8,
    ) !void {
        const api = beacon_api.BeaconApi{ .endpoint_url = self.config.consensus_rpc };
        const bootstrap_update = try api.getBootstrap(allocator, checkpoint);

        if (!self.isValidCheckpoint(bootstrap_update.header.beacon.slot)) {
            if (self.config.strict_checkpoint_age) {
                return error.CheckpointTooOld;
            }
            log.warn(.consensus_sync, "checkpoint too old; consider syncing with a newer checkpoint", .{});
        }

        try consensus_verifier.verifyBootstrap(
            bootstrap_update,
            checkpoint,
            self.config.fork_config,
            self.config.genesis_validators_root,
            allocator,
        );

        consensus_verifier.applyBootstrap(&self.store, bootstrap_update);
    }

    pub fn advance(self: *ConsensusSyncEngine, allocator: std.mem.Allocator) !void {
        errdefer self.setStatus(.err);

        const api = beacon_api.BeaconApi{ .endpoint_url = self.config.consensus_rpc };
        const finality_update = try api.getFinalityUpdate(allocator);

        const generic_finality_update = genericFromFinalityUpdate(finality_update);
        try consensus_verifier.verifyUpdate(
            generic_finality_update,
            self.expectedCurrentSlot(),
            self.store,
            self.config.genesis_validators_root,
            self.config.fork_config,
            allocator,
        );
        if (consensus_verifier.applyUpdate(&self.store, generic_finality_update)) |new_checkpoint| {
            self.last_checkpoint = new_checkpoint;
        }

        if (self.store.next_sync_committee_pubkeys == null) {
            const current_period = primitives.consensus.calcSyncPeriod(self.store.finalized_header.beacon.slot);
            const updates = try api.getUpdates(allocator, current_period, 1);
            defer allocator.free(updates);

            if (updates.len == 1) {
                const generic_update = genericFromLightClientUpdate(updates[0]);
                if (consensus_verifier.verifyUpdate(
                    generic_update,
                    self.expectedCurrentSlot(),
                    self.store,
                    self.config.genesis_validators_root,
                    self.config.fork_config,
                    allocator,
                )) {
                    if (consensus_verifier.applyUpdate(&self.store, generic_update)) |new_checkpoint| {
                        self.last_checkpoint = new_checkpoint;
                    }
                } else |_| {}
            }
        }

        self.setStatus(.synced);
    }

    pub fn getUpdates(
        self: *ConsensusSyncEngine,
        allocator: std.mem.Allocator,
    ) ![]primitives.LightClientUpdate.LightClientUpdate {
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

                const batch_updates = try api.getUpdates(allocator, next_update_fetch_period, batch_size);
                defer allocator.free(batch_updates);
                try updates.appendSlice(batch_updates);

                next_update_fetch_period += batch_size_u64;
            }
        }

        const final_batch_updates = try api.getUpdates(
            allocator,
            next_update_fetch_period,
            MAX_REQUEST_LIGHT_CLIENT_UPDATES,
        );
        defer allocator.free(final_batch_updates);
        try updates.appendSlice(final_batch_updates);

        return updates.toOwnedSlice();
    }

    pub fn expectedCurrentSlot(self: *ConsensusSyncEngine) u64 {
        return primitives.consensus.expectedCurrentSlot(self.config.genesis_time);
    }

    pub fn isValidCheckpoint(self: *ConsensusSyncEngine, slot: u64) bool {
        const slot_timestamp = self.slotTimestamp(slot);
        const current_slot_timestamp = self.slotTimestamp(self.expectedCurrentSlot());

        const age = current_slot_timestamp -| slot_timestamp;
        return age < self.config.max_checkpoint_age;
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

fn parseHex32(comptime value: []const u8) [32]u8 {
    var bytes: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, value) catch unreachable;
    return bytes;
}
