const std = @import("std");
const mining = @import("mining.zig");

test "MiningConfig default is auto" {
    const config = mining.MiningConfig.default();
    try std.testing.expectEqual(mining.MiningConfigType.auto, std.meta.activeTag(config));
}

test "MiningConfig interval holds block time" {
    const config: mining.MiningConfig = .{ .interval = .{ .block_time = 15 } };
    try std.testing.expectEqual(mining.MiningConfigType.interval, std.meta.activeTag(config));
    switch (config) {
        .interval => |iv| try std.testing.expectEqual(@as(u64, 15), iv.block_time),
        else => return error.TestUnexpectedResult,
    }
}

test "MiningConfig manual variant" {
    const config: mining.MiningConfig = .manual;
    try std.testing.expectEqual(mining.MiningConfigType.manual, std.meta.activeTag(config));
}

test "MiningConfig interval with zero block time" {
    const config: mining.MiningConfig = .{ .interval = .{ .block_time = 0 } };
    switch (config) {
        .interval => |iv| try std.testing.expectEqual(@as(u64, 0), iv.block_time),
        else => return error.TestUnexpectedResult,
    }
}
