const std = @import("std");
const jsonrpc = @import("jsonrpc");
const app_config = @import("../config.zig");
const dispatcher = @import("dispatcher.zig");
const log = @import("../log.zig");

pub const ServerConfig = app_config.RpcConfig;

pub const TestHttpResponse = struct {
    status: std.http.Status,
    body: ?[]u8,
    content_type: ?[]const u8 = null,

    pub fn deinit(self: *TestHttpResponse, allocator: std.mem.Allocator) void {
        if (self.body) |body| {
            allocator.free(body);
        }
    }
};

const json_content_type_header = std.http.Header{
    .name = "content-type",
    .value = "application/json",
};

pub fn run(allocator: std.mem.Allocator, server_config: ServerConfig, handlers: *const dispatcher.HandlerRegistry) !void {
    const address = try std.net.Address.parseIp(server_config.host, server_config.port);
    var tcp_server = try address.listen(.{ .reuse_address = true });
    defer tcp_server.deinit();

    log.info(.rpc, "listener bound host={s} port={}", .{ server_config.host, server_config.port });

    while (true) {
        const connection = try tcp_server.accept();
        handleConnection(allocator, handlers, connection) catch {
            continue;
        };
    }
}

pub fn handleHttpRequestForTest(
    allocator: std.mem.Allocator,
    method: std.http.Method,
    body: []const u8,
    handlers: *const dispatcher.HandlerRegistry,
) !TestHttpResponse {
    if (method != .POST) {
        return .{
            .status = .method_not_allowed,
            .body = null,
        };
    }

    const response_body = try handlePost(allocator, body, handlers);
    return .{
        .status = .ok,
        .body = response_body,
        .content_type = "application/json",
    };
}

fn handleConnection(
    allocator: std.mem.Allocator,
    handlers: *const dispatcher.HandlerRegistry,
    connection: std.net.Server.Connection,
) !void {
    defer connection.stream.close();

    var receive_buffer: [8192]u8 = undefined;
    var send_buffer: [8192]u8 = undefined;
    var connection_reader = connection.stream.reader(&receive_buffer);
    var connection_writer = connection.stream.writer(&send_buffer);
    var http_server = std.http.Server.init(connection_reader.interface(), &connection_writer.interface);

    while (http_server.reader.state == .ready) {
        var request = http_server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => return err,
        };

        try handleRequest(allocator, handlers, &request);
    }
}

fn handleRequest(
    allocator: std.mem.Allocator,
    handlers: *const dispatcher.HandlerRegistry,
    request: *std.http.Server.Request,
) !void {
    if (request.head.method != .POST) {
        try request.respond("Method not allowed", .{
            .status = .method_not_allowed,
        });
        return;
    }

    const request_body = try readRequestBody(allocator, request);
    defer allocator.free(request_body);

    const response_body = try handlePost(allocator, request_body, handlers);
    defer allocator.free(response_body);

    try request.respond(response_body, .{
        .status = .ok,
        .extra_headers = &[_]std.http.Header{json_content_type_header},
    });
}

fn readRequestBody(allocator: std.mem.Allocator, request: *std.http.Server.Request) ![]u8 {
    var reader_buffer: [4096]u8 = undefined;
    const reader = try request.readerExpectContinue(&reader_buffer);

    var request_body = std.ArrayList(u8).empty;
    errdefer request_body.deinit(allocator);

    try reader.appendRemaining(allocator, &request_body, .limited(1024 * 1024));

    return request_body.toOwnedSlice(allocator);
}

fn handlePost(
    allocator: std.mem.Allocator,
    body: []const u8,
    handlers: *const dispatcher.HandlerRegistry,
) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return writeErrorResponse(allocator, null, jsonrpc.envelope.ErrorCode.PARSE_ERROR, "Parse error");
    };
    defer parsed.deinit();

    var request_batch = jsonrpc.envelope.parseSingleOrBatch(allocator, body) catch {
        return writeErrorResponse(allocator, null, jsonrpc.envelope.ErrorCode.INVALID_REQUEST, "Invalid request");
    };
    defer request_batch.deinit(allocator);

    return switch (request_batch.kind) {
        .single => |request| handleSingleRequest(allocator, request, handlers),
        .batch => |batch| handleBatch(allocator, batch, handlers),
    };
}

fn handleSingleRequest(
    allocator: std.mem.Allocator,
    request: jsonrpc.envelope.RequestEnvelope,
    handlers: *const dispatcher.HandlerRegistry,
) ![]u8 {
    var response = try dispatcher.dispatch(allocator, request, handlers);
    defer response.deinit(allocator);

    return stringifyResponse(allocator, response);
}

fn handleBatch(
    allocator: std.mem.Allocator,
    batch: []jsonrpc.envelope.RequestEnvelope,
    handlers: *const dispatcher.HandlerRegistry,
) ![]u8 {
    var response_bytes = std.ArrayList(u8).empty;
    errdefer response_bytes.deinit(allocator);

    try response_bytes.append(allocator, '[');
    for (batch, 0..) |request, index| {
        if (index > 0) {
            try response_bytes.append(allocator, ',');
        }

        var response = try dispatcher.dispatch(allocator, request, handlers);
        defer response.deinit(allocator);

        const item_bytes = try stringifyResponse(allocator, response);
        defer allocator.free(item_bytes);

        try response_bytes.appendSlice(allocator, item_bytes);
    }
    try response_bytes.append(allocator, ']');

    return response_bytes.toOwnedSlice(allocator);
}

fn writeErrorResponse(
    allocator: std.mem.Allocator,
    id: ?jsonrpc.envelope.Id,
    code: i32,
    message: []const u8,
) ![]u8 {
    var response = jsonrpc.envelope.ResponseEnvelope.makeError(id, code, message);
    defer response.deinit(allocator);

    return stringifyResponse(allocator, response);
}

fn stringifyResponse(allocator: std.mem.Allocator, response: jsonrpc.envelope.ResponseEnvelope) ![]u8 {
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();

    try std.json.Stringify.value(response, .{}, &writer.writer);

    return writer.toOwnedSlice();
}
