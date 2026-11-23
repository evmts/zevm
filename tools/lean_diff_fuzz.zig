//! Differential fuzzer: zevm's Zig implementations against the Lean 4
//! reference spec (`spec/lean`, executable `zevm-spec`).
//!
//! The tool spawns `zevm-spec` once, sends one request line per case over
//! stdin, reads one response line from stdout, and compares it with the line
//! the Zig implementation produces for the same inputs. Any mismatch is a
//! divergence; the process exits 1 if at least one case diverges.
//!
//! Usage:
//!   lean-diff-fuzz --lean-bin <path> [--cases <N>] [--seed <u64>]
//!                  [--max-report <N>] [--skip-blob-wrappers]
//!
//! `--cases` is per domain (default 1000, seven domains, 7000 cases total).
//!
//! Domain          Zig implementation under test
//! BLOB_FEE        zevm.blob_fee.calcBlobBaseFee, zevm.blob_fee.calcExcessBlobGas
//! BASE_FEE        zevm.block_builder.expectedBaseFeePerGas
//! EFFECTIVE_GAS   zevm.tx_processor.transactionGasFloorForFork, effectiveGasUsed
//! RLP_DECODE      primitives.Rlp.decode
//! TX_DECODE       zevm.transaction_encoding.decodeBlobNetworkWrapper, decodeEnvelope
//! MODEXP          precompiles.modexp.execute
//! EVM_EXEC        guillotine_mini.Evm(.{}).call (Prague and Osaka)
//!
//! Module imports this file needs from build.zig: `zevm`, `primitives`,
//! `precompiles`, `guillotine_mini`. They must be the same module instances
//! the `zevm` module itself imports, so `primitives.Hardfork` is one type.
const std = @import("std");
const zevm = @import("zevm");
const primitives = @import("primitives");
const precompiles = @import("precompiles");
const guillotine_mini = @import("guillotine_mini");

const default_cases_per_domain: usize = 1000;
const default_seed: u64 = 0x2e5e_ed5e_c0de_0001;
const default_max_report: usize = 5;
const report_request_limit: usize = 600;

const bytes_per_blob: usize = 131_072;
const bytes_per_commitment: usize = 48;
const bytes_per_proof: usize = 48;
const cells_per_ext_blob: usize = 128;

const EvmType = guillotine_mini.Evm(.{});

const contract_address: primitives.Address = .{ .bytes = [_]u8{0xc0} ** 20 };
const caller_address: primitives.Address = .{ .bytes = [_]u8{0xca} ** 20 };

const NamedFork = struct {
    name: []const u8,
    fork: primitives.Hardfork,
};

const fork_byzantium: NamedFork = .{ .name = "byzantium", .fork = .BYZANTIUM };
const fork_istanbul: NamedFork = .{ .name = "istanbul", .fork = .ISTANBUL };
const fork_berlin: NamedFork = .{ .name = "berlin", .fork = .BERLIN };
const fork_london: NamedFork = .{ .name = "london", .fork = .LONDON };
const fork_shanghai: NamedFork = .{ .name = "shanghai", .fork = .SHANGHAI };
const fork_cancun: NamedFork = .{ .name = "cancun", .fork = .CANCUN };
const fork_prague: NamedFork = .{ .name = "prague", .fork = .PRAGUE };
const fork_osaka: NamedFork = .{ .name = "osaka", .fork = .OSAKA };

/// Weighted by repetition: Osaka and Prague dominate every domain.
const blob_forks = [_]NamedFork{ fork_osaka, fork_osaka, fork_osaka, fork_osaka, fork_prague, fork_prague, fork_cancun, fork_cancun, fork_shanghai, fork_london };
const gas_forks = [_]NamedFork{ fork_osaka, fork_osaka, fork_osaka, fork_prague, fork_prague, fork_prague, fork_cancun, fork_shanghai, fork_london, fork_berlin, fork_istanbul };
const modexp_forks = [_]NamedFork{ fork_osaka, fork_osaka, fork_osaka, fork_osaka, fork_prague, fork_prague, fork_prague, fork_cancun, fork_london, fork_berlin, fork_istanbul, fork_byzantium };
const evm_forks = [_]NamedFork{ fork_osaka, fork_prague };

/// One fuzz case: the request line sent to the Lean spec and the response
/// line the Zig implementation produces for the same inputs.
const Case = struct {
    request: std.ArrayList(u8) = .empty,
    expected: std.ArrayList(u8) = .empty,
};

const Fuzzer = struct {
    random: std.Random,
    skip_blob_wrappers: bool,
};

const Domain = struct {
    name: []const u8,
    generate: *const fn (fuzzer: *Fuzzer, allocator: std.mem.Allocator, case: *Case) anyerror!void,
};

const domains = [_]Domain{
    .{ .name = "BLOB_FEE", .generate = generateBlobFee },
    .{ .name = "BASE_FEE", .generate = generateBaseFee },
    .{ .name = "EFFECTIVE_GAS", .generate = generateEffectiveGas },
    .{ .name = "RLP_DECODE", .generate = generateRlpDecode },
    .{ .name = "TX_DECODE", .generate = generateTxDecode },
    .{ .name = "MODEXP", .generate = generateModexp },
    .{ .name = "EVM_EXEC", .generate = generateEvmExec },
};

const DomainStats = struct {
    cases: usize = 0,
    passed: usize = 0,
    diverged: usize = 0,
    elapsed_ms: u64 = 0,
};

// ---------------------------------------------------------------------------
// Lean child process
// ---------------------------------------------------------------------------

const LeanProcess = struct {
    child: std.process.Child,
    buffer: std.ArrayList(u8) = .empty,
    consumed: usize = 0,

    /// Sends `request_line` (which must end in '\n') and returns the response
    /// line without its newline. The slice is valid until the next call.
    fn ask(self: *LeanProcess, allocator: std.mem.Allocator, request_line: []const u8) ![]const u8 {
        const stdin = self.child.stdin orelse return error.LeanStdinClosed;
        const stdout = self.child.stdout orelse return error.LeanStdoutClosed;
        try stdin.writeAll(request_line);

        if (self.consumed > 0) {
            const rest = self.buffer.items.len - self.consumed;
            std.mem.copyForwards(u8, self.buffer.items[0..rest], self.buffer.items[self.consumed..]);
            self.buffer.shrinkRetainingCapacity(rest);
            self.consumed = 0;
        }

        var scan_from: usize = 0;
        while (true) {
            if (std.mem.indexOfScalarPos(u8, self.buffer.items, scan_from, '\n')) |newline| {
                self.consumed = newline + 1;
                return std.mem.trimRight(u8, self.buffer.items[0..newline], "\r ");
            }
            scan_from = self.buffer.items.len;
            var chunk: [4096]u8 = undefined;
            const read_len = try stdout.read(&chunk);
            if (read_len == 0) return error.LeanSpecExited;
            try self.buffer.appendSlice(allocator, chunk[0..read_len]);
        }
    }
};

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn pickFork(random: std.Random, comptime forks: []const NamedFork) NamedFork {
    return forks[random.uintLessThan(usize, forks.len)];
}

fn appendHex(allocator: std.mem.Allocator, out: *std.ArrayList(u8), bytes: []const u8) !void {
    if (bytes.len == 0) return out.append(allocator, '-');
    const digits = "0123456789abcdef";
    try out.ensureUnusedCapacity(allocator, bytes.len * 2);
    for (bytes) |byte| {
        out.appendAssumeCapacity(digits[byte >> 4]);
        out.appendAssumeCapacity(digits[byte & 0x0f]);
    }
}

fn appendRandomBytes(allocator: std.mem.Allocator, random: std.Random, out: *std.ArrayList(u8), len: usize) !void {
    const slice = try out.addManyAsSlice(allocator, len);
    random.bytes(slice);
}

/// A u256 biased toward boundary values.
fn randomU256(random: std.Random) u256 {
    const max_u256: u256 = std.math.maxInt(u256);
    return switch (random.uintLessThan(u8, 13)) {
        0 => 0,
        1 => 1,
        2 => max_u256,
        3 => @as(u256, 1) << 255,
        4 => (@as(u256, 1) << 255) - 1,
        5 => @as(u256, 1) << random.int(u8),
        6 => (@as(u256, 1) << random.int(u8)) -% 1,
        7 => random.int(u8),
        8 => random.int(u64),
        9 => max_u256 - random.int(u8),
        10 => random.int(u256) >> random.int(u8),
        11 => (@as(u256, 1) << 255) | (random.int(u256) >> random.int(u8)),
        else => random.int(u256),
    };
}

/// A u64 biased toward boundary values.
fn randomU64(random: std.Random) u64 {
    return switch (random.uintLessThan(u8, 7)) {
        0 => 0,
        1 => 1,
        2 => std.math.maxInt(u64),
        3 => random.int(u8),
        4 => random.int(u32),
        5 => @as(u64, 1) << random.uintLessThan(u6, 63),
        else => random.int(u64),
    };
}

