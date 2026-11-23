//! Deep consensus property and fuzz suite for `block_builder`, `chain_import`
//! and `mining_coordinator`.
//!
//! Part A: deterministic PRNG property tests against independent reference
//! models written in this file (EIP-1559 step law, EIP-7623 gas, greedy block
//! packing, EIP-4844/7918/7892 excess blob gas, RLP sizes).
//! Part B: a native `std.testing.fuzz` target for chain import.
//!
//! Tests named "KNOWN-BUG repro" assert spec behavior that production code
//! does not meet yet. They skip until `known_bug_repros_enabled` is flipped,
//! because the first one aborts the whole test binary with a safety panic.
const std = @import("std");
const primitives = @import("primitives");
const state_manager = @import("state-manager");
const guillotine_mini = @import("guillotine_mini");
const blockchain_mod = @import("blockchain");
const block_builder = @import("../block_builder.zig");
const chain_import = @import("../chain_import.zig");
const mining_coordinator = @import("../mining_coordinator.zig");
const tx_processor = @import("../tx_processor.zig");
const host_adapter = @import("../host_adapter.zig");
const hardfork_schedule = @import("../hardfork_schedule.zig");
const blob_fee = @import("../blob_fee.zig");

/// Both regressions in this file (EIP-1559 overflow and canonical RLP / header size) are patched and active.
const known_bug_repros_enabled = true;

const max64: u64 = std.math.maxInt(u64);
const max256: u256 = std.math.maxInt(u256);
const gas_per_blob: u64 = 131_072;
const rlp_block_cap: usize = 8_388_608;

// Mainnet activation timestamps, restated as literals so the reference model
// does not read the schedule it checks.
const ref_cancun_timestamp: u64 = 1_710_338_135;
const ref_prague_timestamp: u64 = 1_746_612_311;
const ref_osaka_timestamp: u64 = 1_764_798_551;
const ref_bpo1_timestamp: u64 = 1_765_290_071;
const ref_bpo2_timestamp: u64 = 1_767_747_671;

// ---------------------------------------------------------------------------
// Reference models
// ---------------------------------------------------------------------------

const BaseFeeModel = union(enum) {
    value: u256,
    invalid_gas_limit,
    overflow,
};

/// EIP-1559 `calc_base_fee` evaluated in u512, so no intermediate can wrap.
fn referenceBaseFee(parent_base_fee: u256, gas_used: u64, gas_limit: u64) BaseFeeModel {
    const target = gas_limit / 2;
    if (target == 0) return .invalid_gas_limit;
    if (gas_used == target) return .{ .value = parent_base_fee };

    const wide_fee: u512 = parent_base_fee;
    if (gas_used > target) {
        const raw: u512 = wide_fee * @as(u512, gas_used - target) / @as(u512, target) / 8;
        const delta: u512 = if (raw == 0) 1 else raw;
        const next = wide_fee + delta;
        if (next > @as(u512, max256)) return .overflow;
        return .{ .value = @intCast(next) };
    }

    const raw: u512 = wide_fee * @as(u512, target - gas_used) / @as(u512, target) / 8;
    const delta: u512 = if (raw > wide_fee) wide_fee else raw;
    return .{ .value = @intCast(wide_fee - delta) };
}

const BlobRule = struct {
    target: u64,
    max: u64,
    fraction: u64,
    osaka: bool,
};

/// Mainnet blob parameters of the block at `timestamp` (EIP-4844, EIP-7691,
/// EIP-7892 BPO1 and BPO2).
fn referenceBlobRule(timestamp: u64) BlobRule {
    if (timestamp >= ref_bpo2_timestamp) return .{ .target = 14, .max = 21, .fraction = 11_684_671, .osaka = true };
    if (timestamp >= ref_bpo1_timestamp) return .{ .target = 10, .max = 15, .fraction = 8_346_193, .osaka = true };
    if (timestamp >= ref_osaka_timestamp) return .{ .target = 6, .max = 9, .fraction = 5_007_716, .osaka = true };
    if (timestamp >= ref_prague_timestamp) return .{ .target = 6, .max = 9, .fraction = 5_007_716, .osaka = false };
    return .{ .target = 3, .max = 6, .fraction = 3_338_477, .osaka = false };
}

/// EIP-4844 `fake_exponential`, a direct transcription. Callers keep
/// `numerator / denominator` small, so u512 never wraps.
fn referenceFakeExponential(factor: u256, numerator: u64, denominator: u64) u256 {
    var i: u512 = 1;
    var output: u512 = 0;
    var accumulated: u512 = @as(u512, factor) * denominator;
    while (accumulated > 0) : (i += 1) {
        output += accumulated;
        accumulated = accumulated * numerator / (@as(u512, denominator) * i);
    }
    return @intCast(output / denominator);
}

/// EIP-4844 / EIP-7918 `calc_excess_blob_gas` with the child's blob rule.
fn referenceExcessBlobGas(rule: BlobRule, parent_excess: u64, parent_used: u64, parent_base_fee: u256) u64 {
    const total = @as(u128, parent_excess) + parent_used;
    const target_gas = @as(u128, rule.target) * gas_per_blob;
    if (total < target_gas) return 0;
    if (rule.osaka) {
        const parent_blob_fee = referenceFakeExponential(1, parent_excess, rule.fraction);
        if (@as(u512, 8_192) * parent_base_fee > @as(u512, gas_per_blob) * parent_blob_fee) {
            const scaled = @as(u128, parent_used) * (rule.max - rule.target) / rule.max;
            return @intCast(@as(u128, parent_excess) + scaled);
        }
    }
    return @intCast(total - target_gas);
}

/// Gas billed for a plain transfer with calldata: EIP-2028 intrinsic gas and,
/// from Prague, the EIP-7623 calldata floor.
fn referenceTxGas(data: []const u8, prague_floor: bool) u64 {
    var zeros: u64 = 0;
    for (data) |byte| {
        if (byte == 0) zeros += 1;
    }
    const nonzeros: u64 = @as(u64, @intCast(data.len)) - zeros;
    const intrinsic = 21_000 + 4 * zeros + 16 * nonzeros;
    if (!prague_floor) return intrinsic;
    return @max(intrinsic, 21_000 + 10 * (zeros + 4 * nonzeros));
}

const max_block_txs = 8;

const PackingModel = struct {
    included: [max_block_txs]usize = undefined,
    count: usize = 0,
    gas_used: u64 = 0,
    blob_gas_used: u64 = 0,
};

/// Greedy packing in list order: stop when the block is full, leave out a
/// transaction whose gas limit or blob gas does not fit.
fn modelPacking(
    transactions: []const tx_processor.ExecutionTx,
    block_gas_limit: u64,
    blob_gas_cap: u64,
    prague_floor: bool,
) PackingModel {
    var model = PackingModel{};
    for (transactions, 0..) |item, index| {
        if (model.gas_used >= block_gas_limit) break;
        if (item.tx.gas_limit > block_gas_limit - model.gas_used) continue;
        const blob_gas: u64 = @intCast(item.blob_gas_used orelse 0);
        if (blob_gas > blob_gas_cap) continue;
        if (model.blob_gas_used > blob_gas_cap - blob_gas) continue;
        model.included[model.count] = index;
        model.count += 1;
        model.gas_used += referenceTxGas(item.tx.data, prague_floor);
        model.blob_gas_used += blob_gas;
    }
    return model;
}

fn rlpLengthOfLength(length: usize) usize {
    var bytes: usize = 0;
    var rest = length;
    while (rest != 0) : (rest >>= 8) bytes += 1;
    return bytes;
}

/// Encoded size of an RLP list, or of a string longer than one byte.
fn referenceRlpItemLen(payload_len: usize) usize {
    if (payload_len < 56) return payload_len + 1;
    return payload_len + 1 + rlpLengthOfLength(payload_len);
}

/// EIP-7934 builder accounting for a block with an empty withdrawals list:
/// 742-byte header bound, empty ommers list, empty withdrawals list.
fn referenceBlockRlpSize(transactions_payload_len: usize) usize {
    return referenceRlpItemLen(742 + 1 + 1 + referenceRlpItemLen(transactions_payload_len));
}

// ---------------------------------------------------------------------------
// Shared fixtures
// ---------------------------------------------------------------------------

fn encodeRlpList(allocator: std.mem.Allocator, items: []const []const u8) ![]u8 {
    var payload_len: usize = 0;
    for (items) |item| payload_len += item.len;
    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);
    if (payload_len < 56) {
        try out.append(allocator, 0xc0 + @as(u8, @intCast(payload_len)));
    } else {
        const len_bytes = try primitives.Rlp.encodeLength(allocator, payload_len);
        defer allocator.free(len_bytes);
        try out.append(allocator, 0xf7 + @as(u8, @intCast(len_bytes.len)));
        try out.appendSlice(allocator, len_bytes);
    }
    for (items) |item| try out.appendSlice(allocator, item);
    return out.toOwnedSlice(allocator);
}

fn blockContext(
    number: u64,
    timestamp: u64,
    gas_limit: u64,
    base_fee: u256,
    blob_base_fee: u256,
    coinbase: primitives.Address,
) guillotine_mini.BlockContext {
    return .{
        .chain_id = 1,
        .block_number = number,
        .block_timestamp = timestamp,
        .block_difficulty = 0,
        .block_prevrandao = 0,
        .block_coinbase = coinbase,
        .block_gas_limit = gas_limit,
        .block_base_fee = base_fee,
        .blob_base_fee = blob_base_fee,
    };
}

fn randomU256(random: std.Random) u256 {
    return switch (random.uintLessThan(u8, 9)) {
        0 => 0,
        1 => random.uintLessThan(u8, 16),
        2 => @as(u256, 1_000_000_000) * random.uintAtMost(u8, 200),
        3 => max256,
        4 => max256 - random.int(u64),
        5 => (@as(u256, 1) << 255) + random.int(u64),
        6 => (@as(u256, 1) << 255) - random.int(u64),
        else => random.int(u256) >> random.int(u8),
    };
}

fn randomGasLimit(random: std.Random) u64 {
    return switch (random.uintLessThan(u8, 12)) {
        0 => 0,
        1 => 1,
        2 => 2,
        3 => 3,
        4 => 30_000_000,
        5 => 60_000_001,
        6 => max64,
        7 => max64 - 1,
        else => random.int(u64) >> random.int(u6),
    };
}

fn randomGasUsedWithin(random: std.Random, gas_limit: u64) u64 {
    const target = gas_limit / 2;
    return switch (random.uintLessThan(u8, 8)) {
        0 => 0,
        1 => target,
        2 => target -| 1,
        3 => @min(gas_limit, target +| 1),
        4 => @min(gas_limit, target *| 2),
        5 => gas_limit,
        else => random.uintAtMost(u64, gas_limit),
    };
}

const TxEnvironment = struct {
    base_fee: u256,
    blob_base_fee: u256,
    data_pool: []const u8,
    recipients: []const primitives.Address,
    blob_hashes: []const [32]u8,
};

