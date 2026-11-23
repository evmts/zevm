const std = @import("std");
const primitives = @import("primitives");
const state_manager = @import("state-manager");
const guillotine_mini = @import("guillotine_mini");
const block_builder = @import("block_builder.zig");
const genesis = @import("genesis.zig");
const hardfork_schedule = @import("hardfork_schedule.zig");
const tx_processor = @import("tx_processor.zig");
const host_adapter = @import("host_adapter.zig");
const dev_runtime = @import("rpc/dev_runtime.zig");

fn makeLegacyTx(params: struct {
    to: ?primitives.Address,
    value: u256,
    data: []const u8,
    gas_limit: u64,
    gas_price: u256,
    nonce: u64,
}) primitives.Transaction.LegacyTransaction {
    return .{
        .nonce = params.nonce,
        .gas_price = params.gas_price,
        .gas_limit = params.gas_limit,
        .to = params.to,
        .value = params.value,
        .data = params.data,
        .v = 0,
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
    };
}

fn blockContextWithGasLimit(limit: u64) guillotine_mini.BlockContext {
    return .{
        .chain_id = 1,
        .block_number = 1,
        .block_timestamp = 1000,
        .block_difficulty = 0,
        .block_prevrandao = 0,
        .block_coinbase = primitives.Address{ .bytes = [_]u8{0xCB} ++ [_]u8{0} ** 19 },
        .block_gas_limit = limit,
        .block_base_fee = 0,
        .blob_base_fee = 0,
    };
}

fn balanceProbeBytecode(address: primitives.Address) [23]u8 {
    var code: [23]u8 = undefined;
    code[0] = 0x73; // PUSH20
    @memcpy(code[1..21], &address.bytes);
    code[21] = 0x31; // BALANCE
    code[22] = 0x00; // STOP
    return code;
}

test "buildBlock enforces block gas limit" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var adapter = host_adapter.HostAdapter{ .state = &sm };
    const host = adapter.hostInterface();

    const sender = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 };
    const recipient = primitives.Address{ .bytes = [_]u8{0x02} ++ [_]u8{0} ** 19 };

    try sm.setBalance(sender, 1_000_000);
    try sm.setNonce(sender, 0);

    const txs = [_]tx_processor.ExecutionTx{
        .{
            .caller = sender,
            .tx = makeLegacyTx(.{
                .to = recipient,
                .value = 0,
                .data = &[_]u8{},
                .gas_limit = 21_000,
                .gas_price = 1,
                .nonce = 0,
            }),
        },
        .{
            .caller = sender,
            .tx = makeLegacyTx(.{
                .to = recipient,
                .value = 0,
                .data = &[_]u8{},
                .gas_limit = 21_000,
                .gas_price = 1,
                .nonce = 1,
            }),
        },
    };

    var result = try block_builder.buildBlock(
        std.testing.allocator,
        &sm,
        host,
        &txs,
        blockContextWithGasLimit(30_000),
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.receipts.len);
    try std.testing.expectEqual(@as(u32, 0), result.receipts[0].transaction_index);

    const gas_used_u64 = std.math.cast(u64, result.receipts[0].gas_used) orelse return error.GasOverflow;
    try std.testing.expectEqual(gas_used_u64, result.total_gas_used);

    const expected_state_root = try block_builder.computeStateRoot(std.testing.allocator, &sm);
    try std.testing.expectEqualSlices(u8, &expected_state_root, &result.state_root);
    try std.testing.expect(!std.mem.eql(u8, &result.state_root, &primitives.Hash.ZERO));
}

test "buildBlock enforces Cancun blob gas limit" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var adapter = host_adapter.HostAdapter{ .state = &sm };
    const host = adapter.hostInterface();

    const sender = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 };
    const recipient = primitives.Address{ .bytes = [_]u8{0x02} ++ [_]u8{0} ** 19 };

    try sm.setBalance(sender, 1_000_000_000);
    try sm.setNonce(sender, 0);

    var versioned_hashes: [7][32]u8 = undefined;
    var txs: [7]tx_processor.ExecutionTx = undefined;
    for (&txs, 0..) |*tx, i| {
        versioned_hashes[i] = [_]u8{@as(u8, @intCast(i + 1))} ** 32;
        versioned_hashes[i][0] = 0x01;
        tx.* = .{
            .caller = sender,
            .tx = makeLegacyTx(.{
                .to = recipient,
                .value = 0,
                .data = &[_]u8{},
                .gas_limit = 21_000,
                .gas_price = 1,
                .nonce = @intCast(i),
            }),
            .receipt_type = .eip4844,
            .max_fee_per_gas = 1,
            .max_priority_fee_per_gas = 0,
            .blob_gas_used = primitives.Blob.BLOB_GAS_PER_BLOB,
            .blob_gas_price = 0,
            .max_fee_per_blob_gas = 1,
            .blob_versioned_hashes = versioned_hashes[i .. i + 1],
        };
    }

    const withdrawals = [_]primitives.BlockBody.Withdrawal{};
    var result = try block_builder.buildBlockWithOptions(
        std.testing.allocator,
        &sm,
        host,
        &txs,
        blockContextWithGasLimit(1_000_000),
        .{
            .fork = .cancun,
            .hardfork_config = hardfork_schedule.ChainConfig{ .cancun_timestamp = 0 },
            .withdrawals = &withdrawals,
        },
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 6), result.receipts.len);
    try std.testing.expectEqual(@as(u64, 6 * primitives.Blob.BLOB_GAS_PER_BLOB), result.blob_gas_used);
    try std.testing.expectEqual(@as(usize, 6), result.included_tx_indexes.len);
    for (result.included_tx_indexes, 0..) |tx_index, expected| {
        try std.testing.expectEqual(expected, tx_index);
    }

    const expected_root = try block_builder.computeTransactionsRoot(std.testing.allocator, txs[0..6]);
    try std.testing.expectEqualSlices(u8, &expected_root, &result.transactions_root);
}

