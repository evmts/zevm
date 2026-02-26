const std = @import("std");
const primitives = @import("primitives");
const state_manager = @import("state-manager");
const guillotine_mini = @import("guillotine_mini");
const block_builder = @import("block_builder.zig");
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
}

test "buildBlock drops invalid tx and keeps valid order" {
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
                .nonce = 1, // invalid (nonce mismatch)
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
                .nonce = 0,
            }),
        },
    };

    var result = try block_builder.buildBlock(
        std.testing.allocator,
        &sm,
        host,
        &txs,
        blockContextWithGasLimit(30_000_000),
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.receipts.len);
    try std.testing.expectEqual(@as(u32, 0), result.receipts[0].transaction_index);
    try std.testing.expectEqual(sender, result.receipts[0].sender);
}
