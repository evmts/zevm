const std = @import("std");
const jsonrpc = @import("jsonrpc");
const rpc_server = @import("rpc_server.zig");

comptime {
    _ = jsonrpc;
}

fn parseResponse(response_bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, response_bytes, .{
        .allocate = .alloc_always,
    });
}

fn getObject(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.InvalidJsonType,
    };
}

fn getArray(value: std.json.Value) ![]const std.json.Value {
    return switch (value) {
        .array => |array| array.items,
        else => error.InvalidJsonType,
    };
}

fn getField(object: std.json.ObjectMap, key: []const u8) !std.json.Value {
    return object.get(key) orelse error.MissingJsonField;
}

fn getErrorCode(response_object: std.json.ObjectMap) !i64 {
    const error_object = try getObject(try getField(response_object, "error"));
    return switch (try getField(error_object, "code")) {
        .integer => |value| value,
        else => error.InvalidJsonType,
    };
}

test "handleJsonRpc: malformed JSON returns -32700 with null id" {
    const response_bytes = try rpc_server.handleJsonRpc(std.testing.allocator, "{");
    defer std.testing.allocator.free(response_bytes);

    const parsed = try parseResponse(response_bytes);
    defer parsed.deinit();

    const response_object = try getObject(parsed.value);

    try std.testing.expectEqualStrings("2.0", switch (try getField(response_object, "jsonrpc")) {
        .string => |value| value,
        else => return error.InvalidJsonType,
    });
    try std.testing.expect((try getField(response_object, "id")) == .null);
    try std.testing.expectEqual(@as(i64, -32700), try getErrorCode(response_object));

    const error_object = switch (try getField(response_object, "error")) {
        .object => |object| object,
        else => return error.InvalidJsonType,
    };
    try std.testing.expectEqualStrings("Parse error", switch (try getField(error_object, "message")) {
        .string => |value| value,
        else => return error.InvalidJsonType,
    });
}

test "handleJsonRpc: top-level scalar returns -32600" {
    const response_bytes = try rpc_server.handleJsonRpc(std.testing.allocator, "true");
    defer std.testing.allocator.free(response_bytes);

    const parsed = try parseResponse(response_bytes);
    defer parsed.deinit();

    const response_object = try getObject(parsed.value);
    try std.testing.expect((try getField(response_object, "id")) == .null);
    try std.testing.expectEqual(@as(i64, -32600), try getErrorCode(response_object));
    try std.testing.expectEqualStrings("Invalid request", switch (try getField(try getObject(try getField(response_object, "error")), "message")) {
        .string => |value| value,
        else => return error.InvalidJsonType,
    });
}

test "handleJsonRpc: object missing method returns -32600" {
    const response_bytes = try rpc_server.handleJsonRpc(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1}");
    defer std.testing.allocator.free(response_bytes);

    const parsed = try parseResponse(response_bytes);
    defer parsed.deinit();

    const response_object = try getObject(parsed.value);
    try std.testing.expectEqual(@as(i64, 1), switch (try getField(response_object, "id")) {
        .integer => |value| value,
        else => return error.InvalidJsonType,
    });
    try std.testing.expectEqual(@as(i64, -32600), try getErrorCode(response_object));
}

test "handleJsonRpc: jsonrpc != 2.0 returns -32600" {
    const response_bytes = try rpc_server.handleJsonRpc(std.testing.allocator, "{\"jsonrpc\":\"1.0\",\"id\":2,\"method\":\"eth_chainId\"}");
    defer std.testing.allocator.free(response_bytes);

    const parsed = try parseResponse(response_bytes);
    defer parsed.deinit();

    const response_object = try getObject(parsed.value);
    try std.testing.expectEqual(@as(i64, 2), switch (try getField(response_object, "id")) {
        .integer => |value| value,
        else => return error.InvalidJsonType,
    });
    try std.testing.expectEqual(@as(i64, -32600), try getErrorCode(response_object));
}

test "handleJsonRpc: unknown method returns -32601" {
    const response_bytes = try rpc_server.handleJsonRpc(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"zevm_unknown\"}");
    defer std.testing.allocator.free(response_bytes);

    const parsed = try parseResponse(response_bytes);
    defer parsed.deinit();

    const response_object = try getObject(parsed.value);
    try std.testing.expectEqual(@as(i64, -32601), try getErrorCode(response_object));
}

