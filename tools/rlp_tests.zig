//! Runner for `ethereum-tests/RLPTests` against the voltaire RLP codec.
//!
//! Each fixture case is `{"in": <value>, "out": "<hex>"}`:
//! - `in` is a JSON value: encode it and require the bytes to equal `out`,
//!   then decode `out` and require the decoded tree to re-encode to `out`.
//! - `in == "VALID"`: decode `out` and require it to re-encode to `out`.
//! - `in == "INVALID"`: require decoding `out` to fail.
//!
//! Strings beginning with `#` are arbitrary-precision decimal integers.
//! Run with `zig build verify-rlp`.

const std = @import("std");
const primitives = @import("primitives");

pub const fixture_root = "lib/ethereum-tests/RLPTests";

pub const CaseError = error{
    InvalidFixture,
    EncodingMismatch,
    RoundTripMismatch,
    InvalidAccepted,
};

/// Runs one RLPTests case. Returns an error when ZEVM's RLP codec disagrees
/// with the fixture.
pub fn runCase(parent_allocator: std.mem.Allocator, case: std.json.Value) !void {
    var arena = std.heap.ArenaAllocator.init(parent_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    if (case != .object) return CaseError.InvalidFixture;
    const in = case.object.get("in") orelse return CaseError.InvalidFixture;
    const out_value = case.object.get("out") orelse return CaseError.InvalidFixture;
    if (out_value != .string) return CaseError.InvalidFixture;
    const out = try hexToBytes(allocator, out_value.string);

    if (in == .string and std.mem.eql(u8, in.string, "INVALID")) {
        if (primitives.Rlp.decode(allocator, out, false)) |_| {
            return CaseError.InvalidAccepted;
        } else |err| switch (err) {
            error.OutOfMemory => return err,
            else => return,
        }
    }

    if (!(in == .string and std.mem.eql(u8, in.string, "VALID"))) {
        const expected = try encodeJson(allocator, in);
        if (!std.mem.eql(u8, expected, out)) return CaseError.EncodingMismatch;
    }

    const decoded = try primitives.Rlp.decode(allocator, out, false);
    const reencoded = try encodeData(allocator, decoded.data);
    if (!std.mem.eql(u8, reencoded, out)) return CaseError.RoundTripMismatch;
}

/// Returns sorted fixture paths relative to `root_path`. Free with
/// `freeFixtureFiles`.
pub fn listFixtureFiles(allocator: std.mem.Allocator, root_path: []const u8) ![][]u8 {
    var dir = try std.fs.openDirAbsolute(root_path, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var files = std.ArrayList([]u8){};
    errdefer {
        for (files.items) |file| allocator.free(file);
        files.deinit(allocator);
    }
    while (try walker.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".json")) continue;
        try files.append(allocator, try allocator.dupe(u8, entry.path));
    }
    std.mem.sort([]u8, files.items, {}, lessThanPath);
    return files.toOwnedSlice(allocator);
}

pub fn freeFixtureFiles(allocator: std.mem.Allocator, files: [][]u8) void {
    for (files) |file| allocator.free(file);
    allocator.free(files);
}

fn lessThanPath(_: void, lhs: []u8, rhs: []u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

fn hexToBytes(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const digits = if (std.mem.startsWith(u8, text, "0x") or std.mem.startsWith(u8, text, "0X")) text[2..] else text;
    if (digits.len % 2 != 0) return CaseError.InvalidFixture;
    const bytes = try allocator.alloc(u8, digits.len / 2);
    _ = std.fmt.hexToBytes(bytes, digits) catch return CaseError.InvalidFixture;
    return bytes;
}

fn encodeJson(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    switch (value) {
        .string => |text| {
            if (std.mem.startsWith(u8, text, "#")) {
                return primitives.Rlp.encodeBytes(allocator, try decimalToBytes(allocator, text[1..]));
            }
            return primitives.Rlp.encodeBytes(allocator, text);
        },
        .number_string => |text| return primitives.Rlp.encodeBytes(allocator, try decimalToBytes(allocator, text)),
        .integer => |number| {
            if (number < 0) return CaseError.InvalidFixture;
            return primitives.Rlp.encode(allocator, @as(u64, @intCast(number)));
        },
        .array => |items| {
            var payload = std.ArrayList(u8){};
            defer payload.deinit(allocator);
            for (items.items) |item| {
                const encoded = try encodeJson(allocator, item);
                defer allocator.free(encoded);
                try payload.appendSlice(allocator, encoded);
            }
            return wrapList(allocator, payload.items);
        },
        else => return CaseError.InvalidFixture,
    }
}

fn encodeData(allocator: std.mem.Allocator, data: primitives.Rlp.Data) ![]u8 {
    switch (data) {
        .String => |bytes| return primitives.Rlp.encodeBytes(allocator, bytes),
        .List => |items| {
            var payload = std.ArrayList(u8){};
            defer payload.deinit(allocator);
            for (items) |item| {
                const encoded = try encodeData(allocator, item);
                defer allocator.free(encoded);
                try payload.appendSlice(allocator, encoded);
            }
            return wrapList(allocator, payload.items);
        },
    }
}

fn wrapList(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    var result = std.ArrayList(u8){};
    errdefer result.deinit(allocator);
    if (payload.len < 56) {
        try result.append(allocator, 0xc0 + @as(u8, @intCast(payload.len)));
    } else {
        const len_bytes = try primitives.Rlp.encodeLength(allocator, payload.len);
        defer allocator.free(len_bytes);
        try result.append(allocator, 0xf7 + @as(u8, @intCast(len_bytes.len)));
        try result.appendSlice(allocator, len_bytes);
    }
    try result.appendSlice(allocator, payload);
    return result.toOwnedSlice(allocator);
}

/// Converts an unsigned decimal string to minimal big-endian bytes. Zero is empty.
fn decimalToBytes(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (text.len == 0) return CaseError.InvalidFixture;
    var bytes = std.ArrayList(u8){};
    errdefer bytes.deinit(allocator);
    for (text) |char| {
        if (char < '0' or char > '9') return CaseError.InvalidFixture;
        var carry: u16 = char - '0';
        var index = bytes.items.len;
        while (index > 0) {
            index -= 1;
            const product = @as(u16, bytes.items[index]) * 10 + carry;
            bytes.items[index] = @truncate(product);
            carry = product >> 8;
        }
        if (carry != 0) try bytes.insert(allocator, 0, @intCast(carry));
    }
    return bytes.toOwnedSlice(allocator);
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 2) {
        std.debug.print("usage: rlp-tests <repo-root>\n", .{});
        return error.MissingArgument;
    }

    const root_path = try std.fs.path.join(allocator, &.{ args[1], fixture_root });
    defer allocator.free(root_path);
    const files = try listFixtureFiles(allocator, root_path);
    defer freeFixtureFiles(allocator, files);
    if (files.len == 0) return CaseError.InvalidFixture;

    var passed: usize = 0;
    var failed: usize = 0;
    for (files) |relative_path| {
        const path = try std.fs.path.join(allocator, &.{ root_path, relative_path });
        defer allocator.free(path);
        const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 32 * 1024 * 1024);
        defer allocator.free(bytes);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return CaseError.InvalidFixture;

        var it = parsed.value.object.iterator();
        while (it.next()) |entry| {
            if (runCase(allocator, entry.value_ptr.*)) |_| {
                passed += 1;
            } else |err| {
                failed += 1;
                std.debug.print("rlp-tests: FAIL {s}/{s} :: {s} error={s}\n", .{ fixture_root, relative_path, entry.key_ptr.*, @errorName(err) });
            }
        }
    }

    std.debug.print("rlp-tests: files={d} cases={d} passed={d} failed={d} skipped=0\n", .{ files.len, passed + failed, passed, failed });
    if (failed != 0) return error.RlpTestsFailed;
}

