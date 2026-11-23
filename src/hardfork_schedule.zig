const std = @import("std");
const primitives = @import("primitives");

/// EIP-4844 blob gas consumed by one blob (2^17).
pub const GAS_PER_BLOB: u64 = 131_072;

/// Upper bound on EIP-7892 BPO entries per chain. Stored inline in
/// `BlobSchedule` so `ChainConfig` stays a plain value type with zero heap
/// allocations and no ownership/lifetime hazards when copied by value.
pub const MAX_BLOB_SCHEDULE_ENTRIES: usize = 32;

/// Largest `max` blob count whose `max * GAS_PER_BLOB` still fits in a u64.
pub const MAX_BLOBS_PER_BLOCK_LIMIT: u64 = std.math.maxInt(u64) / GAS_PER_BLOB;

/// Blob parameters of a named fork (EIP-7840 `blobSchedule` entry). A named
/// fork's parameters activate with the fork itself, so they carry no timestamp.
pub const BlobConfig = struct {
    target: u64,
    max: u64,
    base_fee_update_fraction: u64,
};

/// EIP-7892 Blob Parameter Only (BPO) fork: a timestamp-activated change of
/// the blob target, max, and base fee update fraction. BPO entries apply only
/// once Osaka is active.
pub const BlobScheduleEntry = struct {
    timestamp: u64,
    target: u64,
    max: u64,
    base_fee_update_fraction: u64,

    pub fn config(self: BlobScheduleEntry) BlobConfig {
        return .{
            .target = self.target,
            .max = self.max,
            .base_fee_update_fraction = self.base_fee_update_fraction,
        };
    }
};

pub const BlobScheduleError = error{
    TooManyBlobScheduleEntries,
    UnorderedBlobSchedule,
    InvalidBlobScheduleEntry,
};

/// Fixed-capacity, strictly ordered list of EIP-7892 BPO entries stored inline
/// in `ChainConfig`. Value-copying `ChainConfig` across node, RPC, mining, and
/// block builder never allocates or produces dangling slices.
pub const BlobSchedule = struct {
    buffer: [MAX_BLOB_SCHEDULE_ENTRIES]BlobScheduleEntry = [_]BlobScheduleEntry{.{
        .timestamp = 0,
        .target = 0,
        .max = 0,
        .base_fee_update_fraction = 0,
    }} ** MAX_BLOB_SCHEDULE_ENTRIES,
    len: usize = 0,

    pub const empty = BlobSchedule{};

    /// Builds a validated schedule from `items`, requiring strictly increasing
    /// timestamps and valid parameters (`validateBlobConfig`).
    pub fn init(items: []const BlobScheduleEntry) BlobScheduleError!BlobSchedule {
        if (items.len > MAX_BLOB_SCHEDULE_ENTRIES) return error.TooManyBlobScheduleEntries;
        var schedule = BlobSchedule{};
        for (items, 0..) |item, index| {
            try validateBlobConfig(item.config());
            if (index > 0 and item.timestamp <= items[index - 1].timestamp) return error.UnorderedBlobSchedule;
            schedule.buffer[index] = item;
        }
        schedule.len = items.len;
        return schedule;
    }

    pub fn entries(self: *const BlobSchedule) []const BlobScheduleEntry {
        return self.buffer[0..self.len];
    }
};

/// Rejects parameters that make blob fee math undefined: `max == 0` divides by
/// zero in EIP-7918, `base_fee_update_fraction == 0` divides by zero in
/// `fake_exponential`, `target > max` makes the reserve increment negative,
/// and `max * GAS_PER_BLOB` must fit in a u64 header field.
pub fn validateBlobConfig(config: BlobConfig) BlobScheduleError!void {
    if (config.max == 0) return error.InvalidBlobScheduleEntry;
    if (config.target > config.max) return error.InvalidBlobScheduleEntry;
    if (config.max > MAX_BLOBS_PER_BLOCK_LIMIT) return error.InvalidBlobScheduleEntry;
    if (config.base_fee_update_fraction == 0) return error.InvalidBlobScheduleEntry;
}

/// Ethereum mainnet blob parameters (EIP-4844, EIP-7691, EIP-7892).
pub const MAINNET_CANCUN_BLOB_CONFIG = BlobConfig{ .target = 3, .max = 6, .base_fee_update_fraction = 3_338_477 };
pub const MAINNET_PRAGUE_BLOB_CONFIG = BlobConfig{ .target = 6, .max = 9, .base_fee_update_fraction = 5_007_716 };
pub const MAINNET_OSAKA_BLOB_CONFIG = BlobConfig{ .target = 6, .max = 9, .base_fee_update_fraction = 5_007_716 };
/// Mainnet BPO1 (2025-12-09): target 10, max 15, update fraction 8_346_193.
pub const MAINNET_BPO1 = BlobScheduleEntry{ .timestamp = 1_765_290_071, .target = 10, .max = 15, .base_fee_update_fraction = 8_346_193 };
/// Mainnet BPO2 (2026-01-07): target 14, max 21, update fraction 11_684_671.
pub const MAINNET_BPO2 = BlobScheduleEntry{ .timestamp = 1_767_747_671, .target = 14, .max = 21, .base_fee_update_fraction = 11_684_671 };

pub const MAINNET_BLOB_SCHEDULE = BlobSchedule.init(&.{ MAINNET_BPO1, MAINNET_BPO2 }) catch unreachable;

pub const MAINNET_CHAIN_CONFIG = ChainConfig{};

