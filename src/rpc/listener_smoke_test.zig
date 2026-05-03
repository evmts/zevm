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

fn postJson(address: std.net.Address, body: []const u8) !RawHttpResponse {
    return postJsonWithAllocator(std.testing.allocator, address, body);
}

fn postJsonWithAllocator(allocator: std.mem.Allocator, address: std.net.Address, body: []const u8) !RawHttpResponse {
    const stream = try std.net.tcpConnectToAddress(address);
    defer stream.close();

    var request = std.Io.Writer.Allocating.init(allocator);
    defer request.deinit();
    try request.writer.print(
        "POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ body.len, body },
    );

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

const AsyncPost = struct {
    address: std.net.Address,
    body: []const u8,
    done: std.Thread.Semaphore = .{},
    result: anyerror!u16 = error.NotStarted,

    fn run(self: *AsyncPost) void {
        var response = postJsonWithAllocator(std.heap.page_allocator, self.address, self.body) catch |err| {
            self.result = err;
            self.done.post();
            return;
        };
        defer response.deinit(std.heap.page_allocator);

        self.result = response.status_code;
        self.done.post();
    }
};

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

fn assertLightCheckpointStatus(checkpoint_dir: []const u8, expected_checkpoint: [32]u8) !void {
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

    const expected_hex = std.fmt.bytesToHex(expected_checkpoint, .lower);
    var expected_prefixed: [66]u8 = undefined;
    expected_prefixed[0] = '0';
    expected_prefixed[1] = 'x';
    @memcpy(expected_prefixed[2..], expected_hex[0..]);
    try std.testing.expectEqualStrings(
        expected_prefixed[0..],
        (try objectField(result, "lastCheckpoint")).string,
    );
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

test "slow client does not block another TCP client" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    installHandlers(&rt, &handlers);

    var listener = try server.TestListener.init(std.testing.allocator, "127.0.0.1", &handlers);
    defer listener.deinit();
    try listener.start();

    var slow_stream: ?std.net.Stream = try std.net.tcpConnectToAddress(listener.address());
    defer if (slow_stream) |stream| stream.close();
    try slow_stream.?.writeAll(
        "POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: 64\r\n",
    );

    var request = AsyncPost{
        .address = listener.address(),
        .body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_chainId\"}",
    };
    const thread = try std.Thread.spawn(.{}, AsyncPost.run, .{&request});

    request.done.timedWait(2 * std.time.ns_per_s) catch |err| switch (err) {
        error.Timeout => {
            slow_stream.?.close();
            slow_stream = null;
            thread.join();
            return error.ConcurrentRequestBlockedBySlowClient;
        },
    };
    thread.join();

    try std.testing.expectEqual(@as(u16, 200), try request.result);
}

test "listener stop unblocks accept loop and active slow connections" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    installHandlers(&rt, &handlers);

    var listener = try server.TestListener.init(std.testing.allocator, "127.0.0.1", &handlers);
    defer listener.deinit();
    try listener.start();

    const slow_stream = try std.net.tcpConnectToAddress(listener.address());
    defer slow_stream.close();
    try slow_stream.writeAll(
        "POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: 64\r\n",
    );

    var attempts: usize = 0;
    while (listener.activeConnectionCountForTest() == 0 and attempts < 100) : (attempts += 1) {
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    try std.testing.expect(listener.activeConnectionCountForTest() > 0);

    listener.stop();
    try std.testing.expectEqual(@as(usize, 0), listener.activeConnectionCountForTest());
}

test "light mode restarts from persisted checkpoint over a real TCP listener" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const checkpoint_dir = try tmpPath(std.testing.allocator, &tmp_dir, "");
    defer std.testing.allocator.free(checkpoint_dir);

    const persisted_checkpoint = [_]u8{0xab} ** 32;
    try checkpoint.saveCheckpoint(std.testing.allocator, checkpoint_dir, persisted_checkpoint);

    try assertLightCheckpointStatus(checkpoint_dir, persisted_checkpoint);
    try assertLightCheckpointStatus(checkpoint_dir, persisted_checkpoint);
}
