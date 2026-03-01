const std = @import("std");
const block_spec = @import("block_spec.zig");
const jsonrpc = @import("jsonrpc");
const runtime = @import("../../node/runtime.zig");

fn makeSpec(s: []const u8) jsonrpc.types.BlockSpec {
    return .{ .value = .{ .string = s } };
}

fn makeRuntime() !runtime.NodeRuntime {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    rt.head_block_number = 10;
    return rt;
}

test "resolveBlockNumber: latest returns head" {
    var rt = try makeRuntime();
    defer rt.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 10), try block_spec.resolveBlockNumber(&rt, makeSpec("latest")));
}

test "resolveBlockNumber: pending returns head" {
    var rt = try makeRuntime();
    defer rt.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 10), try block_spec.resolveBlockNumber(&rt, makeSpec("pending")));
}

test "resolveBlockNumber: earliest returns 0" {
    var rt = try makeRuntime();
    defer rt.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 0), try block_spec.resolveBlockNumber(&rt, makeSpec("earliest")));
}

test "resolveBlockNumber: safe returns head" {
    var rt = try makeRuntime();
    defer rt.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 10), try block_spec.resolveBlockNumber(&rt, makeSpec("safe")));
}

test "resolveBlockNumber: finalized returns head" {
    var rt = try makeRuntime();
    defer rt.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 10), try block_spec.resolveBlockNumber(&rt, makeSpec("finalized")));
}

test "resolveBlockNumber: hex 0x0 returns 0" {
    var rt = try makeRuntime();
    defer rt.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 0), try block_spec.resolveBlockNumber(&rt, makeSpec("0x0")));
}

test "resolveBlockNumber: hex 0x1 returns 1" {
    var rt = try makeRuntime();
    defer rt.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1), try block_spec.resolveBlockNumber(&rt, makeSpec("0x1")));
}

test "resolveBlockNumber: hex 0xa returns 10" {
    var rt = try makeRuntime();
    defer rt.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 10), try block_spec.resolveBlockNumber(&rt, makeSpec("0xa")));
}

test "resolveBlockNumber: hex beyond head returns BlockOutOfRange" {
    var rt = try makeRuntime();
    defer rt.deinit(std.testing.allocator);
    try std.testing.expectError(error.BlockOutOfRange, block_spec.resolveBlockNumber(&rt, makeSpec("0xff")));
}

test "resolveBlockNumber: invalid string returns InvalidBlockSpec" {
    var rt = try makeRuntime();
    defer rt.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidBlockSpec, block_spec.resolveBlockNumber(&rt, makeSpec("garbage")));
}

test "resolveBlockNumber: malformed hex returns InvalidBlockSpec" {
    var rt = try makeRuntime();
    defer rt.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidBlockSpec, block_spec.resolveBlockNumber(&rt, makeSpec("0xZZZ")));
}
