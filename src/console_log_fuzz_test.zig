//! Property and fuzz suites for Hardhat console.log capture and
//! `tevm_drainConsoleLogs`.
//!
//! Every property is one `check*(input: []const u8) !void` function that decodes a
//! structured case from raw bytes. Two drivers feed it:
//!
//! - `runProperty`: a seeded PRNG loop (deterministic, 1,000+ iterations) with a
//!   zero-dependency shrinker that prints the smallest failing input.
//! - `std.testing.fuzz`: the same function as a coverage-guided fuzz target
//!   (`zig build test --fuzz`, Linux only on Zig 0.15.2); without `--fuzz` it
//!   replays the seed corpus.
//!
//! Ported from the fuzz-fable-3-zevm-fusaka suite. Its blob fee and BPO
//! sections targeted a superseded blob schedule API; main's equivalents live in
//! `src/fuzz/blob_fee_fuzz_test.zig`.

const std = @import("std");
const primitives = @import("primitives");
const jsonrpc = @import("jsonrpc");
const console_log = @import("console_log.zig");
const dispatcher = @import("rpc/dispatcher.zig");
const dispatch_wiring = @import("rpc/dispatch_wiring.zig");
const runtime_mod = @import("node/runtime.zig");

const CONSOLE_BUFFER_ITERATIONS: usize = 2_000;
const CONSOLE_OOM_ITERATIONS: usize = 1_000;
const CONSOLE_EVM_SEQUENCES: usize = 60;

const U64_EDGES = [_]u64{
    0,
    1,
    2,
    1 << 32,
    1 << 53,
    std.math.maxInt(i64),
    1 << 63,
    std.math.maxInt(u64) - 1,
    std.math.maxInt(u64),
};

// ============================================================================
// Drivers: byte source, seeded PRNG loop, shrinker, fuzz adapter
// ============================================================================

/// Decodes structured values from raw fuzz bytes. Reads past the end yield zero.
const Source = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn exhausted(self: *const Source) bool {
        return self.pos >= self.bytes.len;
    }

    fn byte(self: *Source) u8 {
        if (self.pos >= self.bytes.len) return 0;
        defer self.pos += 1;
        return self.bytes[self.pos];
    }

    fn int(self: *Source, comptime T: type) T {
        var value: T = 0;
        inline for (0..@sizeOf(T)) |_| value = (value << 8) | self.byte();
        return value;
    }

    /// A u64 biased toward boundaries: edge values, edge neighbors, and every bit width.
    fn interestingU64(self: *Source) u64 {
        const mode = self.byte() % 6;
        const raw = self.int(u64);
        return switch (mode) {
            0 => raw,
            1 => raw >> @as(u6, @intCast(self.byte() % 64)),
            2 => U64_EDGES[raw % U64_EDGES.len],
            3 => U64_EDGES[raw % U64_EDGES.len] +% (self.byte() % 5) -% 2,
            4 => (raw % 64) * 131_072 + (self.byte() % 3),
            else => raw % 200_000_000,
        };
    }

    fn interestingU256(self: *Source) u256 {
        return switch (self.byte() % 6) {
            0 => @as(u256, self.int(u16) % 1_000),
            1 => @as(u256, self.interestingU64()),
            2 => self.int(u256) >> self.byte(),
            3 => @as(u256, std.math.maxInt(u256)) - self.byte(),
            4 => @as(u256, self.int(u16)) * 1_000_000_000,
            else => self.int(u256),
        };
    }
};

fn printInput(input: []const u8) void {
    std.debug.print("0x", .{});
    for (input) |value| std.debug.print("{x:0>2}", .{value});
}

/// Shrinks a failing input in place: truncate, then zero bytes, while it still fails.
/// Returns the shrunk length.
fn shrink(buf: []u8, comptime testOne: fn ([]const u8) anyerror!void) usize {
    var len = buf.len;
    var progress = true;
    while (progress) {
        progress = false;
        var cut = len / 2;
        while (cut > 0) : (cut /= 2) {
            while (len >= cut) {
                if (testOne(buf[0 .. len - cut])) |_| break else |_| {
                    len -= cut;
                    progress = true;
                }
            }
        }
        for (buf[0..len]) |*value| {
            if (value.* == 0) continue;
            const saved = value.*;
            value.* = 0;
            if (testOne(buf[0..len])) |_| {
                value.* = saved;
            } else |_| {
                progress = true;
            }
        }
    }
    return len;
}

