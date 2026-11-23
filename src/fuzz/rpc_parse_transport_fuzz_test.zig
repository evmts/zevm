const std = @import("std");
const jsonrpc = @import("jsonrpc");
const parse = @import("../rpc/parse.zig");
const dispatcher = @import("../rpc/dispatcher.zig");
const server = @import("../rpc/server.zig");

const iterations = 512;
const digits = "0123456789abcdef";

fn nonStringValues(random: std.Random) [6]std.json.Value {
    const n: i64 = random.int(u32);
    return .{
        .{ .integer = n },
        .{ .integer = -n - 1 },
        .{ .float = @as(f64, @floatFromInt(n)) + 0.5 },
        .{ .bool = random.boolean() },
        .null,
        .{ .number_string = "18446744073709551616" },
    };
}

fn checkQuantity(comptime T: type, value: std.json.Value, expected: ?T) !void {
    if (expected) |n| {
        try std.testing.expectEqual(n, try parse.parseQuantity(T, .{ .value = value }));
    } else {
        try std.testing.expectError(error.InvalidParams, parse.parseQuantityValue(T, value));
    }
}

test "property: u64 and u256 QuantityHex round-trip, grammar and overflow" {
    var prng = std.Random.DefaultPrng.init(0x63f7_691d_78ab_ef01);
    const random = prng.random();
    for (0..iterations) |i| {
        inline for (.{ u64, u256 }) |T| {
            const shift = random.int(std.math.Log2Int(T));
            const n: T = switch (i % 16) {
                0 => 0,
                1 => std.math.maxInt(T),
                2 => @as(T, 1) << shift,
                3 => random.int(T),
                else => random.int(T) >> shift,
            };
            const width = @bitSizeOf(T) / 4;
            var buf: [2 + width]u8 = undefined;
            const text = try std.fmt.bufPrint(&buf, "0x{x}", .{n});
            try checkQuantity(T, .{ .string = text }, n);

            var bad: [3 + width]u8 = undefined;
            try checkQuantity(T, .{ .string = try std.fmt.bufPrint(&bad, "0x0{s}", .{text[2..]}) }, null);
            text[1] = 'X';
            try checkQuantity(T, .{ .string = text }, null);
            text[1] = 'x';
            const invalid = "_+-z \x00\xff";
            text[2 + random.uintLessThan(usize, text.len - 2)] = invalid[random.uintLessThan(usize, invalid.len)];
            try checkQuantity(T, .{ .string = text }, null);

            @memcpy(bad[0..3], "0x1");
            for (bad[3..]) |*c| c.* = if (i == 0) '0' else digits[random.int(u4)];
            try std.testing.expect(parse.isQuantityHex(&bad)); // Valid grammar, too wide for T.
            try checkQuantity(T, .{ .string = &bad }, null);
            for (nonStringValues(random)) |value| try checkQuantity(T, value, null);
        }
    }
}

fn checkData(value: std.json.Value, expected: ?[]const u8) !void {
    if (expected) |bytes| {
        try parse.validateHexDataValue(value);
        const decoded = try parse.parseHexDataBytes(std.testing.allocator, value);
        defer std.testing.allocator.free(decoded);
        try std.testing.expectEqualSlices(u8, bytes, decoded);
    } else {
        try std.testing.expectError(error.InvalidParams, parse.validateHexDataValue(value));
        if (parse.parseHexDataBytes(std.testing.allocator, value)) |unexpected| {
            defer std.testing.allocator.free(unexpected);
            return error.AcceptedInvalidHexData;
        } else |err| try std.testing.expectEqual(error.InvalidParams, err);
    }

    if (expected != null and expected.?.len == 20) {
        const address = try parse.parseAddressValue(value);
        try std.testing.expectEqualSlices(u8, expected.?, &address.bytes);
    } else try std.testing.expectError(error.InvalidParams, parse.parseAddressValue(value));

    if (expected != null and expected.?.len == 32) {
        const hash = try parse.parseJsonRpcHash32Value(value);
        try std.testing.expectEqualSlices(u8, expected.?, &hash.bytes);
    } else try std.testing.expectError(error.InvalidParams, parse.parseHash32Value(value));
}

