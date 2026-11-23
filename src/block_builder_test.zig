const std = @import("std");
const primitives = @import("primitives");
const state_manager = @import("state-manager");
const guillotine_mini = @import("guillotine_mini");
const block_builder = @import("block_builder.zig");
const system_contracts = @import("system_contracts.zig");
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

    // Default strict mode rejects blocks whose transactions exceed block gas limit.
    try std.testing.expectError(
        error.InvalidIncludedTransaction,
        block_builder.buildBlock(
            std.testing.allocator,
            &sm,
            host,
            &txs,
            blockContextWithGasLimit(30_000),
        ),
    );

    // Packing mode skips transactions that do not fit remaining block gas.
    var result = try block_builder.buildBlockWithOptions(
        std.testing.allocator,
        &sm,
        host,
        &txs,
        blockContextWithGasLimit(30_000),
        .{ .skip_invalid_transactions = true },
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
            .skip_invalid_transactions = true,
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

    // Deploy minimal EIP-4788-style system contract that stores TIMESTAMP at slot `TIMESTAMP % 8191`
    // and CALLDATALOAD(0) at slot `(TIMESTAMP % 8191) + 8191`.
    // PUSH2 8191; TIMESTAMP; MOD; DUP1; TIMESTAMP; SWAP1; SSTORE; PUSH2 8191; ADD; PUSH0; CALLDATALOAD; SWAP1; SSTORE; STOP
    const beacon_system_code = [_]u8{
        0x61, 0x1f, 0xff, // PUSH2 8191
        0x42, // TIMESTAMP
        0x06, // MOD -> [slot]
        0x80, // DUP1 -> [slot, slot]
        0x42, // TIMESTAMP -> [slot, slot, ts]
        0x90, // SWAP1 -> [slot, ts, slot]
        0x55, // SSTORE -> [slot]
        0x61, 0x1f, 0xff, // PUSH2 8191
        0x01, // ADD -> [slot + 8191]
        0x5f, // PUSH0
        0x35, // CALLDATALOAD -> [slot + 8191, root]
        0x90, // SWAP1 -> [root, slot + 8191]
        0x55, // SSTORE -> []
        0x00, // STOP
    };
    try sm.setCode(block_builder.BEACON_ROOTS_ADDRESS, &beacon_system_code);

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
            .skip_invalid_transactions = true,
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
    const slot = timestamp % 8191;

    // EIP-4788: empty system contract address is a no-op.
    try block_builder.applyBeaconRootsSystemCall(&sm, timestamp, root);
    try std.testing.expectEqual(@as(u256, 0), try sm.getStorage(block_builder.BEACON_ROOTS_ADDRESS, slot));

    // When code is deployed, the system call executes the contract and writes storage.
    const beacon_system_code = [_]u8{
        0x61, 0x1f, 0xff, // PUSH2 8191
        0x42, // TIMESTAMP
        0x06, // MOD -> [slot]
        0x80, // DUP1 -> [slot, slot]
        0x42, // TIMESTAMP -> [slot, slot, ts]
        0x90, // SWAP1 -> [slot, ts, slot]
        0x55, // SSTORE -> [slot]
        0x61, 0x1f, 0xff, // PUSH2 8191
        0x01, // ADD -> [slot + 8191]
        0x5f, // PUSH0
        0x35, // CALLDATALOAD -> [slot + 8191, root]
        0x90, // SWAP1 -> [root, slot + 8191]
        0x55, // SSTORE -> []
        0x00, // STOP
    };
    try sm.setCode(block_builder.BEACON_ROOTS_ADDRESS, &beacon_system_code);
    try block_builder.applyBeaconRootsSystemCall(&sm, timestamp, root);

    try std.testing.expectEqual(@as(u256, timestamp), try sm.getStorage(block_builder.BEACON_ROOTS_ADDRESS, slot));
    try std.testing.expectEqual(std.mem.readInt(u256, &root, .big), try sm.getStorage(block_builder.BEACON_ROOTS_ADDRESS, slot + 8191));
}