/// Applies one random byte-level mutation.
fn mutateBytes(allocator: std.mem.Allocator, random: std.Random, bytes: *std.ArrayList(u8)) !void {
    if (bytes.items.len == 0) return bytes.append(allocator, random.int(u8));
    const position = random.uintLessThan(usize, bytes.items.len);
    switch (random.uintLessThan(u8, 6)) {
        0 => bytes.items[position] ^= @as(u8, 1) << random.int(u3),
        1 => bytes.items[position] = random.int(u8),
        2 => bytes.shrinkRetainingCapacity(position),
        3 => try bytes.append(allocator, random.int(u8)),
        4 => _ = bytes.orderedRemove(position),
        else => try bytes.insert(allocator, position, random.int(u8)),
    }
}

// ---------------------------------------------------------------------------
// RLP encoding (case construction only)
// ---------------------------------------------------------------------------

fn appendRlpHeader(allocator: std.mem.Allocator, out: *std.ArrayList(u8), payload_len: usize, short_base: u8) !void {
    if (payload_len < 56) {
        return out.append(allocator, short_base + @as(u8, @intCast(payload_len)));
    }
    var length_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &length_bytes, payload_len, .big);
    var skip: usize = 0;
    while (length_bytes[skip] == 0) skip += 1;
    try out.append(allocator, short_base + 55 + @as(u8, @intCast(8 - skip)));
    try out.appendSlice(allocator, length_bytes[skip..]);
}

fn appendRlpString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), bytes: []const u8) !void {
    if (bytes.len == 1 and bytes[0] < 0x80) return out.append(allocator, bytes[0]);
    try appendRlpHeader(allocator, out, bytes.len, 0x80);
    try out.appendSlice(allocator, bytes);
}

fn appendRlpList(allocator: std.mem.Allocator, out: *std.ArrayList(u8), payload: []const u8) !void {
    try appendRlpHeader(allocator, out, payload.len, 0xc0);
    try out.appendSlice(allocator, payload);
}

fn appendRlpUint(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u256) !void {
    var word: [32]u8 = undefined;
    std.mem.writeInt(u256, &word, value, .big);
    var skip: usize = 0;
    while (skip < word.len and word[skip] == 0) skip += 1;
    try appendRlpString(allocator, out, word[skip..]);
}

fn appendRandomRlpString(allocator: std.mem.Allocator, random: std.Random, out: *std.ArrayList(u8), len: usize) !void {
    var bytes: std.ArrayList(u8) = .empty;
    try appendRandomBytes(allocator, random, &bytes, len);
    try appendRlpString(allocator, out, bytes.items);
}

fn appendRandomRlpItem(allocator: std.mem.Allocator, random: std.Random, out: *std.ArrayList(u8), depth: u8) std.mem.Allocator.Error!void {
    const make_list = depth < 4 and random.uintLessThan(u8, 10) < 4;
    if (!make_list) {
        const len: usize = switch (random.uintLessThan(u8, 10)) {
            0 => 0,
            1, 2 => 1,
            3 => 55,
            4 => 56,
            5 => 57 + random.uintLessThan(usize, 300),
            else => random.uintLessThan(usize, 40),
        };
        return appendRandomRlpString(allocator, random, out, len);
    }
    var payload: std.ArrayList(u8) = .empty;
    const count = random.uintLessThan(usize, 6);
    for (0..count) |_| try appendRandomRlpItem(allocator, random, &payload, depth + 1);
    try appendRlpList(allocator, out, payload.items);
}

// ---------------------------------------------------------------------------
// BLOB_FEE
// ---------------------------------------------------------------------------

fn generateBlobFee(fuzzer: *Fuzzer, allocator: std.mem.Allocator, case: *Case) anyerror!void {
    const random = fuzzer.random;
    const named = pickFork(random, &blob_forks);
    const gas_per_blob = zevm.blob_fee.GAS_PER_BLOB;
    const mainnet = [_][3]u64{
        .{ 3, 6, 3_338_477 },
        .{ 6, 9, 5_007_716 },
        .{ 10, 15, 8_346_193 },
        .{ 14, 21, 11_684_671 },
    };

    var target: u64 = undefined;
    var max: u64 = undefined;
    var fraction: u64 = undefined;
    switch (random.uintLessThan(u8, 5)) {
        0, 1, 2 => {
            const config = mainnet[random.uintLessThan(usize, mainnet.len)];
            target = config[0];
            max = config[1];
            fraction = config[2];
        },
        3 => {
            max = 1 + random.uintLessThan(u64, 64);
            target = 1 + random.uintLessThan(u64, max);
            fraction = 1 + random.uintLessThan(u64, 20_000_000);
        },
        else => {
            max = 1 + random.uintLessThan(u64, 64);
            target = 1 + random.uintLessThan(u64, max);
            fraction = (@as(u64, 1) << 54) + random.uintLessThan(u64, @as(u64, 1) << 63);
        },
    }
    const target_gas = target * gas_per_blob;
    const max_gas = max * gas_per_blob;

    const parent_excess: u64 = switch (random.uintLessThan(u8, 8)) {
        0 => 0,
        1, 2 => random.uintLessThan(u64, 2 * target_gas + 1),
        3, 4 => (fraction *| random.uintLessThan(u64, 170)) +| random.uintLessThan(u64, fraction),
        // e^177 is the last power that fits in a u256: straddle the saturation edge.
        5 => (fraction *| (170 + random.uintLessThan(u64, 12))) +| random.uintLessThan(u64, fraction),
        6 => random.int(u64),
        else => std.math.maxInt(u64) - random.uintLessThan(u64, 4 * target_gas),
    };
    const parent_used: u64 = switch (random.uintLessThan(u8, 7)) {
        0 => 0,
        1, 2 => gas_per_blob * random.uintAtMost(u64, max),
        // Lands on the target floor boundary, one below, or one above.
        3 => ((target_gas -| parent_excess) +| random.uintLessThan(u64, 3)) -| 1,
        4 => random.uintLessThan(u64, 2 * max_gas),
        5 => max_gas,
        else => random.int(u64),
    };

    const blob_base_fee = zevm.blob_fee.calcBlobBaseFee(parent_excess, fraction);
    const parent_base_fee: u256 = switch (random.uintLessThan(u8, 8)) {
        0 => 0,
        // EIP-7918 reserve boundary: active iff base_fee > 16 * blob_fee.
        1 => blob_base_fee *| 16,
        2 => (blob_base_fee *| 16) +| 1,
        3 => (blob_base_fee *| 16) -| 1,
        4 => random.uintLessThan(u64, 200_000_000_000),
        5 => random.uintLessThan(u64, 64),
        else => randomU256(random),
    };

    const params = zevm.blob_fee.BlobParams.fromConfig(.{
        .target = target,
        .max = max,
        .base_fee_update_fraction = fraction,
    });
    const next_excess = zevm.blob_fee.calcExcessBlobGas(named.fork, params, parent_excess, parent_used, parent_base_fee);

    try case.request.print(allocator, "BLOB_FEE {s} {d} {d} {d} {d} {d} {d}", .{
        named.name, target, max, fraction, parent_excess, parent_used, parent_base_fee,
    });
    try case.expected.print(allocator, "OK {d} {d}", .{ blob_base_fee, next_excess });
}

// ---------------------------------------------------------------------------
// BASE_FEE
// ---------------------------------------------------------------------------

fn generateBaseFee(fuzzer: *Fuzzer, allocator: std.mem.Allocator, case: *Case) anyerror!void {
    const random = fuzzer.random;
    const gas_limit: u64 = switch (random.uintLessThan(u8, 10)) {
        0 => random.uintLessThan(u64, 4),
        1 => 30_000_000,
        2 => 36_000_000,
        3 => 60_000_000,
        4 => 5_000 + random.uintLessThan(u64, 100_000_000),
        5 => random.int(u64),
        6 => std.math.maxInt(u64) - random.uintLessThan(u64, 3),
        else => 2 + random.uintLessThan(u64, 200_000_000),
    };
    const gas_target = gas_limit / 2;
    const gas_used: u64 = switch (random.uintLessThan(u8, 9)) {
        0 => gas_target,
        1 => gas_target +| 1,
        2 => gas_target -| 1,
        3 => 0,
        4 => gas_limit,
        5 => random.uintAtMost(u64, gas_limit),
        6 => random.uintAtMost(u64, gas_limit),
        7 => gas_limit +| random.uintLessThan(u64, 1_000),
        else => random.int(u64),
    };
    const base_fee: u256 = switch (random.uintLessThan(u8, 9)) {
        0 => random.uintLessThan(u64, 16),
        1 => 7,
        2 => 1_000_000_000,
        3, 4 => random.uintLessThan(u64, 500_000_000_000),
        5 => @as(u256, std.math.maxInt(u256)) - random.uintLessThan(u64, 16),
        6 => @as(u256, std.math.maxInt(u256)) / (1 + @as(u256, random.uintLessThan(u64, 16))),
        else => randomU256(random),
    };

    const parent = primitives.BlockHeader.BlockHeader{
        .gas_limit = gas_limit,
        .gas_used = gas_used,
        .base_fee_per_gas = base_fee,
    };
    try case.request.print(allocator, "BASE_FEE {d} {d} {d}", .{ base_fee, gas_used, gas_limit });
    if (zevm.block_builder.expectedBaseFeePerGas(&parent)) |next_base_fee| {
        try case.expected.print(allocator, "OK {d}", .{next_base_fee});
    } else |_| {
        try case.expected.appendSlice(allocator, "ERR");
    }
}

