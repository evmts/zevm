const std = @import("std");
const jsonrpc = @import("jsonrpc");
const dispatcher = @import("dispatcher.zig");

fn failingMethodHandler(allocator: std.mem.Allocator, method_name: []const u8, params: ?std.json.Value) anyerror!std.json.Value {
    _ = allocator;
    _ = method_name;
    _ = params;
    return error.HandlerFailed;
}

test "zevm imports voltaire jsonrpc module" {
    try std.testing.expect(@hasDecl(jsonrpc, "eth"));
    try std.testing.expect(@hasDecl(jsonrpc, "debug"));
    try std.testing.expect(@hasDecl(jsonrpc, "engine"));
    try std.testing.expect(@hasDecl(jsonrpc, "envelope"));
}

test "dispatch unknown method returns -32601" {
    var request = jsonrpc.envelope.RequestEnvelope{
        .jsonrpc = try std.testing.allocator.dupe(u8, "2.0"),
        .id = .{ .integer = 1 },
        .method = try std.testing.allocator.dupe(u8, "no_such_method"),
        .params = null,
    };
    defer request.deinit(std.testing.allocator);

    const handlers = dispatcher.HandlerRegistry{};
    const response = try dispatcher.dispatch(std.testing.allocator, request, &handlers);

    try std.testing.expect(response.error_value != null);
    try std.testing.expectEqual(@as(i32, jsonrpc.envelope.ErrorCode.METHOD_NOT_FOUND), response.error_value.?.code);
}

test "dispatch recognized eth/debug/engine method with no handler returns -32601" {
    const handlers = dispatcher.HandlerRegistry{};

    {
        var request = jsonrpc.envelope.RequestEnvelope{
            .jsonrpc = try std.testing.allocator.dupe(u8, "2.0"),
            .id = .{ .integer = 11 },
            .method = try std.testing.allocator.dupe(u8, "eth_blockNumber"),
            .params = null,
        };
        defer request.deinit(std.testing.allocator);

        const response = try dispatcher.dispatch(std.testing.allocator, request, &handlers);
        try std.testing.expect(response.error_value != null);
        try std.testing.expectEqual(@as(i32, jsonrpc.envelope.ErrorCode.METHOD_NOT_FOUND), response.error_value.?.code);
    }

    {
        var request = jsonrpc.envelope.RequestEnvelope{
            .jsonrpc = try std.testing.allocator.dupe(u8, "2.0"),
            .id = .{ .integer = 12 },
            .method = try std.testing.allocator.dupe(u8, "debug_getBadBlocks"),
            .params = null,
        };
        defer request.deinit(std.testing.allocator);

        const response = try dispatcher.dispatch(std.testing.allocator, request, &handlers);
        try std.testing.expect(response.error_value != null);
        try std.testing.expectEqual(@as(i32, jsonrpc.envelope.ErrorCode.METHOD_NOT_FOUND), response.error_value.?.code);
    }

    {
        var params_array = std.json.Array.init(std.testing.allocator);
        defer params_array.deinit();
        try params_array.append(.null);

        var request = jsonrpc.envelope.RequestEnvelope{
            .jsonrpc = try std.testing.allocator.dupe(u8, "2.0"),
            .id = .{ .integer = 13 },
            .method = try std.testing.allocator.dupe(u8, "engine_exchangeCapabilities"),
            .params = .{ .array = params_array },
        };
        defer request.deinit(std.testing.allocator);

        const response = try dispatcher.dispatch(std.testing.allocator, request, &handlers);
        try std.testing.expect(response.error_value != null);
        try std.testing.expectEqual(@as(i32, jsonrpc.envelope.ErrorCode.METHOD_NOT_FOUND), response.error_value.?.code);
    }

    {
        var request = jsonrpc.envelope.RequestEnvelope{
            .jsonrpc = try std.testing.allocator.dupe(u8, "2.0"),
            .id = .{ .integer = 14 },
            .method = try std.testing.allocator.dupe(u8, "zevm_reset"),
            .params = null,
        };
        defer request.deinit(std.testing.allocator);

        const response = try dispatcher.dispatch(std.testing.allocator, request, &handlers);
        try std.testing.expect(response.error_value != null);
        try std.testing.expectEqual(@as(i32, jsonrpc.envelope.ErrorCode.METHOD_NOT_FOUND), response.error_value.?.code);
    }
}

