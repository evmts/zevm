const std = @import("std");
const primitives = @import("primitives");
const eof = @import("../eof.zig");
const difficulty = @import("../difficulty.zig");
const hardfork_schedule = @import("../hardfork_schedule.zig");
const system_contracts = @import("../system_contracts.zig");
const precompile_compat = @import("../precompile_compat.zig");
const database = @import("../database/root.zig");
const log = @import("../log.zig");
const blob_fee = @import("../blob_fee.zig");

fn readU64(bytes: []const u8, offset: usize) u64 {
    if (offset + 8 <= bytes.len) {
        return std.mem.readInt(u64, bytes[offset..][0..8], .little);
    }
    var buf = [_]u8{0} ** 8;
    if (offset < bytes.len) {
        const n = bytes.len - offset;
        @memcpy(buf[0..n], bytes[offset..]);
    }
    return std.mem.readInt(u64, &buf, .little);
}

fn fuzzEofRuntime(_: void, input: []const u8) !void {
    const allocator = std.testing.allocator;
    const first = eof.validateContainer(allocator, input, .runtime);
    const second = eof.validateContainer(allocator, input, .runtime);
    if (first) {
        try second;
        // Strict EOF acceptance must also be accepted when EIP-4750 0x5b NOP is enabled.
        try eof.validateWithEip4750Nop(allocator, input, .runtime);
    } else |err| {
        try std.testing.expectError(err, second);
    }
}

fn fuzzEofInitcode(_: void, input: []const u8) !void {
    const allocator = std.testing.allocator;
    const first = eof.validateContainer(allocator, input, .initcode);
    const second = eof.validateContainer(allocator, input, .initcode);
    if (first) {
        try second;
        try eof.validateWithEip4750Nop(allocator, input, .initcode);
    } else |err| {
        try std.testing.expectError(err, second);
    }
}

fn fuzzEof4750Nop(_: void, input: []const u8) !void {
    const allocator = std.testing.allocator;
    const kind: eof.ContainerKind = if (input.len > 0 and (input[0] & 1) == 1) .initcode else .runtime;
    const body = if (input.len > 0) input[1..] else input;
    const first = eof.validateWithEip4750Nop(allocator, body, kind);
    const second = eof.validateWithEip4750Nop(allocator, body, kind);
    if (first) {
        try second;
    } else |err| {
        try std.testing.expectError(err, second);
    }
}

fn fuzzCalcDifficulty(_: void, input: []const u8) !void {
    const all_forks = [_]difficulty.DifficultyFork{
        .frontier,
        .homestead,
        .byzantium,
        .constantinople,
        .muir_glacier,
        .london,
        .arrow_glacier,
        .gray_glacier,
        .merge,
    };
    const fork = all_forks[(if (input.len > 0) input[0] else 0) % all_forks.len];
    const parent_ts = readU64(input, 1);
    const current_ts = readU64(input, 9);
    // Construct a full-width 256-bit parent difficulty to exercise reversed-timestamp overflow boundaries.
    const w0: u256 = readU64(input, 17);
    const w1: u256 = readU64(input, 25);
    const w2: u256 = readU64(input, 33);
    const w3: u256 = readU64(input, 41);
    const parent_diff: u256 = w0 | (w1 << 64) | (w2 << 128) | (w3 << 192);
    const block_num = readU64(input, 49);
    const has_uncles = input.len > 57 and (input[57] & 1) == 1;

    const result = difficulty.calcDifficulty(
        fork,
        parent_ts,
        current_ts,
        parent_diff,
        block_num,
        has_uncles,
    );
    if (fork == .merge) {
        try std.testing.expectEqual(@as(u256, 0), result);
    } else {
        try std.testing.expect(result >= difficulty.MINIMUM_DIFFICULTY);
    }
}

fn fuzzForkFromName(_: void, input: []const u8) !void {
    const maybe_fork = difficulty.forkFromName(input);
    if (maybe_fork) |fork| {
        const d = difficulty.calcDifficulty(fork, 100, 112, difficulty.MINIMUM_DIFFICULTY, 1, false);
        if (fork == .merge) {
            try std.testing.expectEqual(@as(u256, 0), d);
        } else {
            try std.testing.expect(d >= difficulty.MINIMUM_DIFFICULTY);
        }
    }
}

