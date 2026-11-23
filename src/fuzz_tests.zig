const std = @import("std");

// Keep fuzz test output quiet so high-throughput coverage-guided runs are not
// bottlenecked on stderr logging.
pub const std_options: std.Options = .{
    .log_level = .err,
};

test {
    _ = @import("fuzz/root.zig");
}
