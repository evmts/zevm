const std = @import("std");
const primitives = @import("primitives");
const fee = @import("../blob_fee.zig");
const schedule = @import("../hardfork_schedule.zig");
const encoding = @import("../transaction_encoding.zig");

const trials = 512;
const max64: u64 = std.math.maxInt(u64);
const max256: u256 = std.math.maxInt(u256);
const fractions = [_]u64{ 3_338_477, 5_007_716, 8_346_193, 11_684_671 };
const forks = [_]primitives.Hardfork{ .SHANGHAI, .CANCUN, .PRAGUE, .OSAKA };

// The first two EIP-4844 terms are exact. For each later term, two integer
// divisions give floor(x / (k*d)). A sum reaching 2^320 saturates for *every*
// u64 divisor, so even a maximal numerator takes bounded work.
fn referenceExponential(factor: u256, n: u64, d: u64) u256 {
    if (d == 0) return max256;
    var sum = @as(u1024, factor) * d;
    var term = @as(u1024, factor) * n;
    var k: u64 = 2;
    while (term != 0) : (k += 1) {
        sum += term;
        if (sum >> 320 != 0) return max256;
        term = ((term * n) / d) / k;
    }
    return std.math.cast(u256, sum / d) orelse max256;
}

fn checkExponential(factor: u256, n: u64, d: u64, step: u64) !void {
    const value = fee.fakeExponential(factor, n, d);
    try std.testing.expectEqual(referenceExponential(factor, n, d), value);
    try std.testing.expect(fee.fakeExponential(factor, n +| step, d) >= value);
    try std.testing.expect(fee.fakeExponential(factor, n, d +| step) <= value);
}

test "property: fake exponential rounding, order and saturation at every fraction" {
    var prng = std.Random.DefaultPrng.init(0x4844_e001);
    const r = prng.random();
    for (0..trials) |i| {
        const arbitrary: u64 = switch (i % 8) {
            0 => 0,
            1 => 1,
            2 => max64,
            3 => r.int(u16),
            else => r.int(u64),
        };
        for (fractions ++ [_]u64{arbitrary}) |d| {
            const n = switch (i % 9) {
                0 => 0,
                1 => d -| 1,
                2 => d +| 1,
                3 => max64,
                4 => r.int(u64),
                5 => d *| r.intRangeAtMost(u64, 175, 179) +| r.uintAtMost(u64, d),
                else => r.uintAtMost(u64, d *| 6),
            };
            const factor: u256 = switch (r.uintLessThan(u8, 8)) {
                0 => 0,
                1 => max256 - r.int(u8),
                2 => r.int(u256),
                3 => r.int(u64),
                else => 1,
            };
            try checkExponential(factor, n, d, if (r.boolean()) 1 else r.int(u32));
        }
        // A nonzero factor and these small denominators guarantee saturation.
        try std.testing.expectEqual(max256, fee.fakeExponential(@max(1, r.int(u128)), max64, @max(1, r.int(u32))));
    }
}

fn reserveByDivision(base: u256, blob: u256) bool {
    return base != 0 and (base - 1) / 16 >= blob;
}

fn checkReserve(base: u256, blob: u256) !void {
    const spec = @as(u512, base) * 8192 > @as(u512, blob) * 131072;
    try std.testing.expectEqual(spec, reserveByDivision(base, blob));
    try std.testing.expectEqual(spec, fee.isBlobReservePriceActive(base, blob));
}

test "property: EIP-7918 strict reserve inequality across u256" {
    var prng = std.Random.DefaultPrng.init(0x7918_0001);
    const r = prng.random();
    const edges = [_]u256{ 0, 1, 15, 16, 17, max256 / 16, max256 / 16 + 1, max256 - 1, max256 };
    for (edges) |base| for (edges) |blob| try checkReserve(base, blob);
    for (0..trials) |i| {
        const power = @as(u256, 1) << @intCast(239 + i % 17);
        for ([_]u256{ r.int(u256), power - 1, power, power + 1, power | r.int(u256) }) |base| {
            const tie = base / 16;
            for ([_]u256{ r.int(u256), tie -| 1, tie, tie + 1 }) |blob| try checkReserve(base, blob);
        }
        const tie = (r.int(u256) / 16) * 16;
        for ([_]u256{ tie -| 1, tie, tie + 1 }) |base| try checkReserve(base, tie / 16);
    }
}

