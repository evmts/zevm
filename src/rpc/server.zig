const std = @import("std");
const jsonrpc = @import("jsonrpc");
const dispatcher = @import("dispatcher.zig");
const node_handler = @import("node_handler.zig");

pub const ServerConfig = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8545,
    fork_url: ?[]const u8 = null,
    fork_block_number: ?u64 = null,
};

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

const subscription_poll_interval_ns: u64 = 200 * std.time.ns_per_ms;

const ConnectionTask = struct {
    allocator: std.mem.Allocator,
    handlers: *const dispatcher.HandlerRegistry,
    handler_mutex: *std.Thread.Mutex,
    connection: std.net.Server.Connection,
};

const WebSocketNotificationTask = struct {
    allocator: std.mem.Allocator,
    handlers: *const dispatcher.HandlerRegistry,
    handler_mutex: *std.Thread.Mutex,
    write_mutex: *std.Thread.Mutex,
    web_socket: *std.http.Server.WebSocket,
    stop: *std.atomic.Value(bool),
};

const IntervalMiningTask = struct {
    allocator: std.mem.Allocator,
    handlers: *const dispatcher.HandlerRegistry,
    handler_mutex: *std.Thread.Mutex,
};

pub fn parseConfig(allocator: std.mem.Allocator, args: []const []const u8) !ServerConfig {
    _ = allocator;

    var config = ServerConfig{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--host")) {
            index += 1;
            if (index >= args.len) {
                return error.MissingHostValue;
            }
            config.host = args[index];
            continue;
        }

        if (std.mem.eql(u8, args[index], "--port")) {
            index += 1;
            if (index >= args.len) {
                return error.MissingPortValue;
            }
            config.port = std.fmt.parseInt(u16, args[index], 10) catch {
                return error.InvalidPort;
            };
            continue;
        }

        if (std.mem.eql(u8, args[index], "--fork-url")) {
            index += 1;
            if (index >= args.len) {
                return error.MissingForkUrlValue;
            }
            config.fork_url = args[index];
            continue;
        }

        if (std.mem.eql(u8, args[index], "--fork-block-number")) {
            index += 1;
            if (index >= args.len) {
                return error.MissingForkBlockNumberValue;
            }

            const raw = args[index];
            config.fork_block_number = if (std.mem.startsWith(u8, raw, "0x") or std.mem.startsWith(u8, raw, "0X"))
                std.fmt.parseInt(u64, raw[2..], 16) catch return error.InvalidForkBlockNumber
            else
                std.fmt.parseInt(u64, raw, 10) catch return error.InvalidForkBlockNumber;
            continue;
        }

        return error.UnknownArgument;
    }

    return config;
}

