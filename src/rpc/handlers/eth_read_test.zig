const std = @import("std");
const jsonrpc = @import("jsonrpc");
const primitives = @import("primitives");
const eth_read = @import("eth_read.zig");
const runtime = @import("../../node/runtime.zig");
const genesis = @import("../../genesis.zig");
const blob_fee = @import("../../blob_fee.zig");
const hardfork_schedule = @import("../../hardfork_schedule.zig");
const tx_submission = @import("tx_submission.zig");

fn makeBlockSpec(tag: []const u8) jsonrpc.types.BlockSpec {
    return .{ .value = .{ .string = tag } };
}

// --- AC: eth_chainId returns configured chain ID ---

test "eth_chainId returns configured chain id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const result = try eth_read.handleEthChainId(arena.allocator(), &rt, .{});
    try expectQuantityStr(result.value, "0x7a69"); // 31337
}

test "eth_chainId returns custom chain id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{ .chain_id = 1 });
    defer rt.deinit();

    const result = try eth_read.handleEthChainId(arena.allocator(), &rt, .{});
    try expectQuantityStr(result.value, "0x1");
}

// --- AC: eth_blockNumber returns current head ---

test "eth_blockNumber returns current head number" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const result = try eth_read.handleEthBlockNumber(arena.allocator(), &rt, .{});
    try expectQuantityStr(result.value, "0x0");
}

test "eth_blockNumber reflects updated head" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();
    rt.head_block_number = 42;

    const result = try eth_read.handleEthBlockNumber(arena.allocator(), &rt, .{});
    try expectQuantityStr(result.value, "0x2a");
}

// --- AC: eth_getBalance reads from state manager ---

test "eth_getBalance returns dev account balance at latest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const result = try eth_read.handleEthGetBalance(
        arena.allocator(),
        &rt,
        .{
            .address = .{ .bytes = runtime.DEFAULT_DEV_ACCOUNTS[0].bytes },
            .block = makeBlockSpec("latest"),
        },
    );

    // 10000 ETH = 10000 * 1e18 = 0x21e19e0c9bab2400000
    try expectQuantityStr(result.value, "0x21e19e0c9bab2400000");
}

test "eth_getBalance returns 0 for unknown address" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const result = try eth_read.handleEthGetBalance(
        arena.allocator(),
        &rt,
        .{
            .address = .{ .bytes = [_]u8{0xde} ** 20 },
            .block = makeBlockSpec("latest"),
        },
    );
    try expectQuantityStr(result.value, "0x0");
}

test "state read handlers replay historical numeric selectors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();
    try rt.mineBlocks(1, 0);

    const address = jsonrpc.types.Address{ .bytes = runtime.DEFAULT_DEV_ACCOUNTS[0].bytes };
    const historical = makeBlockSpec("0x0");

    const balance = try eth_read.handleEthGetBalance(
        arena.allocator(),
        &rt,
        .{ .address = address, .block = historical },
    );
    try expectQuantityStr(balance.value, "0x21e19e0c9bab2400000");

    const code = try eth_read.handleEthGetCode(
        arena.allocator(),
        &rt,
        .{ .address = address, .block = historical },
    );
    try expectQuantityStr(code.value, "0x");

    const storage = try eth_read.handleEthGetStorageAt(
        arena.allocator(),
        &rt,
        .{
            .address = address,
            .storage_slot = .{ .value = .{ .string = "0x0" } },
            .block = historical,
        },
    );
    try expectQuantityStr(storage.value, "0x0000000000000000000000000000000000000000000000000000000000000000");

    const nonce = try eth_read.handleEthGetTransactionCount(
        arena.allocator(),
        &rt,
        .{ .address = address, .block = historical },
    );
    try expectQuantityStr(nonce.value, "0x0");
}

test "state read handlers accept current numeric selector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();
    try rt.mineBlocks(1, 0);

    const result = try eth_read.handleEthGetTransactionCount(
        arena.allocator(),
        &rt,
        .{
            .address = .{ .bytes = runtime.DEFAULT_DEV_ACCOUNTS[0].bytes },
            .block = makeBlockSpec("0x1"),
        },
    );
    try expectQuantityStr(result.value, "0x0");
}

