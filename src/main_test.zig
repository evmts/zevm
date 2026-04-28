const std = @import("std");
const config = @import("config.zig");

test "config.load uses trusted defaults" {
    var app_config = try config.load(std.testing.allocator, &[_][]const u8{});
    defer app_config.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("127.0.0.1", app_config.rpc.host);
    try std.testing.expectEqual(@as(u16, 8545), app_config.rpc.port);
    try std.testing.expectEqual(config.Mode.trusted, std.meta.activeTag(app_config.mode));
}

test "config.load reads --host and --port" {
    var app_config = try config.load(
        std.testing.allocator,
        &[_][]const u8{ "--host", "0.0.0.0", "--port", "9555" },
    );
    defer app_config.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("0.0.0.0", app_config.rpc.host);
    try std.testing.expectEqual(@as(u16, 9555), app_config.rpc.port);
}

test "config.load reads --fork-url and --fork-block-number" {
    var app_config = try config.load(
        std.testing.allocator,
        &[_][]const u8{
            "--fork-url",
            "https://rpc.example.org",
            "--fork-block-number",
            "2048",
        },
    );
    defer app_config.deinit(std.testing.allocator);

    const trusted = switch (app_config.mode) {
        .trusted => |trusted| trusted,
        .light => return error.ExpectedTrustedConfig,
    };
    try std.testing.expectEqualStrings("https://rpc.example.org", trusted.fork.?.url);
    try std.testing.expectEqual(@as(u64, 2048), trusted.fork.?.block_number.?);
}