/// A valid plain transfer: legacy, EIP-1559, or EIP-4844 with 1 to 6 blobs.
fn randomValidTx(
    random: std.Random,
    env: TxEnvironment,
    sender: primitives.Address,
    nonce: u64,
) tx_processor.ExecutionTx {
    const data_len = random.uintAtMost(usize, 64);
    const data_start = random.uintAtMost(usize, env.data_pool.len - data_len);
    const fee_cap: u256 = env.base_fee + random.uintAtMost(u8, 7);

    var item = tx_processor.ExecutionTx{
        .caller = sender,
        .tx = .{
            .nonce = nonce,
            .gas_price = fee_cap,
            // Covers the EIP-7623 floor for all-nonzero calldata.
            .gas_limit = 21_000 + 40 * @as(u64, @intCast(data_len)) + random.uintAtMost(u64, 3_000),
            .to = env.recipients[random.uintLessThan(usize, env.recipients.len)],
            .value = random.uintAtMost(u64, 1_000),
            .data = env.data_pool[data_start .. data_start + data_len],
            .v = 27 + random.uintAtMost(u64, 1),
            .r = [_]u8{0} ** 32,
            .s = [_]u8{0} ** 32,
        },
    };
    random.bytes(&item.tx.r);
    random.bytes(&item.tx.s);

    const kind = random.uintLessThan(u8, 20);
    if (kind < 8) return item;

    item.max_fee_per_gas = fee_cap;
    item.max_priority_fee_per_gas = @min(fee_cap, @as(u256, random.uintAtMost(u8, 5)));
    if (kind < 15) {
        item.receipt_type = .eip1559;
        return item;
    }

    const blob_count = 1 + random.uintLessThan(usize, 6);
    item.receipt_type = .eip4844;
    item.blob_gas_used = @as(u256, blob_count) * gas_per_blob;
    item.max_fee_per_blob_gas = env.blob_base_fee + random.uintAtMost(u8, 3);
    item.blob_versioned_hashes = env.blob_hashes[0..blob_count];
    return item;
}

const sender_count = 8;
const recipient_count = 4;
const funded_balance: u256 = 1_000_000_000_000_000_000_000_000_000;

const Actors = struct {
    senders: [sender_count]primitives.Address,
    recipients: [recipient_count + sender_count]primitives.Address,
    coinbase: primitives.Address,
    nonces: [sender_count]u64 = [_]u64{0} ** sender_count,
    data_pool: [512]u8,
    blob_hashes: [6][32]u8,

    fn init(random: std.Random, sm: *state_manager.StateManager) !Actors {
        var actors = Actors{
            .senders = undefined,
            .recipients = undefined,
            .coinbase = primitives.Address.fromU256(0xc0ffee),
            .data_pool = undefined,
            .blob_hashes = undefined,
        };
        for (&actors.senders, 0..) |*sender, index| {
            sender.* = primitives.Address.fromU256(0xa11ce000 + @as(u256, index));
            try sm.setBalance(sender.*, funded_balance);
            // Senders also receive transfers.
            actors.recipients[recipient_count + index] = sender.*;
        }
        for (actors.recipients[0..recipient_count], 0..) |*recipient, index| {
            recipient.* = primitives.Address.fromU256(0xb0b000 + @as(u256, index));
        }
        random.bytes(&actors.data_pool);
        for (&actors.data_pool) |*byte| {
            if (random.uintLessThan(u8, 3) == 0) byte.* = 0;
        }
        for (&actors.blob_hashes, 0..) |*hash, index| {
            hash.* = [_]u8{@as(u8, @intCast(index + 1))} ** 32;
            hash[0] = 0x01;
        }
        // Prague and later call both request system contracts every block.
        try sm.setCode(block_builder.WITHDRAWAL_REQUESTS_ADDRESS, &.{0x00});
        try sm.setCode(block_builder.CONSOLIDATION_REQUESTS_ADDRESS, &.{0x00});
        return actors;
    }

    fn environment(self: *const Actors, base_fee: u256, blob_base_fee: u256) TxEnvironment {
        return .{
            .base_fee = base_fee,
            .blob_base_fee = blob_base_fee,
            .data_pool = &self.data_pool,
            .recipients = &self.recipients,
            .blob_hashes = &self.blob_hashes,
        };
    }

    /// Fills `out` with transactions from distinct senders, so leaving one
    /// out never invalidates the nonce of a later one.
    fn randomBatch(
        self: *const Actors,
        random: std.Random,
        env: TxEnvironment,
        out: *[max_block_txs]tx_processor.ExecutionTx,
    ) []const tx_processor.ExecutionTx {
        var order: [sender_count]usize = undefined;
        for (&order, 0..) |*slot, index| slot.* = index;
        random.shuffle(usize, &order);
        const count = random.uintAtMost(usize, @min(max_block_txs, sender_count) - 1);
        for (out[0..count], order[0..count]) |*item, sender_index| {
            item.* = randomValidTx(random, env, self.senders[sender_index], self.nonces[sender_index]);
        }
        return out[0..count];
    }

    fn recordIncluded(self: *Actors, transaction: tx_processor.ExecutionTx) void {
        for (self.senders, 0..) |sender, index| {
            if (std.mem.eql(u8, &sender.bytes, &transaction.caller.bytes)) self.nonces[index] += 1;
        }
    }

    fn expectNonces(self: *const Actors, sm: *state_manager.StateManager) !void {
        for (self.senders, self.nonces) |sender, nonce| {
            try std.testing.expectEqual(nonce, try sm.getNonce(sender));
        }
    }

    /// Total wei held by every account a transaction can touch.
    fn totalBalance(self: *const Actors, sm: *state_manager.StateManager) !u256 {
        var total: u256 = try sm.getBalance(self.coinbase);
        // `recipients` also lists every sender.
        for (self.recipients) |address| total += try sm.getBalance(address);
        return total;
    }
};

fn expectBuiltBlockMatchesModel(
    result: block_builder.BlockResult,
    model: PackingModel,
    transactions: []const tx_processor.ExecutionTx,
    prague_floor: bool,
) !void {
    try std.testing.expectEqualSlices(usize, model.included[0..model.count], result.included_tx_indexes);
    try std.testing.expectEqual(model.count, result.receipts.len);
    try std.testing.expectEqual(model.gas_used, result.total_gas_used);
    try std.testing.expectEqual(model.blob_gas_used, result.blob_gas_used);

    var cumulative: u256 = 0;
    for (result.receipts, result.included_tx_indexes, 0..) |receipt, tx_index, position| {
        const item = transactions[tx_index];
        const gas: u256 = referenceTxGas(item.tx.data, prague_floor);
        cumulative += gas;
        try std.testing.expectEqual(gas, receipt.gas_used);
        try std.testing.expectEqual(cumulative, receipt.cumulative_gas_used);
        try std.testing.expectEqual(@as(u32, @intCast(position)), receipt.transaction_index);
        try std.testing.expectEqual(item.receipt_type, receipt.type);
        try std.testing.expect(receipt.status.?.success);
        try std.testing.expectEqual(item.blob_gas_used, receipt.blob_gas_used);
    }
}

// ---------------------------------------------------------------------------
// Part A.1: EIP-1559 base fee step law
// ---------------------------------------------------------------------------

fn expectBaseFeeStepLaw(parent_base_fee: u256, gas_used: u64, gas_limit: u64) !void {
    const parent = primitives.BlockHeader.BlockHeader{
        .gas_limit = gas_limit,
        .gas_used = gas_used,
        .base_fee_per_gas = parent_base_fee,
    };
    const actual = block_builder.expectedBaseFeePerGas(&parent);
    const coordinator = mining_coordinator.calculateNextBaseFee(parent_base_fee, gas_used, gas_limit);
    const target = gas_limit / 2;

    switch (referenceBaseFee(parent_base_fee, gas_used, gas_limit)) {
        .invalid_gas_limit => {
            try std.testing.expectError(error.InvalidGasLimit, actual);
            try std.testing.expectEqual(parent_base_fee, coordinator);
        },
        .overflow => {
            try std.testing.expectError(error.BaseFeeOverflow, actual);
            try std.testing.expectEqual(max256, coordinator);
            try std.testing.expect(gas_used > target);
        },
        .value => |expected| {
            const next = try actual;
            try std.testing.expectEqual(expected, next);
            // The dev coordinator and the header validator agree.
            try std.testing.expectEqual(expected, coordinator);

            if (gas_used == target) {
                try std.testing.expectEqual(parent_base_fee, next);
            } else if (gas_used > target) {
                try std.testing.expect(next > parent_base_fee);
                const delta = next - parent_base_fee;
                if (gas_used - target <= target) {
                    // At most 12.5%, except the mandatory minimum step of 1 wei.
                    try std.testing.expect(delta == 1 or delta <= parent_base_fee / 8);
                } else {
                    // Odd gas limit, completely full block: gas_used = 2 * target + 1.
                    try std.testing.expectEqual(target + 1, gas_used - target);
                    try std.testing.expect(delta == 1 or delta <= parent_base_fee / 4);
                }
            } else {
                try std.testing.expect(next <= parent_base_fee);
                try std.testing.expect(parent_base_fee - next <= parent_base_fee / 8);
            }
        },
    }
}

test "property: EIP-1559 base fee moves at most 12.5% per block and never panics on extreme u256 fees" {
    var prng = std.Random.DefaultPrng.init(0x1559_0001);
    const random = prng.random();

    // A header without a base fee starts the London fee market.
    const pre_london = primitives.BlockHeader.BlockHeader{ .gas_limit = 30_000_000, .gas_used = 30_000_000 };
    try std.testing.expectEqual(@as(u256, 1_000_000_000), try block_builder.expectedBaseFeePerGas(&pre_london));

    const corner_fees = [_]u256{ 0, 1, 7, 8, 9, 1_000_000_000, max256 / 8, max256 - 1, max256 };
    const corner_limits = [_]u64{ 0, 1, 2, 3, 4, 5_000, 30_000_000, 60_000_001, max64 - 1, max64 };
    for (corner_fees) |fee| {
        for (corner_limits) |limit| {
            const target = limit / 2;
            for ([_]u64{ 0, target -| 1, target, @min(limit, target +| 1), @min(limit, target *| 2), limit }) |used| {
                try expectBaseFeeStepLaw(fee, used, limit);
            }
        }
    }

    for (0..300) |_| {
        const fee = randomU256(random);
        const limit = randomGasLimit(random);
        const used_a = randomGasUsedWithin(random, limit);
        const used_b = randomGasUsedWithin(random, limit);
        try expectBaseFeeStepLaw(fee, used_a, limit);
        try expectBaseFeeStepLaw(fee, used_b, limit);

        // More gas used never yields a lower next base fee.
        const low = referenceBaseFee(fee, @min(used_a, used_b), limit);
        const high = referenceBaseFee(fee, @max(used_a, used_b), limit);
        switch (low) {
            .invalid_gas_limit => try std.testing.expect(high == .invalid_gas_limit),
            .overflow => try std.testing.expect(high == .overflow),
            .value => |low_fee| switch (high) {
                .invalid_gas_limit => return error.TestUnexpectedResult,
                .overflow => {},
                .value => |high_fee| try std.testing.expect(high_fee >= low_fee),
            },
        }
    }
}

