//! Runner for `ethereum-tests/TrieTests`.
//!
//! Usage: `zig build trie-tests` (or `trie-tests <repo-root>`).
//!
//! Each fixture case is replayed against the trie code ZEVM uses for
//! consensus roots and proofs:
//!   - `primitives.TrieHash.trie_root` / `secure_trie_root` (block, receipt,
//!     storage, and state roots), and
//!   - `zevm.mpt_proof.secureProof` (eth_getProof) for secure-trie cases: the
//!     proof root and the hash-linked proof path must match the fixture root.
//!
//! Fixture semantics follow go-ethereum's TrieTests runner: strings starting
//! with `0x` are hex-decoded, other strings are raw bytes; ordered `in` lists
//! are applied in sequence where a `null` or empty value deletes the key.
//!
//! Exclusion: `trietestnextprev.json` checks iterator next/prev ordering.
//! ZEVM exposes no trie iterator, so the file is reported as excluded.

const std = @import("std");
const primitives = @import("primitives");
const zevm = @import("zevm");

const fixture_dir = "lib/ethereum-tests/TrieTests";

const TrieTestError = error{
    MissingArgument,
    InvalidFixture,
    RootMismatch,
    ProofMismatch,
    UnknownFixtureFile,
};

const FixtureFile = struct {
    name: []const u8,
    kind: Kind,

    const Kind = enum { plain, secure, excluded };
};

/// Every file in TrieTests must appear here so new upstream files fail loudly
/// instead of being silently ignored.
const fixture_files = [_]FixtureFile{
    .{ .name = "hex_encoded_securetrie_test.json", .kind = .secure },
    .{ .name = "trieanyorder.json", .kind = .plain },
    .{ .name = "trieanyorder_secureTrie.json", .kind = .secure },
    .{ .name = "trietest.json", .kind = .plain },
    .{ .name = "trietest_secureTrie.json", .kind = .secure },
    .{ .name = "trietestnextprev.json", .kind = .excluded },
};

const Summary = struct {
    passed: usize = 0,
    failed: usize = 0,
    excluded_files: usize = 0,
};

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 2) return TrieTestError.MissingArgument;

    const dir_path = try std.fs.path.join(allocator, &.{ args[1], fixture_dir });
    defer allocator.free(dir_path);

    const summary = try runFixtureDir(allocator, dir_path);
    std.debug.print("trie-tests: complete passed={d} failed={d} excluded_files={d}\n", .{
        summary.passed,
        summary.failed,
        summary.excluded_files,
    });
    if (summary.failed != 0) return TrieTestError.RootMismatch;
}

fn runFixtureDir(allocator: std.mem.Allocator, dir_path: []const u8) !Summary {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("trie-tests: cannot open {s}: {s} (run `git submodule update --init lib/ethereum-tests`)\n", .{ dir_path, @errorName(err) });
        return err;
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        if (findFixtureFile(entry.name) == null) {
            std.debug.print("trie-tests: unclassified fixture file {s}\n", .{entry.name});
            return TrieTestError.UnknownFixtureFile;
        }
    }

    var summary = Summary{};
    for (fixture_files) |file| {
        if (file.kind == .excluded) {
            std.debug.print("trie-tests: excluded {s} (iterator next/prev; ZEVM has no trie iterator)\n", .{file.name});
            summary.excluded_files += 1;
            continue;
        }
        const bytes = try dir.readFileAlloc(allocator, file.name, 16 * 1024 * 1024);
        defer allocator.free(bytes);
        try runFixtureFile(allocator, file.name, bytes, file.kind == .secure, &summary);
    }
    return summary;
}

fn findFixtureFile(name: []const u8) ?FixtureFile {
    for (fixture_files) |file| {
        if (std.mem.eql(u8, file.name, name)) return file;
    }
    return null;
}

fn runFixtureFile(allocator: std.mem.Allocator, file_name: []const u8, bytes: []const u8, secure: bool, summary: *Summary) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return TrieTestError.InvalidFixture;

    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        runCase(allocator, entry.value_ptr.*, secure) catch |err| {
            summary.failed += 1;
            std.debug.print("trie-tests: FAIL {s}/{s}: {s}\n", .{ file_name, entry.key_ptr.*, @errorName(err) });
            continue;
        };
        summary.passed += 1;
    }
}

