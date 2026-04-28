const std = @import("std");
const primitives = @import("primitives");
const state_manager = @import("state-manager");
const blockchain = @import("blockchain");

pub const DEFAULT_BLOCK_GAS_LIMIT: u64 = 30_000_000;

pub const NodeDevConfig = struct {
    coinbase: primitives.Address.Address,
    next_block_base_fee_per_gas: ?u256,
    next_block_timestamp: ?u64,
    block_gas_limit: u64,
    blob_base_fee: ?u256,
};

pub const SnapshotEntry = struct {
    state_snapshot_id: u64,
    block_number: u64,
    config: NodeDevConfig,
};

pub const DevRuntime = struct {
    snapshots: std.AutoHashMapUnmanaged(u64, SnapshotEntry),
    next_snapshot_id: u64,
    config: NodeDevConfig,

    pub fn init() DevRuntime {
        return initWithCoinbase(primitives.Address.Address.ZERO_ADDRESS);
    }

    pub fn initWithCoinbase(coinbase: primitives.Address.Address) DevRuntime {
        return .{
            .snapshots = .{},
            .next_snapshot_id = 1,
            .config = defaultConfig(coinbase),
        };
    }

    pub fn deinit(self: *DevRuntime, allocator: std.mem.Allocator) void {
        self.snapshots.deinit(allocator);
    }

    pub fn resetConfig(self: *DevRuntime, coinbase: primitives.Address.Address) void {
        self.config = defaultConfig(coinbase);
    }

    pub fn clearNextBlockOverrides(self: *DevRuntime) void {
        self.config.next_block_base_fee_per_gas = null;
        self.config.next_block_timestamp = null;
    }

    pub fn takeSnapshot(
        self: *DevRuntime,
        allocator: std.mem.Allocator,
        state: *state_manager.StateManager,
        block_number: u64,
    ) !u64 {
        const snapshot_id = self.next_snapshot_id;
        self.next_snapshot_id += 1;

        const state_snapshot_id = try state.snapshot();

        try self.snapshots.put(allocator, snapshot_id, .{
            .state_snapshot_id = state_snapshot_id,
            .block_number = block_number,
            .config = self.config,
        });

        return snapshot_id;
    }

    pub fn revertSnapshot(
        self: *DevRuntime,
        allocator: std.mem.Allocator,
        state: *state_manager.StateManager,
        bc: *blockchain.Blockchain,
        snapshot_id: u64,
    ) !bool {
        _ = bc;
        const entry = self.snapshots.get(snapshot_id) orelse return false;

        state.revertToSnapshot(entry.state_snapshot_id) catch return false;

        self.config = entry.config;

        var to_remove = std.ArrayList(u64){};
        defer to_remove.deinit(allocator);

        var it = self.snapshots.iterator();
        while (it.next()) |kv| {
            if (kv.key_ptr.* >= snapshot_id) {
                try to_remove.append(allocator, kv.key_ptr.*);
            }
        }

        for (to_remove.items) |id| {
            _ = self.snapshots.remove(id);
        }

        return true;
    }
};

pub fn defaultConfig(coinbase: primitives.Address.Address) NodeDevConfig {
    return .{
        .coinbase = coinbase,
        .next_block_base_fee_per_gas = null,
        .next_block_timestamp = null,
        .block_gas_limit = DEFAULT_BLOCK_GAS_LIMIT,
        .blob_base_fee = null,
    };
}

test "takeSnapshot stores state snapshot id and block number" {
    const allocator = std.testing.allocator;
    var runtime = DevRuntime.init();
    defer runtime.deinit(allocator);

    var state = try state_manager.StateManager.init(allocator, null);
    defer state.deinit();

    const snap_id = try runtime.takeSnapshot(allocator, &state, 42);

    try std.testing.expect(snap_id >= 1);
    const entry = runtime.snapshots.get(snap_id).?;
    try std.testing.expectEqual(@as(u64, 42), entry.block_number);
}

