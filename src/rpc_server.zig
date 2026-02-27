const std = @import("std");

pub fn handleJsonRpc(allocator: std.mem.Allocator, request_bytes: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, request_bytes, .{
        .allocate = .alloc_always,
    }) catch {
        return allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}");
    };
    parsed.deinit();

    if (parsed.value != .object and parsed.value != .array) {
        return allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"Invalid request\"}}");
    }

    return error.NotImplemented;
}
