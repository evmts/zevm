const std = @import("std");
const checkpoint = @import("../checkpoint.zig");
const dispatcher = @import("dispatcher.zig");
const dispatch_wiring = @import("dispatch_wiring.zig");
const runtime_mod = @import("../node/runtime.zig");
const server = @import("server.zig");

const RawHttpResponse = struct {
    bytes: []u8,
    status_code: u16,
    body: []const u8,

    fn deinit(self: *RawHttpResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }
};

fn tmpPath(allocator: std.mem.Allocator, tmp_dir: *std.testing.TmpDir, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp_dir.sub_path, name });
}

fn installHandlers(rt: *runtime_mod.NodeRuntime, handlers: *dispatcher.HandlerRegistry) void {
    dispatch_wiring.install(handlers, rt);
}

fn sendHttp(
    address: std.net.Address,
    method: []const u8,
    target: []const u8,
    content_type: ?[]const u8,
    body: []const u8,
) !RawHttpResponse {
    const allocator = std.testing.allocator;
    const stream = try std.net.tcpConnectToAddress(address);
    defer stream.close();

    var request = std.Io.Writer.Allocating.init(allocator);
    defer request.deinit();
    try request.writer.print("{s} {s} HTTP/1.1\r\nHost: 127.0.0.1\r\n", .{ method, target });
    if (content_type) |value| {
        try request.writer.print("Content-Type: {s}\r\n", .{value});
    }
    try request.writer.print("Content-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body });

    try stream.writeAll(request.written());

    var response = std.ArrayList(u8).empty;
    errdefer response.deinit(allocator);

    var header_end: ?usize = null;
    var expected_len: ?usize = null;
    var read_buffer: [1024]u8 = undefined;

    while (true) {
        const read_count = try stream.read(&read_buffer);
        if (read_count == 0) break;
        try response.appendSlice(allocator, read_buffer[0..read_count]);

        if (header_end == null) {
            if (std.mem.indexOf(u8, response.items, "\r\n\r\n")) |idx| {
                header_end = idx + 4;
                expected_len = try contentLength(response.items[0..idx]);
            }
        }

        if (header_end) |end| {
            if (expected_len) |len| {
                if (response.items.len >= end + len) break;
            }
        }

        if (response.items.len > 1024 * 1024) return error.ResponseTooLarge;
    }

    const owned = try response.toOwnedSlice(allocator);
    const end = header_end orelse return error.MalformedHttpResponse;
    const len = expected_len orelse owned.len - end;
    if (owned.len < end + len) return error.TruncatedHttpResponse;

    return .{
        .bytes = owned,
        .status_code = try statusCode(owned[0..end]),
        .body = owned[end .. end + len],
    };
}

fn postJson(address: std.net.Address, body: []const u8) !RawHttpResponse {
    return sendHttp(address, "POST", "/", "application/json", body);
}

fn statusCode(headers: []const u8) !u16 {
    const line_end = std.mem.indexOf(u8, headers, "\r\n") orelse return error.MalformedHttpResponse;
    const status_line = headers[0..line_end];
    var fields = std.mem.splitScalar(u8, status_line, ' ');
    _ = fields.next() orelse return error.MalformedHttpResponse;
    const code_text = fields.next() orelse return error.MalformedHttpResponse;
    return std.fmt.parseInt(u16, code_text, 10);
}

fn contentLength(headers: []const u8) !?usize {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    _ = lines.next();

    while (lines.next()) |line| {
        const colon_index = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon_index], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "content-length")) continue;

        const value = std.mem.trim(u8, line[colon_index + 1 ..], " \t");
        return try std.fmt.parseInt(usize, value, 10);
    }

    return null;
}

fn parseBody(body: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{
        .allocate = .alloc_always,
    });
}

fn objectField(value: std.json.Value, key: []const u8) !std.json.Value {
    return switch (value) {
        .object => |object| object.get(key) orelse error.MissingField,
        else => error.ExpectedObject,
    };
}

test "trusted mode serves JSON-RPC over a real TCP listener" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    installHandlers(&rt, &handlers);

    var listener = try server.TestListener.init(std.testing.allocator, "127.0.0.1", &handlers);
    defer listener.deinit();
    try listener.start();

    var response = try postJson(listener.address(), "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_chainId\"}");
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 200), response.status_code);

    const parsed = try parseBody(response.body);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 1), (try objectField(parsed.value, "id")).integer);
    try std.testing.expectEqualStrings("0x7a69", (try objectField(parsed.value, "result")).string);
}

