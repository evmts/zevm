//! Blob gas accounting for EIP-4844, EIP-7691, EIP-7892 (BPO forks), and
//! EIP-7918 (blob base fee bounded by execution cost).
//!
//! All parameters for a block come from the *child* block's fork and
//! timestamp, matching go-ethereum `eip4844.CalcExcessBlobGas` and the
//! execution-specs fork modules: at a BPO transition the parent's blob base
//! fee used by the EIP-7918 reserve check is priced with the child's update
//! fraction.
//!
//! All functions are pure and allocation-free.
const std = @import("std");
const primitives = @import("primitives");
const hardfork_schedule = @import("hardfork_schedule.zig");

/// EIP-4844 blob gas per blob (2^17).
pub const GAS_PER_BLOB: u64 = hardfork_schedule.GAS_PER_BLOB;
/// EIP-7918 execution-cost floor per blob, in units of base fee (2^13).
pub const BLOB_BASE_COST: u64 = 8_192;
/// EIP-4844 minimum blob base fee in wei.
pub const MIN_BASE_FEE_PER_BLOB_GAS: u256 = 1;

pub const BlobConfig = hardfork_schedule.BlobConfig;
pub const BlobScheduleEntry = hardfork_schedule.BlobScheduleEntry;
pub const BlobSchedule = hardfork_schedule.BlobSchedule;
pub const MAINNET_BPO1 = hardfork_schedule.MAINNET_BPO1;
pub const MAINNET_BPO2 = hardfork_schedule.MAINNET_BPO2;

/// Blob parameters in force for one block. All fields are zero before
/// Cancun, which means "no blobs allowed and no blob fee".
pub const BlobParams = struct {
    target_blobs: u64,
    max_blobs: u64,
    target_blob_gas: u64,
    max_blob_gas: u64,
    base_fee_update_fraction: u64,

    pub const none = BlobParams{
        .target_blobs = 0,
        .max_blobs = 0,
        .target_blob_gas = 0,
        .max_blob_gas = 0,
        .base_fee_update_fraction = 0,
    };

    /// Callers pass a config checked by `hardfork_schedule.validateBlobConfig`;
    /// saturating multiplication keeps unvalidated inputs from wrapping.
    pub fn fromConfig(config: hardfork_schedule.BlobConfig) BlobParams {
        return .{
            .target_blobs = config.target,
            .max_blobs = config.max,
            .target_blob_gas = config.target *| GAS_PER_BLOB,
            .max_blob_gas = config.max *| GAS_PER_BLOB,
            .base_fee_update_fraction = config.base_fee_update_fraction,
        };
    }

    pub fn baseFee(self: BlobParams, excess_blob_gas: u64) u256 {
        if (self.max_blobs == 0) return 0;
        return calcBlobBaseFee(excess_blob_gas, self.base_fee_update_fraction);
    }
};

/// Blob parameters for a block of `fork` at `timestamp`. Cancun and Prague use
/// their named configs; Osaka and later start from `config.osaka_blob_config`
/// and apply the latest BPO entry with `entry.timestamp <= timestamp` (EIP-7892).
pub fn blobParamsForFork(
    config: hardfork_schedule.ChainConfig,
    fork: primitives.Hardfork,
    timestamp: u64,
) BlobParams {
    if (fork.isBefore(.CANCUN)) return BlobParams.none;
    if (fork.isBefore(.PRAGUE)) return BlobParams.fromConfig(config.cancun_blob_config);
    if (fork.isBefore(.OSAKA)) return BlobParams.fromConfig(config.prague_blob_config);

    var selected: ?hardfork_schedule.BlobScheduleEntry = null;
    for (config.blob_schedule.entries()) |entry| {
        if (entry.timestamp > timestamp) continue;
        if (selected == null or entry.timestamp >= selected.?.timestamp) {
            selected = entry;
        }
    }
    if (selected) |entry| return BlobParams.fromConfig(entry.config());
    return BlobParams.fromConfig(config.osaka_blob_config);
}

