const std = @import("std");
const jsonrpc = @import("jsonrpc");
const eth_read = @import("eth_read.zig");
const runtime = @import("../../node/runtime.zig");

fn makeBlockSpec(tag: []const u8) jsonrpc.types.BlockSpec {
    return .{ .value = .{ .string = tag } };
}

// --- AC: eth_chainId returns configured chain ID ---

test "eth_chainId returns configured chain id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();
    rt.head_block_number = 5;

    const result = try eth_read.handleEthChainId(arena.allocator(), &rt, .{});
    try expectQuantityStr(result.value, "0x7a69"); // 31337
}

test "eth_chainId returns custom chain id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{ .chain_id = 1 });
    defer rt.deinit();

    const result = try eth_read.handleEthChainId(arena.allocator(), &rt, .{});
    try expectQuantityStr(result.value, "0x1");
}

// --- AC: eth_blockNumber returns current head ---

test "eth_blockNumber returns current head number" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();
    const result = try eth_read.handleEthBlockNumber(arena.allocator(), &rt, .{});
    try expectQuantityStr(result.value, "0x0");
}

test "eth_blockNumber reflects updated head" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();
    rt.head_block_number = 5;
    rt.head_block_number = 42;

    const result = try eth_read.handleEthBlockNumber(arena.allocator(), &rt, .{});
    try expectQuantityStr(result.value, "0x2a");
}

// --- AC: eth_getBalance reads from state manager ---

test "eth_getBalance returns dev account balance at latest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();
    rt.head_block_number = 5;

    const result = try eth_read.handleEthGetBalance(
        arena.allocator(),
        &rt,
        .{
            .address = .{ .bytes = runtime.DEFAULT_DEV_ACCOUNTS[0].bytes },
            .block = makeBlockSpec("latest"),
        },
    );

    // 10000 ETH = 10000 * 1e18 = 0x21e19e0c9bab2400000
    try expectQuantityStr(result.value, "0x21e19e0c9bab2400000");
}

test "eth_getBalance returns 0 for unknown address" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const result = try eth_read.handleEthGetBalance(
        arena.allocator(),
        &rt,
        .{
            .address = .{ .bytes = [_]u8{0xde} ** 20 },
            .block = makeBlockSpec("latest"),
        },
    );
    try expectQuantityStr(result.value, "0x0");
}


// --- AC: eth_getTransactionCount reads nonce ---

test "eth_getTransactionCount returns 0 for fresh account" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const result = try eth_read.handleEthGetTransactionCount(
        arena.allocator(),
        &rt,
        .{
            .address = .{ .bytes = runtime.DEFAULT_DEV_ACCOUNTS[0].bytes },
            .block = makeBlockSpec("latest"),
        },
    );
    try expectQuantityStr(result.value, "0x0");
}


// --- AC: eth_coinbase returns coinbase address ---

test "eth_coinbase returns default coinbase" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const result = try eth_read.handleEthCoinbase(std.testing.allocator, &rt, .{});
    try std.testing.expectEqual(runtime.DEFAULT_DEV_ACCOUNTS[0].bytes, result.value.bytes);
}

// --- AC: eth_accounts returns managed dev accounts ---

test "eth_accounts returns 10 dev accounts" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const result = try eth_read.handleEthAccounts(std.testing.allocator, &rt, .{});
    defer std.testing.allocator.free(result.value);

    try std.testing.expectEqual(@as(usize, 10), result.value.len);
    try std.testing.expectEqual(runtime.DEFAULT_DEV_ACCOUNTS[0].bytes, result.value[0].bytes);
    try std.testing.expectEqual(runtime.DEFAULT_DEV_ACCOUNTS[9].bytes, result.value[9].bytes);
}

// --- AC: eth_gasPrice returns valid hex quantity ---

test "eth_gasPrice returns default gas price" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const result = try eth_read.handleEthGasPrice(arena.allocator(), &rt, .{});
    // 2 gwei = 2_000_000_000 = 0x77359400
    try expectQuantityStr(result.value, "0x77359400");
}

