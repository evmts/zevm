const std = @import("std");
const jsonrpc = @import("../voltaire/packages/voltaire-zig/src/jsonrpc/root.zig");

test "parse" {
    const parsed = try std.json.parseFromSlice(jsonrpc.types.Quantity, std.testing.allocator, "\"0x1\"", .{});
    defer parsed.deinit();
    _ = parsed.value;
}