/// EIP-7892 `get_blob_schedule` for the block at (`block_number`, `timestamp`).
pub fn resolveBlobParams(config: hardfork_schedule.ChainConfig, block_number: u64, timestamp: u64) BlobParams {
    const fork = hardfork_schedule.resolveHardforkWithConfig(config, block_number, timestamp);
    return blobParamsForFork(config, fork, timestamp);
}

/// EIP-4844 `fake_exponential(factor, numerator, denominator)`.
///
/// Exact for every result that fits in a u256: intermediates stay below 2^384
/// because the loop stops as soon as the running sum proves `output / denom >= 2^256`,
/// returning `maxInt(u256)`. That early exit bounds iterations for adversarial
/// `numerator` values near `maxInt(u64)`. A zero `denominator` returns `maxInt(u256)`.
pub fn fakeExponential(factor: u256, numerator: u64, denominator: u64) u256 {
    if (denominator == 0) return std.math.maxInt(u256);

    const wide_denominator: u512 = denominator;
    // output / denominator >= 2^256  <=>  output >= 2^256 * denominator.
    const saturation_limit: u512 = (@as(u512, 1) << 256) * wide_denominator;

    var i: u512 = 1;
    var output: u512 = 0;
    var numerator_accumulated: u512 = @as(u512, factor) * wide_denominator;
    while (numerator_accumulated > 0) {
        output += numerator_accumulated;
        if (output >= saturation_limit) return std.math.maxInt(u256);
        numerator_accumulated = (numerator_accumulated * numerator) / (wide_denominator * i);
        i += 1;
    }
    return @intCast(output / wide_denominator);
}

/// EIP-4844 `get_base_fee_per_blob_gas` for a block with `excess_blob_gas`,
/// priced with that block's `base_fee_update_fraction`. Returns 0 when the
/// fraction is 0 (pre-Cancun `BlobParams.none`).
pub fn calcBlobBaseFee(excess_blob_gas: u64, base_fee_update_fraction: u64) u256 {
    if (base_fee_update_fraction == 0) return 0;
    return fakeExponential(MIN_BASE_FEE_PER_BLOB_GAS, excess_blob_gas, base_fee_update_fraction);
}

/// Blob base fee of the block at (`block_number`, `timestamp`) with header
/// field `excess_blob_gas`. Zero before Cancun.
pub fn blobBaseFeeAt(
    config: hardfork_schedule.ChainConfig,
    block_number: u64,
    timestamp: u64,
    excess_blob_gas: u64,
) u256 {
    return resolveBlobParams(config, block_number, timestamp).baseFee(excess_blob_gas);
}

/// EIP-7918 reserve check: true when the execution-cost floor
/// `BLOB_BASE_COST * base_fee` strictly exceeds the blob cost
/// `GAS_PER_BLOB * blob_fee`. Both products are evaluated in u512 so neither
/// can overflow for any u256 inputs, and a saturated `blob_base_fee`
/// (true value >= 2^256) still compares false because 2^17 * (2^256 - 1) > 2^13 * (2^256 - 1).
pub fn isBlobReservePriceActive(parent_base_fee_per_gas: u256, parent_blob_base_fee: u256) bool {
    const reserve_price = @as(u512, BLOB_BASE_COST) * @as(u512, parent_base_fee_per_gas);
    const blob_price = @as(u512, GAS_PER_BLOB) * @as(u512, parent_blob_base_fee);
    return reserve_price > blob_price;
}

