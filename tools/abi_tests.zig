//! Runs `ethereum-tests/ABITests` vectors against Voltaire's `primitives.Abi`.
//!
//! Usage: abi-tests <repo-root>
//!
//! Every case in `lib/ethereum-tests/ABITests/*.json` must either pass or be
//! listed in `exclusions` with a reason. Each passing case must encode its
//! `args` to exactly `result`, and decoding `result` then re-encoding must
//! reproduce `result`. An exclusion whose case now parses is reported as stale
//! so the list cannot silently outlive the gap it documents.

const std = @import("std");
const primitives = @import("primitives");

pub const fixture_dir = "lib/ethereum-tests/ABITests";

pub const Exclusion = struct {
    file: []const u8,
    case: []const u8,
    reason: []const u8,
};

pub const exclusions = [_]Exclusion{
    .{
        .file = "basic_abi_tests.json",
        .case = "GithubWikiTest",
        .reason = "uses uint32[] and bytes10, which primitives.Abi.AbiType does not define",
    },
};

pub const CaseOutcome = enum { passed, excluded };

pub const CaseError = error{
    InvalidFixture,
    UnsupportedAbiType,
    InvalidArgument,
    EncodingMismatch,
    RoundTripMismatch,
    StaleExclusion,
};

pub const Summary = struct {
    passed: usize = 0,
    failed: usize = 0,
    excluded: usize = 0,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 2) {
        std.debug.print("usage: abi-tests <repo-root>\n", .{});
        return error.InvalidArgument;
    }

    const dir_path = try std.fs.path.join(allocator, &.{ args[1], fixture_dir });
    defer allocator.free(dir_path);

    const summary = runDir(allocator, dir_path) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("ABITests fixtures not found at {s}; run `git submodule update --init --depth 1 -- lib/ethereum-tests`\n", .{dir_path});
        }
        return err;
    };
    std.debug.print("ABITests: {d} passed, {d} failed, {d} excluded\n", .{ summary.passed, summary.failed, summary.excluded });
    if (summary.failed != 0) return error.AbiTestsFailed;
    if (summary.passed == 0) return error.NoAbiTestsRan;
}

pub fn runDir(allocator: std.mem.Allocator, dir_path: []const u8) !Summary {
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, names.items, {}, lessThan);

    var summary: Summary = .{};
    for (names.items) |name| {
        const bytes = try dir.readFileAlloc(allocator, name, 16 * 1024 * 1024);
        defer allocator.free(bytes);
        try runFile(allocator, name, bytes, &summary);
    }
    return summary;
}

fn lessThan(_: void, lhs: []u8, rhs: []u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

pub fn runFile(allocator: std.mem.Allocator, file_name: []const u8, json_text: []const u8, summary: *Summary) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidFixture;

    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        const case_name = entry.key_ptr.*;
        const excluded = findExclusion(file_name, case_name);
        if (runCase(allocator, entry.value_ptr.*, excluded != null)) |outcome| switch (outcome) {
            .passed => summary.passed += 1,
            .excluded => {
                summary.excluded += 1;
                std.debug.print("EXCLUDED {s}/{s}: {s}\n", .{ file_name, case_name, excluded.?.reason });
            },
        } else |err| {
            summary.failed += 1;
            std.debug.print("FAIL {s}/{s}: {s}\n", .{ file_name, case_name, @errorName(err) });
        }
    }
}

fn findExclusion(file_name: []const u8, case_name: []const u8) ?Exclusion {
    for (exclusions) |exclusion| {
        if (std.mem.eql(u8, exclusion.file, file_name) and std.mem.eql(u8, exclusion.case, case_name)) return exclusion;
    }
    return null;
}

