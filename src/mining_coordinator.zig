const std = @import("std");
const primitives = @import("primitives");
const state_manager = @import("state-manager");
const guillotine_mini = @import("guillotine_mini");
const tx_processor = @import("tx_processor.zig");
const block_builder = @import("block_builder.zig");
const host_adapter = @import("host_adapter.zig");
const dev_runtime = @import("rpc/dev_runtime.zig");
const hardfork_schedule = @import("hardfork_schedule.zig");

pub const INITIAL_BASE_FEE: u256 = 1_000_000_000;
pub const BASE_FEE_MAX_CHANGE_DENOMINATOR: u64 = 8;
pub const ELASTICITY_MULTIPLIER: u64 = 2;
pub const GAS_PER_BLOB: u64 = 131_072;
pub const CANCUN_TARGET_BLOB_GAS_PER_BLOCK: u64 = 393_216;
pub const CANCUN_MAX_BLOB_GAS_PER_BLOCK: u64 = 786_432;
pub const PRAGUE_TARGET_BLOB_GAS_PER_BLOCK: u64 = 786_432;
pub const PRAGUE_MAX_BLOB_GAS_PER_BLOCK: u64 = 1_179_648;
pub const MIN_BASE_FEE_PER_BLOB_GAS: u256 = 1;
pub const CANCUN_BLOB_BASE_FEE_UPDATE_FRACTION: u64 = 3_338_477;
pub const PRAGUE_BLOB_BASE_FEE_UPDATE_FRACTION: u64 = 5_007_716;

pub const MAINNET_CHAIN_CONFIG = hardfork_schedule.MAINNET_CHAIN_CONFIG;
pub const ChainConfig = hardfork_schedule.ChainConfig;

pub const HeaderValidationError = error{
    MissingBaseFee,
    InvalidBaseFee,
    UnexpectedBaseFee,
    MissingBlobGas,
    InvalidExcessBlobGas,
    UnexpectedBlobGas,
    BlobGasLimitExceeded,
};

pub const MiningMode = enum {
    auto,
    manual,
    interval,
};

pub const MiningBlockOptions = struct {
    prevrandao: u256 = 0,
    blob_gas_used: u64 = 0,
    block_hashes: []const [32]u8 = &.{},
    dev_runtime: ?*dev_runtime.DevRuntime = null,
};

pub fn resolveHardfork(block_number: u64, timestamp: u64) primitives.Hardfork {
    return hardfork_schedule.resolveHardfork(block_number, timestamp);
}

pub fn resolveHardforkWithConfig(config: ChainConfig, block_number: u64, timestamp: u64) primitives.Hardfork {
    return hardfork_schedule.resolveHardforkWithConfig(config, block_number, timestamp);
}

pub fn calculateNextBaseFee(parent_base_fee: u256, parent_gas_used: u64, parent_gas_limit: u64) u256 {
    const target_gas = parent_gas_limit / ELASTICITY_MULTIPLIER;
    if (target_gas == 0 or parent_gas_used == target_gas) return parent_base_fee;

    if (parent_gas_used > target_gas) {
        const gas_delta = parent_gas_used - target_gas;
        const product = @as(u512, parent_base_fee) * @as(u512, gas_delta);
        const delta_raw = product / @as(u512, target_gas) / @as(u512, BASE_FEE_MAX_CHANGE_DENOMINATOR);
        const delta = @max(@as(u256, 1), clampU512ToU256(delta_raw));
        return std.math.add(u256, parent_base_fee, delta) catch std.math.maxInt(u256);
    }

    const gas_delta = target_gas - parent_gas_used;
    const product = @as(u512, parent_base_fee) * @as(u512, gas_delta);
    const delta = clampU512ToU256(product / @as(u512, target_gas) / @as(u512, BASE_FEE_MAX_CHANGE_DENOMINATOR));
    return if (delta > parent_base_fee) 0 else parent_base_fee - delta;
}