test "property: HexData, Address and Bytes32 preserve bytes and enforce widths" {
    var prng = std.Random.DefaultPrng.init(0xa120_88ff_7285_0361);
    const random = prng.random();
    for (0..iterations) |_| {
        var raw: [97]u8 = undefined;
        random.bytes(&raw);
        for ([_]usize{ random.uintAtMost(usize, 96), 20, 32 }) |len| {
            // Include an extra byte to test a well-formed value one byte too wide.
            var buf: [2 + 2 * raw.len]u8 = undefined;
            const lower = try std.fmt.bufPrint(&buf, "0x{x}", .{raw[0 .. len + 1]});
            const text = lower[0 .. 2 + 2 * len];
            try checkData(.{ .string = text }, raw[0..len]);
            try checkData(.{ .string = lower }, raw[0 .. len + 1]);
            if (len > 0) try checkData(.{ .string = text[0 .. text.len - 2] }, raw[0 .. len - 1]);

            for (text[2..]) |*c| c.* = std.ascii.toUpper(c.*);
            try checkData(.{ .string = text }, raw[0..len]);
            for (text[2..]) |*c| {
                if (random.boolean()) c.* = std.ascii.toLower(c.*);
            }
            try checkData(.{ .string = text }, raw[0..len]);
            try checkData(.{ .string = lower[0 .. text.len + 1] }, null);
            text[1] = 'X';
            try checkData(.{ .string = text }, null);
            text[1] = 'x';
            if (len > 0) {
                text[2 + random.uintLessThan(usize, len * 2)] = 'g';
                try checkData(.{ .string = text }, null);
            }
        }
        for (nonStringValues(random)) |value| try checkData(value, null);
    }
}

// Allocate a fresh result so notification suppression and batch serialization
// also exercise the dispatcher's result ownership.
fn mockHandler(allocator: std.mem.Allocator, method: []const u8, _: ?std.json.Value) anyerror!std.json.Value {
    if (std.mem.eql(u8, method, "debug_traceCall")) return error.ModeUnsupported;
    return .{ .string = try allocator.dupe(u8, "0x2a") };
}

const handlers = dispatcher.HandlerRegistry{ .on_method = &mockHandler };

const Reply = struct {
    id: jsonrpc.envelope.Id = .null_value,
    code: ?i32 = null,
};

fn checkReply(value: std.json.Value, expected: Reply) !void {
    try std.testing.expect(value == .object);
    const obj = value.object;
    const version = obj.get("jsonrpc") orelse return error.MissingVersion;
    try std.testing.expect(version == .string);
    try std.testing.expectEqualStrings("2.0", version.string);
    const id = obj.get("id") orelse return error.MissingId;
    switch (expected.id) {
        .integer => |n| {
            try std.testing.expect(id == .integer);
            try std.testing.expectEqual(n, id.integer);
        },
        .string => |s| {
            try std.testing.expect(id == .string);
            try std.testing.expectEqualStrings(s, id.string);
        },
        .null_value => try std.testing.expect(id == .null),
    }
    if (expected.code) |code| {
        try std.testing.expect(!obj.contains("result"));
        const failure = obj.get("error") orelse return error.MissingError;
        try std.testing.expect(failure == .object);
        const actual = failure.object.get("code") orelse return error.MissingCode;
        const message = failure.object.get("message") orelse return error.MissingMessage;
        try std.testing.expect(actual == .integer);
        try std.testing.expectEqual(@as(i64, code), actual.integer);
        try std.testing.expect(message == .string and message.string.len > 0);
    } else {
        try std.testing.expect(!obj.contains("error"));
        const result = obj.get("result") orelse return error.MissingResult;
        try std.testing.expect(result == .string);
        try std.testing.expectEqualStrings("0x2a", result.string);
    }
}

fn checkPost(payload: []const u8, batch: bool, replies: []const Reply) !void {
    const allocator = std.testing.allocator;
    const body = try server.handlePost(allocator, payload, &handlers);
    defer if (body) |bytes| allocator.free(bytes);
    if (replies.len == 0) return std.testing.expect(body == null);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body orelse return error.MissingResponse, .{});
    defer parsed.deinit();
    if (batch) {
        try std.testing.expect(parsed.value == .array);
        try std.testing.expectEqual(replies.len, parsed.value.array.items.len);
        for (parsed.value.array.items, replies) |value, expected| try checkReply(value, expected);
    } else {
        try std.testing.expectEqual(@as(usize, 1), replies.len);
        try checkReply(parsed.value, replies[0]);
    }
}