/// Runs `testOne` on `iterations` PRNG-generated inputs. On failure it prints the
/// seed, the iteration, and a shrunk input that reproduces the failure.
fn runProperty(
    comptime name: []const u8,
    seed: u64,
    iterations: usize,
    comptime max_len: usize,
    comptime testOne: fn ([]const u8) anyerror!void,
) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var buf: [max_len]u8 = undefined;
    for (0..iterations) |iteration| {
        const len = if (iteration % 8 == 0) random.uintLessThan(usize, max_len + 1) else max_len;
        random.bytes(buf[0..len]);
        testOne(buf[0..len]) catch |err| {
            std.debug.print("\nproperty '{s}' failed with {s}: seed=0x{x} iteration={d}\n  input=", .{ name, @errorName(err), seed, iteration });
            printInput(buf[0..len]);
            const shrunk_len = shrink(buf[0..len], testOne);
            std.debug.print("\n  shrunk=", .{});
            printInput(buf[0..shrunk_len]);
            std.debug.print("\n", .{});
            return err;
        };
    }
}

fn fuzzTarget(comptime testOne: fn ([]const u8) anyerror!void) fn (void, []const u8) anyerror!void {
    return struct {
        fn run(_: void, input: []const u8) anyerror!void {
            try testOne(input);
        }
    }.run;
}

fn clampU64(value: anytype) u64 {
    return if (value > std.math.maxInt(u64)) std.math.maxInt(u64) else @intCast(value);
}

// ============================================================================
// 1. Hardhat console.log capture and tevm_drainConsoleLogs
// ============================================================================

const CALLDATA_LENGTH_EDGES = [_]usize{ 0, 1, 3, 4, 5, 31, 32, 33, 36, 100, 255, 256, 257, 1_023, 1_024 };

fn decodeCalldataLength(src: *Source) usize {
    return switch (src.byte() % 3) {
        0 => CALLDATA_LENGTH_EDGES[src.byte() % CALLDATA_LENGTH_EDGES.len],
        1 => src.byte() % 68,
        else => src.int(u16) % 1_025,
    };
}

/// Fills `buf[0..len]` with calldata that is unique per (`sequence`, `seed`).
fn fillCalldata(buf: *[1_024]u8, len: usize, sequence: usize, seed: u8) []const u8 {
    for (buf[0..len], 0..) |*value, index| value.* = seed +% @as(u8, @truncate(index *% 31 +% sequence *% 7));
    if (len >= 2) std.mem.writeInt(u16, buf[0..2], @truncate(sequence), .big);
    return buf[0..len];
}

/// Reference FIFO: keeps the newest `capacity` entries.
const ConsoleModel = struct {
    capacity: usize,
    entries: std.ArrayList([]u8) = .{},

    fn deinit(self: *ConsoleModel) void {
        self.clear();
        self.entries.deinit(std.testing.allocator);
    }

    fn clear(self: *ConsoleModel) void {
        for (self.entries.items) |entry| std.testing.allocator.free(entry);
        self.entries.clearRetainingCapacity();
    }

    fn record(self: *ConsoleModel, calldata: []const u8) !void {
        if (self.capacity == 0) return;
        if (self.entries.items.len >= self.capacity) std.testing.allocator.free(self.entries.orderedRemove(0));
        try self.entries.append(std.testing.allocator, try std.testing.allocator.dupe(u8, calldata));
    }
};

fn expectDrainMatchesModel(buffer: *console_log.ConsoleLogBuffer, model: *ConsoleModel) !void {
    var drained = buffer.drain();
    defer drained.deinit();
    try std.testing.expectEqual(model.entries.items.len, drained.entries.items.len);
    for (model.entries.items, drained.entries.items) |want, got| try std.testing.expectEqualSlices(u8, want, got);
    model.clear();
    try std.testing.expectEqual(@as(usize, 0), buffer.len());
}

fn expectEmptyDrain(buffer: *console_log.ConsoleLogBuffer) !void {
    var drained = buffer.drain();
    defer drained.deinit();
    try std.testing.expectEqual(@as(usize, 0), drained.entries.items.len);
}