const Parent = struct { excess: u64, used: u64, base: u256 };

// Express the reserve increment as used minus ceil(used * target / max).
// This oracle also covers unvalidated configs passed directly to the math API.
fn referenceExcess(fork: primitives.Hardfork, p: fee.BlobParams, parent: Parent, blob_price: u256) u64 {
    const total = @as(u128, parent.excess) + parent.used;
    if (fork.isBefore(.CANCUN) or total < p.target_blob_gas) return 0;
    var next = total - p.target_blob_gas;
    if (fork.isAtLeast(.OSAKA) and p.max_blobs != 0 and reserveByDivision(parent.base, blob_price)) {
        const product = @as(u128, parent.used) * @min(p.target_blobs, p.max_blobs);
        const deducted = (product + (p.max_blobs - 1)) / p.max_blobs;
        next = total - deducted;
    }
    return @intCast(@min(next, max64));
}

fn checkAccounting(fork: primitives.Hardfork, p: fee.BlobParams, parent: Parent, step: u64, base_step: u256) !void {
    const e = parent.excess;
    const u = parent.used;
    const b = parent.base;
    const d = p.base_fee_update_fraction;
    const price = if (d == 0) 0 else referenceExponential(1, e, d);
    try std.testing.expectEqual(price, fee.calcBlobBaseFee(e, d));
    const result = fee.calcExcessBlobGas(fork, p, e, u, b);
    try std.testing.expectEqual(referenceExcess(fork, p, parent, price), result);
    try std.testing.expect(result <= e +| u);

    const more_used = Parent{ .excess = e, .used = u +| step, .base = b };
    const by_use = fee.calcExcessBlobGas(fork, p, e, more_used.used, b);
    try std.testing.expectEqual(referenceExcess(fork, p, more_used, price), by_use);
    try std.testing.expect(by_use >= result);

    const more_excess = Parent{ .excess = e +| step, .used = u, .base = b };
    const next_price = if (d == 0) 0 else referenceExponential(1, more_excess.excess, d);
    const by_excess = fee.calcExcessBlobGas(fork, p, more_excess.excess, u, b);
    try std.testing.expectEqual(referenceExcess(fork, p, more_excess, next_price), by_excess);
    if (fork.isBefore(.OSAKA) or reserveByDivision(b, price) == reserveByDivision(b, next_price)) {
        try std.testing.expect(by_excess >= result);
    }

    const more_base = Parent{ .excess = e, .used = u, .base = b +| base_step };
    const by_base = fee.calcExcessBlobGas(fork, p, e, u, more_base.base);
    try std.testing.expectEqual(referenceExcess(fork, p, more_base, price), by_base);
    if (u <= p.max_blob_gas and p.target_blobs <= p.max_blobs) {
        try std.testing.expect(by_base >= result);
        const ordinary = fee.calcExcessBlobGas(fork, p, e, u, 0);
        try std.testing.expect(result >= ordinary);
        if (fork.isAtLeast(.OSAKA) and p.max_blobs > 0 and price <= (max256 - 1) / 16) {
            const active = fee.calcExcessBlobGas(fork, p, e, u, price * 16 + 1);
            try std.testing.expect(active >= ordinary);
            try std.testing.expectEqual(referenceExcess(fork, p, .{ .excess = e, .used = u, .base = price * 16 + 1 }, price), active);
        }
    }
}

test "property: target floor precedes reserve pricing at any execution base fee" {
    var prng = std.Random.DefaultPrng.init(0x7918_f100);
    const r = prng.random();
    for (0..trials) |i| {
        const max = r.intRangeAtMost(u64, 1, schedule.MAX_BLOBS_PER_BLOCK_LIMIT);
        const p = fee.BlobParams.fromConfig(.{ .target = r.intRangeAtMost(u64, 1, max), .max = max, .base_fee_update_fraction = @max(1, r.int(u64)) });
        const total = if (i % 2 == 0) p.target_blob_gas - 1 else r.uintLessThan(u64, p.target_blob_gas);
        const excess = r.uintAtMost(u64, total);
        for ([_]u256{ 0, 16, 17, r.int(u256), max256 }) |base| {
            try std.testing.expectEqual(@as(u64, 0), fee.calcExcessBlobGas(.OSAKA, p, excess, total - excess, base));
        }
    }
}