// ---------------------------------------------------------------------------
// EFFECTIVE_GAS
// ---------------------------------------------------------------------------

fn generateEffectiveGas(fuzzer: *Fuzzer, allocator: std.mem.Allocator, case: *Case) anyerror!void {
    const random = fuzzer.random;
    const named = pickFork(random, &gas_forks);
    const calldata_len: usize = switch (random.uintLessThan(u8, 8)) {
        0 => 0,
        1...3 => random.uintLessThan(usize, 64),
        4...6 => random.uintLessThan(usize, 4096),
        else => random.uintLessThan(usize, 1 << 20),
    };
    const calldata = try allocator.alloc(u8, calldata_len);
    defer allocator.free(calldata);
    const zero_percent: u8 = switch (random.uintLessThan(u8, 4)) {
        0 => 0,
        1 => 100,
        else => random.uintLessThan(u8, 100),
    };
    var zero_bytes: usize = 0;
    for (calldata) |*byte| {
        byte.* = if (random.uintLessThan(u8, 100) < zero_percent) 0 else random.intRangeAtMost(u8, 1, 255);
        zero_bytes += @intFromBool(byte.* == 0);
    }
    const non_zero_bytes = calldata.len - zero_bytes;
    const gas_floor = try zevm.tx_processor.transactionGasFloorForFork(calldata, named.fork);
    const intrinsic = zevm.tx_processor.intrinsicGasForFork(calldata, false, named.fork);
    const boundary = @max(gas_floor, intrinsic);

    const exec_gas: u64 = switch (random.uintLessThan(u8, 8)) {
        0 => intrinsic,
        1 => intrinsic + random.uintLessThan(u64, 100_000),
        // Straddle the floor so both arms of the final max() are taken.
        2, 3 => (boundary -| 200) + random.uintLessThan(u64, 400),
        4 => (boundary * 5 / 4 -| 200) + random.uintLessThan(u64, 400),
        5 => random.uintLessThan(u64, 30_000_000),
        6 => random.uintLessThan(u64, 1 << 40),
        else => random.uintLessThan(u64, 16),
    };
    const refund: u64 = switch (random.uintLessThan(u8, 7)) {
        0 => 0,
        1 => exec_gas / 5,
        2 => exec_gas / 5 + 1,
        3 => exec_gas / 2,
        4 => random.uintAtMost(u64, exec_gas),
        5 => exec_gas +| random.uintLessThan(u64, 1_000),
        else => random.int(u64),
    };

    const billed = zevm.tx_processor.effectiveGasUsed(exec_gas, gas_floor, refund, named.fork);
    try case.request.print(allocator, "EFFECTIVE_GAS {s} {d} {d} {d} {d}", .{
        named.name, exec_gas, refund, zero_bytes, non_zero_bytes,
    });
    try case.expected.print(allocator, "OK {d}", .{billed});
}

// ---------------------------------------------------------------------------
// RLP_DECODE
// ---------------------------------------------------------------------------

fn generateRlpDecode(fuzzer: *Fuzzer, allocator: std.mem.Allocator, case: *Case) anyerror!void {
    const random = fuzzer.random;
    var input: std.ArrayList(u8) = .empty;

    switch (random.uintLessThan(u8, 20)) {
        // Well-formed items.
        0...8 => try appendRandomRlpItem(allocator, random, &input, 0),
        // Well-formed, then one to three byte-level mutations.
        9...13 => {
            try appendRandomRlpItem(allocator, random, &input, 0);
            for (0..1 + random.uintLessThan(usize, 3)) |_| try mutateBytes(allocator, random, &input);
        },
        // Unstructured bytes.
        14, 15 => try appendRandomBytes(allocator, random, &input, random.uintLessThan(usize, 40)),
        // Two concatenated items: trailing bytes must be rejected.
        16 => {
            try appendRandomRlpItem(allocator, random, &input, 0);
            try appendRandomRlpItem(allocator, random, &input, 0);
        },
        // Hand-built canonical-form violations and boundaries.
        else => switch (random.uintLessThan(u8, 9)) {
            0 => {},
            1 => try input.appendSlice(allocator, &.{ 0x81, random.uintLessThan(u8, 0x80) }),
            2 => try input.appendSlice(allocator, &.{ 0x81, 0x80 + random.uintLessThan(u8, 0x80) }),
            3 => {
                const len = random.uintLessThan(u8, 56);
                try input.appendSlice(allocator, &.{ 0xb8, len });
                try appendRandomBytes(allocator, random, &input, len);
            },
            4 => {
                const len = 56 + random.uintLessThan(u8, 100);
                try input.appendSlice(allocator, &.{ 0xb9, 0x00, len });
                try appendRandomBytes(allocator, random, &input, len);
            },
            5 => {
                const len = random.uintLessThan(u8, 56);
                try input.appendSlice(allocator, &.{ 0xf8, len });
                for (0..@as(usize, len)) |_| try input.append(allocator, random.uintLessThan(u8, 0x80));
            },
            6 => {
                const len = 56 + random.uintLessThan(u8, 100);
                try input.appendSlice(allocator, &.{ 0xf9, 0x00, len });
                for (0..@as(usize, len)) |_| try input.append(allocator, random.uintLessThan(u8, 0x80));
            },
            7 => try input.append(allocator, 0xb7 + random.uintLessThan(u8, 9)),
            else => try input.appendSlice(allocator, &.{ 0xc1 + random.uintLessThan(u8, 5), 0x80 }),
        },
    }

    try case.request.appendSlice(allocator, "RLP_DECODE ");
    try appendHex(allocator, &case.request, input.items);

    if (primitives.Rlp.decode(allocator, input.items, false)) |decoded| {
        switch (decoded.data) {
            .String => |bytes| try case.expected.print(allocator, "OK bytes {d}", .{bytes.len}),
            .List => |items| try case.expected.print(allocator, "OK list {d}", .{items.len}),
        }
    } else |_| {
        try case.expected.appendSlice(allocator, "ERR");
    }
}

// ---------------------------------------------------------------------------
// TX_DECODE
// ---------------------------------------------------------------------------

fn appendRlpAddress(allocator: std.mem.Allocator, random: std.Random, out: *std.ArrayList(u8)) !void {
    try appendRandomRlpString(allocator, random, out, 20);
}

fn appendRlpOptionalTo(allocator: std.mem.Allocator, random: std.Random, out: *std.ArrayList(u8)) !void {
    switch (random.uintLessThan(u8, 20)) {
        0, 1, 2 => try appendRlpString(allocator, out, &.{}),
        // Wrong address width: both sides must reject.
        3 => try appendRandomRlpString(allocator, random, out, 19 + 2 * random.uintLessThan(usize, 2)),
        else => try appendRlpAddress(allocator, random, out),
    }
}

fn appendRlpAccessList(allocator: std.mem.Allocator, random: std.Random, out: *std.ArrayList(u8)) !void {
    var entries: std.ArrayList(u8) = .empty;
    for (0..random.uintLessThan(usize, 3)) |_| {
        var keys: std.ArrayList(u8) = .empty;
        for (0..random.uintLessThan(usize, 3)) |_| try appendRandomRlpString(allocator, random, &keys, 32);
        var entry: std.ArrayList(u8) = .empty;
        try appendRlpAddress(allocator, random, &entry);
        try appendRlpList(allocator, &entry, keys.items);
        try appendRlpList(allocator, &entries, entry.items);
    }
    try appendRlpList(allocator, out, entries.items);
}

fn appendRlpAuthorizationList(allocator: std.mem.Allocator, random: std.Random, out: *std.ArrayList(u8)) !void {
    var tuples: std.ArrayList(u8) = .empty;
    for (0..random.uintLessThan(usize, 3)) |_| {
        var tuple: std.ArrayList(u8) = .empty;
        try appendRlpUint(allocator, &tuple, random.uintLessThan(u64, 100_000));
        try appendRlpAddress(allocator, random, &tuple);
        try appendRlpUint(allocator, &tuple, randomU64(random));
        try appendRlpUint(allocator, &tuple, random.uintLessThan(u8, 2));
        try appendRlpUint(allocator, &tuple, randomU256(random));
        try appendRlpUint(allocator, &tuple, randomU256(random));
        try appendRlpList(allocator, &tuples, tuple.items);
    }
    try appendRlpList(allocator, out, tuples.items);
}

