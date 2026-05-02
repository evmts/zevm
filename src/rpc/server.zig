const std = @import("std");
const builtin = @import("builtin");
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

pub const TestHttpRequest = struct {
    method: std.http.Method,
    target: []const u8 = "/",
    content_type: ?[]const u8 = "application/json",
    body: []const u8 = "",
};

pub const RequestTelemetryFields = struct {
    method: []const u8,
    id_present: bool,
    batch_size: usize,
    status: []const u8,
    error_code: ?i32,
    duration_ns: i128,
    mode: []const u8,
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

pub const TestListener = struct {
    allocator: std.mem.Allocator,
    tcp_server: std.net.Server,
    handlers: *const dispatcher.HandlerRegistry,
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    serve_error: ?anyerror = null,

    pub fn init(
        allocator: std.mem.Allocator,
        host: []const u8,
        handlers: *const dispatcher.HandlerRegistry,
    ) !TestListener {
        const listen_address = try std.net.Address.parseIp(host, 0);
        const tcp_server = try listen_address.listen(.{ .reuse_address = true });
        return .{
            .allocator = allocator,
            .tcp_server = tcp_server,
            .handlers = handlers,
        };
    }

    pub fn start(self: *TestListener) !void {
        // The accept thread stores this pointer; start only after final placement.
        std.debug.assert(self.thread == null);
        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
    }

    pub fn address(self: *const TestListener) std.net.Address {
        return self.tcp_server.listen_address;
    }

    pub fn deinit(self: *TestListener) void {
        self.stop();
        self.tcp_server.deinit();
    }

    fn stop(self: *TestListener) void {
        const thread = self.thread orelse return;
        self.stop_requested.store(true, .seq_cst);
        self.unblockAccept();
        thread.join();
        self.thread = null;
    }

    fn unblockAccept(self: *const TestListener) void {
        const stream = std.net.tcpConnectToAddress(self.address()) catch return;
        stream.close();
    }

    fn acceptLoop(self: *TestListener) void {
        while (!self.stop_requested.load(.seq_cst)) {
            const connection = self.tcp_server.accept() catch |err| {
                if (self.stop_requested.load(.seq_cst)) break;
                self.serve_error = err;
                continue;
            };

            if (self.stop_requested.load(.seq_cst)) {
                connection.stream.close();
                break;
            }

            handleConnection(self.allocator, self.handlers, connection) catch |err| {
                if (self.stop_requested.load(.seq_cst)) break;
                self.serve_error = err;
            };
        }
    }
};

pub fn handleHttpRequestForTest(
    allocator: std.mem.Allocator,
    method: std.http.Method,
    body: []const u8,
    handlers: *const dispatcher.HandlerRegistry,
) !TestHttpResponse {
    return handleHttpRequestForTestWithOptions(allocator, .{
        .method = method,
        .body = body,
    }, handlers);
}

pub fn handleHttpRequestForTestWithOptions(
    allocator: std.mem.Allocator,
    request: TestHttpRequest,
    handlers: *const dispatcher.HandlerRegistry,
) !TestHttpResponse {
    if (!isRootTarget(request.target)) {
        return .{
            .status = .not_found,
            .body = null,
        };
    }

    if (request.method != .POST) {
        return .{
            .status = .method_not_allowed,
            .body = null,
        };
    }

    if (!isJsonContentType(request.content_type)) {
        return .{
            .status = .unsupported_media_type,
            .body = null,
        };
    }

    if (try handlePost(allocator, request.body, handlers)) |response_body| {
        return .{
            .status = .ok,
            .body = response_body,
            .content_type = "application/json",
        };
    }

    return .{
        .status = .no_content,
        .body = null,
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
    if (!isRootTarget(request.head.target)) {
        try request.respond("", .{
            .status = .not_found,
        });
        return;
    }

    if (request.head.method != .POST) {
        try request.respond("", .{
            .status = .method_not_allowed,
        });
        return;
    }

    if (!isJsonContentType(request.head.content_type)) {
        try request.respond("", .{
            .status = .unsupported_media_type,
        });
        return;
    }

    const request_body = try readRequestBody(allocator, request);
    defer allocator.free(request_body);

    if (try handlePost(allocator, request_body, handlers)) |response_body| {
        defer allocator.free(response_body);

        try request.respond(response_body, .{
            .status = .ok,
            .extra_headers = &[_]std.http.Header{json_content_type_header},
        });
        return;
    }

    try request.respond("", .{
        .status = .no_content,
    });
}

fn isRootTarget(target: []const u8) bool {
    return std.mem.eql(u8, target, "/");
}

fn isJsonContentType(content_type: ?[]const u8) bool {
    const raw_content_type = content_type orelse return false;
    var parts = std.mem.splitScalar(u8, raw_content_type, ';');
    const media_type = std.mem.trim(u8, parts.first(), " \t");

    return std.ascii.eqlIgnoreCase(media_type, "application/json");
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
) !?[]u8 {
    const start_ns = std.time.nanoTimestamp();
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        logRequestTelemetry(allocator, .{
            .method = "<parse>",
            .id_present = false,
            .batch_size = 0,
            .status = "error",
            .error_code = jsonrpc.envelope.ErrorCode.PARSE_ERROR,
            .duration_ns = elapsedSince(start_ns),
            .mode = activeModeName(handlers),
        });
        return @as(?[]u8, try writeErrorResponse(allocator, null, jsonrpc.envelope.ErrorCode.PARSE_ERROR, "Parse error"));
    };
    defer parsed.deinit();

    var request_batch = jsonrpc.envelope.parseSingleOrBatch(allocator, body) catch {
        logRequestTelemetry(allocator, .{
            .method = "<invalid>",
            .id_present = false,
            .batch_size = 0,
            .status = "error",
            .error_code = jsonrpc.envelope.ErrorCode.INVALID_REQUEST,
            .duration_ns = elapsedSince(start_ns),
            .mode = activeModeName(handlers),
        });
        return @as(?[]u8, try writeErrorResponse(allocator, null, jsonrpc.envelope.ErrorCode.INVALID_REQUEST, "Invalid Request"));
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
) !?[]u8 {
    const start_ns = std.time.nanoTimestamp();
    if (request.invalid) {
        logRequestTelemetry(allocator, .{
            .method = "<invalid>",
            .id_present = request.id != null,
            .batch_size = 1,
            .status = "error",
            .error_code = jsonrpc.envelope.ErrorCode.INVALID_REQUEST,
            .duration_ns = elapsedSince(start_ns),
            .mode = activeModeName(handlers),
        });
        return @as(?[]u8, try writeErrorResponse(allocator, null, jsonrpc.envelope.ErrorCode.INVALID_REQUEST, "Invalid Request"));
    }

    var response = try dispatcher.dispatch(allocator, request, handlers);
    defer response.deinit(allocator);

    if (isNotification(request)) {
        logRequestTelemetry(allocator, .{
            .method = request.method,
            .id_present = false,
            .batch_size = 1,
            .status = "notification",
            .error_code = responseErrorCode(response),
            .duration_ns = elapsedSince(start_ns),
            .mode = activeModeName(handlers),
        });
        return null;
    }

    const response_body = try stringifyResponse(allocator, response);
    logRequestTelemetry(allocator, .{
        .method = request.method,
        .id_present = true,
        .batch_size = 1,
        .status = responseStatus(response),
        .error_code = responseErrorCode(response),
        .duration_ns = elapsedSince(start_ns),
        .mode = activeModeName(handlers),
    });
    return @as(?[]u8, response_body);
}

fn handleBatch(
    allocator: std.mem.Allocator,
    batch: []jsonrpc.envelope.RequestEnvelope,
    handlers: *const dispatcher.HandlerRegistry,
) !?[]u8 {
    var response_bytes = std.ArrayList(u8).empty;
    errdefer response_bytes.deinit(allocator);

    try response_bytes.append(allocator, '[');
    var wrote_response = false;
    for (batch) |request| {
        const start_ns = std.time.nanoTimestamp();
        if (isNotification(request)) {
            var response = try dispatcher.dispatch(allocator, request, handlers);
            defer response.deinit(allocator);
            logRequestTelemetry(allocator, .{
                .method = request.method,
                .id_present = false,
                .batch_size = batch.len,
                .status = "notification",
                .error_code = responseErrorCode(response),
                .duration_ns = elapsedSince(start_ns),
                .mode = activeModeName(handlers),
            });
            continue;
        }

        if (wrote_response) {
            try response_bytes.append(allocator, ',');
        }

        const item_bytes = if (request.invalid) blk: {
            const bytes = try writeErrorResponse(allocator, null, jsonrpc.envelope.ErrorCode.INVALID_REQUEST, "Invalid Request");
            logRequestTelemetry(allocator, .{
                .method = "<invalid>",
                .id_present = request.id != null,
                .batch_size = batch.len,
                .status = "error",
                .error_code = jsonrpc.envelope.ErrorCode.INVALID_REQUEST,
                .duration_ns = elapsedSince(start_ns),
                .mode = activeModeName(handlers),
            });
            break :blk bytes;
        } else blk: {
            var response = try dispatcher.dispatch(allocator, request, handlers);
            defer response.deinit(allocator);

            const bytes = try stringifyResponse(allocator, response);
            logRequestTelemetry(allocator, .{
                .method = request.method,
                .id_present = request.id != null,
                .batch_size = batch.len,
                .status = responseStatus(response),
                .error_code = responseErrorCode(response),
                .duration_ns = elapsedSince(start_ns),
                .mode = activeModeName(handlers),
            });
            break :blk bytes;
        };
        defer allocator.free(item_bytes);

        try response_bytes.appendSlice(allocator, item_bytes);
        wrote_response = true;
    }

    if (!wrote_response) {
        response_bytes.deinit(allocator);
        return null;
    }
    try response_bytes.append(allocator, ']');

    return @as(?[]u8, try response_bytes.toOwnedSlice(allocator));
}

fn isNotification(request: jsonrpc.envelope.RequestEnvelope) bool {
    return !request.invalid and request.id == null;
}

fn responseStatus(response: jsonrpc.envelope.ResponseEnvelope) []const u8 {
    return if (response.error_value == null) "success" else "error";
}

fn responseErrorCode(response: jsonrpc.envelope.ResponseEnvelope) ?i32 {
    return if (response.error_value) |error_value| error_value.code else null;
}

fn elapsedSince(start_ns: i128) i128 {
    const elapsed = std.time.nanoTimestamp() - start_ns;
    return if (elapsed < 0) 0 else elapsed;
}

fn activeModeName(handlers: *const dispatcher.HandlerRegistry) []const u8 {
    if (handlers.mode_name) |mode_name| return mode_name(handlers.context);
    return "unknown";
}

fn logRequestTelemetry(
    allocator: std.mem.Allocator,
    fields: RequestTelemetryFields,
) void {
    if (isTestBuild()) return;

    const message = formatRequestTelemetry(allocator, fields) catch return;
    defer allocator.free(message);
    log.info(.rpc, "{s}", .{message});
}

fn isTestBuild() bool {
    if (builtin.is_test) return true;
    const root = @import("root");
    return if (@hasDecl(root, "is_test")) root.is_test else false;
}

fn formatRequestTelemetry(allocator: std.mem.Allocator, fields: RequestTelemetryFields) ![]u8 {
    if (fields.error_code) |code| {
        return std.fmt.allocPrint(
            allocator,
            "rpc_request method={s} id_present={} batch_size={} status={s} error_code={} duration_us={} mode={s}",
            .{ fields.method, fields.id_present, fields.batch_size, fields.status, code, @divTrunc(fields.duration_ns, 1000), fields.mode },
        );
    }

    return std.fmt.allocPrint(
        allocator,
        "rpc_request method={s} id_present={} batch_size={} status={s} error_code=null duration_us={} mode={s}",
        .{ fields.method, fields.id_present, fields.batch_size, fields.status, @divTrunc(fields.duration_ns, 1000), fields.mode },
    );
}

pub fn formatRequestTelemetryForTest(allocator: std.mem.Allocator, fields: RequestTelemetryFields) ![]u8 {
    return formatRequestTelemetry(allocator, fields);
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