fn writeRequest(writer: *std.Io.Writer, random: std.Random, notifications_only: bool) !?Reply {
    // Raw fragments let the same generator include structurally invalid items.
    const Case = struct { fields: []const u8, code: ?i32 = null };
    var unknown: [64]u8 = undefined;
    const cases = [_]Case{
        .{ .fields = "\"method\":\"eth_blockNumber\"" },
        .{ .fields = "\"method\":\"net_version\",\"params\":[]" },
        .{ .fields = "\"method\":\"zevm_reset\",\"params\":[null]" },
        .{ .fields = try std.fmt.bufPrint(&unknown, "\"method\":\"unknown_{x}\"", .{random.int(u64)}), .code = -32601 },
        .{ .fields = "\"method\":\"debug_traceCall\"", .code = -32010 },
        .{ .fields = "\"method\":\"eth_getBalance\",\"params\":[]", .code = -32602 },
        .{ .fields = "\"method\":\"anvil_setRpcUrl\",\"params\":[17]", .code = -32602 },
        .{ .fields = "\"method\":\"eth_getBalance\",\"params\":{}", .code = -32602 },
        .{ .fields = "\"method\":false", .code = -32600 },
        .{ .fields = "\"method\":\"eth_blockNumber\",\"params\":17", .code = -32600 },
    };
    const item = cases[random.uintLessThan(usize, if (notifications_only) cases.len - 2 else cases.len)];
    const id: ?jsonrpc.envelope.Id = if (notifications_only) null else switch (random.int(u2)) {
        0 => null,
        1 => .null_value,
        2 => .{ .integer = random.int(i64) },
        3 => .{ .string = if (random.boolean()) "id\"\\\n" else "" },
    };
    try writer.writeAll("{\"jsonrpc\":\"2.0\",");
    try writer.writeAll(item.fields);
    if (id) |present| {
        try writer.writeAll(",\"id\":");
        try std.json.Stringify.value(present, .{}, writer);
    }
    try writer.writeByte('}');
    if (item.code == -32600) return Reply{ .code = -32600 };
    return .{ .id = id orelse return null, .code = item.code };
}

test "property: dispatch correlates IDs, omits notifications and preserves mixed batch order" {
    var prng = std.Random.DefaultPrng.init(0xf383_39e0_218e_188b);
    const random = prng.random();
    for (0..iterations) |i| {
        for ([_]bool{ false, true }) |batch| {
            var buf: [1024]u8 = undefined;
            var writer = std.Io.Writer.fixed(&buf);
            var replies: [6]Reply = undefined;
            var count: usize = 0;
            if (batch) try writer.writeByte('[');
            const size = if (batch) 1 + random.uintLessThan(usize, replies.len) else 1;
            for (0..size) |j| {
                if (j != 0) try writer.writeByte(',');
                if (try writeRequest(&writer, random, i % 8 == 0)) |reply| {
                    replies[count] = reply;
                    count += 1;
                }
            }
            if (batch) try writer.writeByte(']');
            try checkPost(writer.buffered(), batch, replies[0..count]);
        }
    }
}

test "explicit null params are an invalid request, including when id is absent" {
    try checkPost("{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\",\"params\":null}", false, &.{.{ .code = -32600 }});
}

const call = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_blockNumber\"}";
const notification = "{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\"}";

fn checkHttp(request: server.TestHttpRequest, expected: std.http.Status) !void {
    const allocator = std.testing.allocator;
    var response = try server.handleHttpRequestForTestWithOptions(allocator, request, &handlers);
    defer response.deinit(allocator);
    try std.testing.expectEqual(expected, response.status);
    if (expected == .ok) {
        try std.testing.expectEqualStrings("application/json", response.content_type orelse return error.MissingMediaType);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body orelse return error.MissingResponse, .{});
        defer parsed.deinit();
        try checkReply(parsed.value, .{ .id = .{ .integer = 1 } });
    } else {
        try std.testing.expect(response.body == null);
        try std.testing.expect(response.content_type == null);
    }
}

