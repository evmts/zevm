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

pub const MAX_REQUEST_BODY_BYTES: usize = 1024 * 1024;
pub const MAX_HTTP_HEAD_BYTES: usize = 8192;
pub const DEFAULT_MAX_ACTIVE_CONNECTIONS: usize = 64;
pub const DEFAULT_READ_TIMEOUT_MS: u32 = 15_000;
pub const DEFAULT_WRITE_TIMEOUT_MS: u32 = 15_000;

const CONNECTION_SLOT_WAIT_NS = 50 * std.time.ns_per_ms;

pub const TransportLimits = struct {
    max_active_connections: usize = DEFAULT_MAX_ACTIVE_CONNECTIONS,
    read_timeout_ms: u32 = DEFAULT_READ_TIMEOUT_MS,
    write_timeout_ms: u32 = DEFAULT_WRITE_TIMEOUT_MS,
    max_request_body_bytes: usize = MAX_REQUEST_BODY_BYTES,
};

const json_content_type_header = std.http.Header{
    .name = "content-type",
    .value = "application/json",
};

pub fn run(allocator: std.mem.Allocator, server_config: ServerConfig, handlers: *const dispatcher.HandlerRegistry) !void {
    var listener = try RpcServer.init(allocator, server_config, handlers, .{});
    defer listener.deinit();

    try listener.run();
}

pub const RpcServer = struct {
    allocator: std.mem.Allocator,
    tcp_server: std.net.Server,
    handlers: *const dispatcher.HandlerRegistry,
    limits: TransportLimits,
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    accept_thread: ?std.Thread = null,
    serve_error: ?anyerror = null,
    connection_slots: std.Thread.Semaphore,
    active_mutex: std.Thread.Mutex = .{},
    active_cond: std.Thread.Condition = .{},
    active_head: ?*ConnectionContext = null,
    active_connections: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        server_config: ServerConfig,
        handlers: *const dispatcher.HandlerRegistry,
        limits: TransportLimits,
    ) !RpcServer {
        std.debug.assert(limits.max_active_connections > 0);
        std.debug.assert(limits.max_request_body_bytes > 0);

        const listen_address = try std.net.Address.parseIp(server_config.host, server_config.port);
        const tcp_server = try listen_address.listen(.{ .reuse_address = true });

        return .{
            .allocator = allocator,
            .tcp_server = tcp_server,
            .handlers = handlers,
            .limits = limits,
            .connection_slots = .{ .permits = limits.max_active_connections },
        };
    }

    pub fn run(self: *RpcServer) !void {
        self.logListenerBound();
        self.acceptLoop();
        self.waitForConnections();
    }

    pub fn start(self: *RpcServer) !void {
        std.debug.assert(self.accept_thread == null);
        self.logListenerBound();
        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
    }

    pub fn stop(self: *RpcServer) void {
        self.stop_requested.store(true, .seq_cst);
        self.unblockAccept();
        self.shutdownActiveConnections();

        if (self.accept_thread) |thread| {
            thread.join();
            self.accept_thread = null;
        }

        self.waitForConnections();
        log.info(.rpc, "listener stopped address={any}", .{self.address()});
    }

    pub fn deinit(self: *RpcServer) void {
        self.stop();
        self.tcp_server.deinit();
    }

    pub fn address(self: *const RpcServer) std.net.Address {
        return self.tcp_server.listen_address;
    }

    pub fn activeConnectionCountForTest(self: *RpcServer) usize {
        return self.activeConnectionCount();
    }

    fn activeConnectionCount(self: *RpcServer) usize {
        self.active_mutex.lock();
        defer self.active_mutex.unlock();
        return self.active_connections;
    }

    fn acceptLoop(self: *RpcServer) void {
        while (!self.stop_requested.load(.seq_cst)) {
            if (!self.waitForConnectionSlot()) break;

            const connection = self.tcp_server.accept() catch |err| {
                self.connection_slots.post();
                if (self.stop_requested.load(.seq_cst)) break;

                self.serve_error = err;
                log.warn(.rpc, "accept failed address={any} error={s}", .{ self.address(), @errorName(err) });
                continue;
            };

            if (self.stop_requested.load(.seq_cst)) {
                connection.stream.close();
                self.connection_slots.post();
                break;
            }

            self.spawnConnection(connection) catch |err| {
                self.serve_error = err;
                log.warn(.rpc, "connection spawn failed remote={any} error={s}", .{ connection.address, @errorName(err) });
            };
        }
    }

    fn waitForConnectionSlot(self: *RpcServer) bool {
        while (!self.stop_requested.load(.seq_cst)) {
            self.connection_slots.timedWait(CONNECTION_SLOT_WAIT_NS) catch |err| switch (err) {
                error.Timeout => continue,
            };
            return true;
        }

        return false;
    }

    fn spawnConnection(self: *RpcServer, connection: std.net.Server.Connection) !void {
        var registered = false;
        errdefer if (!registered) self.connection_slots.post();
        errdefer connection.stream.close();

        const ctx = try self.allocator.create(ConnectionContext);
        errdefer self.allocator.destroy(ctx);
        ctx.* = .{
            .server = self,
            .connection = connection,
        };

        self.registerConnection(ctx);
        registered = true;
        errdefer self.unregisterConnection(ctx);

        const thread = try std.Thread.spawn(.{}, connectionThread, .{ctx});
        thread.detach();

        log.info(.rpc, "connection accepted remote={any} active_connections={}", .{
            connection.address,
            self.activeConnectionCount(),
        });
    }

    fn registerConnection(self: *RpcServer, ctx: *ConnectionContext) void {
        self.active_mutex.lock();
        defer self.active_mutex.unlock();

        ctx.prev = null;
        ctx.next = self.active_head;
        if (self.active_head) |head| head.prev = ctx;
        self.active_head = ctx;
        self.active_connections += 1;
    }

    fn unregisterConnection(self: *RpcServer, ctx: *ConnectionContext) void {
        self.active_mutex.lock();
        defer self.active_mutex.unlock();

        if (ctx.prev) |prev| {
            prev.next = ctx.next;
        } else if (self.active_head == ctx) {
            self.active_head = ctx.next;
        }

        if (ctx.next) |next| next.prev = ctx.prev;
        ctx.prev = null;
        ctx.next = null;

        std.debug.assert(self.active_connections > 0);
        self.active_connections -= 1;
        self.connection_slots.post();
        self.active_cond.broadcast();
    }

    fn waitForConnections(self: *RpcServer) void {
        self.active_mutex.lock();
        defer self.active_mutex.unlock();

        while (self.active_connections != 0) {
            self.active_cond.wait(&self.active_mutex);
        }
    }

    fn shutdownActiveConnections(self: *RpcServer) void {
        self.active_mutex.lock();
        defer self.active_mutex.unlock();

        var node = self.active_head;
        while (node) |ctx| : (node = ctx.next) {
            std.posix.shutdown(ctx.connection.stream.handle, .both) catch {};
        }
    }

    fn unblockAccept(self: *const RpcServer) void {
        const stream = std.net.tcpConnectToAddress(self.address()) catch return;
        stream.close();
    }

    fn logListenerBound(self: *const RpcServer) void {
        log.info(.rpc, "listener bound address={any} max_active_connections={} read_timeout_ms={} write_timeout_ms={} max_request_body_bytes={}", .{
            self.address(),
            self.limits.max_active_connections,
            self.limits.read_timeout_ms,
            self.limits.write_timeout_ms,
            self.limits.max_request_body_bytes,
        });
    }
};