/// Header `excess_blob_gas` of a child block.
///
/// `fork` and `blob_params` belong to the child. Pre-Osaka this is the
/// EIP-4844 rule; Osaka and later add the EIP-7918 reserve rule.
/// The zero target floor runs first; sums use u128 and saturate at `maxInt(u64)`.
pub fn calcExcessBlobGas(
    fork: primitives.Hardfork,
    blob_params: BlobParams,
    parent_excess_blob_gas: u64,
    parent_blob_gas_used: u64,
    parent_base_fee_per_gas: u256,
) u64 {
    if (fork.isBefore(.CANCUN)) return 0;

    const parent_blob_gas = @as(u128, parent_excess_blob_gas) + @as(u128, parent_blob_gas_used);
    if (parent_blob_gas < blob_params.target_blob_gas) return 0;

    if (fork.isAtLeast(.OSAKA) and blob_params.max_blobs != 0) {
        const parent_blob_base_fee = calcBlobBaseFee(parent_excess_blob_gas, blob_params.base_fee_update_fraction);
        if (isBlobReservePriceActive(parent_base_fee_per_gas, parent_blob_base_fee)) {
            const delta = blob_params.max_blobs -| blob_params.target_blobs;
            const scaled = (@as(u128, parent_blob_gas_used) * @as(u128, delta)) / @as(u128, blob_params.max_blobs);
            return saturateU64(@as(u128, parent_excess_blob_gas) + scaled);
        }
    }

    return saturateU64(parent_blob_gas - blob_params.target_blob_gas);
}

/// `excess_blob_gas` of the block at (`child_number`, `child_timestamp`) given
/// raw parent header fields. Missing parent fields count as zero.
pub fn nextExcessBlobGas(
    config: hardfork_schedule.ChainConfig,
    child_number: u64,
    child_timestamp: u64,
    parent_excess_blob_gas: ?u64,
    parent_blob_gas_used: ?u64,
    parent_base_fee_per_gas: ?u256,
) u64 {
    const fork = hardfork_schedule.resolveHardforkWithConfig(config, child_number, child_timestamp);
    return calcExcessBlobGas(
        fork,
        blobParamsForFork(config, fork, child_timestamp),
        parent_excess_blob_gas orelse 0,
        parent_blob_gas_used orelse 0,
        parent_base_fee_per_gas orelse 0,
    );
}

/// `excess_blob_gas` of the child of `parent_header` at (`child_number`, `child_timestamp`).
/// A parent from before Cancun contributes zero blob gas regardless of stray header fields.
pub fn nextExcessBlobGasForHeader(
    config: hardfork_schedule.ChainConfig,
    parent_header: primitives.BlockHeader.BlockHeader,
    child_number: u64,
    child_timestamp: u64,
) u64 {
    const child_fork = hardfork_schedule.resolveHardforkWithConfig(config, child_number, child_timestamp);
    if (child_fork.isBefore(.CANCUN)) return 0;

    const parent_fork = hardfork_schedule.resolveHardforkWithConfig(
        config,
        parent_header.number,
        parent_header.timestamp,
    );
    const parent_has_blobs = parent_fork.isAtLeast(.CANCUN);
    return calcExcessBlobGas(
        child_fork,
        blobParamsForFork(config, child_fork, child_timestamp),
        if (parent_has_blobs) parent_header.excess_blob_gas orelse 0 else 0,
        if (parent_has_blobs) parent_header.blob_gas_used orelse 0 else 0,
        parent_header.base_fee_per_gas orelse 0,
    );
}