pub fn nextBaseFee(
    parent_header: primitives.BlockHeader.BlockHeader,
    child_block_number: u64,
    child_timestamp: u64,
) HeaderValidationError!?u256 {
    const child_hardfork = resolveHardfork(child_block_number, child_timestamp);
    if (child_hardfork.isBefore(.LONDON)) return null;

    const parent_hardfork = resolveHardfork(parent_header.number, parent_header.timestamp);
    if (parent_hardfork.isBefore(.LONDON)) return INITIAL_BASE_FEE;

    const parent_base_fee = parent_header.base_fee_per_gas orelse return HeaderValidationError.MissingBaseFee;
    return calculateNextBaseFee(parent_base_fee, parent_header.gas_used, parent_header.gas_limit);
}

pub fn validateBaseFee(
    parent_header: primitives.BlockHeader.BlockHeader,
    child_header: primitives.BlockHeader.BlockHeader,
) HeaderValidationError!void {
    const expected = try nextBaseFee(parent_header, child_header.number, child_header.timestamp);
    if (expected) |base_fee| {
        const actual = child_header.base_fee_per_gas orelse return HeaderValidationError.MissingBaseFee;
        if (actual != base_fee) return HeaderValidationError.InvalidBaseFee;
        return;
    }

    if (child_header.base_fee_per_gas) |base_fee| {
        if (base_fee != 0) return HeaderValidationError.UnexpectedBaseFee;
    }
}

pub fn blobTargetGasPerBlock(hardfork: primitives.Hardfork) u64 {
    return if (hardfork.isAtLeast(.PRAGUE)) PRAGUE_TARGET_BLOB_GAS_PER_BLOCK else CANCUN_TARGET_BLOB_GAS_PER_BLOCK;
}

pub fn maxBlobGasPerBlock(hardfork: primitives.Hardfork) u64 {
    return if (hardfork.isAtLeast(.PRAGUE)) PRAGUE_MAX_BLOB_GAS_PER_BLOCK else CANCUN_MAX_BLOB_GAS_PER_BLOCK;
}

pub fn calculateNextExcessBlobGas(parent_excess_blob_gas: u64, parent_blob_gas_used: u64, target_blob_gas: u64) u64 {
    const parent_blob_gas = std.math.add(u64, parent_excess_blob_gas, parent_blob_gas_used) catch std.math.maxInt(u64);
    return if (parent_blob_gas < target_blob_gas) 0 else parent_blob_gas - target_blob_gas;
}

pub fn nextExcessBlobGas(parent_header: primitives.BlockHeader.BlockHeader) u64 {
    return nextExcessBlobGasForChild(
        parent_header,
        parent_header.number + 1,
        parent_header.timestamp + MAINNET_CHAIN_CONFIG.seconds_per_slot,
    );
}

pub fn nextExcessBlobGasForChild(
    parent_header: primitives.BlockHeader.BlockHeader,
    child_block_number: u64,
    child_timestamp: u64,
) u64 {
    const child_hardfork = resolveHardfork(child_block_number, child_timestamp);
    if (child_hardfork.isBefore(.CANCUN)) return 0;

    const parent_hardfork = resolveHardfork(parent_header.number, parent_header.timestamp);
    const parent_excess_blob_gas = if (parent_hardfork.isAtLeast(.CANCUN)) parent_header.excess_blob_gas orelse 0 else 0;
    const parent_blob_gas_used = if (parent_hardfork.isAtLeast(.CANCUN)) parent_header.blob_gas_used orelse 0 else 0;

    return calculateNextExcessBlobGas(parent_excess_blob_gas, parent_blob_gas_used, blobTargetGasPerBlock(child_hardfork));
}

pub fn nextBlobBaseFee(excess_blob_gas: u64, hardfork: primitives.Hardfork) u256 {
    if (hardfork.isBefore(.CANCUN)) return 0;
    const denominator = if (hardfork.isAtLeast(.PRAGUE))
        PRAGUE_BLOB_BASE_FEE_UPDATE_FRACTION
    else
        CANCUN_BLOB_BASE_FEE_UPDATE_FRACTION;
    return fakeExponential(MIN_BASE_FEE_PER_BLOB_GAS, excess_blob_gas, denominator);
}

