const std = @import("std");
const mining = @import("mining.zig");
const mining_coordinator = @import("mining_coordinator.zig");
const primitives = @import("primitives");

test "MiningConfig default is auto" {
    const config = mining.MiningConfig.default();
    try std.testing.expectEqual(mining.MiningConfigType.auto, std.meta.activeTag(config));
}

test "MiningConfig interval holds block time" {
    const config: mining.MiningConfig = .{ .interval = .{ .block_time = 15 } };
    try std.testing.expectEqual(mining.MiningConfigType.interval, std.meta.activeTag(config));
    switch (config) {
        .interval => |iv| try std.testing.expectEqual(@as(u64, 15), iv.block_time),
        else => return error.TestUnexpectedResult,
    }
}

test "MiningConfig manual variant" {
    const config: mining.MiningConfig = .manual;
    try std.testing.expectEqual(mining.MiningConfigType.manual, std.meta.activeTag(config));
}

test "MiningConfig interval with zero block time" {
    const config: mining.MiningConfig = .{ .interval = .{ .block_time = 0 } };
    switch (config) {
        .interval => |iv| try std.testing.expectEqual(@as(u64, 0), iv.block_time),
        else => return error.TestUnexpectedResult,
    }
}

test "resolveHardfork uses mainnet block and timestamp activations" {
    try std.testing.expectEqual(primitives.Hardfork.FRONTIER, mining_coordinator.resolveHardfork(0, 0));
    try std.testing.expectEqual(primitives.Hardfork.BERLIN, mining_coordinator.resolveHardfork(mining_coordinator.MAINNET_CHAIN_CONFIG.berlin_block, 0));
    try std.testing.expectEqual(primitives.Hardfork.LONDON, mining_coordinator.resolveHardfork(mining_coordinator.MAINNET_CHAIN_CONFIG.london_block, 0));
    try std.testing.expectEqual(primitives.Hardfork.MERGE, mining_coordinator.resolveHardfork(mining_coordinator.MAINNET_CHAIN_CONFIG.merge_block, 0));
    try std.testing.expectEqual(primitives.Hardfork.SHANGHAI, mining_coordinator.resolveHardfork(mining_coordinator.MAINNET_CHAIN_CONFIG.merge_block, mining_coordinator.MAINNET_CHAIN_CONFIG.shanghai_timestamp));
    try std.testing.expectEqual(primitives.Hardfork.CANCUN, mining_coordinator.resolveHardfork(mining_coordinator.MAINNET_CHAIN_CONFIG.merge_block, mining_coordinator.MAINNET_CHAIN_CONFIG.cancun_timestamp));
    try std.testing.expectEqual(primitives.Hardfork.PRAGUE, mining_coordinator.resolveHardfork(mining_coordinator.MAINNET_CHAIN_CONFIG.merge_block, mining_coordinator.MAINNET_CHAIN_CONFIG.prague_timestamp));
}

test "calculateNextBaseFee follows EIP-1559 target rules" {
    const parent_base_fee: u256 = 1_000_000_000;
    const gas_limit: u64 = 30_000_000;
    const target_gas: u64 = gas_limit / mining_coordinator.ELASTICITY_MULTIPLIER;

    try std.testing.expectEqual(parent_base_fee, mining_coordinator.calculateNextBaseFee(parent_base_fee, target_gas, gas_limit));
    try std.testing.expectEqual(@as(u256, 1_125_000_000), mining_coordinator.calculateNextBaseFee(parent_base_fee, gas_limit, gas_limit));
    try std.testing.expectEqual(@as(u256, 875_000_000), mining_coordinator.calculateNextBaseFee(parent_base_fee, 0, gas_limit));
    try std.testing.expectEqual(@as(u256, 8), mining_coordinator.calculateNextBaseFee(7, target_gas + 1, gas_limit));
}

test "nextBaseFee returns initial London fee at transition" {
    const parent_header = makeHeader(.{
        .number = mining_coordinator.MAINNET_CHAIN_CONFIG.london_block - 1,
        .gas_limit = 30_000_000,
        .gas_used = 30_000_000,
    });

    const expected = try mining_coordinator.nextBaseFee(parent_header, mining_coordinator.MAINNET_CHAIN_CONFIG.london_block, 0);
    try std.testing.expectEqual(@as(?u256, mining_coordinator.INITIAL_BASE_FEE), expected);
}

test "validateBaseFee accepts null or zero before London" {
    const parent_header = makeHeader(.{
        .number = mining_coordinator.MAINNET_CHAIN_CONFIG.london_block - 2,
    });
    const child_without_base_fee = makeHeader(.{
        .number = mining_coordinator.MAINNET_CHAIN_CONFIG.london_block - 1,
    });
    const child_with_zero_base_fee = makeHeader(.{
        .number = mining_coordinator.MAINNET_CHAIN_CONFIG.london_block - 1,
        .base_fee_per_gas = 0,
    });
    const child_with_nonzero_base_fee = makeHeader(.{
        .number = mining_coordinator.MAINNET_CHAIN_CONFIG.london_block - 1,
        .base_fee_per_gas = 1,
    });

    try mining_coordinator.validateBaseFee(parent_header, child_without_base_fee);
    try mining_coordinator.validateBaseFee(parent_header, child_with_zero_base_fee);
    try std.testing.expectError(mining_coordinator.HeaderValidationError.UnexpectedBaseFee, mining_coordinator.validateBaseFee(parent_header, child_with_nonzero_base_fee));
}