fn saturateU64(value: u128) u64 {
    return std.math.cast(u64, value) orelse std.math.maxInt(u64);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn referenceFakeExponential(factor: u256, numerator: u64, denominator: u64) u256 {
    var i: u1024 = 1;
    var output: u1024 = 0;
    var acc: u1024 = @as(u1024, factor) * denominator;
    while (acc > 0) {
        output += acc;
        acc = (acc * numerator) / (@as(u1024, denominator) * i);
        i += 1;
    }
    return @intCast(output / denominator);
}

test "fakeExponential matches EIP-4844 geth TestFakeExponential reference vectors" {
    const Case = struct { factor: u256, numerator: u64, denominator: u64, want: u256 };
    const cases = [_]Case{
        .{ .factor = 1, .numerator = 0, .denominator = 1, .want = 1 },
        .{ .factor = 38493, .numerator = 0, .denominator = 1000, .want = 38493 },
        .{ .factor = 0, .numerator = 1234, .denominator = 2345, .want = 0 },
        .{ .factor = 1, .numerator = 2, .denominator = 1, .want = 6 },
        .{ .factor = 1, .numerator = 4, .denominator = 2, .want = 6 },
        .{ .factor = 1, .numerator = 3, .denominator = 1, .want = 16 },
        .{ .factor = 1, .numerator = 6, .denominator = 2, .want = 18 },
        .{ .factor = 1, .numerator = 4, .denominator = 1, .want = 49 },
        .{ .factor = 1, .numerator = 8, .denominator = 2, .want = 50 },
        .{ .factor = 10, .numerator = 8, .denominator = 2, .want = 542 },
        .{ .factor = 11, .numerator = 8, .denominator = 2, .want = 596 },
        .{ .factor = 1, .numerator = 5, .denominator = 1, .want = 136 },
        .{ .factor = 1, .numerator = 5, .denominator = 2, .want = 11 },
        .{ .factor = 2, .numerator = 5, .denominator = 2, .want = 23 },
        .{ .factor = 1, .numerator = 50_000_000, .denominator = 2_225_652, .want = 5_709_098_764 },
        .{ .factor = 1, .numerator = 380_928, .denominator = 3_338_477, .want = 1 },
        .{ .factor = 1, .numerator = 1_000, .denominator = 100, .want = 22_025 },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.want, fakeExponential(case.factor, case.numerator, case.denominator));
    }
}

test "fakeExponential agrees with 1024-bit reference across all four mainnet fractions" {
    const fractions = [_]u64{ 3_338_477, 5_007_716, 8_346_193, 11_684_671 };
    for (fractions) |fraction| {
        var excess: u64 = 0;
        while (excess < 170 * fraction) : (excess += fraction / 3 + 12_345) {
            try std.testing.expectEqual(referenceFakeExponential(1, excess, fraction), fakeExponential(1, excess, fraction));
        }
    }
}

test "fakeExponential saturates cleanly and terminates for adversarial inputs" {
    const max_u256: u256 = std.math.maxInt(u256);
    try std.testing.expectEqual(max_u256, fakeExponential(1, std.math.maxInt(u64), 1));
    try std.testing.expectEqual(max_u256, fakeExponential(1, std.math.maxInt(u64), 3_338_477));
    try std.testing.expectEqual(max_u256, fakeExponential(max_u256, 1, 1));
    try std.testing.expectEqual(max_u256, fakeExponential(1, 1, 0));
    try std.testing.expectEqual(max_u256, fakeExponential(max_u256, 0, std.math.maxInt(u64)));
    try std.testing.expectEqual(max_u256 - 1, fakeExponential(max_u256 - 1, 0, std.math.maxInt(u64)));
    // e^177 fits in u256; e^178 saturates (Cancun fraction).
    try std.testing.expect(fakeExponential(1, 177 * 3_338_477, 3_338_477) < max_u256);
    try std.testing.expectEqual(max_u256, fakeExponential(1, 178 * 3_338_477, 3_338_477));
}

test "isBlobReservePriceActive matches algebraic division form across u256 boundaries" {
    const max_u256: u256 = std.math.maxInt(u256);
    const boundary_blob_fee = max_u256 / 16;
    const samples = [_]struct { base_fee: u256, blob_fee: u256 }{
        .{ .base_fee = 0, .blob_fee = 0 },
        .{ .base_fee = 0, .blob_fee = 1 },
        .{ .base_fee = 1, .blob_fee = 0 },
        .{ .base_fee = 15, .blob_fee = 1 },
        .{ .base_fee = 16, .blob_fee = 1 },
        .{ .base_fee = 17, .blob_fee = 1 },
        .{ .base_fee = max_u256, .blob_fee = boundary_blob_fee },
        .{ .base_fee = max_u256, .blob_fee = boundary_blob_fee + 1 },
        .{ .base_fee = max_u256, .blob_fee = max_u256 },
    };
    for (samples) |s| {
        const algebraic = s.base_fee != 0 and (s.base_fee - 1) / (GAS_PER_BLOB / BLOB_BASE_COST) >= s.blob_fee;
        try std.testing.expectEqual(algebraic, isBlobReservePriceActive(s.base_fee, s.blob_fee));
    }
}

