const std = @import("std");
const state_manager = @import("state-manager");
const blockchain = @import("blockchain");
const handlers = @import("handlers.zig");
const server = @import("server.zig");

fn getObjectField(value: std.json.Value, key: []const u8) !std.json.Value {
    return switch (value) {
        .object => |object| object.get(key) orelse error.MissingField,
        else => error.InvalidJsonType,
    };
}

test "POST valid JSON-RPC returns HTTP 200 with JSON body" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var chain = try blockchain.Blockchain.init(std.testing.allocator, null);
    defer chain.deinit();

    const context = handlers.HandlerContext{
        .state_manager = &sm,
        .blockchain = &chain,
        .chain_id = 1,
    };

    var response = try server.handleHttpRequestForTests(
        std.testing.allocator,
        .{ .host = "127.0.0.1", .port = 8545, .cors_enabled = false },
        &context,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_chainId\"}",
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    try std.testing.expectEqualStrings("application/json", response.content_type.?);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, response.body.?, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const error_object = try getObjectField(parsed.value, "error");
    try std.testing.expectEqual(@as(i64, -32601), (try getObjectField(error_object, "code")).integer);
}

test "non-POST returns 405" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var chain = try blockchain.Blockchain.init(std.testing.allocator, null);
    defer chain.deinit();

    const context = handlers.HandlerContext{
        .state_manager = &sm,
        .blockchain = &chain,
        .chain_id = 1,
    };

    var response = try server.handleHttpRequestForTests(
        std.testing.allocator,
        .{ .host = "127.0.0.1", .port = 8545, .cors_enabled = false },
        &context,
        .GET,
        "",
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.method_not_allowed, response.status);
}

test "malformed POST body returns JSON-RPC parse error" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var chain = try blockchain.Blockchain.init(std.testing.allocator, null);
    defer chain.deinit();

    const context = handlers.HandlerContext{
        .state_manager = &sm,
        .blockchain = &chain,
        .chain_id = 1,
    };

    var response = try server.handleHttpRequestForTests(
        std.testing.allocator,
        .{ .host = "127.0.0.1", .port = 8545, .cors_enabled = false },
        &context,
        .POST,
        "{\"jsonrpc\":\"2.0",
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, response.status);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, response.body.?, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const error_object = try getObjectField(parsed.value, "error");
    try std.testing.expectEqual(@as(i64, -32700), (try getObjectField(error_object, "code")).integer);
}

test "batch POST returns JSON array" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var chain = try blockchain.Blockchain.init(std.testing.allocator, null);
    defer chain.deinit();

    const context = handlers.HandlerContext{
        .state_manager = &sm,
        .blockchain = &chain,
        .chain_id = 1,
    };

    var response = try server.handleHttpRequestForTests(
        std.testing.allocator,
        .{ .host = "127.0.0.1", .port = 8545, .cors_enabled = false },
        &context,
        .POST,
        "[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_chainId\"},{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"eth_unknown\"}]",
    );
    defer response.deinit(std.testing.allocator);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, response.body.?, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const items = switch (parsed.value) {
        .array => |array| array.items,
        else => return error.ExpectedArray,
    };

    try std.testing.expectEqual(@as(usize, 2), items.len);
}

test "OPTIONS with CORS enabled returns CORS headers" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var chain = try blockchain.Blockchain.init(std.testing.allocator, null);
    defer chain.deinit();

    const context = handlers.HandlerContext{
        .state_manager = &sm,
        .blockchain = &chain,
        .chain_id = 1,
    };

    var response = try server.handleHttpRequestForTests(
        std.testing.allocator,
        .{ .host = "127.0.0.1", .port = 8545, .cors_enabled = true },
        &context,
        .OPTIONS,
        "",
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.no_content, response.status);
    try std.testing.expectEqualStrings("*", response.access_control_allow_origin.?);
    try std.testing.expectEqualStrings("POST, OPTIONS", response.access_control_allow_methods.?);
    try std.testing.expectEqualStrings("content-type", response.access_control_allow_headers.?);
}
