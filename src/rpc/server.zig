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
    /// Listener options to emulate. Defaults match the public listener, which
    /// rejects `engine_*` methods.
    options: RpcServer.Options = .{},
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

/// Public listener body cap.
pub const DEFAULT_MAX_BODY_BYTES: usize = 8 * 1024 * 1024;
/// Engine listener body cap. EIP-7934 caps an RLP block at ~10 MiB; hex JSON
/// encoding more than doubles that.
pub const ENGINE_MAX_BODY_BYTES: usize = 24 * 1024 * 1024;
/// Deprecated name for `DEFAULT_MAX_BODY_BYTES`.
pub const MAX_REQUEST_BODY_BYTES: usize = DEFAULT_MAX_BODY_BYTES;
pub const DEFAULT_MAX_JSON_DEPTH: usize = 64;
pub const DEFAULT_MAX_BATCH_SIZE: usize = 256;
pub const MAX_HTTP_HEAD_BYTES: usize = 8192;
pub const DEFAULT_MAX_ACTIVE_CONNECTIONS: usize = 64;
pub const MAX_CONNECTIONS_PER_IP: usize = 16;
pub const DEFAULT_READ_TIMEOUT_MS: u32 = 15_000;
pub const DEFAULT_WRITE_TIMEOUT_MS: u32 = 15_000;
/// Test fixture secret (also Hive's default). Production startup never uses it:
/// `main` loads `--authrpc.jwtsecret` or generates a CSPRNG secret.
pub const DEFAULT_ENGINE_JWT_SECRET = "secretsecretsecretsecretsecretse";
pub const ENGINE_JWT_SECRET_BYTES: usize = 32;
pub const DEFAULT_ENGINE_JWT_MAX_TIME_DRIFT_SECONDS: i64 = 60;
pub const DEFAULT_CORS_ALLOW_ORIGIN: ?[]const u8 = null;
pub const DEFAULT_MAX_JSON_VALUES: usize = 100_000;

const CONNECTION_SLOT_WAIT_NS = 50 * std.time.ns_per_ms;
const ACCEPT_BACKOFF_INITIAL_NS = 5 * std.time.ns_per_ms;
const ACCEPT_BACKOFF_MAX_NS = 500 * std.time.ns_per_ms;
pub const REQUEST_HEAD_DEADLINE_MS: i64 = 10_000;
pub const REQUEST_BODY_DEADLINE_MS: i64 = 30_000;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

/// Deprecated name for `RpcServer.Options`.
pub const TransportLimits = RpcServer.Options;

/// Per-request JSON-RPC policy applied before dispatch.
pub const RequestPolicy = struct {
    /// In-process callers (`handlePost`, C bindings) are trusted and may call
    /// `engine_*`. Network listeners derive this from `RpcServer.Options`.
    allow_engine_methods: bool = true,
    allow_dev_methods: bool = true,
    allow_testing_build_block: bool = false,
    max_json_values: usize = DEFAULT_MAX_JSON_VALUES,
    max_json_depth: usize = DEFAULT_MAX_JSON_DEPTH,
    max_batch_size: usize = DEFAULT_MAX_BATCH_SIZE,
};

pub const InitError = error{
    EngineJwtSecretRequired,
    InsecureEngineJwtSecret,
};