test "property: validateHeader accepts exactly the EIP-1559 base fee and rejects its neighbors" {
    var prng = std.Random.DefaultPrng.init(0x1559_0002);
    const random = prng.random();

    for (0..200) |_| {
        const gas_limit = 5_000 + random.uintLessThan(u64, 60_000_000);
        const parent = primitives.BlockHeader.BlockHeader{
            .ommers_hash = primitives.BlockHeader.EMPTY_OMMERS_HASH,
            .number = random.uintLessThan(u64, 30_000_000),
            .gas_limit = gas_limit,
            .gas_used = randomGasUsedWithin(random, gas_limit),
            .timestamp = random.uintLessThan(u64, 2_000_000_000),
            .base_fee_per_gas = random.int(u256) >> random.int(u8),
        };
        const expected = switch (referenceBaseFee(parent.base_fee_per_gas.?, parent.gas_used, gas_limit)) {
            .value => |fee| fee,
            else => continue,
        };

        var child = primitives.BlockHeader.BlockHeader{
            .ommers_hash = primitives.BlockHeader.EMPTY_OMMERS_HASH,
            .number = parent.number + 1,
            .gas_limit = gas_limit,
            .gas_used = random.uintAtMost(u64, gas_limit),
            .timestamp = parent.timestamp + 1 + random.uintLessThan(u64, 100),
            .base_fee_per_gas = expected,
        };
        try block_builder.validateHeader(&child, &parent, .paris);

        if (expected != max256) {
            child.base_fee_per_gas = expected + 1;
            try std.testing.expectError(error.InvalidBaseFeePerGas, block_builder.validateHeader(&child, &parent, .paris));
        }
        if (expected != 0) {
            child.base_fee_per_gas = expected - 1;
            try std.testing.expectError(error.InvalidBaseFeePerGas, block_builder.validateHeader(&child, &parent, .paris));
        }
        child.base_fee_per_gas = null;
        try std.testing.expectError(error.MissingBaseFeePerGas, block_builder.validateHeader(&child, &parent, .paris));
    }
}

test "KNOWN-BUG repro (skipped until patched): expectedBaseFeePerGas must not panic when parent.gas_used exceeds parent.gas_limit" {
    // block_builder.zig:646 narrows a u512 delta to u256 with @intCast. With
    // gas_used far above the target and a base fee near 2^256 the delta does
    // not fit, and the cast aborts instead of returning error.BaseFeeOverflow.
    if (!known_bug_repros_enabled) return error.SkipZigTest;

    var prng = std.Random.DefaultPrng.init(0x1559_0003);
    const random = prng.random();
    try expectUnvalidatedParentBaseFee(max256, max64, 2);
    for (0..200) |_| {
        try expectUnvalidatedParentBaseFee(randomU256(random), random.int(u64), randomGasLimit(random));
    }
}

fn expectUnvalidatedParentBaseFee(parent_base_fee: u256, gas_used: u64, gas_limit: u64) !void {
    const parent = primitives.BlockHeader.BlockHeader{
        .gas_limit = gas_limit,
        .gas_used = gas_used,
        .base_fee_per_gas = parent_base_fee,
    };
    const actual = block_builder.expectedBaseFeePerGas(&parent);
    switch (referenceBaseFee(parent_base_fee, gas_used, gas_limit)) {
        .invalid_gas_limit => try std.testing.expectError(error.InvalidGasLimit, actual),
        .overflow => try std.testing.expectError(error.BaseFeeOverflow, actual),
        .value => |expected| try std.testing.expectEqual(expected, try actual),
    }
}

// ---------------------------------------------------------------------------
// Part A.2: multi-block buildBlock -> validateBlock round trip
// ---------------------------------------------------------------------------

const ForkSegment = struct {
    first_timestamp: u64,
    fork: block_builder.Hardfork,
    max_blobs: u64,
};

const fork_segments = [_]ForkSegment{
    // The synthetic parent sits on the Cancun activation timestamp.
    .{ .first_timestamp = ref_cancun_timestamp + 12, .fork = .cancun, .max_blobs = 6 },
    .{ .first_timestamp = ref_prague_timestamp, .fork = .prague, .max_blobs = 9 },
    .{ .first_timestamp = ref_osaka_timestamp, .fork = .osaka, .max_blobs = 9 },
    .{ .first_timestamp = ref_bpo1_timestamp, .fork = .osaka, .max_blobs = 15 },
    .{ .first_timestamp = ref_bpo2_timestamp, .fork = .osaka, .max_blobs = 21 },
};

const HeaderMutation = enum {
    gas_used,
    excess_blob_gas,
    transactions_root,
    receipts_root,
    logs_bloom,
    base_fee,
    blob_gas_used,
};

fn validationInput(
    header: *const primitives.BlockHeader.BlockHeader,
    parent: *const primitives.BlockHeader.BlockHeader,
    fork: block_builder.Hardfork,
    transactions: []const tx_processor.ExecutionTx,
    result: block_builder.BlockResult,
) block_builder.BlockValidationInput {
    return .{
        .header = header,
        .parent_header = parent,
        .fork = fork,
        .hardfork_config = hardfork_schedule.MAINNET_CHAIN_CONFIG,
        .execution_transactions = transactions,
        .receipts = result.receipts,
        .withdrawals = &.{},
        .state_root = result.state_root,
        .requests_hash = result.requests_hash,
    };
}

test "property: buildBlock output passes validateBlock across Cancun, Prague, Osaka, BPO1 and BPO2" {
    const allocator = std.testing.allocator;
    const config = hardfork_schedule.MAINNET_CHAIN_CONFIG;
    const blocks_per_segment = 30;

    var prng = std.Random.DefaultPrng.init(0xb10c_0002);
    const random = prng.random();

    var sm = try state_manager.StateManager.init(allocator, null);
    defer sm.deinit();
    var adapter = host_adapter.HostAdapter{ .state = &sm };
    var actors = try Actors.init(random, &sm);

    // Synthetic Cancun parent with non-trivial gas and blob history.
    var parent = primitives.BlockHeader.BlockHeader{
        .ommers_hash = primitives.BlockHeader.EMPTY_OMMERS_HASH,
        .beneficiary = actors.coinbase,
        .transactions_root = primitives.BlockHeader.EMPTY_TRANSACTIONS_ROOT,
        .receipts_root = primitives.BlockHeader.EMPTY_RECEIPTS_ROOT,
        .number = 20_000_000,
        .gas_limit = 120_000,
        .gas_used = random.uintAtMost(u64, 120_000),
        .timestamp = ref_cancun_timestamp,
        .base_fee_per_gas = 1_000_000_000,
        .withdrawals_root = primitives.BlockHeader.EMPTY_WITHDRAWALS_ROOT,
        .blob_gas_used = random.uintAtMost(u64, 6) * gas_per_blob,
        .excess_blob_gas = random.uintAtMost(u64, 40) * gas_per_blob + random.uintLessThan(u64, gas_per_blob),
        .parent_beacon_block_root = primitives.Hash.ZERO,
    };
    var parent_requests_hash: ?[32]u8 = null;

    var blocks_above_target: usize = 0;
    var blocks_with_left_out_tx: usize = 0;

    for (fork_segments) |segment| {
        for (0..blocks_per_segment) |block_in_segment| {
            const number = parent.number + 1;
            const timestamp = if (block_in_segment == 0)
                segment.first_timestamp
            else
                parent.timestamp + 1 + random.uintLessThan(u64, 24);

            // The schedule resolves the fork this segment targets.
            const evm_fork = hardfork_schedule.resolveHardforkWithConfig(config, number, timestamp);
            const fork = block_builder.hardforkFromEvm(evm_fork);
            try std.testing.expectEqual(segment.fork, fork);
            const rule = referenceBlobRule(timestamp);
            try std.testing.expectEqual(segment.max_blobs, rule.max);
            const prague_floor = timestamp >= ref_prague_timestamp;

            // Header fields the parent determines.
            const base_fee = referenceBaseFee(parent.base_fee_per_gas.?, parent.gas_used, parent.gas_limit).value;
            const excess = referenceExcessBlobGas(
                rule,
                parent.excess_blob_gas.?,
                parent.blob_gas_used.?,
                parent.base_fee_per_gas.?,
            );
            try std.testing.expectEqual(
                excess,
                mining_coordinator.nextExcessBlobGasForChildWithConfig(config, parent, number, timestamp),
            );
            const blob_base_fee = referenceFakeExponential(1, excess, rule.fraction);
            try std.testing.expectEqual(blob_base_fee, blob_fee.blobBaseFeeAt(config, number, timestamp, excess));

            // Gas limit walks inside the 1/1024 band.
            const band = parent.gas_limit / 1024 - 1;
            const gas_limit = parent.gas_limit - band + random.uintAtMost(u64, 2 * band);

            var batch: [max_block_txs]tx_processor.ExecutionTx = undefined;
            const transactions = actors.randomBatch(random, actors.environment(base_fee, blob_base_fee), &batch);
            const model = modelPacking(transactions, gas_limit, rule.max * gas_per_blob, prague_floor);

            const parent_hash = try block_builder.computeHeaderHashWithRequestsHash(allocator, &parent, parent_requests_hash);
            var beacon_root: [32]u8 = undefined;
            random.bytes(&beacon_root);
            const supply_before = try actors.totalBalance(&sm);

            var result = try block_builder.buildBlockWithOptions(
                allocator,
                &sm,
                adapter.hostInterface(),
                transactions,
                blockContext(number, timestamp, gas_limit, base_fee, blob_base_fee, actors.coinbase),
                .{
                    .hardfork_config = config,
                    .withdrawals = &.{},
                    .parent_beacon_block_root = beacon_root,
                    .parent_hash = parent_hash,
                    .skip_invalid_transactions = true,
                },
            );
            defer result.deinit(allocator);

            // Builder output equals the reference packing and gas model.
            try expectBuiltBlockMatchesModel(result, model, transactions, prague_floor);
            try std.testing.expectEqual(number, result.block_number);
            try std.testing.expect(result.blob_gas_used <= rule.max * gas_per_blob);
            try std.testing.expect(result.total_gas_used <= gas_limit);
            try std.testing.expect(result.rlp_size_upper_bound <= rlp_block_cap);
            if (result.total_gas_used > gas_limit / 2) blocks_above_target += 1;
            if (model.count < transactions.len) blocks_with_left_out_tx += 1;

            var included: [max_block_txs]tx_processor.ExecutionTx = undefined;
            for (result.included_tx_indexes, 0..) |tx_index, position| {
                included[position] = transactions[tx_index];
                actors.recordIncluded(transactions[tx_index]);
            }
            const included_transactions = included[0..result.included_tx_indexes.len];
            try actors.expectNonces(&sm);

            // Conservation: the base fee and the blob fee are burned, nothing else.
            const burned = base_fee * result.total_gas_used + blob_base_fee * result.blob_gas_used;
            try std.testing.expectEqual(supply_before - burned, try actors.totalBalance(&sm));

            // The committed state root is the root of the live state.
            const live_state_root = try block_builder.computeStateRoot(allocator, &sm);
            try std.testing.expectEqualSlices(u8, &live_state_root, &result.state_root);

            const header = primitives.BlockHeader.BlockHeader{
                .parent_hash = parent_hash,
                .ommers_hash = primitives.BlockHeader.EMPTY_OMMERS_HASH,
                .beneficiary = actors.coinbase,
                .state_root = result.state_root,
                .transactions_root = result.transactions_root,
                .receipts_root = result.receipts_root,
                .logs_bloom = result.logs_bloom,
                .number = number,
                .gas_limit = gas_limit,
                .gas_used = result.total_gas_used,
                .timestamp = timestamp,
                .base_fee_per_gas = base_fee,
                .withdrawals_root = result.withdrawals_root,
                .blob_gas_used = result.blob_gas_used,
                .excess_blob_gas = excess,
                .parent_beacon_block_root = beacon_root,
            };

            const commitments = try block_builder.validateBlock(
                allocator,
                validationInput(&header, &parent, fork, included_transactions, result),
            );
            try std.testing.expectEqualSlices(u8, &result.transactions_root, &commitments.transactions_root);
            try std.testing.expectEqualSlices(u8, &result.receipts_root, &commitments.receipts_root);
            try std.testing.expectEqualSlices(u8, &result.logs_bloom, &commitments.logs_bloom);
            try std.testing.expectEqualSlices(u8, &result.withdrawals_root.?, &commitments.withdrawals_root.?);
            try std.testing.expectEqualSlices(u8, &primitives.BlockHeader.EMPTY_WITHDRAWALS_ROOT, &commitments.withdrawals_root.?);
            try std.testing.expectEqual(result.blob_gas_used, commitments.blob_gas_used);
            try std.testing.expectEqual(@as(?u64, excess), commitments.excess_blob_gas);
            try std.testing.expectEqual(result.requests_hash, commitments.requests_hash);
            try std.testing.expectEqual(prague_floor, result.requests_hash != null);

            // The public root helpers reproduce the committed roots.
            const transactions_root = try block_builder.computeTransactionsRoot(allocator, included_transactions);
            try std.testing.expectEqualSlices(u8, &transactions_root, &result.transactions_root);
            const receipts_root = try block_builder.computeReceiptsRoot(allocator, result.receipts);
            try std.testing.expectEqualSlices(u8, &receipts_root, &result.receipts_root);
            const logs_bloom = block_builder.aggregateLogsBloom(result.receipts);
            try std.testing.expectEqualSlices(u8, &logs_bloom, &result.logs_bloom);

            // The same header through the coordinator's header-only checks.
            try mining_coordinator.validateBlobGasWithConfig(config, parent, header);
            try chain_import.validateImportedBlobHeader(config, parent, header);

            // One wrong commitment invalidates the block with its own error.
            for (0..2) |_| {
                var bad = header;
                const expected_error: anyerror = switch (random.enumValue(HeaderMutation)) {
                    .gas_used => blk: {
                        bad.gas_used += 1;
                        break :blk if (bad.gas_used > bad.gas_limit) error.HeaderGasUsedExceedsLimit else error.InvalidGasUsed;
                    },
                    .excess_blob_gas => blk: {
                        bad.excess_blob_gas = excess + 1;
                        break :blk error.InvalidExcessBlobGas;
                    },
                    .transactions_root => blk: {
                        bad.transactions_root[random.uintLessThan(usize, 32)] ^= 0x01;
                        break :blk error.InvalidTransactionsRoot;
                    },
                    .receipts_root => blk: {
                        bad.receipts_root[random.uintLessThan(usize, 32)] ^= 0x01;
                        break :blk error.InvalidReceiptsRoot;
                    },
                    .logs_bloom => blk: {
                        bad.logs_bloom[random.uintLessThan(usize, 256)] ^= 0x80;
                        break :blk error.InvalidLogsBloom;
                    },
                    .base_fee => blk: {
                        bad.base_fee_per_gas = base_fee + 1;
                        break :blk error.InvalidBaseFeePerGas;
                    },
                    .blob_gas_used => blk: {
                        bad.blob_gas_used = result.blob_gas_used + gas_per_blob;
                        break :blk error.InvalidBlobGasUsed;
                    },
                };
                try std.testing.expectError(expected_error, block_builder.validateBlock(
                    allocator,
                    validationInput(&bad, &parent, fork, included_transactions, result),
                ));
            }

            parent = header;
            parent_requests_hash = result.requests_hash;
        }
    }

    // The generator reaches both sides of the gas target and the skip path.
    try std.testing.expect(blocks_above_target > 0);
    try std.testing.expect(blocks_above_target < fork_segments.len * blocks_per_segment);
    try std.testing.expect(blocks_with_left_out_tx > 0);
}