test "historical block hash system storage writes parent hash" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    const block_number: u64 = 8193;
    const parent_hash = [_]u8{0x34} ** 32;
    const slot = (block_number - 1) % 8191;

    // EIP-2935: empty system contract address is a no-op.
    try block_builder.applyHistoricalBlockHashSystemCall(&sm, block_number, parent_hash);
    try std.testing.expectEqual(@as(u256, 0), try sm.getStorage(block_builder.HISTORY_STORAGE_ADDRESS, slot));

    // When code is deployed, the system call executes the contract:
    // stores CALLDATALOAD(0) at slot `(NUMBER - 1) % 8191`.
    const history_system_code = [_]u8{
        0x5f, // PUSH0
        0x35, // CALLDATALOAD -> [parent_hash]
        0x61, 0x1f, 0xff, // PUSH2 8191
        0x60, 0x01, // PUSH1 1
        0x43, // NUMBER
        0x03, // SUB -> [NUMBER - 1]
        0x06, // MOD -> [(NUMBER - 1) % 8191]
        0x55, // SSTORE
        0x00, // STOP
    };
    try sm.setCode(block_builder.HISTORY_STORAGE_ADDRESS, &history_system_code);
    try block_builder.applyHistoricalBlockHashSystemCall(&sm, block_number, parent_hash);

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
        // Prague and later call both request system contracts every block.
        try system_contracts.installGenesis(&self.sm);
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
            try system_contracts.installGenesis(&sm);
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
            .requests_hash = if (case.fork == .cancun) null else [_]u8{0x5a} ** 32,
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
        .requests_hash = [_]u8{0x5a} ** 32,
    });
    // Osaka: reserve active -> excess = 6 * 3 / 9 = 2 blobs; 0 is rejected.
    try std.testing.expectError(error.InvalidExcessBlobGas, block_builder.validateBlock(std.testing.allocator, .{
        .header = &child,
        .parent_header = &parent,
        .fork = .osaka,
        .withdrawals = &withdrawals,
        .requests_hash = [_]u8{0x5a} ** 32,
    }));
    child.excess_blob_gas = 2 * gas_per_blob;
    _ = try block_builder.validateBlock(std.testing.allocator, .{
        .header = &child,
        .parent_header = &parent,
        .fork = .osaka,
        .withdrawals = &withdrawals,
        .requests_hash = [_]u8{0x5a} ** 32,
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
        .requests_hash = [_]u8{0x5a} ** 32,
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
        .requests_hash = [_]u8{0x5a} ** 32,
        .receipts = &blob_22_receipts,
        .withdrawals = &withdrawals,
    }));
}

test "pre-Byzantium receipts carry the intermediate state root instead of a status" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();
    var adapter = host_adapter.HostAdapter{ .state = &sm };

    const sender = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 };
    const recipient = primitives.Address{ .bytes = [_]u8{0x02} ++ [_]u8{0} ** 19 };
    try sm.setBalance(sender, 1_000_000);

    const txs = [_]tx_processor.ExecutionTx{
        .{
            .caller = sender,
            .tx = makeLegacyTx(.{ .to = recipient, .value = 1, .data = &.{}, .gas_limit = 21_000, .gas_price = 1, .nonce = 0 }),
        },
        .{
            .caller = sender,
            .tx = makeLegacyTx(.{ .to = recipient, .value = 1, .data = &.{}, .gas_limit = 21_000, .gas_price = 1, .nonce = 1 }),
        },
    };

    var result = try block_builder.buildBlockWithOptions(
        std.testing.allocator,
        &sm,
        adapter.hostInterface(),
        &txs,
        blockContextWithGasLimit(1_000_000),
        .{ .fork = .homestead },
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), result.receipts.len);
    for (result.receipts) |receipt| {
        try std.testing.expect(receipt.status == null);
        try std.testing.expect(receipt.root != null);
    }
    const first_root = result.receipts[0].root.?;
    const second_root = result.receipts[1].root.?;
    try std.testing.expect(!std.mem.eql(u8, &first_root, &second_root));
    // The block reward lands after the last transaction, so the last receipt
    // root is not the block state root.
    try std.testing.expect(!std.mem.eql(u8, &second_root, &result.state_root));

    // The receipts root commits to the root-form receipts.
    const receipts_root = try block_builder.computeReceiptsRoot(std.testing.allocator, result.receipts);
    try std.testing.expectEqualSlices(u8, &receipts_root, &result.receipts_root);
}

