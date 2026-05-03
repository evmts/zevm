const std = @import("std");
const primitives = @import("primitives");
const state_manager = @import("state-manager");
const guillotine_mini = @import("guillotine_mini");
const block_builder = @import("block_builder.zig");
const genesis = @import("genesis.zig");
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
