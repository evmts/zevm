const std = @import("std");
const zevm = @import("zevm");
const Hardfork = @import("guillotine_mini").Hardfork;
const encoding = zevm.transaction_encoding;

const Result = struct {
    exception: ?[]const u8 = null,
    hash: ?[]const u8 = null,
    intrinsicGas: ?[]const u8 = null,
    sender: ?[]const u8 = null,
};

const Fixture = struct {
    txbytes: []const u8,
    result: std.json.ArrayHashMap(Result),
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
    const path = if (args.len == 2) args[1] else "lib/ethereum-tests/TransactionTests";
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
        std.debug.print("Cannot open TransactionTests at {s}: {s}\n", .{ path, @errorName(err) });
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
    std.debug.print("TransactionTests: {d} passed, {d} failed\n", .{ counts.passed, counts.failed });
    if (counts.failed != 0) return error.TransactionTestsFailed;
    if (counts.passed == 0) return error.NoTransactionTests;
}

fn runFile(backing: std.mem.Allocator, dir: std.fs.Dir, path: []const u8, counts: *Counts) !void {
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();
    const json = try dir.readFileAlloc(allocator, path, 32 * 1024 * 1024);
    const fixtures = try std.json.parseFromSliceLeaky(std.json.ArrayHashMap(Fixture), allocator, json, .{ .ignore_unknown_fields = true });
    if (fixtures.map.count() == 0) return error.EmptyFixtureFile;

    var tests = fixtures.map.iterator();
    while (tests.next()) |test_entry| {
        const fixture = test_entry.value_ptr.*;
        const hex = try hexDigits(fixture.txbytes);
        const raw = try std.fmt.hexToBytes(try allocator.alloc(u8, hex.len / 2), hex);
        if (fixture.result.map.count() == 0) return error.EmptyFixtureResults;
        var results = fixture.result.map.iterator();
        while (results.next()) |entry| {
            const name = entry.key_ptr.*;
            checkResult(allocator, raw, name, entry.value_ptr.*) catch |err| {
                std.debug.print("{s} [{s}/{s}]: {s}\n", .{ path, test_entry.key_ptr.*, name, @errorName(err) });
                counts.failed += 1;
                continue;
            };
            counts.passed += 1;
        }
    }
}

fn hexDigits(value: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, value, "0x")) return error.ExpectedHexPrefix;
    return value[2..];
}

fn hardfork(name: []const u8) !Hardfork {
    if (std.mem.eql(u8, name, "EIP150")) return .TANGERINE_WHISTLE;
    if (std.mem.eql(u8, name, "EIP158")) return .SPURIOUS_DRAGON;
    if (std.mem.eql(u8, name, "ConstantinopleFix")) return .PETERSBURG;
    if (std.mem.eql(u8, name, "Paris")) return .MERGE;
    // The pinned corpus misspells Cancun in one result.
    if (std.mem.eql(u8, name, "Cancnun")) return .CANCUN;
    return Hardfork.fromString(name) orelse error.UnknownFixtureFork;
}

fn checkResult(allocator: std.mem.Allocator, raw: []const u8, name: []const u8, expected: Result) !void {
    const fork = try hardfork(name);
    const actual = evaluate(allocator, raw, fork) catch |err| {
        if (expected.exception != null and err != error.OutOfMemory) return;
        return err;
    };
    if (expected.exception) |exception| {
        std.debug.print("Expected rejection ({s}); ", .{exception});
        return error.UnexpectedAcceptance;
    }

    var hash: [32]u8 = undefined;
    const hash_hex = try hexDigits(expected.hash orelse return error.MissingExpectedHash);
    if (hash_hex.len != hash.len * 2) return error.InvalidExpectedHash;
    _ = try std.fmt.hexToBytes(&hash, hash_hex);
    if (!std.mem.eql(u8, &hash, &encoding.transactionHash(raw))) return error.HashMismatch;

    var sender: [20]u8 = undefined;
    const sender_hex = try hexDigits(expected.sender orelse return error.MissingExpectedSender);
    if (sender_hex.len != sender.len * 2) return error.InvalidExpectedSender;
    _ = try std.fmt.hexToBytes(&sender, sender_hex);
    if (!std.mem.eql(u8, &sender, &actual.sender)) return error.SenderMismatch;

    const gas = try std.fmt.parseInt(u64, try hexDigits(expected.intrinsicGas orelse return error.MissingExpectedIntrinsicGas), 16);
    if (gas != actual.intrinsic_gas) {
        std.debug.print("Expected gas {d}, got {d}; ", .{ gas, actual.intrinsic_gas });
        return error.IntrinsicGasMismatch;
    }
}

fn evaluate(allocator: std.mem.Allocator, raw: []const u8, fork: Hardfork) !struct { sender: [20]u8, intrinsic_gas: u64 } {
    try encoding.requireCanonicalEnvelope(raw);
    const decoded = try encoding.decodeEnvelope(allocator, raw);
    defer decoded.deinit(allocator);
    const gas = try zevm.tx_processor.validateEnvelope(decoded, fork, 1);
    const sender = try encoding.recoverEnvelopeSenderForFork(allocator, decoded, fork);
    return .{ .sender = sender.bytes, .intrinsic_gas = gas };
}
