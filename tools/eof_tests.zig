//! Run the ethereum-tests EOF1 validation fixtures. A fork key labels an
//! independent expected result. The fixture format does not model activation.
const std = @import("std");
const zevm = @import("zevm");
const eof = zevm.eof;

const Result = struct {
    result: bool,
    exception: ?std.json.Value = null, // Some fixture producers use a list.
};

const Vector = struct {
    code: []const u8,
    containerKind: []const u8 = "RUNTIME",
    results: std.json.ArrayHashMap(Result),
};

const Fixture = struct { vectors: std.json.ArrayHashMap(Vector) };

const Counts = struct {
    files: usize = 0,
    vectors: usize = 0,
    results: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
    api_passed: usize = 0,
    api_failed: usize = 0,
    opcode_conflicts: usize = 0,
    input_errors: usize = 0,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len > 2) return error.ExpectedSingleFixtureDirectory;
    const path = if (args.len == 2) args[1] else "lib/ethereum-tests/EOFTests";
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
        std.debug.print("Cannot open EOFTests at {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    defer dir.close();

    std.debug.print(
        "EOFTests profile: ethereum-tests EOF1 draft (data kind 0x04, 2-byte subcontainer sizes, absolute max stack height).\n" ++
            "Later EIP-3540 uses data kind 0xff and 4-byte subcontainer sizes. EIP-5450 records max stack increase above inputs.\n",
        .{},
    );
    var counts: Counts = .{};
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".json")) continue;
        counts.files += 1;
        const before = counts;
        runFile(allocator, dir, entry.path, &counts) catch |err| {
            std.debug.print("{s}: {s}\n", .{ entry.path, @errorName(err) });
            counts.input_errors += 1;
        };
        std.debug.print("{s}: {d} passed, {d} failed, {d} opcode-profile conflicts, {d} input errors\n", .{
            entry.path,
            counts.passed - before.passed,
            counts.failed - before.failed,
            counts.opcode_conflicts - before.opcode_conflicts,
            counts.input_errors - before.input_errors,
        });
    }
    std.debug.print("validateContainer: {d} passed, {d} failed. Confirmed 0x5b profile differences: {d}\n", .{
        counts.api_passed, counts.api_failed, counts.opcode_conflicts,
    });
    std.debug.print("EOFTests (fixture rules): {d} files, {d} vectors, {d} fork results, {d} passed, {d} failed, {d} input errors\n", .{
        counts.files, counts.vectors, counts.results, counts.passed, counts.failed, counts.input_errors,
    });
    if (counts.failed != 0 or counts.input_errors != 0) return error.EOFTestsFailed;
    if (counts.results == 0) return error.NoEOFTests;
}

fn runFile(backing: std.mem.Allocator, dir: std.fs.Dir, path: []const u8, counts: *Counts) !void {
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();
    const json = try dir.readFileAlloc(allocator, path, 32 * 1024 * 1024);
    const fixtures = try std.json.parseFromSliceLeaky(std.json.ArrayHashMap(Fixture), allocator, json, .{ .ignore_unknown_fields = true });
    if (fixtures.map.count() == 0) return error.EmptyFixtureFile;

    var tests = fixtures.map.iterator();
    while (tests.next()) |t| {
        const test_name = t.key_ptr.*;
        if (t.value_ptr.vectors.map.count() == 0) {
            std.debug.print("{s} [{s}]: no vectors\n", .{ path, test_name });
            counts.input_errors += 1;
        }
        var vectors = t.value_ptr.vectors.map.iterator();
        while (vectors.next()) |v| {
            const vector = v.value_ptr.*;
            const vector_name = v.key_ptr.*;
            counts.vectors += 1;
            counts.results += vector.results.map.count();
            runVector(backing, path, test_name, vector_name, vector, counts) catch |err| {
                std.debug.print("{s} [{s}/{s}]: {s}\n", .{ path, test_name, vector_name, @errorName(err) });
                counts.input_errors += 1;
            };
        }
    }
}

fn runVector(
    allocator: std.mem.Allocator,
    path: []const u8,
    test_name: []const u8,
    vector_name: []const u8,
    vector: Vector,
    counts: *Counts,
) !void {
    if (vector.results.map.count() == 0) return error.EmptyFixtureResults;
    const kind: eof.ContainerKind = if (std.ascii.eqlIgnoreCase(vector.containerKind, "RUNTIME"))
        .runtime
    else if (std.ascii.eqlIgnoreCase(vector.containerKind, "INITCODE"))
        .initcode
    else
        return error.UnknownContainerKind;
    if (!std.mem.startsWith(u8, vector.code, "0x")) return error.ExpectedHexPrefix;
    const digits = vector.code[2..];
    if (digits.len % 2 != 0) return error.OddHexLength;
    const bytes = try allocator.alloc(u8, digits.len / 2);
    defer allocator.free(bytes);
    _ = try std.fmt.hexToBytes(bytes, digits);

    var results = vector.results.map.iterator();
    while (results.next()) |r| {
        const fork = r.key_ptr.*;
        const expected = r.value_ptr.*;
        const api = try validationResult(eof.validateContainer(allocator, bytes, kind));
        if (expected.result == (api == null)) counts.api_passed += 1 else counts.api_failed += 1;
        // A byte in a PUSH immediate or in data is never a NOP. Retry only
        // when the decoder actually encounters this opcode as an instruction.
        var rejection = api;
        if (api != null and api.? == error.LegacyJumpdest) {
            rejection = try validationResult(eof.validateWithEip4750Nop(allocator, bytes, kind));
            if (rejection == null) {
                counts.opcode_conflicts += 1;
                std.debug.print("{s} [{s}/{s}/{s}, {s}]: strict API rejects 0x5b, valid under EIP-4750 NOP\n", .{
                    path, test_name, vector_name, fork, @tagName(kind),
                });
            }
        }
        if (expected.result == (rejection == null)) {
            counts.passed += 1;
            continue;
        }
        counts.failed += 1;
        std.debug.print("{s} [{s}/{s}/{s}, {s}]: expected {s}, got {s}", .{
            path,
            test_name,
            vector_name,
            fork,
            @tagName(kind),
            if (expected.result) "valid" else "invalid",
            if (rejection) |err| @errorName(err) else "valid",
        });
        if (expected.exception) |exception| {
            const description = try std.json.Stringify.valueAlloc(allocator, exception, .{});
            defer allocator.free(description);
            std.debug.print(" (fixture exception {s})", .{description});
        }
        std.debug.print("\n", .{});
    }
}

fn validationResult(result: eof.ValidationError!void) error{OutOfMemory}!?eof.ValidationError {
    result catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return @as(?eof.ValidationError, err);
    };
    return null;
}
