//! EIP-7910 `eth_config`: current, next, and last fork configuration.

const std = @import("std");
const primitives = @import("primitives");
const block_builder = @import("../../block_builder.zig");
const hardfork_schedule = @import("../../hardfork_schedule.zig");

/// Mainnet deposit contract (EIP-6110).
pub const DEPOSIT_CONTRACT_ADDRESS = primitives.Address{ .bytes = .{
    0x00, 0x00, 0x00, 0x00, 0x21, 0x9a, 0xb5, 0x40, 0x35, 0x6c,
    0xbb, 0x83, 0x9c, 0xbe, 0x05, 0x30, 0x3d, 0x77, 0x05, 0xfa,
} };

pub const ChainInfo = struct {
    chain_id: u64,
    genesis_hash: [32]u8,
    genesis_timestamp: u64,
    head_block_number: u64,
    head_timestamp: u64,
};

const UNSCHEDULED = std.math.maxInt(u64);

const ForkEntry = struct {
    activation_time: u64,
    fork: primitives.Hardfork,
    blob_schedule: ?hardfork_schedule.BlobConfig,
};

/// Cancun, Prague, Osaka, then every EIP-7892 BPO entry.
const MAX_BLOB_FORKS = 3 + hardfork_schedule.MAX_BLOB_SCHEDULE_ENTRIES;

const NamedAddress = struct {
    name: []const u8,
    address: primitives.Address,
    since: primitives.Hardfork,
};

// Both tables are sorted by name: EIP-7910 requires alphabetically ordered keys.
const PRECOMPILES = [_]NamedAddress{
    .{ .name = "BLAKE2F", .address = primitives.Address.fromU256(0x09), .since = .ISTANBUL },
    .{ .name = "BLS12_G1ADD", .address = primitives.Address.fromU256(0x0b), .since = .PRAGUE },
    .{ .name = "BLS12_G1MSM", .address = primitives.Address.fromU256(0x0c), .since = .PRAGUE },
    .{ .name = "BLS12_G2ADD", .address = primitives.Address.fromU256(0x0d), .since = .PRAGUE },
    .{ .name = "BLS12_G2MSM", .address = primitives.Address.fromU256(0x0e), .since = .PRAGUE },
    .{ .name = "BLS12_MAP_FP2_TO_G2", .address = primitives.Address.fromU256(0x11), .since = .PRAGUE },
    .{ .name = "BLS12_MAP_FP_TO_G1", .address = primitives.Address.fromU256(0x10), .since = .PRAGUE },
    .{ .name = "BLS12_PAIRING_CHECK", .address = primitives.Address.fromU256(0x0f), .since = .PRAGUE },
    .{ .name = "BN254_ADD", .address = primitives.Address.fromU256(0x06), .since = .BYZANTIUM },
    .{ .name = "BN254_MUL", .address = primitives.Address.fromU256(0x07), .since = .BYZANTIUM },
    .{ .name = "BN254_PAIRING", .address = primitives.Address.fromU256(0x08), .since = .BYZANTIUM },
    .{ .name = "ECREC", .address = primitives.Address.fromU256(0x01), .since = .FRONTIER },
    .{ .name = "ID", .address = primitives.Address.fromU256(0x04), .since = .FRONTIER },
    .{ .name = "KZG_POINT_EVALUATION", .address = primitives.Address.fromU256(0x0a), .since = .CANCUN },
    .{ .name = "MODEXP", .address = primitives.Address.fromU256(0x05), .since = .BYZANTIUM },
    .{ .name = "P256VERIFY", .address = primitives.Address.fromU256(0x100), .since = .OSAKA },
    .{ .name = "RIPEMD160", .address = primitives.Address.fromU256(0x03), .since = .FRONTIER },
    .{ .name = "SHA256", .address = primitives.Address.fromU256(0x02), .since = .FRONTIER },
};