fn fuzzBlobScheduleInit(_: void, input: []const u8) !void {
    const entry_bytes = 32;
    const raw_count = @min(input.len / entry_bytes, hardfork_schedule.MAX_BLOB_SCHEDULE_ENTRIES + 2);
    var items: [hardfork_schedule.MAX_BLOB_SCHEDULE_ENTRIES + 2]hardfork_schedule.BlobScheduleEntry = undefined;
    for (0..raw_count) |i| {
        const base = i * entry_bytes;
        items[i] = .{
            .timestamp = readU64(input, base),
            .target = readU64(input, base + 8),
            .max = readU64(input, base + 16),
            .base_fee_update_fraction = readU64(input, base + 24),
        };
    }

    if (hardfork_schedule.BlobSchedule.init(items[0..raw_count])) |sched| {
        const entries = sched.entries();
        try std.testing.expectEqual(raw_count, entries.len);
        for (entries, 0..) |entry, idx| {
            try hardfork_schedule.validateBlobConfig(entry.config());
            if (idx > 0) {
                try std.testing.expect(entry.timestamp > entries[idx - 1].timestamp);
            }
        }
    } else |_| {}
}

fn fuzzResolveHardforkMonotonic(_: void, input: []const u8) !void {
    const b1 = readU64(input, 0);
    const t1 = readU64(input, 8);
    const db = readU64(input, 16);
    const dt = readU64(input, 24);
    const b2 = b1 +| db;
    const t2 = t1 +| dt;

    const f1 = hardfork_schedule.resolveHardfork(b1, t1);
    const f2 = hardfork_schedule.resolveHardfork(b2, t2);
    try std.testing.expect(f2.isAtLeast(f1));
}

fn fuzzSystemContractsFind(_: void, input: []const u8) !void {
    var addr = primitives.Address{ .bytes = [_]u8{0} ** 20 };
    const n = @min(input.len, 20);
    @memcpy(addr.bytes[0..n], input[0..n]);

    if (system_contracts.find(addr)) |contract| {
        try std.testing.expect(contract.address.equals(addr));
        try std.testing.expect(contract.code.len > 0);
    }
}

fn fuzzPrecompileEcrecover(_: void, input: []const u8) !void {
    const allocator = std.testing.allocator;
    const gas_limit: u64 = if (input.len >= 8) readU64(input, 0) % 10_000 else 5_000;
    const payload = if (input.len >= 8) input[8..] else input;
    const addr = primitives.Address.fromU256(1);

    if (gas_limit < 3000) {
        try std.testing.expectError(
            error.OutOfGas,
            precompile_compat.execute(allocator, addr, payload, gas_limit, .OSAKA),
        );
        return;
    }
    const res = try precompile_compat.execute(allocator, addr, payload, gas_limit, .OSAKA);
    defer allocator.free(res.output);
    try std.testing.expect(res.success);
    try std.testing.expectEqual(@as(u64, 3000), res.gas_used);
    try std.testing.expect(res.output.len == 0 or res.output.len == 32);
}

fn fuzzAccountsStateful(_: void, input: []const u8) !void {
    const allocator = std.testing.allocator;
    var accounts = database.Accounts.init(allocator);
    defer accounts.deinit();

    var cursor: usize = 0;
    const max_ops: usize = 24;
    var ops: usize = 0;
    while (cursor + 3 <= input.len and ops < max_ops) : (ops += 1) {
        const op = input[cursor] % 3;
        const addr_byte = input[cursor + 1];
        const val = input[cursor + 2];
        cursor += 3;

        const addr = primitives.Address.fromU256(addr_byte);
        switch (op) {
            0 => {
                const state = primitives.AccountState.AccountState.from(.{
                    .nonce = val,
                    .balance = @as(u256, val) * 1000,
                });
                try accounts.put(allocator, addr, &state);
                const loaded = (try accounts.get(allocator, addr)) orelse return error.TestUnexpectedResult;
                try std.testing.expectEqual(@as(u64, val), loaded.nonce);
            },
            1 => {
                try accounts.remove(addr);
                try std.testing.expectEqual(
                    @as(?primitives.AccountState.AccountState, null),
                    try accounts.get(allocator, addr),
                );
            },
            else => {
                _ = accounts.stateRoot();
            },
        }
    }
}