// ---------------------------------------------------------------------------
// Part A.3: EIP-7934 RLP block size cap
// ---------------------------------------------------------------------------

fn sizeGateOptions() block_builder.BuildBlockOptions {
    return .{
        .hardfork_config = hardfork_schedule.MAINNET_CHAIN_CONFIG,
        .withdrawals = &.{},
        .parent_beacon_block_root = [_]u8{0} ** 32,
        .parent_hash = [_]u8{0x11} ** 32,
    };
}

fn encodeLegacyTransaction(allocator: std.mem.Allocator, tx: primitives.Transaction.LegacyTransaction) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const to_rlp = if (tx.to) |address|
        try primitives.Rlp.encodeBytes(a, &address.bytes)
    else
        try primitives.Rlp.encodeBytes(a, &.{});
    return encodeRlpList(allocator, &.{
        try primitives.Rlp.encode(a, tx.nonce),
        try primitives.Rlp.encode(a, tx.gas_price),
        try primitives.Rlp.encode(a, tx.gas_limit),
        to_rlp,
        try primitives.Rlp.encode(a, tx.value),
        try primitives.Rlp.encodeBytes(a, tx.data),
        try primitives.Rlp.encode(a, tx.v),
        try primitives.Rlp.encode(a, std.mem.readInt(u256, &tx.r, .big)),
        try primitives.Rlp.encode(a, std.mem.readInt(u256, &tx.s, .big)),
    });
}

test "property: EIP-7934 cap is exact at 8,388,608 bytes on Osaka and absent on Prague" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x7934_0001);
    const random = prng.random();

    try std.testing.expectEqual(rlp_block_cap, block_builder.MAX_RLP_BLOCK_SIZE);
    try std.testing.expectEqual(rlp_block_cap, chain_import.MAX_RLP_BLOCK_SIZE);

    const calldata = try allocator.alloc(u8, rlp_block_cap + 8_192);
    defer allocator.free(calldata);
    @memset(calldata, 0);

    var sm = try state_manager.StateManager.init(allocator, null);
    defer sm.deinit();
    var adapter = host_adapter.HostAdapter{ .state = &sm };
    try sm.setCode(block_builder.WITHDRAWAL_REQUESTS_ADDRESS, &.{0x00});
    try sm.setCode(block_builder.CONSOLIDATION_REQUESTS_ADDRESS, &.{0x00});
    const sender = primitives.Address.fromU256(0x7934);
    try sm.setBalance(sender, funded_balance);
    const untouched_state_root = try block_builder.computeStateRoot(allocator, &sm);

    for (0..300) |iteration| {
        // The transaction can never execute: its nonce is ahead of the
        // account. The builder checks the block size before it executes
        // anything, so the returned error tells which gate fired without
        // paying for 8 MiB of calldata per iteration.
        var item = tx_processor.ExecutionTx{
            .caller = sender,
            .tx = .{
                .nonce = 1 + random.uintLessThan(u64, 1_000),
                .gas_price = random.int(u256) >> random.int(u8),
                .gas_limit = 16_777_216,
                .to = if (random.boolean()) primitives.Address.fromU256(0x200) else null,
                .value = random.int(u256) >> random.int(u8),
                .data = calldata[0..8_300_000],
                .v = random.int(u64) >> random.int(u6),
                .r = [_]u8{0} ** 32,
                .s = [_]u8{0} ** 32,
            },
        };
        random.bytes(&item.tx.r);
        random.bytes(&item.tx.s);
        if (random.boolean()) {
            item.receipt_type = .eip1559;
            item.max_fee_per_gas = item.tx.gas_price;
            item.max_priority_fee_per_gas = random.int(u64);
        }

        // Every length in this range keeps a 4-byte RLP prefix, so the size
        // is the calldata length plus a constant.
        const overhead = block_builder.executionTxRlpSize(item, 1) - 8_300_000;
        const distance: i64 = if (random.boolean())
            random.intRangeAtMost(i64, -3, 3)
        else
            random.intRangeAtMost(i64, -4_096, 4_096);
        const block_size: usize = @intCast(@as(i64, rlp_block_cap) + distance);
        // 742 + 2 fixed payload bytes and two 4-byte list prefixes.
        const data_len = block_size - 752 - overhead;
        item.tx.data = calldata[0..data_len];

        const tx_size = block_builder.executionTxRlpSize(item, 1);
        try std.testing.expectEqual(data_len + overhead, tx_size);
        try std.testing.expectEqual(block_size, referenceBlockRlpSize(tx_size));
        const over_cap = block_size > rlp_block_cap;

        // Stateless validators.
        if (over_cap) {
            try std.testing.expectError(error.BlockRlpSizeExceeded, block_builder.validateBlockRlpSize(block_size, .osaka));
            try std.testing.expectError(error.BlockRlpSizeExceeded, chain_import.validateBlockRlpSize(block_size, .OSAKA));
        } else {
            try block_builder.validateBlockRlpSize(block_size, .osaka);
            try chain_import.validateBlockRlpSize(block_size, .OSAKA);
        }
        try block_builder.validateBlockRlpSize(block_size, .prague);
        try block_builder.validateBlockRlpSize(block_size, .cancun);
        try chain_import.validateBlockRlpSize(block_size, .PRAGUE);
        try chain_import.validateBlockRlpSize(block_size, .CANCUN);

        // Builder gate on Osaka: over the cap fails on size, at or under the
        // cap reaches execution and fails on the nonce.
        const osaka_error: anyerror = if (over_cap) error.BlockRlpSizeExceeded else error.InvalidIncludedTransaction;
        try std.testing.expectError(osaka_error, block_builder.buildBlockWithOptions(
            allocator,
            &sm,
            adapter.hostInterface(),
            &.{item},
            blockContext(2, ref_osaka_timestamp + 12, 30_000_000, 0, 1, primitives.Address.fromU256(0xc0ffee)),
            sizeGateOptions(),
        ));
        // Prague has no size rule: every size reaches execution.
        try std.testing.expectError(error.InvalidIncludedTransaction, block_builder.buildBlockWithOptions(
            allocator,
            &sm,
            adapter.hostInterface(),
            &.{item},
            blockContext(2, ref_prague_timestamp + 12, 30_000_000, 0, 1, primitives.Address.fromU256(0xc0ffee)),
            sizeGateOptions(),
        ));

        // A rejected block leaves no trace in state.
        const state_root = try block_builder.computeStateRoot(allocator, &sm);
        try std.testing.expectEqualSlices(u8, &untouched_state_root, &state_root);
        try std.testing.expectEqual(@as(u64, 0), try sm.getNonce(sender));

        // The size estimate equals a real 8 MiB encoding (legacy, few rounds).
        if (iteration < 3) {
            var legacy = item;
            legacy.receipt_type = .legacy;
            const encoded = try encodeLegacyTransaction(allocator, legacy.tx);
            defer allocator.free(encoded);
            try std.testing.expectEqual(encoded.len, block_builder.executionTxRlpSize(legacy, 1));
        }
    }
}

