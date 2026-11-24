const std = @import("std");
const primitives = @import("primitives");
const state_manager = @import("state-manager");
const guillotine_mini = @import("guillotine_mini");
const tx_processor = @import("tx_processor.zig");
const host_adapter = @import("host_adapter.zig");
const hardfork_schedule = @import("hardfork_schedule.zig");
const tx_encoding = @import("transaction_encoding.zig");

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

fn defaultBlockContext() guillotine_mini.BlockContext {
    return .{
        .chain_id = 1,
        .block_number = 19_426_587,
        .block_timestamp = 1_710_338_135,
        .block_difficulty = 0,
        .block_prevrandao = 0,
        .block_coinbase = primitives.Address{ .bytes = [_]u8{0xCB} ++ [_]u8{0} ** 19 },
        .block_gas_limit = 30_000_000,
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

test "contract creation intrinsic gas changes at Homestead" {
    try std.testing.expectEqual(@as(u64, 21_000), tx_processor.intrinsicGasForFork(&.{}, true, .FRONTIER));
    try std.testing.expectEqual(@as(u64, 53_000), tx_processor.intrinsicGasForFork(&.{}, true, .HOMESTEAD));
}

test "intrinsic gas calculation" {
    try std.testing.expectEqual(@as(u64, 21_000), tx_processor.intrinsicGas(&[_]u8{}, false));
    try std.testing.expectEqual(@as(u64, 21_000 + 32_000), tx_processor.intrinsicGas(&[_]u8{}, true));
    try std.testing.expectEqual(@as(u64, 21_000 + 16 + 4 + 16), tx_processor.intrinsicGas(&[_]u8{ 0x01, 0x00, 0x02 }, false));
    try std.testing.expectEqual(@as(u64, 21_000 + 32_000 + 8 + 16 * 100), tx_processor.intrinsicGasForFork(&([_]u8{0x01} ** 100), true, .CANCUN));
    try std.testing.expectEqual(@as(u64, 21_000 + 32_000 + 16 * 100), tx_processor.intrinsicGasForFork(&([_]u8{0x01} ** 100), true, .LONDON));
}

test "contract creation intrinsic gas follows the Homestead boundary" {
    try std.testing.expectEqual(@as(u64, 21_068), tx_processor.intrinsicGasForFork(&.{0x01}, true, .FRONTIER));
    try std.testing.expectEqual(@as(u64, 53_068), tx_processor.intrinsicGasForFork(&.{0x01}, true, .HOMESTEAD));
}

test "EIP-3860 rejects oversized creation transactions from Shanghai" {
    const max_size = primitives.GasConstants.MaxInitcodeSize;
    const data = [_]u8{0} ** (max_size + 1);
    const sender = primitives.Address.fromU256(0x100);
    const recipient = primitives.Address.fromU256(0x200);
    const cases = [_]struct { fork: guillotine_mini.Hardfork, len: usize, to: ?primitives.Address, valid: bool }{
        .{ .fork = .BERLIN, .len = data.len, .to = null, .valid = true },
        .{ .fork = .SHANGHAI, .len = max_size, .to = null, .valid = true },
        .{ .fork = .SHANGHAI, .len = data.len, .to = null, .valid = false },
        .{ .fork = .SHANGHAI, .len = data.len, .to = recipient, .valid = true },
    };
    for (cases) |case| {
        var sm = try state_manager.StateManager.init(std.testing.allocator, null);
        defer sm.deinit();
        var adapter = host_adapter.HostAdapter{ .state = &sm };
        try sm.setBalance(sender, 1_000_000);
        const result = tx_processor.processTransactionWithOptions(
            std.testing.allocator,
            &sm,
            adapter.hostInterface(),
            sender,
            makeLegacyTx(.{ .to = case.to, .value = 0, .data = data[0..case.len], .gas_limit = 500_000, .gas_price = 1, .nonce = 0 }),
            defaultBlockContext(),
            .{ .hardfork_override = case.fork },
        );
        if (result) |value| {
            var receipt = value;
            defer receipt.deinit(std.testing.allocator);
            try std.testing.expect(case.valid and receipt.status.?.success);
        } else |err| {
            if (case.valid) return err;
            try std.testing.expectEqual(@as(anyerror, error.InitcodeTooLarge), err);
            try std.testing.expectEqual(@as(u64, 0), try sm.getNonce(sender));
            try std.testing.expectEqual(@as(u256, 1_000_000), try sm.getBalance(sender));
        }
    }
}

test "resolveHardfork follows block number and timestamp schedule" {
    var ctx = defaultBlockContext();

    ctx.block_number = 0;
    ctx.block_timestamp = 0;
    try std.testing.expectEqual(guillotine_mini.Hardfork.FRONTIER, tx_processor.resolveHardfork(ctx));

    ctx.block_number = 12_965_000;
    ctx.block_timestamp = 0;
    try std.testing.expectEqual(guillotine_mini.Hardfork.LONDON, tx_processor.resolveHardfork(ctx));

    ctx.block_number = 15_537_394;
    ctx.block_timestamp = 1_681_338_455;
    try std.testing.expectEqual(guillotine_mini.Hardfork.SHANGHAI, tx_processor.resolveHardfork(ctx));

    ctx.block_timestamp = 1_710_338_135;
    try std.testing.expectEqual(guillotine_mini.Hardfork.CANCUN, tx_processor.resolveHardfork(ctx));

    ctx.block_timestamp = 1_746_612_311;
    try std.testing.expectEqual(guillotine_mini.Hardfork.PRAGUE, tx_processor.resolveHardfork(ctx));

    ctx.block_number = 0;
    ctx.block_timestamp = 0;
    const dev_config = hardfork_schedule.ChainConfig{
        .homestead_block = 0,
        .dao_block = 0,
        .tangerine_whistle_block = 0,
        .spurious_dragon_block = 0,
        .byzantium_block = 0,
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
        .prague_timestamp = std.math.maxInt(u64),
        .osaka_timestamp = std.math.maxInt(u64),
    };
    try std.testing.expectEqual(guillotine_mini.Hardfork.CANCUN, tx_processor.resolveHardforkWithConfig(dev_config, ctx));
}

test "processTransaction uses block-context hardfork for intrinsic gas" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var adapter = host_adapter.HostAdapter{ .state = &sm };
    const sender = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 };
    const recipient = primitives.Address{ .bytes = [_]u8{0x02} ++ [_]u8{0} ** 19 };

    try sm.setBalance(sender, 1_000_000_000_000);
    try sm.setNonce(sender, 0);

    var frontier_ctx = defaultBlockContext();
    frontier_ctx.block_number = 0;
    frontier_ctx.block_timestamp = 0;

    const result = tx_processor.processTransaction(
        std.testing.allocator,
        &sm,
        adapter.hostInterface(),
        sender,
        makeLegacyTx(.{
            .to = recipient,
            .value = 0,
            .data = &[_]u8{0x01},
            .gas_limit = 21_016,
            .gas_price = 0,
            .nonce = 0,
        }),
        frontier_ctx,
    );

    try std.testing.expectError(tx_processor.TxError.IntrinsicGasExceedsLimit, result);
    try std.testing.expectEqual(@as(u64, 0), try sm.getNonce(sender));
}