const SYSTEM_CONTRACTS = [_]NamedAddress{
    .{ .name = "BEACON_ROOTS_ADDRESS", .address = block_builder.BEACON_ROOTS_ADDRESS, .since = .CANCUN },
    .{ .name = "CONSOLIDATION_REQUEST_PREDEPLOY_ADDRESS", .address = block_builder.CONSOLIDATION_REQUESTS_ADDRESS, .since = .PRAGUE },
    .{ .name = "DEPOSIT_CONTRACT_ADDRESS", .address = DEPOSIT_CONTRACT_ADDRESS, .since = .PRAGUE },
    .{ .name = "HISTORY_STORAGE_ADDRESS", .address = block_builder.HISTORY_STORAGE_ADDRESS, .since = .PRAGUE },
    .{ .name = "WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS", .address = block_builder.WITHDRAWAL_REQUESTS_ADDRESS, .since = .PRAGUE },
};

/// Builds the `eth_config` result. The caller owns the returned value: every
/// string and object key is allocated with `allocator`.
pub fn ethConfigValue(
    allocator: std.mem.Allocator,
    config: hardfork_schedule.ChainConfig,
    info: ChainInfo,
) !std.json.Value {
    var entries_buf: [MAX_BLOB_FORKS]ForkEntry = undefined;
    const entries = scheduledBlobForks(config, &entries_buf);

    // Index of the first scheduled fork that is not active yet.
    var future_start: usize = 0;
    while (future_start < entries.len and entries[future_start].activation_time <= info.head_timestamp) future_start += 1;

    const current: ForkEntry = if (future_start > 0) entries[future_start - 1] else blk: {
        const fork = hardfork_schedule.resolveHardforkWithConfig(config, info.head_block_number, info.head_timestamp);
        break :blk .{
            .activation_time = if (fork.isAtLeast(.SHANGHAI)) config.shanghai_timestamp else 0,
            .fork = fork,
            .blob_schedule = null,
        };
    };
    const future = entries[future_start..];

    var obj = std.json.ObjectMap.init(allocator);
    errdefer {
        var value = std.json.Value{ .object = obj };
        deinitValue(allocator, &value);
    }
    try putOwned(&obj, allocator, "current", try forkConfigValue(allocator, config, info, current));
    try putOwned(&obj, allocator, "next", if (future.len > 0) try forkConfigValue(allocator, config, info, future[0]) else .null);
    try putOwned(&obj, allocator, "last", if (future.len > 0) try forkConfigValue(allocator, config, info, future[future.len - 1]) else .null);
    return .{ .object = obj };
}

/// EIP-6122 FORK_HASH after every fork active at `block_number` / `timestamp`.
pub fn forkHash(
    config: hardfork_schedule.ChainConfig,
    genesis_hash: [32]u8,
    genesis_timestamp: u64,
    block_number: u64,
    timestamp: u64,
) u32 {
    var crc = std.hash.Crc32.init();
    crc.update(&genesis_hash);

    // The merge was triggered by terminal total difficulty and is not part of the fork ID.
    const block_forks = [_]u64{
        config.homestead_block,      config.dao_block,          config.tangerine_whistle_block,
        config.spurious_dragon_block, config.byzantium_block,   config.constantinople_block,
        config.petersburg_block,     config.istanbul_block,     config.muir_glacier_block,
        config.berlin_block,         config.london_block,       config.arrow_glacier_block,
        config.gray_glacier_block,
    };
    var previous: u64 = 0;
    for (block_forks) |fork_block| {
        if (fork_block == UNSCHEDULED or fork_block <= previous or fork_block > block_number) continue;
        updateForkHash(&crc, fork_block);
        previous = fork_block;
    }

    const named_time_forks = [_]u64{
        config.shanghai_timestamp,
        config.cancun_timestamp,
        config.prague_timestamp,
        config.osaka_timestamp,
    };
    previous = genesis_timestamp;
    for (named_time_forks) |fork_time| {
        if (fork_time == UNSCHEDULED or fork_time <= previous or fork_time > timestamp) continue;
        updateForkHash(&crc, fork_time);
        previous = fork_time;
    }
    // EIP-7892 BPO forks apply only once Osaka is scheduled.
    if (config.osaka_timestamp != UNSCHEDULED) {
        for (config.blob_schedule.entries()) |entry| {
            const fork_time = entry.timestamp;
            if (fork_time == UNSCHEDULED or fork_time <= previous or fork_time > timestamp) continue;
            updateForkHash(&crc, fork_time);
            previous = fork_time;
        }
    }
    return crc.final();
}