test "property: EIP-7934 exact-fit Osaka block builds, one more byte is rejected on Osaka and built on Prague" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x7934_0002);
    const random = prng.random();

    // Six zero-calldata transfers. Each stays under the EIP-7825 gas cap
    // (21,000 + 10 gas per byte <= 16,777,216) and together they land on the
    // EIP-7934 cap. Five lengths are random, the sixth is solved for.
    const tx_count = 6;
    const calldata = try allocator.alloc(u8, 1_700_000);
    defer allocator.free(calldata);
    @memset(calldata, 0);

    var transactions: [tx_count]tx_processor.ExecutionTx = undefined;
    var first_five_size: usize = 0;
    for (&transactions, 0..) |*item, index| {
        const data_len = 1_360_000 + random.uintLessThan(usize, 240_000);
        item.* = .{
            .caller = primitives.Address.fromU256(0x1000 + @as(u256, index)),
            .tx = .{
                .nonce = 0,
                .gas_price = 1,
                .gas_limit = 16_777_216,
                .to = primitives.Address.fromU256(0x200),
                .value = 1,
                .data = calldata[0..data_len],
                .v = 27,
                .r = [_]u8{0} ** 32,
                .s = [_]u8{0} ** 32,
            },
        };
        if (index < tx_count - 1) first_five_size += block_builder.executionTxRlpSize(item.*, 1);
    }
    const last = &transactions[tx_count - 1];
    const overhead = block_builder.executionTxRlpSize(last.*, 1) - last.tx.data.len;
    // 8,387,856 transaction bytes plus 752 bytes of block framing is the cap.
    const exact_fit_len = 8_387_856 - first_five_size - overhead;
    try std.testing.expect(exact_fit_len >= 65_536 and exact_fit_len < 1_675_000);

    const context_osaka = blockContext(2, ref_osaka_timestamp + 12, 200_000_000, 0, 1, primitives.Address.fromU256(0xc0ffee));
    const context_prague = blockContext(2, ref_prague_timestamp + 12, 200_000_000, 0, 1, primitives.Address.fromU256(0xc0ffee));

    for ([_]bool{ true, false }) |osaka| {
        var sm = try state_manager.StateManager.init(allocator, null);
        defer sm.deinit();
        var adapter = host_adapter.HostAdapter{ .state = &sm };
        try sm.setCode(block_builder.WITHDRAWAL_REQUESTS_ADDRESS, &.{0x00});
        try sm.setCode(block_builder.CONSOLIDATION_REQUESTS_ADDRESS, &.{0x00});
        for (transactions) |item| try sm.setBalance(item.caller, 1_000_000_000_000);

        // One byte over the cap.
        last.tx.data = calldata[0 .. exact_fit_len + 1];
        var expected_size = rlp_block_cap + 1;
        if (osaka) {
            try std.testing.expectError(error.BlockRlpSizeExceeded, block_builder.buildBlockWithOptions(
                allocator,
                &sm,
                adapter.hostInterface(),
                &transactions,
                context_osaka,
                sizeGateOptions(),
            ));
            for (transactions) |item| {
                try std.testing.expectEqual(@as(u64, 0), try sm.getNonce(item.caller));
                try std.testing.expectEqual(@as(u256, 1_000_000_000_000), try sm.getBalance(item.caller));
            }
            // Exactly on the cap: the same state builds the block.
            last.tx.data = calldata[0..exact_fit_len];
            expected_size = rlp_block_cap;
        }

        var result = try block_builder.buildBlockWithOptions(
            allocator,
            &sm,
            adapter.hostInterface(),
            &transactions,
            if (osaka) context_osaka else context_prague,
            sizeGateOptions(),
        );
        defer result.deinit(allocator);

        try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3, 4, 5 }, result.included_tx_indexes);
        try std.testing.expectEqual(expected_size, result.rlp_size_upper_bound);
        var expected_gas: u64 = 0;
        for (transactions) |item| expected_gas += referenceTxGas(item.tx.data, true);
        try std.testing.expectEqual(expected_gas, result.total_gas_used);
        for (transactions) |item| try std.testing.expectEqual(@as(u64, 1), try sm.getNonce(item.caller));
    }
}

fn randomSignatureWord(random: std.Random) [32]u8 {
    var word: [32]u8 = undefined;
    random.bytes(&word);
    // Leading zero bytes exercise integer trimming, down to the value zero.
    if (random.boolean()) @memset(word[0..random.uintAtMost(usize, 32)], 0);
    return word;
}

fn randomWideUint(random: std.Random) u256 {
    return random.int(u256) >> random.int(u8);
}

fn randomNarrowUint(random: std.Random) u64 {
    return random.int(u64) >> random.int(u6);
}

test "property: executionTxRlpSize equals the real RLP encoding for random transactions of every type" {
    var prng = std.Random.DefaultPrng.init(0x7934_0003);
    const random = prng.random();

    var data_pool: [1_300]u8 = undefined;
    random.bytes(&data_pool);
    const boundary_lengths = [_]usize{ 0, 1, 2, 55, 56, 57, 255, 256, 257 };
    const transaction_types = [_]primitives.Receipt.TransactionType{ .legacy, .eip2930, .eip1559, .eip4844, .eip7702 };

    for (0..250) |iteration| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const data_len = if (random.boolean())
            boundary_lengths[random.uintLessThan(usize, boundary_lengths.len)]
        else
            random.uintAtMost(usize, data_pool.len);
        const data = data_pool[0..data_len];
        // A single byte below 0x80 encodes as itself; above, with a prefix.
        if (data_len == 1) data[0] = if (random.boolean()) random.uintLessThan(u8, 0x80) else 0x80 + random.uintLessThan(u8, 0x80);

        const receipt_type = transaction_types[iteration % transaction_types.len];
        const chain_id = randomWideUint(random);
        const max_fee = randomWideUint(random);
        const max_priority = randomWideUint(random);
        const max_fee_per_blob_gas = randomWideUint(random);
        const y_parity: u64 = random.uintAtMost(u64, 1);
        const tx = primitives.Transaction.LegacyTransaction{
            .nonce = randomNarrowUint(random),
            .gas_price = max_fee,
            .gas_limit = randomNarrowUint(random),
            .to = if (random.uintLessThan(u8, 4) == 0) null else primitives.Address.fromU256(random.int(u160)),
            .value = randomWideUint(random),
            .data = data,
            .v = randomNarrowUint(random),
            .r = randomSignatureWord(random),
            .s = randomSignatureWord(random),
        };

        const access_list = try a.alloc(primitives.AccessList.AccessListEntry, random.uintAtMost(usize, 3));
        for (access_list) |*entry| {
            const keys = try a.alloc([32]u8, random.uintAtMost(usize, 3));
            for (keys) |*key| random.bytes(key);
            entry.* = .{ .address = primitives.Address.fromU256(random.int(u160)), .storage_keys = keys };
        }
        const blob_hashes = try a.alloc([32]u8, random.uintAtMost(usize, 6));
        for (blob_hashes) |*hash| random.bytes(hash);
        const authorizations = try a.alloc(primitives.Authorization.Authorization, random.uintAtMost(usize, 3));
        for (authorizations) |*authorization| {
            authorization.* = .{
                .chain_id = randomNarrowUint(random),
                .address = primitives.Address.fromU256(random.int(u160)),
                .nonce = randomNarrowUint(random),
                .v = randomNarrowUint(random),
                .r = randomSignatureWord(random),
                .s = randomSignatureWord(random),
            };
        }

        const nonce_rlp = try primitives.Rlp.encode(a, tx.nonce);
        const gas_limit_rlp = try primitives.Rlp.encode(a, tx.gas_limit);
        const to_rlp = if (tx.to) |address|
            try primitives.Rlp.encodeBytes(a, &address.bytes)
        else
            try primitives.Rlp.encodeBytes(a, &.{});
        const value_rlp = try primitives.Rlp.encode(a, tx.value);
        const data_rlp = try primitives.Rlp.encodeBytes(a, data);
        const r_rlp = try primitives.Rlp.encode(a, std.mem.readInt(u256, &tx.r, .big));
        const s_rlp = try primitives.Rlp.encode(a, std.mem.readInt(u256, &tx.s, .big));
        const chain_id_rlp = try primitives.Rlp.encode(a, chain_id);
        const max_fee_rlp = try primitives.Rlp.encode(a, max_fee);
        const max_priority_rlp = try primitives.Rlp.encode(a, max_priority);
        const y_parity_rlp = try primitives.Rlp.encode(a, y_parity);

        const access_list_rlp = blk: {
            const entries = try a.alloc([]const u8, access_list.len);
            for (access_list, entries) |entry, *encoded| {
                const keys = try a.alloc([]const u8, entry.storage_keys.len);
                for (entry.storage_keys, keys) |key, *encoded_key| encoded_key.* = try primitives.Rlp.encodeBytes(a, &key);
                encoded.* = try encodeRlpList(a, &.{
                    try primitives.Rlp.encodeBytes(a, &entry.address.bytes),
                    try encodeRlpList(a, keys),
                });
            }
            break :blk try encodeRlpList(a, entries);
        };

        var item = tx_processor.ExecutionTx{ .caller = primitives.Address.fromU256(0x100), .tx = tx, .receipt_type = receipt_type };
        const payload: []const u8 = switch (receipt_type) {
            .legacy => try encodeRlpList(a, &.{
                nonce_rlp,                          max_fee_rlp, gas_limit_rlp, to_rlp, value_rlp, data_rlp,
                try primitives.Rlp.encode(a, tx.v), r_rlp,       s_rlp,
            }),
            .eip2930 => blk: {
                item.access_list = access_list;
                break :blk try encodeRlpList(a, &.{
                    chain_id_rlp,    nonce_rlp,    max_fee_rlp, gas_limit_rlp, to_rlp, value_rlp, data_rlp,
                    access_list_rlp, y_parity_rlp, r_rlp,       s_rlp,
                });
            },
            .eip1559 => blk: {
                item.access_list = access_list;
                item.max_fee_per_gas = max_fee;
                item.max_priority_fee_per_gas = max_priority;
                break :blk try encodeRlpList(a, &.{
                    chain_id_rlp, nonce_rlp,       max_priority_rlp, max_fee_rlp, gas_limit_rlp, to_rlp, value_rlp,
                    data_rlp,     access_list_rlp, y_parity_rlp,     r_rlp,       s_rlp,
                });
            },
            .eip4844 => blk: {
                item.access_list = access_list;
                item.max_fee_per_gas = max_fee;
                item.max_priority_fee_per_gas = max_priority;
                item.max_fee_per_blob_gas = max_fee_per_blob_gas;
                item.blob_versioned_hashes = blob_hashes;
                const hashes = try a.alloc([]const u8, blob_hashes.len);
                for (blob_hashes, hashes) |hash, *encoded| encoded.* = try primitives.Rlp.encodeBytes(a, &hash);
                break :blk try encodeRlpList(a, &.{
                    chain_id_rlp, nonce_rlp,       max_priority_rlp,                                   max_fee_rlp,                  gas_limit_rlp, to_rlp, value_rlp,
                    data_rlp,     access_list_rlp, try primitives.Rlp.encode(a, max_fee_per_blob_gas), try encodeRlpList(a, hashes), y_parity_rlp,  r_rlp,  s_rlp,
                });
            },
            .eip7702 => blk: {
                item.access_list = access_list;
                item.max_fee_per_gas = max_fee;
                item.max_priority_fee_per_gas = max_priority;
                item.authorization_list = authorizations;
                const encoded_authorizations = try a.alloc([]const u8, authorizations.len);
                for (authorizations, encoded_authorizations) |authorization, *encoded| {
                    encoded.* = try encodeRlpList(a, &.{
                        try primitives.Rlp.encode(a, authorization.chain_id),
                        try primitives.Rlp.encodeBytes(a, &authorization.address.bytes),
                        try primitives.Rlp.encode(a, authorization.nonce),
                        try primitives.Rlp.encode(a, authorization.v),
                        try primitives.Rlp.encode(a, std.mem.readInt(u256, &authorization.r, .big)),
                        try primitives.Rlp.encode(a, std.mem.readInt(u256, &authorization.s, .big)),
                    });
                }
                break :blk try encodeRlpList(a, &.{
                    chain_id_rlp, nonce_rlp,       max_priority_rlp,                             max_fee_rlp,  gas_limit_rlp, to_rlp, value_rlp,
                    data_rlp,     access_list_rlp, try encodeRlpList(a, encoded_authorizations), y_parity_rlp, r_rlp,         s_rlp,
                });
            },
        };

        // A legacy transaction is a list in the body; a typed one is the byte
        // string `type || rlp(payload)`.
        const body_item_len = if (receipt_type == .legacy) payload.len else blk: {
            const envelope = try a.alloc(u8, payload.len + 1);
            envelope[0] = 0x02;
            @memcpy(envelope[1..], payload);
            break :blk (try primitives.Rlp.encodeBytes(a, envelope)).len;
        };
        try std.testing.expectEqual(body_item_len, block_builder.executionTxRlpSize(item, chain_id));
    }
}