test "computeStateRoot matches premine trie root" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    const allocation = [_]genesis.PremineAccount{
        .{
            .address = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 },
            .balance = 1_000,
        },
        .{
            .address = primitives.Address{ .bytes = [_]u8{0x02} ++ [_]u8{0} ** 19 },
            .balance = 2_000,
            .nonce = 3,
        },
    };

    for (&allocation) |account| {
        try sm.initAccount(account.address, account.balance);
        if (account.nonce != 0) {
            try sm.setNonce(account.address, account.nonce);
        }
    }

    const expected = try genesis.computeStateRootFromPremine(std.testing.allocator, &allocation);
    const actual = try block_builder.computeStateRoot(std.testing.allocator, &sm);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "computeStateRoot preserves explicit empty accounts" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    const allocation = [_]genesis.PremineAccount{
        .{
            .address = primitives.Address{ .bytes = [_]u8{0x03} ++ [_]u8{0} ** 19 },
            .balance = 0,
            .nonce = 0,
        },
    };

    try sm.initAccount(allocation[0].address, allocation[0].balance);

    const expected = try genesis.computeStateRootFromPremine(std.testing.allocator, &allocation);
    const actual = try block_builder.computeStateRoot(std.testing.allocator, &sm);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "buildBlock rejects invalid included tx and reverts block state" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var adapter = host_adapter.HostAdapter{ .state = &sm };
    const host = adapter.hostInterface();

    const sender = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 };
    const recipient = primitives.Address{ .bytes = [_]u8{0x02} ++ [_]u8{0} ** 19 };

    try sm.setBalance(sender, 1_000_000);
    try sm.setNonce(sender, 0);

    const txs = [_]tx_processor.ExecutionTx{
        .{
            .caller = sender,
            .tx = makeLegacyTx(.{
                .to = recipient,
                .value = 0,
                .data = &[_]u8{},
                .gas_limit = 21_000,
                .gas_price = 1,
                .nonce = 0,
            }),
        },
        .{
            .caller = sender,
            .tx = makeLegacyTx(.{
                .to = recipient,
                .value = 0,
                .data = &[_]u8{},
                .gas_limit = 21_000,
                .gas_price = 1,
                .nonce = 3,
            }),
        },
    };

    try std.testing.expectError(error.InvalidIncludedTransaction, block_builder.buildBlock(
        std.testing.allocator,
        &sm,
        host,
        &txs,
        blockContextWithGasLimit(30_000_000),
    ));

    try std.testing.expectEqual(@as(u64, 0), try sm.getNonce(sender));
    try std.testing.expectEqual(@as(u256, 0), try sm.getBalance(recipient));
}

test "buildBlockWithOptions skips invalid txpool candidates when requested" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var adapter = host_adapter.HostAdapter{ .state = &sm };
    const host = adapter.hostInterface();

    const sender = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 };
    const recipient = primitives.Address{ .bytes = [_]u8{0x02} ++ [_]u8{0} ** 19 };

    try sm.setBalance(sender, 1_000_000);
    try sm.setNonce(sender, 0);

    const txs = [_]tx_processor.ExecutionTx{
        .{
            .caller = sender,
            .tx = makeLegacyTx(.{
                .to = recipient,
                .value = 0,
                .data = &[_]u8{},
                .gas_limit = 21_000,
                .gas_price = 1,
                .nonce = 0,
            }),
        },
        .{
            .caller = sender,
            .tx = makeLegacyTx(.{
                .to = recipient,
                .value = 0,
                .data = &[_]u8{},
                .gas_limit = 21_000,
                .gas_price = 2,
                .nonce = 0,
            }),
        },
    };

    var block_ctx = blockContextWithGasLimit(30_000_000);
    block_ctx.block_base_fee = 2;

    var result = try block_builder.buildBlockWithOptions(
        std.testing.allocator,
        &sm,
        host,
        &txs,
        block_ctx,
        .{
            .fork = .london,
            .hardfork_config = hardfork_schedule.ChainConfig{ .london_block = 0 },
            .skip_invalid_transactions = true,
        },
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.receipts.len);
    try std.testing.expectEqual(@as(usize, 1), result.included_tx_indexes.len);
    try std.testing.expectEqual(@as(usize, 1), result.included_tx_indexes[0]);
    try std.testing.expectEqual(@as(u64, 1), try sm.getNonce(sender));
}

test "buildBlock aborts and reverts when EVM host read records an error" {
    var fork_backend = try state_manager.ForkBackend.init(std.testing.allocator, "latest", .{});
    defer fork_backend.deinit();

    var sm = try state_manager.StateManager.init(std.testing.allocator, &fork_backend);
    defer sm.deinit();

    var adapter = host_adapter.HostAdapter{ .state = &sm };
    const host = adapter.hostInterface();

    const sender = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 };
    const contract = primitives.Address{ .bytes = [_]u8{0x02} ++ [_]u8{0} ** 19 };
    const remote = primitives.Address{ .bytes = [_]u8{0x99} ++ [_]u8{0} ** 19 };
    const code = balanceProbeBytecode(remote);

    try sm.initAccount(sender, 0);
    try sm.setCode(sender, &[_]u8{});
    try sm.setCode(contract, &code);

    const txs = [_]tx_processor.ExecutionTx{.{
        .caller = sender,
        .tx = makeLegacyTx(.{
            .to = contract,
            .value = 0,
            .data = &[_]u8{},
            .gas_limit = 100_000,
            .gas_price = 0,
            .nonce = 0,
        }),
    }};

    try std.testing.expectError(tx_processor.TxError.StateError, block_builder.buildBlock(
        std.testing.allocator,
        &sm,
        host,
        &txs,
        blockContextWithGasLimit(30_000_000),
    ));
    try std.testing.expectEqual(@as(?host_adapter.HostAdapter.HostError, null), adapter.getHostError());
    try std.testing.expectEqual(@as(u64, 0), try sm.getNonce(sender));
}

test "buildBlockWithOptions consumes dev block environment overrides once" {
    var runtime = dev_runtime.DevRuntime.init();
    defer runtime.deinit(std.testing.allocator);
    runtime.config.block_gas_limit = 21_000;
    runtime.config.next_block_base_fee_per_gas = 2;
    runtime.config.next_block_timestamp = 8193;
    runtime.config.blob_base_fee = 7;

    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var adapter = host_adapter.HostAdapter{ .state = &sm };
    const host = adapter.hostInterface();

    const sender = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 };
    const recipient = primitives.Address{ .bytes = [_]u8{0x02} ++ [_]u8{0} ** 19 };

    try sm.setBalance(sender, 1_000_000);
    try sm.setNonce(sender, 0);

    const txs = [_]tx_processor.ExecutionTx{
        .{
            .caller = sender,
            .tx = makeLegacyTx(.{
                .to = recipient,
                .value = 0,
                .data = &[_]u8{},
                .gas_limit = 21_000,
                .gas_price = 2,
                .nonce = 0,
            }),
        },
        .{
            .caller = sender,
            .tx = makeLegacyTx(.{
                .to = recipient,
                .value = 0,
                .data = &[_]u8{},
                .gas_limit = 21_000,
                .gas_price = 2,
                .nonce = 1,
            }),
        },
    };

    var block_ctx = blockContextWithGasLimit(42_000);
    block_ctx.block_base_fee = 3;
    block_ctx.blob_base_fee = 1;

    const withdrawals = [_]primitives.BlockBody.Withdrawal{};
    const parent_beacon_root = [_]u8{0x42} ** 32;
    var result = try block_builder.buildBlockWithOptions(
        std.testing.allocator,
        &sm,
        host,
        &txs,
        block_ctx,
        .{
            .fork = .cancun,
            .withdrawals = &withdrawals,
            .parent_beacon_block_root = parent_beacon_root,
            .dev_runtime = &runtime,
        },
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.receipts.len);
    try std.testing.expectEqual(@as(u64, 21_000), result.total_gas_used);
    try std.testing.expectEqual(@as(u256, 8193), try sm.getStorage(block_builder.BEACON_ROOTS_ADDRESS, 8193 % 8191));
    try std.testing.expect(runtime.config.next_block_base_fee_per_gas == null);
    try std.testing.expect(runtime.config.next_block_timestamp == null);
    try std.testing.expectEqual(@as(u64, 21_000), runtime.config.block_gas_limit);
    try std.testing.expectEqual(@as(u256, 7), runtime.config.blob_base_fee.?);
}