fn updateForkHash(crc: *std.hash.Crc32, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .big);
    crc.update(&bytes);
}

/// Scheduled forks that carry a blob schedule, ordered by activation time.
fn scheduledBlobForks(config: hardfork_schedule.ChainConfig, buf: *[MAX_BLOB_FORKS]ForkEntry) []const ForkEntry {
    var candidates: [MAX_BLOB_FORKS]ForkEntry = undefined;
    candidates[0] = .{ .activation_time = config.cancun_timestamp, .fork = .CANCUN, .blob_schedule = config.cancun_blob_config };
    candidates[1] = .{ .activation_time = config.prague_timestamp, .fork = .PRAGUE, .blob_schedule = config.prague_blob_config };
    candidates[2] = .{ .activation_time = config.osaka_timestamp, .fork = .OSAKA, .blob_schedule = config.osaka_blob_config };
    var candidate_count: usize = 3;
    // BPO entries apply only once Osaka is active (EIP-7892).
    if (config.osaka_timestamp != UNSCHEDULED) {
        for (config.blob_schedule.entries()) |entry| {
            candidates[candidate_count] = .{
                .activation_time = @max(entry.timestamp, config.osaka_timestamp),
                .fork = .OSAKA,
                .blob_schedule = entry.config(),
            };
            candidate_count += 1;
        }
    }

    var count: usize = 0;
    for (candidates[0..candidate_count]) |candidate| {
        if (candidate.activation_time == UNSCHEDULED) continue;
        // A later fork at the same activation time supersedes the earlier one.
        if (count > 0 and buf[count - 1].activation_time >= candidate.activation_time) {
            buf[count - 1] = .{
                .activation_time = buf[count - 1].activation_time,
                .fork = candidate.fork,
                .blob_schedule = candidate.blob_schedule,
            };
            continue;
        }
        buf[count] = candidate;
        count += 1;
    }
    return buf[0..count];
}

fn forkConfigValue(
    allocator: std.mem.Allocator,
    config: hardfork_schedule.ChainConfig,
    info: ChainInfo,
    entry: ForkEntry,
) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    errdefer {
        var value = std.json.Value{ .object = obj };
        deinitValue(allocator, &value);
    }

    try putOwned(&obj, allocator, "activationTime", .{ .integer = std.math.cast(i64, entry.activation_time) orelse return error.InvalidForkConfig });
    try putOwned(&obj, allocator, "blobSchedule", if (entry.blob_schedule) |schedule| try blobScheduleValue(allocator, schedule) else .null);
    try putOwned(&obj, allocator, "chainId", .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{info.chain_id}) });
    const fork_hash = forkHash(
        config,
        info.genesis_hash,
        info.genesis_timestamp,
        info.head_block_number,
        @max(entry.activation_time, if (entry.blob_schedule == null) info.head_timestamp else 0),
    );
    try putOwned(&obj, allocator, "forkId", .{ .string = try std.fmt.allocPrint(allocator, "0x{x:0>8}", .{fork_hash}) });
    try putOwned(&obj, allocator, "precompiles", try addressTableValue(allocator, &PRECOMPILES, entry.fork));
    try putOwned(&obj, allocator, "systemContracts", try addressTableValue(allocator, &SYSTEM_CONTRACTS, entry.fork));
    return .{ .object = obj };
}