test "property: excess accounting on both sides of the reserve and the u64 limit" {
    var prng = std.Random.DefaultPrng.init(0x7918_abcd);
    const r = prng.random();
    for (0..trials) |i| {
        const max = r.intRangeAtMost(u64, 1, 64);
        const p = fee.BlobParams.fromConfig(.{
            .target = r.uintAtMost(u64, max),
            .max = max,
            .base_fee_update_fraction = fractions[i % fractions.len],
        });
        const e = switch (i % 5) {
            0 => max64 - r.int(u16),
            1 => p.target_blob_gas -| r.int(u16),
            2 => r.uintAtMost(u64, 4 * p.base_fee_update_fraction),
            3 => r.int(u64),
            else => r.uintAtMost(u64, p.max_blob_gas),
        };
        const parent = Parent{
            .excess = e,
            .used = if (i % 7 == 0) p.max_blob_gas else r.uintAtMost(u64, p.max_blob_gas),
            .base = if (r.boolean()) r.int(u256) else r.int(u8),
        };
        const step = r.intRangeAtMost(u64, 1, p.base_fee_update_fraction);
        try checkAccounting(.OSAKA, p, parent, step, r.int(u256));
        try checkAccounting(forks[i % 3], p, parent, step, r.int(u256));
    }
}

test "EIP-7918 increasing parent excess can deactivate the Osaka reserve" {
    const p = fee.BlobParams.fromConfig(schedule.MAINNET_OSAKA_BLOB_CONFIG);
    const g = fee.GAS_PER_BLOB;
    try std.testing.expectEqual(@as(u256, 1), p.baseFee(26 * g));
    try std.testing.expectEqual(@as(u256, 2), p.baseFee(27 * g));
    try std.testing.expectEqual(26 * g, fee.calcExcessBlobGas(.OSAKA, p, 26 * g, 0, 17));
    try std.testing.expectEqual(21 * g, fee.calcExcessBlobGas(.OSAKA, p, 27 * g, 0, 17));
    // A schedule can also lower the child's max below the parent's usage.
    try std.testing.expectEqual(6 * g, fee.calcExcessBlobGas(.OSAKA, p, 0, 12 * g, 16));
    try std.testing.expectEqual(4 * g, fee.calcExcessBlobGas(.OSAKA, p, 0, 12 * g, 17));
}

fn randomEntry(r: std.Random, timestamp: u64) schedule.BlobScheduleEntry {
    const max = if (r.boolean()) r.intRangeAtMost(u64, 1, 64) else r.intRangeAtMost(u64, 1, schedule.MAX_BLOBS_PER_BLOCK_LIMIT);
    return .{
        .timestamp = timestamp,
        .target = r.uintAtMost(u64, max),
        .max = max,
        .base_fee_update_fraction = @max(1, r.int(u64)),
    };
}

fn checkParams(expected: schedule.BlobConfig, actual: fee.BlobParams) !void {
    try std.testing.expectEqual(expected.target, actual.target_blobs);
    try std.testing.expectEqual(expected.max, actual.max_blobs);
    try std.testing.expectEqual(expected.target * 131072, actual.target_blob_gas);
    try std.testing.expectEqual(expected.max * 131072, actual.max_blob_gas);
    try std.testing.expectEqual(expected.base_fee_update_fraction, actual.base_fee_update_fraction);
}