test "process simple ETH transfer" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var adapter = host_adapter.HostAdapter{ .state = &sm };
    const host = adapter.hostInterface();

    const sender = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 };
    const recipient = primitives.Address{ .bytes = [_]u8{0x02} ++ [_]u8{0} ** 19 };

    try sm.setBalance(sender, 1_000_000_000_000);
    try sm.setNonce(sender, 0);

    var receipt = try tx_processor.processTransaction(
        std.testing.allocator,
        &sm,
        host,
        sender,
        makeLegacyTx(.{
            .to = recipient,
            .value = 1000,
            .data = &[_]u8{},
            .gas_limit = 21_000,
            .gas_price = 1,
            .nonce = 0,
        }),
        defaultBlockContext(),
    );
    defer receipt.deinit(std.testing.allocator);

    try std.testing.expect(receipt.status.?.success);
    try std.testing.expectEqual(@as(u256, 21_000), receipt.gas_used);
    try std.testing.expectEqual(@as(u64, 1), try sm.getNonce(sender));

    // Verify value transferred
    const recipient_bal = try sm.getBalance(recipient);
    try std.testing.expectEqual(@as(u256, 1000), recipient_bal);
}

test "processTransaction receipt hash uses canonical signed legacy envelope" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var adapter = host_adapter.HostAdapter{ .state = &sm };
    const host = adapter.hostInterface();

    const sender = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 };
    const recipient = primitives.Address{ .bytes = [_]u8{0x02} ++ [_]u8{0} ** 19 };
    var r = [_]u8{0} ** 32;
    var s = [_]u8{0} ** 32;
    r[31] = 0x01;
    s[31] = 0x80;

    try sm.setBalance(sender, 1_000_000_000_000);
    try sm.setNonce(sender, 0);

    var tx = makeLegacyTx(.{
        .to = recipient,
        .value = 0,
        .data = &[_]u8{},
        .gas_limit = 21_000,
        .gas_price = 1,
        .nonce = 0,
    });
    tx.v = 37;
    tx.r = r;
    tx.s = s;

    const canonical = try tx_encoding.encodeLegacyTransactionEnvelope(std.testing.allocator, tx);
    defer std.testing.allocator.free(canonical);
    const expected_hash = tx_encoding.transactionHash(canonical);

    var receipt = try tx_processor.processTransaction(
        std.testing.allocator,
        &sm,
        host,
        sender,
        tx,
        defaultBlockContext(),
    );
    defer receipt.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &expected_hash, &receipt.transaction_hash);
}