test "resolveBlobParams follows mainnet Cancun, Prague, Osaka, BPO1, and BPO2 schedule" {
    const merge = hardfork_schedule.MAINNET_CHAIN_CONFIG.merge_block;
    const Case = struct { timestamp: u64, target: u64, max: u64, fraction: u64 };
    const cases = [_]Case{
        .{ .timestamp = hardfork_schedule.MAINNET_CHAIN_CONFIG.shanghai_timestamp, .target = 0, .max = 0, .fraction = 0 },
        .{ .timestamp = hardfork_schedule.MAINNET_CHAIN_CONFIG.cancun_timestamp - 1, .target = 0, .max = 0, .fraction = 0 },
        .{ .timestamp = hardfork_schedule.MAINNET_CHAIN_CONFIG.cancun_timestamp, .target = 3, .max = 6, .fraction = 3_338_477 },
        .{ .timestamp = hardfork_schedule.MAINNET_CHAIN_CONFIG.prague_timestamp - 1, .target = 3, .max = 6, .fraction = 3_338_477 },
        .{ .timestamp = hardfork_schedule.MAINNET_CHAIN_CONFIG.prague_timestamp, .target = 6, .max = 9, .fraction = 5_007_716 },
        .{ .timestamp = hardfork_schedule.MAINNET_CHAIN_CONFIG.osaka_timestamp, .target = 6, .max = 9, .fraction = 5_007_716 },
        .{ .timestamp = 1_765_290_070, .target = 6, .max = 9, .fraction = 5_007_716 },
        .{ .timestamp = 1_765_290_071, .target = 10, .max = 15, .fraction = 8_346_193 },
        .{ .timestamp = 1_767_747_670, .target = 10, .max = 15, .fraction = 8_346_193 },
        .{ .timestamp = 1_767_747_671, .target = 14, .max = 21, .fraction = 11_684_671 },
        .{ .timestamp = std.math.maxInt(u64), .target = 14, .max = 21, .fraction = 11_684_671 },
    };
    for (cases) |case| {
        const params = resolveBlobParams(hardfork_schedule.MAINNET_CHAIN_CONFIG, merge, case.timestamp);
        try std.testing.expectEqual(case.target, params.target_blobs);
        try std.testing.expectEqual(case.max, params.max_blobs);
        try std.testing.expectEqual(case.target * GAS_PER_BLOB, params.target_blob_gas);
        try std.testing.expectEqual(case.max * GAS_PER_BLOB, params.max_blob_gas);
        try std.testing.expectEqual(case.fraction, params.base_fee_update_fraction);
    }
}

test "BPO entries never apply before Osaka" {
    var config = hardfork_schedule.MAINNET_CHAIN_CONFIG;
    config.osaka_timestamp = std.math.maxInt(u64);
    const params = resolveBlobParams(config, config.merge_block, hardfork_schedule.MAINNET_BPO2.timestamp + 100);
    try std.testing.expectEqual(@as(u64, 9), params.max_blobs);
    try std.testing.expectEqual(@as(u64, 5_007_716), params.base_fee_update_fraction);
}

test "custom BPO schedule and empty schedule" {
    var config = hardfork_schedule.MAINNET_CHAIN_CONFIG;
    config.osaka_timestamp = 100;
    config.blob_schedule = try hardfork_schedule.BlobSchedule.init(&.{
        .{ .timestamp = 200, .target = 1, .max = 2, .base_fee_update_fraction = 7 },
    });
    try std.testing.expectEqual(@as(u64, 9), resolveBlobParams(config, 0, 199).max_blobs);
    try std.testing.expectEqual(@as(u64, 2), resolveBlobParams(config, 0, 200).max_blobs);
    try std.testing.expectEqual(@as(u64, 7), resolveBlobParams(config, 0, 200).base_fee_update_fraction);

    config.blob_schedule = hardfork_schedule.BlobSchedule.empty;
    try std.testing.expectEqual(@as(u64, 9), resolveBlobParams(config, 0, std.math.maxInt(u64)).max_blobs);
}