const json_content_type_header = std.http.Header{
    .name = "content-type",
    .value = "application/json",
};
const jwt_authenticate_header = std.http.Header{
    .name = "www-authenticate",
    .value = "Bearer",
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
    limits: Options,
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    accept_thread: ?std.Thread = null,
    serve_error_mutex: std.Thread.Mutex = .{},
    serve_error: ?anyerror = null,
    connection_slots: std.Thread.Semaphore,
    active_mutex: std.Thread.Mutex = .{},
    active_cond: std.Thread.Condition = .{},
    active_head: ?*ConnectionContext = null,
    active_connections: usize = 0,

    pub const Options = struct {
        max_active_connections: usize = DEFAULT_MAX_ACTIVE_CONNECTIONS,
        read_timeout_ms: u32 = DEFAULT_READ_TIMEOUT_MS,
        write_timeout_ms: u32 = DEFAULT_WRITE_TIMEOUT_MS,
        max_body_bytes: usize = DEFAULT_MAX_BODY_BYTES,
        /// Deprecated alias for `max_body_bytes`; overrides it when set.
        max_request_body_bytes: ?usize = null,
        max_json_depth: usize = DEFAULT_MAX_JSON_DEPTH,
        max_batch_size: usize = DEFAULT_MAX_BATCH_SIZE,
        /// Public listeners keep this false and answer `engine_*` with -32601.
        /// Engine listeners set it true and must also set `jwt_secret`.
        allow_engine_methods: bool = false,
        allow_dev_methods: bool = true,
        allow_testing_build_block: bool = false,
        max_json_values: usize = DEFAULT_MAX_JSON_VALUES,
        jwt_secret: ?[]const u8 = null,
        jwt_max_time_drift_seconds: i64 = DEFAULT_ENGINE_JWT_MAX_TIME_DRIFT_SECONDS,
        /// `Access-Control-Allow-Origin` value; null disables CORS headers.
        cors_allow_origin: ?[]const u8 = DEFAULT_CORS_ALLOW_ORIGIN,
        /// When set, the listener validates the Host header against loopback
        /// names and this value. Set automatically from the bind host when
        /// it resolves to a loopback address. Null disables Host validation.
        validate_host: ?[]const u8 = null,

        pub fn bodyLimit(self: Options) usize {
            return self.max_request_body_bytes orelse self.max_body_bytes;
        }

        pub fn requestPolicy(self: Options) RequestPolicy {
            return .{
                .allow_engine_methods = self.allow_engine_methods,
                .allow_dev_methods = self.allow_dev_methods,
                .allow_testing_build_block = self.allow_testing_build_block,
                .max_json_values = self.max_json_values,
                .max_json_depth = self.max_json_depth,
                .max_batch_size = self.max_batch_size,
            };
        }
    };

    pub fn init(
        allocator: std.mem.Allocator,
        server_config: ServerConfig,
        handlers: *const dispatcher.HandlerRegistry,
        limits: Options,
    ) !RpcServer {
        std.debug.assert(limits.max_active_connections > 0);
        std.debug.assert(limits.bodyLimit() > 0);
        if (limits.jwt_secret != null) {
            std.debug.assert(limits.jwt_max_time_drift_seconds >= 0);
        }
        try validateEngineAuth(limits);

        const listen_address = try parseListenAddress(server_config.host, server_config.port);
        const tcp_server = try listen_address.listen(.{ .reuse_address = true });

        var effective_limits = limits;
        if (effective_limits.validate_host == null and isLoopbackAddress(listen_address)) {
            effective_limits.validate_host = server_config.host;
        }

        return .{
            .allocator = allocator,
            .tcp_server = tcp_server,
            .handlers = handlers,
            .limits = effective_limits,
            .connection_slots = .{ .permits = effective_limits.max_active_connections },
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

    /// Ask a running `run()` loop to return. Safe to call from another thread.
    pub fn requestShutdown(self: *RpcServer) void {
        self.stop_requested.store(true, .seq_cst);
        self.unblockAccept();
        self.shutdownActiveConnections();
    }

    pub fn stop(self: *RpcServer) void {
        self.stop_requested.store(true, .seq_cst);
        self.unblockAccept();

        if (self.accept_thread) |thread| {
            thread.join();
            self.accept_thread = null;
        }

        self.shutdownActiveConnections();
        self.waitForConnections();
        log.info(.rpc, "listener stopped address={any}", .{self.address()});
    }

    pub fn deinit(self: *RpcServer) void {
        self.stop();
        self.tcp_server.deinit();
    }

    pub fn boundHost(self: *const RpcServer, buffer: *[64]u8) []const u8 {
        const endpoint = std.fmt.bufPrint(buffer, "{f}", .{self.address()}) catch unreachable;
        const port_separator = std.mem.lastIndexOfScalar(u8, endpoint, ':').?;
        return std.mem.trim(u8, endpoint[0..port_separator], "[]");
    }

    pub fn address(self: *const RpcServer) std.net.Address {
        return self.tcp_server.listen_address;
    }

    pub fn lastServeError(self: *RpcServer) ?anyerror {
        self.serve_error_mutex.lock();
        defer self.serve_error_mutex.unlock();
        return self.serve_error;
    }

    pub fn activeConnectionCountForTest(self: *RpcServer) usize {
        return self.activeConnectionCount();
    }

    fn setServeError(self: *RpcServer, err: anyerror) void {
        self.serve_error_mutex.lock();
        defer self.serve_error_mutex.unlock();
        self.serve_error = err;
    }

    fn activeConnectionCount(self: *RpcServer) usize {
        self.active_mutex.lock();
        defer self.active_mutex.unlock();
        return self.active_connections;
    }

    fn acceptLoop(self: *RpcServer) void {
        var backoff_ns: u64 = 0;
        while (!self.stop_requested.load(.seq_cst)) {
            if (!self.waitForConnectionSlot()) break;

            const connection = self.tcp_server.accept() catch |err| {
                self.connection_slots.post();
                if (self.stop_requested.load(.seq_cst)) break;

                self.setServeError(err);
                log.warn(.rpc, "accept failed address={any} error={s}", .{ self.address(), @errorName(err) });
                // Persistent failures such as EMFILE would otherwise spin the CPU.
                backoff_ns = nextAcceptBackoff(backoff_ns);
                std.Thread.sleep(backoff_ns);
                continue;
            };
            backoff_ns = 0;

            if (self.stop_requested.load(.seq_cst)) {
                connection.stream.close();
                self.connection_slots.post();
                break;
            }

            self.spawnConnection(connection) catch |err| {
                self.setServeError(err);
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
        errdefer if (!registered) {
            connection.stream.close();
            self.connection_slots.post();
        };

        if (self.countConnectionsFromIp(connection.address) >= MAX_CONNECTIONS_PER_IP) {
            log.warn(.rpc, "per-ip connection limit reached remote={any} limit={}", .{ connection.address, MAX_CONNECTIONS_PER_IP });
            connection.stream.close();
            self.connection_slots.post();
            return;
        }

        const ctx = try self.allocator.create(ConnectionContext);
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

    fn countConnectionsFromIp(self: *RpcServer, remote: std.net.Address) usize {
        self.active_mutex.lock();
        defer self.active_mutex.unlock();
        var count: usize = 0;
        var node = self.active_head;
        while (node) |ctx| : (node = ctx.next) {
            if (sameIp(ctx.connection.address, remote)) count += 1;
        }
        return count;
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
        ctx.connection.stream.close();
        self.allocator.destroy(ctx);

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
        const stream = std.net.tcpConnectToAddress(connectableAddress(self.address())) catch return;
        stream.close();
    }

    fn logListenerBound(self: *const RpcServer) void {
        log.info(.rpc, "listener bound address={any} max_active_connections={} read_timeout_ms={} write_timeout_ms={} max_request_body_bytes={} max_json_depth={} max_batch_size={} allow_engine_methods={}", .{
            self.address(),
            self.limits.max_active_connections,
            self.limits.read_timeout_ms,
            self.limits.write_timeout_ms,
            self.limits.bodyLimit(),
            self.limits.max_json_depth,
            self.limits.max_batch_size,
            self.limits.allow_engine_methods,
        });
    }
};

fn validateEngineAuth(limits: RpcServer.Options) InitError!void {
    if (!limits.allow_engine_methods) return;
    const secret = limits.jwt_secret orelse return error.EngineJwtSecretRequired;
    // Engine API spec: a 256-bit secret. Choosing the secret (file or CSPRNG)
    // is the caller's job; Hive legitimately supplies the fixture bytes.
    if (secret.len < ENGINE_JWT_SECRET_BYTES) return error.InsecureEngineJwtSecret;
}

pub fn validateEngineAuthForTest(limits: RpcServer.Options) InitError!void {
    return validateEngineAuth(limits);
}

fn nextAcceptBackoff(current_ns: u64) u64 {
    if (current_ns == 0) return ACCEPT_BACKOFF_INITIAL_NS;
    return @min(current_ns *| 2, ACCEPT_BACKOFF_MAX_NS);
}

pub fn nextAcceptBackoffForTest(current_ns: u64) u64 {
    return nextAcceptBackoff(current_ns);
}

pub fn isLoopbackHost(host: []const u8) bool {
    const address = parseListenAddress(host, 0) catch return false;
    return isLoopbackAddress(address);
}

pub fn isLoopbackAddress(address: std.net.Address) bool {
    return switch (address.any.family) {
        std.posix.AF.INET => @as([4]u8, @bitCast(address.in.sa.addr))[0] == 127,
        std.posix.AF.INET6 => std.mem.eql(u8, &address.in6.sa.addr, &([_]u8{0} ** 15 ++ [_]u8{1})),
        else => false,
    };
}

/// Resolves a listen host. Accepts IPv4/IPv6 literals and `localhost`.
pub fn parseListenAddress(host: []const u8, port: u16) !std.net.Address {
    if (std.ascii.eqlIgnoreCase(host, "localhost")) {
        return std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    }
    return std.net.Address.parseIp(host, port);
}

/// Maps a wildcard bind address to the matching loopback address so a local
/// connect reaches the listener.
pub fn connectableAddress(bound: std.net.Address) std.net.Address {
    switch (bound.any.family) {
        std.posix.AF.INET => {
            if (bound.in.sa.addr == 0) {
                return std.net.Address.initIp4(.{ 127, 0, 0, 1 }, bound.getPort());
            }
        },
        std.posix.AF.INET6 => {
            if (std.mem.allEqual(u8, &bound.in6.sa.addr, 0)) {
                var loopback = [_]u8{0} ** 16;
                loopback[15] = 1;
                return std.net.Address.initIp6(loopback, bound.getPort(), 0, 0);
            }
        },
        else => {},
    }
    return bound;
}

fn sendRawResponse(stream: std.net.Stream, bytes: []const u8) void {
    stream.writeAll(bytes) catch {};
}

fn sameIp(a: std.net.Address, b: std.net.Address) bool {
    if (a.any.family != b.any.family) return false;
    return switch (a.any.family) {
        std.posix.AF.INET => a.in.sa.addr == b.in.sa.addr,
        std.posix.AF.INET6 => std.mem.eql(u8, &a.in6.sa.addr, &b.in6.sa.addr),
        else => false,
    };
}

pub fn sameIpForTest(a: std.net.Address, b: std.net.Address) bool {
    return sameIp(a, b);
}

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
        limits: RpcServer.Options,
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
    defer ctx.server.unregisterConnection(ctx);

    setConnectionTimeouts(ctx.connection.stream, ctx.server.limits) catch |err| {
        log.warn(.rpc, "connection timeout setup failed remote={any} error={s}", .{ ctx.connection.address, @errorName(err) });
        return;
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

    if (request.body.len > request.options.bodyLimit()) {
        return .{
            .status = .payload_too_large,
            .body = null,
        };
    }

    if (try handlePostWithPolicy(allocator, request.body, handlers, request.options.requestPolicy())) |response_body| {
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
    limits: RpcServer.Options,
) !void {
    var receive_buffer: [MAX_HTTP_HEAD_BYTES]u8 = undefined;
    var send_buffer: [8192]u8 = undefined;
    var connection_reader = connection.stream.reader(&receive_buffer);
    var connection_writer = connection.stream.writer(&send_buffer);
    var http_server = std.http.Server.init(connection_reader.interface(), &connection_writer.interface);

    while (http_server.reader.state == .ready) {
        var request = http_server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            error.HttpHeadersOversize => {
                sendRawResponse(connection.stream, "HTTP/1.1 431 Request Header Fields Too Large\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
                return;
            },
            error.HttpHeadersInvalid => {
                sendRawResponse(connection.stream, "HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
                return;
            },
            else => return err,
        };
        // Start monotonic timer after head arrival so keep-alive idle waits
        // (e.g. Engine API 12-second slots) are never miscounted as head lag.
        var request_timer = std.time.Timer.start() catch null;

        const keep_alive = try handleRequest(allocator, handlers, &request, dispatch_mutex, limits);
        if (!keep_alive) return;
        if (request_timer) |*timer| {
            if (timer.read() > @as(u64, REQUEST_BODY_DEADLINE_MS) * std.time.ns_per_ms) return;
        }
    }
}

/// Responds to a request whose body was not consumed. The connection is
/// closed: draining an unauthenticated or oversized body costs unbounded reads,
/// and keeping the connection open would parse the unread body as the next
/// request head.
fn respondEarlyAndClose(
    request: *std.http.Server.Request,
    status: std.http.Status,
    extra_headers: []const std.http.Header,
) !bool {
    try request.respond("", .{
        .status = status,
        .keep_alive = false,
        .extra_headers = extra_headers,
    });
    return false;
}

fn handleRequest(
    allocator: std.mem.Allocator,
    handlers: *const dispatcher.HandlerRegistry,
    request: *std.http.Server.Request,
    dispatch_mutex: ?*std.Thread.Mutex,
    limits: RpcServer.Options,
) !bool {
    var cors_headers_buffer: [4]std.http.Header = undefined;
    const cors_headers = corsResponseHeaders(&cors_headers_buffer, limits);

    if (!isRootTarget(request.head.target)) {
        return respondEarlyAndClose(request, .not_found, cors_headers);
    }

    if (request.head.method == .OPTIONS and isCorsPreflight(request) and limits.cors_allow_origin != null) {
        var preflight_buffer: [4]std.http.Header = undefined;
        return respondEarlyAndClose(request, .no_content, corsPreflightHeaders(&preflight_buffer, limits));
    }

    if (request.head.method != .POST) {
        return respondEarlyAndClose(request, .method_not_allowed, cors_headers);
    }

    if (!isAllowedHostHeader(hostHeaderValue(request), limits.validate_host)) {
        return respondEarlyAndClose(request, .bad_request, cors_headers);
    }

    if (request.head.content_length == null and request.head.transfer_encoding != .chunked) {
        return respondEarlyAndClose(request, .length_required, cors_headers);
    }

    if (limits.jwt_secret) |jwt_secret| {
        const authorization = authorizationHeaderValue(request);
        const authorized = if (authorization) |header_value|
            try validateJwtAuthorization(allocator, header_value, jwt_secret, std.time.timestamp(), limits.jwt_max_time_drift_seconds)
        else
            false;
        if (!authorized) {
            return respondEarlyAndClose(request, .unauthorized, &[_]std.http.Header{jwt_authenticate_header});
        }
    }

    if (!isJsonContentType(request.head.content_type)) {
        return respondEarlyAndClose(request, .unsupported_media_type, cors_headers);
    }

    const body_limit = limits.bodyLimit();
    if (request.head.content_length) |content_length| {
        if (content_length > body_limit) {
            return respondEarlyAndClose(request, .payload_too_large, cors_headers);
        }
    }

    const request_body = readRequestBody(allocator, request, body_limit) catch |err| switch (err) {
        error.StreamTooLong => return respondEarlyAndClose(request, .payload_too_large, cors_headers),
        else => return err,
    };
    defer allocator.free(request_body);

    const policy = limits.requestPolicy();
    const response_body = blk: {
        if (dispatch_mutex) |mutex| {
            mutex.lock();
            defer mutex.unlock();
            break :blk try handlePostWithPolicy(allocator, request_body, handlers, policy);
        }

        break :blk try handlePostWithPolicy(allocator, request_body, handlers, policy);
    };

    const keep_alive = request.head.keep_alive;
    if (response_body) |body| {
        defer allocator.free(body);

        var ok_headers_buffer: [5]std.http.Header = undefined;
        ok_headers_buffer[0] = json_content_type_header;
        @memcpy(ok_headers_buffer[1 .. 1 + cors_headers.len], cors_headers);
        try request.respond(body, .{
            .status = .ok,
            .keep_alive = keep_alive,
            .extra_headers = ok_headers_buffer[0 .. 1 + cors_headers.len],
        });
        return keep_alive;
    }

    try request.respond("", .{
        .status = .no_content,
        .keep_alive = keep_alive,
        .extra_headers = cors_headers,
    });
    return keep_alive;
}

fn corsResponseHeaders(buffer: *[4]std.http.Header, limits: RpcServer.Options) []const std.http.Header {
    const origin = limits.cors_allow_origin orelse return buffer[0..0];
    buffer[0] = .{ .name = "access-control-allow-origin", .value = origin };
    return buffer[0..1];
}

fn corsPreflightHeaders(buffer: *[4]std.http.Header, limits: RpcServer.Options) []const std.http.Header {
    const origin = limits.cors_allow_origin orelse return buffer[0..0];
    buffer[0] = .{ .name = "access-control-allow-origin", .value = origin };
    buffer[1] = .{ .name = "access-control-allow-methods", .value = "POST, OPTIONS" };
    buffer[2] = .{ .name = "access-control-allow-headers", .value = "content-type, authorization" };
    buffer[3] = .{ .name = "access-control-max-age", .value = "600" };
    return buffer[0..4];
}

/// A CORS preflight is an OPTIONS request carrying `Access-Control-Request-Method`.
fn isCorsPreflight(request: *const std.http.Server.Request) bool {
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "access-control-request-method")) return true;
    }
    return false;
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

fn hostHeaderValue(request: *const std.http.Server.Request) ?[]const u8 {
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "host")) {
            return header.value;
        }
    }
    return null;
}

/// Strips the port from a Host header value (e.g. "localhost:8545" -> "localhost").
fn hostWithoutPort(host: []const u8) []const u8 {
    if (std.mem.startsWith(u8, host, "[")) {
        if (std.mem.indexOfScalar(u8, host, ']')) |close| {
            return host[0 .. close + 1];
        }
        return host;
    }
    if (std.mem.lastIndexOfScalar(u8, host, ':')) |colon| {
        return host[0..colon];
    }
    return host;
}

fn isAllowedHostHeader(host_header: ?[]const u8, validate_host: ?[]const u8) bool {
    const validate = validate_host orelse return true;
    const raw_host = host_header orelse return false;
    const host = hostWithoutPort(raw_host);
    if (host.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(host, "localhost")) return true;
    if (std.mem.eql(u8, host, "127.0.0.1")) return true;
    if (std.mem.eql(u8, host, "[::1]")) return true;
    return std.ascii.eqlIgnoreCase(host, validate);
}

pub fn isAllowedHostHeaderForTest(host_header: ?[]const u8, validate_host: ?[]const u8) bool {
    return isAllowedHostHeader(host_header, validate_host);
}

fn authorizationHeaderValue(request: *const std.http.Server.Request) ?[]const u8 {
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "authorization")) {
            return header.value;
        }
    }

    return null;
}

