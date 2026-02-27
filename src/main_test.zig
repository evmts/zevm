const std = @import("std");
const main = @import("main.zig");

test "parseRpcConfigFromArgs uses defaults" {
    const args = [_][]const u8{"zevm"};
    const config = try main.parseRpcConfigFromArgs(&args);

    try std.testing.expectEqualStrings("127.0.0.1", config.host);
    try std.testing.expectEqual(@as(u16, 8545), config.port);
}

test "parseRpcConfigFromArgs reads --host and --port" {
    const args = [_][]const u8{ "zevm", "--host", "0.0.0.0", "--port", "9555" };
    const config = try main.parseRpcConfigFromArgs(&args);

    try std.testing.expectEqualStrings("0.0.0.0", config.host);
    try std.testing.expectEqual(@as(u16, 9555), config.port);
}
