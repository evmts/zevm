const std = @import("std");
const jsonrpc = @import("jsonrpc");
const dispatcher = @import("dispatcher.zig");
const server = @import("server.zig");
const node_handler = @import("node_handler.zig");

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

test "single notification returns HTTP 204 with no response body" {
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
}

test "unknown method notification is suppressed (no response body)" {
    const handlers = dispatcher.HandlerRegistry{};

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"method\":\"unknown_method\"}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.no_content, response.status);
    try std.testing.expect(response.body == null);
}

test "batch notifications only returns HTTP 204 with no response body" {
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
}

test "batch mixed notification and request omits notification response" {
    const handlers = dispatcher.HandlerRegistry{
        .on_method = &successHandler,
    };

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "[{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\"},{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_blockNumber\"}]",
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
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqual(@as(i64, 1), (try getObjectField(items[0], "id")).integer);
}

test "mixed batch suppresses unknown notification error and keeps normal response" {
    const handlers = dispatcher.HandlerRegistry{
        .on_method = &successHandler,
    };

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "[{\"jsonrpc\":\"2.0\",\"method\":\"unknown_method\"},{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_blockNumber\"}]",
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
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqual(@as(i64, 1), (try getObjectField(items[0], "id")).integer);
    try std.testing.expectEqual(@as(i64, 7), (try getObjectField(items[0], "result")).integer);
}

test "request with id null still returns JSON-RPC response" {
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
    const id_value = try getObjectField(parsed.value, "id");
    try std.testing.expect(id_value == .null);
    try std.testing.expectEqual(@as(i64, 7), (try getObjectField(parsed.value, "result")).integer);
}

test "request with integral float id succeeds and echoes integer id" {
    const handlers = dispatcher.HandlerRegistry{
        .on_method = &successHandler,
    };

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"id\":7.0,\"method\":\"eth_blockNumber\"}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 7), (try getObjectField(parsed.value, "id")).integer);
    try std.testing.expectEqual(@as(i64, 7), (try getObjectField(parsed.value, "result")).integer);
}

test "request with fractional float id returns invalid request" {
    const handlers = dispatcher.HandlerRegistry{
        .on_method = &successHandler,
    };

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"id\":7.5,\"method\":\"eth_blockNumber\"}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();
    try std.testing.expect((try getObjectField(parsed.value, "id")) == .null);
    const error_object = try getObjectField(parsed.value, "error");
    try std.testing.expectEqual(@as(i64, jsonrpc.envelope.ErrorCode.INVALID_REQUEST), (try getObjectField(error_object, "code")).integer);
}

test "request with out-of-range float id returns invalid request" {
    const handlers = dispatcher.HandlerRegistry{
        .on_method = &successHandler,
    };

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"id\":1e30,\"method\":\"eth_blockNumber\"}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();
    try std.testing.expect((try getObjectField(parsed.value, "id")) == .null);
    const error_object = try getObjectField(parsed.value, "error");
    try std.testing.expectEqual(@as(i64, jsonrpc.envelope.ErrorCode.INVALID_REQUEST), (try getObjectField(error_object, "code")).integer);
}

test "notification executes side effects while suppressing response" {
    var handler = try node_handler.NodeHandler.init(std.testing.allocator, null);
    defer handler.deinit(std.testing.allocator);

    const handlers = dispatcher.HandlerRegistry{
        .context = &handler,
        .on_method_with_context = &node_handler.NodeHandler.onMethod,
    };

    var notification_response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"method\":\"hardhat_mine\",\"params\":[\"0x1\"]}",
        &handlers,
    );
    defer notification_response.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.no_content, notification_response.status);

    var read_response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_blockNumber\",\"params\":[]}",
        &handlers,
    );
    defer read_response.deinit(std.testing.allocator);

    const parsed = try parseJson(read_response.body.?);
    defer parsed.deinit();
    const result = try getObjectField(parsed.value, "result");
    try std.testing.expectEqualStrings("0x1", result.string);
}