test "blockContextWithEnvironmentOverrides applies persistent blob base fee" {
    var runtime = dev_runtime.DevRuntime.init();
    defer runtime.deinit(std.testing.allocator);
    runtime.config.blob_base_fee = 9;

    var block_ctx = blockContextWithGasLimit(30_000_000);
    block_ctx.blob_base_fee = 1;

    const effective = block_builder.blockContextWithEnvironmentOverrides(&runtime, block_ctx);
    try std.testing.expectEqual(@as(u256, 9), effective.blob_base_fee);
    try std.testing.expectEqual(@as(u256, 9), runtime.config.blob_base_fee.?);
}

fn parentHeader() primitives.BlockHeader.BlockHeader {
    return .{
        .ommers_hash = primitives.BlockHeader.EMPTY_OMMERS_HASH,
        .transactions_root = primitives.BlockHeader.EMPTY_TRANSACTIONS_ROOT,
        .receipts_root = primitives.BlockHeader.EMPTY_RECEIPTS_ROOT,
        .difficulty = 0,
        .number = 10,
        .gas_limit = 30_000_000,
        .gas_used = 15_000_000,
        .timestamp = 1000,
        .base_fee_per_gas = 1_000_000_000,
    };
}

fn childHeader(parent: primitives.BlockHeader.BlockHeader) primitives.BlockHeader.BlockHeader {
    return .{
        .ommers_hash = primitives.BlockHeader.EMPTY_OMMERS_HASH,
        .transactions_root = primitives.BlockHeader.EMPTY_TRANSACTIONS_ROOT,
        .receipts_root = primitives.BlockHeader.EMPTY_RECEIPTS_ROOT,
        .difficulty = 0,
        .number = parent.number + 1,
        .gas_limit = parent.gas_limit,
        .gas_used = 0,
        .timestamp = parent.timestamp + 1,
        .base_fee_per_gas = 1_000_000_000,
    };
}

fn makeReceipt(params: struct {
    gas_used: u256 = 21_000,
    cumulative_gas_used: u256 = 21_000,
    logs_bloom: [256]u8 = [_]u8{0} ** 256,
    tx_type: primitives.Receipt.TransactionType = .legacy,
    blob_gas_used: ?u256 = null,
}) primitives.Receipt.Receipt {
    return .{
        .transaction_hash = [_]u8{0x11} ** 32,
        .transaction_index = 0,
        .block_hash = primitives.Hash.ZERO,
        .block_number = 1,
        .sender = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 },
        .to = primitives.Address{ .bytes = [_]u8{0x02} ++ [_]u8{0} ** 19 },
        .cumulative_gas_used = params.cumulative_gas_used,
        .gas_used = params.gas_used,
        .contract_address = null,
        .logs = &[_]primitives.EventLog.EventLog{},
        .logs_bloom = params.logs_bloom,
        .status = primitives.Receipt.TransactionStatus{ .success = true, .gas_used = params.gas_used },
        .root = null,
        .effective_gas_price = 1,
        .type = params.tx_type,
        .blob_gas_used = params.blob_gas_used,
        .blob_gas_price = null,
    };
}

test "validateHeader enforces V(H) post-Paris and London base fee" {
    var parent = parentHeader();
    var header = childHeader(parent);

    try block_builder.validateHeader(&header, &parent, .paris);

    header.gas_used = header.gas_limit + 1;
    try std.testing.expectError(error.HeaderGasUsedExceedsLimit, block_builder.validateHeader(&header, &parent, .paris));

    header = childHeader(parent);
    header.timestamp = parent.timestamp;
    try std.testing.expectError(error.InvalidTimestamp, block_builder.validateHeader(&header, &parent, .paris));

    header = childHeader(parent);
    header.difficulty = 1;
    try std.testing.expectError(error.InvalidPostParisDifficulty, block_builder.validateHeader(&header, &parent, .paris));

    header = childHeader(parent);
    header.base_fee_per_gas = 2;
    try std.testing.expectError(error.InvalidBaseFeePerGas, block_builder.validateHeader(&header, &parent, .paris));
}

test "withdrawals credit gwei amounts and produce empty root" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    const recipient = primitives.Address{ .bytes = [_]u8{0x77} ++ [_]u8{0} ** 19 };
    const withdrawals = [_]primitives.BlockBody.Withdrawal{
        .{
            .index = 1,
            .validator_index = 2,
            .address = recipient,
            .amount = 3,
        },
    };

    try block_builder.applyWithdrawals(&sm, &withdrawals);
    try std.testing.expectEqual(@as(u256, 3_000_000_000), try sm.getBalance(recipient));

    const empty_root = try block_builder.computeWithdrawalsRoot(std.testing.allocator, &[_]primitives.BlockBody.Withdrawal{});
    try std.testing.expectEqualSlices(u8, &primitives.BlockHeader.EMPTY_WITHDRAWALS_ROOT, &empty_root);
}

test "beacon roots system storage writes timestamp and root" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    const timestamp: u64 = 8193;
    const root = [_]u8{0x42} ** 32;
    try block_builder.applyBeaconRootsSystemCall(&sm, timestamp, root);

    const slot = timestamp % 8191;
    try std.testing.expectEqual(@as(u256, timestamp), try sm.getStorage(block_builder.BEACON_ROOTS_ADDRESS, slot));
    try std.testing.expectEqual(std.mem.readInt(u256, &root, .big), try sm.getStorage(block_builder.BEACON_ROOTS_ADDRESS, slot + 8191));
}