test "dispatch invalid params shape returns -32602" {
    const params_array = std.json.Array.init(std.testing.allocator);

    var request = jsonrpc.envelope.RequestEnvelope{
        .jsonrpc = try std.testing.allocator.dupe(u8, "2.0"),
        .id = .{ .integer = 21 },
        .method = try std.testing.allocator.dupe(u8, "eth_getBalance"),
        .params = .{ .array = params_array },
    };
    defer request.deinit(std.testing.allocator);

    const handlers = dispatcher.HandlerRegistry{};
    const response = try dispatcher.dispatch(std.testing.allocator, request, &handlers);

    try std.testing.expect(response.error_value != null);
    try std.testing.expectEqual(@as(i32, jsonrpc.envelope.ErrorCode.INVALID_PARAMS), response.error_value.?.code);
}

test "dispatch validates zevm_setRpcUrl params" {
    var request = jsonrpc.envelope.RequestEnvelope{
        .jsonrpc = try std.testing.allocator.dupe(u8, "2.0"),
        .id = .{ .integer = 22 },
        .method = try std.testing.allocator.dupe(u8, "zevm_setRpcUrl"),
        .params = .{ .array = std.json.Array.init(std.testing.allocator) },
    };
    defer request.deinit(std.testing.allocator);

    const handlers = dispatcher.HandlerRegistry{};
    const response = try dispatcher.dispatch(std.testing.allocator, request, &handlers);
    try std.testing.expect(response.error_value != null);
    try std.testing.expectEqual(@as(i32, jsonrpc.envelope.ErrorCode.INVALID_PARAMS), response.error_value.?.code);
}

test "dispatch handler failure maps to -32603" {
    var request = jsonrpc.envelope.RequestEnvelope{
        .jsonrpc = try std.testing.allocator.dupe(u8, "2.0"),
        .id = .{ .integer = 31 },
        .method = try std.testing.allocator.dupe(u8, "eth_blockNumber"),
        .params = null,
    };
    defer request.deinit(std.testing.allocator);

    const handlers = dispatcher.HandlerRegistry{
        .on_method = &failingMethodHandler,
    };

    const response = try dispatcher.dispatch(std.testing.allocator, request, &handlers);

    try std.testing.expect(response.error_value != null);
    try std.testing.expectEqual(@as(i32, jsonrpc.envelope.ErrorCode.INTERNAL_ERROR), response.error_value.?.code);
}

test "dispatch preserves integer|string|null id in error responses" {
    const handlers = dispatcher.HandlerRegistry{};

    {
        var request = jsonrpc.envelope.RequestEnvelope{
            .jsonrpc = try std.testing.allocator.dupe(u8, "2.0"),
            .id = .{ .integer = 100 },
            .method = try std.testing.allocator.dupe(u8, "unknown"),
            .params = null,
        };
        defer request.deinit(std.testing.allocator);

        const response = try dispatcher.dispatch(std.testing.allocator, request, &handlers);
        try std.testing.expect(response.id != null);
        try std.testing.expect(response.id.? == .integer);
        try std.testing.expectEqual(@as(i64, 100), response.id.?.integer);
    }

    {
        var request = jsonrpc.envelope.RequestEnvelope{
            .jsonrpc = try std.testing.allocator.dupe(u8, "2.0"),
            .id = .{ .string = try std.testing.allocator.dupe(u8, "req-abc") },
            .method = try std.testing.allocator.dupe(u8, "unknown"),
            .params = null,
        };
        defer request.deinit(std.testing.allocator);

        const response = try dispatcher.dispatch(std.testing.allocator, request, &handlers);
        try std.testing.expect(response.id != null);
        try std.testing.expect(response.id.? == .string);
        try std.testing.expectEqualStrings("req-abc", response.id.?.string);
    }

    {
        var request = jsonrpc.envelope.RequestEnvelope{
            .jsonrpc = try std.testing.allocator.dupe(u8, "2.0"),
            .id = .{ .null_value = {} },
            .method = try std.testing.allocator.dupe(u8, "unknown"),
            .params = null,
        };
        defer request.deinit(std.testing.allocator);

        const response = try dispatcher.dispatch(std.testing.allocator, request, &handlers);
        try std.testing.expect(response.id != null);
        try std.testing.expect(response.id.? == .null_value);
    }
}