fn checkConsoleBuffer(input: []const u8) anyerror!void {
    var src = Source{ .bytes = input };
    const capacity: usize = switch (src.byte() % 6) {
        0 => 0,
        1 => 1,
        2 => 2,
        3 => 7,
        4 => 64,
        else => console_log.DEFAULT_CAPACITY,
    };
    var buffer = console_log.ConsoleLogBuffer.init(std.testing.allocator);
    defer buffer.deinit();
    buffer.capacity = capacity;
    var model = ConsoleModel{ .capacity = capacity };
    defer model.deinit();

    var calldata_buf: [1_024]u8 = undefined;
    var sequence: usize = 0;
    var operations: usize = 0;
    while (!src.exhausted() and operations < 256) : (operations += 1) {
        switch (src.byte() % 8) {
            0, 1, 2 => {
                const calldata = fillCalldata(&calldata_buf, decodeCalldataLength(&src), sequence, src.byte());
                sequence += 1;
                buffer.record(calldata);
                try model.record(calldata);
            },
            3 => {
                // The EVM hook: succeeds with empty output and zero gas for any gas limit.
                const calldata = fillCalldata(&calldata_buf, decodeCalldataLength(&src), sequence, src.byte());
                sequence += 1;
                const override = buffer.precompileOverride();
                try std.testing.expect(override.address.equals(console_log.ADDRESS));
                const output = try override.execute(override.context, std.testing.allocator, calldata, src.interestingU64());
                try std.testing.expect(output.success);
                try std.testing.expectEqual(@as(usize, 0), output.output.len);
                try std.testing.expectEqual(@as(u64, 0), output.gas_used);
                try model.record(calldata);
            },
            4 => {
                // Burst past the capacity: the oldest entries wrap out.
                const burst = @min(capacity, 80) + 1 + src.byte() % 4;
                for (0..burst) |_| {
                    const calldata = fillCalldata(&calldata_buf, 2 + src.byte() % 4, sequence, 0);
                    sequence += 1;
                    buffer.record(calldata);
                    try model.record(calldata);
                }
            },
            5 => try expectDrainMatchesModel(&buffer, &model),
            6 => {
                // Re-draining an empty buffer is idempotent.
                try expectDrainMatchesModel(&buffer, &model);
                try expectEmptyDrain(&buffer);
                try expectEmptyDrain(&buffer);
            },
            else => try std.testing.expectEqual(model.entries.items.len, buffer.len()),
        }
        try std.testing.expectEqual(model.entries.items.len, buffer.len());
        try std.testing.expect(buffer.len() <= capacity);
    }
    try expectDrainMatchesModel(&buffer, &model);
    try expectEmptyDrain(&buffer);
}

test "console fuzz: ConsoleLogBuffer matches a bounded FIFO model" {
    try runProperty("console-buffer-model", 0xC0_0001, CONSOLE_BUFFER_ITERATIONS, 192, checkConsoleBuffer);
}

test "console fuzz: ConsoleLogBuffer (std.testing.fuzz)" {
    try std.testing.fuzz({}, fuzzTarget(checkConsoleBuffer), .{ .corpus = &.{
        "",
        "\x01\x00\x00\x00\x00\x00\x00\x00\x05\x06",
        "\x02\x04\x00\x00\x00\x04\x01\x01\x01\x05\x06\x03\x00\x0e\x09\x00",
        "\x00\x00\x00\x0e\x01\x05",
    } });
}

/// Under allocation failure the buffer drops entries but never leaks, never
/// reorders, and never exceeds its capacity.
fn checkConsoleBufferOutOfMemory(input: []const u8) anyerror!void {
    var src = Source{ .bytes = input };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = src.byte() % 48 });
    const capacity: usize = 1 + src.byte() % 12;
    var buffer = console_log.ConsoleLogBuffer.init(failing.allocator());
    defer buffer.deinit();
    buffer.capacity = capacity;

    var calldata_buf: [1_024]u8 = undefined;
    const records: usize = src.byte() % 64;
    for (0..records) |sequence| {
        // Zero-length calldata allocates nothing, so every length is at least 2 and carries its sequence.
        buffer.record(fillCalldata(&calldata_buf, 2 + decodeCalldataLength(&src) % 64, sequence, 0));
        try std.testing.expect(buffer.len() <= capacity);
    }

    var drained = buffer.drain();
    defer drained.deinit();
    try std.testing.expect(drained.entries.items.len <= @min(capacity, records));
    var previous: ?u16 = null;
    for (drained.entries.items) |entry| {
        const sequence = std.mem.readInt(u16, entry[0..2], .big);
        try std.testing.expect(sequence < records);
        if (previous) |before| try std.testing.expect(sequence > before);
        previous = sequence;
    }
    try expectEmptyDrain(&buffer);
}