test "Byzantium and later receipts keep the status code" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();
    var adapter = host_adapter.HostAdapter{ .state = &sm };

    const sender = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 };
    try sm.setBalance(sender, 1_000_000);
    const txs = [_]tx_processor.ExecutionTx{.{
        .caller = sender,
        .tx = makeLegacyTx(.{ .to = primitives.Address{ .bytes = [_]u8{0x02} ++ [_]u8{0} ** 19 }, .value = 1, .data = &.{}, .gas_limit = 21_000, .gas_price = 1, .nonce = 0 }),
    }};

    var result = try block_builder.buildBlockWithOptions(
        std.testing.allocator,
        &sm,
        adapter.hostInterface(),
        &txs,
        blockContextWithGasLimit(1_000_000),
        .{ .fork = .byzantium },
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.receipts[0].status.?.success);
    try std.testing.expect(result.receipts[0].root == null);
}

test "validateBlock requires a requests hash from Prague and validateHeader rejects one before" {
    const gas_per_blob: u64 = 131_072;
    const withdrawals = [_]primitives.BlockBody.Withdrawal{};

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
    child.excess_blob_gas = 0;
    child.parent_beacon_block_root = primitives.Hash.ZERO;

    const hash = [_]u8{0x5a} ** 32;

    // Prague: a block that commits to no requests hash is invalid.
    try std.testing.expectError(error.InvalidRequestsHash, block_builder.validateBlock(std.testing.allocator, .{
        .header = &child,
        .parent_header = &parent,
        .fork = .prague,
        .withdrawals = &withdrawals,
    }));
    const prague = try block_builder.validateBlock(std.testing.allocator, .{
        .header = &child,
        .parent_header = &parent,
        .fork = .prague,
        .withdrawals = &withdrawals,
        .requests_hash = hash,
    });
    try std.testing.expectEqualSlices(u8, &hash, &prague.requests_hash.?);

    // The hash may also live in the header itself.
    var with_field = child;
    with_field.requests_hash = hash;
    _ = try block_builder.validateBlock(std.testing.allocator, .{
        .header = &with_field,
        .parent_header = &parent,
        .fork = .prague,
        .withdrawals = &withdrawals,
    });

    // Before Prague the header field does not exist.
    try block_builder.validateHeader(&with_field, &parent, .prague);
    try std.testing.expectError(error.InvalidRequestsHash, block_builder.validateHeader(&with_field, &parent, .cancun));
    var paris_with_requests = with_field;
    paris_with_requests.withdrawals_root = null;
    paris_with_requests.blob_gas_used = null;
    paris_with_requests.excess_blob_gas = null;
    paris_with_requests.parent_beacon_block_root = null;
    try std.testing.expectError(error.InvalidRequestsHash, block_builder.validateHeader(&paris_with_requests, &parent, .paris));
    try block_builder.validateHeader(&child, &parent, .cancun);
}

