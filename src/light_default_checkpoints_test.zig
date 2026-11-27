const std = @import("std");
const checkpoints = @import("light_default_checkpoints.zig");

fn expectValidCheckpointHex(bare: []const u8, prefixed: []const u8) !void {
    try std.testing.expectEqual(@as(usize, 64), bare.len);
    try std.testing.expectEqual(@as(usize, 66), prefixed.len);
    try std.testing.expect(std.mem.startsWith(u8, prefixed, "0x"));
    try std.testing.expectEqualStrings(bare, prefixed[2..]);

    var decoded: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&decoded, bare);
    try std.testing.expect(!std.mem.allEqual(u8, &decoded, 0));
}

test "baked light default checkpoints are valid non-zero 32-byte roots" {
    try expectValidCheckpointHex(checkpoints.mainnet_hex, checkpoints.mainnet_prefixed);
    try expectValidCheckpointHex(checkpoints.sepolia_hex, checkpoints.sepolia_prefixed);
    try expectValidCheckpointHex(checkpoints.holesky_hex, checkpoints.holesky_prefixed);
    try expectValidCheckpointHex(checkpoints.hoodi_hex, checkpoints.hoodi_prefixed);
}