fn runCase(parent_allocator: std.mem.Allocator, case: std.json.Value, secure: bool) !void {
    var arena = std.heap.ArenaAllocator.init(parent_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    if (case != .object) return TrieTestError.InvalidFixture;
    const input = case.object.get("in") orelse return TrieTestError.InvalidFixture;
    const root_value = case.object.get("root") orelse return TrieTestError.InvalidFixture;
    if (root_value != .string) return TrieTestError.InvalidFixture;
    const expected_bytes = try decodeString(allocator, root_value.string);
    if (expected_bytes.len != 32) return TrieTestError.InvalidFixture;
    const expected: [32]u8 = expected_bytes[0..32].*;

    var entries = std.StringArrayHashMapUnmanaged([]const u8){};
    switch (input) {
        .array => |pairs| for (pairs.items) |pair| {
            if (pair != .array or pair.array.items.len != 2) return TrieTestError.InvalidFixture;
            try applyUpdate(allocator, &entries, pair.array.items[0], pair.array.items[1]);
        },
        .object => |map| {
            var map_it = map.iterator();
            while (map_it.next()) |kv| {
                try applyUpdate(allocator, &entries, .{ .string = kv.key_ptr.* }, kv.value_ptr.*);
            }
        },
        else => return TrieTestError.InvalidFixture,
    }

    const keys = entries.keys();
    const values = entries.values();
    const actual = if (secure)
        try primitives.TrieHash.secure_trie_root(allocator, keys, values)
    else
        try primitives.TrieHash.trie_root(allocator, keys, values);
    if (!std.mem.eql(u8, &actual, &expected)) return TrieTestError.RootMismatch;

    if (secure) {
        for (keys) |key| try checkSecureProof(allocator, keys, values, key, expected);
    }
}

fn applyUpdate(
    allocator: std.mem.Allocator,
    entries: *std.StringArrayHashMapUnmanaged([]const u8),
    key_value: std.json.Value,
    value_value: std.json.Value,
) !void {
    if (key_value != .string) return TrieTestError.InvalidFixture;
    const key = try decodeString(allocator, key_value.string);
    const value: []const u8 = switch (value_value) {
        .null => &.{},
        .string => |text| try decodeString(allocator, text),
        else => return TrieTestError.InvalidFixture,
    };
    if (value.len == 0) {
        _ = entries.orderedRemove(key);
    } else {
        try entries.put(allocator, key, value);
    }
}

fn decodeString(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, text, "0x")) return text;
    const hex = text[2..];
    if (hex.len % 2 != 0) return TrieTestError.InvalidFixture;
    const out = try allocator.alloc(u8, hex.len / 2);
    _ = std.fmt.hexToBytes(out, hex) catch return TrieTestError.InvalidFixture;
    return out;
}

/// Checks the eth_getProof trie path: the proof root equals the fixture
/// root, the first node hashes to the root, and every later hash-referenced
/// node is referenced by the node before it.
fn checkSecureProof(
    allocator: std.mem.Allocator,
    keys: []const []const u8,
    values: []const []const u8,
    target_key: []const u8,
    expected_root: [32]u8,
) !void {
    var proof = try zevm.mpt_proof.secureProof(allocator, keys, values, target_key);
    defer proof.deinit(allocator);
    if (!std.mem.eql(u8, &proof.root, &expected_root)) return TrieTestError.ProofMismatch;
    if (proof.nodes.len == 0) return TrieTestError.ProofMismatch;

    var root_hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(proof.nodes[0], &root_hash, .{});
    if (!std.mem.eql(u8, &root_hash, &expected_root)) return TrieTestError.ProofMismatch;
    for (proof.nodes[0 .. proof.nodes.len - 1], proof.nodes[1..]) |parent, child| {
        var child_hash: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(child, &child_hash, .{});
        if (std.mem.indexOf(u8, parent, &child_hash) == null) return TrieTestError.ProofMismatch;
    }
}

test "ordered input applies deletions (trietest emptyValues)" {
    const fixture =
        \\{"emptyValues": {"in": [["do","verb"],["ether","wookiedoo"],["horse","stallion"],
        \\["shaman","horse"],["doge","coin"],["ether",null],["dog","puppy"],["shaman",null]],
        \\"root": "0x5991bb8c6514148a29db676a14ac506cd2cd5775ace63c30a4fe457715e9ac84"}}
    ;
    var summary = Summary{};
    try runFixtureFile(std.testing.allocator, "inline", fixture, false, &summary);
    try std.testing.expectEqual(@as(usize, 1), summary.passed);
    try std.testing.expectEqual(@as(usize, 0), summary.failed);
}

test "secure trie with hex keys and values also checks proofs" {
    const fixture =
        \\{"test1": {"in": {"0xa94f5374fce5edbc8e2a8697c15331677e6ebf0b": "0xf848018405f446a7a056e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421a0c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
        \\"0x095e7baea6a6c7c4c2dfeb977efac326af552d87": "0xf8440101a056e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421a004bccc5d94f4d1f99aab44369a910179931772f2a5c001c3229f57831c102769",
        \\"0xd2571607e241ecf590ed94b12d87c94babe36db6": "0xf8440180a0ba4b47865c55a341a4a78759bb913cd15c3ee8eaf30a62fa8d1c8863113d84e8a0c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
        \\"0x62c01474f089b07dae603491675dc5b5748f7049": "0xf8448080a056e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421a0c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
        \\"0x2adc25665018aa1fe0e6bc666dac8fc2697ff9ba": "0xf8478083019a59a056e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421a0c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"},
        \\"root": "0x730a444e08ab4b8dee147c9b232fc52d34a223d600031c1e9d25bfc985cbd797", "hexEncoded": true}}
    ;
    var summary = Summary{};
    try runFixtureFile(std.testing.allocator, "inline", fixture, true, &summary);
    try std.testing.expectEqual(@as(usize, 0), summary.failed);
    try std.testing.expectEqual(@as(usize, 1), summary.passed);
}

test "root mismatch is reported as a failure" {
    const fixture =
        \\{"wrong": {"in": {"A": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
        \\"root": "0x0000000000000000000000000000000000000000000000000000000000000000"}}
    ;
    var summary = Summary{};
    try runFixtureFile(std.testing.allocator, "inline", fixture, false, &summary);
    try std.testing.expectEqual(@as(usize, 0), summary.passed);
    try std.testing.expectEqual(@as(usize, 1), summary.failed);
}