const ConnectionContext = struct {
    server: *RpcServer,
    connection: std.net.Server.Connection,
    prev: ?*ConnectionContext = null,
    next: ?*ConnectionContext = null,
};

pub const TestListener = struct {
    server: RpcServer,

    pub fn init(
        allocator: std.mem.Allocator,
        host: []const u8,
        handlers: *const dispatcher.HandlerRegistry,
    ) !TestListener {
        return initWithLimits(allocator, host, handlers, .{});
    }

    pub fn initWithLimits(
        allocator: std.mem.Allocator,
        host: []const u8,
        handlers: *const dispatcher.HandlerRegistry,
        limits: TransportLimits,
    ) !TestListener {
        return .{
            .server = try RpcServer.init(allocator, .{
                .host = host,
                .port = 0,
            }, handlers, limits),
        };
    }

    pub fn start(self: *TestListener) !void {
        // The accept thread stores this pointer; start only after final placement.
        try self.server.start();
    }

    pub fn address(self: *const TestListener) std.net.Address {
        return self.server.address();
    }

    pub fn stop(self: *TestListener) void {
        self.server.stop();
    }

    pub fn deinit(self: *TestListener) void {
        self.server.deinit();
    }

    pub fn activeConnectionCountForTest(self: *TestListener) usize {
        return self.server.activeConnectionCountForTest();
    }
};