fn blobScheduleValue(allocator: std.mem.Allocator, schedule: hardfork_schedule.BlobConfig) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    errdefer {
        var value = std.json.Value{ .object = obj };
        deinitValue(allocator, &value);
    }
    try putOwned(&obj, allocator, "baseFeeUpdateFraction", .{ .integer = @intCast(schedule.base_fee_update_fraction) });
    try putOwned(&obj, allocator, "max", .{ .integer = @intCast(schedule.max) });
    try putOwned(&obj, allocator, "target", .{ .integer = @intCast(schedule.target) });
    return .{ .object = obj };
}

fn addressTableValue(allocator: std.mem.Allocator, table: []const NamedAddress, fork: primitives.Hardfork) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    errdefer {
        var value = std.json.Value{ .object = obj };
        deinitValue(allocator, &value);
    }
    for (table) |item| {
        if (!fork.isAtLeast(item.since)) continue;
        const hex = std.fmt.bytesToHex(item.address.bytes, .lower);
        try putOwned(&obj, allocator, item.name, .{ .string = try std.fmt.allocPrint(allocator, "0x{s}", .{&hex}) });
    }
    return .{ .object = obj };
}

/// Takes ownership of `value`; frees it when the insert fails.
fn putOwned(obj: *std.json.ObjectMap, allocator: std.mem.Allocator, key: []const u8, value: std.json.Value) !void {
    errdefer {
        var orphaned = value;
        deinitValue(allocator, &orphaned);
    }
    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    try obj.put(owned_key, value);
}

pub fn deinitValue(allocator: std.mem.Allocator, value: *std.json.Value) void {
    switch (value.*) {
        .string => |text| allocator.free(text),
        .object => |*object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                deinitValue(allocator, entry.value_ptr);
            }
            object.deinit();
        },
        else => {},
    }
}

const MAINNET_GENESIS_HASH = [32]u8{
    0xd4, 0xe5, 0x67, 0x40, 0xf8, 0x76, 0xae, 0xf8, 0xc0, 0x10, 0xb8, 0x6a, 0x40, 0xd5, 0xf5, 0x67,
    0x45, 0xa1, 0x18, 0xd0, 0x90, 0x6a, 0x34, 0xe6, 0x9a, 0xec, 0x8c, 0x0d, 0xb1, 0xcb, 0x8f, 0xa3,
};

fn mainnetInfo(head_timestamp: u64) ChainInfo {
    return .{
        .chain_id = 1,
        .genesis_hash = MAINNET_GENESIS_HASH,
        .genesis_timestamp = 0,
        .head_block_number = 23_000_000,
        .head_timestamp = head_timestamp,
    };
}

test "forkHash matches known mainnet EIP-6122 fork hashes" {
    const config = hardfork_schedule.MAINNET_CHAIN_CONFIG;
    try std.testing.expectEqual(@as(u32, 0xfc64ec04), forkHash(config, MAINNET_GENESIS_HASH, 0, 0, 0));
    try std.testing.expectEqual(@as(u32, 0xdce96c2d), forkHash(config, MAINNET_GENESIS_HASH, 0, 17_000_000, config.shanghai_timestamp));
    try std.testing.expectEqual(@as(u32, 0x9f3d2254), forkHash(config, MAINNET_GENESIS_HASH, 0, 19_500_000, config.cancun_timestamp));
    try std.testing.expectEqual(@as(u32, 0xc376cf8b), forkHash(config, MAINNET_GENESIS_HASH, 0, 22_500_000, config.prague_timestamp));
}