fn fuzzContractsStateful(_: void, input: []const u8) !void {
    const allocator = std.testing.allocator;
    var contracts = database.Contracts.init();
    defer contracts.deinit(allocator);

    var cursor: usize = 0;
    const max_ops: usize = 32;
    var ops: usize = 0;
    while (cursor + 3 <= input.len and ops < max_ops) : (ops += 1) {
        const op = input[cursor] % 2;
        const key_byte = input[cursor + 1];
        const len = @min(@as(usize, input[cursor + 2] % 16), input.len - (cursor + 3));
        const code = input[cursor + 3 ..][0..len];
        cursor += 3 + len;

        const key: primitives.Hash.Hash = [_]u8{key_byte} ** 32;
        if (op == 0) {
            try contracts.put(allocator, key, code);
            const got = contracts.get(key) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualSlices(u8, code, got);
        } else {
            contracts.remove(allocator, key);
            try std.testing.expectEqual(@as(?[]const u8, null), contracts.get(key));
        }
    }
}

test "fuzz: eof.validateContainer runtime" {
    try std.testing.fuzz({}, fuzzEofRuntime, .{
        .corpus = &.{
            "",
            &.{ 0xef, 0x00, 0x01, 0x01, 0x00, 0x04, 0x02, 0x00, 0x01, 0x00, 0x01, 0x04, 0x00, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00 },
        },
    });
}

test "fuzz: eof.validateContainer initcode" {
    try std.testing.fuzz({}, fuzzEofInitcode, .{
        .corpus = &.{ "", &.{ 0xef, 0x00, 0x01 } },
    });
}

test "fuzz: eof.validateWithEip4750Nop" {
    try std.testing.fuzz({}, fuzzEof4750Nop, .{
        .corpus = &.{ &.{0}, &.{ 1, 0xef, 0x00, 0x01 } },
    });
}

test "fuzz: difficulty.calcDifficulty invariants" {
    const z34 = [_]u8{0} ** 34;
    const m34 = [_]u8{8} ** 34;
    try std.testing.fuzz({}, fuzzCalcDifficulty, .{
        .corpus = &.{ &z34, &m34 },
    });
}

test "fuzz: difficulty.forkFromName arbitrary UTF-8" {
    try std.testing.fuzz({}, fuzzForkFromName, .{
        .corpus = &.{ "Frontier", "Homestead", "London", "Merge", "Paris", "" },
    });
}

test "fuzz: hardfork_schedule.BlobSchedule.init invariants" {
    const z64 = [_]u8{0} ** 64;
    try std.testing.fuzz({}, fuzzBlobScheduleInit, .{
        .corpus = &.{ "", &z64 },
    });
}

test "fuzz: hardfork_schedule.resolveHardfork monotonicity" {
    const z32 = [_]u8{0} ** 32;
    try std.testing.fuzz({}, fuzzResolveHardforkMonotonic, .{
        .corpus = &.{&z32},
    });
}

test "fuzz: system_contracts.find lookup" {
    try std.testing.fuzz({}, fuzzSystemContractsFind, .{
        .corpus = &.{ "", &system_contracts.BEACON_ROOTS_ADDRESS.bytes },
    });
}

test "fuzz: precompile_compat.execute ecrecover" {
    const z136 = [_]u8{0} ** 136;
    try std.testing.fuzz({}, fuzzPrecompileEcrecover, .{
        .corpus = &.{ "", &z136 },
    });
}

test "fuzz: database.Accounts stateful put/get/remove" {
    try std.testing.fuzz({}, fuzzAccountsStateful, .{
        .corpus = &.{&.{ 0, 1, 5, 2, 1, 0, 1, 1, 0 }},
    });
}

test "fuzz: database.Contracts stateful put/overwrite/remove" {
    try std.testing.fuzz({}, fuzzContractsStateful, .{
        .corpus = &.{&.{ 0, 1, 2, 0x60, 0x00, 1, 1, 0 }},
    });
}

