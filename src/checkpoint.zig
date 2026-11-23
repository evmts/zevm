const std = @import("std");
const builtin = @import("builtin");

const CHECKPOINT_FILE_NAME = "checkpoint";
const CHECKPOINT_TMP_PREFIX = "checkpoint.tmp.";
const CHECKPOINT_TMP_SUFFIX_BYTES = 8;
const CHECKPOINT_TMP_NAME_LEN = CHECKPOINT_TMP_PREFIX.len + CHECKPOINT_TMP_SUFFIX_BYTES * 2;
const CHECKPOINT_TMP_CREATE_ATTEMPTS = 8;

/// Persists `checkpoint_hash` crash-safely: the hex is written to a per-call
/// `checkpoint.tmp.<16 hex>` file created exclusively, flushed to disk, then
/// atomically renamed over `checkpoint`. Concurrent saves never share a temp
/// file, and a crash at any point leaves either the previous checkpoint or
/// the new one, never a truncated file.
pub fn saveCheckpoint(allocator: std.mem.Allocator, dir_path: []const u8, checkpoint_hash: [32]u8) !void {
    _ = allocator;
    try std.fs.cwd().makePath(dir_path);

    var dir = try std.fs.cwd().openDir(dir_path, .{});
    defer dir.close();

    var tmp_name_buf: [CHECKPOINT_TMP_NAME_LEN]u8 = undefined;
    const file = try createUniqueTempFile(dir, &tmp_name_buf);
    const tmp_name: []const u8 = tmp_name_buf[0..];

    {
        errdefer {
            file.close();
            dir.deleteFile(tmp_name) catch {};
        }

        const checkpoint_hex = std.fmt.bytesToHex(checkpoint_hash, .lower);
        try file.writeAll(checkpoint_hex[0..]);
        try file.sync();
    }
    file.close();

    dir.rename(tmp_name, CHECKPOINT_FILE_NAME) catch |err| {
        dir.deleteFile(tmp_name) catch {};
        return err;
    };

    // Persist the directory entry so the rename survives power loss. On Linux
    // `std.fs.Dir.openDir` uses O_PATH (which cannot be fsync'd), so open a
    // dedicated RDONLY directory fd on POSIX. Call the raw `fsync` syscall
    // directly because `std.posix.fsync` maps EINVAL/EROFS to `unreachable` in
    // Zig 0.15.2, whereas some filesystems legitimately reject directory sync.
    if (builtin.os.tag != .windows) {
        const dir_fd = try std.posix.open(dir_path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
        defer std.posix.close(dir_fd);
        while (try directorySyncNeedsRetry(std.posix.errno(std.posix.system.fsync(dir_fd)))) {}
    }
}

fn directorySyncNeedsRetry(errno: std.posix.E) !bool {
    return switch (errno) {
        .SUCCESS, .INVAL, .ROFS, .OPNOTSUPP, .NOSYS => false,
        .INTR => true,
        .IO => error.InputOutput,
        .NOSPC => error.NoSpaceLeft,
        .DQUOT => error.DiskQuota,
        else => error.Unexpected,
    };
}

test "directory sync retries interruption and propagates write failures" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try std.testing.expect(!try directorySyncNeedsRetry(.INVAL));
    try std.testing.expect(try directorySyncNeedsRetry(.INTR));
    try std.testing.expectError(error.InputOutput, directorySyncNeedsRetry(.IO));
    try std.testing.expectError(error.NoSpaceLeft, directorySyncNeedsRetry(.NOSPC));
}

/// Creates `checkpoint.tmp.<16 random hex>` with `.exclusive = true`, writing
/// the chosen name into `name_buf`. Retries on the (astronomically unlikely)
/// name collision so a concurrent or stale temp file is never reused.
fn createUniqueTempFile(dir: std.fs.Dir, name_buf: *[CHECKPOINT_TMP_NAME_LEN]u8) !std.fs.File {
    @memcpy(name_buf[0..CHECKPOINT_TMP_PREFIX.len], CHECKPOINT_TMP_PREFIX);
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        var suffix: [CHECKPOINT_TMP_SUFFIX_BYTES]u8 = undefined;
        std.crypto.random.bytes(&suffix);
        const suffix_hex = std.fmt.bytesToHex(suffix, .lower);
        @memcpy(name_buf[CHECKPOINT_TMP_PREFIX.len..], suffix_hex[0..]);

        return dir.createFile(name_buf[0..], .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                if (attempt + 1 >= CHECKPOINT_TMP_CREATE_ATTEMPTS) return err;
                continue;
            },
            else => return err,
        };
    }
}

pub fn loadCheckpoint(allocator: std.mem.Allocator, dir_path: []const u8) ![32]u8 {
    const checkpoint_path = try std.fs.path.join(allocator, &.{ dir_path, CHECKPOINT_FILE_NAME });
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

    _ = dir.statFile(CHECKPOINT_FILE_NAME) catch return false;
    return true;
}

fn expectNoUniqueTempFiles(dir: std.fs.Dir) !void {
    var iterable = try dir.openDir(".", .{ .iterate = true });
    defer iterable.close();
    var it = iterable.iterate();
    while (try it.next()) |entry| {
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, CHECKPOINT_TMP_PREFIX));
    }
}

test "saveCheckpoint ignores a stale legacy temp file and leaves no per-call temp file" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp_dir.sub_path});
    defer std.testing.allocator.free(dir_path);

    // A crash mid-write in an older build left a partial fixed-name temp file.
    try tmp_dir.dir.writeFile(.{ .sub_path = "checkpoint.tmp", .data = "partial" });

    const expected = [_]u8{0x5a} ** 32;
    try saveCheckpoint(std.testing.allocator, dir_path, expected);

    try expectNoUniqueTempFiles(tmp_dir.dir);
    const loaded = try loadCheckpoint(std.testing.allocator, dir_path);
    try std.testing.expectEqualSlices(u8, expected[0..], loaded[0..]);
}

test "concurrent saveCheckpoint calls never share a temp file" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp_dir.sub_path});
    defer std.testing.allocator.free(dir_path);

    const Worker = struct {
        fn run(path: []const u8, byte: u8, result: *?anyerror) void {
            var i: usize = 0;
            while (i < 32) : (i += 1) {
                saveCheckpoint(std.testing.allocator, path, [_]u8{byte} ** 32) catch |err| {
                    result.* = err;
                    return;
                };
            }
        }
    };

    var results = [_]?anyerror{ null, null, null, null };
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ dir_path, @as(u8, @intCast(index + 1)), &results[index] });
    }
    for (threads) |thread| thread.join();
    for (results) |result| try std.testing.expectEqual(@as(?anyerror, null), result);

    try expectNoUniqueTempFiles(tmp_dir.dir);
    const loaded = try loadCheckpoint(std.testing.allocator, dir_path);
    const first = loaded[0];
    try std.testing.expect(first >= 1 and first <= 4);
    for (loaded) |byte| try std.testing.expectEqual(first, byte);
}