fn validateJwtAuthorization(
    allocator: std.mem.Allocator,
    authorization: []const u8,
    secret: []const u8,
    now_seconds: i64,
    max_time_drift_seconds: i64,
) !bool {
    const token = bearerToken(authorization) orelse return false;
    return validateJwtToken(allocator, token, secret, now_seconds, max_time_drift_seconds);
}

/// Builds the `Authorization` header value an Engine API client sends:
/// `Bearer <HS256 JWT>` whose payload carries only `iat`. Caller owns the result.
pub fn engineJwtAuthorization(allocator: std.mem.Allocator, secret: []const u8, iat_seconds: i64) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const header_json = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";
    var payload_buffer: [64]u8 = undefined;
    const payload_json = try std.fmt.bufPrint(&payload_buffer, "{{\"iat\":{d}}}", .{iat_seconds});

    const signing_input = try allocator.alloc(u8, encoder.calcSize(header_json.len) + 1 + encoder.calcSize(payload_json.len));
    defer allocator.free(signing_input);
    const header_segment = encoder.encode(signing_input, header_json);
    signing_input[header_segment.len] = '.';
    _ = encoder.encode(signing_input[header_segment.len + 1 ..], payload_json);

    var signature: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&signature, signing_input, secret);
    var signature_segment: [encoder.calcSize(HmacSha256.mac_length)]u8 = undefined;
    _ = encoder.encode(&signature_segment, &signature);

    return std.fmt.allocPrint(allocator, "Bearer {s}.{s}", .{ signing_input, signature_segment });
}

