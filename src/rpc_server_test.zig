const std = @import("std");
const rpc_server = @import("rpc_server.zig");

test "handleJsonRpc: malformed JSON returns -32700 with null id" {
    const response_bytes = try rpc_server.handleJsonRpc(std.testing.allocator, "{");
    defer std.testing.allocator.free(response_bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, response_bytes, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const response_object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidJsonType,
    };

    try std.testing.expectEqualStrings("2.0", switch (response_object.get("jsonrpc") orelse return error.MissingJsonField) {
        .string => |value| value,
        else => return error.InvalidJsonType,
    });
    try std.testing.expect((response_object.get("id") orelse return error.MissingJsonField) == .null);

    const error_object = switch (response_object.get("error") orelse return error.MissingJsonField) {
        .object => |object| object,
        else => return error.InvalidJsonType,
    };
    try std.testing.expectEqual(@as(i64, -32700), switch (error_object.get("code") orelse return error.MissingJsonField) {
        .integer => |value| value,
        else => return error.InvalidJsonType,
    });
    try std.testing.expectEqualStrings("Parse error", switch (error_object.get("message") orelse return error.MissingJsonField) {
        .string => |value| value,
        else => return error.InvalidJsonType,
    });
}