test "property: EIP-7892 resolves the latest active entry through every interval" {
    var prng = std.Random.DefaultPrng.init(0x7892_b900);
    const r = prng.random();
    for (0..trials) |i| {
        const osaka = if (r.boolean()) max64 - 100_000 else 256 + @as(u64, r.int(u32));
        var chain = schedule.ChainConfig{
            .shanghai_timestamp = osaka - 3,
            .cancun_timestamp = osaka - 2,
            .prague_timestamp = osaka - 1,
            .osaka_timestamp = osaka,
            .cancun_blob_config = randomEntry(r, 0).config(),
            .prague_blob_config = randomEntry(r, 0).config(),
            .osaka_blob_config = randomEntry(r, 0).config(),
        };
        var entries: [schedule.MAX_BLOB_SCHEDULE_ENTRIES]schedule.BlobScheduleEntry = undefined;
        const len = i % (entries.len + 1);
        var at = osaka;
        for (entries[0..len], 0..) |*entry, j| {
            if (j != 0 or r.boolean()) at += r.intRangeAtMost(u64, 1, 1024);
            if (j + 1 == len and i % 3 == 0) at = max64;
            entry.* = randomEntry(r, at);
        }
        chain.blob_schedule = try schedule.BlobSchedule.init(entries[0..len]);
        const block = r.int(u64);
        try std.testing.expectEqual(fee.BlobParams.none, fee.resolveBlobParams(chain, block, osaka - 3));
        try checkParams(chain.cancun_blob_config, fee.resolveBlobParams(chain, block, osaka - 2));
        try checkParams(chain.prague_blob_config, fee.resolveBlobParams(chain, block, osaka - 1));
        // Even when all BPO timestamps have elapsed, an older fork ignores them.
        try std.testing.expectEqual(fee.BlobParams.none, fee.blobParamsForFork(chain, .SHANGHAI, max64));
        try checkParams(chain.cancun_blob_config, fee.blobParamsForFork(chain, .CANCUN, max64));
        try checkParams(chain.prague_blob_config, fee.blobParamsForFork(chain, .PRAGUE, max64));

        // Advance the expected schedule index in input order. Later configs
        // may decrease any fee parameter, so compare the entire chosen entry.
        var first = osaka;
        var selected = chain.osaka_blob_config;
        for (entries[0..len]) |entry| {
            if (first < entry.timestamp) {
                const last = entry.timestamp - 1;
                for ([_]u64{ first, r.intRangeAtMost(u64, first, last), last }) |t| {
                    try checkParams(selected, fee.resolveBlobParams(chain, block, t));
                }
            }
            first = entry.timestamp;
            selected = entry.config();
            try checkParams(selected, fee.resolveBlobParams(chain, block, first));
        }
        for ([_]u64{ first, r.intRangeAtMost(u64, first, max64), max64 }) |t| {
            try checkParams(selected, fee.resolveBlobParams(chain, block, t));
        }
    }
}

test "property: EIP-7892 schedule validation rejects ordering, capacity and parameter errors" {
    var prng = std.Random.DefaultPrng.init(0x7892_bad0);
    const r = prng.random();
    for (0..trials) |_| {
        var entries: [schedule.MAX_BLOB_SCHEDULE_ENTRIES + 1]schedule.BlobScheduleEntry = undefined;
        var at: u64 = r.int(u32);
        for (&entries) |*entry| {
            at += r.intRangeAtMost(u64, 1, 1024);
            entry.* = randomEntry(r, at);
        }
        try std.testing.expectError(error.TooManyBlobScheduleEntries, schedule.BlobSchedule.init(&entries));
        const len = r.intRangeAtMost(usize, 2, entries.len - 1);
        const items = entries[0..len];
        _ = try schedule.BlobSchedule.init(items);
        const j = r.intRangeLessThan(usize, 1, len);
        const good = items[j];
        items[j].timestamp = items[j - 1].timestamp;
        try std.testing.expectError(error.UnorderedBlobSchedule, schedule.BlobSchedule.init(items));
        items[j].timestamp -= 1;
        try std.testing.expectError(error.UnorderedBlobSchedule, schedule.BlobSchedule.init(items));
        items[j] = good;
        items[j].max = 0;
        items[j].target = 0;
        try std.testing.expectError(error.InvalidBlobScheduleEntry, schedule.BlobSchedule.init(items));
        items[j] = good;
        items[j].target = good.max + 1;
        try std.testing.expectError(error.InvalidBlobScheduleEntry, schedule.BlobSchedule.init(items));
        items[j] = good;
        items[j].max = schedule.MAX_BLOBS_PER_BLOCK_LIMIT + 1;
        try std.testing.expectError(error.InvalidBlobScheduleEntry, schedule.BlobSchedule.init(items));
        items[j] = good;
        items[j].base_fee_update_fraction = 0;
        try std.testing.expectError(error.InvalidBlobScheduleEntry, schedule.BlobSchedule.init(items));
    }
}