/// Appends `y_parity, r, s`. One case in 25 carries an out-of-range parity.
fn appendTypedSignature(allocator: std.mem.Allocator, random: std.Random, out: *std.ArrayList(u8)) !void {
    const y_parity: u8 = if (random.uintLessThan(u8, 25) == 0) 2 + random.uintLessThan(u8, 100) else random.uintLessThan(u8, 2);
    try appendRlpUint(allocator, out, y_parity);
    try appendRlpUint(allocator, out, randomU256(random));
    try appendRlpUint(allocator, out, randomU256(random));
}

const BlobWrapperKind = enum { bare, v0, v1 };

/// Appends the 14 fields of an EIP-4844 transaction as an RLP list.
/// `versioned_hashes` is a concatenation of 32-byte hashes.
fn appendEip4844List(allocator: std.mem.Allocator, random: std.Random, out: *std.ArrayList(u8), versioned_hashes: []const u8) !void {
    var fields: std.ArrayList(u8) = .empty;
    try appendRlpUint(allocator, &fields, random.uintLessThan(u64, 100_000));
    try appendRlpUint(allocator, &fields, randomU64(random));
    try appendRlpUint(allocator, &fields, randomU256(random));
    try appendRlpUint(allocator, &fields, randomU256(random));
    try appendRlpUint(allocator, &fields, randomU64(random));
    try appendRlpAddress(allocator, random, &fields);
    try appendRlpUint(allocator, &fields, randomU256(random));
    try appendRandomRlpString(allocator, random, &fields, random.uintLessThan(usize, 40));
    try appendRlpAccessList(allocator, random, &fields);
    try appendRlpUint(allocator, &fields, randomU256(random));
    var hashes: std.ArrayList(u8) = .empty;
    var offset: usize = 0;
    while (offset < versioned_hashes.len) : (offset += 32) {
        try appendRlpString(allocator, &hashes, versioned_hashes[offset .. offset + 32]);
    }
    try appendRlpList(allocator, &fields, hashes.items);
    try appendTypedSignature(allocator, random, &fields);
    try appendRlpList(allocator, out, fields.items);
}

/// Appends a type-3 network wrapper (EIP-4844 v0 or EIP-7594 v1). Three in ten
/// wrappers carry one structural defect that both decoders must reject.
fn appendBlobWrapper(allocator: std.mem.Allocator, random: std.Random, out: *std.ArrayList(u8), kind: BlobWrapperKind) !void {
    const defect: u8 = if (random.uintLessThan(u8, 10) < 3) 1 + random.uintLessThan(u8, 7) else 0;
    const blob_count: usize = if (defect == 7) 0 else 1 + @as(usize, random.uintLessThan(u8, 5) / 4);

    var commitments_raw: std.ArrayList(u8) = .empty;
    try appendRandomBytes(allocator, random, &commitments_raw, blob_count * bytes_per_commitment);
    var versioned_hashes: std.ArrayList(u8) = .empty;
    for (0..blob_count) |index| {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(commitments_raw.items[index * bytes_per_commitment ..][0..bytes_per_commitment], &digest, .{});
        digest[0] = 0x01;
        try versioned_hashes.appendSlice(allocator, &digest);
    }
    // Defect 1: a versioned hash that no longer matches its commitment.
    if (defect == 1) versioned_hashes.items[random.uintLessThan(usize, versioned_hashes.items.len)] ^= 0x40;
    // Defect 2: one versioned hash more than there are blobs.
    if (defect == 2) try versioned_hashes.appendSlice(allocator, versioned_hashes.items[0..32]);

    var payload: std.ArrayList(u8) = .empty;
    try appendEip4844List(allocator, random, &payload, versioned_hashes.items);
    if (kind == .v1) {
        // Defect 3: unsupported wrapper version byte.
        try payload.append(allocator, if (defect == 3) 0x02 else 0x01);
    }

    var blobs: std.ArrayList(u8) = .empty;
    for (0..blob_count) |index| {
        // Defect 4: the first blob is one byte short.
        const blob_len = if (defect == 4 and index == 0) bytes_per_blob - 1 else bytes_per_blob;
        try appendRlpHeader(allocator, &blobs, blob_len, 0x80);
        const blob = try blobs.addManyAsSlice(allocator, blob_len);
        @memset(blob, 0);
        random.bytes(blob[0..64]);
    }
    try appendRlpList(allocator, &payload, blobs.items);

    var commitments: std.ArrayList(u8) = .empty;
    // Defect 5: one commitment more than there are blobs.
    const commitment_count = if (defect == 5) blob_count + 1 else blob_count;
    for (0..commitment_count) |index| {
        const source = (index % @max(blob_count, 1)) * bytes_per_commitment;
        try appendRlpString(allocator, &commitments, commitments_raw.items[source .. source + bytes_per_commitment]);
    }
    try appendRlpList(allocator, &payload, commitments.items);

    var proofs: std.ArrayList(u8) = .empty;
    const proofs_per_blob: usize = if (kind == .v1) cells_per_ext_blob else 1;
    // Defect 6: one proof missing.
    const proof_count = blob_count * proofs_per_blob - @intFromBool(defect == 6);
    for (0..proof_count) |_| try appendRandomRlpString(allocator, random, &proofs, bytes_per_proof);
    try appendRlpList(allocator, &payload, proofs.items);

    try out.append(allocator, 0x03);
    try appendRlpList(allocator, out, payload.items);
}

fn appendLegacyTx(allocator: std.mem.Allocator, random: std.Random, out: *std.ArrayList(u8)) !void {
    var fields: std.ArrayList(u8) = .empty;
    try appendRlpUint(allocator, &fields, randomU64(random));
    try appendRlpUint(allocator, &fields, randomU256(random));
    try appendRlpUint(allocator, &fields, randomU64(random));
    try appendRlpOptionalTo(allocator, random, &fields);
    try appendRlpUint(allocator, &fields, randomU256(random));
    try appendRandomRlpString(allocator, random, &fields, random.uintLessThan(usize, 40));
    const v: u64 = switch (random.uintLessThan(u8, 12)) {
        0, 1 => 27,
        2, 3 => 28,
        4, 5 => 37 + random.uintLessThan(u64, 2),
        6, 7 => 35 + random.uintLessThan(u64, 1 << 40),
        8 => std.math.maxInt(u64),
        9 => 35,
        // Invalid: neither 27, 28, nor an EIP-155 value.
        else => ([_]u64{ 0, 1, 26, 29, 34 })[random.uintLessThan(usize, 5)],
    };
    try appendRlpUint(allocator, &fields, v);
    try appendRlpUint(allocator, &fields, randomU256(random));
    try appendRlpUint(allocator, &fields, randomU256(random));
    try appendRlpList(allocator, out, fields.items);
}

fn appendTypedTx(allocator: std.mem.Allocator, random: std.Random, out: *std.ArrayList(u8), tx_type: u8) !void {
    var fields: std.ArrayList(u8) = .empty;
    try appendRlpUint(allocator, &fields, random.uintLessThan(u64, 100_000));
    try appendRlpUint(allocator, &fields, randomU64(random));
    try appendRlpUint(allocator, &fields, randomU256(random));
    if (tx_type != 0x01) try appendRlpUint(allocator, &fields, randomU256(random));
    try appendRlpUint(allocator, &fields, randomU64(random));
    if (tx_type == 0x04) {
        try appendRlpAddress(allocator, random, &fields);
    } else {
        try appendRlpOptionalTo(allocator, random, &fields);
    }
    try appendRlpUint(allocator, &fields, randomU256(random));
    try appendRandomRlpString(allocator, random, &fields, random.uintLessThan(usize, 40));
    try appendRlpAccessList(allocator, random, &fields);
    if (tx_type == 0x04) try appendRlpAuthorizationList(allocator, random, &fields);
    try appendTypedSignature(allocator, random, &fields);
    try out.append(allocator, tx_type);
    try appendRlpList(allocator, out, fields.items);
}

fn appendBareBlobTx(allocator: std.mem.Allocator, random: std.Random, out: *std.ArrayList(u8)) !void {
    var versioned_hashes: std.ArrayList(u8) = .empty;
    for (0..random.uintLessThan(usize, 4)) |_| {
        const hash = try versioned_hashes.addManyAsSlice(allocator, 32);
        random.bytes(hash);
        hash[0] = 0x01;
    }
    try out.append(allocator, 0x03);
    try appendEip4844List(allocator, random, out, versioned_hashes.items);
}