test "ethConfigValue returns the canonical Osaka schema on mainnet" {
    const allocator = std.testing.allocator;
    const config = hardfork_schedule.MAINNET_CHAIN_CONFIG;
    var value = try ethConfigValue(allocator, config, mainnetInfo(config.osaka_timestamp));
    defer deinitValue(allocator, &value);

    const json = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(json);

    const current = value.object.get("current").?.object;
    try std.testing.expectEqual(@as(i64, 1_764_798_551), current.get("activationTime").?.integer);
    try std.testing.expectEqualStrings("0x1", current.get("chainId").?.string);
    try std.testing.expectEqual(@as(usize, 10), current.get("forkId").?.string.len);
    const schedule = current.get("blobSchedule").?.object;
    try std.testing.expectEqual(@as(i64, 5_007_716), schedule.get("baseFeeUpdateFraction").?.integer);
    try std.testing.expectEqual(@as(i64, 9), schedule.get("max").?.integer);
    try std.testing.expectEqual(@as(i64, 6), schedule.get("target").?.integer);
    try std.testing.expectEqualStrings(
        "0x0000000000000000000000000000000000000100",
        current.get("precompiles").?.object.get("P256VERIFY").?.string,
    );
    try std.testing.expectEqual(@as(usize, 18), current.get("precompiles").?.object.count());
    try std.testing.expectEqualStrings(
        "0x000f3df6d732807ef1319fb7b8bb8522d0beac02",
        current.get("systemContracts").?.object.get("BEACON_ROOTS_ADDRESS").?.string,
    );
    try std.testing.expectEqual(@as(usize, 5), current.get("systemContracts").?.object.count());

    // Mainnet schedules BPO1 and BPO2 after Osaka (EIP-7892).
    const next = value.object.get("next").?.object;
    try std.testing.expectEqual(@as(i64, 1_765_290_071), next.get("activationTime").?.integer);
    try std.testing.expectEqual(@as(i64, 15), next.get("blobSchedule").?.object.get("max").?.integer);
    const last = value.object.get("last").?.object;
    try std.testing.expectEqual(@as(i64, 1_767_747_671), last.get("activationTime").?.integer);
    try std.testing.expectEqual(@as(i64, 21), last.get("blobSchedule").?.object.get("max").?.integer);
    try std.testing.expect(!std.mem.eql(u8, current.get("forkId").?.string, next.get("forkId").?.string));

    // Keys serialize in alphabetical order.
    try std.testing.expect(std.mem.startsWith(u8, json, "{\"current\":{\"activationTime\":1764798551,\"blobSchedule\":{\"baseFeeUpdateFraction\":5007716,\"max\":9,\"target\":6},\"chainId\":\"0x1\",\"forkId\":\"0x"));
}

test "ethConfigValue returns null next and last when no fork is scheduled" {
    const allocator = std.testing.allocator;
    const config = hardfork_schedule.MAINNET_CHAIN_CONFIG;
    var value = try ethConfigValue(allocator, config, mainnetInfo(hardfork_schedule.MAINNET_BPO2.timestamp));
    defer deinitValue(allocator, &value);

    try std.testing.expectEqual(@as(i64, 21), value.object.get("current").?.object.get("blobSchedule").?.object.get("max").?.integer);
    try std.testing.expect(value.object.get("next").? == .null);
    try std.testing.expect(value.object.get("last").? == .null);
}

test "ethConfigValue omits Prague and Osaka entries before those forks" {
    const allocator = std.testing.allocator;
    const config = hardfork_schedule.MAINNET_CHAIN_CONFIG;
    var value = try ethConfigValue(allocator, config, mainnetInfo(config.cancun_timestamp));
    defer deinitValue(allocator, &value);

    const current = value.object.get("current").?.object;
    try std.testing.expectEqualStrings("0x9f3d2254", current.get("forkId").?.string);
    try std.testing.expect(current.get("precompiles").?.object.get("P256VERIFY") == null);
    try std.testing.expect(current.get("precompiles").?.object.get("BLS12_G1ADD") == null);
    try std.testing.expectEqual(@as(usize, 1), current.get("systemContracts").?.object.count());
    try std.testing.expectEqualStrings("0xc376cf8b", value.object.get("next").?.object.get("forkId").?.string);
}
