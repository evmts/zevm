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