/// Appends the response line zevm produces for `raw`.
fn appendZigTxDecode(allocator: std.mem.Allocator, raw: []const u8, out: *std.ArrayList(u8)) !void {
    const wrapper = zevm.transaction_encoding.decodeBlobNetworkWrapper(raw) catch {
        return out.appendSlice(allocator, "ERR");
    };
    const tag: []const u8 = if (wrapper) |view| switch (view.version) {
        .v0 => "v0",
        .v1 => "v1",
    } else "bare";

    const decoded = zevm.transaction_encoding.decodeEnvelope(allocator, raw) catch {
        return out.appendSlice(allocator, "ERR");
    };
    var tx_type: u8 = 0;
    var nonce: u64 = 0;
    var gas_limit: u64 = 0;
    switch (decoded) {
        .legacy => |tx| {
            tx_type = 0;
            nonce = tx.nonce;
            gas_limit = tx.gas_limit;
        },
        .eip2930 => |tx| {
            tx_type = 1;
            nonce = tx.nonce;
            gas_limit = tx.gas_limit;
        },
        .eip1559 => |tx| {
            tx_type = 2;
            nonce = tx.nonce;
            gas_limit = tx.gas_limit;
        },
        .eip4844 => |tx| {
            tx_type = 3;
            nonce = tx.nonce;
            gas_limit = tx.gas_limit;
        },
        .eip7702 => |tx| {
            tx_type = 4;
            nonce = tx.nonce;
            gas_limit = tx.gas_limit;
        },
    }
    try out.print(allocator, "OK {d} {d} {d} {s}", .{ tx_type, nonce, gas_limit, tag });
}

fn generateTxDecode(fuzzer: *Fuzzer, allocator: std.mem.Allocator, case: *Case) anyerror!void {
    const random = fuzzer.random;
    var raw: std.ArrayList(u8) = .empty;

    const wrapper_roll = random.uintLessThan(u8, 100);
    if (!fuzzer.skip_blob_wrappers and wrapper_roll < 3) {
        // About 3% of cases: each carries at least one 131072-byte blob.
        try appendBlobWrapper(allocator, random, &raw, if (random.boolean()) .v0 else .v1);
    } else {
        switch (random.uintLessThan(u8, 5)) {
            0 => try appendLegacyTx(allocator, random, &raw),
            1 => try appendTypedTx(allocator, random, &raw, 0x01),
            2 => try appendTypedTx(allocator, random, &raw, 0x02),
            3 => try appendBareBlobTx(allocator, random, &raw),
            else => try appendTypedTx(allocator, random, &raw, 0x04),
        }
        switch (random.uintLessThan(u8, 20)) {
            0, 1, 2 => try mutateBytes(allocator, random, &raw),
            3 => for (0..3) |_| try mutateBytes(allocator, random, &raw),
            4 => raw.items[0] = random.int(u8),
            5 => try raw.append(allocator, 0x00),
            else => {},
        }
    }

    try case.request.appendSlice(allocator, "TX_DECODE ");
    try appendHex(allocator, &case.request, raw.items);
    try appendZigTxDecode(allocator, raw.items, &case.expected);
}

// ---------------------------------------------------------------------------
// MODEXP
// ---------------------------------------------------------------------------

fn appendModexpOperand(allocator: std.mem.Allocator, random: std.Random, out: *std.ArrayList(u8), len: usize) !void {
    const start = out.items.len;
    try appendRandomBytes(allocator, random, out, len);
    if (len == 0) return;
    const operand = out.items[start..];
    switch (random.uintLessThan(u8, 12)) {
        0 => @memset(operand, 0),
        1 => {
            @memset(operand, 0);
            operand[len - 1] = 1;
        },
        2 => {
            @memset(operand, 0);
            operand[len - 1] = 2;
        },
        // Leading zero bytes: exercises the exponent head bit-length rule.
        3, 4 => @memset(operand[0..random.uintLessThan(usize, len)], 0),
        5 => {
            @memset(operand, 0);
            operand[random.uintLessThan(usize, len)] = @as(u8, 1) << random.int(u3);
        },
        6 => @memset(operand, 0xff),
        7 => operand[len - 1] &= 0xfe,
        else => {},
    }
}

fn generateModexp(fuzzer: *Fuzzer, allocator: std.mem.Allocator, case: *Case) anyerror!void {
    const random = fuzzer.random;
    const named = pickFork(random, &modexp_forks);

    var base_len: u256 = 0;
    var exp_len: u256 = 0;
    var mod_len: u256 = 0;
    var gas_limit: u64 = 10_000_000;
    var allow_low_gas = true;

    switch (random.uintLessThan(u8, 20)) {
        0...11 => {
            base_len = random.uintLessThan(u16, 41);
            exp_len = random.uintLessThan(u16, 41);
            mod_len = random.uintLessThan(u16, 41);
        },
        12, 13, 14 => {
            base_len = random.uintLessThan(u16, 300);
            exp_len = random.uintLessThan(u16, 70);
            mod_len = random.uintLessThan(u16, 300);
        },
        // EIP-7823 bounds: 1024 is accepted from Osaka, 1025 is rejected.
        15, 16 => {
            const edges = [_]u16{ 0, 1, 32, 33, 1023, 1024, 1025 };
            const exp_edges = [_]u16{ 0, 1, 31, 32, 33, 64, 1024, 1025 };
            base_len = edges[random.uintLessThan(usize, edges.len)];
            exp_len = exp_edges[random.uintLessThan(usize, exp_edges.len)];
            mod_len = edges[random.uintLessThan(usize, edges.len)];
            gas_limit = 1 << 40;
            allow_low_gas = false;
        },
        // One declared length far beyond the input. Every such case is out of
        // gas or invalid at a 10M gas limit, so neither side allocates it.
        17 => {
            const huge = [_]u256{
                1 << 32,
                (1 << 63) - 1,
                1 << 63,
                (1 << 64) - 1,
                1 << 64,
                1 << 128,
                1 << 255,
                std.math.maxInt(u256),
            };
            base_len = random.uintLessThan(u16, 8);
            exp_len = random.uintLessThan(u16, 8);
            mod_len = random.uintLessThan(u16, 8);
            const value = huge[random.uintLessThan(usize, huge.len)];
            switch (random.uintLessThan(u8, 3)) {
                0 => base_len = value,
                1 => exp_len = value,
                else => mod_len = value,
            }
            allow_low_gas = false;
        },
        // Header shorter than 96 bytes: missing length bytes read as zero.
        else => {
            base_len = random.uintLessThan(u16, 4);
            exp_len = random.uintLessThan(u16, 4);
            mod_len = random.uintLessThan(u16, 4);
        },
    }

    var input: std.ArrayList(u8) = .empty;
    var word: [32]u8 = undefined;
    for ([_]u256{ base_len, exp_len, mod_len }) |length| {
        std.mem.writeInt(u256, &word, length, .big);
        try input.appendSlice(allocator, &word);
    }
    const lengths_fit = base_len <= 4096 and exp_len <= 4096 and mod_len <= 4096;
    if (lengths_fit) {
        try appendModexpOperand(allocator, random, &input, @intCast(base_len));
        try appendModexpOperand(allocator, random, &input, @intCast(exp_len));
        try appendModexpOperand(allocator, random, &input, @intCast(mod_len));
    } else {
        try appendRandomBytes(allocator, random, &input, random.uintLessThan(usize, 24));
    }
    switch (random.uintLessThan(u8, 20)) {
        // Truncate anywhere, including inside the length header.
        0, 1, 2 => input.shrinkRetainingCapacity(random.uintAtMost(usize, input.items.len)),
        3 => try appendRandomBytes(allocator, random, &input, 1 + random.uintLessThan(usize, 40)),
        4 => input.clearRetainingCapacity(),
        else => {},
    }

    if (allow_low_gas and random.uintLessThan(u8, 10) < 3) {
        gas_limit = switch (random.uintLessThan(u8, 4)) {
            0 => random.uintLessThan(u64, 3),
            1 => 199 + random.uintLessThan(u64, 3),
            2 => 499 + random.uintLessThan(u64, 3),
            else => random.uintLessThan(u64, 4_000),
        };
    }

    try case.request.print(allocator, "MODEXP {s} {d} ", .{ named.name, gas_limit });
    try appendHex(allocator, &case.request, input.items);

    if (precompiles.modexp.execute(allocator, input.items, gas_limit, named.fork)) |result| {
        try case.expected.print(allocator, "OK {d} ", .{result.gas_used});
        try appendHex(allocator, &case.expected, result.output);
    } else |_| {
        try case.expected.appendSlice(allocator, "ERR");
    }
}

// ---------------------------------------------------------------------------
// EVM_EXEC
// ---------------------------------------------------------------------------