test "precompile call executes even with empty input" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var adapter = host_adapter.HostAdapter{ .state = &sm };
    const host = adapter.hostInterface();

    const sender = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 };
    const precompile = primitives.Address.fromU256(4);

    try sm.setBalance(sender, 1_000_000);
    try sm.setNonce(sender, 0);

    var receipt = try tx_processor.processTransaction(
        std.testing.allocator,
        &sm,
        host,
        sender,
        makeLegacyTx(.{
            .to = precompile,
            .value = 0,
            .data = &[_]u8{},
            .gas_limit = 25_000,
            .gas_price = 1,
            .nonce = 0,
        }),
        defaultBlockContext(),
    );
    defer receipt.deinit(std.testing.allocator);

    try std.testing.expect(receipt.status.?.success);
    try std.testing.expect(receipt.gas_used > @as(u256, 21_000));
}

test "processTransaction aborts when EVM host read records an error" {
    var fork_backend = try state_manager.ForkBackend.init(std.testing.allocator, "latest", .{});
    defer fork_backend.deinit();

    var sm = try state_manager.StateManager.init(std.testing.allocator, &fork_backend);
    defer sm.deinit();

    var adapter = host_adapter.HostAdapter{ .state = &sm };

    const sender = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 };
    const contract = primitives.Address{ .bytes = [_]u8{0x02} ++ [_]u8{0} ** 19 };
    const remote = primitives.Address{ .bytes = [_]u8{0x99} ++ [_]u8{0} ** 19 };
    const code = balanceProbeBytecode(remote);

    try sm.initAccount(sender, 0);
    try sm.setCode(sender, &[_]u8{});
    try sm.setCode(contract, &code);

    const result = tx_processor.processTransaction(
        std.testing.allocator,
        &sm,
        adapter.hostInterface(),
        sender,
        makeLegacyTx(.{
            .to = contract,
            .value = 0,
            .data = &[_]u8{},
            .gas_limit = 100_000,
            .gas_price = 0,
            .nonce = 0,
        }),
        defaultBlockContext(),
    );

    try std.testing.expectError(tx_processor.TxError.StateError, result);
    try std.testing.expectEqual(@as(?host_adapter.HostAdapter.HostError, null), adapter.getHostError());
    try std.testing.expectEqual(@as(u64, 0), try sm.getNonce(sender));
}

test "reject wrong nonce" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var adapter = host_adapter.HostAdapter{ .state = &sm };

    try sm.setBalance(primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 }, 1_000_000_000_000);
    try sm.setNonce(primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 }, 5);

    const result = tx_processor.processTransaction(
        std.testing.allocator,
        &sm,
        adapter.hostInterface(),
        primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 },
        makeLegacyTx(.{
            .to = primitives.Address{ .bytes = [_]u8{0x02} ++ [_]u8{0} ** 19 },
            .value = 0,
            .data = &[_]u8{},
            .gas_limit = 21_000,
            .gas_price = 1,
            .nonce = 0,
        }),
        defaultBlockContext(),
    );

    try std.testing.expectError(tx_processor.TxError.NonceMismatch, result);
}

test "reject transaction from sender with code" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var adapter = host_adapter.HostAdapter{ .state = &sm };
    const sender = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 };

    try sm.setBalance(sender, 1_000_000_000_000);
    try sm.setNonce(sender, 0);
    try sm.setCode(sender, &[_]u8{0x00});

    const result = tx_processor.processTransaction(
        std.testing.allocator,
        &sm,
        adapter.hostInterface(),
        sender,
        makeLegacyTx(.{
            .to = primitives.Address{ .bytes = [_]u8{0x02} ++ [_]u8{0} ** 19 },
            .value = 0,
            .data = &[_]u8{},
            .gas_limit = 21_000,
            .gas_price = 1,
            .nonce = 0,
        }),
        defaultBlockContext(),
    );

    try std.testing.expectError(tx_processor.TxError.SenderNotEOA, result);
    try std.testing.expectEqual(@as(u64, 0), try sm.getNonce(sender));
}

test "reject typed transactions before activation fork" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var adapter = host_adapter.HostAdapter{ .state = &sm };
    const sender = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 };
    const recipient = primitives.Address{ .bytes = [_]u8{0x02} ++ [_]u8{0} ** 19 };

    try sm.setBalance(sender, 1_000_000_000_000);
    try sm.setNonce(sender, 0);

    const access_list_result = tx_processor.processTransactionWithOptions(
        std.testing.allocator,
        &sm,
        adapter.hostInterface(),
        sender,
        makeLegacyTx(.{
            .to = recipient,
            .value = 0,
            .data = &[_]u8{},
            .gas_limit = 21_000,
            .gas_price = 1,
            .nonce = 0,
        }),
        defaultBlockContext(),
        .{ .receipt_type = .eip2930, .hardfork_override = .ISTANBUL },
    );
    try std.testing.expectError(tx_processor.TxError.UnsupportedTransactionType, access_list_result);
    try std.testing.expectEqual(@as(u64, 0), try sm.getNonce(sender));

    const dynamic_fee_result = tx_processor.processTransactionWithOptions(
        std.testing.allocator,
        &sm,
        adapter.hostInterface(),
        sender,
        makeLegacyTx(.{
            .to = recipient,
            .value = 0,
            .data = &[_]u8{},
            .gas_limit = 21_000,
            .gas_price = 1,
            .nonce = 0,
        }),
        defaultBlockContext(),
        .{ .receipt_type = .eip1559, .hardfork_override = .BERLIN },
    );
    try std.testing.expectError(tx_processor.TxError.UnsupportedTransactionType, dynamic_fee_result);
    try std.testing.expectEqual(@as(u64, 0), try sm.getNonce(sender));
}

