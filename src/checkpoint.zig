const std = @import("std");

pub fn saveCheckpoint(allocator: std.mem.Allocator, dir_path: []const u8, checkpoint_hash: [32]u8) !void {
    try std.fs.cwd().makePath(dir_path);

    const checkpoint_path = try std.fs.path.join(allocator, &.{ dir_path, "checkpoint" });
    defer allocator.free(checkpoint_path);

    var file = try std.fs.cwd().createFile(checkpoint_path, .{ .truncate = true });
    defer file.close();

    const checkpoint_hex = std.fmt.bytesToHex(checkpoint_hash, .lower);
    try file.writeAll(checkpoint_hex[0..]);
}

pub fn loadCheckpoint(allocator: std.mem.Allocator, dir_path: []const u8) ![32]u8 {
    const checkpoint_path = try std.fs.path.join(allocator, &.{ dir_path, "checkpoint" });
    defer allocator.free(checkpoint_path);

    var file = try std.fs.cwd().openFile(checkpoint_path, .{});
    defer file.close();

    const encoded_checkpoint = try file.readToEndAlloc(allocator, 1024);
    defer allocator.free(encoded_checkpoint);

    const trimmed = std.mem.trim(u8, encoded_checkpoint, " \t\r\n");
    if (trimmed.len != 64) {
        return error.InvalidCheckpointLength;
    }

    var checkpoint_hash: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(checkpoint_hash[0..], trimmed);
    return checkpoint_hash;
}

pub fn checkpointExists(dir_path: []const u8) bool {
    var dir = std.fs.cwd().openDir(dir_path, .{}) catch return false;
    defer dir.close();

    _ = dir.statFile("checkpoint") catch return false;
    return true;
}