/// Runs one fixture case. `excluded` cases must fail to map onto
/// `primitives.Abi`; if they now map, the exclusion is stale.
pub fn runCase(parent_allocator: std.mem.Allocator, case: std.json.Value, excluded: bool) !CaseOutcome {
    var arena = std.heap.ArenaAllocator.init(parent_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    if (case != .object) return CaseError.InvalidFixture;
    const args = case.object.get("args") orelse return CaseError.InvalidFixture;
    const types = case.object.get("types") orelse return CaseError.InvalidFixture;
    const result = case.object.get("result") orelse return CaseError.InvalidFixture;
    if (args != .array or types != .array or result != .string) return CaseError.InvalidFixture;
    if (args.array.items.len != types.array.items.len) return CaseError.InvalidFixture;

    const expected = try decodeHex(allocator, result.string);

    const values = try allocator.alloc(primitives.Abi.AbiValue, types.array.items.len);
    const abi_types = try allocator.alloc(primitives.Abi.AbiType, types.array.items.len);
    for (types.array.items, args.array.items, values, abi_types) |type_json, arg, *value, *abi_type| {
        if (type_json != .string) return CaseError.InvalidFixture;
        value.* = parseValue(allocator, type_json.string, arg) catch |err| {
            if (excluded and err == CaseError.UnsupportedAbiType) return .excluded;
            return err;
        };
        abi_type.* = value.get_type();
    }
    if (excluded) return CaseError.StaleExclusion;

    const encoded = try primitives.Abi.encodeAbiParameters(allocator, values);
    if (!std.mem.eql(u8, encoded, expected)) return CaseError.EncodingMismatch;

    const decoded = try primitives.Abi.decodeAbiParameters(allocator, expected, abi_types);
    const reencoded = try primitives.Abi.encodeAbiParameters(allocator, decoded);
    if (!std.mem.eql(u8, reencoded, expected)) return CaseError.RoundTripMismatch;

    return .passed;
}

fn decodeHex(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const digits = if (std.mem.startsWith(u8, text, "0x")) text[2..] else text;
    if (digits.len % 2 != 0) return CaseError.InvalidFixture;
    const out = try allocator.alloc(u8, digits.len / 2);
    _ = std.fmt.hexToBytes(out, digits) catch return CaseError.InvalidFixture;
    return out;
}

/// Maps a Solidity type name onto the matching `primitives.Abi.AbiValue` member.
fn parseValue(allocator: std.mem.Allocator, type_name: []const u8, arg: std.json.Value) !primitives.Abi.AbiValue {
    inline for (@typeInfo(primitives.Abi.AbiValue).@"union".fields) |member| {
        if (std.mem.eql(u8, member.name, type_name)) {
            return @unionInit(primitives.Abi.AbiValue, member.name, try parseAs(member.type, allocator, arg));
        }
    }
    return CaseError.UnsupportedAbiType;
}

/// ABITests encode integers as JSON numbers, addresses as hex strings, and
/// `bytes`, `bytesN`, and `string` as literal ASCII strings.
fn parseAs(comptime T: type, allocator: std.mem.Allocator, arg: std.json.Value) !T {
    if (T == primitives.Address) {
        if (arg != .string) return CaseError.InvalidArgument;
        return primitives.Address.fromHex(arg.string) catch CaseError.InvalidArgument;
    }
    switch (@typeInfo(T)) {
        .int => return switch (arg) {
            .integer => |n| std.math.cast(T, n) orelse CaseError.InvalidArgument,
            .number_string, .string => |s| std.fmt.parseInt(T, s, 0) catch CaseError.InvalidArgument,
            else => CaseError.InvalidArgument,
        },
        .bool => return switch (arg) {
            .bool => |b| b,
            else => CaseError.InvalidArgument,
        },
        .array => |info| {
            var out: T = undefined;
            if (info.child == u8) {
                if (arg != .string or arg.string.len != info.len) return CaseError.InvalidArgument;
                @memcpy(&out, arg.string);
                return out;
            }
            if (arg != .array or arg.array.items.len != info.len) return CaseError.InvalidArgument;
            for (arg.array.items, &out) |item, *slot| slot.* = try parseAs(info.child, allocator, item);
            return out;
        },
        .pointer => |info| {
            if (info.size != .slice) @compileError("unsupported AbiValue payload " ++ @typeName(T));
            if (info.child == u8) {
                if (arg != .string) return CaseError.InvalidArgument;
                return try allocator.dupe(u8, arg.string);
            }
            if (arg != .array) return CaseError.InvalidArgument;
            const out = try allocator.alloc(info.child, arg.array.items.len);
            for (arg.array.items, out) |item, *slot| slot.* = try parseAs(info.child, allocator, item);
            return out;
        },
        else => @compileError("unsupported AbiValue payload " ++ @typeName(T)),
    }
}

fn runCaseText(json_text: []const u8, excluded: bool) !CaseOutcome {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_text, .{});
    defer parsed.deinit();
    return runCase(std.testing.allocator, parsed.value, excluded);
}

test "integer and address vector encodes and round-trips" {
    try std.testing.expectEqual(CaseOutcome.passed, try runCaseText(
        \\{"args": [324124, "0xcd2a3d9f938e13cd947ec05abc7fe734df8dd826"],
        \\ "result": "000000000000000000000000000000000000000000000000000000000004f21c000000000000000000000000cd2a3d9f938e13cd947ec05abc7fe734df8dd826",
        \\ "types": ["uint256", "address"]}
    , false));
}

test "dynamic bytes and array vector encodes and round-trips" {
    try std.testing.expectEqual(CaseOutcome.passed, try runCaseText(
        \\{"args": [[1, 2], "Hi"],
        \\ "result": "0x000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000024869000000000000000000000000000000000000000000000000000000000000",
        \\ "types": ["uint256[]", "bytes"]}
    , false));
}

test "wrong expected result is an encoding mismatch" {
    try std.testing.expectError(CaseError.EncodingMismatch, runCaseText(
        \\{"args": [1], "result": "0000000000000000000000000000000000000000000000000000000000000002", "types": ["uint256"]}
    , false));
}

test "unknown type fails unless excluded" {
    const text =
        \\{"args": [[1]], "result": "", "types": ["uint32[]"]}
    ;
    try std.testing.expectError(CaseError.UnsupportedAbiType, runCaseText(text, false));
    try std.testing.expectEqual(CaseOutcome.excluded, try runCaseText(text, true));
}

test "excluded case that maps onto primitives.Abi is stale" {
    try std.testing.expectError(CaseError.StaleExclusion, runCaseText(
        \\{"args": [1], "result": "0000000000000000000000000000000000000000000000000000000000000001", "types": ["uint256"]}
    , true));
}