// --- AC: eth_getTransactionCount reads nonce ---

test "eth_getTransactionCount returns 0 for fresh account" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const result = try eth_read.handleEthGetTransactionCount(
        arena.allocator(),
        &rt,
        .{
            .address = .{ .bytes = runtime.DEFAULT_DEV_ACCOUNTS[0].bytes },
            .block = makeBlockSpec("latest"),
        },
    );
    try expectQuantityStr(result.value, "0x0");
}

test "eth_getTransactionCount pending tag includes consecutive pool transactions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const sender = runtime.DEFAULT_DEV_ACCOUNTS[0];
    // committed state nonce is 0; pool has two consecutive pending txs (nonces 0, 1)
    // plus a non-consecutive queued tx (nonce 3) which must NOT advance the count.
    try rt.pool.setNonce(.{ .bytes = sender.bytes }, 0);
    try rt.pool.add(std.testing.allocator, .{
        .sender = .{ .bytes = sender.bytes },
        .nonce = 0,
        .gas_limit = 21_000,
        .max_fee_per_gas = 1_000_000_000,
        .hash = [_]u8{0x11} ** 32,
    });
    try rt.pool.add(std.testing.allocator, .{
        .sender = .{ .bytes = sender.bytes },
        .nonce = 1,
        .gas_limit = 21_000,
        .max_fee_per_gas = 1_000_000_000,
        .hash = [_]u8{0x22} ** 32,
    });
    try rt.pool.add(std.testing.allocator, .{
        .sender = .{ .bytes = sender.bytes },
        .nonce = 3,
        .gas_limit = 21_000,
        .max_fee_per_gas = 1_000_000_000,
        .hash = [_]u8{0x33} ** 32,
    });

    // "pending" must reflect the next usable nonce after the two consecutive txs.
    const pending = try eth_read.handleEthGetTransactionCount(
        arena.allocator(),
        &rt,
        .{
            .address = .{ .bytes = sender.bytes },
            .block = makeBlockSpec("pending"),
        },
    );
    try expectQuantityStr(pending.value, "0x2");

    // "latest" must still return only the committed state nonce.
    const latest = try eth_read.handleEthGetTransactionCount(
        arena.allocator(),
        &rt,
        .{
            .address = .{ .bytes = sender.bytes },
            .block = makeBlockSpec("latest"),
        },
    );
    try expectQuantityStr(latest.value, "0x0");
}

// --- AC: eth_coinbase returns coinbase address ---

test "eth_coinbase returns default coinbase" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const result = try eth_read.handleEthCoinbase(std.testing.allocator, &rt, .{});
    try std.testing.expectEqual(runtime.DEFAULT_DEV_ACCOUNTS[0].bytes, result.value.bytes);
}

// --- AC: eth_accounts returns managed dev accounts ---

test "eth_accounts returns 10 dev accounts" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const result = try eth_read.handleEthAccounts(std.testing.allocator, &rt, .{});
    defer std.testing.allocator.free(result.value);

    try std.testing.expectEqual(@as(usize, 10), result.value.len);
    try std.testing.expectEqual(runtime.DEFAULT_DEV_ACCOUNTS[0].bytes, result.value[0].bytes);
    try std.testing.expectEqual(runtime.DEFAULT_DEV_ACCOUNTS[9].bytes, result.value[9].bytes);
}

test "eth_accounts reads managed accounts from runtime" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();
    rt.managed_accounts[0] = genesis.DEV_ACCOUNTS[1];

    const result = try eth_read.handleEthAccounts(std.testing.allocator, &rt, .{});
    defer std.testing.allocator.free(result.value);

    try std.testing.expectEqual(genesis.DEV_ACCOUNTS[1].address.bytes, result.value[0].bytes);
}

// --- AC: eth_gasPrice returns valid hex quantity ---

test "eth_gasPrice returns default gas price" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const result = try eth_read.handleEthGasPrice(arena.allocator(), &rt, .{});
    // 2 gwei = 2_000_000_000 = 0x77359400
    try expectQuantityStr(result.value, "0x77359400");
}

// --- AC: eth_maxPriorityFeePerGas returns valid hex quantity ---