test "reject invalid dynamic fee caps" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var adapter = host_adapter.HostAdapter{ .state = &sm };
    const sender = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 };
    const recipient = primitives.Address{ .bytes = [_]u8{0x02} ++ [_]u8{0} ** 19 };
    var block_ctx = defaultBlockContext();
    block_ctx.block_base_fee = 100;

    try sm.setBalance(sender, 1_000_000_000_000);
    try sm.setNonce(sender, 0);

    const low_fee_cap = tx_processor.processTransactionWithOptions(
        std.testing.allocator,
        &sm,
        adapter.hostInterface(),
        sender,
        makeLegacyTx(.{
            .to = recipient,
            .value = 0,
            .data = &[_]u8{},
            .gas_limit = 21_000,
            .gas_price = 99,
            .nonce = 0,
        }),
        block_ctx,
        .{ .receipt_type = .eip1559, .max_fee_per_gas = 99, .max_priority_fee_per_gas = 1, .hardfork_override = .LONDON },
    );
    try std.testing.expectError(tx_processor.TxError.GasPriceBelowBaseFee, low_fee_cap);
    try std.testing.expectEqual(@as(u64, 0), try sm.getNonce(sender));

    const excessive_tip = tx_processor.processTransactionWithOptions(
        std.testing.allocator,
        &sm,
        adapter.hostInterface(),
        sender,
        makeLegacyTx(.{
            .to = recipient,
            .value = 0,
            .data = &[_]u8{},
            .gas_limit = 21_000,
            .gas_price = 100,
            .nonce = 0,
        }),
        block_ctx,
        .{ .receipt_type = .eip1559, .max_fee_per_gas = 100, .max_priority_fee_per_gas = 101, .hardfork_override = .LONDON },
    );
    try std.testing.expectError(tx_processor.TxError.TipExceedsFeeCap, excessive_tip);
    try std.testing.expectEqual(@as(u64, 0), try sm.getNonce(sender));

    try sm.setBalance(sender, 50_000_020);
    const insufficient_fee_cap_balance = tx_processor.processTransactionWithOptions(
        std.testing.allocator,
        &sm,
        adapter.hostInterface(),
        sender,
        makeLegacyTx(.{
            .to = recipient,
            .value = 48_000_020,
            .data = &[_]u8{0},
            .gas_limit = 50_000,
            .gas_price = 40,
            .nonce = 0,
        }),
        block_ctx,
        .{ .receipt_type = .eip1559, .max_fee_per_gas = 1000, .max_priority_fee_per_gas = 20, .hardfork_override = .LONDON },
    );
    try std.testing.expectError(tx_processor.TxError.InsufficientBalance, insufficient_fee_cap_balance);
    try std.testing.expectEqual(@as(u64, 0), try sm.getNonce(sender));
}

test "dynamic fee transaction exposes effective gas precharge during execution" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var adapter = host_adapter.HostAdapter{ .state = &sm };
    const sender = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 };
    const contract = primitives.Address{ .bytes = [_]u8{0x02} ++ [_]u8{0} ** 19 };
    const sender_balance: u256 = 1_000_000_000_000_000_000;
    const gas_limit: u64 = 60_000;
    const base_fee: u256 = 11;
    const priority_fee: u256 = 100;
    const max_fee: u256 = 1000;
    const effective_gas_price = base_fee + priority_fee;

    var block_ctx = defaultBlockContext();
    block_ctx.block_base_fee = base_fee;

    try sm.setBalance(sender, sender_balance);
    try sm.setNonce(sender, 0);
    try sm.setCode(contract, &.{ 0x33, 0x31, 0x60, 0x00, 0x55, 0x00 });

    var receipt = try tx_processor.processTransactionWithOptions(
        std.testing.allocator,
        &sm,
        adapter.hostInterface(),
        sender,
        makeLegacyTx(.{
            .to = contract,
            .value = 0,
            .data = &.{},
            .gas_limit = gas_limit,
            .gas_price = max_fee,
            .nonce = 0,
        }),
        block_ctx,
        .{
            .receipt_type = .eip1559,
            .max_fee_per_gas = max_fee,
            .max_priority_fee_per_gas = priority_fee,
            .hardfork_override = .LONDON,
        },
    );
    defer receipt.deinit(std.testing.allocator);

    try std.testing.expect(receipt.status.?.success);
    try std.testing.expectEqual(effective_gas_price, receipt.effective_gas_price);
    try std.testing.expectEqual(
        sender_balance - gas_limit * effective_gas_price,
        try sm.getStorage(contract, 0),
    );
}

