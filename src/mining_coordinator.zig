const std = @import("std");
const primitives = @import("primitives");
const state_manager = @import("state-manager");
const guillotine_mini = @import("guillotine_mini");
const tx_processor = @import("tx_processor.zig");
const block_builder = @import("block_builder.zig");
const host_adapter = @import("host_adapter.zig");

pub const MiningMode = enum {
    auto,
    manual,
    interval,
};

pub const MiningCoordinator = struct {
    pending_txs: std.ArrayList(tx_processor.ExecutionTx),
    mode: MiningMode,
    interval_seconds: u64,
    current_block_number: u64,
    current_timestamp: u64,
    block_gas_limit: u64,
    chain_id: u256,
    coinbase: primitives.Address,
    mined_blocks: std.ArrayList(block_builder.BlockResult),

    pub fn init() MiningCoordinator {
        return .{
            .pending_txs = .{},
            .mode = .auto,
            .interval_seconds = 0,
            .current_block_number = 1,
            .current_timestamp = 1000,
            .block_gas_limit = 30_000_000,
            .chain_id = 1,
            .coinbase = primitives.Address{ .bytes = [_]u8{0xCB} ++ [_]u8{0} ** 19 },
            .mined_blocks = .{},
        };
    }

    pub fn deinit(self: *MiningCoordinator, allocator: std.mem.Allocator) void {
        self.pending_txs.deinit(allocator);
        for (self.mined_blocks.items) |*b| {
            b.deinit(allocator);
        }
        self.mined_blocks.deinit(allocator);
    }

    pub fn setMode(self: *MiningCoordinator, mode: MiningMode) void {
        if (self.mode == .interval and mode != .interval) {
            self.interval_seconds = 0;
        }
        self.mode = mode;
    }

    pub fn submitTx(
        self: *MiningCoordinator,
        allocator: std.mem.Allocator,
        sm: *state_manager.StateManager,
        tx: tx_processor.ExecutionTx,
    ) !void {
        try self.pending_txs.append(allocator, tx);
        if (self.mode == .auto) {
            var adapter = host_adapter.HostAdapter{ .state = sm };
            _ = try self.mineBlock(allocator, sm, adapter.hostInterface());
        }
    }

    pub fn mineBlock(
        self: *MiningCoordinator,
        allocator: std.mem.Allocator,
        sm: *state_manager.StateManager,
        host_iface: guillotine_mini.HostInterface,
    ) !block_builder.BlockResult {
        const block_ctx = guillotine_mini.BlockContext{
            .chain_id = self.chain_id,
            .block_number = self.current_block_number,
            .block_timestamp = self.current_timestamp,
            .block_difficulty = 0,
            .block_prevrandao = 0,
            .block_coinbase = self.coinbase,
            .block_gas_limit = self.block_gas_limit,
            .block_base_fee = 0,
            .blob_base_fee = 0,
        };

        const result = try block_builder.buildBlock(
            allocator,
            sm,
            host_iface,
            self.pending_txs.items,
            block_ctx,
        );

        self.pending_txs.clearRetainingCapacity();
        self.current_block_number += 1;
        self.current_timestamp += 1;

        const result_copy = result;
        try self.mined_blocks.append(allocator, result_copy);

        return result;
    }

    pub fn mineBlocks(
        self: *MiningCoordinator,
        allocator: std.mem.Allocator,
        sm: *state_manager.StateManager,
        host_iface: guillotine_mini.HostInterface,
        count: u64,
        interval: u64,
    ) !void {
        var i: u64 = 0;
        while (i < count) : (i += 1) {
            if (i > 0 and interval > 0) {
                self.current_timestamp += interval - 1;
            }
            var result = try self.mineBlock(allocator, sm, host_iface);
            _ = &result;
        }
    }

    pub fn setIntervalMining(self: *MiningCoordinator, seconds: u64) void {
        if (seconds == 0) {
            self.setMode(.manual);
        } else {
            self.interval_seconds = seconds;
            self.mode = .interval;
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn makeLegacyTx(params: struct {
    to: ?primitives.Address,
    value: u256,
    data: []const u8,
    gas_limit: u64,
    gas_price: u256,
    nonce: u64,
}) primitives.Transaction.LegacyTransaction {
    return .{
        .nonce = params.nonce,
        .gas_price = params.gas_price,
        .gas_limit = params.gas_limit,
        .to = params.to,
        .value = params.value,
        .data = params.data,
        .v = 0,
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
    };
}

fn makeTestTx(sender: primitives.Address, recipient: primitives.Address, nonce: u64) tx_processor.ExecutionTx {
    return .{
        .caller = sender,
        .tx = makeLegacyTx(.{
            .to = recipient,
            .value = 0,
            .data = &[_]u8{},
            .gas_limit = 21_000,
            .gas_price = 1,
            .nonce = nonce,
        }),
    };
}

test "MiningCoordinator init and deinit" {
    var mc = MiningCoordinator.init();
    defer mc.deinit(std.testing.allocator);

    try std.testing.expectEqual(MiningMode.auto, mc.mode);
    try std.testing.expectEqual(@as(u64, 0), mc.interval_seconds);
    try std.testing.expectEqual(@as(u64, 1), mc.current_block_number);
    try std.testing.expectEqual(@as(usize, 0), mc.pending_txs.items.len);
}

test "MiningCoordinator setMode transitions" {
    var mc = MiningCoordinator.init();
    defer mc.deinit(std.testing.allocator);

    mc.setMode(.manual);
    try std.testing.expectEqual(MiningMode.manual, mc.mode);

    mc.setMode(.interval);
    mc.interval_seconds = 5;
    try std.testing.expectEqual(MiningMode.interval, mc.mode);

    // Switching away from interval clears interval_seconds
    mc.setMode(.auto);
    try std.testing.expectEqual(MiningMode.auto, mc.mode);
    try std.testing.expectEqual(@as(u64, 0), mc.interval_seconds);
}

test "MiningCoordinator submitTx queues in manual mode" {
    var mc = MiningCoordinator.init();
    defer mc.deinit(std.testing.allocator);
    mc.setMode(.manual);

    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    const sender = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 };
    const recipient = primitives.Address{ .bytes = [_]u8{0x02} ++ [_]u8{0} ** 19 };

    try sm.setBalance(sender, 1_000_000);
    try sm.setNonce(sender, 0);

    try mc.submitTx(std.testing.allocator, &sm, makeTestTx(sender, recipient, 0));

    try std.testing.expectEqual(@as(usize, 1), mc.pending_txs.items.len);
    try std.testing.expectEqual(@as(usize, 0), mc.mined_blocks.items.len);
}

test "MiningCoordinator submitTx mines immediately in auto mode" {
    var mc = MiningCoordinator.init();
    defer mc.deinit(std.testing.allocator);

    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    const sender = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 };
    const recipient = primitives.Address{ .bytes = [_]u8{0x02} ++ [_]u8{0} ** 19 };

    try sm.setBalance(sender, 1_000_000);
    try sm.setNonce(sender, 0);

    try mc.submitTx(std.testing.allocator, &sm, makeTestTx(sender, recipient, 0));

    // Auto mode should have drained pending and produced a block
    try std.testing.expectEqual(@as(usize, 0), mc.pending_txs.items.len);
    try std.testing.expectEqual(@as(usize, 1), mc.mined_blocks.items.len);
}

test "MiningCoordinator mineBlock drains pending pool" {
    var mc = MiningCoordinator.init();
    defer mc.deinit(std.testing.allocator);
    mc.setMode(.manual);

    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var adapter = host_adapter.HostAdapter{ .state = &sm };
    const host = adapter.hostInterface();

    const sender = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 };
    const recipient = primitives.Address{ .bytes = [_]u8{0x02} ++ [_]u8{0} ** 19 };

    try sm.setBalance(sender, 1_000_000);
    try sm.setNonce(sender, 0);

    try mc.submitTx(std.testing.allocator, &sm, makeTestTx(sender, recipient, 0));
    try std.testing.expectEqual(@as(usize, 1), mc.pending_txs.items.len);

    var result = try mc.mineBlock(std.testing.allocator, &sm, host);
    _ = &result;

    try std.testing.expectEqual(@as(usize, 0), mc.pending_txs.items.len);
    try std.testing.expectEqual(@as(usize, 1), mc.mined_blocks.items.len);
    try std.testing.expectEqual(@as(u64, 2), mc.current_block_number);
}