test "eth_maxPriorityFeePerGas returns default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const result = try eth_read.handleEthMaxPriorityFeePerGas(arena.allocator(), &rt, .{});
    // 1 gwei = 1_000_000_000 = 0x3b9aca00
    try expectQuantityStr(result.value, "0x3b9aca00");
}

// --- AC: eth_blobBaseFee returns valid hex quantity ---

test "eth_blobBaseFee returns default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const result = try eth_read.handleEthBlobBaseFee(arena.allocator(), &rt, .{});
    try expectQuantityStr(result.value, "0x1");
}

test "eth_blobBaseFee returns dev override" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    rt.dev_runtime.config.blob_base_fee = 7;
    const result = try eth_read.handleEthBlobBaseFee(arena.allocator(), &rt, .{});
    try expectQuantityStr(result.value, "0x7");
}

// --- AC: eth_feeHistory returns correctly shaped object ---

test "eth_feeHistory returns correct shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const result = try eth_read.handleEthFeeHistory(
        arena.allocator(),
        &rt,
        .{
            .block_count = .{ .value = .{ .string = "0x1" } },
            .newest_block = makeBlockSpec("latest"),
        },
    );

    // block_count=1 => base_fee_per_gas has 2 entries, gas_used_ratio has 1
    try std.testing.expectEqual(@as(usize, 2), result.base_fee_per_gas.len);
    try std.testing.expectEqual(@as(usize, 1), result.gas_used_ratio.len);
    try std.testing.expectEqual(@as(f64, 0.0), result.gas_used_ratio[0]);
}

test "eth_feeHistory uses mined block base fee history" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    rt.base_fee = 7;
    try rt.mineBlocks(1, 0);
    rt.base_fee = 11;
    try rt.mineBlocks(1, 0);

    const result = try eth_read.handleEthFeeHistory(
        arena.allocator(),
        &rt,
        .{
            .block_count = .{ .value = .{ .string = "0x2" } },
            .newest_block = makeBlockSpec("latest"),
        },
    );

    try std.testing.expectEqual(@as(usize, 3), result.base_fee_per_gas.len);
    try expectQuantityStr(result.base_fee_per_gas[0], "0x7");
    try expectQuantityStr(result.base_fee_per_gas[1], "0xb");
    try expectQuantityStr(result.base_fee_per_gas[2], "0xa");
    try std.testing.expectEqual(@as(usize, 3), result.base_fee_per_blob_gas.?.len);
    try std.testing.expectEqual(@as(usize, 2), result.blob_gas_used_ratio.?.len);
}

test "eth_feeHistory truncates large count and genesis range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();
    try rt.mineBlocks(3, 0);

    const result = try eth_read.handleEthFeeHistory(
        arena.allocator(),
        &rt,
        .{
            .block_count = .{ .value = .{ .string = "0x800" } },
            .newest_block = makeBlockSpec("latest"),
        },
    );

    try expectQuantityStr(result.oldest_block, "0x0");
    try std.testing.expectEqual(@as(usize, 5), result.base_fee_per_gas.len);
    try std.testing.expectEqual(@as(usize, 4), result.gas_used_ratio.len);
}

test "eth_feeHistory rejects missing numeric newest block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    try std.testing.expectError(error.InvalidParams, eth_read.handleEthFeeHistory(
        arena.allocator(),
        &rt,
        .{
            .block_count = .{ .value = .{ .string = "0x1" } },
            .newest_block = makeBlockSpec("0x999"),
        },
    ));
}

test "eth_feeHistory includes reward when empty percentiles are provided" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();
    try rt.mineBlocks(2, 0);

    const percentiles = [_]f64{};
    const result = try eth_read.handleEthFeeHistory(
        arena.allocator(),
        &rt,
        .{
            .block_count = .{ .value = .{ .string = "0x2" } },
            .newest_block = makeBlockSpec("latest"),
            .reward_percentiles = &percentiles,
        },
    );

    const reward = result.reward orelse return error.ExpectedReward;
    try std.testing.expectEqual(@as(usize, 2), reward.len);
    try std.testing.expectEqual(@as(usize, 0), reward[0].len);
    try std.testing.expectEqual(@as(usize, 0), reward[1].len);
}