pub fn run(allocator: std.mem.Allocator, config: ServerConfig, handlers: *const dispatcher.HandlerRegistry) !void {
    const address = try std.net.Address.parseIp(config.host, config.port);
    var tcp_server = try address.listen(.{ .reuse_address = true });
    defer tcp_server.deinit();
    var handler_mutex = std.Thread.Mutex{};

    if (handlers.on_method_with_context != null and handlers.context != null) {
        const interval_task = allocator.create(IntervalMiningTask) catch null;
        if (interval_task) |task| {
            task.* = .{
                .allocator = allocator,
                .handlers = handlers,
                .handler_mutex = &handler_mutex,
            };
            const interval_thread: ?std.Thread = std.Thread.spawn(.{}, serveIntervalMining, .{task}) catch blk: {
                allocator.destroy(task);
                break :blk null;
            };
            if (interval_thread) |thread| {
                thread.detach();
            }
        }
    }

    while (true) {
        const connection = try tcp_server.accept();
        const task = allocator.create(ConnectionTask) catch {
            connection.stream.close();
            continue;
        };
        task.* = .{
            .allocator = allocator,
            .handlers = handlers,
            .handler_mutex = &handler_mutex,
            .connection = connection,
        };

        const thread = std.Thread.spawn(.{}, handleConnectionThread, .{task}) catch {
            allocator.destroy(task);
            connection.stream.close();
            continue;
        };
        thread.detach();
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
    if (response_body) |body_bytes| {
        return .{
            .status = .ok,
            .body = body_bytes,
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
    handler_mutex: *std.Thread.Mutex,
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

        switch (request.upgradeRequested()) {
            .websocket => |key_opt| {
                const key = key_opt orelse return;
                var web_socket = try request.respondWebSocket(.{ .key = key });
                try serveWebSocket(allocator, handlers, handler_mutex, &web_socket);
                return;
            },
            .other => {
                try request.respond("Unsupported upgrade", .{
                    .status = .bad_request,
                });
                return;
            },
            .none => {
                try handleRequest(allocator, handlers, handler_mutex, &request);
            },
        }
    }
}

fn handleRequest(
    allocator: std.mem.Allocator,
    handlers: *const dispatcher.HandlerRegistry,
    handler_mutex: *std.Thread.Mutex,
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

    handler_mutex.lock();
    defer handler_mutex.unlock();
    const response_body = try handlePost(allocator, request_body, handlers);
    if (response_body) |body_bytes| {
        defer allocator.free(body_bytes);
        try request.respond(body_bytes, .{
            .status = .ok,
            .extra_headers = &[_]std.http.Header{json_content_type_header},
        });
        return;
    }

    try request.respond("", .{
        .status = .no_content,
    });
}

fn handleConnectionThread(task: *ConnectionTask) void {
    defer task.allocator.destroy(task);
    handleConnection(task.allocator, task.handlers, task.handler_mutex, task.connection) catch {};
}

fn serveWebSocket(
    allocator: std.mem.Allocator,
    handlers: *const dispatcher.HandlerRegistry,
    handler_mutex: *std.Thread.Mutex,
    web_socket: *std.http.Server.WebSocket,
) !void {
    var write_mutex = std.Thread.Mutex{};
    var stop = std.atomic.Value(bool).init(false);
    var notification_task = WebSocketNotificationTask{
        .allocator = allocator,
        .handlers = handlers,
        .handler_mutex = handler_mutex,
        .write_mutex = &write_mutex,
        .web_socket = web_socket,
        .stop = &stop,
    };

    const notification_thread = try std.Thread.spawn(.{}, serveWebSocketNotifications, .{&notification_task});
    defer {
        stop.store(true, .release);
        notification_thread.join();
    }

    while (true) {
        const message = web_socket.readSmallMessage() catch {
            return;
        };

        if (message.opcode == .ping) {
            write_mutex.lock();
            const pong_result = web_socket.writeMessage(message.data, .pong);
            write_mutex.unlock();
            pong_result catch return;
            continue;
        }

        if (message.opcode != .text and message.opcode != .binary) {
            continue;
        }

        handler_mutex.lock();
        const response_body = handlePost(allocator, message.data, handlers) catch {
            handler_mutex.unlock();
            continue;
        };
        handler_mutex.unlock();
        if (response_body) |body_bytes| {
            defer allocator.free(body_bytes);

            write_mutex.lock();
            const write_result = web_socket.writeMessage(body_bytes, .text);
            write_mutex.unlock();
            write_result catch return;
        }
    }
}

fn serveWebSocketNotifications(task: *WebSocketNotificationTask) void {
    const context = task.handlers.context orelse return;
    const handler: *node_handler.NodeHandler = @ptrCast(@alignCast(context));

    while (!task.stop.load(.acquire)) {
        task.handler_mutex.lock();
        const messages = handler.collectSubscriptionMessages(task.allocator) catch {
            task.handler_mutex.unlock();
            std.Thread.sleep(subscription_poll_interval_ns);
            continue;
        };
        task.handler_mutex.unlock();
        defer {
            for (messages) |message| {
                task.allocator.free(message);
            }
            task.allocator.free(messages);
        }

        for (messages) |message| {
            task.write_mutex.lock();
            const write_result = task.web_socket.writeMessage(message, .text);
            task.write_mutex.unlock();
            write_result catch {
                task.stop.store(true, .release);
                return;
            };
        }

        std.Thread.sleep(subscription_poll_interval_ns);
    }
}

fn serveIntervalMining(task: *IntervalMiningTask) void {
    defer task.allocator.destroy(task);

    const context = task.handlers.context orelse return;
    const handler: *node_handler.NodeHandler = @ptrCast(@alignCast(context));

    while (true) {
        std.Thread.sleep(subscription_poll_interval_ns);
        task.handler_mutex.lock();
        handler.maybeMineInterval(task.allocator) catch {
            // Keep background mining loop alive.
        };
        task.handler_mutex.unlock();
    }
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
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return try writeErrorResponse(allocator, null, jsonrpc.envelope.ErrorCode.PARSE_ERROR, "Parse error");
    };
    defer parsed.deinit();

    return switch (parsed.value) {
        .object => blk: {
            var request = jsonrpc.envelope.RequestEnvelope.jsonParseFromValue(allocator, parsed.value, .{}) catch {
                break :blk try writeErrorResponse(allocator, null, jsonrpc.envelope.ErrorCode.INVALID_REQUEST, "Invalid request");
            };
            defer request.deinit(allocator);
            break :blk try handleSingleRequest(allocator, request, handlers);
        },
        .array => |array| blk: {
            if (array.items.len == 0) {
                break :blk try writeErrorResponse(allocator, null, jsonrpc.envelope.ErrorCode.INVALID_REQUEST, "Invalid request");
            }
            break :blk try handleBatch(allocator, array.items, handlers);
        },
        else => try writeErrorResponse(allocator, null, jsonrpc.envelope.ErrorCode.INVALID_REQUEST, "Invalid request"),
    };
}

fn handleSingleRequest(
    allocator: std.mem.Allocator,
    request: jsonrpc.envelope.RequestEnvelope,
    handlers: *const dispatcher.HandlerRegistry,
) !?[]u8 {
    var response = try dispatcher.dispatch(allocator, request, handlers);
    defer response.deinit(allocator);

    if (request.id == null) {
        return null;
    }

    const response_bytes = try stringifyResponse(allocator, response);
    return response_bytes;
}

fn handleBatch(
    allocator: std.mem.Allocator,
    batch: []const std.json.Value,
    handlers: *const dispatcher.HandlerRegistry,
) !?[]u8 {
    var response_bytes = std.ArrayList(u8).empty;
    errdefer response_bytes.deinit(allocator);

    try response_bytes.append(allocator, '[');
    var emitted_count: usize = 0;
    for (batch) |item| {
        if (item != .object) {
            const invalid_bytes = try writeErrorResponse(allocator, null, jsonrpc.envelope.ErrorCode.INVALID_REQUEST, "Invalid request");
            defer allocator.free(invalid_bytes);
            if (emitted_count > 0) {
                try response_bytes.append(allocator, ',');
            }
            try response_bytes.appendSlice(allocator, invalid_bytes);
            emitted_count += 1;
            continue;
        }

        var request = jsonrpc.envelope.RequestEnvelope.jsonParseFromValue(allocator, item, .{}) catch {
            const invalid_bytes = try writeErrorResponse(allocator, null, jsonrpc.envelope.ErrorCode.INVALID_REQUEST, "Invalid request");
            defer allocator.free(invalid_bytes);
            if (emitted_count > 0) {
                try response_bytes.append(allocator, ',');
            }
            try response_bytes.appendSlice(allocator, invalid_bytes);
            emitted_count += 1;
            continue;
        };
        defer request.deinit(allocator);

        const item_response = try handleSingleRequest(allocator, request, handlers);
        if (item_response) |item_bytes| {
            defer allocator.free(item_bytes);
            if (emitted_count > 0) {
                try response_bytes.append(allocator, ',');
            }
            try response_bytes.appendSlice(allocator, item_bytes);
            emitted_count += 1;
        }
    }

    if (emitted_count == 0) {
        response_bytes.deinit(allocator);
        return null;
    }

    try response_bytes.append(allocator, ']');

    const owned = try response_bytes.toOwnedSlice(allocator);
    return owned;
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