pub fn fakeExponential(factor: u256, numerator: u64, denominator: u64) u256 {
    if (denominator == 0) return std.math.maxInt(u256);

    var i: u512 = 1;
    var output: u512 = 0;
    var numerator_accumulated = @as(u512, factor) * @as(u512, denominator);
    while (numerator_accumulated > 0) {
        output = std.math.add(u512, output, numerator_accumulated) catch std.math.maxInt(u512);
        const product = std.math.mul(u512, numerator_accumulated, @as(u512, numerator)) catch std.math.maxInt(u512);
        numerator_accumulated = product / (@as(u512, denominator) * i);
        i += 1;
    }

    return clampU512ToU256(output / @as(u512, denominator));
}

pub fn validateBlobGas(
    parent_header: primitives.BlockHeader.BlockHeader,
    child_header: primitives.BlockHeader.BlockHeader,
) HeaderValidationError!void {
    const child_hardfork = resolveHardfork(child_header.number, child_header.timestamp);
    if (child_hardfork.isBefore(.CANCUN)) {
        if ((child_header.blob_gas_used orelse 0) != 0) return HeaderValidationError.UnexpectedBlobGas;
        if ((child_header.excess_blob_gas orelse 0) != 0) return HeaderValidationError.UnexpectedBlobGas;
        return;
    }

    const blob_gas_used = child_header.blob_gas_used orelse return HeaderValidationError.MissingBlobGas;
    if (blob_gas_used > maxBlobGasPerBlock(child_hardfork)) return HeaderValidationError.BlobGasLimitExceeded;

    const expected_excess_blob_gas = nextExcessBlobGasForChild(parent_header, child_header.number, child_header.timestamp);
    const actual_excess_blob_gas = child_header.excess_blob_gas orelse return HeaderValidationError.MissingBlobGas;
    if (actual_excess_blob_gas != expected_excess_blob_gas) return HeaderValidationError.InvalidExcessBlobGas;
}

fn clampU512ToU256(value: u512) u256 {
    const max_u256 = @as(u512, std.math.maxInt(u256));
    return if (value > max_u256) std.math.maxInt(u256) else @intCast(value);
}