fn bearerToken(authorization: []const u8) ?[]const u8 {
    var parts = std.mem.tokenizeAny(u8, authorization, " \t");
    const scheme = parts.next() orelse return null;
    const token = parts.next() orelse return null;
    if (parts.next() != null) return null;
    if (!std.ascii.eqlIgnoreCase(scheme, "Bearer")) return null;
    return if (token.len == 0) null else token;
}

fn validateJwtToken(
    allocator: std.mem.Allocator,
    token: []const u8,
    secret: []const u8,
    now_seconds: i64,
    max_time_drift_seconds: i64,
) !bool {
    if (max_time_drift_seconds < 0) return false;

    const header_end = std.mem.indexOfScalar(u8, token, '.') orelse return false;
    const payload_end_relative = std.mem.indexOfScalar(u8, token[header_end + 1 ..], '.') orelse return false;
    const payload_end = header_end + 1 + payload_end_relative;
    if (std.mem.indexOfScalar(u8, token[payload_end + 1 ..], '.') != null) return false;

    const header_segment = token[0..header_end];
    const payload_segment = token[header_end + 1 .. payload_end];
    const signature_segment = token[payload_end + 1 ..];
    if (header_segment.len == 0 or payload_segment.len == 0 or signature_segment.len == 0) return false;

    if (!try jwtHeaderUsesHs256(allocator, header_segment)) return false;
    if (!try jwtSignatureValid(allocator, token[0..payload_end], signature_segment, secret)) return false;

    const iat = try jwtPayloadIat(allocator, payload_segment) orelse return false;
    return jwtIatWithinDrift(now_seconds, iat, max_time_drift_seconds);
}