test "historical block hash system storage writes parent hash" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    const block_number: u64 = 8193;
    const parent_hash = [_]u8{0x34} ** 32;
    try block_builder.applyHistoricalBlockHashSystemCall(&sm, block_number, parent_hash);

    const slot = (block_number - 1) % 8191;
    try std.testing.expectEqual(
        std.mem.readInt(u256, &parent_hash, .big),
        try sm.getStorage(block_builder.HISTORY_STORAGE_ADDRESS, slot),
    );
}

test "validateBlock checks roots blooms withdrawals and blob gas" {
    const tx_raw = [_]u8{ 0x01, 0xc0 };
    const txs = [_]primitives.BlockBody.TransactionData{.{ .raw = &tx_raw }};
    var bloom: [256]u8 = [_]u8{0} ** 256;
    bloom[10] = 0xaa;
    const receipts = [_]primitives.Receipt.Receipt{makeReceipt(.{
        .logs_bloom = bloom,
        .tx_type = .eip2930,
        .blob_gas_used = 131_072,
    })};
    const withdrawals = [_]primitives.BlockBody.Withdrawal{};

    var parent = parentHeader();
    parent.withdrawals_root = primitives.BlockHeader.EMPTY_WITHDRAWALS_ROOT;
    parent.blob_gas_used = 0;
    parent.excess_blob_gas = 0;
    parent.parent_beacon_block_root = primitives.Hash.ZERO;

    var header = childHeader(parent);
    header.transactions_root = try block_builder.computeRawTransactionsRoot(std.testing.allocator, &txs);
    header.receipts_root = try block_builder.computeReceiptsRoot(std.testing.allocator, &receipts);
    header.logs_bloom = block_builder.aggregateLogsBloom(&receipts);
    header.gas_used = 21_000;
    header.withdrawals_root = try block_builder.computeWithdrawalsRoot(std.testing.allocator, &withdrawals);
    header.blob_gas_used = 131_072;
    header.excess_blob_gas = 0;
    header.parent_beacon_block_root = primitives.Hash.ZERO;

    _ = try block_builder.validateBlock(std.testing.allocator, .{
        .header = &header,
        .parent_header = &parent,
        .fork = .cancun,
        .transaction_envelopes = &txs,
        .receipts = &receipts,
        .withdrawals = &withdrawals,
    });

    header.blob_gas_used = 0;
    try std.testing.expectError(error.InvalidBlobGasUsed, block_builder.validateBlock(std.testing.allocator, .{
        .header = &header,
        .parent_header = &parent,
        .fork = .cancun,
        .transaction_envelopes = &txs,
        .receipts = &receipts,
        .withdrawals = &withdrawals,
    }));
}

test "requests hash skips empty request types" {
    const hash_a = block_builder.computeRequestsHash(.{ .deposits = "a", .consolidations = "c" });
    const hash_b = block_builder.computeRequestsHash(.{ .deposits = "a", .withdrawals = "", .consolidations = "c" });
    const hash_c = block_builder.computeRequestsHash(.{ .deposits = "a", .withdrawals = "b", .consolidations = "c" });

    try std.testing.expectEqualSlices(u8, &hash_a, &hash_b);
    try std.testing.expect(!std.mem.eql(u8, &hash_a, &hash_c));
}

test "EIP-7825 invalidates an included transaction even when it cannot fit the block" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();
    var adapter = host_adapter.HostAdapter{ .state = &sm };
    const sender = primitives.Address.fromU256(0x100);
    const recipient = primitives.Address.fromU256(0x200);
    try sm.setBalance(sender, 1_000_000_000);
    const transactions = [_]tx_processor.ExecutionTx{.{
        .caller = sender,
        .tx = makeLegacyTx(.{ .to = recipient, .value = 1, .data = &.{}, .gas_limit = 16_777_217, .gas_price = 1, .nonce = 0 }),
    }};
    for ([_]u64{ 21_000, 30_000_000 }) |block_gas_limit| {
        var context = blockContextWithGasLimit(block_gas_limit);
        context.block_timestamp = 1_764_798_551;
        try std.testing.expectError(error.InvalidIncludedTransaction, block_builder.buildBlock(
            std.testing.allocator,
            &sm,
            adapter.hostInterface(),
            &transactions,
            context,
        ));
        try std.testing.expectEqual(@as(u64, 0), try sm.getNonce(sender));
        try std.testing.expectEqual(@as(u256, 1_000_000_000), try sm.getBalance(sender));
        try std.testing.expectEqual(@as(u256, 0), try sm.getBalance(recipient));
    }
}

test "Osaka maps to its own block-builder fork with Prague blob limits" {
    try std.testing.expectEqual(block_builder.Hardfork.osaka, block_builder.hardforkFromEvm(.OSAKA));
    try std.testing.expectEqual(block_builder.Hardfork.prague, block_builder.hardforkFromEvm(.PRAGUE));
    try std.testing.expectEqual(block_builder.Hardfork.cancun, block_builder.hardforkFromEvm(.CANCUN));
    try std.testing.expect(@intFromEnum(block_builder.Hardfork.osaka) > @intFromEnum(block_builder.Hardfork.prague));
    try std.testing.expectEqual(block_builder.maxBlobGasPerBlock(.prague), block_builder.maxBlobGasPerBlock(.osaka));
    try std.testing.expectEqual(
        block_builder.calculateExcessBlobGasForFork(.prague, 900_000, 800_000),
        block_builder.calculateExcessBlobGasForFork(.osaka, 900_000, 800_000),
    );
    try std.testing.expectEqual(@as(?u256, null), block_builder.blockRewardWei(.osaka));
}

test "EIP-7934 size constants and fork gate" {
    try std.testing.expectEqual(@as(usize, 8_388_608), block_builder.MAX_RLP_BLOCK_SIZE);
    try std.testing.expectEqual(@as(usize, 10_485_760), block_builder.MAX_BLOCK_SIZE);
    try std.testing.expectEqual(@as(usize, 2_097_152), block_builder.BLOCK_SIZE_SAFETY_MARGIN);
    try std.testing.expectEqual(@as(u64, 60_000_000), block_builder.OSAKA_DEFAULT_BLOCK_GAS_LIMIT);

    try block_builder.validateBlockRlpSize(8_388_608, .osaka);
    try std.testing.expectError(error.BlockRlpSizeExceeded, block_builder.validateBlockRlpSize(8_388_609, .osaka));
    try block_builder.validateBlockRlpSize(8_388_609, .prague);
    try block_builder.validateBlockRlpSize(std.math.maxInt(usize), .cancun);
}

