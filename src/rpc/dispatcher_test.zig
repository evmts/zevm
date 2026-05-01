const std = @import("std");
const jsonrpc = @import("jsonrpc");
const dispatcher = @import("dispatcher.zig");
const envelope = @import("envelope.zig");

fn failingMethodHandler(allocator: std.mem.Allocator, method_name: []const u8, params: ?std.json.Value) anyerror!std.json.Value {
    _ = allocator;
    _ = method_name;
    _ = params;
    return error.HandlerFailed;
}

fn makeRequest(method: []const u8, params: ?std.json.Value) envelope.Request {
    return .{
        .id = .{ .number = 1 },
        .method = method,
        .params = params,
    };
}

test "zevm imports voltaire method modules" {
    try std.testing.expect(@hasDecl(jsonrpc, "eth"));
    try std.testing.expect(@hasDecl(jsonrpc, "debug"));
    try std.testing.expect(@hasDecl(jsonrpc, "engine"));
}

test "dispatch unknown method returns -32601" {
    const handlers = dispatcher.HandlerRegistry{};
    var response = try dispatcher.dispatch(std.testing.allocator, makeRequest("no_such_method", null), &handlers);
    defer response.deinit(std.testing.allocator);

    try std.testing.expect(response.error_value != null);
    try std.testing.expectEqual(@as(i32, dispatcher.ErrorCode.METHOD_NOT_FOUND), response.error_value.?.code);
}

test "dispatch recognized eth/debug/engine method with no handler returns -32601" {
    const handlers = dispatcher.HandlerRegistry{};

    {
        var response = try dispatcher.dispatch(std.testing.allocator, makeRequest("eth_blockNumber", null), &handlers);
        defer response.deinit(std.testing.allocator);

        try std.testing.expect(response.error_value != null);
        try std.testing.expectEqual(@as(i32, dispatcher.ErrorCode.METHOD_NOT_FOUND), response.error_value.?.code);
    }

    {
        var response = try dispatcher.dispatch(std.testing.allocator, makeRequest("debug_getBadBlocks", null), &handlers);
        defer response.deinit(std.testing.allocator);

        try std.testing.expect(response.error_value != null);
        try std.testing.expectEqual(@as(i32, dispatcher.ErrorCode.METHOD_NOT_FOUND), response.error_value.?.code);
    }

    {
        var params_array = std.json.Array.init(std.testing.allocator);
        defer params_array.deinit();
        try params_array.append(.null);

        var response = try dispatcher.dispatch(
            std.testing.allocator,
            makeRequest("engine_exchangeCapabilities", .{ .array = params_array }),
            &handlers,
        );
        defer response.deinit(std.testing.allocator);

        try std.testing.expect(response.error_value != null);
        try std.testing.expectEqual(@as(i32, dispatcher.ErrorCode.METHOD_NOT_FOUND), response.error_value.?.code);
    }

    {
        var response = try dispatcher.dispatch(std.testing.allocator, makeRequest("zevm_reset", null), &handlers);
        defer response.deinit(std.testing.allocator);

        try std.testing.expect(response.error_value != null);
        try std.testing.expectEqual(@as(i32, dispatcher.ErrorCode.METHOD_NOT_FOUND), response.error_value.?.code);
    }
}

test "dispatch invalid params shape returns -32602" {
    const handlers = dispatcher.HandlerRegistry{};

    var params_array = std.json.Array.init(std.testing.allocator);
    defer params_array.deinit();

    var response = try dispatcher.dispatch(
        std.testing.allocator,
        makeRequest("eth_getBalance", .{ .array = params_array }),
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expect(response.error_value != null);
    try std.testing.expectEqual(@as(i32, dispatcher.ErrorCode.INVALID_PARAMS), response.error_value.?.code);
}

test "dispatch validates zevm_setRpcUrl params" {
    const handlers = dispatcher.HandlerRegistry{};

    var params_array = std.json.Array.init(std.testing.allocator);
    defer params_array.deinit();

    var response = try dispatcher.dispatch(
        std.testing.allocator,
        makeRequest("zevm_setRpcUrl", .{ .array = params_array }),
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expect(response.error_value != null);
    try std.testing.expectEqual(@as(i32, dispatcher.ErrorCode.INVALID_PARAMS), response.error_value.?.code);
}

test "dispatch handler failure maps to -32603" {
    const handlers = dispatcher.HandlerRegistry{
        .on_method = &failingMethodHandler,
    };

    var response = try dispatcher.dispatch(std.testing.allocator, makeRequest("eth_blockNumber", null), &handlers);
    defer response.deinit(std.testing.allocator);

    try std.testing.expect(response.error_value != null);
    try std.testing.expectEqual(@as(i32, dispatcher.ErrorCode.INTERNAL_ERROR), response.error_value.?.code);
}

test "dispatch preserves integer|string|null id in error responses" {
    const handlers = dispatcher.HandlerRegistry{};

    {
        var response = try dispatcher.dispatch(
            std.testing.allocator,
            .{
                .id = .{ .number = 100 },
                .method = "unknown",
                .params = null,
            },
            &handlers,
        );
        defer response.deinit(std.testing.allocator);

        try std.testing.expect(response.id != null);
        try std.testing.expect(response.id.? == .number);
        try std.testing.expectEqual(@as(i64, 100), response.id.?.number);
    }

    {
        var response = try dispatcher.dispatch(
            std.testing.allocator,
            .{
                .id = .{ .string = "req-abc" },
                .method = "unknown",
                .params = null,
            },
            &handlers,
        );
        defer response.deinit(std.testing.allocator);

        try std.testing.expect(response.id != null);
        try std.testing.expect(response.id.? == .string);
        try std.testing.expectEqualStrings("req-abc", response.id.?.string);
    }

    {
        var response = try dispatcher.dispatch(
            std.testing.allocator,
            .{
                .id = .{ .null_value = {} },
                .method = "unknown",
                .params = null,
            },
            &handlers,
        );
        defer response.deinit(std.testing.allocator);

        try std.testing.expect(response.id != null);
        try std.testing.expect(response.id.? == .null_value);
    }
}

test "dispatch marks invalid_request as -32600" {
    const handlers = dispatcher.HandlerRegistry{};

    var response = try dispatcher.dispatch(
        std.testing.allocator,
        .{
            .id = null,
            .method = "",
            .params = null,
            .invalid_request = true,
        },
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expect(response.error_value != null);
    try std.testing.expectEqual(@as(i32, dispatcher.ErrorCode.INVALID_REQUEST), response.error_value.?.code);
}