// ---------------------------------------------------------------------------
// Part A.4: MiningCoordinator multi-block chain invariant
// ---------------------------------------------------------------------------

test "property: MiningCoordinator keeps numbers, timestamps and EIP-7918/7892 excess blob gas continuous from Osaka through BPO1 and BPO2" {
    const allocator = std.testing.allocator;
    const config = hardfork_schedule.MAINNET_CHAIN_CONFIG;
    const block_count = 180;
    const bpo1_block = 60;
    const bpo2_block = 120;

    // The reference table restates the schedule; fail loudly if it drifts.
    try std.testing.expectEqual(ref_cancun_timestamp, config.cancun_timestamp);
    try std.testing.expectEqual(ref_prague_timestamp, config.prague_timestamp);
    try std.testing.expectEqual(ref_osaka_timestamp, config.osaka_timestamp);
    try std.testing.expectEqual(ref_bpo1_timestamp, hardfork_schedule.MAINNET_BPO1.timestamp);
    try std.testing.expectEqual(ref_bpo2_timestamp, hardfork_schedule.MAINNET_BPO2.timestamp);

    var prng = std.Random.DefaultPrng.init(0x7918_7892);
    const random = prng.random();

    var sm = try state_manager.StateManager.init(allocator, null);
    defer sm.deinit();
    var adapter = host_adapter.HostAdapter{ .state = &sm };
    var actors = try Actors.init(random, &sm);

    var mc = mining_coordinator.MiningCoordinator.init();
    defer mc.deinit(allocator);
    mc.setMode(.manual);
    mc.coinbase = actors.coinbase;
    mc.block_gas_limit = 100_000;
    mc.current_block_number = 23_000_000;
    mc.current_timestamp = ref_osaka_timestamp + 100;
    mc.current_base_fee_per_gas = 1_000_000_000;
    mc.current_excess_blob_gas = random.uintAtMost(u64, 80) * gas_per_blob + random.uintLessThan(u64, gas_per_blob);

    // Model of the parent block: null before the first mined block.
    var previous: ?primitives.BlockHeader.BlockHeader = null;
    var base_fee: u256 = mc.current_base_fee_per_gas.?;
    var base_fee_overridden = true;
    const seeded_excess = mc.current_excess_blob_gas;

    var reserve_rule_blocks: usize = 0;
    var target_rule_blocks: usize = 0;

    for (0..block_count) |index| {
        // Move the clock: land one second before each BPO activation, mine
        // the activation block on the exact timestamp, otherwise drift.
        if (index == bpo1_block - 1) {
            mc.current_timestamp = ref_bpo1_timestamp - 1;
        } else if (index == bpo2_block - 1) {
            mc.current_timestamp = ref_bpo2_timestamp - 1;
        } else if (index != bpo1_block and index != bpo2_block and random.boolean()) {
            mc.current_timestamp += random.uintLessThan(u64, 24);
        }
        if (index == bpo1_block) try std.testing.expectEqual(ref_bpo1_timestamp, mc.current_timestamp);
        if (index == bpo2_block) try std.testing.expectEqual(ref_bpo2_timestamp, mc.current_timestamp);

        const number = mc.current_block_number;
        const timestamp = mc.current_timestamp;
        const rule = referenceBlobRule(timestamp);
        const expected_max_blobs: u64 = if (index < bpo1_block) 9 else if (index < bpo2_block) 15 else 21;
        try std.testing.expectEqual(expected_max_blobs, rule.max);
        try std.testing.expectEqual(expected_max_blobs, blob_fee.resolveBlobParams(config, number, timestamp).max_blobs);

        // Excess blob gas of the block about to be mined.
        const excess = if (previous) |parent|
            referenceExcessBlobGas(rule, parent.excess_blob_gas.?, parent.blob_gas_used.?, parent.base_fee_per_gas.?)
        else
            seeded_excess;
        try std.testing.expectEqual(excess, mc.excessAt(number, timestamp));
        if (previous) |parent| {
            const parent_blob_fee = referenceFakeExponential(1, parent.excess_blob_gas.?, rule.fraction);
            const total = parent.excess_blob_gas.? + parent.blob_gas_used.?;
            if (total >= rule.target * gas_per_blob) {
                if (@as(u512, 8_192) * parent.base_fee_per_gas.? > @as(u512, gas_per_blob) * parent_blob_fee) {
                    reserve_rule_blocks += 1;
                } else {
                    target_rule_blocks += 1;
                }
            }
        }

        const context = mc.blockContext(.{});
        const blob_base_fee = referenceFakeExponential(1, excess, rule.fraction);
        try std.testing.expectEqual(number, context.block_number);
        try std.testing.expectEqual(timestamp, context.block_timestamp);
        try std.testing.expectEqual(base_fee, context.block_base_fee);
        try std.testing.expectEqual(blob_base_fee, context.blob_base_fee);
        try std.testing.expectEqual(mc.block_gas_limit, context.block_gas_limit);

        var batch: [max_block_txs]tx_processor.ExecutionTx = undefined;
        const transactions = actors.randomBatch(random, actors.environment(base_fee, blob_base_fee), &batch);
        for (transactions) |item| try mc.submitTx(allocator, &sm, item);
        try std.testing.expectEqual(transactions.len, mc.pending_txs.items.len);
        const model = modelPacking(transactions, mc.block_gas_limit, rule.max * gas_per_blob, true);

        var parent_hash: [32]u8 = undefined;
        random.bytes(&parent_hash);
        var result = try mc.mineBlockWithOptions(allocator, &sm, adapter.hostInterface(), .{
            .prevrandao = random.int(u256),
            .parent_hash = parent_hash,
            .skip_invalid_transactions = true,
        });
        defer result.deinit(allocator);

        try expectBuiltBlockMatchesModel(result, model, transactions, true);
        for (result.included_tx_indexes) |tx_index| actors.recordIncluded(transactions[tx_index]);
        try actors.expectNonces(&sm);

        // Block number and timestamp advance by exactly one.
        try std.testing.expectEqual(number, result.block_number);
        try std.testing.expectEqual(number + 1, mc.current_block_number);
        try std.testing.expectEqual(timestamp + 1, mc.current_timestamp);
        try std.testing.expectEqual(@as(usize, 0), mc.pending_txs.items.len);
        try std.testing.expectEqual(index + 1, mc.mined_blocks.items.len);
        const stored = mc.mined_blocks.items[index];
        try std.testing.expectEqual(number, stored.block_number);
        try std.testing.expectEqual(result.blob_gas_used, stored.blob_gas_used);
        try std.testing.expectEqualSlices(u8, &result.state_root, &stored.state_root);
        try std.testing.expect(result.blob_gas_used <= rule.max * gas_per_blob);

        // The coordinator retains this block as the next block's parent.
        const retained = mc.parent_blob_fees.?;
        try std.testing.expectEqual(excess, retained.excess);
        try std.testing.expectEqual(result.blob_gas_used, retained.used);
        try std.testing.expectEqual(base_fee, retained.base_fee);
        try std.testing.expectEqual(@as(u64, 0), mc.current_blob_gas_used);

        const header = primitives.BlockHeader.BlockHeader{
            .ommers_hash = primitives.BlockHeader.EMPTY_OMMERS_HASH,
            .number = number,
            .gas_limit = mc.block_gas_limit,
            .gas_used = result.total_gas_used,
            .timestamp = timestamp,
            .base_fee_per_gas = base_fee,
            .blob_gas_used = result.blob_gas_used,
            .excess_blob_gas = excess,
        };

        // Header-level continuity against the parent, through three modules.
        if (previous) |parent| {
            try std.testing.expectEqual(parent.number + 1, header.number);
            try std.testing.expect(header.timestamp > parent.timestamp);
            try mining_coordinator.validateBlobGasWithConfig(config, parent, header);
            try chain_import.validateImportedBlobHeader(config, parent, header);
            try std.testing.expectEqual(excess, blob_fee.nextExcessBlobGasForHeader(config, parent, number, timestamp));

            var wrong_excess = header;
            wrong_excess.excess_blob_gas = excess + 1;
            try std.testing.expectError(
                error.InvalidExcessBlobGas,
                mining_coordinator.validateBlobGasWithConfig(config, parent, wrong_excess),
            );
            var too_many_blobs = header;
            too_many_blobs.blob_gas_used = (rule.max + 1) * gas_per_blob;
            try std.testing.expectError(
                error.BlobGasLimitExceeded,
                chain_import.validateImportedBlobHeader(config, parent, too_many_blobs),
            );

            if (!base_fee_overridden) {
                try mining_coordinator.validateBaseFee(parent, header);
                try block_builder.validateHeader(&header, &parent, .osaka);
                try std.testing.expectEqual(base_fee, try block_builder.expectedBaseFeePerGas(&parent));
            }
        }

        // Fee state prepared for the next block.
        const next_base_fee = referenceBaseFee(base_fee, result.total_gas_used, mc.block_gas_limit).value;
        try std.testing.expectEqual(@as(?u256, next_base_fee), mc.current_base_fee_per_gas);
        try std.testing.expectEqual(
            referenceExcessBlobGas(referenceBlobRule(timestamp + 1), excess, result.blob_gas_used, base_fee),
            mc.current_excess_blob_gas,
        );

        previous = header;
        base_fee = next_base_fee;
        base_fee_overridden = false;

        // Sometimes set the next base fee directly (dev override), from 1 wei
        // to about 68 gwei, so both EIP-7918 branches stay reachable.
        if (random.uintLessThan(u8, 5) == 0) {
            base_fee = @as(u256, 1) << random.uintLessThan(u8, 37);
            mc.current_base_fee_per_gas = base_fee;
            base_fee_overridden = true;
        }
    }

    // Both the reserve-price rule and the plain target rule were exercised.
    try std.testing.expect(reserve_rule_blocks > 0);
    try std.testing.expect(target_rule_blocks > 0);
}

