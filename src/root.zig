const std = @import("std");

pub const Database = @import("database.zig").Database;

test {
    _ = @import("database_test.zig");
}
