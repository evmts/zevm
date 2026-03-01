const std = @import("std");
const state_manager = @import("state-manager");
const primitives = @import("primitives");
const blockchain = @import("blockchain");
const txpool = @import("txpool");
const crypto = @import("crypto");
const mining = @import("../mining.zig");
const genesis = @import("../genesis.zig");

/// Hardhat/Anvil-style deterministic dev accounts.
/// These are the same 10 accounts used by Hardhat/Anvil (derived from mnemonic
/// "test test test test test test test test test test test junk").
pub const DEFAULT_DEV_ACCOUNTS = [10]primitives.Address{
    genesis.DEV_ACCOUNTS[0].address,
    genesis.DEV_ACCOUNTS[1].address,
    genesis.DEV_ACCOUNTS[2].address,
    genesis.DEV_ACCOUNTS[3].address,
    genesis.DEV_ACCOUNTS[4].address,
    genesis.DEV_ACCOUNTS[5].address,
    genesis.DEV_ACCOUNTS[6].address,
    genesis.DEV_ACCOUNTS[7].address,
    genesis.DEV_ACCOUNTS[8].address,
    genesis.DEV_ACCOUNTS[9].address,
};

pub const DEFAULT_DEV_PRIVATE_KEYS = [10]crypto.Crypto.PrivateKey{
    genesis.DEV_ACCOUNTS[0].private_key,
    genesis.DEV_ACCOUNTS[1].private_key,
    genesis.DEV_ACCOUNTS[2].private_key,
    genesis.DEV_ACCOUNTS[3].private_key,
    genesis.DEV_ACCOUNTS[4].private_key,
    genesis.DEV_ACCOUNTS[5].private_key,
    genesis.DEV_ACCOUNTS[6].private_key,
    genesis.DEV_ACCOUNTS[7].private_key,
    genesis.DEV_ACCOUNTS[8].private_key,
    genesis.DEV_ACCOUNTS[9].private_key,
};

/// Default initial balance: 10,000 ETH in wei
pub const DEFAULT_BALANCE: u256 = 10_000 * 1_000_000_000_000_000_000;

/// Default chain ID matching Hardhat/Anvil
pub const DEFAULT_CHAIN_ID: u64 = 31337;

/// Default gas price: 2 gwei
pub const DEFAULT_GAS_PRICE: u256 = 2_000_000_000;

/// Default base fee: 1 gwei (EIP-1559)
pub const DEFAULT_BASE_FEE: u256 = 1_000_000_000;

/// Default blob base fee: 1 wei (EIP-4844 minimum)
pub const DEFAULT_BLOB_BASE_FEE: u256 = 1;

/// Default max priority fee: 1 gwei
pub const DEFAULT_MAX_PRIORITY_FEE: u256 = 1_000_000_000;

pub const MiningMode = enum {
    auto,
    manual,
    interval,
};

pub const TransactionRecord = struct {
    sender: primitives.Address,
    raw: []u8,
    block_hash: ?[32]u8 = null,
    block_number: ?u64 = null,
    block_timestamp: ?u64 = null,
    transaction_index: ?u64 = null,
};

pub const NodeConfig = struct {
    chain_id: u64 = DEFAULT_CHAIN_ID,
    coinbase_index: u8 = 0,
    initial_balance: u256 = DEFAULT_BALANCE,
    gas_price: u256 = DEFAULT_GAS_PRICE,
    base_fee: u256 = DEFAULT_BASE_FEE,
    blob_base_fee: u256 = DEFAULT_BLOB_BASE_FEE,
    max_priority_fee: u256 = DEFAULT_MAX_PRIORITY_FEE,
    mining_config: mining.MiningConfig = mining.MiningConfig.default(),
};