test "EIP-6110 deposit requests come from the configured deposit contract" {
    const allocator = std.testing.allocator;
    const custom = primitives.Address{ .bytes = [_]u8{0xde} ** 20 };
    const topics = [_]primitives.Hash.Hash{block_builder.DEPOSIT_EVENT_TOPIC};

    // A log with the deposit topic and malformed data is a deposit only when
    // it comes from the configured contract.
    const logs = [_]primitives.EventLog.EventLog{.{
        .address = custom,
        .topics = &topics,
        .data = &.{},
        .block_number = null,
        .transaction_hash = null,
        .transaction_index = null,
        .log_index = null,
        .removed = false,
    }};
    var receipt = makeReceipt(.{ .logs_bloom = [_]u8{0} ** 256 });
    receipt.logs = &logs;
    const receipts = [_]primitives.Receipt.Receipt{receipt};

    try std.testing.expect((try block_builder.extractDepositRequests(allocator, &receipts)) == null);
    try std.testing.expectError(
        error.InvalidDepositEventLayout,
        block_builder.extractDepositRequestsFrom(allocator, &receipts, custom),
    );
    const defaults = block_builder.BuildBlockOptions{};
    try std.testing.expect(defaults.deposit_contract_address == null);
    try std.testing.expect(defaults.effectiveDepositContractAddress().equals(block_builder.DEPOSIT_CONTRACT_ADDRESS));
}

test "EIP-161 deletes a touched pre-existing empty beneficiary and keeps an untouched one" {
    const allocator = std.testing.allocator;
    var sm = try state_manager.StateManager.init(allocator, null);
    defer sm.deinit();
    var adapter = host_adapter.HostAdapter{ .state = &sm };

    const sender = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 };
    const recipient = primitives.Address{ .bytes = [_]u8{0x02} ++ [_]u8{0} ** 19 };
    const untouched_empty = primitives.Address{ .bytes = [_]u8{0xE1} ++ [_]u8{0} ** 19 };
    const beneficiary = primitives.Address{ .bytes = [_]u8{0xE2} ++ [_]u8{0} ** 19 };

    const sender_balance: u256 = 1_000_000_000;
    try sm.setBalance(sender, sender_balance);
    // Two accounts that are in the state trie and empty before the block.
    try sm.initAccount(untouched_empty, 0);
    try sm.initAccount(beneficiary, 0);

    // Post-Merge block whose transaction pays exactly the base fee: the
    // priority fee is zero, so fee settlement touches the beneficiary
    // without crediting it.
    var block_ctx = blockContextWithGasLimit(30_000_000);
    block_ctx.block_coinbase = beneficiary;
    block_ctx.block_base_fee = 7;

    const transfer_value: u256 = 1;
    const txs = [_]tx_processor.ExecutionTx{.{
        .caller = sender,
        .tx = makeLegacyTx(.{
            .to = recipient,
            .value = transfer_value,
            .data = &.{},
            .gas_limit = 21_000,
            .gas_price = 7,
            .nonce = 0,
        }),
    }};

    var config = hardfork_schedule.MAINNET_CHAIN_CONFIG;
    config.shanghai_timestamp = std.math.maxInt(u64);
    config.cancun_timestamp = std.math.maxInt(u64);
    config.prague_timestamp = std.math.maxInt(u64);
    config.osaka_timestamp = std.math.maxInt(u64);
    config.merge_block = 0;
    config.london_block = 0;

    var result = try block_builder.buildBlockWithOptions(
        allocator,
        &sm,
        adapter.hostInterface(),
        &txs,
        block_ctx,
        .{ .fork = .paris, .hardfork_config = config },
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.receipts.len);
    try std.testing.expect(result.receipts[0].status.?.success);
    // The beneficiary earned nothing.
    try std.testing.expectEqual(@as(u256, 0), try sm.getBalance(beneficiary));

    // Only the untouched empty account is still in the state trie.
    const expected_accounts = [_]genesis.PremineAccount{
        .{ .address = sender, .balance = sender_balance - transfer_value - 21_000 * 7, .nonce = 1 },
        .{ .address = recipient, .balance = transfer_value, .nonce = 0 },
        .{ .address = untouched_empty, .balance = 0, .nonce = 0 },
    };
    const expected_root = try genesis.computeStateRootFromPremine(allocator, &expected_accounts);
    try std.testing.expectEqualSlices(u8, &expected_root, &result.state_root);

    // Keeping the touched beneficiary, as the builder did before, gives a
    // different root.
    const stale_accounts = expected_accounts ++ [_]genesis.PremineAccount{
        .{ .address = beneficiary, .balance = 0, .nonce = 0 },
    };
    const stale_root = try genesis.computeStateRootFromPremine(allocator, &stale_accounts);
    try std.testing.expect(!std.mem.eql(u8, &stale_root, &result.state_root));
}