test "reject transaction gas limit above block gas limit" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var adapter = host_adapter.HostAdapter{ .state = &sm };
    const sender = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 };
    const recipient = primitives.Address{ .bytes = [_]u8{0x02} ++ [_]u8{0} ** 19 };
    var block_ctx = defaultBlockContext();
    block_ctx.block_gas_limit = 20_999;

    try sm.setBalance(sender, 1_000_000_000_000);
    try sm.setNonce(sender, 0);

    const result = tx_processor.processTransaction(
        std.testing.allocator,
        &sm,
        adapter.hostInterface(),
        sender,
        makeLegacyTx(.{
            .to = recipient,
            .value = 0,
            .data = &[_]u8{},
            .gas_limit = 21_000,
            .gas_price = 1,
            .nonce = 0,
        }),
        block_ctx,
    );
    try std.testing.expectError(tx_processor.TxError.BlockGasLimitExceeded, result);
    try std.testing.expectEqual(@as(u64, 0), try sm.getNonce(sender));
}

test "reject insufficient balance" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var adapter = host_adapter.HostAdapter{ .state = &sm };

    try sm.setBalance(primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 }, 100);
    try sm.setNonce(primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 }, 0);

    const result = tx_processor.processTransaction(
        std.testing.allocator,
        &sm,
        adapter.hostInterface(),
        primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 },
        makeLegacyTx(.{
            .to = primitives.Address{ .bytes = [_]u8{0x02} ++ [_]u8{0} ** 19 },
            .value = 0,
            .data = &[_]u8{},
            .gas_limit = 21_000,
            .gas_price = 1,
            .nonce = 0,
        }),
        defaultBlockContext(),
    );

    try std.testing.expectError(tx_processor.TxError.InsufficientBalance, result);
}

test "reject gas limit below intrinsic" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var adapter = host_adapter.HostAdapter{ .state = &sm };

    try sm.setBalance(primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 }, 1_000_000_000_000);
    try sm.setNonce(primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 }, 0);

    const result = tx_processor.processTransaction(
        std.testing.allocator,
        &sm,
        adapter.hostInterface(),
        primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 },
        makeLegacyTx(.{
            .to = primitives.Address{ .bytes = [_]u8{0x02} ++ [_]u8{0} ** 19 },
            .value = 0,
            .data = &[_]u8{},
            .gas_limit = 20_000,
            .gas_price = 1,
            .nonce = 0,
        }),
        defaultBlockContext(),
    );

    try std.testing.expectError(tx_processor.TxError.IntrinsicGasExceedsLimit, result);
}

test "gas accounting: sender pays gas, coinbase receives" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var adapter = host_adapter.HostAdapter{ .state = &sm };
    const host = adapter.hostInterface();

    const sender = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 };
    const recipient = primitives.Address{ .bytes = [_]u8{0x02} ++ [_]u8{0} ** 19 };
    const coinbase = primitives.Address{ .bytes = [_]u8{0xCB} ++ [_]u8{0} ** 19 };

    const initial_balance: u256 = 1_000_000;
    try sm.setBalance(sender, initial_balance);
    try sm.setNonce(sender, 0);

    const gas_price: u256 = 10;
    const gas_limit: u64 = 21_000;

    var receipt = try tx_processor.processTransaction(
        std.testing.allocator,
        &sm,
        host,
        sender,
        makeLegacyTx(.{
            .to = recipient,
            .value = 0,
            .data = &[_]u8{},
            .gas_limit = gas_limit,
            .gas_price = gas_price,
            .nonce = 0,
        }),
        defaultBlockContext(),
    );
    defer receipt.deinit(std.testing.allocator);

    const gas_cost = gas_price * @as(u256, receipt.gas_used);
    try std.testing.expectEqual(initial_balance - gas_cost, try sm.getBalance(sender));
    try std.testing.expectEqual(gas_cost, try sm.getBalance(coinbase));
}