fn checkSections(view: encoding.BlobNetworkWrapper, count: usize, version: encoding.BlobWrapperVersion) !void {
    try std.testing.expectEqual(version, view.version);
    try std.testing.expectEqual(count, view.blob_count);
    // These are the sizes of encoded list *items*, excluding the outer list
    // prefix. A 131072-byte blob needs four prefix bytes; a 48-byte item one.
    try std.testing.expectEqual(count * (131072 + 4), view.blobs.len);
    try std.testing.expectEqual(count * 49, view.commitments.len);
    const per_blob: usize = if (version == .v1) 128 else 1;
    try std.testing.expectEqual(count * 49 * per_blob, view.proofs.len);
}

const full_width_r = [_]u8{0x32} ** 32;

// Generate an actual wire encoding. Returning the bytes also lets the native
// fuzzer start directly inside both valid wrapper grammars.
fn roundTrip(allocator: std.mem.Allocator, r: std.Random, version: encoding.BlobWrapperVersion, count: usize, sig_r: [32]u8) ![]u8 {
    const sidecars = try allocator.alloc(encoding.BlobSidecar, count);
    defer allocator.free(sidecars);
    var hashes: [encoding.MAX_BLOBS_PER_TRANSACTION]primitives.Blob.VersionedHash = undefined;
    for (sidecars, hashes[0..count]) |*sidecar, *hash| {
        @memset(&sidecar.blob, r.int(u8));
        const offset = r.uintAtMost(usize, sidecar.blob.len - 32);
        r.bytes(sidecar.blob[offset..][0..32]);
        r.bytes(sidecar.blob[0..32]);
        r.bytes(sidecar.blob[sidecar.blob.len - 32 ..]);
        r.bytes(&sidecar.commitment);
        hash.* = primitives.Blob.commitmentToVersionedHash(sidecar.commitment);
        switch (version) {
            .v0 => {
                sidecar.proofs = .{ .blob = undefined };
                r.bytes(&sidecar.proofs.blob);
            },
            .v1 => {
                sidecar.proofs = .{ .cells = undefined };
                r.bytes(std.mem.asBytes(&sidecar.proofs.cells));
            },
        }
    }
    var address: primitives.Address = undefined;
    r.bytes(&address.bytes);
    var keys: [2][32]u8 = undefined;
    r.bytes(std.mem.asBytes(&keys));
    const access = [_]primitives.Transaction.AccessListItem{.{ .address = address, .storage_keys = keys[0..r.uintAtMost(usize, keys.len)] }};
    var data: [64]u8 = undefined;
    r.bytes(&data);
    const tx = primitives.Transaction.Eip4844Transaction{
        .chain_id = r.int(u32),
        .nonce = r.int(u64),
        .max_priority_fee_per_gas = r.int(u16),
        .max_fee_per_gas = 65_536 + @as(u256, r.int(u128)),
        .gas_limit = r.intRangeAtMost(u64, 50_000, 30_000_000),
        .to = address,
        .value = r.int(u256),
        .data = data[0..r.uintAtMost(usize, data.len)],
        .access_list = access[0..r.uintAtMost(usize, access.len)],
        .max_fee_per_blob_gas = @max(1, r.int(u128)),
        .blob_versioned_hashes = hashes[0..count],
        .y_parity = r.int(u1),
        .r = sig_r,
        .s = [_]u8{0x13} ** 32,
    };
    const bare = try primitives.Transaction.encodeEip4844ForSigning(allocator, tx);
    defer allocator.free(bare);
    try encoding.requireCanonicalEnvelope(bare);
    try std.testing.expect((try encoding.decodeBlobNetworkWrapper(bare)) == null);
    const raw = try encoding.encodeBlobNetworkEnvelope(allocator, bare, sidecars);
    errdefer allocator.free(raw);
    const view = (try encoding.decodeBlobNetworkWrapper(raw)) orelse return error.ExpectedBlobWrapper;
    try checkSections(view, count, version);
    try std.testing.expectEqualSlices(u8, bare[1..], view.tx_payload);
    try encoding.validateWrapperCommitments(view, tx.blob_versioned_hashes);

    const recovered = try view.sidecars(allocator);
    defer allocator.free(recovered);
    try std.testing.expectEqual(count, recovered.len);
    for (sidecars, recovered) |*want, *got| {
        try std.testing.expect(std.mem.eql(u8, &want.blob, &got.blob));
        try std.testing.expectEqual(want.commitment, got.commitment);
        switch (version) {
            .v0 => {
                try std.testing.expect(got.proofs == .blob);
                try std.testing.expectEqual(want.proofs.blob, got.proofs.blob);
            },
            .v1 => {
                try std.testing.expect(got.proofs == .cells);
                try std.testing.expect(std.mem.eql(u8, std.mem.asBytes(&want.proofs.cells), std.mem.asBytes(&got.proofs.cells)));
            },
        }
    }
    const canonical = try encoding.canonicalTransactionEnvelope(allocator, raw);
    defer canonical.deinit(allocator);
    try std.testing.expectEqualSlices(u8, bare, canonical.bytes);
    try std.testing.expectEqual(encoding.transactionHash(bare), encoding.transactionHash(canonical.bytes));
    const decoded = try encoding.decodeEnvelope(allocator, raw);
    defer decoded.deinit(allocator);
    try std.testing.expect(decoded == .eip4844);
    try std.testing.expectEqualDeep(tx, decoded.eip4844);
    return raw;
}

