const std = @import("std");
const genesis = @import("genesis.zig");
const primitives = @import("primitives");
const state_manager = @import("state-manager");
const blockchain_mod = @import("blockchain");
const database = @import("database/root.zig");

// ============================================================================
// Dev Account Constants Tests
// ============================================================================

test "DEV_ACCOUNTS has exactly 10 entries" {
    try std.testing.expectEqual(@as(usize, 10), genesis.DEV_ACCOUNTS.len);
}

test "DEV_ACCOUNTS[0] address matches well-known Hardhat account 0" {
    const expected = primitives.Address.Address{ .bytes = .{
        0xf3, 0x9f, 0xd6, 0xe5, 0x1a, 0xad, 0x88, 0xf6,
        0xf4, 0xce, 0x6a, 0xb8, 0x82, 0x72, 0x79, 0xcf,
        0xff, 0xb9, 0x22, 0x66,
    } };
    try std.testing.expect(primitives.Address.Address.equals(genesis.DEV_ACCOUNTS[0].address, expected));
}

test "DEV_ACCOUNTS[0] private key matches well-known Hardhat key 0" {
    const expected = [32]u8{
        0xac, 0x09, 0x74, 0xbe, 0xc3, 0x9a, 0x17, 0xe3,
        0x6b, 0xa4, 0xa6, 0xb4, 0xd2, 0x38, 0xff, 0x94,
        0x4b, 0xac, 0xb4, 0x78, 0xcb, 0xed, 0x5e, 0xfc,
        0xae, 0x78, 0x4d, 0x7b, 0xf4, 0xf2, 0xff, 0x80,
    };
    try std.testing.expectEqualSlices(u8, &expected, &genesis.DEV_ACCOUNTS[0].private_key);
}

test "all DEV_ACCOUNTS have unique addresses" {
    for (0..genesis.DEV_ACCOUNTS.len) |i| {
        for (i + 1..genesis.DEV_ACCOUNTS.len) |j| {
            try std.testing.expect(!primitives.Address.Address.equals(
                genesis.DEV_ACCOUNTS[i].address,
                genesis.DEV_ACCOUNTS[j].address,
            ));
        }
    }
}

// ============================================================================
// Genesis Config Constants Tests
// ============================================================================

test "CHAIN_ID is 31337" {
    try std.testing.expectEqual(@as(u64, 31337), genesis.CHAIN_ID);
}

test "DEV_BALANCE is 10000 ETH in wei" {
    const expected: u256 = 10_000 * 1_000_000_000_000_000_000;
    try std.testing.expectEqual(expected, genesis.DEV_BALANCE);
}

test "DEFAULT_GAS_LIMIT is 30 million" {
    try std.testing.expectEqual(@as(u64, 30_000_000), genesis.DEFAULT_GAS_LIMIT);
}

test "DEFAULT_BASE_FEE is 1 gwei" {
    try std.testing.expectEqual(@as(u256, 1_000_000_000), genesis.DEFAULT_BASE_FEE);
}

// ============================================================================
// Genesis Block Construction Tests
// ============================================================================

test "createGenesisBlock returns block with number 0" {
    const allocator = std.testing.allocator;
    const block = try genesis.createGenesisBlock(allocator, genesis.DEVNET_CHAIN_ID);
    try std.testing.expectEqual(@as(u64, 0), block.header.number);
}

test "createGenesisBlock has correct gas limit" {
    const allocator = std.testing.allocator;
    const block = try genesis.createGenesisBlock(allocator, genesis.DEVNET_CHAIN_ID);
    try std.testing.expectEqual(@as(u64, 30_000_000), block.header.gas_limit);
}

test "createGenesisBlock has correct base fee" {
    const allocator = std.testing.allocator;
    const block = try genesis.createGenesisBlock(allocator, genesis.DEVNET_CHAIN_ID);
    try std.testing.expectEqual(@as(u256, 1_000_000_000), block.header.base_fee_per_gas.?);
}

test "createGenesisBlock has zero parent hash" {
    const allocator = std.testing.allocator;
    const block = try genesis.createGenesisBlock(allocator, genesis.DEVNET_CHAIN_ID);
    try std.testing.expect(primitives.Hash.isZero(&block.header.parent_hash));
}

test "createGenesisBlock has zero difficulty" {
    const allocator = std.testing.allocator;
    const block = try genesis.createGenesisBlock(allocator, genesis.DEVNET_CHAIN_ID);
    try std.testing.expectEqual(@as(u256, 0), block.header.difficulty);
}