/// Widen to i128 so `now - iat` cannot overflow for any pair of i64 values.
fn jwtIatWithinDrift(now_seconds: i64, iat: i64, max_time_drift_seconds: i64) bool {
    const delta = @as(i128, now_seconds) - @as(i128, iat);
    const drift: u128 = @abs(delta);
    return drift <= @as(u128, @intCast(@max(max_time_drift_seconds, 0)));
}

fn jwtHeaderUsesHs256(allocator: std.mem.Allocator, encoded_header: []const u8) !bool {
    const header_json = decodeBase64UrlNoPad(allocator, encoded_header) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer allocator.free(header_json);
    if (exceedsJsonDepth(header_json, DEFAULT_MAX_JSON_DEPTH)) return false;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, header_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |object| object,
        else => return false,
    };
    const alg = object.get("alg") orelse return false;
    return switch (alg) {
        .string => |value| std.mem.eql(u8, value, "HS256"),
        else => false,
    };
}

fn jwtPayloadIat(allocator: std.mem.Allocator, encoded_payload: []const u8) !?i64 {
    const payload_json = decodeBase64UrlNoPad(allocator, encoded_payload) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer allocator.free(payload_json);
    if (exceedsJsonDepth(payload_json, DEFAULT_MAX_JSON_DEPTH)) return null;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |object| object,
        else => return null,
    };
    const iat = object.get("iat") orelse return null;
    return switch (iat) {
        .integer => |value| value,
        .float => |value| floatIatToSeconds(value),
        else => null,
    };
}