fn fuzzLogParseLevel(_: void, input: []const u8) !void {
    if (log.parseLevel(input)) |lvl| {
        try std.testing.expect(lvl == .err or lvl == .warn or lvl == .info or lvl == .debug);
    }
}

fn fuzzLogRedactUrl(_: void, input: []const u8) !void {
    var out: [128]u8 = undefined;
    const redacted = log.redactUrl(&out, input);
    try std.testing.expect(redacted.len > 0);
    if (!std.mem.eql(u8, redacted, "<redacted>")) {
        try std.testing.expect(std.mem.indexOfScalar(u8, redacted, '@') == null);
        try std.testing.expect(std.mem.indexOfScalar(u8, redacted, '?') == null);
        try std.testing.expect(std.mem.indexOfScalar(u8, redacted, '#') == null);
    }
}

fn fuzzLogSanitizeRpcMethod(_: void, input: []const u8) !void {
    const clean = log.sanitizeRpcMethod(input);
    if (!std.mem.eql(u8, clean, "<invalid>")) {
        try std.testing.expect(clean.len >= 1 and clean.len <= 64);
        for (clean) |ch| {
            try std.testing.expect(std.ascii.isAlphanumeric(ch) or ch == '_');
        }
    }
}

fn fuzzBlobFakeExpMono(_: void, input: []const u8) !void {
    const factor: u256 = readU64(input, 0);
    const n1 = readU64(input, 8);
    const dn = readU64(input, 16) % 1024;
    const d = readU64(input, 24);
    const v1 = blob_fee.fakeExponential(factor, n1, d);
    const v2 = blob_fee.fakeExponential(factor, n1 +| dn, d);
    try std.testing.expect(v2 >= v1);
    if (d == 0) {
        try std.testing.expectEqual(std.math.maxInt(u256), v1);
    }
}

fn fuzzBlobBaseFeeZeroAndMono(_: void, input: []const u8) !void {
    const excess = readU64(input, 0);
    const delta = readU64(input, 8) % 512;
    const frac = readU64(input, 16);
    try std.testing.expectEqual(@as(u256, 0), blob_fee.calcBlobBaseFee(excess, 0));
    const f1 = blob_fee.calcBlobBaseFee(excess, frac);
    const f2 = blob_fee.calcBlobBaseFee(excess +| delta, frac);
    try std.testing.expect(f2 >= f1);
}

fn fuzzBlobReserveEquiv(_: void, input: []const u8) !void {
    const base_fee: u256 = readU64(input, 0);
    const b_fee: u256 = readU64(input, 8);
    const active = blob_fee.isBlobReservePriceActive(base_fee, b_fee);
    try std.testing.expectEqual(base_fee > 16 * b_fee, active);
}

fn fuzzCalcExcessBlobGasInvariants(_: void, input: []const u8) !void {
    const forks = [_]primitives.Hardfork{ .SHANGHAI, .CANCUN, .PRAGUE, .OSAKA };
    const fork = forks[(if (input.len > 0) input[0] else 0) % forks.len];
    const ts = readU64(input, 1);
    const parent_excess = readU64(input, 9);
    const parent_used = readU64(input, 17);
    const base_fee: u256 = readU64(input, 25);
    const params = blob_fee.blobParamsForFork(hardfork_schedule.MAINNET_CHAIN_CONFIG, fork, ts);
    const next = blob_fee.calcExcessBlobGas(fork, params, parent_excess, parent_used, base_fee);
    if (fork.isBefore(.CANCUN)) {
        try std.testing.expectEqual(@as(u64, 0), next);
    } else if (@as(u128, parent_excess) + @as(u128, parent_used) < params.target_blob_gas) {
        try std.testing.expectEqual(@as(u64, 0), next);
    }
}

fn fuzzMainnetBlobParamsInvariants(_: void, input: []const u8) !void {
    const forks = [_]primitives.Hardfork{ .LONDON, .SHANGHAI, .CANCUN, .PRAGUE, .OSAKA };
    const fork = forks[(if (input.len > 0) input[0] else 0) % forks.len];
    const ts = readU64(input, 1);
    const params = blob_fee.blobParamsForFork(hardfork_schedule.MAINNET_CHAIN_CONFIG, fork, ts);
    try std.testing.expect(params.target_blobs <= params.max_blobs);
    if (fork.isAtLeast(.CANCUN)) {
        try std.testing.expect(params.base_fee_update_fraction > 0);
    }
}