test "property: HTTP routing, media-type parameters, notifications and oversized bodies" {
    var prng = std.Random.DefaultPrng.init(0x1507_d8f6_93f1_bada);
    const random = prng.random();
    const oversized = try std.testing.allocator.alloc(u8, server.MAX_REQUEST_BODY_BYTES + 128);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, ' ');
    const other_methods = [_]std.http.Method{ .GET, .PUT, .HEAD, .DELETE, .PATCH, .OPTIONS };
    const invalid_types = [_][]const u8{ "", "application/jsonp", "text/json", "application/json+xml", "application /json", "text/plain; type=application/json" };
    for (0..iterations) |_| {
        var media = "application/json".*;
        for (&media) |*c| {
            if (random.boolean()) c.* = std.ascii.toUpper(c.*);
        }
        var media_buf: [96]u8 = undefined;
        const content_type = try std.fmt.bufPrint(&media_buf, " \t{s} \t; charset=utf-8; profile=\"v{x}\"", .{ media, random.int(u32) });
        try checkHttp(.{ .method = .POST, .body = call, .content_type = content_type }, .ok);
        try checkHttp(.{ .method = .POST, .body = notification, .content_type = content_type }, .no_content);
        const other = other_methods[random.uintLessThan(usize, other_methods.len)];
        var target_buf: [48]u8 = undefined;
        const target = try std.fmt.bufPrint(&target_buf, "/rpc/{x}?v=1", .{random.int(u64)});
        try checkHttp(.{ .method = if (random.boolean()) .POST else other, .target = target, .content_type = null }, .not_found);
        try checkHttp(.{ .method = other, .content_type = null }, .method_not_allowed);
        try checkHttp(.{ .method = .POST, .content_type = null, .body = call }, .unsupported_media_type);
        try checkHttp(.{ .method = .POST, .content_type = invalid_types[random.uintLessThan(usize, invalid_types.len)], .body = call }, .unsupported_media_type);
        const len = server.MAX_REQUEST_BODY_BYTES + 1 + random.uintLessThan(usize, 128);
        try checkHttp(.{ .method = .POST, .body = oversized[0..len] }, .payload_too_large);
    }
}

fn paddedHead(buf: []u8, pad: u8) []const u8 {
    const start = "GET / HTTP/1.1\r\nConnection: close\r\nX-Pad: ";
    const end = "\r\n\r\n";
    @memcpy(buf[0..start.len], start);
    @memset(buf[start.len .. buf.len - end.len], pad);
    @memcpy(buf[buf.len - end.len ..], end);
    return buf;
}

test "property: fragmented HTTP heads fit up to and including the receive buffer limit" {
    var prng = std.Random.DefaultPrng.init(0xfe98_042b_9050_4206);
    const random = prng.random();
    const limit = server.MAX_HTTP_HEAD_BYTES;
    var input: [limit + 128]u8 = undefined;
    var receive_buffer: [limit]u8 = undefined;
    for (0..iterations) |i| {
        const len = switch (i % 4) {
            0 => limit,
            1 => limit + 1,
            else => limit - 128 + random.uintAtMost(usize, 256),
        };
        const head = paddedHead(input[0..len], digits[random.int(u4)]);
        // Split both inside a header and inside the final CRLFCRLF.
        const cut = if (random.boolean()) len - 1 - random.uintLessThan(usize, 3) else random.uintLessThan(usize, len);
        const calls = [_]std.testing.Reader.Call{ .{ .buffer = head[0..cut] }, .{ .buffer = head[cut..] } };
        var reader = std.testing.Reader.init(&receive_buffer, &calls);
        var sink = std.Io.Writer.fixed(&.{});
        var http = std.http.Server.init(&reader.interface, &sink);
        if (len > limit) {
            try std.testing.expectError(error.HttpHeadersOversize, http.receiveHead());
        } else {
            const request = try http.receiveHead();
            try std.testing.expectEqual(len, request.head_buffer.len);
            try std.testing.expectEqual(std.http.Method.GET, request.head.method);
            try std.testing.expectEqualStrings("/", request.head.target);
        }
    }
}

// Half-close after the complete request, then collect the entire small response.
fn checkWire(listener: *const server.TestListener, bytes: []const u8, expected: ?std.http.Status) !void {
    const stream = try std.net.tcpConnectToAddress(listener.address());
    defer stream.close();
    try stream.writeAll(bytes);
    std.posix.shutdown(stream.handle, .send) catch |err| switch (err) {
        error.SocketNotConnected, error.ConnectionResetByPeer => {},
        else => return err,
    };
    var buf: [1024]u8 = undefined;
    var used: usize = 0;
    while (used < buf.len) {
        const n = stream.read(buf[used..]) catch |err| switch (err) {
            error.ConnectionResetByPeer => 0,
            else => return err,
        };
        if (n == 0) break;
        used += n;
    }
    const status = expected orelse return std.testing.expectEqual(@as(usize, 0), used);
    if (used == buf.len) return error.ResponseTooLong;
    const end = std.mem.indexOf(u8, buf[0..used], "\r\n\r\n") orelse return error.MissingResponseHead;
    const head = try std.http.Client.Response.Head.parse(buf[0 .. end + 4]);
    try std.testing.expectEqual(status, head.status);
    if (head.content_length) |length| try std.testing.expectEqual(@as(u64, 0), length);
    const empty_body: []const u8 = if (head.transfer_encoding == .chunked) "0\r\n\r\n" else "";
    try std.testing.expectEqualSlices(u8, empty_body, buf[end + 4 .. used]);
}

