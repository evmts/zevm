const std = @import("std");
const jsonrpc = @import("jsonrpc");
const dispatcher = @import("dispatcher.zig");
const server = @import("server.zig");

fn getObjectField(value: std.json.Value, key: []const u8) !std.json.Value {
    return switch (value) {
        .object => |object| object.get(key) orelse error.MissingField,
        else => error.InvalidJsonType,
    };
}

fn parseJson(body: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{
        .allocate = .alloc_always,
    });
}

fn successHandler(allocator: std.mem.Allocator, method_name: []const u8, params: ?std.json.Value) anyerror!std.json.Value {
    _ = allocator;
    _ = params;

    if (std.mem.eql(u8, method_name, "eth_blockNumber")) {
        return .{ .integer = 7 };
    }

    return error.UnexpectedMethod;
}

test "POST single request returns HTTP 200 + JSON-RPC envelope" {
    const handlers = dispatcher.HandlerRegistry{
        .on_method = &successHandler,
    };

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_blockNumber\"}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    try std.testing.expectEqualStrings("application/json", response.content_type.?);

    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 7), (try getObjectField(parsed.value, "result")).integer);
}

test "batch request returns per-item result/error array" {
    const handlers = dispatcher.HandlerRegistry{
        .on_method = &successHandler,
    };

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_blockNumber\"},{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"unknown_method\"}]",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, response.status);

    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();

    const items = switch (parsed.value) {
        .array => |array| array.items,
        else => return error.ExpectedArray,
    };
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqual(@as(i64, 7), (try getObjectField(items[0], "result")).integer);

    const error_object = try getObjectField(items[1], "error");
    try std.testing.expectEqual(@as(i64, jsonrpc.envelope.ErrorCode.METHOD_NOT_FOUND), (try getObjectField(error_object, "code")).integer);
}

test "malformed JSON returns -32700" {
    const handlers = dispatcher.HandlerRegistry{};

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();

    const error_object = try getObjectField(parsed.value, "error");
    try std.testing.expectEqual(@as(i64, jsonrpc.envelope.ErrorCode.PARSE_ERROR), (try getObjectField(error_object, "code")).integer);
}

test "invalid request object returns -32600" {
    const handlers = dispatcher.HandlerRegistry{};

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"id\":1}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();

    const error_object = try getObjectField(parsed.value, "error");
    try std.testing.expectEqual(@as(i64, jsonrpc.envelope.ErrorCode.INVALID_REQUEST), (try getObjectField(error_object, "code")).integer);
}

test "unknown method returns -32601" {
    const handlers = dispatcher.HandlerRegistry{};

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"unknown_method\"}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();

    const error_object = try getObjectField(parsed.value, "error");
    try std.testing.expectEqual(@as(i64, jsonrpc.envelope.ErrorCode.METHOD_NOT_FOUND), (try getObjectField(error_object, "code")).integer);
}

test "invalid params returns -32602" {
    const handlers = dispatcher.HandlerRegistry{};

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getBalance\",\"params\":[]}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();

    const error_object = try getObjectField(parsed.value, "error");
    try std.testing.expectEqual(@as(i64, jsonrpc.envelope.ErrorCode.INVALID_PARAMS), (try getObjectField(error_object, "code")).integer);
}

test "content-type is application/json for JSON-RPC responses" {
    const handlers = dispatcher.HandlerRegistry{};

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"unknown_method\"}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    try std.testing.expectEqualStrings("application/json", response.content_type.?);
}

test "non-root request target returns 404 without JSON-RPC body" {
    const handlers = dispatcher.HandlerRegistry{};

    var response = try server.handleHttpRequestForTestWithOptions(
        std.testing.allocator,
        .{
            .method = .POST,
            .target = "/rpc",
            .body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_blockNumber\"}",
        },
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.not_found, response.status);
    try std.testing.expect(response.body == null);
    try std.testing.expect(response.content_type == null);
}

test "non-POST request returns 405" {
    const handlers = dispatcher.HandlerRegistry{};

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .GET,
        "",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.method_not_allowed, response.status);
    try std.testing.expect(response.body == null);
    try std.testing.expect(response.content_type == null);
}

test "missing or invalid content-type returns 415 without JSON-RPC body" {
    const handlers = dispatcher.HandlerRegistry{};

    {
        var response = try server.handleHttpRequestForTestWithOptions(
            std.testing.allocator,
            .{
                .method = .POST,
                .content_type = null,
                .body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_blockNumber\"}",
            },
            &handlers,
        );
        defer response.deinit(std.testing.allocator);

        try std.testing.expectEqual(std.http.Status.unsupported_media_type, response.status);
        try std.testing.expect(response.body == null);
        try std.testing.expect(response.content_type == null);
    }

    {
        var response = try server.handleHttpRequestForTestWithOptions(
            std.testing.allocator,
            .{
                .method = .POST,
                .content_type = "text/plain",
                .body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_blockNumber\"}",
            },
            &handlers,
        );
        defer response.deinit(std.testing.allocator);

        try std.testing.expectEqual(std.http.Status.unsupported_media_type, response.status);
        try std.testing.expect(response.body == null);
        try std.testing.expect(response.content_type == null);
    }
}

test "application/json content-type allows media-type parameters" {
    const handlers = dispatcher.HandlerRegistry{
        .on_method = &successHandler,
    };

    var response = try server.handleHttpRequestForTestWithOptions(
        std.testing.allocator,
        .{
            .method = .POST,
            .content_type = "application/json; charset=utf-8",
            .body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_blockNumber\"}",
        },
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    try std.testing.expectEqualStrings("application/json", response.content_type.?);

    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 7), (try getObjectField(parsed.value, "result")).integer);
}

test "single notification returns 204 empty response" {
    const handlers = dispatcher.HandlerRegistry{
        .on_method = &successHandler,
    };

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\"}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.no_content, response.status);
    try std.testing.expect(response.body == null);
    try std.testing.expect(response.content_type == null);
}

test "notification-only batch returns 204 empty response" {
    const handlers = dispatcher.HandlerRegistry{
        .on_method = &successHandler,
    };

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "[{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\"},{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\"}]",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.no_content, response.status);
    try std.testing.expect(response.body == null);
    try std.testing.expect(response.content_type == null);
}

test "mixed batch omits notifications and preserves response order" {
    const handlers = dispatcher.HandlerRegistry{
        .on_method = &successHandler,
    };

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "[{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\"},{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"eth_blockNumber\"},{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\"},{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"eth_blockNumber\"}]",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    try std.testing.expectEqualStrings("application/json", response.content_type.?);

    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();

    const items = switch (parsed.value) {
        .array => |array| array.items,
        else => return error.ExpectedArray,
    };
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqual(@as(i64, 2), (try getObjectField(items[0], "id")).integer);
    try std.testing.expectEqual(@as(i64, 7), (try getObjectField(items[0], "result")).integer);
    try std.testing.expectEqual(@as(i64, 3), (try getObjectField(items[1], "id")).integer);
    try std.testing.expectEqual(@as(i64, 7), (try getObjectField(items[1], "result")).integer);
}

test "id null is not treated as a notification" {
    const handlers = dispatcher.HandlerRegistry{
        .on_method = &successHandler,
    };

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"eth_blockNumber\"}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, response.status);

    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();

    try std.testing.expect((try getObjectField(parsed.value, "id")) == .null);
}
