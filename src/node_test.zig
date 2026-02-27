const std = @import("std");
const node = @import("node.zig");

test "RpcConfig defaults to localhost:8545 with CORS enabled" {
    const config = node.RpcConfig{};
    try std.testing.expectEqualStrings("127.0.0.1", config.host);
    try std.testing.expectEqual(@as(u16, 8545), config.port);
    try std.testing.expect(config.cors_enabled);
}