// ---------------------------------------------------------------------------
// Part B: chain import fuzz target
// ---------------------------------------------------------------------------

fn rlpPrefixLit(comptime base: u8, comptime len: usize) []const u8 {
    if (len < 56) return &[_]u8{base + @as(u8, @intCast(len))};
    if (len < 256) return &[_]u8{ base + 56, @as(u8, @intCast(len)) };
    return &[_]u8{ base + 57, @as(u8, @intCast(len >> 8)), @as(u8, @intCast(len & 0xff)) };
}

// The literal builders evaluate at compile time even when a test body calls
// them, so every seed is a constant.
fn rlpStringLit(comptime payload: []const u8) []const u8 {
    return comptime blk: {
        if (payload.len == 1 and payload[0] < 0x80) break :blk payload;
        break :blk rlpPrefixLit(0x80, payload.len) ++ payload;
    };
}

fn rlpListLit(comptime items: []const []const u8) []const u8 {
    return comptime blk: {
        var payload: []const u8 = &.{};
        for (items) |item| payload = payload ++ item;
        break :blk rlpPrefixLit(0xc0, payload.len) ++ payload;
    };
}

/// `depth` lists nested inside each other around one empty list.
fn nestedListLit(comptime depth: usize) []const u8 {
    return comptime blk: {
        var item: []const u8 = &.{0xc0};
        for (0..depth) |_| item = rlpListLit(&.{item});
        break :blk item;
    };
}

fn keccakLit(comptime bytes: []const u8) [32]u8 {
    @setEvalBranchQuota(4_000_000);
    var out: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(bytes, &out, .{});
    return out;
}

/// Header fields are given already RLP-encoded, so a seed can carry a
/// malformed or non-canonical field.
const HeaderLit = struct {
    parent_hash: [32]u8 = [_]u8{0} ** 32,
    number: []const u8 = &.{0x80},
    gas_limit: []const u8 = &.{ 0x83, 0x0f, 0x42, 0x40 },
    gas_used: []const u8 = &.{0x80},
    timestamp: []const u8 = &.{0x2a},
    extra_data: []const u8 = &.{ 0x83, 'z', 'v', 'm' },
    /// Fields after the nonce: base fee, withdrawals root, blob gas, ...
    tail: []const []const u8 = &.{&.{0x07}},
};

const hash_lit = rlpStringLit(&([_]u8{0x11} ** 32));

fn headerLit(comptime spec: HeaderLit) []const u8 {
    const fields = [_][]const u8{
        rlpStringLit(&spec.parent_hash),
        rlpStringLit(&primitives.BlockHeader.EMPTY_OMMERS_HASH),
        rlpStringLit(&([_]u8{0xaa} ** 20)),
        hash_lit,
        hash_lit,
        hash_lit,
        rlpStringLit(&([_]u8{0} ** 256)),
        &.{0x80},
        spec.number,
        spec.gas_limit,
        spec.gas_used,
        spec.timestamp,
        spec.extra_data,
        hash_lit,
        rlpStringLit(&([_]u8{0} ** 8)),
    };
    return comptime rlpListLit(&fields ++ spec.tail);
}

fn blockLit(comptime header: []const u8, comptime body: []const []const u8) []const u8 {
    const head = [_][]const u8{header};
    return comptime rlpListLit(&head ++ body);
}

const empty_list_lit: []const u8 = &.{0xc0};
const empty_body_lit = [_][]const u8{ empty_list_lit, empty_list_lit };

const genesis_header_lit = headerLit(.{});
const genesis_block_lit = blockLit(genesis_header_lit, &empty_body_lit);
const child_header_lit = headerLit(.{
    .parent_hash = keccakLit(genesis_header_lit),
    .number = &.{0x01},
    .timestamp = &.{0x36},
});
const child_block_lit = blockLit(child_header_lit, &empty_body_lit);
const two_block_chain_lit = genesis_block_lit ++ child_block_lit;

const cancun_tail_lit = [_][]const u8{
    &.{0x07},
    hash_lit,
    &.{ 0x83, 0x02, 0x00, 0x00 },
    &.{0x80},
    hash_lit,
};
const prague_tail_lit = cancun_tail_lit ++ [_][]const u8{hash_lit};
const withdrawal_lit = rlpListLit(&.{ &.{0x01}, &.{0x02}, rlpStringLit(&([_]u8{0xbb} ** 20)), &.{ 0x82, 0x03, 0xe8 } });
const legacy_tx_lit = rlpListLit(&.{ &.{0x80}, &.{0x01}, &.{ 0x82, 0x52, 0x08 }, &.{0x80}, &.{0x80}, &.{0x80}, &.{0x1b}, &.{0x01}, &.{0x01} });
const typed_tx_lit = rlpStringLit(&[_]u8{0x02} ++ rlpListLit(&.{ &.{0x01}, &.{0x80}, &.{0x80} }));
/// Type-3 envelope whose first payload item is a list: the network wrapper
/// that canonical block bodies must reject.
const wrapped_blob_tx_lit = rlpStringLit(&[_]u8{0x03} ++ rlpListLit(&.{ rlpListLit(&.{&.{0x01}}), empty_list_lit }));

const fuzz_corpus = [_][]const u8{
    // Empty stream, a lone empty string and a lone empty list.
    &.{},
    &.{0x80},
    empty_list_lit,
    // Valid London genesis, and a two-block canonical chain.
    genesis_block_lit,
    two_block_chain_lit,
    // The same block twice: the second copy is a duplicate hash.
    genesis_block_lit ++ genesis_block_lit,
    // An orphan: block 1 without its parent.
    child_block_lit,
    // One ommer, a 15-field pre-London header.
    blockLit(genesis_header_lit, &.{ empty_list_lit, rlpListLit(&.{headerLit(.{ .tail = &.{} })}) }),
    // Shanghai body with one withdrawal and a Cancun header.
    blockLit(headerLit(.{ .tail = &cancun_tail_lit }), &.{ empty_list_lit, empty_list_lit, rlpListLit(&.{withdrawal_lit}) }),
    // Prague header (21 fields) with a legacy and a typed transaction.
    blockLit(headerLit(.{ .tail = &prague_tail_lit }), &.{ rlpListLit(&.{ legacy_tx_lit, typed_tx_lit }), empty_list_lit, empty_list_lit }),
    // Network-wrapped blob transaction in a block body.
    blockLit(genesis_header_lit, &.{ rlpListLit(&.{wrapped_blob_tx_lit}), empty_list_lit }),
    // Truncated genesis block.
    genesis_block_lit[0 .. genesis_block_lit.len / 2],
    // Header with 14 fields; block with two and with five body fields.
    blockLit(rlpListLit(&([_][]const u8{hash_lit} ** 14)), &empty_body_lit),
    blockLit(genesis_header_lit, &.{empty_list_lit}),
    blockLit(genesis_header_lit, &.{ empty_list_lit, empty_list_lit, empty_list_lit, empty_list_lit }),
    // Ommer nested deeper than Voltaire's RLP recursion limit.
    blockLit(genesis_header_lit, &.{ empty_list_lit, rlpListLit(&.{nestedListLit(40)}) }),
    // Length prefixes that lie: past the end, 8-byte length, leading zero.
    &.{ 0xf9, 0xff, 0xff, 0xc0, 0xc0 },
    &.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff },
    &.{ 0xbf, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff },
    &.{ 0xf9, 0x00, 0x03, 0xc0, 0xc0, 0xc0 },
    // Header fields of the wrong kind: number as a list, 9-byte gas limit.
    blockLit(headerLit(.{ .number = &.{ 0xc1, 0x01 } }), &empty_body_lit),
    blockLit(headerLit(.{ .gas_limit = &.{ 0x89, 0x01, 0, 0, 0, 0, 0, 0, 0, 0 } }), &empty_body_lit),
};

const ImportOutcome = struct {
    failure: ?anyerror = null,
    block_count: usize = 0,
    transaction_count: usize = 0,
    head_block_number: u64 = 0,
    head_hash: [32]u8 = [_]u8{0} ** 32,
    owned_bodies: usize = 0,
    stored_blocks: usize = 0,
};

/// End offset of the RLP item at `start`, or null when it is cut short.
fn topLevelItemEnd(bytes: []const u8, start: usize) ?usize {
    if (start >= bytes.len) return null;
    const prefix = bytes[start];
    var header_len: usize = 1;
    var payload_len: usize = 0;
    if (prefix <= 0x7f) {
        return start + 1;
    } else if (prefix <= 0xb7) {
        payload_len = prefix - 0x80;
    } else if (prefix <= 0xbf or prefix >= 0xf8) {
        const length_bytes: usize = if (prefix <= 0xbf) prefix - 0xb7 else prefix - 0xf7;
        if (bytes.len - start - 1 < length_bytes) return null;
        var value: u128 = 0;
        for (bytes[start + 1 .. start + 1 + length_bytes]) |byte| value = (value << 8) | byte;
        if (value > bytes.len) return null;
        payload_len = @intCast(value);
        header_len = 1 + length_bytes;
    } else {
        payload_len = prefix - 0xc0;
    }
    const end = start + header_len + payload_len;
    if (end > bytes.len) return null;
    return end;
}