test "pruneEmptyAccounts deletes touched or new empty accounts and keeps untouched pre-existing ones" {
    const allocator = std.testing.allocator;
    var sm = try state_manager.StateManager.init(allocator, null);
    defer sm.deinit();

    const untouched_empty = primitives.Address{ .bytes = [_]u8{0xE1} ++ [_]u8{0} ** 19 };
    const touched_empty = primitives.Address{ .bytes = [_]u8{0xE2} ++ [_]u8{0} ** 19 };
    const new_empty = primitives.Address{ .bytes = [_]u8{0xE3} ++ [_]u8{0} ** 19 };
    const touched_funded = primitives.Address{ .bytes = [_]u8{0xE4} ++ [_]u8{0} ** 19 };

    try sm.initAccount(untouched_empty, 0);
    try sm.initAccount(touched_empty, 0);
    try sm.initAccount(touched_funded, 5);

    var preserved = try block_builder.collectEmptyAccounts(allocator, &sm);
    defer preserved.deinit();
    try std.testing.expectEqual(@as(u32, 2), preserved.count());

    try sm.initAccount(new_empty, 0);

    var touched = std.AutoHashMap(primitives.Address, void).init(allocator);
    defer touched.deinit();
    try touched.put(touched_empty, {});
    try touched.put(touched_funded, {});

    try block_builder.pruneEmptyAccounts(allocator, &sm, &preserved, &touched);

    const expected_accounts = [_]genesis.PremineAccount{
        .{ .address = untouched_empty, .balance = 0, .nonce = 0 },
        .{ .address = touched_funded, .balance = 5, .nonce = 0 },
    };
    const expected_root = try genesis.computeStateRootFromPremine(allocator, &expected_accounts);
    try std.testing.expectEqualSlices(u8, &expected_root, &(try block_builder.computeStateRoot(allocator, &sm)));
}

test "buildBlockWithOptions rejects a Prague block without the request predeploys only in strict mode" {
    const allocator = std.testing.allocator;
    // mstore8(0, 0xaa); return(0, 1)
    const one_byte = [_]u8{ 0x60, 0xaa, 0x60, 0x00, 0x53, 0x60, 0x01, 0x60, 0x00, 0xf3 };
    var block_ctx = blockContextWithGasLimit(30_000_000);
    block_ctx.block_timestamp = hardfork_schedule.MAINNET_CHAIN_CONFIG.prague_timestamp;
    block_ctx.block_number = 22_500_000;

    const predeploys = [_]primitives.Address{
        block_builder.WITHDRAWAL_REQUESTS_ADDRESS,
        block_builder.CONSOLIDATION_REQUESTS_ADDRESS,
    };
    for (predeploys) |deployed| {
        var sm = try state_manager.StateManager.init(allocator, null);
        defer sm.deinit();
        var adapter = host_adapter.HostAdapter{ .state = &sm };
        try sm.setCode(deployed, &one_byte);
        const root_before = try block_builder.computeStateRoot(allocator, &sm);

        var options = block_builder.BuildBlockOptions{
            .fork = .prague,
            .hardfork_config = hardfork_schedule.MAINNET_CHAIN_CONFIG,
            .withdrawals = &.{},
            .parent_hash = [_]u8{0x11} ** 32,
            .require_system_contracts = true,
        };
        try std.testing.expectError(
            error.SystemContractMissingCode,
            block_builder.buildBlockWithOptions(allocator, &sm, adapter.hostInterface(), &.{}, block_ctx, options),
        );
        // The rejected block left the state unchanged.
        try std.testing.expectEqualSlices(u8, &root_before, &(try block_builder.computeStateRoot(allocator, &sm)));

        options.require_system_contracts = false;
        var result = try block_builder.buildBlockWithOptions(allocator, &sm, adapter.hostInterface(), &.{}, block_ctx, options);
        defer result.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), result.execution_requests.len);
    }
}