test "calcExcessBlobGas EIP-7918 reserve boundaries, target floor, truncation, and huge fees" {
    const osaka = BlobParams.fromConfig(hardfork_schedule.MAINNET_OSAKA_BLOB_CONFIG);
    const cancun = BlobParams.fromConfig(hardfork_schedule.MAINNET_CANCUN_BLOB_CONFIG);
    const max_u256: u256 = std.math.maxInt(u256);
    const max_u64 = std.math.maxInt(u64);

    // Pre-Osaka ignores base fee.
    try std.testing.expectEqual(@as(u64, 0), calcExcessBlobGas(.SHANGHAI, cancun, 999, 999, max_u256));
    try std.testing.expectEqual(@as(u64, 0), calcExcessBlobGas(.PRAGUE, osaka, 0, osaka.target_blob_gas, 17));
    try std.testing.expectEqual(@as(u64, 1), calcExcessBlobGas(.PRAGUE, osaka, 0, osaka.target_blob_gas + 1, max_u256));

    // Target floor beats active reserve even at max_u256 base fee.
    try std.testing.expectEqual(@as(u64, 0), calcExcessBlobGas(.OSAKA, osaka, 0, osaka.target_blob_gas - 1, max_u256));

    // Strict inequality at boundary: base_fee == 16 is inactive, 17 is active.
    try std.testing.expectEqual(@as(u64, 0), calcExcessBlobGas(.OSAKA, osaka, 0, osaka.target_blob_gas, 16));
    try std.testing.expectEqual(@as(u64, 2 * GAS_PER_BLOB), calcExcessBlobGas(.OSAKA, osaka, 0, osaka.target_blob_gas, 17));
    try std.testing.expectEqual(GAS_PER_BLOB * 3, calcExcessBlobGas(.OSAKA, osaka, 0, osaka.max_blob_gas, 16));
    try std.testing.expectEqual(GAS_PER_BLOB * 3, calcExcessBlobGas(.OSAKA, osaka, 0, osaka.max_blob_gas, 17));
    try std.testing.expectEqual(osaka.target_blob_gas, calcExcessBlobGas(.OSAKA, osaka, osaka.target_blob_gas, 0, max_u256));
    try std.testing.expectEqual(@as(u64, 0), calcExcessBlobGas(.OSAKA, osaka, osaka.target_blob_gas, 0, 0));

    // Truncation: 1 * 3 / 9 == 0, 5 * 3 / 9 == 1.
    try std.testing.expectEqual(osaka.target_blob_gas, calcExcessBlobGas(.OSAKA, osaka, osaka.target_blob_gas, 1, max_u256));
    try std.testing.expectEqual(osaka.target_blob_gas + 1, calcExcessBlobGas(.OSAKA, osaka, osaka.target_blob_gas, 5, max_u256));

    // Huge fees where both 8192*base_fee and 131072*blob_fee exceed u256.
    const huge_excess: u64 = 850_000_000;
    const huge_fee = osaka.baseFee(huge_excess);
    try std.testing.expect(huge_fee > max_u256 / GAS_PER_BLOB);
    const equal_base_fee = huge_fee * 16;
    try std.testing.expectEqual(huge_excess - osaka.target_blob_gas, calcExcessBlobGas(.OSAKA, osaka, huge_excess, 0, equal_base_fee));
    try std.testing.expectEqual(huge_excess, calcExcessBlobGas(.OSAKA, osaka, huge_excess, 0, equal_base_fee + 1));

    // Saturated blob fee & u64 excess saturation without wrapping.
    try std.testing.expectEqual(max_u64 - osaka.target_blob_gas, calcExcessBlobGas(.OSAKA, osaka, max_u64 - osaka.target_blob_gas, osaka.target_blob_gas, max_u256));
    try std.testing.expectEqual(max_u64 - 1, calcExcessBlobGas(.CANCUN, cancun, max_u64, cancun.target_blob_gas - 1, 0));
    try std.testing.expectEqual(max_u64, calcExcessBlobGas(.OSAKA, osaka, max_u64, osaka.max_blob_gas, max_u256));
}

