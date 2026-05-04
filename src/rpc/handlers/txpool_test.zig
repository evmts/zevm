const std = @import("std");
const jsonrpc = @import("jsonrpc");
const primitives = @import("primitives");
const dispatcher = @import("../dispatcher.zig");
const dispatch_wiring = @import("../dispatch_wiring.zig");
const runtime = @import("../../node/runtime.zig");
const txpool = @import("txpool.zig");

fn makeRuntime() !runtime.NodeRuntime {
    return runtime.NodeRuntime.init(std.testing.allocator, null);
}

fn makeHash(byte: u8) [32]u8 {
    return [_]u8{byte} ** 32;
}

fn makeRequest(method: []const u8, params: ?std.json.Value) !jsonrpc.envelope.RequestEnvelope {
    return .{
        .jsonrpc = try std.testing.allocator.dupe(u8, "2.0"),
        .id = .{ .integer = 1 },
        .method = try std.testing.allocator.dupe(u8, method),
        .params = params,
    };
}

fn expectObject(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.ExpectedObject,
    };
}

fn field(obj: std.json.ObjectMap, key: []const u8) !std.json.Value {
    return obj.get(key) orelse error.MissingField;
}

test "txpool_status reports pending and queued counts" {
    var rt = try makeRuntime();
    defer rt.deinit();

    const sender = runtime.DEFAULT_DEV_ACCOUNTS[0];
    try rt.pool.setNonce(sender, 0);
    try rt.pool.add(std.testing.allocator, .{
        .sender = sender,
        .nonce = 0,
        .gas_limit = 21_000,
        .max_fee_per_gas = 1_000_000_000,
        .hash = makeHash(0x11),
    });
    try rt.pool.add(std.testing.allocator, .{
        .sender = sender,
        .nonce = 2,
        .gas_limit = 21_000,
        .max_fee_per_gas = 1_000_000_000,
        .hash = makeHash(0x22),
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try txpool.handleStatus(arena.allocator(), &rt, null);
    const obj = try expectObject(result);

    try std.testing.expectEqualStrings("0x1", (try field(obj, "pending")).string);
    try std.testing.expectEqualStrings("0x1", (try field(obj, "queued")).string);
}

test "txpool_content groups pending and queued transactions by sender and decimal nonce" {
    var rt = try makeRuntime();
    defer rt.deinit();

    const sender = runtime.DEFAULT_DEV_ACCOUNTS[0];
    const recipient = runtime.DEFAULT_DEV_ACCOUNTS[1];
    try rt.pool.setNonce(sender, 1);
    try rt.pool.add(std.testing.allocator, .{
        .sender = sender,
        .nonce = 1,
        .gas_limit = 21_000,
        .max_fee_per_gas = 1_000_000_000,
        .hash = makeHash(0x11),
        .to = recipient,
        .value = 42,
        .input = &.{ 0xab, 0xcd },
    });
    try rt.pool.add(std.testing.allocator, .{
        .sender = sender,
        .nonce = 3,
        .gas_limit = 30_000,
        .max_fee_per_gas = 2_000_000_000,
        .hash = makeHash(0x22),
        .to = recipient,
        .value = 7,
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try txpool.handleContent(arena.allocator(), &rt, null);
    const root = try expectObject(result);
    const pending = try expectObject(try field(root, "pending"));
    const queued = try expectObject(try field(root, "queued"));
    const account_key = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";

    const pending_account = try expectObject(try field(pending, account_key));
    const queued_account = try expectObject(try field(queued, account_key));
    const pending_tx = try expectObject(try field(pending_account, "1"));
    _ = try field(queued_account, "3");

    try std.testing.expectEqualStrings("0x1", (try field(pending_tx, "nonce")).string);
    try std.testing.expectEqualStrings("0x5208", (try field(pending_tx, "gas")).string);
    try std.testing.expectEqualStrings("0x3b9aca00", (try field(pending_tx, "gasPrice")).string);
    try std.testing.expectEqualStrings("0x2a", (try field(pending_tx, "value")).string);
    try std.testing.expectEqualStrings("0xabcd", (try field(pending_tx, "input")).string);
    try std.testing.expectEqualStrings("0x1111111111111111111111111111111111111111111111111111111111111111", (try field(pending_tx, "hash")).string);
    try std.testing.expectEqual(.null, try field(pending_tx, "blockHash"));
    try std.testing.expectEqual(.null, try field(pending_tx, "transactionIndex"));
}

test "txpool_inspect returns geth-style summaries" {
    var rt = try makeRuntime();
    defer rt.deinit();

    const sender = runtime.DEFAULT_DEV_ACCOUNTS[0];
    const recipient = runtime.DEFAULT_DEV_ACCOUNTS[1];
    try rt.pool.setNonce(sender, 0);
    try rt.pool.add(std.testing.allocator, .{
        .sender = sender,
        .nonce = 0,
        .gas_limit = 21_000,
        .max_fee_per_gas = 1_000_000_000,
        .hash = makeHash(0x11),
        .to = recipient,
        .value = 42,
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try txpool.handleInspect(arena.allocator(), &rt, null);
    const root = try expectObject(result);
    const pending = try expectObject(try field(root, "pending"));
    const account = try expectObject(try field(pending, "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"));

    try std.testing.expectEqualStrings(
        "0x70997970C51812dc3A010C7d01b50e0d17dc79C8: 42 wei + 21000 gas x 1000000000 wei",
        (try field(account, "0")).string,
    );
}

test "txpool handlers reject non-empty params" {
    var rt = try makeRuntime();
    defer rt.deinit();

    var params = std.json.Array.init(std.testing.allocator);
    defer params.deinit();
    try params.append(.{ .bool = true });

    try std.testing.expectError(
        error.InvalidParams,
        txpool.handleStatus(std.testing.allocator, &rt, .{ .array = params }),
    );
}

test "dispatch wiring reaches txpool_status" {
    var rt = try makeRuntime();
    defer rt.deinit();

    try rt.pool.setNonce(runtime.DEFAULT_DEV_ACCOUNTS[0], 0);
    try rt.pool.add(std.testing.allocator, .{
        .sender = runtime.DEFAULT_DEV_ACCOUNTS[0],
        .nonce = 0,
        .gas_limit = 21_000,
        .max_fee_per_gas = 1,
        .hash = makeHash(0x33),
    });

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    var request = try makeRequest("txpool_status", null);
    defer request.deinit(std.testing.allocator);

    var response = try dispatcher.dispatch(std.testing.allocator, request, &handlers);
    defer response.deinit(std.testing.allocator);

    try std.testing.expect(response.error_value == null);
    const result = try expectObject(response.result.?);
    try std.testing.expectEqualStrings("0x1", (try field(result, "pending")).string);
    try std.testing.expectEqualStrings("0x0", (try field(result, "queued")).string);
}