test "mixed batch executes notification side effects and returns only request responses" {
    var handler = try node_handler.NodeHandler.init(std.testing.allocator, null);
    defer handler.deinit(std.testing.allocator);

    const handlers = dispatcher.HandlerRegistry{
        .context = &handler,
        .on_method_with_context = &node_handler.NodeHandler.onMethod,
    };

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "[{\"jsonrpc\":\"2.0\",\"method\":\"hardhat_mine\",\"params\":[\"0x1\"]},{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_blockNumber\",\"params\":[]}]",
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
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqual(@as(i64, 1), (try getObjectField(items[0], "id")).integer);
    try std.testing.expectEqualStrings("0x1", (try getObjectField(items[0], "result")).string);
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

test "batch with invalid item returns per-item invalid request error" {
    const handlers = dispatcher.HandlerRegistry{
        .on_method = &successHandler,
    };

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "[123,{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_blockNumber\"}]",
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

    const first_error = try getObjectField(items[0], "error");
    try std.testing.expectEqual(@as(i64, jsonrpc.envelope.ErrorCode.INVALID_REQUEST), (try getObjectField(first_error, "code")).integer);
    try std.testing.expect((try getObjectField(items[0], "id")) == .null);
    try std.testing.expectEqual(@as(i64, 7), (try getObjectField(items[1], "result")).integer);
}

test "batch invalid object with id echoes id in error item" {
    const handlers = dispatcher.HandlerRegistry{
        .on_method = &successHandler,
    };

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "[{\"jsonrpc\":\"1.0\",\"id\":42,\"method\":\"eth_blockNumber\"},{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_blockNumber\"}]",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();
    const items = switch (parsed.value) {
        .array => |array| array.items,
        else => return error.ExpectedArray,
    };
    try std.testing.expectEqual(@as(usize, 2), items.len);

    try std.testing.expectEqual(@as(i64, 42), (try getObjectField(items[0], "id")).integer);
    const first_error = try getObjectField(items[0], "error");
    try std.testing.expectEqual(@as(i64, jsonrpc.envelope.ErrorCode.INVALID_REQUEST), (try getObjectField(first_error, "code")).integer);
    try std.testing.expectEqual(@as(i64, 7), (try getObjectField(items[1], "result")).integer);
}

test "batch invalid object with string id echoes string id in error item" {
    const handlers = dispatcher.HandlerRegistry{
        .on_method = &successHandler,
    };

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "[{\"jsonrpc\":\"1.0\",\"id\":\"bad-req\",\"method\":\"eth_blockNumber\"},{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_blockNumber\"}]",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();
    const items = switch (parsed.value) {
        .array => |array| array.items,
        else => return error.ExpectedArray,
    };
    try std.testing.expectEqual(@as(usize, 2), items.len);

    try std.testing.expectEqualStrings("bad-req", (try getObjectField(items[0], "id")).string);
    const first_error = try getObjectField(items[0], "error");
    try std.testing.expectEqual(@as(i64, jsonrpc.envelope.ErrorCode.INVALID_REQUEST), (try getObjectField(first_error, "code")).integer);
    try std.testing.expectEqual(@as(i64, 7), (try getObjectField(items[1], "result")).integer);
}

test "batch with out-of-range float id item returns invalid request item and keeps valid item" {
    const handlers = dispatcher.HandlerRegistry{
        .on_method = &successHandler,
    };

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "[{\"jsonrpc\":\"2.0\",\"id\":1e30,\"method\":\"eth_blockNumber\"},{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_blockNumber\"}]",
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

    try std.testing.expect((try getObjectField(items[0], "id")) == .null);
    const first_error = try getObjectField(items[0], "error");
    try std.testing.expectEqual(@as(i64, jsonrpc.envelope.ErrorCode.INVALID_REQUEST), (try getObjectField(first_error, "code")).integer);
    try std.testing.expectEqual(@as(i64, 7), (try getObjectField(items[1], "result")).integer);
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

test "invalid request object with id echoes id in error response" {
    const handlers = dispatcher.HandlerRegistry{};

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"1.0\",\"id\":7,\"method\":\"eth_blockNumber\"}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 7), (try getObjectField(parsed.value, "id")).integer);
    const error_object = try getObjectField(parsed.value, "error");
    try std.testing.expectEqual(@as(i64, jsonrpc.envelope.ErrorCode.INVALID_REQUEST), (try getObjectField(error_object, "code")).integer);
}

test "invalid request object with string id echoes string id in error response" {
    const handlers = dispatcher.HandlerRegistry{};

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"1.0\",\"id\":\"abc\",\"method\":\"eth_blockNumber\"}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("abc", (try getObjectField(parsed.value, "id")).string);
    const error_object = try getObjectField(parsed.value, "error");
    try std.testing.expectEqual(@as(i64, jsonrpc.envelope.ErrorCode.INVALID_REQUEST), (try getObjectField(error_object, "code")).integer);
}

test "invalid request object with integral float id echoes integer id in error response" {
    const handlers = dispatcher.HandlerRegistry{};

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"1.0\",\"id\":7.0,\"method\":\"eth_blockNumber\"}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 7), (try getObjectField(parsed.value, "id")).integer);
    const error_object = try getObjectField(parsed.value, "error");
    try std.testing.expectEqual(@as(i64, jsonrpc.envelope.ErrorCode.INVALID_REQUEST), (try getObjectField(error_object, "code")).integer);
}

test "invalid request object with fractional float id returns null id" {
    const handlers = dispatcher.HandlerRegistry{};

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"1.0\",\"id\":7.5,\"method\":\"eth_blockNumber\"}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();

    try std.testing.expect((try getObjectField(parsed.value, "id")) == .null);
    const error_object = try getObjectField(parsed.value, "error");
    try std.testing.expectEqual(@as(i64, jsonrpc.envelope.ErrorCode.INVALID_REQUEST), (try getObjectField(error_object, "code")).integer);
}

test "invalid request object with out-of-range float id returns null id" {
    const handlers = dispatcher.HandlerRegistry{};

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"1.0\",\"id\":1e30,\"method\":\"eth_blockNumber\"}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();

    try std.testing.expect((try getObjectField(parsed.value, "id")) == .null);
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
}

test "parseConfig defaults to 127.0.0.1:8545" {
    const config = try server.parseConfig(std.testing.allocator, &[_][]const u8{});

    try std.testing.expectEqualStrings("127.0.0.1", config.host);
    try std.testing.expectEqual(@as(u16, 8545), config.port);
    try std.testing.expect(config.fork_url == null);
    try std.testing.expect(config.fork_block_number == null);
}

test "parseConfig parses --host and --port" {
    const config = try server.parseConfig(
        std.testing.allocator,
        &[_][]const u8{ "--host", "0.0.0.0", "--port", "9555" },
    );

    try std.testing.expectEqualStrings("0.0.0.0", config.host);
    try std.testing.expectEqual(@as(u16, 9555), config.port);
}

test "parseConfig parses --fork-url" {
    const config = try server.parseConfig(
        std.testing.allocator,
        &[_][]const u8{ "--fork-url", "https://example.rpc" },
    );

    try std.testing.expect(config.fork_url != null);
    try std.testing.expectEqualStrings("https://example.rpc", config.fork_url.?);
    try std.testing.expect(config.fork_block_number == null);
}

test "parseConfig parses --fork-block-number decimal" {
    const config = try server.parseConfig(
        std.testing.allocator,
        &[_][]const u8{ "--fork-url", "https://example.rpc", "--fork-block-number", "12345678" },
    );

    try std.testing.expectEqual(@as(u64, 12_345_678), config.fork_block_number.?);
}

test "parseConfig parses --fork-block-number hex" {
    const config = try server.parseConfig(
        std.testing.allocator,
        &[_][]const u8{ "--fork-url", "https://example.rpc", "--fork-block-number", "0xbc614e" },
    );

    try std.testing.expectEqual(@as(u64, 12_345_678), config.fork_block_number.?);
}

test "parseConfig rejects --fork-block-number without --fork-url" {
    try std.testing.expectError(
        error.ForkBlockNumberRequiresForkUrl,
        server.parseConfig(std.testing.allocator, &[_][]const u8{ "--fork-block-number", "0x10" }),
    );
}

test "parseConfig rejects missing --fork-block-number value" {
    try std.testing.expectError(
        error.MissingForkBlockNumberValue,
        server.parseConfig(std.testing.allocator, &[_][]const u8{"--fork-block-number"}),
    );
}

test "parseConfig rejects invalid --fork-block-number value" {
    try std.testing.expectError(
        error.InvalidForkBlockNumber,
        server.parseConfig(std.testing.allocator, &[_][]const u8{ "--fork-block-number", "not-a-number" }),
    );
}

test "server with NodeHandler context handles eth_chainId response ownership safely" {
    var handler = try node_handler.NodeHandler.init(std.testing.allocator, null);
    defer handler.deinit(std.testing.allocator);

    const handlers = dispatcher.HandlerRegistry{
        .context = &handler,
        .on_method_with_context = &node_handler.NodeHandler.onMethod,
    };

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_chainId\",\"params\":[]}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();
    const result = try getObjectField(parsed.value, "result");
    try std.testing.expectEqualStrings("0x7a69", result.string);
}

test "server with NodeHandler context handles hardhat_mine response ownership safely" {
    var handler = try node_handler.NodeHandler.init(std.testing.allocator, null);
    defer handler.deinit(std.testing.allocator);

    const handlers = dispatcher.HandlerRegistry{
        .context = &handler,
        .on_method_with_context = &node_handler.NodeHandler.onMethod,
    };

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"hardhat_mine\",\"params\":[\"0x1\"]}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();
    const result = try getObjectField(parsed.value, "result");
    try std.testing.expectEqualStrings("0x0", result.string);
}

test "server with NodeHandler context handles eth_feeHistory ownership safely" {
    var handler = try node_handler.NodeHandler.init(std.testing.allocator, null);
    defer handler.deinit(std.testing.allocator);

    const handlers = dispatcher.HandlerRegistry{
        .context = &handler,
        .on_method_with_context = &node_handler.NodeHandler.onMethod,
    };

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_feeHistory\",\"params\":[\"0x2\",\"latest\",[]]}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();
    const result = try getObjectField(parsed.value, "result");
    const result_object = switch (result) {
        .object => |obj| obj,
        else => return error.ExpectedObject,
    };

    try std.testing.expect(result_object.get("oldestBlock") != null);
    try std.testing.expect(result_object.get("baseFeePerGas") != null);
    try std.testing.expect(result_object.get("gasUsedRatio") != null);
    try std.testing.expect(result_object.get("baseFeePerBlobGas") != null);
    try std.testing.expect(result_object.get("blobGasUsedRatio") != null);
}

test "server with NodeHandler context includes eth_feeHistory reward matrix" {
    var handler = try node_handler.NodeHandler.init(std.testing.allocator, null);
    defer handler.deinit(std.testing.allocator);

    const handlers = dispatcher.HandlerRegistry{
        .context = &handler,
        .on_method_with_context = &node_handler.NodeHandler.onMethod,
    };

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_feeHistory\",\"params\":[\"0x1\",\"latest\",[10,50]]}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();
    const result = try getObjectField(parsed.value, "result");
    const result_object = switch (result) {
        .object => |obj| obj,
        else => return error.ExpectedObject,
    };

    const reward_value = result_object.get("reward") orelse return error.ExpectedReward;
    const reward_array = switch (reward_value) {
        .array => |array| array.items,
        else => return error.ExpectedArray,
    };
    try std.testing.expectEqual(@as(usize, 1), reward_array.len);
}

test "server with NodeHandler context maps eth_feeHistory descending reward percentiles to -32602" {
    var handler = try node_handler.NodeHandler.init(std.testing.allocator, null);
    defer handler.deinit(std.testing.allocator);

    const handlers = dispatcher.HandlerRegistry{
        .context = &handler,
        .on_method_with_context = &node_handler.NodeHandler.onMethod,
    };

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_feeHistory\",\"params\":[\"0x1\",\"latest\",[90,10]]}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();
    const error_object = try getObjectField(parsed.value, "error");
    try std.testing.expectEqual(@as(i64, jsonrpc.envelope.ErrorCode.INVALID_PARAMS), (try getObjectField(error_object, "code")).integer);
}

test "server with NodeHandler context handles eth_getBlockByNumber ownership safely" {
    var handler = try node_handler.NodeHandler.init(std.testing.allocator, null);
    defer handler.deinit(std.testing.allocator);

    const handlers = dispatcher.HandlerRegistry{
        .context = &handler,
        .on_method_with_context = &node_handler.NodeHandler.onMethod,
    };

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getBlockByNumber\",\"params\":[\"latest\",false]}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();
    const result = try getObjectField(parsed.value, "result");
    const block_object = switch (result) {
        .object => |obj| obj,
        else => return error.ExpectedObject,
    };

    try std.testing.expect(block_object.get("number") != null);
    try std.testing.expect(block_object.get("hash") != null);
    try std.testing.expect(block_object.get("transactions") != null);
}

test "server with NodeHandler context maps invalid sendRawTransaction to -32602" {
    var handler = try node_handler.NodeHandler.init(std.testing.allocator, null);
    defer handler.deinit(std.testing.allocator);

    const handlers = dispatcher.HandlerRegistry{
        .context = &handler,
        .on_method_with_context = &node_handler.NodeHandler.onMethod,
    };

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_sendRawTransaction\",\"params\":[\"0x1234\"]}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();
    const error_object = try getObjectField(parsed.value, "error");
    try std.testing.expectEqual(@as(i64, jsonrpc.envelope.ErrorCode.INVALID_PARAMS), (try getObjectField(error_object, "code")).integer);
}

test "server with NodeHandler context maps malformed eth_getStorageAt slot to -32602" {
    var handler = try node_handler.NodeHandler.init(std.testing.allocator, null);
    defer handler.deinit(std.testing.allocator);

    const handlers = dispatcher.HandlerRegistry{
        .context = &handler,
        .on_method_with_context = &node_handler.NodeHandler.onMethod,
    };

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getStorageAt\",\"params\":[\"0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266\",\"0xZZ\",\"latest\"]}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();
    const error_object = try getObjectField(parsed.value, "error");
    try std.testing.expectEqual(@as(i64, jsonrpc.envelope.ErrorCode.INVALID_PARAMS), (try getObjectField(error_object, "code")).integer);
}

test "server with NodeHandler context maps malformed eth_getLogs quantity to -32602" {
    var handler = try node_handler.NodeHandler.init(std.testing.allocator, null);
    defer handler.deinit(std.testing.allocator);

    const handlers = dispatcher.HandlerRegistry{
        .context = &handler,
        .on_method_with_context = &node_handler.NodeHandler.onMethod,
    };

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getLogs\",\"params\":[{\"fromBlock\":\"0xZZ\",\"toBlock\":\"0x1\"}]}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();
    const error_object = try getObjectField(parsed.value, "error");
    try std.testing.expectEqual(@as(i64, jsonrpc.envelope.ErrorCode.INVALID_PARAMS), (try getObjectField(error_object, "code")).integer);
}

test "server with NodeHandler context maps eth_newFilter non-object param to -32602" {
    var handler = try node_handler.NodeHandler.init(std.testing.allocator, null);
    defer handler.deinit(std.testing.allocator);

    const handlers = dispatcher.HandlerRegistry{
        .context = &handler,
        .on_method_with_context = &node_handler.NodeHandler.onMethod,
    };

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_newFilter\",\"params\":[1]}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();
    const error_object = try getObjectField(parsed.value, "error");
    try std.testing.expectEqual(@as(i64, jsonrpc.envelope.ErrorCode.INVALID_PARAMS), (try getObjectField(error_object, "code")).integer);
}

test "server with NodeHandler context maps eth_subscribe logs non-object filter to -32602" {
    var handler = try node_handler.NodeHandler.init(std.testing.allocator, null);
    defer handler.deinit(std.testing.allocator);

    const handlers = dispatcher.HandlerRegistry{
        .context = &handler,
        .on_method_with_context = &node_handler.NodeHandler.onMethod,
    };

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_subscribe\",\"params\":[\"logs\",\"0x1\"]}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();
    const error_object = try getObjectField(parsed.value, "error");
    try std.testing.expectEqual(@as(i64, jsonrpc.envelope.ErrorCode.INVALID_PARAMS), (try getObjectField(error_object, "code")).integer);
}

test "server with NodeHandler context maps eth_call non-string from to -32602" {
    var handler = try node_handler.NodeHandler.init(std.testing.allocator, null);
    defer handler.deinit(std.testing.allocator);

    const handlers = dispatcher.HandlerRegistry{
        .context = &handler,
        .on_method_with_context = &node_handler.NodeHandler.onMethod,
    };

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_call\",\"params\":[{\"from\":1,\"to\":\"0x70997970C51812dc3A010C7d01b50e0d17dc79C8\",\"data\":\"0x\"},\"latest\"]}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();
    const error_object = try getObjectField(parsed.value, "error");
    try std.testing.expectEqual(@as(i64, jsonrpc.envelope.ErrorCode.INVALID_PARAMS), (try getObjectField(error_object, "code")).integer);
}

test "server with NodeHandler context maps hardhat_setIntervalMining malformed interval to -32602" {
    var handler = try node_handler.NodeHandler.init(std.testing.allocator, null);
    defer handler.deinit(std.testing.allocator);

    const handlers = dispatcher.HandlerRegistry{
        .context = &handler,
        .on_method_with_context = &node_handler.NodeHandler.onMethod,
    };

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"hardhat_setIntervalMining\",\"params\":[\"0xZZ\"]}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();
    const error_object = try getObjectField(parsed.value, "error");
    try std.testing.expectEqual(@as(i64, jsonrpc.envelope.ErrorCode.INVALID_PARAMS), (try getObjectField(error_object, "code")).integer);
}

test "server with NodeHandler context maps evm_mine malformed count to -32602" {
    var handler = try node_handler.NodeHandler.init(std.testing.allocator, null);
    defer handler.deinit(std.testing.allocator);

    const handlers = dispatcher.HandlerRegistry{
        .context = &handler,
        .on_method_with_context = &node_handler.NodeHandler.onMethod,
    };

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"evm_mine\",\"params\":[\"0xZZ\"]}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();
    const error_object = try getObjectField(parsed.value, "error");
    try std.testing.expectEqual(@as(i64, jsonrpc.envelope.ErrorCode.INVALID_PARAMS), (try getObjectField(error_object, "code")).integer);
}

test "server with NodeHandler context maps unmanaged sendTransaction to -32602" {
    var handler = try node_handler.NodeHandler.init(std.testing.allocator, null);
    defer handler.deinit(std.testing.allocator);

    const handlers = dispatcher.HandlerRegistry{
        .context = &handler,
        .on_method_with_context = &node_handler.NodeHandler.onMethod,
    };

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_sendTransaction\",\"params\":[{\"from\":\"0x0000000000000000000000000000000000000001\",\"to\":\"0x70997970C51812dc3A010C7d01b50e0d17dc79C8\",\"value\":\"0x1\",\"gas\":\"0x5208\"}]}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();
    const error_object = try getObjectField(parsed.value, "error");
    try std.testing.expectEqual(@as(i64, jsonrpc.envelope.ErrorCode.INVALID_PARAMS), (try getObjectField(error_object, "code")).integer);
}

test "server with NodeHandler context maps unknown filter changes to -32000" {
    var handler = try node_handler.NodeHandler.init(std.testing.allocator, null);
    defer handler.deinit(std.testing.allocator);

    const handlers = dispatcher.HandlerRegistry{
        .context = &handler,
        .on_method_with_context = &node_handler.NodeHandler.onMethod,
    };

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getFilterChanges\",\"params\":[\"0x999\"]}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();
    const error_object = try getObjectField(parsed.value, "error");
    try std.testing.expectEqual(@as(i64, jsonrpc.envelope.ErrorCode.SERVER_ERROR), (try getObjectField(error_object, "code")).integer);
}

test "server with NodeHandler context maps unknown filter logs to -32000" {
    var handler = try node_handler.NodeHandler.init(std.testing.allocator, null);
    defer handler.deinit(std.testing.allocator);

    const handlers = dispatcher.HandlerRegistry{
        .context = &handler,
        .on_method_with_context = &node_handler.NodeHandler.onMethod,
    };

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getFilterLogs\",\"params\":[\"0x999\"]}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();
    const error_object = try getObjectField(parsed.value, "error");
    try std.testing.expectEqual(@as(i64, jsonrpc.envelope.ErrorCode.SERVER_ERROR), (try getObjectField(error_object, "code")).integer);
}
