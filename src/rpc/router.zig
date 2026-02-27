const std = @import("std");
const jsonrpc = @import("jsonrpc");
const envelope = @import("envelope.zig");
const handlers = @import("handlers.zig");

pub fn route(
    allocator: std.mem.Allocator,
    context: *const handlers.HandlerContext,
    request: envelope.Request,
) ![]u8 {
    if (request.invalid_request or request.method.len == 0) {
        return envelope.writeError(allocator, request.id, -32600, "Invalid request");
    }

    if (!isKnownMethod(request.method)) {
        return envelope.writeError(allocator, request.id, -32601, "Method not found");
    }

    const dispatch_result = try handlers.dispatch(
        allocator,
        context,
        request.method,
        request.params,
        request.id,
    );

    return switch (dispatch_result) {
        .success => |result| envelope.writeSuccess(allocator, request.id, result),
        .rpc_error => |rpc_error| envelope.writeError(allocator, request.id, rpc_error.code, rpc_error.message),
    };
}

pub fn routeBatch(
    allocator: std.mem.Allocator,
    context: *const handlers.HandlerContext,
    requests: []const envelope.Request,
) ![]u8 {
    var response_writer = std.Io.Writer.Allocating.init(allocator);
    defer response_writer.deinit();

    try response_writer.writer.writeByte('[');

    for (requests, 0..) |request, index| {
        if (index > 0) {
            try response_writer.writer.writeByte(',');
        }

        const response_item = try route(allocator, context, request);
        defer allocator.free(response_item);

        try response_writer.writer.writeAll(response_item);
    }

    try response_writer.writer.writeByte(']');

    return response_writer.toOwnedSlice();
}

fn isKnownMethod(method_name: []const u8) bool {
    _ = jsonrpc.eth.EthMethod.fromMethodName(method_name) catch {
        _ = jsonrpc.debug.DebugMethod.fromMethodName(method_name) catch {
            _ = jsonrpc.engine.EngineMethod.fromMethodName(method_name) catch {
                return false;
            };
            return true;
        };
        return true;
    };
    return true;
}