test "MiningCoordinator mineBlocks handles timestamp intervals" {
    var mc = MiningCoordinator.init();
    defer mc.deinit(std.testing.allocator);
    mc.setMode(.manual);

    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var adapter = host_adapter.HostAdapter{ .state = &sm };
    const host = adapter.hostInterface();

    const initial_timestamp = mc.current_timestamp;
    const initial_block = mc.current_block_number;

    try mc.mineBlocks(std.testing.allocator, &sm, host, 3, 10);

    try std.testing.expectEqual(initial_block + 3, mc.current_block_number);
    try std.testing.expectEqual(@as(usize, 3), mc.mined_blocks.items.len);

    // First block uses initial timestamp, second +10, third +10
    // After 3 blocks: initial + 1 (from first mineBlock) + 10-1 + 1 (second) + 10-1 + 1 (third)
    // = initial + 1 + 10 + 10 = initial + 21
    try std.testing.expectEqual(initial_timestamp + 21, mc.current_timestamp);
}

test "MiningCoordinator setIntervalMining toggles modes" {
    var mc = MiningCoordinator.init();
    defer mc.deinit(std.testing.allocator);

    mc.setIntervalMining(5);
    try std.testing.expectEqual(MiningMode.interval, mc.mode);
    try std.testing.expectEqual(@as(u64, 5), mc.interval_seconds);

    mc.setIntervalMining(0);
    try std.testing.expectEqual(MiningMode.manual, mc.mode);
    try std.testing.expectEqual(@as(u64, 0), mc.interval_seconds);
}