test "handleJsonRpc: known eth/debug/engine method still returns -32601 stub" {
    const response_bytes = try rpc_server.handleJsonRpc(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"eth_chainId\"}");
    defer std.testing.allocator.free(response_bytes);

    const parsed = try parseResponse(response_bytes);
    defer parsed.deinit();

    const response_object = try getObject(parsed.value);
    try std.testing.expectEqual(@as(i64, 4), switch (try getField(response_object, "id")) {
        .integer => |value| value,
        else => return error.InvalidJsonType,
    });
    try std.testing.expectEqual(@as(i64, -32601), try getErrorCode(response_object));
}

test "handleJsonRpc: empty batch returns single -32600 error object" {
    const response_bytes = try rpc_server.handleJsonRpc(std.testing.allocator, "[]");
    defer std.testing.allocator.free(response_bytes);

    const parsed = try parseResponse(response_bytes);
    defer parsed.deinit();

    const response_object = try getObject(parsed.value);
    try std.testing.expect((try getField(response_object, "id")) == .null);
    try std.testing.expectEqual(@as(i64, -32600), try getErrorCode(response_object));
}

test "handleJsonRpc: batch of two valid requests returns two responses" {
    const response_bytes = try rpc_server.handleJsonRpc(std.testing.allocator, "[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_chainId\"},{\"jsonrpc\":\"2.0\",\"id\":\"a\",\"method\":\"eth_chainId\"}]");
    defer std.testing.allocator.free(response_bytes);

    const parsed = try parseResponse(response_bytes);
    defer parsed.deinit();

    const responses = try getArray(parsed.value);
    try std.testing.expectEqual(@as(usize, 2), responses.len);

    const first = try getObject(responses[0]);
    const second = try getObject(responses[1]);

    try std.testing.expectEqual(@as(i64, 1), switch (try getField(first, "id")) {
        .integer => |value| value,
        else => return error.InvalidJsonType,
    });
    try std.testing.expectEqualStrings("a", switch (try getField(second, "id")) {
        .string => |value| value,
        else => return error.InvalidJsonType,
    });
}

test "handleJsonRpc: batch with mixed valid and invalid entries returns mixed responses" {
    const response_bytes = try rpc_server.handleJsonRpc(std.testing.allocator, "[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_chainId\"},{\"jsonrpc\":\"2.0\",\"id\":2},{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"zevm_unknown\"},true]");
    defer std.testing.allocator.free(response_bytes);

    const parsed = try parseResponse(response_bytes);
    defer parsed.deinit();

    const responses = try getArray(parsed.value);
    try std.testing.expectEqual(@as(usize, 4), responses.len);
    try std.testing.expectEqual(@as(i64, -32601), try getErrorCode(try getObject(responses[0])));
    try std.testing.expectEqual(@as(i64, -32600), try getErrorCode(try getObject(responses[1])));
    try std.testing.expectEqual(@as(i64, -32601), try getErrorCode(try getObject(responses[2])));
    try std.testing.expectEqual(@as(i64, -32600), try getErrorCode(try getObject(responses[3])));
    try std.testing.expect((try getField(try getObject(responses[3]), "id")) == .null);
}

test "handleJsonRpc: preserves numeric, string, and null id" {
    const response_bytes = try rpc_server.handleJsonRpc(std.testing.allocator, "[{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"eth_chainId\"},{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"method\":\"eth_chainId\"},{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"eth_chainId\"}]");
    defer std.testing.allocator.free(response_bytes);

    const parsed = try parseResponse(response_bytes);
    defer parsed.deinit();

    const responses = try getArray(parsed.value);
    try std.testing.expectEqual(@as(i64, 5), switch (try getField(try getObject(responses[0]), "id")) {
        .integer => |value| value,
        else => return error.InvalidJsonType,
    });
    try std.testing.expectEqualStrings("abc", switch (try getField(try getObject(responses[1]), "id")) {
        .string => |value| value,
        else => return error.InvalidJsonType,
    });
    try std.testing.expect((try getField(try getObject(responses[2]), "id")) == .null);
}

test "handleJsonRpc: invalid id type is treated as null" {
    const response_bytes = try rpc_server.handleJsonRpc(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":{\"bad\":1}}");
    defer std.testing.allocator.free(response_bytes);

    const parsed = try parseResponse(response_bytes);
    defer parsed.deinit();

    const response_object = try getObject(parsed.value);
    try std.testing.expect((try getField(response_object, "id")) == .null);
    try std.testing.expectEqual(@as(i64, -32600), try getErrorCode(response_object));
}