/// Host that serves one contract's code and no other state. The spec models a
/// single frame with no storage, balances, or calls.
const FuzzHost = struct {
    code: []const u8,

    const vtable: guillotine_mini.HostInterface.VTable = .{
        .getBalance = getBalance,
        .setBalance = setBalance,
        .getCode = getCode,
        .setCode = setCode,
        .getStorage = getStorage,
        .setStorage = setStorage,
        .getNonce = getNonce,
        .setNonce = setNonce,
    };

    fn interface(self: *FuzzHost) guillotine_mini.HostInterface {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn getBalance(_: *anyopaque, _: primitives.Address) u256 {
        return 0;
    }

    fn setBalance(_: *anyopaque, _: primitives.Address, _: u256) void {}

    fn getCode(ptr: *anyopaque, address: primitives.Address) []const u8 {
        const self: *FuzzHost = @ptrCast(@alignCast(ptr));
        if (std.mem.eql(u8, &address.bytes, &contract_address.bytes)) return self.code;
        return &.{};
    }

    fn setCode(_: *anyopaque, _: primitives.Address, _: []const u8) void {}

    fn getStorage(_: *anyopaque, _: primitives.Address, _: u256) u256 {
        return 0;
    }

    fn setStorage(_: *anyopaque, _: primitives.Address, _: u256, _: u256) void {}

    fn getNonce(_: *anyopaque, _: primitives.Address) u64 {
        return 0;
    }

    fn setNonce(_: *anyopaque, _: primitives.Address, _: u64) void {}
};

/// Appends the response line guillotine-mini produces for one frame.
fn appendZigEvmExec(
    allocator: std.mem.Allocator,
    fork: primitives.Hardfork,
    code: []const u8,
    calldata: []const u8,
    gas_limit: u64,
    out: *std.ArrayList(u8),
) !void {
    var host = FuzzHost{ .code = code };
    var evm: EvmType = undefined;
    try evm.init(allocator, host.interface(), fork, null, caller_address, 0, null);
    defer evm.deinit();

    const result = evm.call(.{ .call = .{
        .caller = caller_address,
        .to = contract_address,
        .value = 0,
        .input = calldata,
        .gas = gas_limit,
    } });
    try out.print(allocator, "OK {d} {d} ", .{ @intFromBool(result.success), gas_limit -| result.gas_left });
    try appendHex(allocator, out, result.output);
}

const op_stop: u8 = 0x00;
const op_sub: u8 = 0x03;
const op_addmod: u8 = 0x08;
const op_mulmod: u8 = 0x09;
const op_iszero: u8 = 0x15;
const op_not: u8 = 0x19;
const op_clz: u8 = 0x1e;
const op_calldataload: u8 = 0x35;
const op_calldatasize: u8 = 0x36;
const op_calldatacopy: u8 = 0x37;
const op_codesize: u8 = 0x38;
const op_codecopy: u8 = 0x39;
const op_pop: u8 = 0x50;
const op_mload: u8 = 0x51;
const op_mstore: u8 = 0x52;
const op_mstore8: u8 = 0x53;
const op_jump: u8 = 0x56;
const op_jumpi: u8 = 0x57;
const op_pc: u8 = 0x58;
const op_msize: u8 = 0x59;
const op_gas: u8 = 0x5a;
const op_jumpdest: u8 = 0x5b;
const op_mcopy: u8 = 0x5e;
const op_push0: u8 = 0x5f;
const op_push1: u8 = 0x60;
const op_push32: u8 = 0x7f;
const op_dup1: u8 = 0x80;
const op_swap1: u8 = 0x90;
const op_return: u8 = 0xf3;
const op_revert: u8 = 0xfd;

/// ADD MUL SUB DIV SDIV MOD SMOD EXP SIGNEXTEND.
const arithmetic_binary_ops = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x0a, 0x0b };
/// LT GT SLT SGT EQ AND OR XOR BYTE.
const bitwise_binary_ops = [_]u8{ 0x10, 0x11, 0x12, 0x13, 0x14, 0x16, 0x17, 0x18, 0x1a };
/// SHL SHR SAR.
const shift_ops = [_]u8{ 0x1b, 0x1c, 0x1d };
const all_binary_ops = arithmetic_binary_ops ++ bitwise_binary_ops ++ shift_ops;

/// Every opcode the Lean spec gives non-exceptional semantics to, apart from
/// PUSH1..PUSH32, DUP, and SWAP, which the generators emit explicitly.
const spec_ops = all_binary_ops ++ [_]u8{
    op_stop,         op_addmod,       op_mulmod,       op_iszero,   op_not,      op_clz,
    op_calldataload, op_calldatasize, op_calldatacopy, op_codesize, op_codecopy, op_pop,
    op_mload,        op_mstore,       op_mstore8,      op_jump,     op_jumpi,    op_pc,
    op_msize,        op_gas,          op_jumpdest,     op_mcopy,    op_push0,    op_return,
    op_revert,
};

/// Opcodes unassigned through Osaka, plus the designated INVALID (0xfe). Both
/// sides must halt exceptionally and consume all gas.
const undefined_ops = [_]u8{ 0x0c, 0x0f, 0x1f, 0x21, 0x2f, 0x4f, 0xa5, 0xbb, 0xef, 0xf6, 0xfb, 0xfc, 0xfe };

/// Emits the shortest PUSH for `value`, or a full PUSH32 when `wide` is set.
fn emitPush(allocator: std.mem.Allocator, code: *std.ArrayList(u8), value: u256, wide: bool) !void {
    var word: [32]u8 = undefined;
    std.mem.writeInt(u256, &word, value, .big);
    if (wide) {
        try code.append(allocator, op_push32);
        return code.appendSlice(allocator, &word);
    }
    if (value == 0) return code.append(allocator, op_push0);
    var skip: usize = 0;
    while (word[skip] == 0) skip += 1;
    try code.append(allocator, op_push1 + @as(u8, @intCast(31 - skip)));
    try code.appendSlice(allocator, word[skip..]);
}

fn emitRandomPush(allocator: std.mem.Allocator, random: std.Random, code: *std.ArrayList(u8), value: u256) !void {
    try emitPush(allocator, code, value, random.uintLessThan(u8, 4) == 0);
}

/// MSTORE the stack top at offset 0 and RETURN those 32 bytes.
fn emitReturnTop(allocator: std.mem.Allocator, code: *std.ArrayList(u8)) !void {
    try code.appendSlice(allocator, &.{ op_push0, op_mstore, op_push1, 0x20, op_push0, op_return });
}

/// RETURN the whole active memory.
fn emitReturnMemory(allocator: std.mem.Allocator, code: *std.ArrayList(u8)) !void {
    try code.appendSlice(allocator, &.{ op_msize, op_push0, op_return });
}

/// A memory offset or length: small most of the time, occasionally large
/// enough that expansion must run out of gas.
fn randomMemoryOperand(random: std.Random) u256 {
    return switch (random.uintLessThan(u8, 24)) {
        0 => 0,
        1 => 31 + @as(u256, random.uintLessThan(u8, 3)),
        2 => @as(u256, 1) << (16 + random.uintLessThan(u8, 8)),
        3 => ([_]u256{ 1 << 32, 1 << 64, 1 << 255, std.math.maxInt(u256) })[random.uintLessThan(usize, 4)],
        else => random.uintLessThan(u16, 200),
    };
}

fn randomShiftAmount(random: std.Random) u256 {
    return switch (random.uintLessThan(u8, 8)) {
        0 => 0,
        1 => 1,
        2 => 255,
        3 => 256,
        4 => 257,
        5 => random.int(u8),
        6 => randomU256(random),
        else => 7 + 8 * @as(u256, random.uintLessThan(u8, 32)),
    };
}

fn emitUnaryProgram(allocator: std.mem.Allocator, random: std.Random, code: *std.ArrayList(u8), op: u8) !void {
    try emitRandomPush(allocator, random, code, randomU256(random));
    try code.append(allocator, op);
    try emitReturnTop(allocator, code);
}

fn emitBinaryProgram(allocator: std.mem.Allocator, random: std.Random, code: *std.ArrayList(u8), op: u8, shift: bool) !void {
    // Operands are pushed in reverse: the last push is the first operand.
    try emitRandomPush(allocator, random, code, randomU256(random));
    try emitRandomPush(allocator, random, code, if (shift) randomShiftAmount(random) else randomU256(random));
    try code.append(allocator, op);
    try emitReturnTop(allocator, code);
}

fn emitTernaryProgram(allocator: std.mem.Allocator, random: std.Random, code: *std.ArrayList(u8), op: u8) !void {
    for (0..3) |_| try emitRandomPush(allocator, random, code, randomU256(random));
    try code.append(allocator, op);
    try emitReturnTop(allocator, code);
}