test "sequential transactions increment nonce" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var adapter = host_adapter.HostAdapter{ .state = &sm };
    const host = adapter.hostInterface();

    const sender = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 };
    const recipient = primitives.Address{ .bytes = [_]u8{0x02} ++ [_]u8{0} ** 19 };

    try sm.setBalance(sender, 1_000_000);
    try sm.setNonce(sender, 0);

    // First tx
    var r1 = try tx_processor.processTransaction(
        std.testing.allocator,
        &sm,
        host,
        sender,
        makeLegacyTx(.{
            .to = recipient,
            .value = 100,
            .data = &[_]u8{},
            .gas_limit = 21_000,
            .gas_price = 1,
            .nonce = 0,
        }),
        defaultBlockContext(),
    );
    defer r1.deinit(std.testing.allocator);
    try std.testing.expect(r1.status.?.success);

    // Second tx with nonce 1
    var r2 = try tx_processor.processTransaction(
        std.testing.allocator,
        &sm,
        host,
        sender,
        makeLegacyTx(.{
            .to = recipient,
            .value = 200,
            .data = &[_]u8{},
            .gas_limit = 21_000,
            .gas_price = 1,
            .nonce = 1,
        }),
        defaultBlockContext(),
    );
    defer r2.deinit(std.testing.allocator);
    try std.testing.expect(r2.status.?.success);

    try std.testing.expectEqual(@as(u64, 2), try sm.getNonce(sender));
    try std.testing.expectEqual(@as(u256, 300), try sm.getBalance(recipient));
}

test "EIP-7623: refund cap and floor applied in correct order" {
    // Regression test for the EIP-7623 ordering bug: the refund cap must be
    // derived from the non-floored gas, the refund subtracted from it, and the
    // calldata floor applied as a hard lower bound LAST.
    //
    // Worked example (Prague, large zero-byte calldata so the floor dominates):
    //   gas_used_without_floor = intrinsic + gas_consumed = 100_000
    //   gas_floor              = 200_000
    //   refund_counter         = 50_000
    // Correct (London+): max_refund = 100_000/5 = 20_000;
    //   after refund = 100_000 - 20_000 = 80_000;
    //   effective = max(80_000, 200_000) = 200_000.
    // The buggy implementation floored first (200_000), capped the refund on the
    // floored value (200_000/5 = 40_000), and subtracted after flooring, yielding
    // 160_000 — below the mandated floor and undercharging the sender.
    try std.testing.expectEqual(
        @as(u64, 200_000),
        tx_processor.effectiveGasUsed(100_000, 200_000, 50_000, .PRAGUE),
    );

    // When the non-floored gas dominates, the floor is inert and the capped
    // refund reduces the bill normally.
    //   max_refund = 1_000_000/5 = 200_000; refund = min(50_000, 200_000) = 50_000;
    //   effective = max(1_000_000 - 50_000, 21_000) = 950_000.
    try std.testing.expectEqual(
        @as(u64, 950_000),
        tx_processor.effectiveGasUsed(1_000_000, 21_000, 50_000, .LONDON),
    );

    // The refund itself is capped at gas_used_without_floor/5 (London+).
    //   max_refund = 100_000/5 = 20_000; refund = min(50_000, 20_000) = 20_000;
    //   effective = max(100_000 - 20_000, 0) = 80_000.
    try std.testing.expectEqual(
        @as(u64, 80_000),
        tx_processor.effectiveGasUsed(100_000, 0, 50_000, .LONDON),
    );

    // Pre-London uses a 1/2 refund cap.
    //   max_refund = 100_000/2 = 50_000; refund = min(50_000, 50_000) = 50_000;
    //   effective = max(100_000 - 50_000, 0) = 50_000.
    try std.testing.expectEqual(
        @as(u64, 50_000),
        tx_processor.effectiveGasUsed(100_000, 0, 50_000, .ISTANBUL),
    );
}

test "EIP-7825 rejects every envelope above Osaka cap without state changes" {
    const sender = primitives.Address.fromU256(0x100);
    const recipient = primitives.Address.fromU256(0x200);
    for ([_]primitives.Receipt.TransactionType{ .legacy, .eip2930, .eip1559, .eip4844, .eip7702 }) |receipt_type| {
        var sm = try state_manager.StateManager.init(std.testing.allocator, null);
        defer sm.deinit();
        var adapter = host_adapter.HostAdapter{ .state = &sm };
        try sm.setBalance(sender, 1_000_000_000);
        const result = tx_processor.processTransactionWithOptions(
            std.testing.allocator,
            &sm,
            adapter.hostInterface(),
            sender,
            makeLegacyTx(.{ .to = recipient, .value = 1, .data = &.{}, .gas_limit = 16_777_217, .gas_price = 1, .nonce = 0 }),
            defaultBlockContext(),
            .{ .hardfork_override = .OSAKA, .receipt_type = receipt_type },
        );
        // Release an unexpected success so the regression reports the missing
        // validation independently of an allocation leak.
        if (result) |value| {
            var receipt = value;
            receipt.deinit(std.testing.allocator);
        } else |_| {}
        try std.testing.expectError(error.TransactionGasLimitExceeded, result);
        try std.testing.expectEqual(@as(u64, 0), try sm.getNonce(sender));
        try std.testing.expectEqual(@as(u256, 1_000_000_000), try sm.getBalance(sender));
        try std.testing.expectEqual(@as(u256, 0), try sm.getBalance(recipient));
    }
}