/// Rejects non-finite, fractional and out-of-range floats. `maxInt(i64)` is not
/// representable as f64 and rounds up to 2^63, so the upper bound is exclusive.
fn floatIatToSeconds(value: f64) ?i64 {
    const lower: f64 = -9223372036854775808.0; // -2^63, exact
    const upper: f64 = 9223372036854775808.0; // 2^63, exact
    if (!std.math.isFinite(value)) return null;
    if (@floor(value) != value) return null;
    if (value < lower or value >= upper) return null;
    return @as(i64, @intFromFloat(value));
}

pub fn floatIatToSecondsForTest(value: f64) ?i64 {
    return floatIatToSeconds(value);
}

fn jwtSignatureValid(
    allocator: std.mem.Allocator,
    signing_input: []const u8,
    encoded_signature: []const u8,
    secret: []const u8,
) !bool {
    const signature = decodeBase64UrlNoPad(allocator, encoded_signature) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer allocator.free(signature);
    if (signature.len != HmacSha256.mac_length) return false;

    var expected: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&expected, signing_input, secret);

    var actual: [HmacSha256.mac_length]u8 = undefined;
    @memcpy(actual[0..], signature);

    return std.crypto.timing_safe.eql([HmacSha256.mac_length]u8, expected, actual);
}

fn decodeBase64UrlNoPad(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const size = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(source) catch |err| switch (err) {
        error.InvalidPadding => return error.InvalidJwtBase64,
        else => return err,
    };
    const out = try allocator.alloc(u8, size);
    errdefer allocator.free(out);
    std.base64.url_safe_no_pad.Decoder.decode(out, source) catch |err| switch (err) {
        error.InvalidCharacter, error.InvalidPadding => return error.InvalidJwtBase64,
        else => return err,
    };
    return out;
}

pub fn validateJwtAuthorizationForTest(
    allocator: std.mem.Allocator,
    authorization: []const u8,
    secret: []const u8,
    now_seconds: i64,
    max_time_drift_seconds: i64,
) !bool {
    return validateJwtAuthorization(allocator, authorization, secret, now_seconds, max_time_drift_seconds);
}

fn readRequestBody(allocator: std.mem.Allocator, request: *std.http.Server.Request, max_request_body_bytes: usize) ![]u8 {
    var reader_buffer: [4096]u8 = undefined;
    const reader = try request.readerExpectContinue(&reader_buffer);

    var request_body = std.ArrayList(u8).empty;
    errdefer request_body.deinit(allocator);

    // Allow reading up to max + 1 bytes so a body of length == max_request_body_bytes
    // hits EOF cleanly instead of triggering StreamTooLong on the inclusive boundary.
    try reader.appendRemaining(allocator, &request_body, .limited(max_request_body_bytes +| 1));
    if (request_body.items.len > max_request_body_bytes) {
        return error.StreamTooLong;
    }

    return request_body.toOwnedSlice(allocator);
}

fn setConnectionTimeouts(stream: std.net.Stream, limits: RpcServer.Options) !void {
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

pub const JsonShape = struct {
    max_depth: usize,
    value_count: usize,
    /// Element count of a top-level array; null when the root is not an array.
    top_level_array_len: ?usize,
};

pub fn scanJsonShape(body: []const u8, depth_limit: usize) JsonShape {
    return scanJsonShapeWithLimit(body, depth_limit, DEFAULT_MAX_JSON_VALUES);
}

/// Bounds nesting and value count before std.json allocates a parse tree.
/// Syntax validation remains the parser's responsibility.
fn scanJsonShapeWithLimit(body: []const u8, depth_limit: usize, value_limit: usize) JsonShape {
    var depth: usize = 0;
    var max_depth: usize = 0;
    var value_count: usize = 0;
    var in_primitive = false;
    var in_string = false;
    var escaped = false;
    var root_is_array: ?bool = null;
    var top_level_separators: usize = 0;
    var top_level_has_element = false;

    for (body, 0..) |byte, index| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
                // A string followed by a colon is an object key.
                const next = std.mem.trimStart(u8, body[index + 1 ..], " \t\r\n");
                if (next.len == 0 or next[0] != ':') {
                    value_count += 1;
                    if (value_count > value_limit) break;
                }
            }
            continue;
        }

        const starts_primitive = switch (byte) {
            '"', '[', '{', ']', '}', ':', ',', ' ', '\t', '\r', '\n' => false,
            else => true,
        };
        if (starts_primitive and !in_primitive) value_count += 1;
        in_primitive = starts_primitive;

        switch (byte) {
            '"' => {
                in_string = true;
                if (depth == 1) top_level_has_element = true;
            },
            '[', '{' => {
                value_count += 1;
                if (depth == 0 and root_is_array == null) root_is_array = byte == '[';
                if (depth == 1) top_level_has_element = true;
                depth += 1;
                if (depth > max_depth) {
                    max_depth = depth;
                    if (max_depth > depth_limit) break;
                }
            },
            ']', '}' => depth -|= 1,
            ',' => {
                if (depth == 1) top_level_separators += 1;
            },
            ':', ' ', '\t', '\r', '\n' => {},
            else => {
                if (depth == 0 and root_is_array == null) root_is_array = false;
                if (depth == 1) top_level_has_element = true;
            },
        }
        if (value_count > value_limit) break;
    }

    const is_array = root_is_array orelse false;
    return .{
        .max_depth = max_depth,
        .value_count = value_count,
        .top_level_array_len = if (!is_array)
            null
        else if (top_level_has_element or top_level_separators > 0)
            top_level_separators + 1
        else
            0,
    };
}