test "applyBlockRewards does not overflow near the top of the block number range (R4-07)" {
    const allocator = std.testing.allocator;
    const miner = primitives.Address{ .bytes = [_]u8{0xa1} ++ [_]u8{0} ** 19 };
    const ommer_miner = primitives.Address{ .bytes = [_]u8{0xb2} ++ [_]u8{0} ** 19 };
    const reward = block_builder.blockRewardWei(.london).?;
    const max = std.math.maxInt(u64);

    {
        var sm = try state_manager.StateManager.init(allocator, null);
        defer sm.deinit();
        const ommers = [_]primitives.BlockBody.UncleHeader{.{ .number = max - 2, .beneficiary = ommer_miner }};
        try block_builder.applyBlockRewards(&sm, miner, &ommers, max, .london);
        try std.testing.expectEqual(reward + reward / 32, try sm.getBalance(miner));
        // Distance 2: (8 - 2) / 8 of the block reward.
        try std.testing.expectEqual(reward * 6 / 8, try sm.getBalance(ommer_miner));
    }

    // Distance 6 is the oldest ommer the Yellow Paper admits.
    {
        var sm = try state_manager.StateManager.init(allocator, null);
        defer sm.deinit();
        const ommers = [_]primitives.BlockBody.UncleHeader{.{ .number = max - 6, .beneficiary = ommer_miner }};
        try block_builder.applyBlockRewards(&sm, miner, &ommers, max, .london);
        try std.testing.expectEqual(reward * 2 / 8, try sm.getBalance(ommer_miner));
    }

    // Distance 7, a same-height ommer and a future ommer are rejected.
    for ([_]struct { ommer: u64, block: u64 }{
        .{ .ommer = max - 7, .block = max },
        .{ .ommer = 3, .block = 10 },
        .{ .ommer = max, .block = max },
        .{ .ommer = max, .block = max - 1 },
    }) |case| {
        var sm = try state_manager.StateManager.init(allocator, null);
        defer sm.deinit();
        const ommers = [_]primitives.BlockBody.UncleHeader{.{ .number = case.ommer, .beneficiary = ommer_miner }};
        try std.testing.expectError(
            error.InvalidOmmerReward,
            block_builder.applyBlockRewards(&sm, miner, &ommers, case.block, .london),
        );
    }
}

test "collectBlockExecutionRequestsWithOptions honors require_system_contracts (R4-06)" {
    const allocator = std.testing.allocator;
    const block_ctx = blockContextWithGasLimit(30_000_000);

    var sm = try state_manager.StateManager.init(allocator, null);
    defer sm.deinit();

    // Neither EIP-7002 nor EIP-7251 predeploy has code.
    try std.testing.expectError(
        error.SystemContractMissingCode,
        block_builder.collectBlockExecutionRequestsWithOptions(allocator, &sm, &.{}, .prague, block_ctx, .{
            .require_system_contracts = true,
        }),
    );

    // The relaxed option and the thin wrapper keep the dev-chain no-op.
    const relaxed = try block_builder.collectBlockExecutionRequestsWithOptions(allocator, &sm, &.{}, .prague, block_ctx, .{});
    defer block_builder.freeExecutionRequests(allocator, relaxed);
    try std.testing.expectEqual(@as(usize, 0), relaxed.len);

    const wrapped = try block_builder.collectBlockExecutionRequestsFrom(allocator, &sm, &.{}, .prague, block_ctx, block_builder.DEPOSIT_CONTRACT_ADDRESS);
    defer block_builder.freeExecutionRequests(allocator, wrapped);
    try std.testing.expectEqual(@as(usize, 0), wrapped.len);

    // Before Prague there are no requests and no system-contract check.
    const cancun = try block_builder.collectBlockExecutionRequestsWithOptions(allocator, &sm, &.{}, .cancun, block_ctx, .{
        .require_system_contracts = true,
    });
    defer block_builder.freeExecutionRequests(allocator, cancun);
    try std.testing.expectEqual(@as(usize, 0), cancun.len);
}
