const std = @import("std");
const block_builder = @import("block_builder.zig");
const genesis_alloc = @import("genesis_alloc.zig");
const primitives = @import("primitives");
const state_manager = @import("state-manager");

test "applyGenesisJson seeds balance nonce code and storage" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    const count = try genesis_alloc.applyGenesisJson(std.testing.allocator, &sm,
        \\{
        \\  "alloc": {
        \\    "0000000000000000000000000000000000000001": {
        \\      "balance": "0x2a",
        \\      "nonce": "0x7",
        \\      "code": "0x6001",
        \\      "storage": {
        \\        "0x00": "0x05",
        \\        "1": "9"
        \\      }
        \\    },
        \\    "0x0000000000000000000000000000000000000002": {
        \\      "balance": 10
        \\    }
        \\  }
        \\}
    );

    try std.testing.expectEqual(@as(usize, 2), count);

    const account = try primitives.Address.fromHex("0x0000000000000000000000000000000000000001");
    try std.testing.expectEqual(@as(u256, 42), try sm.getBalance(account));
    try std.testing.expectEqual(@as(u64, 7), try sm.getNonce(account));
    try std.testing.expectEqual(@as(u256, 5), try sm.getStorage(account, 0));
    try std.testing.expectEqual(@as(u256, 9), try sm.getStorage(account, 1));

    const code = try sm.getCode(account);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x60, 0x01 }, code);

    const decimal_account = try primitives.Address.fromHex("0x0000000000000000000000000000000000000002");
    try std.testing.expectEqual(@as(u256, 10), try sm.getBalance(decimal_account));
    try std.testing.expectEqual(@as(u64, 0), try sm.getNonce(decimal_account));
}

test "applyGenesisJson accepts legacy wei balances and key metadata" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    const count = try genesis_alloc.applyGenesisJson(std.testing.allocator, &sm,
        \\{
        \\  "alloc": {
        \\    "0x0000000000000000000000000000000000000006": {
        \\      "wei": "123",
        \\      "secretKey": "0x00"
        \\    }
        \\  }
        \\}
    );

    try std.testing.expectEqual(@as(usize, 1), count);

    const account = try primitives.Address.fromHex("0x0000000000000000000000000000000000000006");
    try std.testing.expectEqual(@as(u256, 123), try sm.getBalance(account));
}

test "loadGenesisJson parses genesis header fields" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var loaded = try genesis_alloc.loadGenesisJson(std.testing.allocator, &sm,
        \\{
        \\  "parentHash": "0x1111111111111111111111111111111111111111111111111111111111111111",
        \\  "coinbase": "0x00000000000000000000000000000000000000aa",
        \\  "difficulty": "0x20",
        \\  "gasLimit": "0x100000",
        \\  "timestamp": "0x1234",
        \\  "extraData": "0x68697665",
        \\  "mixHash": "0x2222222222222222222222222222222222222222222222222222222222222222",
        \\  "nonce": "0x0102030405060708",
        \\  "baseFeePerGas": "0x7",
        \\  "blobGasUsed": "0x8",
        \\  "excessBlobGas": "0x9",
        \\  "parentBeaconBlockRoot": "0x3333333333333333333333333333333333333333333333333333333333333333",
        \\  "alloc": {}
        \\}
    );
    defer loaded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), loaded.account_count);
    try std.testing.expectEqual(try primitives.Address.fromHex("0x00000000000000000000000000000000000000aa"), loaded.header.beneficiary.?);
    try std.testing.expectEqual(@as(u256, 0x20), loaded.header.difficulty);
    try std.testing.expectEqual(@as(u64, 0x100000), loaded.header.gas_limit.?);
    try std.testing.expectEqual(@as(u64, 0x1234), loaded.header.timestamp);
    try std.testing.expectEqualSlices(u8, "hive", loaded.header.extraData());
    try std.testing.expectEqual(@as(u256, 7), loaded.header.base_fee_per_gas.?);
    try std.testing.expectEqual(@as(u64, 8), loaded.header.blob_gas_used.?);
    try std.testing.expectEqual(@as(u64, 9), loaded.header.excess_blob_gas.?);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 }, &loaded.header.nonce);
}

test "loadGenesisJson treats null optional header fields as absent" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var loaded = try genesis_alloc.loadGenesisJson(std.testing.allocator, &sm,
        \\{
        \\  "baseFeePerGas": null,
        \\  "blobGasUsed": null,
        \\  "excessBlobGas": null,
        \\  "withdrawalsRoot": null,
        \\  "parentBeaconBlockRoot": null,
        \\  "alloc": {}
        \\}
    );
    defer loaded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), loaded.account_count);
    try std.testing.expectEqual(null, loaded.header.base_fee_per_gas);
    try std.testing.expectEqual(null, loaded.header.blob_gas_used);
    try std.testing.expectEqual(null, loaded.header.excess_blob_gas);
    try std.testing.expectEqual(null, loaded.header.withdrawals_root);
    try std.testing.expectEqual(null, loaded.header.parent_beacon_block_root);
}

test "applyGenesisJson accepts empty accounts and produces a state root" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    const count = try genesis_alloc.applyGenesisJson(std.testing.allocator, &sm,
        \\{
        \\  "alloc": {
        \\    "0x0000000000000000000000000000000000000003": {}
        \\  }
        \\}
    );

    try std.testing.expectEqual(@as(usize, 1), count);

    const account = try primitives.Address.fromHex("0x0000000000000000000000000000000000000003");
    try std.testing.expectEqual(@as(u256, 0), try sm.getBalance(account));
    try std.testing.expectEqual(@as(u64, 0), try sm.getNonce(account));

    _ = try block_builder.computeStateRoot(std.testing.allocator, &sm);
}

test "applyGenesisJson rejects malformed allocation data" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    try std.testing.expectError(
        error.InvalidGenesisAlloc,
        genesis_alloc.applyGenesisJson(std.testing.allocator, &sm, "{}"),
    );
    try std.testing.expectError(
        error.InvalidGenesisAlloc,
        genesis_alloc.applyGenesisJson(std.testing.allocator, &sm,
            \\{
            \\  "alloc": {
            \\    "0x0000000000000000000000000000000000000004": {
            \\      "storageRoot": "0x00"
            \\    }
            \\  }
            \\}
        ),
    );
    try std.testing.expectError(
        error.InvalidGenesisAlloc,
        genesis_alloc.applyGenesisJson(std.testing.allocator, &sm,
            \\{
            \\  "alloc": {
            \\    "0x0000000000000000000000000000000000000005": {
            \\      "code": "0x0"
            \\    }
            \\  }
            \\}
        ),
    );
}