test "property: EIP-4844 and PeerDAS wrapper round trips preserve sidecars and signed transaction identity" {
    var prng = std.Random.DefaultPrng.init(0x7594_4844);
    const r = prng.random();
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    for (0..trials) |i| {
        for ([_]encoding.BlobWrapperVersion{ .v0, .v1 }) |version| {
            const count = if (i % 16 == 0) 2 + (i / 16) % (encoding.MAX_BLOBS_PER_TRANSACTION - 1) else 1;
            const raw = try roundTrip(scratch.allocator(), r, version, count, full_width_r);
            scratch.allocator().free(raw);
            _ = scratch.reset(.retain_capacity);
        }
    }
}

// Voltaire currently emits a padded RLP byte string for a short signature
// scalar. Keep the expected successful decode visible as an integration test.
test "type-3 wrapper round trip preserves a minimally encoded signature scalar" {
    var prng = std.Random.DefaultPrng.init(0x4844_0031);
    var short_r = full_width_r;
    short_r[0] = 0;
    const raw = try roundTrip(std.testing.allocator, prng.random(), .v1, 1, short_r);
    defer std.testing.allocator.free(raw);
}

const FeeSeed = struct {
    fork_index: u8 = 3,
    excess: u64 = 0,
    used: u64 = 0,
    base: u256 = 17,
    target: u64 = 6,
    max: u64 = 9,
    fraction: u64 = fractions[1],
    step: u64 = 1,

    fn bytes(s: FeeSeed) [81]u8 {
        var out: [81]u8 = undefined;
        out[0] = s.fork_index;
        std.mem.writeInt(u64, out[1..9], s.excess, .little);
        std.mem.writeInt(u64, out[9..17], s.used, .little);
        std.mem.writeInt(u256, out[17..49], s.base, .little);
        std.mem.writeInt(u64, out[49..57], s.target, .little);
        std.mem.writeInt(u64, out[57..65], s.max, .little);
        std.mem.writeInt(u64, out[65..73], s.fraction, .little);
        std.mem.writeInt(u64, out[73..81], s.step, .little);
        return out;
    }
};

fn fuzzFee(_: void, input: []const u8) anyerror!void {
    var buf = [_]u8{0} ** 81;
    const len = @min(buf.len, input.len);
    @memcpy(buf[0..len], input[0..len]);
    const fork = forks[buf[0] % forks.len];
    const parent = Parent{
        .excess = std.mem.readInt(u64, buf[1..9], .little),
        .used = std.mem.readInt(u64, buf[9..17], .little),
        .base = std.mem.readInt(u256, buf[17..49], .little),
    };
    const p = fee.BlobParams.fromConfig(.{
        .target = std.mem.readInt(u64, buf[49..57], .little),
        .max = std.mem.readInt(u64, buf[57..65], .little),
        .base_fee_update_fraction = std.mem.readInt(u64, buf[65..73], .little),
    });
    const step = @max(1, std.mem.readInt(u64, buf[73..81], .little));
    try checkExponential(parent.base, parent.excess, p.base_fee_update_fraction, step);
    try checkAccounting(fork, p, parent, step, step);
}

