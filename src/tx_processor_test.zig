const std = @import("std");
const primitives = @import("primitives");
const state_manager = @import("state-manager");
const guillotine_mini = @import("guillotine_mini");
const tx_processor = @import("tx_processor.zig");
const host_adapter = @import("host_adapter.zig");

fn makeLegacyTx(params: struct {
    to: ?primitives.Address,
    value: u256,
    data: []const u8,
    gas_limit: u64,
    gas_price: u256,
    nonce: u64,
}) tx_processor.Transaction {
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
        .block_number = 1,
        .block_timestamp = 1000,
        .block_difficulty = 0,
        .block_prevrandao = 0,
        .block_coinbase = primitives.Address{ .bytes = [_]u8{0xCB} ++ [_]u8{0} ** 19 },
        .block_gas_limit = 30_000_000,
        .block_base_fee = 0,
        .blob_base_fee = 0,
    };
}

test "intrinsic gas calculation" {
    try std.testing.expectEqual(@as(u64, 21_000), tx_processor.intrinsicGas(&[_]u8{}, false));
    try std.testing.expectEqual(@as(u64, 21_000 + 32_000), tx_processor.intrinsicGas(&[_]u8{}, true));
    try std.testing.expectEqual(@as(u64, 21_000 + 16 + 4 + 16), tx_processor.intrinsicGas(&[_]u8{ 0x01, 0x00, 0x02 }, false));
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