test "EIP-7825 accepts exact cap and preserves Prague gas limits" {
    for ([_]guillotine_mini.Hardfork{ .PRAGUE, .OSAKA }) |fork| {
        for ([_]u64{ 16_777_215, 16_777_216, 16_777_217 }) |gas_limit| {
            if (fork == .OSAKA and gas_limit > 16_777_216) continue;
            var sm = try state_manager.StateManager.init(std.testing.allocator, null);
            defer sm.deinit();
            var adapter = host_adapter.HostAdapter{ .state = &sm };
            const sender = primitives.Address.fromU256(0x100);
            const recipient = primitives.Address.fromU256(0x200);
            try sm.setBalance(sender, 1_000_000_000);
            var receipt = try tx_processor.processTransactionWithOptions(
                std.testing.allocator,
                &sm,
                adapter.hostInterface(),
                sender,
                makeLegacyTx(.{ .to = recipient, .value = 1, .data = &.{}, .gas_limit = gas_limit, .gas_price = 1, .nonce = 0 }),
                defaultBlockContext(),
                .{ .hardfork_override = fork },
            );
            defer receipt.deinit(std.testing.allocator);
            try std.testing.expect(receipt.status.?.success);
            try std.testing.expectEqual(@as(u256, 21_000), receipt.gas_used);
            try std.testing.expectEqual(@as(u256, 1), try sm.getBalance(recipient));
        }
    }
}

test "EIP-7825 non-validating simulation bypass retains the block gas bound" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();
    var adapter = host_adapter.HostAdapter{ .state = &sm };
    const sender = primitives.Address.fromU256(0x100);
    const recipient = primitives.Address.fromU256(0x200);
    try sm.setBalance(sender, 1_000_000_000);
    const tx = makeLegacyTx(.{ .to = recipient, .value = 1, .data = &.{}, .gas_limit = 16_777_217, .gas_price = 1, .nonce = 0 });
    const options = tx_processor.ProcessTransactionOptions{ .hardfork_override = .OSAKA, .skip_transaction_gas_limit_validation = true };
    var context = defaultBlockContext();
    context.block_gas_limit = 16_777_216;
    try std.testing.expectError(error.BlockGasLimitExceeded, tx_processor.processTransactionWithOptions(
        std.testing.allocator,
        &sm,
        adapter.hostInterface(),
        sender,
        tx,
        context,
        options,
    ));
    context.block_gas_limit = 30_000_000;
    var receipt = try tx_processor.processTransactionWithOptions(
        std.testing.allocator,
        &sm,
        adapter.hostInterface(),
        sender,
        tx,
        context,
        options,
    );
    defer receipt.deinit(std.testing.allocator);
    try std.testing.expect(receipt.status.?.success);
    try std.testing.expectEqual(@as(u256, 21_000), receipt.gas_used);
    try std.testing.expectEqual(@as(u256, 1), try sm.getBalance(recipient));
}