test "console fuzz: ConsoleLogBuffer survives allocation failure without leaks" {
    try runProperty("console-buffer-oom", 0xC0_0002, CONSOLE_OOM_ITERATIONS, 160, checkConsoleBufferOutOfMemory);
}

const ConsoleWriter = struct {
    buffer: *console_log.ConsoleLogBuffer,
    thread_id: u8,
    records: u16,

    fn run(self: ConsoleWriter) void {
        var sequence: u16 = 0;
        while (sequence < self.records) : (sequence += 1) {
            var entry: [3]u8 = undefined;
            entry[0] = self.thread_id;
            std.mem.writeInt(u16, entry[1..3], sequence, .big);
            self.buffer.record(&entry);
        }
    }
};

test "console fuzz: concurrent console writers keep per-thread FIFO order" {
    const thread_count = 4;
    const records_per_thread: u16 = 500;
    for ([_]usize{ console_log.DEFAULT_CAPACITY, 64 }) |capacity| {
        var buffer = console_log.ConsoleLogBuffer.init(std.testing.allocator);
        defer buffer.deinit();
        buffer.capacity = capacity;

        var threads: [thread_count]std.Thread = undefined;
        for (&threads, 0..) |*thread, index| {
            thread.* = try std.Thread.spawn(.{}, ConsoleWriter.run, .{ConsoleWriter{
                .buffer = &buffer,
                .thread_id = @intCast(index),
                .records = records_per_thread,
            }});
        }
        for (threads) |thread| thread.join();

        var drained = buffer.drain();
        defer drained.deinit();
        try std.testing.expectEqual(@min(capacity, thread_count * @as(usize, records_per_thread)), drained.entries.items.len);
        var next_sequence = [_]?u16{null} ** thread_count;
        for (drained.entries.items) |entry| {
            const sequence = std.mem.readInt(u16, entry[1..3], .big);
            if (next_sequence[entry[0]]) |expected| {
                try std.testing.expectEqual(expected, sequence);
            }
            next_sequence[entry[0]] = sequence + 1;
        }
        // Without wrap-around every thread delivered its whole run.
        if (capacity == console_log.DEFAULT_CAPACITY) {
            for (next_sequence) |sequence| try std.testing.expectEqual(@as(?u16, records_per_thread), sequence);
        }
    }
}

fn makeRequest(method: []const u8, params: ?std.json.Value) !jsonrpc.envelope.RequestEnvelope {
    return .{
        .jsonrpc = try std.testing.allocator.dupe(u8, "2.0"),
        .id = .{ .integer = 1 },
        .method = try std.testing.allocator.dupe(u8, method),
        .params = params,
    };
}

fn dispatchWith(allocator: std.mem.Allocator, rt: *runtime_mod.NodeRuntime, method: []const u8, params: ?std.json.Value) !jsonrpc.envelope.ResponseEnvelope {
    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, rt);
    var request = try makeRequest(method, params);
    defer request.deinit(std.testing.allocator);
    return dispatcher.dispatch(allocator, request, &handlers);
}

fn dispatch(rt: *runtime_mod.NodeRuntime, method: []const u8, params: ?std.json.Value) !jsonrpc.envelope.ResponseEnvelope {
    return dispatchWith(std.testing.allocator, rt, method, params);
}

const CONSOLE_ADDRESS_TEXT = "0x000000000000000000636f6e736f6c652e6c6f67";
const CALL_FORWARDER_TEXT = "0x00000000000000000000000000000000000c0de1";
const STATICCALL_FORWARDER_TEXT = "0x00000000000000000000000000000000000c0de2";
const SENDER_TEXT = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266";
const SUCCESS_WORD = "0x0000000000000000000000000000000000000000000000000000000000000001";