/// Test-only RLP list encoder over already encoded items.
fn testRlpList(allocator: std.mem.Allocator, items: []const []const u8) ![]u8 {
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

test "executionTxRlpSize equals the encoded transaction for every type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const to = primitives.Address.fromU256(0x200);
    const chain_id: u64 = 31337;
    // r keeps a leading zero byte so integer trimming is exercised.
    var r = [_]u8{0xaa} ** 32;
    r[0] = 0;
    const s = [_]u8{0x55} ** 32;
    const storage_keys = [_][32]u8{ [_]u8{1} ** 32, [_]u8{2} ** 32 };
    const access_list = [_]primitives.AccessList.AccessListEntry{
        .{ .address = to, .storage_keys = &storage_keys },
        .{ .address = primitives.Address.fromU256(0x300), .storage_keys = &.{} },
    };
    const blob_hashes = [_][32]u8{ [_]u8{0x01} ** 32, [_]u8{0x01} ** 32, [_]u8{0x01} ** 32 };
    const authorizations = [_]primitives.Authorization.Authorization{
        .{ .chain_id = chain_id, .address = to, .nonce = 300, .v = 1, .r = r, .s = s },
        .{ .chain_id = 0, .address = to, .nonce = 0, .v = 0, .r = s, .s = r },
    };

    const access_list_rlp = blk: {
        var entries: [access_list.len][]const u8 = undefined;
        for (access_list, 0..) |entry, i| {
            const keys = try a.alloc([]const u8, entry.storage_keys.len);
            for (entry.storage_keys, 0..) |key, k| keys[k] = try primitives.Rlp.encodeBytes(a, &key);
            entries[i] = try testRlpList(a, &.{
                try primitives.Rlp.encodeBytes(a, &entry.address.bytes),
                try testRlpList(a, keys),
            });
        }
        break :blk try testRlpList(a, &entries);
    };
    const blob_hashes_rlp = blk: {
        var items: [blob_hashes.len][]const u8 = undefined;
        for (blob_hashes, 0..) |hash, i| items[i] = try primitives.Rlp.encodeBytes(a, &hash);
        break :blk try testRlpList(a, &items);
    };
    const authorizations_rlp = blk: {
        var items: [authorizations.len][]const u8 = undefined;
        for (authorizations, 0..) |auth, i| {
            items[i] = try testRlpList(a, &.{
                try primitives.Rlp.encode(a, auth.chain_id),
                try primitives.Rlp.encodeBytes(a, &auth.address.bytes),
                try primitives.Rlp.encode(a, auth.nonce),
                try primitives.Rlp.encode(a, auth.v),
                try primitives.Rlp.encode(a, std.mem.readInt(u256, &auth.r, .big)),
                try primitives.Rlp.encode(a, std.mem.readInt(u256, &auth.s, .big)),
            });
        }
        break :blk try testRlpList(a, &items);
    };

    // Data lengths straddle every RLP string form: empty, a single byte below
    // and above 0x80, the 55/56 short/long boundary, and a two-byte length.
    const data_cases = [_][]const u8{
        &.{},
        &.{0x7f},
        &.{0x80},
        &([_]u8{0xab} ** 55),
        &([_]u8{0xab} ** 56),
        &([_]u8{0xab} ** 300),
    };
    for (data_cases) |data| {
        for ([_]?primitives.Address{ to, null }) |recipient| {
            const nonce: u64 = 0x1234;
            const gas_limit: u64 = 16_777_216;
            const value: u256 = 1_000_000_000_000_000_000;
            const max_fee: u256 = 30_000_000_000;
            const max_priority: u256 = 0;
            const max_fee_per_blob_gas: u256 = 7;
            const y_parity: u64 = 1;

            const nonce_rlp = try primitives.Rlp.encode(a, nonce);
            const gas_limit_rlp = try primitives.Rlp.encode(a, gas_limit);
            const to_rlp = if (recipient) |address|
                try primitives.Rlp.encodeBytes(a, &address.bytes)
            else
                try primitives.Rlp.encodeBytes(a, &.{});
            const value_rlp = try primitives.Rlp.encode(a, value);
            const data_rlp = try primitives.Rlp.encodeBytes(a, data);
            const chain_id_rlp = try primitives.Rlp.encode(a, chain_id);
            const max_fee_rlp = try primitives.Rlp.encode(a, max_fee);
            const max_priority_rlp = try primitives.Rlp.encode(a, max_priority);
            const y_parity_rlp = try primitives.Rlp.encode(a, y_parity);
            const r_rlp = try primitives.Rlp.encode(a, std.mem.readInt(u256, &r, .big));
            const s_rlp = try primitives.Rlp.encode(a, std.mem.readInt(u256, &s, .big));

            const legacy_v: u64 = chain_id * 2 + 36;
            const legacy = try testRlpList(a, &.{
                nonce_rlp,                              max_fee_rlp, gas_limit_rlp, to_rlp, value_rlp, data_rlp,
                try primitives.Rlp.encode(a, legacy_v), r_rlp,       s_rlp,
            });
            const eip2930 = try testRlpList(a, &.{
                chain_id_rlp,    nonce_rlp,    max_fee_rlp, gas_limit_rlp, to_rlp, value_rlp, data_rlp,
                access_list_rlp, y_parity_rlp, r_rlp,       s_rlp,
            });
            const eip1559 = try testRlpList(a, &.{
                chain_id_rlp, nonce_rlp,       max_priority_rlp, max_fee_rlp, gas_limit_rlp, to_rlp, value_rlp,
                data_rlp,     access_list_rlp, y_parity_rlp,     r_rlp,       s_rlp,
            });
            const eip4844 = try testRlpList(a, &.{
                chain_id_rlp, nonce_rlp,       max_priority_rlp,                                   max_fee_rlp,     gas_limit_rlp, to_rlp, value_rlp,
                data_rlp,     access_list_rlp, try primitives.Rlp.encode(a, max_fee_per_blob_gas), blob_hashes_rlp, y_parity_rlp,  r_rlp,  s_rlp,
            });
            const eip7702 = try testRlpList(a, &.{
                chain_id_rlp, nonce_rlp,       max_priority_rlp,   max_fee_rlp,  gas_limit_rlp, to_rlp, value_rlp,
                data_rlp,     access_list_rlp, authorizations_rlp, y_parity_rlp, r_rlp,         s_rlp,
            });

            const base_tx = primitives.Transaction.LegacyTransaction{
                .nonce = nonce,
                .gas_price = max_fee,
                .gas_limit = gas_limit,
                .to = recipient,
                .value = value,
                .data = data,
                .v = y_parity + 27,
                .r = r,
                .s = s,
            };
            var legacy_tx = base_tx;
            legacy_tx.v = legacy_v;
            const caller = primitives.Address.fromU256(0x100);

            try std.testing.expectEqual(legacy.len, block_builder.executionTxRlpSize(.{ .caller = caller, .tx = legacy_tx }, chain_id));
            // A typed transaction sits in the body as the byte string
            // `type || rlp(payload)`.
            const typed = [_]struct { payload: []const u8, item: tx_processor.ExecutionTx }{
                .{ .payload = eip2930, .item = .{ .caller = caller, .tx = base_tx, .receipt_type = .eip2930, .access_list = &access_list } },
                .{ .payload = eip1559, .item = .{
                    .caller = caller,
                    .tx = base_tx,
                    .receipt_type = .eip1559,
                    .access_list = &access_list,
                    .max_fee_per_gas = max_fee,
                    .max_priority_fee_per_gas = max_priority,
                } },
                .{ .payload = eip4844, .item = .{
                    .caller = caller,
                    .tx = base_tx,
                    .receipt_type = .eip4844,
                    .access_list = &access_list,
                    .max_fee_per_gas = max_fee,
                    .max_priority_fee_per_gas = max_priority,
                    .max_fee_per_blob_gas = max_fee_per_blob_gas,
                    .blob_versioned_hashes = &blob_hashes,
                } },
                .{ .payload = eip7702, .item = .{
                    .caller = caller,
                    .tx = base_tx,
                    .receipt_type = .eip7702,
                    .access_list = &access_list,
                    .max_fee_per_gas = max_fee,
                    .max_priority_fee_per_gas = max_priority,
                    .authorization_list = &authorizations,
                } },
            };
            for (typed) |case| {
                const envelope = try a.alloc(u8, case.payload.len + 1);
                // The type byte's value does not change the size.
                envelope[0] = 0x02;
                @memcpy(envelope[1..], case.payload);
                const body_item = try primitives.Rlp.encodeBytes(a, envelope);
                try std.testing.expectEqual(body_item.len, block_builder.executionTxRlpSize(case.item, chain_id));
            }
        }
    }
}