fn exceedsJsonDepth(body: []const u8, depth_limit: usize) bool {
    return scanJsonShapeWithLimit(body, depth_limit, std.math.maxInt(usize)).max_depth > depth_limit;
}

/// Dispatch a JSON-RPC request or batch without opening an HTTP listener.
/// The caller owns the returned buffer; notifications return null.
/// In-process callers are trusted: `engine_*` methods are allowed.
pub fn handlePost(
    allocator: std.mem.Allocator,
    body: []const u8,
    handlers: *const dispatcher.HandlerRegistry,
) !?[]u8 {
    return handlePostWithPolicy(allocator, body, handlers, .{});
}

pub fn handlePostWithPolicy(
    allocator: std.mem.Allocator,
    body: []const u8,
    handlers: *const dispatcher.HandlerRegistry,
    policy: RequestPolicy,
) !?[]u8 {
    const start_ns = std.time.nanoTimestamp();
    var req_arena = std.heap.ArenaAllocator.init(allocator);
    defer req_arena.deinit();
    const req_alloc = req_arena.allocator();

    const shape = scanJsonShapeWithLimit(body, policy.max_json_depth, policy.max_json_values);
    const too_many_values = shape.value_count > policy.max_json_values;
    const too_deep = shape.max_depth > policy.max_json_depth;
    const too_many = if (shape.top_level_array_len) |len| len > policy.max_batch_size else false;
    if (too_deep or too_many or too_many_values) {
        logRequestTelemetry(req_alloc, .{
            .method = if (too_deep) "too_deep" else if (too_many_values) "too_many_values" else "batch_too_large",
            .id_present = false,
            .batch_size = shape.top_level_array_len orelse 0,
            .status = "error",
            .error_code = jsonrpc.envelope.ErrorCode.INVALID_REQUEST,
            .duration_ns = elapsedSince(start_ns),
            .mode = activeModeName(handlers),
        });
        return @as(?[]u8, try writeErrorResponse(allocator, req_alloc, null, jsonrpc.envelope.ErrorCode.INVALID_REQUEST, "Invalid Request"));
    }

    const request_batch = jsonrpc.envelope.parseSingleOrBatch(req_alloc, body) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidRequest => {
            logRequestTelemetry(req_alloc, .{
                .method = "<invalid>",
                .id_present = false,
                .batch_size = 0,
                .status = "error",
                .error_code = jsonrpc.envelope.ErrorCode.INVALID_REQUEST,
                .duration_ns = elapsedSince(start_ns),
                .mode = activeModeName(handlers),
            });
            return @as(?[]u8, try writeErrorResponse(allocator, req_alloc, null, jsonrpc.envelope.ErrorCode.INVALID_REQUEST, "Invalid Request"));
        },
        else => {
            logRequestTelemetry(req_alloc, .{
                .method = "parse_error",
                .id_present = false,
                .batch_size = 0,
                .status = "error",
                .error_code = jsonrpc.envelope.ErrorCode.PARSE_ERROR,
                .duration_ns = elapsedSince(start_ns),
                .mode = activeModeName(handlers),
            });
            return @as(?[]u8, try writeErrorResponse(allocator, req_alloc, null, jsonrpc.envelope.ErrorCode.PARSE_ERROR, "Parse error"));
        },
    };

    return switch (request_batch.kind) {
        .single => |request| handleSingleRequest(allocator, req_alloc, request, handlers, policy),
        .batch => |batch| blk: {
            // The pre-parse scan already bounds this; keep the parsed count authoritative.
            if (batch.len > policy.max_batch_size) {
                break :blk @as(?[]u8, try writeErrorResponse(allocator, req_alloc, null, jsonrpc.envelope.ErrorCode.INVALID_REQUEST, "Invalid Request"));
            }
            break :blk handleBatch(allocator, req_alloc, batch, handlers, policy);
        },
    };
}

