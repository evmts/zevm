const std = @import("std");

comptime {
    _ = @import("embedded_node.zig");
}

export fn zevm_alloc(len: usize) ?[*]u8 {
    const buf = std.heap.c_allocator.alloc(u8, len) catch return null;
    return buf.ptr;
}

export fn zevm_free(ptr: [*]u8, len: usize) void {
    std.heap.c_allocator.free(ptr[0..len]);
}

test "browser zevm_alloc and zevm_free allocate writable buffer" {
    const len: usize = 64;
    const ptr = zevm_alloc(len) orelse return error.TestUnexpectedResult;
    defer zevm_free(ptr, len);
    @memset(ptr[0..len], 0x5a);
    try std.testing.expectEqual(@as(u8, 0x5a), ptr[0]);
    try std.testing.expectEqual(@as(u8, 0x5a), ptr[len - 1]);
}