test "validateBaseFee rejects wrong post-London child fee" {
    const parent_header = makeHeader(.{
        .number = mining_coordinator.MAINNET_CHAIN_CONFIG.london_block,
        .gas_limit = 30_000_000,
        .gas_used = 30_000_000,
        .base_fee_per_gas = mining_coordinator.INITIAL_BASE_FEE,
    });
    const child_header = makeHeader(.{
        .number = mining_coordinator.MAINNET_CHAIN_CONFIG.london_block + 1,
        .gas_limit = 30_000_000,
        .base_fee_per_gas = mining_coordinator.INITIAL_BASE_FEE,
    });

    try std.testing.expectError(mining_coordinator.HeaderValidationError.InvalidBaseFee, mining_coordinator.validateBaseFee(parent_header, child_header));
}

test "nextExcessBlobGas uses Prague target on the transition child" {
    const parent_header = makeHeader(.{
        .number = 22_431_083,
        .timestamp = mining_coordinator.MAINNET_CHAIN_CONFIG.prague_timestamp - mining_coordinator.MAINNET_CHAIN_CONFIG.seconds_per_slot,
        .blob_gas_used = mining_coordinator.PRAGUE_TARGET_BLOB_GAS_PER_BLOCK,
        .excess_blob_gas = mining_coordinator.PRAGUE_TARGET_BLOB_GAS_PER_BLOCK,
    });

    try std.testing.expectEqual(
        @as(u64, mining_coordinator.PRAGUE_TARGET_BLOB_GAS_PER_BLOCK),
        mining_coordinator.nextExcessBlobGasForChild(
            parent_header,
            parent_header.number + 1,
            mining_coordinator.MAINNET_CHAIN_CONFIG.prague_timestamp,
        ),
    );
}

test "nextBlobBaseFee uses fork-specific update fractions" {
    try std.testing.expectEqual(@as(u256, 0), mining_coordinator.nextBlobBaseFee(0, .SHANGHAI));
    try std.testing.expectEqual(@as(u256, 1), mining_coordinator.nextBlobBaseFee(0, .CANCUN));
    try std.testing.expect(mining_coordinator.nextBlobBaseFee(
        10 * mining_coordinator.PRAGUE_TARGET_BLOB_GAS_PER_BLOCK,
        .PRAGUE,
    ) < mining_coordinator.nextBlobBaseFee(
        10 * mining_coordinator.PRAGUE_TARGET_BLOB_GAS_PER_BLOCK,
        .CANCUN,
    ));
}

test "validateBlobGas enforces Cancun fields and Prague max" {
    const parent_header = makeHeader(.{
        .number = 22_431_083,
        .timestamp = mining_coordinator.MAINNET_CHAIN_CONFIG.prague_timestamp - mining_coordinator.MAINNET_CHAIN_CONFIG.seconds_per_slot,
        .blob_gas_used = mining_coordinator.PRAGUE_TARGET_BLOB_GAS_PER_BLOCK,
        .excess_blob_gas = mining_coordinator.PRAGUE_TARGET_BLOB_GAS_PER_BLOCK,
    });
    const child_header = makeHeader(.{
        .number = 22_431_084,
        .timestamp = mining_coordinator.MAINNET_CHAIN_CONFIG.prague_timestamp,
        .blob_gas_used = mining_coordinator.PRAGUE_MAX_BLOB_GAS_PER_BLOCK + 1,
        .excess_blob_gas = mining_coordinator.PRAGUE_TARGET_BLOB_GAS_PER_BLOCK,
    });

    try std.testing.expectError(mining_coordinator.HeaderValidationError.BlobGasLimitExceeded, mining_coordinator.validateBlobGas(parent_header, child_header));
}

test "MiningCoordinator blockContext carries post-Paris prevrandao" {
    var coordinator = mining_coordinator.MiningCoordinator.init();
    defer coordinator.deinit(std.testing.allocator);

    coordinator.current_block_number = mining_coordinator.MAINNET_CHAIN_CONFIG.merge_block;
    coordinator.current_timestamp = mining_coordinator.MAINNET_CHAIN_CONFIG.prague_timestamp;

    const context = coordinator.blockContext(.{ .prevrandao = 0xabc });
    try std.testing.expectEqual(@as(u256, 0xabc), context.block_prevrandao);
}

test "MiningCoordinator blockContext computes base and blob fees" {
    var coordinator = mining_coordinator.MiningCoordinator.init();
    defer coordinator.deinit(std.testing.allocator);

    coordinator.current_block_number = mining_coordinator.MAINNET_CHAIN_CONFIG.london_block;
    coordinator.current_timestamp = 0;
    try std.testing.expectEqual(mining_coordinator.INITIAL_BASE_FEE, coordinator.blockContext(.{}).block_base_fee);

    coordinator.current_timestamp = mining_coordinator.MAINNET_CHAIN_CONFIG.cancun_timestamp;
    coordinator.current_excess_blob_gas = mining_coordinator.CANCUN_TARGET_BLOB_GAS_PER_BLOCK;
    try std.testing.expectEqual(
        mining_coordinator.nextBlobBaseFee(mining_coordinator.CANCUN_TARGET_BLOB_GAS_PER_BLOCK, .CANCUN),
        coordinator.blockContext(.{}).blob_base_fee,
    );
}

fn makeHeader(params: struct {
    number: u64,
    timestamp: u64 = 0,
    gas_limit: u64 = 30_000_000,
    gas_used: u64 = 0,
    base_fee_per_gas: ?u256 = null,
    blob_gas_used: ?u64 = null,
    excess_blob_gas: ?u64 = null,
}) primitives.BlockHeader.BlockHeader {
    return .{
        .number = params.number,
        .timestamp = params.timestamp,
        .gas_limit = params.gas_limit,
        .gas_used = params.gas_used,
        .base_fee_per_gas = params.base_fee_per_gas,
        .blob_gas_used = params.blob_gas_used,
        .excess_blob_gas = params.excess_blob_gas,
    };
}