fn emitMemoryProgram(allocator: std.mem.Allocator, random: std.Random, code: *std.ArrayList(u8)) !void {
    for (0..1 + random.uintLessThan(usize, 6)) |_| {
        switch (random.uintLessThan(u8, 6)) {
            0, 1 => {
                try emitRandomPush(allocator, random, code, randomU256(random));
                try emitPush(allocator, code, randomMemoryOperand(random), false);
                try code.append(allocator, op_mstore);
            },
            2 => {
                try emitRandomPush(allocator, random, code, randomU256(random));
                try emitPush(allocator, code, randomMemoryOperand(random), false);
                try code.append(allocator, op_mstore8);
            },
            3 => {
                try emitPush(allocator, code, randomMemoryOperand(random), false);
                try code.appendSlice(allocator, &.{ op_mload, op_pop });
            },
            4 => {
                // CALLDATACOPY or CODECOPY: dest, offset, len.
                try emitPush(allocator, code, randomMemoryOperand(random), false);
                try emitPush(allocator, code, randomMemoryOperand(random), false);
                try emitPush(allocator, code, randomMemoryOperand(random), false);
                try code.append(allocator, if (random.boolean()) op_calldatacopy else op_codecopy);
            },
            else => try code.appendSlice(allocator, &.{ op_msize, op_pop }),
        }
    }
    switch (random.uintLessThan(u8, 4)) {
        0 => try emitReturnMemory(allocator, code),
        1 => {
            try code.append(allocator, op_msize);
            try emitReturnTop(allocator, code);
        },
        else => {
            // RETURN or REVERT an arbitrary range: offset, len.
            try emitPush(allocator, code, randomMemoryOperand(random), false);
            try emitPush(allocator, code, randomMemoryOperand(random), false);
            try code.append(allocator, if (random.uintLessThan(u8, 4) == 0) op_revert else op_return);
        },
    }
}

fn emitMcopyProgram(allocator: std.mem.Allocator, random: std.Random, code: *std.ArrayList(u8)) !void {
    // Seed memory with calldata so copies move distinguishable bytes.
    try code.appendSlice(allocator, &.{ op_calldatasize, op_push0, op_push0, op_calldatacopy });
    for (0..1 + random.uintLessThan(usize, 3)) |_| {
        // MCOPY: dest, src, len. Overlapping ranges are the interesting case.
        try emitPush(allocator, code, randomMemoryOperand(random), false);
        try emitPush(allocator, code, randomMemoryOperand(random), false);
        try emitPush(allocator, code, randomMemoryOperand(random), false);
        try code.append(allocator, op_mcopy);
    }
    try emitReturnMemory(allocator, code);
}

/// Random program that tracks stack depth, so most instructions execute
/// instead of underflowing on the first step.
fn emitStackAwareProgram(allocator: std.mem.Allocator, random: std.Random, code: *std.ArrayList(u8)) !void {
    var depth: usize = 0;
    for (0..4 + random.uintLessThan(usize, 40)) |_| {
        const roll = random.uintLessThan(u8, 100);
        if (roll < 30 or depth == 0) {
            const value: u256 = if (random.uintLessThan(u8, 10) < 6) random.int(u8) else randomU256(random);
            try emitRandomPush(allocator, random, code, value);
            depth += 1;
        } else if (roll < 58 and depth >= 2) {
            try code.append(allocator, all_binary_ops[random.uintLessThan(usize, all_binary_ops.len)]);
            depth -= 1;
        } else if (roll < 65) {
            try code.append(allocator, ([_]u8{ op_iszero, op_not, op_clz })[random.uintLessThan(usize, 3)]);
        } else if (roll < 69 and depth >= 3) {
            try code.append(allocator, if (random.boolean()) op_addmod else op_mulmod);
            depth -= 2;
        } else if (roll < 75) {
            try code.append(allocator, op_dup1 + random.uintLessThan(u8, @intCast(@min(depth, 16))));
            depth += 1;
        } else if (roll < 81 and depth >= 2) {
            try code.append(allocator, op_swap1 + random.uintLessThan(u8, @intCast(@min(depth - 1, 16))));
        } else if (roll < 84) {
            try code.append(allocator, op_pop);
            depth -= 1;
        } else if (roll < 88) {
            try emitPush(allocator, code, random.uintLessThan(u16, 200), false);
            try code.append(allocator, if (random.boolean()) op_mstore else op_mstore8);
            depth -= 1;
        } else if (roll < 91) {
            try emitPush(allocator, code, random.uintLessThan(u16, 200), false);
            try code.append(allocator, op_mload);
            depth += 1;
        } else if (roll < 94) {
            for (0..3) |_| try emitPush(allocator, code, random.uintLessThan(u16, 120), false);
            try code.append(allocator, ([_]u8{ op_calldatacopy, op_codecopy, op_mcopy })[random.uintLessThan(usize, 3)]);
        } else if (roll < 97) {
            try code.append(allocator, ([_]u8{ op_calldatasize, op_codesize, op_pc, op_msize, op_gas })[random.uintLessThan(usize, 5)]);
            depth += 1;
        } else if (roll < 99) {
            try emitPush(allocator, code, random.uintLessThan(u16, 100), false);
            try code.append(allocator, op_calldataload);
            depth += 1;
        } else {
            try code.append(allocator, op_jumpdest);
        }
    }
    switch (random.uintLessThan(u8, 10)) {
        0 => try code.append(allocator, op_stop),
        1 => {},
        2 => try emitReturnMemory(allocator, code),
        3 => {
            // REVERT the stack top as 32 bytes of revert data.
            if (depth == 0) try code.append(allocator, op_push0);
            try code.appendSlice(allocator, &.{ op_push0, op_mstore, op_push1, 0x20, op_push0, op_revert });
        },
        else => {
            if (depth == 0) try code.append(allocator, op_push0);
            try emitReturnTop(allocator, code);
        },
    }
}

/// Unstructured bytecode over the spec's opcode set: underflows, bad jumps,
/// truncated PUSH immediates, undefined opcodes.
fn emitRawProgram(allocator: std.mem.Allocator, random: std.Random, code: *std.ArrayList(u8)) !void {
    for (0..1 + random.uintLessThan(usize, 48)) |_| {
        const roll = random.uintLessThan(u8, 100);
        if (roll < 50) {
            try code.append(allocator, spec_ops[random.uintLessThan(usize, spec_ops.len)]);
        } else if (roll < 80) {
            const width = 1 + random.uintLessThan(u8, 32);
            try code.append(allocator, op_push1 + width - 1);
            if (random.uintLessThan(u8, 3) == 0) {
                // Small immediates make jump targets and offsets land in range.
                try code.appendNTimes(allocator, 0, @as(usize, width) - 1);
                try code.append(allocator, random.uintLessThan(u8, 64));
            } else {
                try appendRandomBytes(allocator, random, code, width);
            }
        } else if (roll < 88) {
            try code.append(allocator, op_dup1 + random.uintLessThan(u8, 16));
        } else if (roll < 95) {
            try code.append(allocator, op_swap1 + random.uintLessThan(u8, 16));
        } else {
            try code.append(allocator, undefined_ops[random.uintLessThan(usize, undefined_ops.len)]);
        }
    }
    // A trailing PUSH with missing immediate bytes reads them as zero.
    if (random.uintLessThan(u8, 8) == 0) try code.append(allocator, op_push1 + random.uintLessThan(u8, 32));
}

/// Countdown loop: exercises JUMPDEST analysis, JUMPI, and exact gas
/// accounting when the gas limit ends the loop early.
fn emitLoopProgram(allocator: std.mem.Allocator, random: std.Random, code: *std.ArrayList(u8)) !void {
    try emitPush(allocator, code, 1 + @as(u256, random.uintLessThan(u16, 300)), false);
    const loop_start: u8 = @intCast(code.items.len);
    try code.appendSlice(allocator, &.{ op_jumpdest, op_push1, 0x01, op_swap1, op_sub, op_dup1, op_push1 });
    // One case in six jumps to a wrong target (often inside a PUSH immediate).
    const target = if (random.uintLessThan(u8, 6) == 0) random.uintLessThan(u8, 24) else loop_start;
    try code.appendSlice(allocator, &.{ target, op_jumpi });
    try code.append(allocator, op_gas);
    try emitReturnTop(allocator, code);
}

/// Stack limit: 1023, 1024, or 1025 pushes. The 1025th must fail.
fn emitStackLimitProgram(allocator: std.mem.Allocator, random: std.Random, code: *std.ArrayList(u8)) !void {
    const pushes = 1023 + random.uintLessThan(usize, 3);
    switch (random.uintLessThan(u8, 3)) {
        0 => try code.appendNTimes(allocator, op_push0, pushes),
        1 => {
            try code.append(allocator, op_push0);
            try code.appendNTimes(allocator, op_dup1, pushes - 1);
        },
        else => try code.appendNTimes(allocator, op_pc, pushes),
    }
    try emitReturnTop(allocator, code);
}

