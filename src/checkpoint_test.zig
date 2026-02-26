const std = @import("std");
const checkpoint = @import("checkpoint.zig");

fn testDirPath(allocator: std.mem.Allocator, tmp_dir: *std.testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp_dir.sub_path});
}

test "save then load checkpoint" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir_path = try testDirPath(std.testing.allocator, &tmp_dir);
    defer std.testing.allocator.free(dir_path);

    const expected: [32]u8 = .{
        0x00, 0x01, 0x02, 0x03,
        0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0A, 0x0B,
        0x0C, 0x0D, 0x0E, 0x0F,
        0x10, 0x11, 0x12, 0x13,
        0x14, 0x15, 0x16, 0x17,
        0x18, 0x19, 0x1A, 0x1B,
        0x1C, 0x1D, 0x1E, 0x1F,
    };

    try checkpoint.saveCheckpoint(std.testing.allocator, dir_path, expected);
    const loaded = try checkpoint.loadCheckpoint(std.testing.allocator, dir_path);

    try std.testing.expectEqualSlices(u8, expected[0..], loaded[0..]);
    try std.testing.expect(checkpoint.checkpointExists(dir_path));
}

test "checkpointExists returns false for nonexistent path" {
    var tmp_dir = std.testing.tmpDir(.{});
    const dir_path = try testDirPath(std.testing.allocator, &tmp_dir);
    defer std.testing.allocator.free(dir_path);
    tmp_dir.cleanup();

    try std.testing.expect(!checkpoint.checkpointExists(dir_path));
}

test "save overwrites existing checkpoint" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir_path = try testDirPath(std.testing.allocator, &tmp_dir);
    defer std.testing.allocator.free(dir_path);

    const first: [32]u8 = [_]u8{0x11} ** 32;
    const second: [32]u8 = [_]u8{0xEE} ** 32;

    try checkpoint.saveCheckpoint(std.testing.allocator, dir_path, first);
    try checkpoint.saveCheckpoint(std.testing.allocator, dir_path, second);

    const loaded = try checkpoint.loadCheckpoint(std.testing.allocator, dir_path);
    try std.testing.expectEqualSlices(u8, second[0..], loaded[0..]);
}