test "eth_feeHistory validates reward percentiles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const descending = [_]f64{ 50.0, 10.0 };
    try std.testing.expectError(error.InvalidParams, eth_read.handleEthFeeHistory(
        arena.allocator(),
        &rt,
        .{
            .block_count = .{ .value = .{ .string = "0x1" } },
            .newest_block = makeBlockSpec("latest"),
            .reward_percentiles = &descending,
        },
    ));

    const too_many = [_]f64{0.0} ** (eth_read.MAX_REWARD_PERCENTILES + 1);
    try std.testing.expectError(error.InvalidParams, eth_read.handleEthFeeHistory(
        arena.allocator(),
        &rt,
        .{
            .block_count = .{ .value = .{ .string = "0x1" } },
            .newest_block = makeBlockSpec("latest"),
            .reward_percentiles = &too_many,
        },
    ));
}

// --- Helper ---

fn expectQuantityStr(q: jsonrpc.types.Quantity, expected: []const u8) !void {
    switch (q.value) {
        .string => |s| try std.testing.expectEqualStrings(expected, s),
        else => return error.ExpectedString,
    }
}

test "eth_blobBaseFee and eth_feeHistory reflect EIP-7892 BPO2 max and EIP-7918 reserve with non-trivial fees" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{
        .chain_id = 1,
        .hardfork_config = hardfork_schedule.MAINNET_CHAIN_CONFIG,
    });
    defer rt.deinit();

    // Canonical BPO2 block: 18 blobs used (of 21 max), 350 blobs excess, 1 gwei base fee.
    const parent = (try rt.blockchain.getBlockByNumber(0)).?;
    const bpo2_excess: u64 = 350 * blob_fee.GAS_PER_BLOB;
    const bpo2_used: u64 = 18 * blob_fee.GAS_PER_BLOB;
    const bpo2_ts = hardfork_schedule.MAINNET_BPO2.timestamp;
    const bpo2_fraction = hardfork_schedule.MAINNET_BPO2.base_fee_update_fraction;
    const header = primitives.BlockHeader.BlockHeader{
        .parent_hash = parent.hash,
        .ommers_hash = primitives.BlockHeader.EMPTY_OMMERS_HASH,
        .beneficiary = rt.coinbase,
        .state_root = parent.header.state_root,
        .transactions_root = primitives.BlockHeader.EMPTY_TRANSACTIONS_ROOT,
        .receipts_root = primitives.BlockHeader.EMPTY_RECEIPTS_ROOT,
        .logs_bloom = [_]u8{0} ** primitives.BlockHeader.BLOOM_SIZE,
        .difficulty = 0,
        .number = 1,
        .gas_limit = 30_000_000,
        .gas_used = 0,
        .timestamp = bpo2_ts,
        .base_fee_per_gas = 1_000_000_000,
        .withdrawals_root = primitives.BlockHeader.EMPTY_WITHDRAWALS_ROOT,
        .blob_gas_used = bpo2_used,
        .excess_blob_gas = bpo2_excess,
        .parent_beacon_block_root = primitives.Hash.ZERO,
    };
    const body = primitives.BlockBody.init();
    const block = try primitives.Block.from(&header, &body, std.testing.allocator);
    try rt.blockchain.putBlock(block);
    try rt.blockchain.setCanonicalHead(block.hash);
    rt.head_block_number = 1;
    rt.head_block_timestamp = bpo2_ts;
    rt.setNextBlockTimestamp(bpo2_ts + 12);

    // EIP-7918 next excess on BPO2: 350 + (18 * 7) / 21 = 356 blobs (vs 354 without reserve).
    const expected_next_fee = blob_fee.calcBlobBaseFee(356 * blob_fee.GAS_PER_BLOB, bpo2_fraction);
    const expected_block1_fee = blob_fee.calcBlobBaseFee(bpo2_excess, bpo2_fraction);
    const non_reserve_next_fee = blob_fee.calcBlobBaseFee(354 * blob_fee.GAS_PER_BLOB, bpo2_fraction);
    try std.testing.expect(expected_block1_fee > 1);
    try std.testing.expect(expected_next_fee > non_reserve_next_fee);
    try std.testing.expect(expected_next_fee > expected_block1_fee);

    const expected_next_hex = try std.fmt.allocPrint(arena.allocator(), "0x{x}", .{expected_next_fee});
    const expected_block1_hex = try std.fmt.allocPrint(arena.allocator(), "0x{x}", .{expected_block1_fee});

    const blob_fee_result = try eth_read.handleEthBlobBaseFee(arena.allocator(), &rt, .{});
    try expectQuantityStr(blob_fee_result.value, expected_next_hex);

    const history = try eth_read.handleEthFeeHistory(
        arena.allocator(),
        &rt,
        .{
            .block_count = .{ .value = .{ .string = "0x1" } },
            .newest_block = makeBlockSpec("latest"),
        },
    );
    try std.testing.expectEqual(@as(usize, 2), history.base_fee_per_blob_gas.?.len);
    try expectQuantityStr(history.base_fee_per_blob_gas.?[0], expected_block1_hex);
    try expectQuantityStr(history.base_fee_per_blob_gas.?[1], expected_next_hex);
    try std.testing.expectApproxEqAbs(@as(f64, 18.0 / 21.0), history.blob_gas_used_ratio.?[0], 1e-12);
}

