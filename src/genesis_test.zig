const std = @import("std");
const primitives = @import("primitives");
const state_manager = @import("state-manager");
const blockchain_mod = @import("blockchain");
const genesis = @import("genesis.zig");
const database = @import("database/root.zig");

// ── Dev Account Constants Tests ───────────────────────────────────────

test "DEV_ACCOUNTS has exactly 10 entries" {
    try std.testing.expectEqual(@as(usize, 10), genesis.DEV_ACCOUNTS.len);
}

test "DEV_ACCOUNTS[0] address matches well-known Hardhat account 0" {
    const expected = try primitives.Address.fromHex("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
    try std.testing.expectEqualSlices(u8, &expected.bytes, &genesis.DEV_ACCOUNTS[0].address.bytes);
}

test "DEV_ACCOUNTS[0] private key matches well-known Hardhat key 0" {
    const expected_hex = "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
    var expected: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&expected, expected_hex) catch unreachable;
    try std.testing.expectEqualSlices(u8, &expected, &genesis.DEV_ACCOUNTS[0].private_key);
}

test "all DEV_ACCOUNTS have unique addresses" {
    for (genesis.DEV_ACCOUNTS, 0..) |account_a, i| {
        for (genesis.DEV_ACCOUNTS[i + 1 ..]) |account_b| {
            try std.testing.expect(!std.mem.eql(u8, &account_a.address.bytes, &account_b.address.bytes));
        }
    }
}

test "private keys derive to correct addresses" {
    const crypto = @import("crypto");
    for (&genesis.DEV_ACCOUNTS) |*account| {
        const signer = try crypto.signers.LocalSigner.init(account.private_key);
        try std.testing.expectEqualSlices(u8, &account.address.bytes, &signer.address.bytes);
    }
}

// ── Genesis Config Constants Tests ────────────────────────────────────

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

// ── Genesis Block Construction Tests ──────────────────────────────────

test "createGenesisBlock returns block with number 0" {
    const block = try genesis.createGenesisBlock(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 0), block.header.number);
}

test "createGenesisBlock has correct gas limit" {
    const block = try genesis.createGenesisBlock(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 30_000_000), block.header.gas_limit);
}

test "createGenesisBlock has correct base fee" {
    const block = try genesis.createGenesisBlock(std.testing.allocator);
    try std.testing.expect(block.header.base_fee_per_gas != null);
    try std.testing.expectEqual(@as(u256, 1_000_000_000), block.header.base_fee_per_gas.?);
}

test "createGenesisBlock has zero parent hash" {
    const block = try genesis.createGenesisBlock(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &primitives.Hash.ZERO, &block.header.parent_hash);
}

test "createGenesisBlock has zero difficulty" {
    const block = try genesis.createGenesisBlock(std.testing.allocator);
    try std.testing.expectEqual(@as(u256, 0), block.header.difficulty);
}

test "createGenesisBlock has beneficiary set to account 0" {
    const block = try genesis.createGenesisBlock(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &genesis.DEV_ACCOUNTS[0].address.bytes, &block.header.beneficiary.bytes);
}

test "createGenesisBlock has empty transactions root" {
    const block = try genesis.createGenesisBlock(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &primitives.BlockHeader.EMPTY_TRANSACTIONS_ROOT, &block.header.transactions_root);
}

test "createGenesisBlock has empty ommers hash" {
    const block = try genesis.createGenesisBlock(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &primitives.BlockHeader.EMPTY_OMMERS_HASH, &block.header.ommers_hash);
}

test "createGenesisBlock has non-zero hash" {
    const block = try genesis.createGenesisBlock(std.testing.allocator);
    try std.testing.expect(!std.mem.eql(u8, &primitives.Hash.ZERO, &block.hash));
}

test "createGenesisBlock has non-zero timestamp" {
    const block = try genesis.createGenesisBlock(std.testing.allocator);
    try std.testing.expect(block.header.timestamp > 0);
}

test "createGenesisBlock has empty body" {
    const block = try genesis.createGenesisBlock(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), block.body.transactions.len);
    try std.testing.expectEqual(@as(usize, 0), block.body.ommers.len);
}

// ── State Initialization Tests ────────────────────────────────────────

test "initGenesisState funds all 10 dev accounts" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    try genesis.initGenesisState(&sm);

    for (&genesis.DEV_ACCOUNTS) |*account| {
        const balance = try sm.getBalance(account.address);
        try std.testing.expectEqual(genesis.DEV_BALANCE, balance);
    }
}

test "initGenesisState sets nonce 0 for all dev accounts" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    try genesis.initGenesisState(&sm);

    for (&genesis.DEV_ACCOUNTS) |*account| {
        const nonce = try sm.getNonce(account.address);
        try std.testing.expectEqual(@as(u64, 0), nonce);
    }
}