test "takeSnapshot clones node config" {
    const allocator = std.testing.allocator;
    var runtime = DevRuntime.init();
    defer runtime.deinit(allocator);

    var state = try state_manager.StateManager.init(allocator, null);
    defer state.deinit();

    runtime.config.block_gas_limit = 15_000_000;
    runtime.config.next_block_timestamp = 1234;
    runtime.config.blob_base_fee = 7;
    const snap_id = try runtime.takeSnapshot(allocator, &state, 0);

    runtime.config.block_gas_limit = 99_000_000;
    runtime.config.next_block_timestamp = 9999;
    runtime.config.blob_base_fee = 42;

    const entry = runtime.snapshots.get(snap_id).?;
    try std.testing.expectEqual(@as(u64, 15_000_000), entry.config.block_gas_limit);
    try std.testing.expectEqual(@as(u64, 1234), entry.config.next_block_timestamp.?);
    try std.testing.expectEqual(@as(u256, 7), entry.config.blob_base_fee.?);
}

test "revertSnapshot returns false for unknown id" {
    const allocator = std.testing.allocator;
    var runtime = DevRuntime.init();
    defer runtime.deinit(allocator);

    var state = try state_manager.StateManager.init(allocator, null);
    defer state.deinit();

    var bc = try blockchain.Blockchain.init(allocator, null);
    defer bc.deinit();

    const result = try runtime.revertSnapshot(allocator, &state, &bc, 999);
    try std.testing.expect(!result);
}

test "revertSnapshot restores block number and config" {
    const allocator = std.testing.allocator;
    var runtime = DevRuntime.init();
    defer runtime.deinit(allocator);

    var state = try state_manager.StateManager.init(allocator, null);
    defer state.deinit();

    var bc = try blockchain.Blockchain.init(allocator, null);
    defer bc.deinit();

    runtime.config.block_gas_limit = 15_000_000;
    runtime.config.next_block_base_fee_per_gas = 2;
    runtime.config.next_block_timestamp = 1234;
    runtime.config.blob_base_fee = 7;
    const snap_id = try runtime.takeSnapshot(allocator, &state, 5);

    runtime.config.block_gas_limit = 99_000_000;
    runtime.config.next_block_base_fee_per_gas = 3;
    runtime.config.next_block_timestamp = 9999;
    runtime.config.blob_base_fee = 42;

    const result = try runtime.revertSnapshot(allocator, &state, &bc, snap_id);
    try std.testing.expect(result);
    try std.testing.expectEqual(@as(u64, 15_000_000), runtime.config.block_gas_limit);
    try std.testing.expectEqual(@as(u256, 2), runtime.config.next_block_base_fee_per_gas.?);
    try std.testing.expectEqual(@as(u64, 1234), runtime.config.next_block_timestamp.?);
    try std.testing.expectEqual(@as(u256, 7), runtime.config.blob_base_fee.?);
}

test "clearNextBlockOverrides keeps persistent block environment overrides" {
    const allocator = std.testing.allocator;
    var runtime = DevRuntime.init();
    defer runtime.deinit(allocator);

    runtime.config.next_block_base_fee_per_gas = 2;
    runtime.config.next_block_timestamp = 1234;
    runtime.config.block_gas_limit = 15_000_000;
    runtime.config.blob_base_fee = 7;

    runtime.clearNextBlockOverrides();

    try std.testing.expect(runtime.config.next_block_base_fee_per_gas == null);
    try std.testing.expect(runtime.config.next_block_timestamp == null);
    try std.testing.expectEqual(@as(u64, 15_000_000), runtime.config.block_gas_limit);
    try std.testing.expectEqual(@as(u256, 7), runtime.config.blob_base_fee.?);
}

test "revertSnapshot removes newer snapshots (nested semantics)" {
    const allocator = std.testing.allocator;
    var runtime = DevRuntime.init();
    defer runtime.deinit(allocator);

    var state = try state_manager.StateManager.init(allocator, null);
    defer state.deinit();

    var bc = try blockchain.Blockchain.init(allocator, null);
    defer bc.deinit();

    const snap1 = try runtime.takeSnapshot(allocator, &state, 0);
    const snap2 = try runtime.takeSnapshot(allocator, &state, 1);

    const result = try runtime.revertSnapshot(allocator, &state, &bc, snap1);
    try std.testing.expect(result);

    const result2 = try runtime.revertSnapshot(allocator, &state, &bc, snap2);
    try std.testing.expect(!result2);
}