/// Runtime code that forwards its whole calldata to the Hardhat console address
/// with `call_opcode` (0xf1 CALL or 0xfa STATICCALL) and returns the success flag.
fn consoleForwarderCode(comptime call_opcode: u8) []const u8 {
    const copy_calldata = [_]u8{ 0x36, 0x60, 0x00, 0x60, 0x00, 0x37 }; // CALLDATACOPY(0, 0, CALLDATASIZE)
    const return_and_args = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x36, 0x60, 0x00 }; // retSize retOffset argsSize argsOffset
    const value = if (call_opcode == 0xf1) [_]u8{ 0x60, 0x00 } else [_]u8{};
    const call = [_]u8{0x73} ++ console_log.ADDRESS.bytes ++ [_]u8{ 0x5a, call_opcode }; // PUSH20 console, GAS, CALL
    const return_flag = [_]u8{ 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 }; // MSTORE(0, flag); RETURN(0, 32)
    const code = copy_calldata ++ return_and_args ++ value ++ call ++ return_flag;
    return &code;
}

fn hexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const text = try allocator.alloc(u8, 2 + bytes.len * 2);
    text[0] = '0';
    text[1] = 'x';
    for (bytes, 0..) |value, index| {
        text[2 + index * 2] = "0123456789abcdef"[value >> 4];
        text[3 + index * 2] = "0123456789abcdef"[value & 0x0f];
    }
    return text;
}

/// Sends `method` (eth_call or eth_estimateGas) to `to` with `data_hex` and returns the response.
fn dispatchTransaction(rt: *runtime_mod.NodeRuntime, method: []const u8, to: []const u8, data_hex: []const u8) !jsonrpc.envelope.ResponseEnvelope {
    var tx = std.json.ObjectMap.init(std.testing.allocator);
    defer tx.deinit();
    try tx.put("from", .{ .string = SENDER_TEXT });
    try tx.put("to", .{ .string = to });
    try tx.put("data", .{ .string = data_hex });

    var params = std.json.Array.init(std.testing.allocator);
    defer params.deinit();
    try params.append(.{ .object = tx });
    if (std.mem.eql(u8, method, "eth_call")) try params.append(.{ .string = "latest" });
    return dispatch(rt, method, .{ .array = params });
}

/// `tevm_drainConsoleLogs` returns exactly the model, as lowercase 0x-hex, oldest first.
fn expectRpcDrainMatchesModel(rt: *runtime_mod.NodeRuntime, model: *ConsoleModel) !void {
    var response = try dispatch(rt, "tevm_drainConsoleLogs", null);
    defer response.deinit(std.testing.allocator);
    try std.testing.expect(response.error_value == null);
    const logs = response.result.?.array.items;
    try std.testing.expectEqual(model.entries.items.len, logs.len);
    for (model.entries.items, logs) |want, got| {
        const want_hex = try hexAlloc(std.testing.allocator, want);
        defer std.testing.allocator.free(want_hex);
        try std.testing.expectEqualStrings(want_hex, got.string);
    }
    model.clear();
}