const Eip7934Fixture = struct {
    const tx_count = 7;
    /// 1.5 MiB of zero calldata: 15.7M floor gas, under the EIP-7825 cap, so
    /// six of them exceed the 8 MiB block cap while each stays a valid tx.
    const big_data_len = 1_572_864;
    const gas_limit: u64 = 16_777_216;

    sm: state_manager.StateManager,
    data: []u8,
    transactions: [tx_count]tx_processor.ExecutionTx,

    fn init(self: *Eip7934Fixture, allocator: std.mem.Allocator) !void {
        self.sm = try state_manager.StateManager.init(allocator, null);
        errdefer self.sm.deinit();
        self.data = try allocator.alloc(u8, big_data_len);
        @memset(self.data, 0);
        // Prague and later read both request system contracts every block.
        try self.sm.setCode(block_builder.WITHDRAWAL_REQUESTS_ADDRESS, &.{0x00});
        try self.sm.setCode(block_builder.CONSOLIDATION_REQUESTS_ADDRESS, &.{0x00});
        const recipient = primitives.Address.fromU256(0x200);
        for (&self.transactions, 0..) |*item, index| {
            const sender = senderAddress(index);
            try self.sm.setBalance(sender, 1_000_000_000_000);
            // The last transaction is small: it still fits after a big one is
            // left out.
            const data: []const u8 = if (index == tx_count - 1) &.{} else self.data;
            item.* = .{
                .caller = sender,
                .tx = makeLegacyTx(.{ .to = recipient, .value = 1, .data = data, .gas_limit = gas_limit, .gas_price = 1, .nonce = 0 }),
            };
        }
    }

    fn deinit(self: *Eip7934Fixture, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        self.sm.deinit();
    }

    fn senderAddress(index: usize) primitives.Address {
        return primitives.Address.fromU256(0x1000 + @as(u256, index));
    }

    fn options(fork_config: hardfork_schedule.ChainConfig, skip_invalid: bool) block_builder.BuildBlockOptions {
        return .{
            .hardfork_config = fork_config,
            .withdrawals = &.{},
            .parent_beacon_block_root = [_]u8{0} ** 32,
            .parent_hash = [_]u8{0x11} ** 32,
            .skip_invalid_transactions = skip_invalid,
        };
    }
};

const eip7934_osaka_config = hardfork_schedule.ChainConfig{
    .homestead_block = 0,
    .dao_block = 0,
    .tangerine_whistle_block = 0,
    .spurious_dragon_block = 0,
    .byzantium_block = 0,
    .constantinople_block = 0,
    .petersburg_block = 0,
    .istanbul_block = 0,
    .muir_glacier_block = 0,
    .berlin_block = 0,
    .london_block = 0,
    .arrow_glacier_block = 0,
    .gray_glacier_block = 0,
    .merge_block = 0,
    .shanghai_timestamp = 0,
    .cancun_timestamp = 0,
    .prague_timestamp = 0,
    .osaka_timestamp = 0,
};

fn eip7934PragueConfig() hardfork_schedule.ChainConfig {
    var config = eip7934_osaka_config;
    config.osaka_timestamp = std.math.maxInt(u64);
    return config;
}

test "EIP-7934 Osaka builder leaves out pending transactions that overflow the block size" {
    var fixture: Eip7934Fixture = undefined;
    try fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    var adapter = host_adapter.HostAdapter{ .state = &fixture.sm };

    var result = try block_builder.buildBlockWithOptions(
        std.testing.allocator,
        &fixture.sm,
        adapter.hostInterface(),
        &fixture.transactions,
        blockContextWithGasLimit(200_000_000),
        Eip7934Fixture.options(eip7934_osaka_config, true),
    );
    defer result.deinit(std.testing.allocator);

    // Five 1.5 MiB transactions fit; the sixth overflows 8 MiB and is left
    // out; the small seventh still fits.
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3, 4, 6 }, result.included_tx_indexes);
    try std.testing.expect(result.rlp_size_upper_bound <= block_builder.MAX_RLP_BLOCK_SIZE);
    try std.testing.expect(result.rlp_size_upper_bound > 5 * Eip7934Fixture.big_data_len);
    try std.testing.expectEqual(@as(u64, 0), try fixture.sm.getNonce(Eip7934Fixture.senderAddress(5)));
    try std.testing.expectEqual(@as(u64, 1), try fixture.sm.getNonce(Eip7934Fixture.senderAddress(6)));
}

test "EIP-7934 Prague builder keeps a block larger than 8 MiB" {
    for ([_]bool{ true, false }) |skip_invalid| {
        var fixture: Eip7934Fixture = undefined;
        try fixture.init(std.testing.allocator);
        defer fixture.deinit(std.testing.allocator);
        var adapter = host_adapter.HostAdapter{ .state = &fixture.sm };

        var result = try block_builder.buildBlockWithOptions(
            std.testing.allocator,
            &fixture.sm,
            adapter.hostInterface(),
            &fixture.transactions,
            blockContextWithGasLimit(200_000_000),
            Eip7934Fixture.options(eip7934PragueConfig(), skip_invalid),
        );
        defer result.deinit(std.testing.allocator);

        try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3, 4, 5, 6 }, result.included_tx_indexes);
        try std.testing.expect(result.rlp_size_upper_bound > block_builder.MAX_RLP_BLOCK_SIZE);
    }
}

