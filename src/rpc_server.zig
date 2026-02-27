const std = @import("std");

pub fn handleJsonRpc(allocator: std.mem.Allocator, request_bytes: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, request_bytes, .{
        .allocate = .alloc_always,
    }) catch {
        return makeErrorResponseBytes(allocator, .null, -32700, "Parse error");
    };
    defer parsed.deinit();

    return switch (parsed.value) {
        .object => handleSingleValue(allocator, parsed.value),
        .array => error.NotImplemented,
        else => makeErrorResponseBytes(allocator, .null, -32600, "Invalid request"),
    };
}

fn handleSingleValue(allocator: std.mem.Allocator, request_value: std.json.Value) ![]u8 {
    const request_object = switch (request_value) {
        .object => |object| object,
        else => return makeErrorResponseBytes(allocator, .null, -32600, "Invalid request"),
    };

    const request_id = request_object.get("id") orelse .null;

    const jsonrpc_field = request_object.get("jsonrpc") orelse {
        return makeErrorResponseBytes(allocator, request_id, -32600, "Invalid request");
    };

    switch (jsonrpc_field) {
        .string => |jsonrpc_version| {
            if (!std.mem.eql(u8, jsonrpc_version, "2.0")) {
                return makeErrorResponseBytes(allocator, request_id, -32600, "Invalid request");
            }
        },
        else => return makeErrorResponseBytes(allocator, request_id, -32600, "Invalid request"),
    }

    const method_field = request_object.get("method") orelse {
        return makeErrorResponseBytes(allocator, request_id, -32600, "Invalid request");
    };

    if (method_field != .string) {
        return makeErrorResponseBytes(allocator, request_id, -32600, "Invalid request");
    }

    return makeErrorResponseBytes(allocator, request_id, -32601, "Method not found");
}

fn makeErrorResponseBytes(
    allocator: std.mem.Allocator,
    request_id: std.json.Value,
    code: i32,
    message: []const u8,
) ![]u8 {
    var response_writer = std.Io.Writer.Allocating.init(allocator);
    defer response_writer.deinit();

    try response_writer.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(request_id, .{}, &response_writer.writer);
    try response_writer.writer.writeAll(",\"error\":{");
    try response_writer.writer.print("\"code\":{},\"message\":\"{s}\"", .{ code, message });
    try response_writer.writer.writeAll("}}");

    return response_writer.toOwnedSlice();
}