fn handleSingleRequest(
    out_allocator: std.mem.Allocator,
    req_allocator: std.mem.Allocator,
    request: jsonrpc.envelope.RequestEnvelope,
    handlers: *const dispatcher.HandlerRegistry,
    policy: RequestPolicy,
) !?[]u8 {
    const start_ns = std.time.nanoTimestamp();
    if (request.invalid) {
        logRequestTelemetry(req_allocator, .{
            .method = "<invalid>",
            .id_present = request.id != null,
            .batch_size = 1,
            .status = "error",
            .error_code = jsonrpc.envelope.ErrorCode.INVALID_REQUEST,
            .duration_ns = elapsedSince(start_ns),
            .mode = activeModeName(handlers),
        });
        return @as(?[]u8, try writeErrorResponse(out_allocator, req_allocator, null, jsonrpc.envelope.ErrorCode.INVALID_REQUEST, "Invalid Request"));
    }

    const response = try dispatchWithPolicy(req_allocator, request, handlers, policy);

    if (isNotification(request)) {
        logRequestTelemetry(req_allocator, .{
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

    const response_body = try stringifyResponse(out_allocator, response);
    logRequestTelemetry(req_allocator, .{
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
    out_allocator: std.mem.Allocator,
    req_allocator: std.mem.Allocator,
    batch: []jsonrpc.envelope.RequestEnvelope,
    handlers: *const dispatcher.HandlerRegistry,
    policy: RequestPolicy,
) !?[]u8 {
    var writer = std.Io.Writer.Allocating.init(out_allocator);
    errdefer writer.deinit();

    try writer.writer.writeByte('[');
    var wrote_response = false;
    for (batch) |request| {
        // Isolate per-item allocations so a large batch (e.g. debug_traceCall)
        // releases each response's working memory immediately after stringify.
        var item_arena = std.heap.ArenaAllocator.init(out_allocator);
        defer item_arena.deinit();
        const item_allocator = item_arena.allocator();
        _ = req_allocator;

        const start_ns = std.time.nanoTimestamp();
        if (isNotification(request)) {
            const response = try dispatchWithPolicy(item_allocator, request, handlers, policy);
            logRequestTelemetry(item_allocator, .{
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
            try writer.writer.writeByte(',');
        }

        if (request.invalid) {
            const err_resp = jsonrpc.envelope.ResponseEnvelope.makeError(null, jsonrpc.envelope.ErrorCode.INVALID_REQUEST, "Invalid Request");
            try std.json.Stringify.value(err_resp, .{}, &writer.writer);
            logRequestTelemetry(item_allocator, .{
                .method = "<invalid>",
                .id_present = request.id != null,
                .batch_size = batch.len,
                .status = "error",
                .error_code = jsonrpc.envelope.ErrorCode.INVALID_REQUEST,
                .duration_ns = elapsedSince(start_ns),
                .mode = activeModeName(handlers),
            });
        } else {
            const response = try dispatchWithPolicy(item_allocator, request, handlers, policy);
            try std.json.Stringify.value(response, .{}, &writer.writer);
            logRequestTelemetry(item_allocator, .{
                .method = request.method,
                .id_present = request.id != null,
                .batch_size = batch.len,
                .status = responseStatus(response),
                .error_code = responseErrorCode(response),
                .duration_ns = elapsedSince(start_ns),
                .mode = activeModeName(handlers),
            });
        }
        wrote_response = true;
    }

    if (!wrote_response) {
        writer.deinit();
        return null;
    }
    try writer.writer.writeByte(']');

    return @as(?[]u8, try writer.toOwnedSlice());
}

/// Applies the listener namespace policy before any handler runs.
fn dispatchWithPolicy(
    allocator: std.mem.Allocator,
    request: jsonrpc.envelope.RequestEnvelope,
    handlers: *const dispatcher.HandlerRegistry,
    policy: RequestPolicy,
) !jsonrpc.envelope.ResponseEnvelope {
    const testing_build = policy.allow_testing_build_block and std.mem.eql(u8, request.method, "testing_buildBlockV1");
    if ((!policy.allow_engine_methods and dispatcher.isEngineNamespaceMethod(request.method)) or
        (!policy.allow_dev_methods and !testing_build and isDevNamespaceMethod(request.method)))
    {
        return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, jsonrpc.envelope.ErrorCode.METHOD_NOT_FOUND, "Method not found");
    }
    return dispatcher.dispatch(allocator, request, handlers);
}

fn isDevNamespaceMethod(method: []const u8) bool {
    // Read-only light client health/sync endpoint stays accessible even when
    // dev mutators are disabled on non-loopback light-mode listeners.
    if (std.mem.eql(u8, method, "zevm_lightSyncStatus")) return false;
    for ([_][]const u8{ "anvil_", "evm_", "hardhat_", "zevm_", "testing_" }) |prefix| {
        if (std.mem.startsWith(u8, method, prefix)) return true;
    }
    return false;
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
    if (isTestBuild() or !log.shouldLog(.info)) return;

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
    const method = log.sanitizeRpcMethod(fields.method);
    if (fields.error_code) |code| {
        return std.fmt.allocPrint(
            allocator,
            "rpc_request method={s} id_present={} batch_size={} status={s} error_code={} duration_us={} mode={s}",
            .{ method, fields.id_present, fields.batch_size, fields.status, code, @divTrunc(fields.duration_ns, 1000), fields.mode },
        );
    }

    return std.fmt.allocPrint(
        allocator,
        "rpc_request method={s} id_present={} batch_size={} status={s} error_code=null duration_us={} mode={s}",
        .{ method, fields.id_present, fields.batch_size, fields.status, @divTrunc(fields.duration_ns, 1000), fields.mode },
    );
}

pub fn formatRequestTelemetryForTest(allocator: std.mem.Allocator, fields: RequestTelemetryFields) ![]u8 {
    return formatRequestTelemetry(allocator, fields);
}

fn writeErrorResponse(
    out_allocator: std.mem.Allocator,
    req_allocator: std.mem.Allocator,
    id: ?jsonrpc.envelope.Id,
    code: i32,
    message: []const u8,
) ![]u8 {
    _ = req_allocator;
    const response = jsonrpc.envelope.ResponseEnvelope.makeError(id, code, message);
    return stringifyResponse(out_allocator, response);
}

fn stringifyResponse(allocator: std.mem.Allocator, response: jsonrpc.envelope.ResponseEnvelope) ![]u8 {
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();

    try std.json.Stringify.value(response, .{}, &writer.writer);

    return writer.toOwnedSlice();
}