test "BPO transition uses child target, max, and update fraction for reserve pricing" {
    const bpo1 = hardfork_schedule.MAINNET_BPO1;
    const bpo2 = hardfork_schedule.MAINNET_BPO2;
    const merge = hardfork_schedule.MAINNET_CHAIN_CONFIG.merge_block;
    const used_15 = 15 * GAS_PER_BLOB;

    try std.testing.expectEqual(@as(u64, 9 * GAS_PER_BLOB), nextExcessBlobGas(hardfork_schedule.MAINNET_CHAIN_CONFIG, merge, bpo1.timestamp - 1, 0, used_15, 0));
    try std.testing.expectEqual(@as(u64, 5 * GAS_PER_BLOB), nextExcessBlobGas(hardfork_schedule.MAINNET_CHAIN_CONFIG, merge, bpo1.timestamp, 0, used_15, 0));
    try std.testing.expectEqual(@as(u64, 1 * GAS_PER_BLOB), nextExcessBlobGas(hardfork_schedule.MAINNET_CHAIN_CONFIG, merge, bpo2.timestamp, 0, used_15, 0));
    try std.testing.expectEqual(used_15 * 7 / 21, nextExcessBlobGas(hardfork_schedule.MAINNET_CHAIN_CONFIG, merge, bpo2.timestamp, 0, used_15, 1_000_000_000));

    // Excess where Osaka fraction vs BPO1 fraction straddle the reserve threshold.
    const excess: u64 = 30_000_000;
    const fee_osaka = calcBlobBaseFee(excess, 5_007_716);
    const fee_bpo1 = calcBlobBaseFee(excess, 8_346_193);
    try std.testing.expect(fee_bpo1 < fee_osaka);
    const base_fee = fee_bpo1 * 16 + 1;
    try std.testing.expect(isBlobReservePriceActive(base_fee, fee_bpo1));
    try std.testing.expect(!isBlobReservePriceActive(base_fee, fee_osaka));

    const used = 10 * GAS_PER_BLOB;
    try std.testing.expectEqual(
        excess + used * 5 / 15,
        nextExcessBlobGas(hardfork_schedule.MAINNET_CHAIN_CONFIG, merge, bpo1.timestamp, excess, used, base_fee),
    );
}

test "blobBaseFeeAt uses the block's own fraction and returns 0 pre-Cancun" {
    const excess: u64 = 20_000_000;
    const merge = hardfork_schedule.MAINNET_CHAIN_CONFIG.merge_block;
    try std.testing.expectEqual(calcBlobBaseFee(excess, 3_338_477), blobBaseFeeAt(hardfork_schedule.MAINNET_CHAIN_CONFIG, merge, hardfork_schedule.MAINNET_CHAIN_CONFIG.cancun_timestamp, excess));
    try std.testing.expectEqual(calcBlobBaseFee(excess, 5_007_716), blobBaseFeeAt(hardfork_schedule.MAINNET_CHAIN_CONFIG, merge, hardfork_schedule.MAINNET_CHAIN_CONFIG.prague_timestamp, excess));
    try std.testing.expectEqual(calcBlobBaseFee(excess, 11_684_671), blobBaseFeeAt(hardfork_schedule.MAINNET_CHAIN_CONFIG, merge, hardfork_schedule.MAINNET_BPO2.timestamp, excess));
    try std.testing.expectEqual(@as(u256, 0), blobBaseFeeAt(hardfork_schedule.MAINNET_CHAIN_CONFIG, merge, hardfork_schedule.MAINNET_CHAIN_CONFIG.shanghai_timestamp, excess));
}
