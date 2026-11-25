const std = @import("std");
const zevm = @import("zevm");
const difficulty = zevm.difficulty;

const Fixture = struct {
    parentTimestamp: []const u8,
    currentTimestamp: []const u8,
    parentDifficulty: []const u8,
    currentBlockNumber: []const u8,
    parentUncles: []const u8,
    currentDifficulty: []const u8,
};

const Counts = struct {
    passed: usize = 0,
    failed: usize = 0,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len > 2) return error.ExpectedSingleFixtureDirectory;
    const path = if (args.len == 2) args[1] else "lib/ethereum-tests/DifficultyTests";
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
        std.debug.print("Cannot open DifficultyTests at {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var counts: Counts = .{};
    while (try walker.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".json")) continue;
        runFile(allocator, dir, entry.path, &counts) catch |err| {
            std.debug.print("{s}: {s}\n", .{ entry.path, @errorName(err) });
            counts.failed += 1;
        };
    }

    std.debug.print("DifficultyTests: {d} passed, {d} failed\n", .{ counts.passed, counts.failed });
    if (counts.failed != 0) return error.DifficultyTestsFailed;
    if (counts.passed == 0) return error.NoDifficultyTests;
}

fn runFile(backing: std.mem.Allocator, dir: std.fs.Dir, path: []const u8, counts: *Counts) !void {
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();
    const json = try dir.readFileAlloc(allocator, path, 32 * 1024 * 1024);
    const suites = try std.json.parseFromSliceLeaky(
        std.json.ArrayHashMap(std.json.ArrayHashMap(std.json.Value)),
        allocator,
        json,
        .{},
    );
    if (suites.map.count() == 0) return error.EmptyFixtureFile;

    var suite_iter = suites.map.iterator();
    while (suite_iter.next()) |suite| {
        var forks = suite.value_ptr.map.iterator();
        var has_fork = false;
        while (forks.next()) |entry| {
            const name = entry.key_ptr.*;
            if (std.mem.eql(u8, name, "_info")) continue;
            has_fork = true;
            const fork = difficulty.forkFromName(name) orelse {
                std.debug.print("{s} [{s}/{s}]: unknown fork\n", .{ path, suite.key_ptr.*, name });
                counts.failed += 1;
                continue;
            };
            if (entry.value_ptr.* != .object or entry.value_ptr.object.count() == 0) {
                std.debug.print("{s} [{s}/{s}]: expected a nonempty case object\n", .{ path, suite.key_ptr.*, name });
                counts.failed += 1;
                continue;
            }

            var cases = entry.value_ptr.object.iterator();
            while (cases.next()) |case| {
                checkCase(allocator, fork, case.value_ptr.*) catch |err| {
                    std.debug.print("{s} [{s}/{s}/{s}]: {s}\n", .{ path, suite.key_ptr.*, name, case.key_ptr.*, @errorName(err) });
                    counts.failed += 1;
                    continue;
                };
                counts.passed += 1;
            }
        }
        if (!has_fork) {
            std.debug.print("{s} [{s}]: no fixture forks\n", .{ path, suite.key_ptr.* });
            counts.failed += 1;
        }
    }
}

fn checkCase(allocator: std.mem.Allocator, fork: difficulty.DifficultyFork, value: std.json.Value) !void {
    const fixture = try std.json.parseFromValueLeaky(Fixture, allocator, value, .{ .ignore_unknown_fields = true });
    const actual = difficulty.calcDifficulty(
        fork,
        try parseHex(u64, fixture.parentTimestamp),
        try parseHex(u64, fixture.currentTimestamp),
        try parseHex(u256, fixture.parentDifficulty),
        try parseHex(u64, fixture.currentBlockNumber),
        try hasUncles(fixture.parentUncles),
    );
    const expected = try parseHex(u256, fixture.currentDifficulty);
    if (actual != expected) {
        std.debug.print("Expected difficulty 0x{x}, got 0x{x}; ", .{ expected, actual });
        return error.DifficultyMismatch;
    }
}

fn hexDigits(value: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, value, "0x")) return error.ExpectedHexPrefix;
    return value[2..];
}

fn parseHex(comptime T: type, value: []const u8) !T {
    return std.fmt.parseInt(T, try hexDigits(value), 16);
}

fn hasUncles(value: []const u8) !bool {
    const hex = try hexDigits(value);
    if (hex.len <= 2) {
        return switch (try std.fmt.parseInt(u8, hex, 16)) {
            0 => false,
            1 => true,
            else => error.InvalidParentUnclesFlag,
        };
    }

    // Ethereum headers store the Keccak-256 hash of the RLP-encoded uncle list.
    var hash: [32]u8 = undefined;
    if (hex.len != hash.len * 2) return error.InvalidParentUnclesHash;
    _ = try std.fmt.hexToBytes(&hash, hex);
    const empty_uncles_hash = "1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347";
    return !std.ascii.eqlIgnoreCase(hex, empty_uncles_hash);
}