fn connectionThread(ctx: *ConnectionContext) void {
    const start_ns = std.time.nanoTimestamp();
    defer ctx.server.allocator.destroy(ctx);
    defer ctx.connection.stream.close();
    defer ctx.server.unregisterConnection(ctx);

    setConnectionTimeouts(ctx.connection.stream, ctx.server.limits) catch |err| {
        log.warn(.rpc, "connection timeout setup failed remote={any} error={s}", .{ ctx.connection.address, @errorName(err) });
    };

    handleConnection(ctx.server.allocator, ctx.server.handlers, ctx.connection, null, ctx.server.limits) catch |err| {
        if (!ctx.server.stop_requested.load(.seq_cst)) {
            log.warn(.rpc, "connection failed remote={any} error={s}", .{ ctx.connection.address, @errorName(err) });
        }
    };

    log.info(.rpc, "connection closed remote={any} duration_us={}", .{
        ctx.connection.address,
        @divTrunc(elapsedSince(start_ns), 1000),
    });
}

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

    if (request.body.len > MAX_REQUEST_BODY_BYTES) {
        return .{
            .status = .payload_too_large,
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
    dispatch_mutex: ?*std.Thread.Mutex,
    limits: TransportLimits,
) !void {
    var receive_buffer: [MAX_HTTP_HEAD_BYTES]u8 = undefined;
    var send_buffer: [8192]u8 = undefined;
    var connection_reader = connection.stream.reader(&receive_buffer);
    var connection_writer = connection.stream.writer(&send_buffer);
    var http_server = std.http.Server.init(connection_reader.interface(), &connection_writer.interface);

    while (http_server.reader.state == .ready) {
        var request = http_server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => return err,
        };

        const keep_alive = try handleRequest(allocator, handlers, &request, dispatch_mutex, limits);
        if (!keep_alive) return;
    }
}

fn handleRequest(
    allocator: std.mem.Allocator,
    handlers: *const dispatcher.HandlerRegistry,
    request: *std.http.Server.Request,
    dispatch_mutex: ?*std.Thread.Mutex,
    limits: TransportLimits,
) !bool {
    if (!isRootTarget(request.head.target)) {
        try request.respond("", .{
            .status = .not_found,
        });
        return true;
    }

    if (request.head.method != .POST) {
        try request.respond("", .{
            .status = .method_not_allowed,
        });
        return true;
    }

    if (!isJsonContentType(request.head.content_type)) {
        try request.respond("", .{
            .status = .unsupported_media_type,
        });
        return true;
    }

    if (request.head.content_length) |content_length| {
        if (content_length > limits.max_request_body_bytes) {
            try request.respond("", .{
                .status = .payload_too_large,
            });
            return false;
        }
    }

    const request_body = readRequestBody(allocator, request, limits.max_request_body_bytes) catch |err| switch (err) {
        error.StreamTooLong => {
            try request.respond("", .{
                .status = .payload_too_large,
            });
            return false;
        },
        else => return err,
    };
    defer allocator.free(request_body);

    const response_body = blk: {
        if (dispatch_mutex) |mutex| {
            mutex.lock();
            defer mutex.unlock();
            break :blk try handlePost(allocator, request_body, handlers);
        }

        break :blk try handlePost(allocator, request_body, handlers);
    };

    if (response_body) |body| {
        defer allocator.free(body);

        try request.respond(body, .{
            .status = .ok,
            .extra_headers = &[_]std.http.Header{json_content_type_header},
        });
        return true;
    }

    try request.respond("", .{
        .status = .no_content,
    });
    return true;
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

fn readRequestBody(allocator: std.mem.Allocator, request: *std.http.Server.Request, max_request_body_bytes: usize) ![]u8 {
    var reader_buffer: [4096]u8 = undefined;
    const reader = try request.readerExpectContinue(&reader_buffer);

    var request_body = std.ArrayList(u8).empty;
    errdefer request_body.deinit(allocator);

    try reader.appendRemaining(allocator, &request_body, .limited(max_request_body_bytes));

    return request_body.toOwnedSlice(allocator);
}

fn setConnectionTimeouts(stream: std.net.Stream, limits: TransportLimits) !void {
    if (builtin.os.tag == .wasi) return;

    if (builtin.os.tag == .windows) {
        const read_timeout_ms = limits.read_timeout_ms;
        const write_timeout_ms = limits.write_timeout_ms;
        try std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&read_timeout_ms));
        try std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&write_timeout_ms));
        return;
    }

    const read_timeout = timevalFromMillis(limits.read_timeout_ms);
    const write_timeout = timevalFromMillis(limits.write_timeout_ms);
    try std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&read_timeout));
    try std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&write_timeout));
}

fn timevalFromMillis(milliseconds: u32) std.posix.timeval {
    return .{
        .sec = @intCast(milliseconds / std.time.ms_per_s),
        .usec = @intCast((milliseconds % std.time.ms_per_s) * 1000),
    };
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