test "fuzz: blob fee math, fork accounting, rounding and saturation from arbitrary bytes" {
    const g = fee.GAS_PER_BLOB;
    const seeds = [_]FeeSeed{
        .{ .fork_index = 0, .excess = max64, .used = max64, .base = max256 },
        .{ .fork_index = 1, .target = 3, .max = 6, .fraction = fractions[0], .excess = 177 * fractions[0], .step = fractions[0] },
        .{ .fork_index = 2, .used = 6 * g - 1, .base = max256 },
        .{ .used = 6 * g - 1, .base = max256 },
        .{ .used = 6 * g, .base = 16 },
        .{ .used = 9 * g, .base = 17 },
        .{ .excess = 26 * g, .step = g },
        .{ .used = 12 * g, .base = 16 },
        .{ .excess = max64, .used = max64, .target = 10, .max = 15, .fraction = fractions[2] },
        .{ .excess = 178 * fractions[3], .target = 14, .max = 21, .fraction = fractions[3], .base = max256 / 16 },
        .{ .excess = max64, .used = max64, .target = 0, .max = 0, .fraction = 0, .base = 0 },
        .{ .excess = max64, .used = max64, .target = max64, .max = max64 - 1, .fraction = max64, .base = max256, .step = max64 },
    };
    var encoded: [seeds.len][81]u8 = undefined;
    var corpus: [seeds.len][]const u8 = undefined;
    for (seeds, &encoded, &corpus) |s, *buf, *entry| {
        buf.* = s.bytes();
        entry.* = buf;
    }
    try std.testing.fuzz({}, fuzzFee, .{ .corpus = &corpus });
}

fn fuzzWrapper(_: void, input: []const u8) anyerror!void {
    const allocator = std.testing.allocator;
    // Exercise both public entry points on every input, including error paths.
    const parsed = encoding.decodeBlobNetworkWrapper(input);
    const canonical = encoding.canonicalTransactionEnvelope(allocator, input) catch |err| {
        if (err == error.OutOfMemory) return err;
        try std.testing.expectError(err, parsed);
        return;
    };
    defer canonical.deinit(allocator);
    if (try parsed) |view| {
        try std.testing.expect(canonical.owned != null);
        try std.testing.expect(canonical.bytes.len > 0);
        try std.testing.expectEqual(@as(u8, 3), canonical.bytes[0]);
        try std.testing.expectEqualSlices(u8, view.tx_payload, canonical.bytes[1..]);
        try std.testing.expect(view.blob_count > 0 and view.blob_count <= input.len / 131072);
        try checkSections(view, view.blob_count, view.version);
        const sidecars = try view.sidecars(allocator);
        defer allocator.free(sidecars);
        try std.testing.expectEqual(view.blob_count, sidecars.len);
        for (sidecars) |*sidecar| try std.testing.expectEqual(view.version == .v1, sidecar.proofs == .cells);
    } else {
        try std.testing.expect(canonical.owned == null);
        try std.testing.expectEqualSlices(u8, input, canonical.bytes);
    }
}

test "fuzz: decodeBlobNetworkWrapper and canonicalTransactionEnvelope on arbitrary wire bytes" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x7594_c09a);
    const v0 = try roundTrip(allocator, prng.random(), .v0, 1, full_width_r);
    defer allocator.free(v0);
    const v1 = try roundTrip(allocator, prng.random(), .v1, 2, full_width_r);
    defer allocator.free(v1);
    const short_proof = try allocator.dupe(u8, v1);
    defer allocator.free(short_proof);
    // Keep outer RLP lengths intact so the parser reaches the final cell.
    short_proof[short_proof.len - 49] = 0xaf;
    try std.testing.expectError(error.InvalidLength, encoding.decodeBlobNetworkWrapper(short_proof));
    const bare = try encoding.canonicalTransactionEnvelope(allocator, v0);
    defer bare.deinit(allocator);
    try fuzzWrapper({}, "");
    try std.testing.fuzz({}, fuzzWrapper, .{
        .corpus = &.{
            &.{ 2, 0xc0 }, // Non-blob typed envelope.
            &.{3}, // Missing RLP list.
            &.{ 3, 0xf8, 0x01, 0 }, // Long form for a short list.
            &.{ 3, 0xff, 255, 255, 255, 255, 255, 255, 255, 255 },
            &.{ 3, 0xc4, 0xc0, 0xc0, 0xc0, 0xc0 }, // Zero-blob v0.
            &.{ 3, 0xc5, 0xc0, 2, 0xc0, 0xc0, 0xc0 }, // Unknown wrapper version.
            bare.bytes,
            v0,
            v1,
            short_proof,
            v1[0 .. v1.len - 1],
        },
    });
}