test "EIP-7939 CLZ opcode executes across zevm -> guillotine-mini on Osaka and rejects on Prague" {
    // Bytecode: PUSH1 0x00, CLZ (0x1e), PUSH1 0x00, MSTORE, PUSH1 0x20, PUSH1 0x00, RETURN
    const code = [_]u8{ 0x60, 0x00, 0x1e, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    const sender = primitives.Address.fromU256(0x101);
    const target = primitives.Address.fromU256(0x201);

    // Osaka: succeeds and returns 256 (0x100)
    {
        var sm = try state_manager.StateManager.init(std.testing.allocator, null);
        defer sm.deinit();
        var adapter = host_adapter.HostAdapter{ .state = &sm };
        try sm.setBalance(sender, 1_000_000_000);
        try sm.setCode(target, &code);
        var out: []u8 = &.{};
        defer std.testing.allocator.free(out);
        var receipt = try tx_processor.processTransactionWithOptions(
            std.testing.allocator,
            &sm,
            adapter.hostInterface(),
            sender,
            makeLegacyTx(.{ .to = target, .value = 0, .data = &.{}, .gas_limit = 100_000, .gas_price = 1, .nonce = 0 }),
            defaultBlockContext(),
            .{ .hardfork_override = .OSAKA, .capture_output = &out },
        );
        defer receipt.deinit(std.testing.allocator);
        try std.testing.expect(receipt.status.?.success);
        try std.testing.expectEqual(@as(usize, 32), out.len);
        try std.testing.expectEqual(@as(u256, 256), std.mem.readInt(u256, out[0..32], .big));
    }

    // Prague: CLZ (0x1e) is an invalid opcode
    {
        var sm = try state_manager.StateManager.init(std.testing.allocator, null);
        defer sm.deinit();
        var adapter = host_adapter.HostAdapter{ .state = &sm };
        try sm.setBalance(sender, 1_000_000_000);
        try sm.setCode(target, &code);
        var receipt = try tx_processor.processTransactionWithOptions(
            std.testing.allocator,
            &sm,
            adapter.hostInterface(),
            sender,
            makeLegacyTx(.{ .to = target, .value = 0, .data = &.{}, .gas_limit = 100_000, .gas_price = 1, .nonce = 0 }),
            defaultBlockContext(),
            .{ .hardfork_override = .PRAGUE },
        );
        defer receipt.deinit(std.testing.allocator);
        try std.testing.expect(!receipt.status.?.success);
    }
}

test "EIP-7951 P256VERIFY precompile executes across zevm -> guillotine-mini -> voltaire on Osaka" {
    const vector_hex =
        "4cee90eb86eaa050036147a12d49004b6b9c72bd725d39d4785011fe190f0b4d" ++
        "a73bd4903f0ce3b639bbbf6e8e80d16931ff4bcf5993d58468e8fb19086e8cac" ++
        "36dbcd03009df8c59286b162af3bd7fcc0450c9aa81be5d10d312af6c66b1d60" ++
        "4aebd3099c618202fcfe16ae7770b0c49ab5eadf74b754204a3bb6060e44eff3" ++
        "7618b065f9832de4ca6ca971a7a1adc826d0f7c00181a5fb2ddf79ae00b4e10e";
    var input: [160]u8 = undefined;
    _ = try std.fmt.hexToBytes(&input, vector_hex);

    const sender = primitives.Address.fromU256(0x102);
    const p256_addr = primitives.Address.fromU256(0x0100);

    // Osaka: valid signature returns 32-byte big-endian 1
    {
        var sm = try state_manager.StateManager.init(std.testing.allocator, null);
        defer sm.deinit();
        var adapter = host_adapter.HostAdapter{ .state = &sm };
        try sm.setBalance(sender, 1_000_000_000);
        var out: []u8 = &.{};
        defer std.testing.allocator.free(out);
        var receipt = try tx_processor.processTransactionWithOptions(
            std.testing.allocator,
            &sm,
            adapter.hostInterface(),
            sender,
            makeLegacyTx(.{ .to = p256_addr, .value = 0, .data = &input, .gas_limit = 100_000, .gas_price = 1, .nonce = 0 }),
            defaultBlockContext(),
            .{ .hardfork_override = .OSAKA, .capture_output = &out },
        );
        defer receipt.deinit(std.testing.allocator);
        try std.testing.expect(receipt.status.?.success);
        try std.testing.expectEqual(@as(usize, 32), out.len);
        try std.testing.expectEqual(@as(u256, 1), std.mem.readInt(u256, out[0..32], .big));
    }

    // Prague: 0x0100 is not a precompile (empty account call returns empty output)
    {
        var sm = try state_manager.StateManager.init(std.testing.allocator, null);
        defer sm.deinit();
        var adapter = host_adapter.HostAdapter{ .state = &sm };
        try sm.setBalance(sender, 1_000_000_000);
        var out: []u8 = &.{};
        defer std.testing.allocator.free(out);
        var receipt = try tx_processor.processTransactionWithOptions(
            std.testing.allocator,
            &sm,
            adapter.hostInterface(),
            sender,
            makeLegacyTx(.{ .to = p256_addr, .value = 0, .data = &input, .gas_limit = 100_000, .gas_price = 1, .nonce = 0 }),
            defaultBlockContext(),
            .{ .hardfork_override = .PRAGUE, .capture_output = &out },
        );
        defer receipt.deinit(std.testing.allocator);
        try std.testing.expect(receipt.status.?.success);
        try std.testing.expectEqual(@as(usize, 0), out.len);
    }
}

test "dynamic fee caps near u256 max return an error instead of overflowing (#55)" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var adapter = host_adapter.HostAdapter{ .state = &sm };
    const sender = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 };
    const recipient = primitives.Address{ .bytes = [_]u8{0x02} ++ [_]u8{0} ** 19 };
    var block_ctx = defaultBlockContext();
    block_ctx.block_base_fee = 100;

    const max = std.math.maxInt(u256);
    try sm.setBalance(sender, max);
    try sm.setNonce(sender, 0);

    // base_fee + max_priority_fee_per_gas exceeds u256; so does fee cap * gas.
    const result = tx_processor.processTransactionWithOptions(
        std.testing.allocator,
        &sm,
        adapter.hostInterface(),
        sender,
        makeLegacyTx(.{
            .to = recipient,
            .value = 0,
            .data = &[_]u8{},
            .gas_limit = 21_000,
            .gas_price = max,
            .nonce = 0,
        }),
        block_ctx,
        .{ .receipt_type = .eip1559, .max_fee_per_gas = max, .max_priority_fee_per_gas = max, .hardfork_override = .LONDON },
    );
    try std.testing.expectError(tx_processor.TxError.InsufficientBalance, result);
    try std.testing.expectEqual(@as(u64, 0), try sm.getNonce(sender));
    try std.testing.expectEqual(@as(u256, max), try sm.getBalance(sender));
}