pub const ChainConfig = struct {
    homestead_block: u64 = 1_150_000,
    dao_block: u64 = 1_920_000,
    tangerine_whistle_block: u64 = 2_463_000,
    spurious_dragon_block: u64 = 2_675_000,
    byzantium_block: u64 = 4_370_000,
    constantinople_block: u64 = 7_280_000,
    petersburg_block: u64 = 7_280_000,
    istanbul_block: u64 = 9_069_000,
    muir_glacier_block: u64 = 9_200_000,
    berlin_block: u64 = 12_244_000,
    london_block: u64 = 12_965_000,
    arrow_glacier_block: u64 = 13_773_000,
    gray_glacier_block: u64 = 15_050_000,
    merge_block: u64 = 15_537_394,
    shanghai_timestamp: u64 = 1_681_338_455,
    cancun_timestamp: u64 = 1_710_338_135,
    prague_timestamp: u64 = 1_746_612_311,
    osaka_timestamp: u64 = 1_764_798_551,
    seconds_per_slot: u64 = 12,
    cancun_blob_config: BlobConfig = MAINNET_CANCUN_BLOB_CONFIG,
    prague_blob_config: BlobConfig = MAINNET_PRAGUE_BLOB_CONFIG,
    osaka_blob_config: BlobConfig = MAINNET_OSAKA_BLOB_CONFIG,
    /// EIP-7892 BPO entries, consulted only once Osaka is active.
    blob_schedule: BlobSchedule = MAINNET_BLOB_SCHEDULE,
};

pub fn resolveHardfork(block_number: u64, timestamp: u64) primitives.Hardfork {
    return resolveHardforkWithConfig(MAINNET_CHAIN_CONFIG, block_number, timestamp);
}

pub fn resolveHardforkWithConfig(config: ChainConfig, block_number: u64, timestamp: u64) primitives.Hardfork {
    if (timestamp >= config.osaka_timestamp) return .OSAKA;
    if (timestamp >= config.prague_timestamp) return .PRAGUE;
    if (timestamp >= config.cancun_timestamp) return .CANCUN;
    if (timestamp >= config.shanghai_timestamp) return .SHANGHAI;
    if (block_number >= config.merge_block) return .MERGE;
    if (block_number >= config.gray_glacier_block) return .GRAY_GLACIER;
    if (block_number >= config.arrow_glacier_block) return .ARROW_GLACIER;
    if (block_number >= config.london_block) return .LONDON;
    if (block_number >= config.berlin_block) return .BERLIN;
    if (block_number >= config.muir_glacier_block) return .MUIR_GLACIER;
    if (block_number >= config.istanbul_block) return .ISTANBUL;
    if (block_number >= config.petersburg_block) return .PETERSBURG;
    if (block_number >= config.constantinople_block) return .CONSTANTINOPLE;
    if (block_number >= config.byzantium_block) return .BYZANTIUM;
    if (block_number >= config.spurious_dragon_block) return .SPURIOUS_DRAGON;
    if (block_number >= config.tangerine_whistle_block) return .TANGERINE_WHISTLE;
    if (block_number >= config.dao_block) return .DAO;
    if (block_number >= config.homestead_block) return .HOMESTEAD;
    return .FRONTIER;
}

test "mainnet blob schedule matches EIP-7892 BPO1 and BPO2" {
    const entries = MAINNET_CHAIN_CONFIG.blob_schedule.entries();
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(MAINNET_BPO1, entries[0]);
    try std.testing.expectEqual(MAINNET_BPO2, entries[1]);
    try std.testing.expect(entries[0].timestamp > MAINNET_CHAIN_CONFIG.osaka_timestamp);
}

test "BlobSchedule.init rejects unordered, duplicate, oversized, and invalid entries" {
    const a = BlobScheduleEntry{ .timestamp = 10, .target = 1, .max = 2, .base_fee_update_fraction = 1 };
    const b = BlobScheduleEntry{ .timestamp = 20, .target = 1, .max = 2, .base_fee_update_fraction = 1 };
    try std.testing.expectError(error.UnorderedBlobSchedule, BlobSchedule.init(&.{ b, a }));
    try std.testing.expectError(error.UnorderedBlobSchedule, BlobSchedule.init(&.{ a, a }));

    var too_many: [MAX_BLOB_SCHEDULE_ENTRIES + 1]BlobScheduleEntry = undefined;
    for (&too_many, 0..) |*entry, index| {
        entry.* = .{ .timestamp = index, .target = 1, .max = 1, .base_fee_update_fraction = 1 };
    }
    try std.testing.expectError(error.TooManyBlobScheduleEntries, BlobSchedule.init(&too_many));
    _ = try BlobSchedule.init(too_many[0..MAX_BLOB_SCHEDULE_ENTRIES]);

    var bad = a;
    bad.max = 0;
    bad.target = 0;
    try std.testing.expectError(error.InvalidBlobScheduleEntry, BlobSchedule.init(&.{bad}));
    bad = a;
    bad.target = 3;
    try std.testing.expectError(error.InvalidBlobScheduleEntry, BlobSchedule.init(&.{bad}));
    bad = a;
    bad.base_fee_update_fraction = 0;
    try std.testing.expectError(error.InvalidBlobScheduleEntry, BlobSchedule.init(&.{bad}));
    bad = a;
    bad.max = MAX_BLOBS_PER_BLOCK_LIMIT + 1;
    try std.testing.expectError(error.InvalidBlobScheduleEntry, BlobSchedule.init(&.{bad}));

    const ok = try BlobSchedule.init(&.{ a, b });
    try std.testing.expectEqual(@as(usize, 2), ok.entries().len);
}