fn generateEvmExec(fuzzer: *Fuzzer, allocator: std.mem.Allocator, case: *Case) anyerror!void {
    const random = fuzzer.random;
    const named = pickFork(random, &evm_forks);
    var code: std.ArrayList(u8) = .empty;

    switch (random.uintLessThan(u8, 40)) {
        // CLZ (EIP-7939): valid from Osaka, an invalid opcode in Prague.
        0...5 => try emitUnaryProgram(allocator, random, &code, op_clz),
        6...10 => try emitBinaryProgram(allocator, random, &code, arithmetic_binary_ops[random.uintLessThan(usize, arithmetic_binary_ops.len)], false),
        11, 12 => try emitTernaryProgram(allocator, random, &code, if (random.boolean()) op_addmod else op_mulmod),
        13...16 => try emitBinaryProgram(allocator, random, &code, bitwise_binary_ops[random.uintLessThan(usize, bitwise_binary_ops.len)], false),
        17 => try emitUnaryProgram(allocator, random, &code, if (random.boolean()) op_iszero else op_not),
        18...21 => try emitBinaryProgram(allocator, random, &code, shift_ops[random.uintLessThan(usize, shift_ops.len)], true),
        22...25 => try emitMemoryProgram(allocator, random, &code),
        26...29 => try emitMcopyProgram(allocator, random, &code),
        30...34 => try emitStackAwareProgram(allocator, random, &code),
        35, 36, 37 => try emitRawProgram(allocator, random, &code),
        38 => try emitLoopProgram(allocator, random, &code),
        else => if (random.boolean()) try emitStackLimitProgram(allocator, random, &code) else try emitLoopProgram(allocator, random, &code),
    }

    var calldata: std.ArrayList(u8) = .empty;
    if (random.uintLessThan(u8, 10) >= 3) {
        try appendRandomBytes(allocator, random, &calldata, 1 + random.uintLessThan(usize, 96));
    }

    // Gas stays far below the cost of guillotine-mini's 16 MiB memory limit,
    // so the limit (which the spec does not model) is never the deciding factor.
    const gas_limit: u64 = switch (random.uintLessThan(u8, 20)) {
        0...10 => 1_000_000,
        11...16 => random.uintLessThan(u64, 400),
        17 => random.uintLessThan(u64, 12),
        else => random.uintLessThan(u64, 60_000),
    };

    try case.request.print(allocator, "EVM_EXEC {s} {d} ", .{ named.name, gas_limit });
    try appendHex(allocator, &case.request, code.items);
    try case.request.append(allocator, ' ');
    try appendHex(allocator, &case.request, calldata.items);

    try appendZigEvmExec(allocator, named.fork, code.items, calldata.items, gas_limit, &case.expected);
}

// ---------------------------------------------------------------------------
// Driver
// ---------------------------------------------------------------------------

const Options = struct {
    lean_bin: []const u8,
    cases: usize = default_cases_per_domain,
    seed: u64 = default_seed,
    max_report: usize = default_max_report,
    skip_blob_wrappers: bool = false,
};

const usage =
    \\usage: lean-diff-fuzz --lean-bin <path> [--cases <N>] [--seed <u64>]
    \\                      [--max-report <N>] [--skip-blob-wrappers]
    \\
    \\  --lean-bin <path>      zevm-spec executable built from spec/lean (required)
    \\  --cases <N>            cases per domain (default 1000; 7 domains)
    \\  --seed <u64>           PRNG seed, decimal or 0x-prefixed hex
    \\  --max-report <N>       divergences printed in full per domain (default 5)
    \\  --skip-blob-wrappers   omit TX_DECODE cases that carry 131072-byte blobs
    \\
;

fn parseOptions(args: []const [:0]u8) !Options {
    var lean_bin: ?[]const u8 = null;
    var options = Options{ .lean_bin = "" };
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg: []const u8 = args[index];
        if (std.mem.eql(u8, arg, "--skip-blob-wrappers")) {
            options.skip_blob_wrappers = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return error.HelpRequested;
        if (index + 1 >= args.len) return error.MissingOptionValue;
        const value: []const u8 = args[index + 1];
        index += 1;
        if (std.mem.eql(u8, arg, "--lean-bin")) {
            lean_bin = value;
        } else if (std.mem.eql(u8, arg, "--cases")) {
            options.cases = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, arg, "--seed")) {
            options.seed = try std.fmt.parseInt(u64, value, 0);
        } else if (std.mem.eql(u8, arg, "--max-report")) {
            options.max_report = try std.fmt.parseInt(usize, value, 10);
        } else {
            return error.UnknownOption;
        }
    }
    options.lean_bin = lean_bin orelse return error.MissingLeanBin;
    return options;
}

fn printOut(allocator: std.mem.Allocator, comptime format: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, format, args);
    defer allocator.free(text);
    try std.fs.File.stdout().writeAll(text);
}

fn clip(text: []const u8) []const u8 {
    return text[0..@min(text.len, report_request_limit)];
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    const options = parseOptions(args) catch |err| {
        if (err != error.HelpRequested) std.debug.print("lean-diff-fuzz: {s}\n\n", .{@errorName(err)});
        std.debug.print("{s}", .{usage});
        std.process.exit(if (err == error.HelpRequested) 0 else 2);
    };

    const lean_argv = [_][]const u8{options.lean_bin};
    var lean = LeanProcess{ .child = std.process.Child.init(&lean_argv, gpa) };
    lean.child.stdin_behavior = .Pipe;
    lean.child.stdout_behavior = .Pipe;
    lean.child.stderr_behavior = .Inherit;
    lean.child.spawn() catch |err| {
        std.debug.print("lean-diff-fuzz: cannot spawn {s}: {s}\n", .{ options.lean_bin, @errorName(err) });
        std.process.exit(2);
    };

    var prng = std.Random.DefaultPrng.init(options.seed);
    var fuzzer = Fuzzer{ .random = prng.random(), .skip_blob_wrappers = options.skip_blob_wrappers };

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    try printOut(gpa, "lean-diff-fuzz: seed=0x{x} cases/domain={d} lean={s}\n", .{ options.seed, options.cases, options.lean_bin });

    var stats = [_]DomainStats{.{}} ** domains.len;
    var timer = try std.time.Timer.start();

    for (domains, 0..) |domain, domain_index| {
        const domain_start_ns = timer.read();
        defer stats[domain_index].elapsed_ms = (timer.read() - domain_start_ns) / std.time.ns_per_ms;
        for (0..options.cases) |case_index| {
            _ = arena_state.reset(.retain_capacity);
            const arena = arena_state.allocator();

            var case = Case{};
            try domain.generate(&fuzzer, arena, &case);
            try case.request.append(arena, '\n');
            const request = case.request.items[0 .. case.request.items.len - 1];

            const response = lean.ask(gpa, case.request.items) catch |err| {
                std.debug.print(
                    "lean-diff-fuzz: lost the Lean spec process ({s}) on {s} case {d}\n  request ({d} bytes): {s}\n",
                    .{ @errorName(err), domain.name, case_index, request.len, clip(request) },
                );
                std.process.exit(2);
            };

            stats[domain_index].cases += 1;
            if (std.mem.eql(u8, response, case.expected.items)) {
                stats[domain_index].passed += 1;
                continue;
            }
            stats[domain_index].diverged += 1;
            if (stats[domain_index].diverged <= options.max_report) {
                std.debug.print(
                    "DIVERGENCE {s} case {d} (seed 0x{x})\n  request ({d} bytes): {s}\n  lean: {s}\n  zig:  {s}\n",
                    .{ domain.name, case_index, options.seed, request.len, clip(request), clip(response), clip(case.expected.items) },
                );
            }
        }
    }

    // Closing stdin is the EOF that makes the spec exit 0.
    if (lean.child.stdin) |stdin| {
        stdin.close();
        lean.child.stdin = null;
    }
    const term = try lean.child.wait();
    const lean_exited_cleanly = term == .Exited and term.Exited == 0;

    var total = DomainStats{};
    try printOut(gpa, "\n{s:<14} {s:>8} {s:>8} {s:>10} {s:>9}\n", .{ "domain", "cases", "pass", "divergent", "ms" });
    for (domains, stats) |domain, domain_stats| {
        try printOut(gpa, "{s:<14} {d:>8} {d:>8} {d:>10} {d:>9}\n", .{ domain.name, domain_stats.cases, domain_stats.passed, domain_stats.diverged, domain_stats.elapsed_ms });
        total.cases += domain_stats.cases;
        total.passed += domain_stats.passed;
        total.diverged += domain_stats.diverged;
    }
    try printOut(gpa, "{s:<14} {d:>8} {d:>8} {d:>10} {d:>9}\n", .{ "TOTAL", total.cases, total.passed, total.diverged, timer.read() / std.time.ns_per_ms });

    if (!lean_exited_cleanly) {
        try printOut(gpa, "FAIL: the Lean spec process did not exit 0 on EOF\n", .{});
        std.process.exit(2);
    }
    if (total.diverged != 0) {
        try printOut(gpa, "FAIL: {d} divergence(s) between zevm and the Lean spec\n", .{total.diverged});
        std.process.exit(1);
    }
    try printOut(gpa, "PASS: zevm agrees with the Lean spec on all {d} cases\n", .{total.cases});
}
