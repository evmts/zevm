const std = @import("std");
const server = @import("rpc/server.zig");

test "server.parseConfig uses defaults" {
    const config = try server.parseConfig(std.testing.allocator, &[_][]const u8{});

    try std.testing.expectEqualStrings("127.0.0.1", config.host);
    try std.testing.expectEqual(@as(u16, 8545), config.port);
}

test "server.parseConfig reads --host and --port" {
    const config = try server.parseConfig(
        std.testing.allocator,
        &[_][]const u8{ "--host", "0.0.0.0", "--port", "9555" },
    );

    try std.testing.expectEqualStrings("0.0.0.0", config.host);
    try std.testing.expectEqual(@as(u16, 9555), config.port);
}