test "createGenesisBlock has beneficiary set to account 0" {
    const allocator = std.testing.allocator;
    const block = try genesis.createGenesisBlock(allocator, genesis.DEVNET_CHAIN_ID);
    try std.testing.expect(primitives.Address.Address.equals(
        block.header.beneficiary,
        genesis.DEV_ACCOUNTS[0].address,
    ));
}

test "createGenesisBlock has empty transactions root" {
    const allocator = std.testing.allocator;
    const block = try genesis.createGenesisBlock(allocator, genesis.DEVNET_CHAIN_ID);
    try std.testing.expect(primitives.Hash.equals(
        &block.header.transactions_root,
        &primitives.BlockHeader.EMPTY_TRANSACTIONS_ROOT,
    ));
}

test "createGenesisBlock has empty ommers hash" {
    const allocator = std.testing.allocator;
    const block = try genesis.createGenesisBlock(allocator, genesis.DEVNET_CHAIN_ID);
    try std.testing.expect(primitives.Hash.equals(
        &block.header.ommers_hash,
        &primitives.BlockHeader.EMPTY_OMMERS_HASH,
    ));
}

test "createGenesisBlock has non-zero hash" {
    const allocator = std.testing.allocator;
    const block = try genesis.createGenesisBlock(allocator, genesis.DEVNET_CHAIN_ID);
    try std.testing.expect(!primitives.Hash.isZero(&block.hash));
}

test "createGenesisBlock has non-zero timestamp" {
    const allocator = std.testing.allocator;
    const block = try genesis.createGenesisBlock(allocator, genesis.DEVNET_CHAIN_ID);
    try std.testing.expect(block.header.timestamp > 0);
}

test "createGenesisBlock has empty body" {
    const allocator = std.testing.allocator;
    const block = try genesis.createGenesisBlock(allocator, genesis.DEVNET_CHAIN_ID);
    try std.testing.expectEqual(@as(usize, 0), block.body.transactions.len);
    try std.testing.expectEqual(@as(usize, 0), block.body.ommers.len);
}

// ============================================================================
// State Initialization Tests
// ============================================================================

test "initGenesisState funds all 10 dev accounts" {
    const allocator = std.testing.allocator;
    var db = try database.Database.init(allocator, null);
    defer db.deinit(allocator);

    _ = try genesis.initGenesisState(allocator, &db, .devnet, null);

    for (&genesis.DEV_ACCOUNTS) |*account| {
        const balance = try db.state.getBalance(account.address);
        try std.testing.expectEqual(genesis.DEV_BALANCE, balance);
    }
}

test "initGenesisState sets nonce 0 for all dev accounts" {
    const allocator = std.testing.allocator;
    var db = try database.Database.init(allocator, null);
    defer db.deinit(allocator);

    _ = try genesis.initGenesisState(allocator, &db, .devnet, null);

    for (&genesis.DEV_ACCOUNTS) |*account| {
        const nonce = try db.state.getNonce(account.address);
        try std.testing.expectEqual(@as(u64, 0), nonce);
    }
}

test "initGenesisState does not affect non-dev addresses" {
    const allocator = std.testing.allocator;
    var db = try database.Database.init(allocator, null);
    defer db.deinit(allocator);

    _ = try genesis.initGenesisState(allocator, &db, .devnet, null);

    const random_addr = primitives.Address.Address{ .bytes = .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01 } };
    const balance = try db.state.getBalance(random_addr);
    try std.testing.expectEqual(@as(u256, 0), balance);
}

// ============================================================================
// Full Node Init Integration Tests
// ============================================================================

test "initGenesis stores genesis block in blockchain" {
    const allocator = std.testing.allocator;
    var db = try database.Database.init(allocator, null);
    defer db.deinit(allocator);
    var chain = try blockchain_mod.Blockchain.init(allocator, null);
    defer chain.deinit();

    _ = try genesis.initGenesis(allocator, &db, &chain, genesis.DEVNET_CHAIN_ID, null);

    const head = chain.getHeadBlockNumber();
    try std.testing.expect(head != null);
    try std.testing.expectEqual(@as(u64, 0), head.?);
}

test "initGenesis records genesis hash in block_hashes" {
    const allocator = std.testing.allocator;
    var db = try database.Database.init(allocator, null);
    defer db.deinit(allocator);
    var chain = try blockchain_mod.Blockchain.init(allocator, null);
    defer chain.deinit();

    const result = try genesis.initGenesis(allocator, &db, &chain, genesis.DEVNET_CHAIN_ID, null);

    const hash = db.block_hashes.get(0);
    try std.testing.expect(hash != null);
    try std.testing.expect(primitives.Hash.equals(&hash.?, &result.genesis_hash));
}