test "listener applies the published HTTP head limit on the wire" {
    var listener = try server.TestListener.init(std.testing.allocator, "127.0.0.1", &handlers);
    defer listener.deinit();
    try listener.start();
    const limit = server.MAX_HTTP_HEAD_BYTES;
    var buf: [limit + 1]u8 = undefined;
    try checkWire(&listener, paddedHead(buf[0..limit], 'a'), .method_not_allowed);
    try checkWire(&listener, paddedHead(&buf, 'a'), .request_header_fields_too_large);
}

test "listener applies an inclusive decoded body limit to fixed and chunked frames" {
    const limit = 96;
    var listener = try server.TestListener.initWithLimits(std.testing.allocator, "127.0.0.1", &handlers, .{ .max_request_body_bytes = limit });
    defer listener.deinit();
    try listener.start();
    var body = [_]u8{' '} ** (limit + 1);
    @memcpy(body[0..notification.len], notification);
    // Run the below/above controls for both framings before testing equality.
    for ([_]usize{ limit - 1, limit + 1, limit }) |len| {
        for ([_]bool{ false, true }) |chunked| {
            var buf: [384]u8 = undefined;
            var writer = std.Io.Writer.fixed(&buf);
            try writer.writeAll("POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Type: application/json\r\n");
            if (chunked) {
                const split = notification.len / 2;
                try writer.print("Transfer-Encoding: chunked\r\n\r\n{x}\r\n{s}\r\n{x}\r\n{s}\r\n0\r\n\r\n", .{ split, body[0..split], len - split, body[split..len] });
            } else {
                try writer.print("Content-Length: {d}\r\n\r\n{s}", .{ len, body[0..len] });
            }
            try checkWire(&listener, writer.buffered(), if (len <= limit) .no_content else .payload_too_large);
        }
    }
}

fn nibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn hexDigits(value: std.json.Value) ?[]const u8 {
    if (value != .string or !std.mem.startsWith(u8, value.string, "0x")) return null;
    for (value.string[2..]) |c| _ = nibble(c) orelse return null;
    return value.string[2..];
}

fn referenceQuantity(comptime T: type, hex: []const u8) ?T {
    if (hex.len > @bitSizeOf(T) / 4) return null;
    var result: T = 0;
    for (hex) |c| result = (result << 4) | nibble(c).?;
    return result;
}

fn fuzzValue(value: std.json.Value) !void {
    const allocator = std.testing.allocator;
    const hex = hexDigits(value);
    const quantity = if (hex) |s| s.len > 0 and (s.len == 1 or s[0] != '0') else false;
    if (quantity) {
        try parse.validateQuantityValue(value);
    } else try std.testing.expectError(error.InvalidParams, parse.validateQuantityValue(value));
    inline for (.{ u64, u256 }) |T| {
        try checkQuantity(T, value, if (quantity) referenceQuantity(T, hex.?) else null);
    }
    if (hex != null and hex.?.len % 2 == 0) {
        const decoded = try allocator.alloc(u8, hex.?.len / 2);
        defer allocator.free(decoded);
        for (decoded, 0..) |*b, i| b.* = (nibble(hex.?[2 * i]).? << 4) | nibble(hex.?[2 * i + 1]).?;
        try checkData(value, decoded);
    } else try checkData(value, null);

    if (value == .array) {
        try std.testing.expectEqual(value.array.items.len, (try parse.paramsArrayItems(value)).len);
    } else try std.testing.expectError(error.InvalidParams, parse.paramsArrayItems(value));

    const head: u64 = 12345;
    const tags = [_][]const u8{ "earliest", "latest", "pending", "safe", "finalized" };
    for (tags) |tag| {
        if (value == .string and std.mem.eql(u8, value.string, tag)) {
            const selector = try parse.parseLightBlockSelectorValue(value);
            try std.testing.expectEqualStrings(tag, @tagName(selector));
            try std.testing.expectEqual(if (std.mem.eql(u8, tag, "earliest")) @as(u64, 0) else head, try parse.resolveTrustedBlockSelector(head, value));
            return;
        }
    }
    if (quantity) {
        if (referenceQuantity(u64, hex.?)) |number| {
            const selector = try parse.parseLightBlockSelectorValue(value);
            try std.testing.expect(selector == .number);
            try std.testing.expectEqual(number, selector.number);
            try std.testing.expectEqual(number, try parse.resolveTrustedBlockSelector(head, value));
            return;
        }
    }
    try std.testing.expectError(error.InvalidParams, parse.parseLightBlockSelectorValue(value));
    try std.testing.expectError(error.InvalidParams, parse.resolveTrustedBlockSelector(head, value));
}

