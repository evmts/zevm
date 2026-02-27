const std = @import("std");
const jsonrpc = @import("jsonrpc");
const state_manager = @import("state-manager");
const blockchain = @import("blockchain");
const envelope = @import("envelope.zig");
const handlers = @import("handlers.zig");
const router = @import("router.zig");

var dispatch_called = false;
var dispatch_method: []const u8 = "";
var dispatch_saw_string_param = false;
var dispatch_saw_string_id = false;

fn getObjectField(value: std.json.Value, key: []const u8) !std.json.Value {
    return switch (value) {
        .object => |object| object.get(key) orelse error.MissingField,
        else => error.InvalidJsonType,
    };
}

fn parseResponse(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
    });
}

fn testDispatch(
    allocator: std.mem.Allocator,
    context: *const handlers.HandlerContext,
    method_name: []const u8,
    params: ?std.json.Value,
    id: ?envelope.Id,
) !handlers.HandlerResult {
    _ = allocator;
    _ = context;

    dispatch_called = true;
    dispatch_method = method_name;

    if (params) |value| {
        switch (value) {
            .string => |text| {
                dispatch_saw_string_param = std.mem.eql(u8, text, "payload");
            },
            else => {
                dispatch_saw_string_param = false;
            },
        }
    }

    if (id) |actual_id| {
        switch (actual_id) {
            .string => |text| {
                dispatch_saw_string_id = std.mem.eql(u8, text, "request-id");
            },
            else => {
                dispatch_saw_string_id = false;
            },
        }
    }

    return handlers.HandlerResult{ .success = std.json.Value{ .string = "handled" } };
}

test "router has access to voltaire fromMethodName helpers" {
    try std.testing.expectEqual(
        std.meta.Tag(jsonrpc.eth.EthMethod).eth_chainId,
        try jsonrpc.eth.EthMethod.fromMethodName("eth_chainId"),
    );
    try std.testing.expectEqual(
        std.meta.Tag(jsonrpc.debug.DebugMethod).debug_getBadBlocks,
        try jsonrpc.debug.DebugMethod.fromMethodName("debug_getBadBlocks"),
    );
    try std.testing.expectEqual(
        std.meta.Tag(jsonrpc.engine.EngineMethod).engine_exchangeCapabilities,
        try jsonrpc.engine.EngineMethod.fromMethodName("engine_exchangeCapabilities"),
    );
}

test "route returns method-not-found for unknown method" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var chain = try blockchain.Blockchain.init(std.testing.allocator, null);
    defer chain.deinit();

    const context = handlers.HandlerContext{
        .state_manager = &sm,
        .blockchain = &chain,
        .chain_id = 1,
    };

    const response = try router.route(std.testing.allocator, &context, .{
        .id = envelope.Id{ .number = 42 },
        .method = "eth_unknownMethod",
        .params = null,
    });
    defer std.testing.allocator.free(response);

    const parsed = try parseResponse(std.testing.allocator, response);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 42), (try getObjectField(parsed.value, "id")).integer);
    const error_object = try getObjectField(parsed.value, "error");
    try std.testing.expectEqual(@as(i64, -32601), (try getObjectField(error_object, "code")).integer);
}

test "route recognizes eth/debug/engine methods and delegates to handlers" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var chain = try blockchain.Blockchain.init(std.testing.allocator, null);
    defer chain.deinit();

    const context = handlers.HandlerContext{
        .state_manager = &sm,
        .blockchain = &chain,
        .chain_id = 1,
    };

    handlers.setTestDispatchHook(testDispatch);
    defer handlers.clearTestDispatchHook();

    dispatch_called = false;
    const eth_response = try router.route(std.testing.allocator, &context, .{
        .id = envelope.Id{ .number = 1 },
        .method = "eth_chainId",
        .params = null,
    });
    defer std.testing.allocator.free(eth_response);
    try std.testing.expect(dispatch_called);

    dispatch_called = false;
    const debug_response = try router.route(std.testing.allocator, &context, .{
        .id = envelope.Id{ .number = 2 },
        .method = "debug_getBadBlocks",
        .params = null,
    });
    defer std.testing.allocator.free(debug_response);
    try std.testing.expect(dispatch_called);

    dispatch_called = false;
    const engine_response = try router.route(std.testing.allocator, &context, .{
        .id = envelope.Id{ .number = 3 },
        .method = "engine_exchangeCapabilities",
        .params = null,
    });
    defer std.testing.allocator.free(engine_response);
    try std.testing.expect(dispatch_called);
}

test "route passes method params and id into handler adapter" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var chain = try blockchain.Blockchain.init(std.testing.allocator, null);
    defer chain.deinit();

    const context = handlers.HandlerContext{
        .state_manager = &sm,
        .blockchain = &chain,
        .chain_id = 1,
    };

    handlers.setTestDispatchHook(testDispatch);
    defer handlers.clearTestDispatchHook();

    dispatch_called = false;
    dispatch_method = "";
    dispatch_saw_string_param = false;
    dispatch_saw_string_id = false;

    const response = try router.route(std.testing.allocator, &context, .{
        .id = envelope.Id{ .string = "request-id" },
        .method = "eth_chainId",
        .params = std.json.Value{ .string = "payload" },
    });
    defer std.testing.allocator.free(response);

    try std.testing.expect(dispatch_called);
    try std.testing.expectEqualStrings("eth_chainId", dispatch_method);
    try std.testing.expect(dispatch_saw_string_param);
    try std.testing.expect(dispatch_saw_string_id);

    const parsed = try parseResponse(std.testing.allocator, response);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("handled", (try getObjectField(parsed.value, "result")).string);
}

test "routeBatch preserves order and returns per-request errors" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var chain = try blockchain.Blockchain.init(std.testing.allocator, null);
    defer chain.deinit();

    const context = handlers.HandlerContext{
        .state_manager = &sm,
        .blockchain = &chain,
        .chain_id = 1,
    };

    const requests = [_]envelope.Request{
        .{
            .id = envelope.Id{ .number = 1 },
            .method = "eth_chainId",
            .params = null,
        },
        .{
            .id = null,
            .method = "",
            .params = null,
        },
        .{
            .id = envelope.Id{ .number = 3 },
            .method = "eth_unknownMethod",
            .params = null,
        },
    };

    const response = try router.routeBatch(std.testing.allocator, &context, &requests);
    defer std.testing.allocator.free(response);

    const parsed = try parseResponse(std.testing.allocator, response);
    defer parsed.deinit();

    const items = switch (parsed.value) {
        .array => |array| array.items,
        else => return error.ExpectedArrayResponse,
    };

    try std.testing.expectEqual(@as(usize, 3), items.len);

    const first_error = try getObjectField(items[0], "error");
    try std.testing.expectEqual(@as(i64, -32601), (try getObjectField(first_error, "code")).integer);

    const second_error = try getObjectField(items[1], "error");
    try std.testing.expectEqual(@as(i64, -32600), (try getObjectField(second_error, "code")).integer);

    const third_error = try getObjectField(items[2], "error");
    try std.testing.expectEqual(@as(i64, -32601), (try getObjectField(third_error, "code")).integer);
}