test "initGenesis returns correct chain_id" {
    const allocator = std.testing.allocator;
    var db = try database.Database.init(allocator, null);
    defer db.deinit(allocator);
    var chain = try blockchain_mod.Blockchain.init(allocator, null);
    defer chain.deinit();

    const result = try genesis.initGenesis(allocator, &db, &chain, genesis.DEVNET_CHAIN_ID, null);
    try std.testing.expectEqual(@as(u64, 31337), result.chain_id);
}

test "initGenesis returns genesis hash" {
    const allocator = std.testing.allocator;
    var db = try database.Database.init(allocator, null);
    defer db.deinit(allocator);
    var chain = try blockchain_mod.Blockchain.init(allocator, null);
    defer chain.deinit();

    const result = try genesis.initGenesis(allocator, &db, &chain, genesis.DEVNET_CHAIN_ID, null);
    try std.testing.expect(!primitives.Hash.isZero(&result.genesis_hash));
}

test "initGenesis returns all 10 managed accounts" {
    const allocator = std.testing.allocator;
    var db = try database.Database.init(allocator, null);
    defer db.deinit(allocator);
    var chain = try blockchain_mod.Blockchain.init(allocator, null);
    defer chain.deinit();

    const result = try genesis.initGenesis(allocator, &db, &chain, genesis.DEVNET_CHAIN_ID, null);
    try std.testing.expectEqual(@as(usize, 10), result.managed_accounts.len);
    try std.testing.expect(primitives.Address.Address.equals(
        result.managed_accounts[0].address,
        genesis.DEV_ACCOUNTS[0].address,
    ));
}

test "initGenesis returns coinbase as first dev account" {
    const allocator = std.testing.allocator;
    var db = try database.Database.init(allocator, null);
    defer db.deinit(allocator);
    var chain = try blockchain_mod.Blockchain.init(allocator, null);
    defer chain.deinit();

    const result = try genesis.initGenesis(allocator, &db, &chain, genesis.DEVNET_CHAIN_ID, null);
    try std.testing.expect(primitives.Address.Address.equals(
        result.coinbase,
        genesis.DEV_ACCOUNTS[0].address,
    ));
}

test "initGenesis balances are queryable after init" {
    const allocator = std.testing.allocator;
    var db = try database.Database.init(allocator, null);
    defer db.deinit(allocator);
    var chain = try blockchain_mod.Blockchain.init(allocator, null);
    defer chain.deinit();

    _ = try genesis.initGenesis(allocator, &db, &chain, genesis.DEVNET_CHAIN_ID, null);

    for (&genesis.DEV_ACCOUNTS) |*account| {
        const balance = try db.state.getBalance(account.address);
        try std.testing.expectEqual(genesis.DEV_BALANCE, balance);
    }
}

test "initGenesis genesis block retrievable by hash from blockchain" {
    const allocator = std.testing.allocator;
    var db = try database.Database.init(allocator, null);
    defer db.deinit(allocator);
    var chain = try blockchain_mod.Blockchain.init(allocator, null);
    defer chain.deinit();

    const result = try genesis.initGenesis(allocator, &db, &chain, genesis.DEVNET_CHAIN_ID, null);

    const block = try chain.getBlockByHash(result.genesis_hash);
    try std.testing.expect(block != null);
    try std.testing.expectEqual(@as(u64, 0), block.?.header.number);
}

test "initGenesis genesis block retrievable by number from blockchain" {
    const allocator = std.testing.allocator;
    var db = try database.Database.init(allocator, null);
    defer db.deinit(allocator);
    var chain = try blockchain_mod.Blockchain.init(allocator, null);
    defer chain.deinit();

    _ = try genesis.initGenesis(allocator, &db, &chain, genesis.DEVNET_CHAIN_ID, null);

    const block = try chain.getBlockByNumber(0);
    try std.testing.expect(block != null);
    try std.testing.expectEqual(@as(u64, 0), block.?.header.number);
}

// ============================================================================
// Banner Output Tests
// ============================================================================

test "printBanner writes account addresses and private keys" {
    const allocator = std.testing.allocator;
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);

    try genesis.printBanner(buf.writer(allocator));
    const output = buf.items;

    try std.testing.expect(std.mem.indexOf(u8, output, "f39fd6e51aad88f6f4ce6ab8827279cfffb92266") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "10000 ETH") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "31337") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Available Accounts") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Private Keys") != null);
}