fn checkConsoleEvmSequence(input: []const u8) anyerror!void {
    const allocator = std.testing.allocator;
    var src = Source{ .bytes = input };
    var rt = try runtime_mod.NodeRuntime.init(allocator, null);
    defer rt.deinit();
    try rt.state.setCode(try primitives.Address.fromHex(CALL_FORWARDER_TEXT), consoleForwarderCode(0xf1));
    try rt.state.setCode(try primitives.Address.fromHex(STATICCALL_FORWARDER_TEXT), consoleForwarderCode(0xfa));

    const capacity: usize = switch (src.byte() % 5) {
        0 => 1,
        1 => 2,
        2 => 5,
        else => console_log.DEFAULT_CAPACITY,
    };
    rt.console_logs.capacity = capacity;
    var model = ConsoleModel{ .capacity = capacity };
    defer model.deinit();

    var calldata_buf: [1_024]u8 = undefined;
    var sequence: usize = 0;
    var operations: usize = 0;
    while (!src.exhausted() and operations < 32) : (operations += 1) {
        const operation = src.byte() % 10;
        switch (operation) {
            0...6 => {
                const calldata = fillCalldata(&calldata_buf, decodeCalldataLength(&src), sequence, src.byte());
                sequence += 1;
                const data_hex = try hexAlloc(allocator, calldata);
                defer allocator.free(data_hex);

                const method: []const u8 = if (operation == 6) "eth_estimateGas" else "eth_call";
                const to: []const u8 = switch (operation) {
                    0, 1 => CALL_FORWARDER_TEXT,
                    2, 3, 6 => STATICCALL_FORWARDER_TEXT,
                    else => CONSOLE_ADDRESS_TEXT,
                };
                var response = try dispatchTransaction(&rt, method, to, data_hex);
                defer response.deinit(allocator);
                try std.testing.expect(response.error_value == null);
                if (operation <= 3) {
                    // The nested console call succeeded, under CALL and under STATICCALL.
                    try std.testing.expectEqualStrings(SUCCESS_WORD, response.result.?.string);
                } else if (operation <= 5) {
                    try std.testing.expectEqualStrings("0x", response.result.?.string);
                }
                // One request records exactly one entry.
                try model.record(calldata);
            },
            7 => try expectRpcDrainMatchesModel(&rt, &model),
            8 => {
                // Empty re-drain is idempotent.
                try expectRpcDrainMatchesModel(&rt, &model);
                try expectRpcDrainMatchesModel(&rt, &model);
                try expectRpcDrainMatchesModel(&rt, &model);
            },
            else => try std.testing.expectEqual(model.entries.items.len, rt.console_logs.len()),
        }
        try std.testing.expectEqual(model.entries.items.len, rt.console_logs.len());
    }
    try expectRpcDrainMatchesModel(&rt, &model);
    try expectRpcDrainMatchesModel(&rt, &model);
}

test "console fuzz: CALL, STATICCALL, and direct console calls drain in FIFO order over JSON-RPC" {
    // 60 sequences of up to 32 operations: about 1,300 EVM executions.
    try runProperty("console-evm-sequences", 0xC0_0003, CONSOLE_EVM_SEQUENCES, 128, checkConsoleEvmSequence);
}

test "console fuzz: console capture over JSON-RPC (std.testing.fuzz)" {
    try std.testing.fuzz({}, fuzzTarget(checkConsoleEvmSequence), .{ .corpus = &.{
        "",
        "\x03\x00\x00\x03\x11\x02\x00\x0e\x22\x04\x00\x00\x33\x07\x08",
        "\x00\x04\x00\x03\x01\x04\x00\x04\x02\x00\x00\x0e\x03\x06\x00\x03\x04\x08",
    } });
}

test "console fuzz: tevm_drainConsoleLogs leaks nothing when allocation fails mid-drain" {
    const allocator = std.testing.allocator;
    var rt = try runtime_mod.NodeRuntime.init(allocator, null);
    defer rt.deinit();

    var calldata_buf: [1_024]u8 = undefined;
    for (0..40) |fail_index| {
        for (0..6) |sequence| rt.console_logs.record(fillCalldata(&calldata_buf, 1 + sequence * 200, sequence, 0x5a));

        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        if (dispatchWith(failing.allocator(), &rt, "tevm_drainConsoleLogs", null)) |ok| {
            var response = ok;
            response.deinit(failing.allocator());
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }

        // Afterwards the node still drains cleanly: all six entries or none, never a partial or reordered list.
        var response = try dispatch(&rt, "tevm_drainConsoleLogs", null);
        defer response.deinit(allocator);
        try std.testing.expect(response.error_value == null);
        const remaining = response.result.?.array.items.len;
        try std.testing.expect(remaining == 0 or remaining == 6);
    }
}

// ============================================================================
// 2. Shrunk regressions for bugs found by the suites above
// ============================================================================

test "console regression: a direct call to the console address records one entry" {
    // The EVM runs precompile overrides for top-level calls too, so the extra
    // record in the simulation handler captured every direct console call twice.
    const allocator = std.testing.allocator;
    var rt = try runtime_mod.NodeRuntime.init(allocator, null);
    defer rt.deinit();

    var response = try dispatchTransaction(&rt, "eth_call", CONSOLE_ADDRESS_TEXT, "0xaabbccdd01");
    defer response.deinit(allocator);
    try std.testing.expect(response.error_value == null);
    try std.testing.expectEqualStrings("0x", response.result.?.string);

    var drained = try dispatch(&rt, "tevm_drainConsoleLogs", null);
    defer drained.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), drained.result.?.array.items.len);
    try std.testing.expectEqualStrings("0xaabbccdd01", drained.result.?.array.items[0].string);
}