test "EIP-7934 Osaka builder rejects an oversized supplied block without changing state" {
    var fixture: Eip7934Fixture = undefined;
    try fixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);
    var adapter = host_adapter.HostAdapter{ .state = &fixture.sm };

    try std.testing.expectError(error.BlockRlpSizeExceeded, block_builder.buildBlockWithOptions(
        std.testing.allocator,
        &fixture.sm,
        adapter.hostInterface(),
        &fixture.transactions,
        blockContextWithGasLimit(200_000_000),
        Eip7934Fixture.options(eip7934_osaka_config, false),
    ));
    for (0..Eip7934Fixture.tx_count) |index| {
        try std.testing.expectEqual(@as(u64, 0), try fixture.sm.getNonce(Eip7934Fixture.senderAddress(index)));
        try std.testing.expectEqual(@as(u256, 1_000_000_000_000), try fixture.sm.getBalance(Eip7934Fixture.senderAddress(index)));
    }
    try std.testing.expectEqual(@as(u256, 0), try fixture.sm.getBalance(primitives.Address.fromU256(0x200)));

    // The same list without one big transaction is a valid Osaka block.
    var result = try block_builder.buildBlockWithOptions(
        std.testing.allocator,
        &fixture.sm,
        adapter.hostInterface(),
        fixture.transactions[1..],
        blockContextWithGasLimit(200_000_000),
        Eip7934Fixture.options(eip7934_osaka_config, false),
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 6), result.included_tx_indexes.len);
    try std.testing.expect(result.rlp_size_upper_bound <= block_builder.MAX_RLP_BLOCK_SIZE);
}

test "EIP-7934 boundary: a block of exactly 8,388,608 bytes is allowed, one more byte is not" {
    // With an empty withdrawals list the non-transaction payload is the
    // 742-byte header bound plus two empty lists, and both list prefixes are
    // four bytes, so 8,387,856 transaction bytes land exactly on the cap.
    const exact_fit: usize = 8_387_856;
    const sender = primitives.Address.fromU256(0x100);
    const transactions = [_]tx_processor.ExecutionTx{.{
        .caller = sender,
        .tx = makeLegacyTx(.{ .to = primitives.Address.fromU256(0x200), .value = 1, .data = &.{}, .gas_limit = 21_000, .gas_price = 1, .nonce = 0 }),
    }};

    for ([_]struct { size: usize, fits: bool }{
        .{ .size = exact_fit, .fits = true },
        .{ .size = exact_fit + 1, .fits = false },
    }) |case| {
        for ([_]bool{ true, false }) |skip_invalid| {
            var sm = try state_manager.StateManager.init(std.testing.allocator, null);
            defer sm.deinit();
            var adapter = host_adapter.HostAdapter{ .state = &sm };
            try sm.setCode(block_builder.WITHDRAWAL_REQUESTS_ADDRESS, &.{0x00});
            try sm.setCode(block_builder.CONSOLIDATION_REQUESTS_ADDRESS, &.{0x00});
            try sm.setBalance(sender, 1_000_000_000);

            var options = Eip7934Fixture.options(eip7934_osaka_config, skip_invalid);
            options.transaction_rlp_sizes = &.{case.size};
            const built = block_builder.buildBlockWithOptions(
                std.testing.allocator,
                &sm,
                adapter.hostInterface(),
                &transactions,
                blockContextWithGasLimit(30_000_000),
                options,
            );
            if (!case.fits and !skip_invalid) {
                try std.testing.expectError(error.BlockRlpSizeExceeded, built);
                try std.testing.expectEqual(@as(u64, 0), try sm.getNonce(sender));
                continue;
            }
            var result = try built;
            defer result.deinit(std.testing.allocator);
            if (case.fits) {
                try std.testing.expectEqualSlices(usize, &.{0}, result.included_tx_indexes);
                try std.testing.expectEqual(block_builder.MAX_RLP_BLOCK_SIZE, result.rlp_size_upper_bound);
            } else {
                try std.testing.expectEqual(@as(usize, 0), result.included_tx_indexes.len);
                try std.testing.expectEqual(@as(u64, 0), try sm.getNonce(sender));
            }
        }
    }
}

test "EIP-7934 transaction size list must match the transaction list" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();
    var adapter = host_adapter.HostAdapter{ .state = &sm };
    var options = Eip7934Fixture.options(eip7934_osaka_config, true);
    options.transaction_rlp_sizes = &.{ 100, 100 };
    try std.testing.expectError(error.TransactionSizeCountMismatch, block_builder.buildBlockWithOptions(
        std.testing.allocator,
        &sm,
        adapter.hostInterface(),
        &.{},
        blockContextWithGasLimit(30_000_000),
        options,
    ));
}

test "EIP-7825 validateBlock rejects an Osaka block holding a transaction above the cap" {
    const tx_raw = [_]u8{ 0x01, 0xc0 };
    const txs = [_]primitives.BlockBody.TransactionData{.{ .raw = &tx_raw }};
    const receipts = [_]primitives.Receipt.Receipt{makeReceipt(.{
        .logs_bloom = [_]u8{0} ** 256,
        .tx_type = .eip2930,
        .blob_gas_used = 0,
    })};
    const withdrawals = [_]primitives.BlockBody.Withdrawal{};

    var parent = parentHeader();
    parent.withdrawals_root = primitives.BlockHeader.EMPTY_WITHDRAWALS_ROOT;
    parent.blob_gas_used = 0;
    parent.excess_blob_gas = 0;
    parent.parent_beacon_block_root = primitives.Hash.ZERO;

    var header = childHeader(parent);
    header.transactions_root = try block_builder.computeRawTransactionsRoot(std.testing.allocator, &txs);
    header.receipts_root = try block_builder.computeReceiptsRoot(std.testing.allocator, &receipts);
    header.logs_bloom = block_builder.aggregateLogsBloom(&receipts);
    header.gas_used = 21_000;
    header.withdrawals_root = try block_builder.computeWithdrawalsRoot(std.testing.allocator, &withdrawals);
    header.blob_gas_used = 0;
    header.excess_blob_gas = 0;
    header.parent_beacon_block_root = primitives.Hash.ZERO;

    for ([_]struct { fork: block_builder.Hardfork, gas_limit: u64, valid: bool }{
        .{ .fork = .osaka, .gas_limit = 16_777_217, .valid = false },
        .{ .fork = .osaka, .gas_limit = 16_777_216, .valid = true },
        .{ .fork = .prague, .gas_limit = 16_777_217, .valid = true },
        .{ .fork = .cancun, .gas_limit = 30_000_000, .valid = true },
    }) |case| {
        const execution_transactions = [_]tx_processor.ExecutionTx{.{
            .caller = primitives.Address.fromU256(0x100),
            .tx = makeLegacyTx(.{ .to = null, .value = 0, .data = &.{}, .gas_limit = case.gas_limit, .gas_price = 1, .nonce = 0 }),
            .receipt_type = .eip2930,
        }};
        const validated = block_builder.validateBlock(std.testing.allocator, .{
            .header = &header,
            .parent_header = &parent,
            .fork = case.fork,
            .execution_transactions = &execution_transactions,
            .transaction_envelopes = &txs,
            .receipts = &receipts,
            .withdrawals = &withdrawals,
        });
        if (case.valid) {
            _ = try validated;
        } else {
            try std.testing.expectError(error.TransactionGasLimitExceeded, validated);
        }
    }
}