fn importOnce(
    allocator: std.mem.Allocator,
    input: []const u8,
    options: chain_import.ImportOptions,
) anyerror!ImportOutcome {
    var chain = try blockchain_mod.Blockchain.init(allocator, null);
    defer chain.deinit();
    var owned_block_bodies = std.ArrayList(chain_import.OwnedBlockBody){};
    defer {
        for (owned_block_bodies.items) |*body| body.deinit(allocator);
        owned_block_bodies.deinit(allocator);
    }

    const stats = chain_import.importChainBytesWithOptions(allocator, &chain, &owned_block_bodies, input, options) catch |err| {
        // A block is stored only after its body buffers are owned.
        try std.testing.expect(chain.localBlockCount() <= owned_block_bodies.items.len);
        return .{
            .failure = err,
            .owned_bodies = owned_block_bodies.items.len,
            .stored_blocks = chain.localBlockCount(),
        };
    };

    // Every imported block owns one body, and the stream is consumed exactly.
    try std.testing.expectEqual(stats.block_count, owned_block_bodies.items.len);
    var offset: usize = 0;
    var top_level_items: usize = 0;
    while (offset < input.len) : (top_level_items += 1) {
        offset = topLevelItemEnd(input, offset) orelse return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(input.len, offset);
    try std.testing.expectEqual(top_level_items, stats.block_count);

    var transaction_count: usize = 0;
    for (owned_block_bodies.items) |body| {
        transaction_count += body.transactions.len;
        // Each owned body belongs to a stored block no larger than the input.
        const stored = (try chain.getBlockByHash(body.block_hash)) orelse return error.TestUnexpectedResult;
        try std.testing.expect(stored.size <= input.len);
        if (options.hardfork_config) |config| {
            const fork = hardfork_schedule.resolveHardforkWithConfig(config, stored.header.number, stored.header.timestamp);
            if (fork.isAtLeast(.OSAKA)) try std.testing.expect(stored.size <= chain_import.MAX_RLP_BLOCK_SIZE);
        }
    }
    try std.testing.expectEqual(transaction_count, stats.transaction_count);
    try std.testing.expect(chain.localBlockCount() <= stats.block_count);

    if (stats.block_count == 0) {
        try std.testing.expectEqual(@as(usize, 0), input.len);
        try std.testing.expectEqualSlices(u8, &primitives.Hash.ZERO, &stats.head_hash);
    } else {
        const head_body = owned_block_bodies.items[owned_block_bodies.items.len - 1];
        try std.testing.expectEqualSlices(u8, &head_body.block_hash, &stats.head_hash);
        const head = (try chain.getBlockByHash(stats.head_hash)) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(stats.head_block_number, head.header.number);
        try std.testing.expect(chain.localBlockCount() >= 1);
    }

    return .{
        .block_count = stats.block_count,
        .transaction_count = stats.transaction_count,
        .head_block_number = stats.head_block_number,
        .head_hash = stats.head_hash,
        .owned_bodies = owned_block_bodies.items.len,
        .stored_blocks = chain.localBlockCount(),
    };
}

fn expectSameOutcome(expected: ImportOutcome, actual: ImportOutcome) !void {
    try std.testing.expectEqual(expected.failure, actual.failure);
    try std.testing.expectEqual(expected.block_count, actual.block_count);
    try std.testing.expectEqual(expected.transaction_count, actual.transaction_count);
    try std.testing.expectEqual(expected.head_block_number, actual.head_block_number);
    try std.testing.expectEqualSlices(u8, &expected.head_hash, &actual.head_hash);
    try std.testing.expectEqual(expected.owned_bodies, actual.owned_bodies);
    try std.testing.expectEqual(expected.stored_blocks, actual.stored_blocks);
}

fn fuzzImportChainBytes(_: void, input: []const u8) anyerror!void {
    // Counts bytes per input: `std.testing.allocator` alone reports a leak
    // only when the whole test ends, which a fuzz run never does.
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = counting.allocator();

    const with_schedule = try importOnce(allocator, input, .{ .hardfork_config = hardfork_schedule.MAINNET_CHAIN_CONFIG });
    // Import is a pure function of the bytes.
    try expectSameOutcome(with_schedule, try importOnce(allocator, input, .{ .hardfork_config = hardfork_schedule.MAINNET_CHAIN_CONFIG }));
    // Under the EIP-7934 cap the schedule cannot change the result.
    if (input.len <= chain_import.MAX_RLP_BLOCK_SIZE) {
        if (with_schedule.failure) |failure| try std.testing.expect(failure != error.BlockRlpSizeExceeded);
        try expectSameOutcome(with_schedule, try importOnce(allocator, input, .{}));
    }

    try std.testing.expectEqual(counting.allocated_bytes, counting.freed_bytes);
    try std.testing.expectEqual(counting.allocations, counting.deallocations);
}

test "import corpus seeds hit the paths they are named for" {
    const allocator = std.testing.allocator;
    const mainnet = chain_import.ImportOptions{ .hardfork_config = hardfork_schedule.MAINNET_CHAIN_CONFIG };

    const empty = try importOnce(allocator, &.{}, mainnet);
    try std.testing.expectEqual(@as(?anyerror, null), empty.failure);
    try std.testing.expectEqual(@as(usize, 0), empty.block_count);

    const genesis = try importOnce(allocator, genesis_block_lit, mainnet);
    try std.testing.expectEqual(@as(?anyerror, null), genesis.failure);
    try std.testing.expectEqual(@as(usize, 1), genesis.block_count);
    try std.testing.expectEqual(@as(u64, 0), genesis.head_block_number);
    try std.testing.expectEqualSlices(u8, &keccakLit(genesis_header_lit), &genesis.head_hash);

    const chain = try importOnce(allocator, two_block_chain_lit, mainnet);
    try std.testing.expectEqual(@as(?anyerror, null), chain.failure);
    try std.testing.expectEqual(@as(usize, 2), chain.block_count);
    try std.testing.expectEqual(@as(usize, 2), chain.stored_blocks);
    try std.testing.expectEqual(@as(u64, 1), chain.head_block_number);
    try std.testing.expectEqualSlices(u8, &keccakLit(child_header_lit), &chain.head_hash);

    const truncated = try importOnce(allocator, genesis_block_lit[0 .. genesis_block_lit.len / 2], mainnet);
    try std.testing.expectEqual(@as(?anyerror, error.InvalidChainRlp), truncated.failure);
    try std.testing.expectEqual(@as(usize, 0), truncated.stored_blocks);

    // A failure after a valid block keeps the valid block and nothing else.
    const partial = try importOnce(allocator, genesis_block_lit ++ [_]u8{ 0xf9, 0xff, 0xff }, mainnet);
    try std.testing.expectEqual(@as(?anyerror, error.InvalidChainRlp), partial.failure);
    try std.testing.expectEqual(@as(usize, 1), partial.owned_bodies);
    try std.testing.expectEqual(@as(usize, 1), partial.stored_blocks);
}

test "property: mutated chain streams import deterministically without panic or leak" {
    var prng = std.Random.DefaultPrng.init(0x1a90_27b1);
    const random = prng.random();
    const rlp_boundary_bytes = [_]u8{ 0x00, 0x7f, 0x80, 0x81, 0xb7, 0xb8, 0xbf, 0xc0, 0xc1, 0xf7, 0xf8, 0xf9, 0xff };

    var buffer: [4_096]u8 = undefined;
    for (0..300) |_| {
        const seed = fuzz_corpus[random.uintLessThan(usize, fuzz_corpus.len)];
        var len: usize = @min(seed.len, buffer.len);
        @memcpy(buffer[0..len], seed[0..len]);

        switch (random.uintLessThan(u8, 6)) {
            // Flip one bit in up to four bytes.
            0 => if (len > 0) {
                for (0..1 + random.uintLessThan(usize, 4)) |_| {
                    buffer[random.uintLessThan(usize, len)] ^= @as(u8, 1) << random.int(u3);
                }
            },
            // Truncate.
            1 => len = random.uintAtMost(usize, len),
            // Replace bytes with RLP prefix boundary values.
            2 => if (len > 0) {
                for (0..1 + random.uintLessThan(usize, 3)) |_| {
                    buffer[random.uintLessThan(usize, len)] = rlp_boundary_bytes[random.uintLessThan(usize, rlp_boundary_bytes.len)];
                }
            },
            // Concatenate a second seed into one stream.
            3 => {
                const second = fuzz_corpus[random.uintLessThan(usize, fuzz_corpus.len)];
                const extra = @min(second.len, buffer.len - len);
                @memcpy(buffer[len .. len + extra], second[0..extra]);
                len += extra;
            },
            // Append random bytes.
            4 => {
                const extra = @min(random.uintAtMost(usize, 64), buffer.len - len);
                random.bytes(buffer[len .. len + extra]);
                len += extra;
            },
            // Rewrite one of the first bytes: the outer length prefix.
            else => if (len > 0) {
                buffer[random.uintLessThan(usize, @min(len, 4))] = random.int(u8);
            },
        }
        try fuzzImportChainBytes({}, buffer[0..len]);
    }
}

test "KNOWN-BUG repro (skipped until patched): chain import must reject non-canonical RLP and oversized headers" {
    // chain_import.zig `itemSpan` / `parseRlpU64` accept encodings every
    // execution client rejects. The block hash is taken over the raw bytes,
    // so an accepted non-canonical header yields a block no peer agrees on.
    if (!known_bug_repros_enabled) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const tail_22_fields = prague_tail_lit ++ [_][]const u8{hash_lit};
    const rejected = comptime [_][]const u8{
        // Integer zero as the byte 0x00 instead of the empty string.
        blockLit(headerLit(.{ .number = &.{0x00} }), &empty_body_lit),
        // Single byte below 0x80 behind a length prefix.
        blockLit(headerLit(.{ .timestamp = &.{ 0x81, 0x2a } }), &empty_body_lit),
        // Long-form length for a payload shorter than 56 bytes.
        blockLit(headerLit(.{ .extra_data = &.{ 0xb8, 0x03, 'z', 'v', 'm' } }), &empty_body_lit),
        // Header with 22 fields; the last known fork defines 21.
        blockLit(headerLit(.{ .tail = &tail_22_fields }), &empty_body_lit),
    };
    for (rejected) |block| {
        const outcome = try importOnce(allocator, block, .{});
        try std.testing.expect(outcome.failure != null);
        try std.testing.expectEqual(@as(usize, 0), outcome.stored_blocks);
    }
}

test "fuzz: chain_import.importChainBytesWithOptions never panics, overflows or leaks on arbitrary RLP" {
    try fuzzImportChainBytes({}, &.{});
    try std.testing.fuzz({}, fuzzImportChainBytes, .{ .corpus = fuzz_corpus[1..] });
}