fn fuzzValidateBlobConfigBounds(_: void, input: []const u8) !void {
    const cfg = hardfork_schedule.BlobConfig{
        .target = readU64(input, 0),
        .max = readU64(input, 8),
        .base_fee_update_fraction = readU64(input, 16),
    };
    const res = hardfork_schedule.validateBlobConfig(cfg);
    if (cfg.max == 0 or cfg.target > cfg.max or
        cfg.max > hardfork_schedule.MAX_BLOBS_PER_BLOCK_LIMIT or
        cfg.base_fee_update_fraction == 0)
    {
        try std.testing.expectError(error.InvalidBlobScheduleEntry, res);
    } else {
        try res;
    }
}

fn fuzzValidateForkOrder(_: void, input: []const u8) !void {
    var cfg = hardfork_schedule.MAINNET_CHAIN_CONFIG;
    if (input.len >= 16) {
        cfg.shanghai_timestamp = readU64(input, 0);
        cfg.cancun_timestamp = readU64(input, 8);
    }
    const res = hardfork_schedule.validateForkOrder(cfg);
    if (cfg.cancun_timestamp < cfg.shanghai_timestamp) {
        try std.testing.expect(std.meta.isError(res));
    }
}

test "fuzz: log.parseLevel arbitrary text" {
    try std.testing.fuzz({}, fuzzLogParseLevel, .{
        .corpus = &.{ "debug", "info", "warn", "err", "error", "warning", "INVALID", "" },
    });
}

test "fuzz: log.redactUrl strips credentials and query paths" {
    try std.testing.fuzz({}, fuzzLogRedactUrl, .{
        .corpus = &.{ "https://user:secret@rpc.example.com:8545/v2/api_key?token=123", "not-a-url", "" },
    });
}

test "fuzz: log.sanitizeRpcMethod prevents log injection" {
    try std.testing.fuzz({}, fuzzLogSanitizeRpcMethod, .{
        .corpus = &.{ "eth_chainId", "debug_traceCall", "eth_call\nforged=1", "" },
    });
}

test "fuzz: blob_fee.fakeExponential monotonicity and zero-denom saturation" {
    const z32 = [_]u8{0} ** 32;
    try std.testing.fuzz({}, fuzzBlobFakeExpMono, .{
        .corpus = &.{&z32},
    });
}

test "fuzz: blob_fee.calcBlobBaseFee zero fraction and monotonicity" {
    const z24 = [_]u8{0} ** 24;
    try std.testing.fuzz({}, fuzzBlobBaseFeeZeroAndMono, .{
        .corpus = &.{&z24},
    });
}

test "fuzz: blob_fee.isBlobReservePriceActive matches Lean reserve_equiv" {
    const z16 = [_]u8{0} ** 16;
    try std.testing.fuzz({}, fuzzBlobReserveEquiv, .{
        .corpus = &.{&z16},
    });
}

test "fuzz: blob_fee.calcExcessBlobGas matches Lean floor and pre-Cancun theorems" {
    const z33 = [_]u8{0} ** 33;
    try std.testing.fuzz({}, fuzzCalcExcessBlobGasInvariants, .{
        .corpus = &.{&z33},
    });
}

test "fuzz: blob_fee.blobParamsForFork target <= max and positive fraction" {
    const z9 = [_]u8{0} ** 9;
    try std.testing.fuzz({}, fuzzMainnetBlobParamsInvariants, .{
        .corpus = &.{&z9},
    });
}

test "fuzz: hardfork_schedule.validateBlobConfig safety bounds" {
    const z24 = [_]u8{0} ** 24;
    try std.testing.fuzz({}, fuzzValidateBlobConfigBounds, .{
        .corpus = &.{&z24},
    });
}

test "fuzz: hardfork_schedule.validateForkOrder rejects out-of-order timestamps" {
    const z16 = [_]u8{0} ** 16;
    try std.testing.fuzz({}, fuzzValidateForkOrder, .{
        .corpus = &.{&z16},
    });
}