test "initGenesisState does not affect non-dev addresses" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    try genesis.initGenesisState(&sm);

    const random_addr = try primitives.Address.fromHex("0x0000000000000000000000000000000000000001");
    const balance = try sm.getBalance(random_addr);
    try std.testing.expectEqual(@as(u256, 0), balance);
}

// ── Full Integration Tests ────────────────────────────────────────────

test "initGenesis stores genesis block in blockchain" {
    var db = try database.Database.init(std.testing.allocator);
    defer db.deinit(std.testing.allocator);

    var chain = try blockchain_mod.Blockchain.init(std.testing.allocator, null);
    defer chain.deinit();

    _ = try genesis.initGenesis(std.testing.allocator, &db, &chain);

    const head = chain.getHeadBlockNumber();
    try std.testing.expect(head != null);
    try std.testing.expectEqual(@as(u64, 0), head.?);
}

test "initGenesis records genesis hash in block_hashes" {
    var db = try database.Database.init(std.testing.allocator);
    defer db.deinit(std.testing.allocator);

    var chain = try blockchain_mod.Blockchain.init(std.testing.allocator, null);
    defer chain.deinit();

    const result = try genesis.initGenesis(std.testing.allocator, &db, &chain);

    const hash = db.block_hashes.get(0);
    try std.testing.expect(hash != null);
    try std.testing.expectEqualSlices(u8, &result.genesis_hash, &hash.?);
}

test "initGenesis returns correct chain_id" {
    var db = try database.Database.init(std.testing.allocator);
    defer db.deinit(std.testing.allocator);

    var chain = try blockchain_mod.Blockchain.init(std.testing.allocator, null);
    defer chain.deinit();

    const result = try genesis.initGenesis(std.testing.allocator, &db, &chain);
    try std.testing.expectEqual(@as(u64, 31337), result.chain_id);
}

test "initGenesis returns genesis hash" {
    var db = try database.Database.init(std.testing.allocator);
    defer db.deinit(std.testing.allocator);

    var chain = try blockchain_mod.Blockchain.init(std.testing.allocator, null);
    defer chain.deinit();

    const result = try genesis.initGenesis(std.testing.allocator, &db, &chain);
    try std.testing.expect(!std.mem.eql(u8, &primitives.Hash.ZERO, &result.genesis_hash));
}

test "initGenesis returns all 10 managed accounts" {
    var db = try database.Database.init(std.testing.allocator);
    defer db.deinit(std.testing.allocator);

    var chain = try blockchain_mod.Blockchain.init(std.testing.allocator, null);
    defer chain.deinit();

    const result = try genesis.initGenesis(std.testing.allocator, &db, &chain);
    try std.testing.expectEqual(@as(usize, 10), result.managed_accounts.len);
    try std.testing.expectEqualSlices(u8, &genesis.DEV_ACCOUNTS[0].address.bytes, &result.managed_accounts[0].address.bytes);
}

test "initGenesis returns coinbase as first dev account" {
    var db = try database.Database.init(std.testing.allocator);
    defer db.deinit(std.testing.allocator);

    var chain = try blockchain_mod.Blockchain.init(std.testing.allocator, null);
    defer chain.deinit();

    const result = try genesis.initGenesis(std.testing.allocator, &db, &chain);
    try std.testing.expectEqualSlices(u8, &genesis.DEV_ACCOUNTS[0].address.bytes, &result.coinbase.bytes);
}

test "initGenesis balances are queryable after init" {
    var db = try database.Database.init(std.testing.allocator);
    defer db.deinit(std.testing.allocator);

    var chain = try blockchain_mod.Blockchain.init(std.testing.allocator, null);
    defer chain.deinit();

    _ = try genesis.initGenesis(std.testing.allocator, &db, &chain);

    for (&genesis.DEV_ACCOUNTS) |*account| {
        const balance = try db.state.getBalance(account.address);
        try std.testing.expectEqual(genesis.DEV_BALANCE, balance);
    }
}

// ── Banner Output Test ────────────────────────────────────────────────

test "printBanner writes account addresses and private keys" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();

    try genesis.printBanner(buf.writer());
    const output = buf.items;

    // Check banner contains key sections
    try std.testing.expect(std.mem.indexOf(u8, output, "Available Accounts") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Private Keys") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Wallet") != null);

    // Check chain ID
    try std.testing.expect(std.mem.indexOf(u8, output, "31337") != null);

    // Check first account address (lowercase hex)
    try std.testing.expect(std.mem.indexOf(u8, output, "f39fd6e51aad88f6f4ce6ab8827279cfffb92266") != null);

    // Check first private key (lowercase hex)
    try std.testing.expect(std.mem.indexOf(u8, output, "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80") != null);

    // Check balance label
    try std.testing.expect(std.mem.indexOf(u8, output, "10000 ETH") != null);

    // Check mnemonic
    try std.testing.expect(std.mem.indexOf(u8, output, genesis.MNEMONIC) != null);

    // Check gas config
    try std.testing.expect(std.mem.indexOf(u8, output, "30000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "1 gwei") != null);
}