pub const NodeRuntime = struct {
    chain_id: u64,
    coinbase: primitives.Address,
    head_block_number: u64,
    gas_price: u256,
    base_fee: u256,
    blob_base_fee: u256,
    max_priority_fee: u256,
    mining_config: mining.MiningConfig,
    mining_mode: MiningMode,
    interval_seconds: u64,
    current_timestamp: u64,
    state: state_manager.StateManager,
    blockchain: blockchain.Blockchain,
    pool: txpool.TxPool,
    tx_index: std.AutoHashMap([32]u8, TransactionRecord),
    impersonated_accounts: std.AutoHashMap(primitives.Address, void),
    prev_randao: u256,
    next_block_base_fee_override: ?u256,
    next_block_timestamp_override: ?u64,

    pub fn init(allocator: std.mem.Allocator, config_opt: ?NodeConfig) !NodeRuntime {
        const config = config_opt orelse NodeConfig{};

        var state = try state_manager.StateManager.init(allocator, null);
        errdefer state.deinit();

        var chain = try blockchain.Blockchain.init(allocator, null);
        errdefer chain.deinit();

        const genesis_block = try primitives.Block.genesis(config.chain_id, allocator);
        try chain.putBlock(genesis_block);
        try chain.setCanonicalHead(genesis_block.hash);

        // Seed dev accounts with initial balance
        for (&DEFAULT_DEV_ACCOUNTS) |addr| {
            try state.setBalance(addr, config.initial_balance);
        }

        const mode = switch (config.mining_config) {
            .auto => MiningMode.auto,
            .manual => MiningMode.manual,
            .interval => MiningMode.interval,
        };
        const interval_seconds = switch (config.mining_config) {
            .interval => |iv| iv.block_time,
            else => 0,
        };

        return .{
            .chain_id = config.chain_id,
            .coinbase = DEFAULT_DEV_ACCOUNTS[config.coinbase_index],
            .head_block_number = chain.getHeadBlockNumber() orelse 0,
            .gas_price = config.gas_price,
            .base_fee = config.base_fee,
            .blob_base_fee = config.blob_base_fee,
            .max_priority_fee = config.max_priority_fee,
            .mining_config = config.mining_config,
            .mining_mode = mode,
            .interval_seconds = interval_seconds,
            .current_timestamp = @intCast(std.time.timestamp()),
            .state = state,
            .blockchain = chain,
            .pool = txpool.TxPool.init(allocator),
            .tx_index = std.AutoHashMap([32]u8, TransactionRecord).init(allocator),
            .impersonated_accounts = std.AutoHashMap(primitives.Address, void).init(allocator),
            .prev_randao = 0,
            .next_block_base_fee_override = null,
            .next_block_timestamp_override = null,
        };
    }

    pub fn setMiningConfig(self: *NodeRuntime, config: mining.MiningConfig) void {
        self.mining_config = config;
        switch (config) {
            .auto => {
                self.mining_mode = .auto;
                self.interval_seconds = 0;
            },
            .manual => {
                self.mining_mode = .manual;
                self.interval_seconds = 0;
            },
            .interval => |iv| {
                self.mining_mode = .interval;
                self.interval_seconds = iv.block_time;
            },
        }
    }

    pub fn deinit(self: *NodeRuntime, allocator: std.mem.Allocator) void {
        var tx_it = self.tx_index.valueIterator();
        while (tx_it.next()) |record| {
            allocator.free(record.raw);
        }
        self.tx_index.deinit();
        self.pool.deinit(allocator);
        self.impersonated_accounts.deinit();
        self.blockchain.deinit();
        self.state.deinit();
    }

    pub fn lookupManagedAccount(address: primitives.Address) ?crypto.Crypto.PrivateKey {
        for (&DEFAULT_DEV_ACCOUNTS, 0..) |managed_address, i| {
            if (std.mem.eql(u8, &managed_address.bytes, &address.bytes)) {
                return DEFAULT_DEV_PRIVATE_KEYS[i];
            }
        }
        return null;
    }

    pub fn putTransactionRecord(
        self: *NodeRuntime,
        allocator: std.mem.Allocator,
        tx_hash: [32]u8,
        sender: primitives.Address,
        raw_tx: []const u8,
    ) !void {
        const raw_copy = try allocator.dupe(u8, raw_tx);
        errdefer allocator.free(raw_copy);

        const gop = try self.tx_index.getOrPut(tx_hash);
        if (gop.found_existing) {
            allocator.free(gop.value_ptr.raw);
            gop.value_ptr.* = .{
                .sender = sender,
                .raw = raw_copy,
            };
            return;
        }

        gop.value_ptr.* = .{
            .sender = sender,
            .raw = raw_copy,
        };
    }

    pub fn markTransactionMined(
        self: *NodeRuntime,
        tx_hash: [32]u8,
        block_hash: [32]u8,
        block_number: u64,
        block_timestamp: u64,
        transaction_index: u64,
    ) void {
        if (self.tx_index.getPtr(tx_hash)) |record| {
            record.block_hash = block_hash;
            record.block_number = block_number;
            record.block_timestamp = block_timestamp;
            record.transaction_index = transaction_index;
        }
    }

    pub fn getTransactionRecord(self: *const NodeRuntime, tx_hash: [32]u8) ?TransactionRecord {
        return self.tx_index.get(tx_hash);
    }

    pub fn impersonateAccount(
        self: *NodeRuntime,
        allocator: std.mem.Allocator,
        address: primitives.Address,
    ) !void {
        _ = allocator;
        try self.impersonated_accounts.put(address, {});
    }

    pub fn stopImpersonatingAccount(self: *NodeRuntime, address: primitives.Address) void {
        _ = self.impersonated_accounts.remove(address);
    }

    pub fn isImpersonated(self: *const NodeRuntime, address: primitives.Address) bool {
        return self.impersonated_accounts.contains(address);
    }
};