test "trusted mode returns 204 for a notification over a real TCP listener" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    installHandlers(&rt, &handlers);

    var listener = try server.TestListener.init(std.testing.allocator, "127.0.0.1", &handlers);
    defer listener.deinit();
    try listener.start();

    var response = try postJson(listener.address(), "{\"jsonrpc\":\"2.0\",\"method\":\"eth_chainId\"}");
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 204), response.status_code);
    try std.testing.expectEqual(@as(usize, 0), response.body.len);
}

test "trusted mode returns 204 for notification-only batch over a real TCP listener" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    installHandlers(&rt, &handlers);

    var listener = try server.TestListener.init(std.testing.allocator, "127.0.0.1", &handlers);
    defer listener.deinit();
    try listener.start();

    var response = try postJson(
        listener.address(),
        "[{\"jsonrpc\":\"2.0\",\"method\":\"eth_chainId\"},{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\"}]",
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 204), response.status_code);
    try std.testing.expectEqual(@as(usize, 0), response.body.len);
}

test "trusted mode returns -32601 for unknown method over a real TCP listener" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    installHandlers(&rt, &handlers);

    var listener = try server.TestListener.init(std.testing.allocator, "127.0.0.1", &handlers);
    defer listener.deinit();
    try listener.start();

    var response = try postJson(listener.address(), "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"no_such_method\"}");
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 200), response.status_code);

    const parsed = try parseBody(response.body);
    defer parsed.deinit();

    const error_object = try objectField(parsed.value, "error");
    try std.testing.expectEqual(@as(i64, dispatcher.ErrorCode.METHOD_NOT_FOUND), (try objectField(error_object, "code")).integer);
}

test "transport validation is enforced over a real TCP listener" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    installHandlers(&rt, &handlers);

    var listener = try server.TestListener.init(std.testing.allocator, "127.0.0.1", &handlers);
    defer listener.deinit();
    try listener.start();

    {
        var response = try sendHttp(listener.address(), "POST", "/rpc", "application/json", "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_chainId\"}");
        defer response.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u16, 404), response.status_code);
    }

    {
        var response = try sendHttp(listener.address(), "GET", "/", null, "");
        defer response.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u16, 405), response.status_code);
    }

    {
        var response = try sendHttp(listener.address(), "POST", "/", "text/plain", "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_chainId\"}");
        defer response.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u16, 415), response.status_code);
    }
}

test "light mode serves persisted checkpoint status over a real TCP listener" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const checkpoint_dir = try tmpPath(std.testing.allocator, &tmp_dir, "");
    defer std.testing.allocator.free(checkpoint_dir);

    const persisted_checkpoint = [_]u8{0xab} ** 32;
    try checkpoint.saveCheckpoint(std.testing.allocator, checkpoint_dir, persisted_checkpoint);

    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, .{
        .mode = .light,
        .light = .{
            .network = .holesky,
            .consensus_rpc_url = "http://127.0.0.1:5052",
            .proof_rpc_url = "http://127.0.0.1:8545",
            .advance_on_request = false,
            .checkpoint_dir = checkpoint_dir,
        },
    });
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    installHandlers(&rt, &handlers);

    var listener = try server.TestListener.init(std.testing.allocator, "127.0.0.1", &handlers);
    defer listener.deinit();
    try listener.start();

    var response = try postJson(listener.address(), "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"zevm_lightSyncStatus\"}");
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 200), response.status_code);

    const parsed = try parseBody(response.body);
    defer parsed.deinit();

    const result = try objectField(parsed.value, "result");
    try std.testing.expectEqualStrings("syncing", (try objectField(result, "status")).string);
    try std.testing.expectEqual(false, (try objectField(result, "ready")).bool);
    try std.testing.expectEqualStrings("holesky", (try objectField(result, "network")).string);
    try std.testing.expectEqualStrings("persisted", (try objectField(result, "checkpointSource")).string);
    try std.testing.expectEqualStrings(
        "0xabababababababababababababababababababababababababababababababab",
        (try objectField(result, "lastCheckpoint")).string,
    );
}