fn fuzzParsers(_: void, input: []const u8) anyerror!void {
    // Test raw bytes first, even when they cannot form a JSON document.
    try fuzzValue(.{ .string = input });
    const parsed = std.json.parseFromSlice(std.json.Value, std.testing.allocator, input, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    defer parsed.deinit();
    try fuzzValue(parsed.value);
    switch (parsed.value) {
        .array => |array| for (array.items) |item| try fuzzValue(item),
        .object => |obj| for (obj.values()) |item| try fuzzValue(item),
        else => {},
    }
}

test "fuzz: RPC parsers on raw bytes and decoded JSON values" {
    try std.testing.fuzz({}, fuzzParsers, .{ .corpus = &.{
        "\x00\xff0x",
        "0x",
        "0x0",
        "0Xff",
        "0x00",
        "0xff",
        "0x10000000000000000",
        "0x1" ++ "0" ** 64,
        "\"0x" ++ "aF" ** 20 ++ "\"",
        "\"0x" ++ "B1" ** 32 ++ "\"",
        "[null,true,42,-1,2.5,18446744073709551616,\"\\u0030xFf\",\"0x123\"]",
        "{\"first\":\"earliest\",\"head\":\"latest\",\"next\":\"pending\",\"safe\":\"safe\",\"final\":\"finalized\"}",
    } });
}

fn fuzzDispatch(_: void, input: []const u8) anyerror!void {
    const allocator = std.testing.allocator;
    var parsed = jsonrpc.envelope.parseSingleOrBatch(allocator, input) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.InvalidRequest => return checkPost(input, false, &.{.{ .code = -32600 }}),
        else => return checkPost(input, false, &.{.{ .code = -32700 }}),
    };
    defer parsed.deinit(allocator);

    const requests: []const jsonrpc.envelope.RequestEnvelope = switch (parsed.kind) {
        .single => |*request| request[0..1],
        .batch => |batch| batch,
    };
    var replies: std.ArrayList(Reply) = .empty;
    defer replies.deinit(allocator);
    for (requests) |request| {
        if (request.invalid) {
            try replies.append(allocator, .{ .code = -32600 });
            continue;
        }
        var response = try dispatcher.dispatch(allocator, request, &handlers);
        defer response.deinit(allocator);
        try std.testing.expectEqualStrings("2.0", response.jsonrpc);
        try std.testing.expectEqualDeep(request.id, response.id);
        try std.testing.expect((response.result != null) != (response.error_value != null));
        if (response.result) |result| {
            try std.testing.expect(result == .string);
            try std.testing.expectEqualStrings("0x2a", result.string);
        }
        if (request.id) |id| {
            try replies.append(allocator, .{ .id = id, .code = if (response.error_value) |failure| failure.code else null });
        }
    }
    // Compare the typed dispatch results to the serialized transport response.
    try checkPost(input, parsed.kind == .batch, replies.items);
}

test "fuzz: dispatcher and serialized JSON-RPC responses agree" {
    try std.testing.fuzz({}, fuzzDispatch, .{ .corpus = &.{
        "{",
        "\xff",
        "[]",
        "null",
        call,
        notification,
        "[" ++ notification ++ "," ++ notification ++ "]",
        "[42,{}, " ++ notification ++ "," ++ call ++ ",{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"unknown\"}]",
        "{\"jsonrpc\":\"2.0\",\"id\":\"line\\n\\\"\",\"method\":\"eth_getBalance\",\"params\":[]}",
        "{\"jsonrpc\":\"2.0\",\"id\":-9223372036854775808,\"method\":\"anvil_reset\",\"params\":[{\"forking\":{\"jsonRpcUrl\":\"test\",\"blockNumber\":\"0x1\"}}]}",
        "{\"jsonrpc\":\"1.0\",\"id\":{},\"method\":false,\"params\":5}",
        "{\"jsonrpc\":\"2.0\",\"id\":\"\",\"method\":\"debug_traceCall\",\"params\":{}}",
    } });
}
