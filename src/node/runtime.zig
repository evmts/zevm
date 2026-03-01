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
    fork_url: ?[]const u8 = null,
    fork_block_number: ?u64 = null,
    mining_config: mining.MiningConfig = mining.MiningConfig.default(),
};

pub const NodeRuntime = struct {
    chain_id: u64,
    coinbase: primitives.Address,
    head_block_number: u64,
    head_block_hash: [32]u8,
    gas_price: u256,
    base_fee: u256,
    blob_base_fee: u256,
    max_priority_fee: u256,
    block_gas_limit: u64,
    mining_config: mining.MiningConfig,
    mining_mode: MiningMode,
    interval_seconds: u64,
    current_timestamp: u64,
    fork_url: ?[]u8,
    fork_backend: ?*state_manager.ForkBackend,
    fork_block_cache: ?*blockchain.ForkBlockCache,
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
        const mode = switch (config.mining_config) {
            .auto => MiningMode.auto,
            .manual => MiningMode.manual,
            .interval => MiningMode.interval,
        };
        const interval_seconds = switch (config.mining_config) {
            .interval => |iv| iv.block_time,
            else => 0,
        };

        if (config.fork_url) |fork_url| {
            const owned_fork_url = try allocator.dupe(u8, fork_url);
            errdefer allocator.free(owned_fork_url);

            const fork_head = try fetchForkHead(allocator, owned_fork_url);
            const fork_block_number = config.fork_block_number orelse fork_head.number;
            const fork_block_tag = try std.fmt.allocPrint(allocator, "0x{x}", .{fork_block_number});
            defer allocator.free(fork_block_tag);

            const fork_backend_ptr = try allocator.create(state_manager.ForkBackend);
            errdefer allocator.destroy(fork_backend_ptr);
            fork_backend_ptr.* = try state_manager.ForkBackend.init(
                allocator,
                fork_block_tag,
                .{},
            );
            errdefer fork_backend_ptr.deinit();

            var state = try state_manager.StateManager.init(allocator, fork_backend_ptr);
            errdefer state.deinit();

            const fork_block_cache_ptr = try allocator.create(blockchain.ForkBlockCache);
            errdefer allocator.destroy(fork_block_cache_ptr);
            fork_block_cache_ptr.* = try blockchain.ForkBlockCache.init(allocator, fork_block_number);
            errdefer fork_block_cache_ptr.deinit();

            var chain = try blockchain.Blockchain.init(allocator, fork_block_cache_ptr);
            errdefer chain.deinit();

            // Seed deterministic dev accounts as local overrides on top of forked state.
            for (&DEFAULT_DEV_ACCOUNTS) |addr| {
                try state.setBalance(addr, config.initial_balance);
            }

            return .{
                .chain_id = config.chain_id,
                .coinbase = DEFAULT_DEV_ACCOUNTS[config.coinbase_index],
                .head_block_number = fork_head.number,
                .head_block_hash = fork_head.hash,
                .gas_price = config.gas_price,
                .base_fee = config.base_fee,
                .blob_base_fee = config.blob_base_fee,
                .max_priority_fee = config.max_priority_fee,
                .block_gas_limit = 30_000_000,
                .mining_config = config.mining_config,
                .mining_mode = mode,
                .interval_seconds = interval_seconds,
                .current_timestamp = fork_head.timestamp,
                .fork_url = owned_fork_url,
                .fork_backend = fork_backend_ptr,
                .fork_block_cache = fork_block_cache_ptr,
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

        return .{
            .chain_id = config.chain_id,
            .coinbase = DEFAULT_DEV_ACCOUNTS[config.coinbase_index],
            .head_block_number = chain.getHeadBlockNumber() orelse 0,
            .head_block_hash = genesis_block.hash,
            .gas_price = config.gas_price,
            .base_fee = config.base_fee,
            .blob_base_fee = config.blob_base_fee,
            .max_priority_fee = config.max_priority_fee,
            .block_gas_limit = 30_000_000,
            .mining_config = config.mining_config,
            .mining_mode = mode,
            .interval_seconds = interval_seconds,
            .current_timestamp = @intCast(std.time.timestamp()),
            .fork_url = null,
            .fork_backend = null,
            .fork_block_cache = null,
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
        if (self.fork_block_cache) |fork_cache| {
            fork_cache.deinit();
            allocator.destroy(fork_cache);
        }
        if (self.fork_backend) |fork_backend| {
            fork_backend.deinit();
            allocator.destroy(fork_backend);
        }
        if (self.fork_url) |fork_url| {
            allocator.free(fork_url);
        }
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

    pub fn processForkRequests(self: *NodeRuntime, allocator: std.mem.Allocator) !bool {
        const fork_url = self.fork_url orelse return false;
        var progressed = false;

        if (self.fork_backend) |fork_backend| {
            while (fork_backend.nextRequest()) |request| {
                progressed = true;
                const method = try inferStateForkMethod(allocator, request.params_json);
                const response_result = try callForkRpcResult(allocator, fork_url, method, request.params_json);
                defer allocator.free(response_result);
                try fork_backend.continueRequest(request.id, response_result);
            }
        }

        if (self.fork_block_cache) |fork_cache| {
            while (fork_cache.nextRequest()) |request| {
                progressed = true;
                const method = try inferBlockForkMethod(allocator, request.params_json);
                const response_result = try callForkRpcResult(allocator, fork_url, method, request.params_json);
                defer allocator.free(response_result);
                try fork_cache.continueRequest(request.id, response_result);
            }
        }

        return progressed;
    }

    pub fn getBalanceWithFork(
        self: *NodeRuntime,
        allocator: std.mem.Allocator,
        address: primitives.Address,
    ) !u256 {
        var attempts: usize = 0;
        while (attempts < 256) : (attempts += 1) {
            return self.state.getBalance(address) catch |err| switch (err) {
                error.RpcPending => {
                    if (!(try self.processForkRequests(allocator))) return err;
                    continue;
                },
                else => return err,
            };
        }
        return error.RpcPending;
    }

    pub fn getNonceWithFork(
        self: *NodeRuntime,
        allocator: std.mem.Allocator,
        address: primitives.Address,
    ) !u64 {
        var attempts: usize = 0;
        while (attempts < 256) : (attempts += 1) {
            return self.state.getNonce(address) catch |err| switch (err) {
                error.RpcPending => {
                    if (!(try self.processForkRequests(allocator))) return err;
                    continue;
                },
                else => return err,
            };
        }
        return error.RpcPending;
    }

    pub fn getCodeWithFork(
        self: *NodeRuntime,
        allocator: std.mem.Allocator,
        address: primitives.Address,
    ) ![]const u8 {
        var attempts: usize = 0;
        while (attempts < 256) : (attempts += 1) {
            return self.state.getCode(address) catch |err| switch (err) {
                error.RpcPending => {
                    if (!(try self.processForkRequests(allocator))) return err;
                    continue;
                },
                else => return err,
            };
        }
        return error.RpcPending;
    }

    pub fn getStorageWithFork(
        self: *NodeRuntime,
        allocator: std.mem.Allocator,
        address: primitives.Address,
        slot: u256,
    ) !u256 {
        var attempts: usize = 0;
        while (attempts < 256) : (attempts += 1) {
            return self.state.getStorage(address, slot) catch |err| switch (err) {
                error.RpcPending => {
                    if (!(try self.processForkRequests(allocator))) return err;
                    continue;
                },
                else => return err,
            };
        }
        return error.RpcPending;
    }

    pub fn getBlockByNumberWithFork(
        self: *NodeRuntime,
        allocator: std.mem.Allocator,
        number: u64,
    ) !?primitives.Block.Block {
        var attempts: usize = 0;
        while (attempts < 256) : (attempts += 1) {
            return self.blockchain.getBlockByNumber(number) catch |err| switch (err) {
                error.RpcPending => {
                    if (!(try self.processForkRequests(allocator))) return err;
                    continue;
                },
                else => return err,
            };
        }
        return error.RpcPending;
    }

    pub fn getBlockByHashWithFork(
        self: *NodeRuntime,
        allocator: std.mem.Allocator,
        hash: [32]u8,
    ) !?primitives.Block.Block {
        var attempts: usize = 0;
        while (attempts < 256) : (attempts += 1) {
            return self.blockchain.getBlockByHash(hash) catch |err| switch (err) {
                error.RpcPending => {
                    if (!(try self.processForkRequests(allocator))) return err;
                    continue;
                },
                else => return err,
            };
        }
        return error.RpcPending;
    }
};

const ForkHead = struct {
    number: u64,
    hash: [32]u8,
    timestamp: u64,
};

fn fetchForkHead(allocator: std.mem.Allocator, fork_url: []const u8) !ForkHead {
    const result_json = try callForkRpcResult(
        allocator,
        fork_url,
        "eth_getBlockByNumber",
        "[\"latest\", false]",
    );
    defer allocator.free(result_json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result_json, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidForkHead,
    };
    const number_value = object.get("number") orelse return error.InvalidForkHead;
    const hash_value = object.get("hash") orelse return error.InvalidForkHead;
    const timestamp_value = object.get("timestamp") orelse return error.InvalidForkHead;

    const number = parseHexU64Value(number_value) orelse return error.InvalidForkHead;
    const timestamp = parseHexU64Value(timestamp_value) orelse return error.InvalidForkHead;
    const hash_string = switch (hash_value) {
        .string => |value| value,
        else => return error.InvalidForkHead,
    };

    return .{
        .number = number,
        .hash = primitives.Hex.hexToBytesFixed(32, hash_string) catch return error.InvalidForkHead,
        .timestamp = timestamp,
    };
}

fn inferStateForkMethod(allocator: std.mem.Allocator, params_json: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, params_json, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const items = switch (parsed.value) {
        .array => |array| array.items,
        else => return error.InvalidForkRequest,
    };
    if (items.len == 2) return "eth_getCode";
    if (items.len == 3) return "eth_getProof";
    return error.InvalidForkRequest;
}

fn inferBlockForkMethod(allocator: std.mem.Allocator, params_json: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, params_json, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const items = switch (parsed.value) {
        .array => |array| array.items,
        else => return error.InvalidForkRequest,
    };
    if (items.len < 1) return error.InvalidForkRequest;

    const first = switch (items[0]) {
        .string => |value| value,
        else => return error.InvalidForkRequest,
    };

    if (first.len == 66) return "eth_getBlockByHash";
    return "eth_getBlockByNumber";
}

fn callForkRpcResult(
    allocator: std.mem.Allocator,
    fork_url: []const u8,
    method: []const u8,
    params_json: []const u8,
) ![]u8 {
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\",\"params\":{s}}}",
        .{ method, params_json },
    );
    defer allocator.free(payload);

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var response_writer = std.Io.Writer.Allocating.init(allocator);
    defer response_writer.deinit();

    const response = try client.fetch(.{
        .location = .{ .url = fork_url },
        .method = .POST,
        .payload = payload,
        .response_writer = &response_writer.writer,
        .extra_headers = &[_]std.http.Header{
            .{ .name = "content-type", .value = "application/json" },
        },
    });

    if (response.status != .ok) {
        return error.ForkRpcHttpStatus;
    }

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_writer.written(), .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const envelope = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.ForkRpcInvalidResponse,
    };

    if (envelope.get("error")) |_| {
        return error.ForkRpcReturnedError;
    }

    const result_value = envelope.get("result") orelse return error.ForkRpcInvalidResponse;
    var result_writer = std.Io.Writer.Allocating.init(allocator);
    defer result_writer.deinit();
    try std.json.Stringify.value(result_value, .{}, &result_writer.writer);
    return result_writer.toOwnedSlice();
}

fn parseHexU64Value(value: std.json.Value) ?u64 {
    const string = switch (value) {
        .string => |s| s,
        else => return null,
    };
    var hex = string;
    if (std.mem.startsWith(u8, hex, "0x") or std.mem.startsWith(u8, hex, "0X")) {
        hex = hex[2..];
    }
    if (hex.len == 0) return 0;
    return std.fmt.parseInt(u64, hex, 16) catch null;
}