fn sendLegacyTransfer(rt: *runtime.NodeRuntime, nonce_hex: []const u8, gas_price_hex: []const u8) !void {
    var obj = std.json.ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("from", .{ .string = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" });
    try obj.put("to", .{ .string = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" });
    try obj.put("nonce", .{ .string = nonce_hex });
    try obj.put("gasPrice", .{ .string = gas_price_hex });
    try obj.put("value", .{ .string = "0x1" });
    try obj.put("gas", .{ .string = "0x5208" });
    _ = try tx_submission.handleSendTransaction(std.testing.allocator, rt, .{
        .transaction = .{ .value = .{ .object = obj } },
    });
}

test "eth_feeHistory reports gas-weighted effective priority fee percentiles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();
    try rt.setMiningConfig(.manual);

    // Two 21000-gas transfers in one block. The first pays 5 gwei, the second
    // 3 gwei, so the block order differs from the reward order.
    try sendLegacyTransfer(&rt, "0x0", "0x12a05f200");
    try sendLegacyTransfer(&rt, "0x1", "0xb2d05e00");
    try rt.mineBlocks(1, 0);

    const head = rt.head_block_number;
    const block = (try rt.blockchain.getBlockByNumber(head)) orelse return error.MissingBlock;
    try std.testing.expectEqual(@as(usize, 2), block.body.transactions.len);
    const base_fee: u256 = block.header.base_fee_per_gas orelse 0;
    const low_reward: u256 = 3_000_000_000 - base_fee;
    const high_reward: u256 = 5_000_000_000 - base_fee;

    const percentiles = [_]f64{ 0, 50, 51, 100 };
    const result = try eth_read.handleEthFeeHistory(
        arena.allocator(),
        &rt,
        .{
            .block_count = .{ .value = .{ .string = "0x1" } },
            .newest_block = makeBlockSpec("latest"),
            .reward_percentiles = &percentiles,
        },
    );

    const reward = result.reward orelse return error.ExpectedReward;
    try std.testing.expectEqual(@as(usize, 1), reward.len);
    try std.testing.expectEqual(@as(usize, 4), reward[0].len);
    const low_hex = try std.fmt.allocPrint(arena.allocator(), "0x{x}", .{low_reward});
    const high_hex = try std.fmt.allocPrint(arena.allocator(), "0x{x}", .{high_reward});
    // Half the block's gas belongs to the cheaper transaction, so the 50th
    // percentile is still the low reward and the 51st is the high reward.
    try expectQuantityStr(reward[0][0], low_hex);
    try expectQuantityStr(reward[0][1], low_hex);
    try expectQuantityStr(reward[0][2], high_hex);
    try expectQuantityStr(reward[0][3], high_hex);

    // The JSON handler reports the same rewards.
    const value = try eth_read.handleEthFeeHistoryValue(
        arena.allocator(),
        &rt,
        .{
            .block_count = .{ .value = .{ .string = "0x1" } },
            .newest_block = makeBlockSpec("latest"),
            .reward_percentiles = &percentiles,
        },
    );
    const row = value.object.get("reward").?.array.items[0].array.items;
    try std.testing.expectEqualStrings(low_hex, row[0].string);
    try std.testing.expectEqualStrings(high_hex, row[3].string);
}

test "eth_feeHistory reports zero rewards for a block without transactions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();
    try rt.mineBlocks(1, 0);

    const percentiles = [_]f64{ 10, 90 };
    const result = try eth_read.handleEthFeeHistory(
        arena.allocator(),
        &rt,
        .{
            .block_count = .{ .value = .{ .string = "0x1" } },
            .newest_block = makeBlockSpec("latest"),
            .reward_percentiles = &percentiles,
        },
    );
    const reward = result.reward orelse return error.ExpectedReward;
    try expectQuantityStr(reward[0][0], "0x0");
    try expectQuantityStr(reward[0][1], "0x0");
}

test "eth_getProof rejects more than MAX_PROOF_KEYS storage keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const address = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
    inline for (.{ eth_read.MAX_PROOF_KEYS, eth_read.MAX_PROOF_KEYS + 1 }) |key_count| {
        var keys = std.json.Array.init(arena.allocator());
        for (0..key_count) |_| try keys.append(.{ .string = "0x0" });
        var params = std.json.Array.init(arena.allocator());
        try params.append(.{ .string = address });
        try params.append(.{ .array = keys });
        try params.append(.{ .string = "latest" });

        const result = eth_read.handleEthGetProofValue(arena.allocator(), &rt, .{ .array = params });
        if (key_count > eth_read.MAX_PROOF_KEYS) {
            try std.testing.expectError(error.InvalidParams, result);
        } else {
            const proof = try result;
            try std.testing.expectEqual(key_count, proof.object.get("storageProof").?.array.items.len);
        }
    }
}

// --- Round 2 regressions ---

fn blockHashSelector(
    allocator: std.mem.Allocator,
    hash: [32]u8,
    require_canonical: ?bool,
) !jsonrpc.types.BlockSpec {
    const hex = std.fmt.bytesToHex(hash, .lower);
    var object = std.json.ObjectMap.init(allocator);
    try object.put("blockHash", .{ .string = try std.fmt.allocPrint(allocator, "0x{s}", .{&hex}) });
    if (require_canonical) |flag| try object.put("requireCanonical", .{ .bool = flag });
    return .{ .value = .{ .object = object } };
}

test "state read by EIP-1898 blockHash does not serve canonical state for a non-canonical block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();
    try rt.mineBlocks(1, 0);

    // A sibling of canonical block 1: stored, but never made canonical.
    const canonical = (try rt.blockchain.getBlockByNumber(1)).?;
    var side_header = canonical.header;
    side_header.timestamp += 1;
    const body = primitives.BlockBody.init();
    const side = try primitives.Block.from(&side_header, &body, std.testing.allocator);
    try rt.blockchain.putBlock(side);
    try std.testing.expect(!std.mem.eql(u8, &side.hash, &canonical.hash));
    try std.testing.expectEqualSlices(u8, &canonical.hash, &rt.blockchain.getCanonicalHash(1).?);

    const address = jsonrpc.types.Address{ .bytes = runtime.DEFAULT_DEV_ACCOUNTS[0].bytes };

    try std.testing.expectError(error.BlockUnavailable, eth_read.handleEthGetBalance(
        arena.allocator(),
        &rt,
        .{ .address = address, .block = try blockHashSelector(arena.allocator(), side.hash, null) },
    ));
    try std.testing.expectError(error.BlockUnavailable, eth_read.handleEthGetTransactionCount(
        arena.allocator(),
        &rt,
        .{ .address = address, .block = try blockHashSelector(arena.allocator(), side.hash, false) },
    ));
    try std.testing.expectError(error.InvalidParams, eth_read.handleEthGetBalance(
        arena.allocator(),
        &rt,
        .{ .address = address, .block = try blockHashSelector(arena.allocator(), side.hash, true) },
    ));

    // The canonical block's own hash still resolves.
    const balance = try eth_read.handleEthGetBalance(
        arena.allocator(),
        &rt,
        .{ .address = address, .block = try blockHashSelector(arena.allocator(), canonical.hash, null) },
    );
    try expectQuantityStr(balance.value, "0x21e19e0c9bab2400000");
}