// --- AC: eth_maxPriorityFeePerGas returns valid hex quantity ---

test "eth_maxPriorityFeePerGas returns default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const result = try eth_read.handleEthMaxPriorityFeePerGas(arena.allocator(), &rt, .{});
    // 1 gwei = 1_000_000_000 = 0x3b9aca00
    try expectQuantityStr(result.value, "0x3b9aca00");
}

// --- AC: eth_blobBaseFee returns valid hex quantity ---

test "eth_blobBaseFee returns default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const result = try eth_read.handleEthBlobBaseFee(arena.allocator(), &rt, .{});
    try expectQuantityStr(result.value, "0x1");
}

test "eth_blobBaseFee returns dev override" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    rt.dev_runtime.config.blob_base_fee = 7;
    const result = try eth_read.handleEthBlobBaseFee(arena.allocator(), &rt, .{});
    try expectQuantityStr(result.value, "0x7");
}

// --- AC: eth_feeHistory returns correctly shaped object ---

test "eth_feeHistory returns correct shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const result = try eth_read.handleEthFeeHistory(
        arena.allocator(),
        &rt,
        .{
            .block_count = .{ .value = .{ .string = "0x1" } },
            .newest_block = makeBlockSpec("latest"),
        },
    );

    // block_count=1 => base_fee_per_gas has 2 entries, gas_used_ratio has 1
    try std.testing.expectEqual(@as(usize, 2), result.base_fee_per_gas.len);
    try std.testing.expectEqual(@as(usize, 1), result.gas_used_ratio.len);
    try std.testing.expectEqual(@as(f64, 0.0), result.gas_used_ratio[0]);
}

test "eth_feeHistory truncates large count and genesis range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();
    rt.head_block_number = 3;

    const result = try eth_read.handleEthFeeHistory(
        arena.allocator(),
        &rt,
        .{
            .block_count = .{ .value = .{ .string = "0x800" } },
            .newest_block = makeBlockSpec("latest"),
        },
    );

    try expectQuantityStr(result.oldest_block, "0x0");
    try std.testing.expectEqual(@as(usize, 5), result.base_fee_per_gas.len);
    try std.testing.expectEqual(@as(usize, 4), result.gas_used_ratio.len);
}

test "eth_feeHistory includes reward when empty percentiles are provided" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();
    rt.head_block_number = 2;

    const percentiles = [_]f64{};
    const result = try eth_read.handleEthFeeHistory(
        arena.allocator(),
        &rt,
        .{
            .block_count = .{ .value = .{ .string = "0x2" } },
            .newest_block = makeBlockSpec("latest"),
            .reward_percentiles = &percentiles,
        },
    );

    const reward = result.reward orelse return error.ExpectedReward;
    try std.testing.expectEqual(@as(usize, 2), reward.len);
    try std.testing.expectEqual(@as(usize, 0), reward[0].len);
    try std.testing.expectEqual(@as(usize, 0), reward[1].len);
}

test "eth_feeHistory validates reward percentiles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const descending = [_]f64{ 50.0, 10.0 };
    try std.testing.expectError(error.InvalidParams, eth_read.handleEthFeeHistory(
        arena.allocator(),
        &rt,
        .{
            .block_count = .{ .value = .{ .string = "0x1" } },
            .newest_block = makeBlockSpec("latest"),
            .reward_percentiles = &descending,
        },
    ));

    const too_many = [_]f64{0.0} ** (eth_read.MAX_REWARD_PERCENTILES + 1);
    try std.testing.expectError(error.InvalidParams, eth_read.handleEthFeeHistory(
        arena.allocator(),
        &rt,
        .{
            .block_count = .{ .value = .{ .string = "0x1" } },
            .newest_block = makeBlockSpec("latest"),
            .reward_percentiles = &too_many,
        },
    ));
}

// --- Helper ---

fn expectQuantityStr(q: jsonrpc.types.Quantity, expected: []const u8) !void {
    switch (q.value) {
        .string => |s| try std.testing.expectEqualStrings(expected, s),
        else => return error.ExpectedString,
    }
}