test "validateBlock enforces EIP-7918 reserve price on Osaka and EIP-7892 BPO2 max blobs" {
    const gas_per_blob: u64 = hardfork_schedule.GAS_PER_BLOB;
    const withdrawals = [_]primitives.BlockBody.Withdrawal{};

    // Parent at Osaka with target blob usage (6 blobs) and 1 gwei base fee.
    var parent = parentHeader();
    parent.timestamp = hardfork_schedule.MAINNET_CHAIN_CONFIG.osaka_timestamp;
    parent.base_fee_per_gas = 1_000_000_000;
    parent.withdrawals_root = primitives.BlockHeader.EMPTY_WITHDRAWALS_ROOT;
    parent.blob_gas_used = 6 * gas_per_blob;
    parent.excess_blob_gas = 0;
    parent.parent_beacon_block_root = primitives.Hash.ZERO;

    var child = childHeader(parent);
    child.timestamp = parent.timestamp + 12;
    child.base_fee_per_gas = try block_builder.expectedBaseFeePerGas(&parent);
    child.gas_used = 0;
    child.transactions_root = primitives.BlockHeader.EMPTY_TRANSACTIONS_ROOT;
    child.receipts_root = primitives.BlockHeader.EMPTY_RECEIPTS_ROOT;
    child.withdrawals_root = try block_builder.computeWithdrawalsRoot(std.testing.allocator, &withdrawals);
    child.blob_gas_used = 0;
    child.parent_beacon_block_root = primitives.Hash.ZERO;

    // Pre-Osaka (Prague): excess resets to 0.
    child.excess_blob_gas = 0;
    _ = try block_builder.validateBlock(std.testing.allocator, .{
        .header = &child,
        .parent_header = &parent,
        .fork = .prague,
        .withdrawals = &withdrawals,
    });
    // Osaka: reserve active -> excess = 6 * 3 / 9 = 2 blobs; 0 is rejected.
    try std.testing.expectError(error.InvalidExcessBlobGas, block_builder.validateBlock(std.testing.allocator, .{
        .header = &child,
        .parent_header = &parent,
        .fork = .osaka,
        .withdrawals = &withdrawals,
    }));
    child.excess_blob_gas = 2 * gas_per_blob;
    _ = try block_builder.validateBlock(std.testing.allocator, .{
        .header = &child,
        .parent_header = &parent,
        .fork = .osaka,
        .withdrawals = &withdrawals,
    });

    // BPO2 (max 21 blobs): 21 blobs accepted, 22 blobs rejected.
    var bpo2_parent = parent;
    bpo2_parent.timestamp = hardfork_schedule.MAINNET_BPO2.timestamp - 12;
    bpo2_parent.blob_gas_used = 0;
    bpo2_parent.excess_blob_gas = 0;
    const blob_21_receipts = [_]primitives.Receipt.Receipt{makeReceipt(.{
        .logs_bloom = [_]u8{0} ** 256,
        .tx_type = .eip4844,
        .blob_gas_used = 21 * gas_per_blob,
    })};
    const tx_raw = [_]u8{ 0x03, 0xc0 };
    const txs = [_]primitives.BlockBody.TransactionData{.{ .raw = &tx_raw }};

    var bpo2_child = childHeader(bpo2_parent);
    bpo2_child.timestamp = hardfork_schedule.MAINNET_BPO2.timestamp;
    bpo2_child.base_fee_per_gas = try block_builder.expectedBaseFeePerGas(&bpo2_parent);
    bpo2_child.gas_used = 21_000;
    bpo2_child.transactions_root = try block_builder.computeRawTransactionsRoot(std.testing.allocator, &txs);
    bpo2_child.receipts_root = try block_builder.computeReceiptsRoot(std.testing.allocator, &blob_21_receipts);
    bpo2_child.logs_bloom = block_builder.aggregateLogsBloom(&blob_21_receipts);
    bpo2_child.withdrawals_root = try block_builder.computeWithdrawalsRoot(std.testing.allocator, &withdrawals);
    bpo2_child.blob_gas_used = 21 * gas_per_blob;
    bpo2_child.excess_blob_gas = 0;
    bpo2_child.parent_beacon_block_root = primitives.Hash.ZERO;

    _ = try block_builder.validateBlock(std.testing.allocator, .{
        .header = &bpo2_child,
        .parent_header = &bpo2_parent,
        .fork = .osaka,
        .hardfork_config = hardfork_schedule.MAINNET_CHAIN_CONFIG,
        .transaction_envelopes = &txs,
        .receipts = &blob_21_receipts,
        .withdrawals = &withdrawals,
    });

    const blob_22_receipts = [_]primitives.Receipt.Receipt{makeReceipt(.{
        .logs_bloom = [_]u8{0} ** 256,
        .tx_type = .eip4844,
        .blob_gas_used = 22 * gas_per_blob,
    })};
    bpo2_child.receipts_root = try block_builder.computeReceiptsRoot(std.testing.allocator, &blob_22_receipts);
    bpo2_child.blob_gas_used = 22 * gas_per_blob;
    try std.testing.expectError(error.BlobGasLimitExceeded, block_builder.validateBlock(std.testing.allocator, .{
        .header = &bpo2_child,
        .parent_header = &bpo2_parent,
        .fork = .osaka,
        .hardfork_config = hardfork_schedule.MAINNET_CHAIN_CONFIG,
        .transaction_envelopes = &txs,
        .receipts = &blob_22_receipts,
        .withdrawals = &withdrawals,
    }));
}
