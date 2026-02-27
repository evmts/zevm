const std = @import("std");
const envelope = @import("envelope.zig");
const router = @import("router.zig");
const handlers = @import("handlers.zig");

pub const ServerConfig = struct {
    host: []const u8,
    port: u16,
    cors_enabled: bool,
};

pub const TestHttpResponse = struct {
    status: std.http.Status,
    body: ?[]u8,
    content_type: ?[]const u8 = null,
    access_control_allow_origin: ?[]const u8 = null,
    access_control_allow_methods: ?[]const u8 = null,
    access_control_allow_headers: ?[]const u8 = null,

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

const cors_allow_origin_header = std.http.Header{
    .name = "access-control-allow-origin",
    .value = "*",
};

const cors_allow_methods_header = std.http.Header{
    .name = "access-control-allow-methods",
    .value = "POST, OPTIONS",
};

const cors_allow_headers_header = std.http.Header{
    .name = "access-control-allow-headers",
    .value = "content-type",
};

pub fn serve(
    allocator: std.mem.Allocator,
    config: ServerConfig,
    context: *const handlers.HandlerContext,
) !void {
    const address = try std.net.Address.parseIp(config.host, config.port);
    var tcp_server = try address.listen(.{ .reuse_address = true });
    defer tcp_server.deinit();

    while (true) {
        const connection = try tcp_server.accept();
        handleConnection(allocator, config, context, connection) catch {
            continue;
        };
    }
}

pub fn handleHttpRequestForTests(
    allocator: std.mem.Allocator,
    config: ServerConfig,
    context: *const handlers.HandlerContext,
    method: std.http.Method,
    body: []const u8,
) !TestHttpResponse {
    if (method == .POST) {
        const response_body = try handlePost(allocator, context, body);

        return .{
            .status = .ok,
            .body = response_body,
            .content_type = "application/json",
            .access_control_allow_origin = if (config.cors_enabled) "*" else null,
        };
    }

    if (method == .OPTIONS and config.cors_enabled) {
        return .{
            .status = .no_content,
            .body = null,
            .access_control_allow_origin = "*",
            .access_control_allow_methods = "POST, OPTIONS",
            .access_control_allow_headers = "content-type",
        };
    }

    return .{
        .status = .method_not_allowed,
        .body = null,
        .access_control_allow_origin = if (config.cors_enabled) "*" else null,
    };
}

fn handleConnection(
    allocator: std.mem.Allocator,
    config: ServerConfig,
    context: *const handlers.HandlerContext,
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

        try handleRequest(allocator, config, context, &request);
    }
}

fn handleRequest(
    allocator: std.mem.Allocator,
    config: ServerConfig,
    context: *const handlers.HandlerContext,
    request: *std.http.Server.Request,
) !void {
    if (request.head.method == .POST) {
        const request_body = try readRequestBody(allocator, request);
        defer allocator.free(request_body);

        const response_body = try handlePost(allocator, context, request_body);
        defer allocator.free(response_body);

        const headers = if (config.cors_enabled)
            &[_]std.http.Header{ json_content_type_header, cors_allow_origin_header }
        else
            &[_]std.http.Header{json_content_type_header};

        try request.respond(response_body, .{
            .status = .ok,
            .extra_headers = headers,
        });
        return;
    }

    if (request.head.method == .OPTIONS and config.cors_enabled) {
        try request.respond("", .{
            .status = .no_content,
            .extra_headers = &[_]std.http.Header{
                cors_allow_origin_header,
                cors_allow_methods_header,
                cors_allow_headers_header,
            },
        });
        return;
    }

    const headers = if (config.cors_enabled)
        &[_]std.http.Header{cors_allow_origin_header}
    else
        &[_]std.http.Header{};

    try request.respond("Method not allowed", .{
        .status = .method_not_allowed,
        .extra_headers = headers,
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
    context: *const handlers.HandlerContext,
    body: []const u8,
) ![]u8 {
    var parsed_body = envelope.parseBody(allocator, body) catch |err| switch (err) {
        error.ParseError => return envelope.writeError(allocator, null, -32700, "Parse error"),
        error.InvalidRequest => return envelope.writeError(allocator, null, -32600, "Invalid request"),
        else => return err,
    };
    defer parsed_body.deinit(allocator);

    return switch (parsed_body) {
        .single => |request| router.route(allocator, context, request),
        .batch => |requests| router.routeBatch(allocator, context, requests),
    };
}
