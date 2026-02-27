const std = @import("std");
const runtime = @import("runtime.zig");

test "NodeRuntime.init uses deterministic defaults" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    try std.testing.expectEqual(@as(u64, 31337), rt.chain_id);
    try std.testing.expectEqual(@as(u64, 0), rt.head_block_number);
    try std.testing.expectEqual(runtime.DEFAULT_DEV_ACCOUNTS[0], rt.coinbase);
}

test "NodeRuntime.init seeds dev account balances" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    for (&runtime.DEFAULT_DEV_ACCOUNTS) |addr| {
        const balance = try rt.state.getBalance(addr);
        try std.testing.expectEqual(runtime.DEFAULT_BALANCE, balance);
    }
}

test "NodeRuntime.init respects custom config" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{
        .chain_id = 1,
        .coinbase_index = 2,
        .initial_balance = 42,
    });
    defer rt.deinit();

    try std.testing.expectEqual(@as(u64, 1), rt.chain_id);
    try std.testing.expectEqual(runtime.DEFAULT_DEV_ACCOUNTS[2], rt.coinbase);

    const balance = try rt.state.getBalance(runtime.DEFAULT_DEV_ACCOUNTS[0]);
    try std.testing.expectEqual(@as(u256, 42), balance);
}

test "NodeRuntime.init head block number starts at 0" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    try std.testing.expectEqual(@as(u64, 0), rt.head_block_number);
}

test "NodeRuntime.deinit releases state" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    rt.deinit();
    // If allocator leaks, testing.allocator will detect it
}