fn runCaseText(text: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
    defer parsed.deinit();
    try runCase(std.testing.allocator, parsed.value);
}

test "valid RLPTests vectors encode and round-trip" {
    // Vectors copied from ethereum-tests/RLPTests/rlptest.json.
    try runCaseText(
        \\{"in": "", "out": "0x80"}
    );
    try runCaseText(
        \\{"in": "\u0000", "out": "0x00"}
    );
    try runCaseText(
        \\{"in": 0, "out": "0x80"}
    );
    try runCaseText(
        \\{"in": 128, "out": "0x8180"}
    );
    try runCaseText(
        \\{"in": 100000, "out": "0x830186a0"}
    );
    try runCaseText(
        \\{"in": "#83729609699884896815286331701780722", "out": "0x8f102030405060708090a0b0c0d0e0f2"}
    );
    try runCaseText(
        \\{"in": "#115792089237316195423570985008687907853269984665640564039457584007913129639936",
        \\ "out": "0xa1010000000000000000000000000000000000000000000000000000000000000000"}
    );
    try runCaseText(
        \\{"in": "Lorem ipsum dolor sit amet, consectetur adipisicing elit",
        \\ "out": "0xb8384c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e7365637465747572206164697069736963696e6720656c6974"}
    );
    try runCaseText(
        \\{"in": ["zw", [4], 1], "out": "0xc6827a77c10401"}
    );
    try runCaseText(
        \\{"in": [[[], []], []], "out": "0xc4c2c0c0c0"}
    );
    try runCaseText(
        \\{"in": [["asdf","qwer","zxcv"],["asdf","qwer","zxcv"],["asdf","qwer","zxcv"],["asdf","qwer","zxcv"]],
        \\ "out": "0xf840cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376"}
    );
    try runCaseText(
        \\{"in": "VALID", "out": "0xc7c0c1c0c3c0c1c0"}
    );
}

test "invalid RLPTests vectors are rejected" {
    // Vectors copied from ethereum-tests/RLPTests/invalidRLPTest.json.
    const outs = [_][]const u8{
        "0xbf0f000000000000021111",
        "0xff0f000000000000021111",
        "0xf80180",
        "0xf80100",
        "0x8100",
        "0x817F",
        "b800",
        "f800",
        "b801ff",
        "f803112233",
        "",
        "81",
        "c5010203",
        "ba010000aabbccddeeff",
        "ffffffffffffffffff0001020304050607",
    };
    for (outs) |out| {
        const text = try std.fmt.allocPrint(std.testing.allocator, "{{\"in\": \"INVALID\", \"out\": \"{s}\"}}", .{out});
        defer std.testing.allocator.free(text);
        runCaseText(text) catch |err| {
            std.debug.print("unexpected failure for out={s}\n", .{out});
            return err;
        };
    }
}

test "runner reports codec disagreements" {
    try std.testing.expectError(CaseError.EncodingMismatch, runCaseText(
        \\{"in": "dog", "out": "0x83676f64"}
    ));
    try std.testing.expectError(CaseError.InvalidAccepted, runCaseText(
        \\{"in": "INVALID", "out": "0x83646f67"}
    ));
    try std.testing.expectError(error.NonCanonicalSize, runCaseText(
        \\{"in": "VALID", "out": "0x8100"}
    ));
    try std.testing.expectError(CaseError.InvalidFixture, runCaseText(
        \\{"in": -1, "out": "0x80"}
    ));
}