pub const MiningCoordinator = struct {
    pending_txs: std.ArrayList(tx_processor.ExecutionTx),
    mode: MiningMode,
    interval_seconds: u64,
    current_block_number: u64,
    current_timestamp: u64,
    block_gas_limit: u64,
    chain_id: u256,
    chain_config: hardfork_schedule.ChainConfig,
    coinbase: primitives.Address,
    current_base_fee_per_gas: ?u256,
    current_excess_blob_gas: u64,
    current_blob_gas_used: u64,
    next_prevrandao: u256,
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
            .chain_config = hardfork_schedule.MAINNET_CHAIN_CONFIG,
            .coinbase = primitives.Address{ .bytes = [_]u8{0xCB} ++ [_]u8{0} ** 19 },
            .current_base_fee_per_gas = null,
            .current_excess_blob_gas = 0,
            .current_blob_gas_used = 0,
            .next_prevrandao = 0,
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

    pub fn setNextPrevrandao(self: *MiningCoordinator, prevrandao: u256) void {
        self.next_prevrandao = prevrandao;
    }

    pub fn blockContext(self: *const MiningCoordinator, options: MiningBlockOptions) guillotine_mini.BlockContext {
        const active_hardfork = resolveHardforkWithConfig(self.chain_config, self.current_block_number, self.current_timestamp);
        const block_base_fee = currentBlockBaseFee(self.current_base_fee_per_gas, active_hardfork);
        const excess_blob_gas = if (active_hardfork.isAtLeast(.CANCUN)) self.current_excess_blob_gas else 0;

        return guillotine_mini.BlockContext{
            .chain_id = self.chain_id,
            .block_number = self.current_block_number,
            .block_timestamp = self.current_timestamp,
            .block_difficulty = 0,
            .block_prevrandao = if (active_hardfork.isAtLeast(.MERGE)) options.prevrandao else 0,
            .block_coinbase = self.coinbase,
            .block_gas_limit = self.block_gas_limit,
            .block_base_fee = block_base_fee,
            .blob_base_fee = nextBlobBaseFee(excess_blob_gas, active_hardfork),
            .block_hashes = options.block_hashes,
        };
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
        return self.mineBlockWithOptions(allocator, sm, host_iface, .{
            .prevrandao = self.next_prevrandao,
        });
    }

    pub fn mineBlockWithPrevrandao(
        self: *MiningCoordinator,
        allocator: std.mem.Allocator,
        sm: *state_manager.StateManager,
        host_iface: guillotine_mini.HostInterface,
        prevrandao: u256,
    ) !block_builder.BlockResult {
        return self.mineBlockWithOptions(allocator, sm, host_iface, .{
            .prevrandao = prevrandao,
        });
    }

    pub fn mineBlockWithOptions(
        self: *MiningCoordinator,
        allocator: std.mem.Allocator,
        sm: *state_manager.StateManager,
        host_iface: guillotine_mini.HostInterface,
        options: MiningBlockOptions,
    ) !block_builder.BlockResult {
        const block_ctx = block_builder.blockContextWithEnvironmentOverrides(options.dev_runtime, self.blockContext(options));
        const active_hardfork = resolveHardforkWithConfig(self.chain_config, block_ctx.block_number, block_ctx.block_timestamp);
        const block_base_fee = block_ctx.block_base_fee;

        const result = try block_builder.buildBlockWithOptions(
            allocator,
            sm,
            host_iface,
            self.pending_txs.items,
            block_ctx,
            .{
                .dev_runtime = options.dev_runtime,
                .hardfork_config = self.chain_config,
            },
        );

        self.pending_txs.clearRetainingCapacity();
        self.advanceFeeState(active_hardfork, block_base_fee, result.total_gas_used, options.blob_gas_used, block_ctx.block_gas_limit);
        self.current_block_number += 1;
        self.current_timestamp = block_ctx.block_timestamp +| 1;

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
        try self.mineBlocksWithOptions(allocator, sm, host_iface, count, interval, .{});
    }

    pub fn mineBlocksWithOptions(
        self: *MiningCoordinator,
        allocator: std.mem.Allocator,
        sm: *state_manager.StateManager,
        host_iface: guillotine_mini.HostInterface,
        count: u64,
        interval: u64,
        options: MiningBlockOptions,
    ) !void {
        var i: u64 = 0;
        while (i < count) : (i += 1) {
            if (i > 0 and interval > 0) {
                self.current_timestamp += interval - 1;
            }
            var result = try self.mineBlockWithOptions(allocator, sm, host_iface, options);
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

    fn advanceFeeState(
        self: *MiningCoordinator,
        active_hardfork: primitives.Hardfork,
        block_base_fee: u256,
        gas_used: u64,
        blob_gas_used: u64,
        block_gas_limit: u64,
    ) void {
        const next_hardfork = resolveHardforkWithConfig(self.chain_config, self.current_block_number + 1, self.current_timestamp + 1);
        if (next_hardfork.isBefore(.LONDON)) {
            self.current_base_fee_per_gas = null;
        } else if (active_hardfork.isBefore(.LONDON)) {
            self.current_base_fee_per_gas = INITIAL_BASE_FEE;
        } else {
            self.current_base_fee_per_gas = calculateNextBaseFee(block_base_fee, gas_used, block_gas_limit);
        }

        if (next_hardfork.isBefore(.CANCUN)) {
            self.current_excess_blob_gas = 0;
            self.current_blob_gas_used = 0;
            return;
        }

        const parent_excess_blob_gas = if (active_hardfork.isAtLeast(.CANCUN)) self.current_excess_blob_gas else 0;
        const parent_blob_gas_used = if (active_hardfork.isAtLeast(.CANCUN)) blob_gas_used else 0;
        self.current_excess_blob_gas = calculateNextExcessBlobGas(
            parent_excess_blob_gas,
            parent_blob_gas_used,
            blobTargetGasPerBlock(next_hardfork),
        );
        self.current_blob_gas_used = 0;
    }
};

fn currentBlockBaseFee(current_base_fee_per_gas: ?u256, hardfork: primitives.Hardfork) u256 {
    if (hardfork.isBefore(.LONDON)) return 0;
    return current_base_fee_per_gas orelse INITIAL_BASE_FEE;
}

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
