const std = @import("std");
const state_manager = @import("state-manager");
const primitives = @import("primitives");
const blockchain_mod = @import("blockchain");
const mining = @import("../mining.zig");
const mining_coordinator = @import("../mining_coordinator.zig");
const block_builder = @import("../block_builder.zig");
const tx_processor = @import("../tx_processor.zig");
const txpool = @import("../txpool.zig");
const genesis = @import("../genesis.zig");
const genesis_alloc = @import("../genesis_alloc.zig");
const chain_import = @import("../chain_import.zig");
const host_adapter = @import("../host_adapter.zig");
const dev_runtime_mod = @import("../rpc/dev_runtime.zig");
const receipt_index_mod = @import("../receipt_index.zig");
const log_index_mod = @import("../log_index.zig");
const checkpoint = @import("../checkpoint.zig");
const consensus_sync = @import("../consensus_sync.zig");
const hardfork_schedule = @import("../hardfork_schedule.zig");
const light_proof = @import("../light_proof.zig");
const tx_encoding = @import("../transaction_encoding.zig");
const log = @import("../log.zig");
const guillotine_mini = @import("guillotine_mini");

/// Hardhat/Anvil-style deterministic dev accounts.
/// These are the same 10 accounts used by Hardhat/Anvil (derived from mnemonic
/// "test test test test test test test test test test test junk").
pub const DEFAULT_DEV_ACCOUNTS = devAccountAddresses();

fn devAccountAddresses() [genesis.DEV_ACCOUNTS.len]primitives.Address {
    var addresses: [genesis.DEV_ACCOUNTS.len]primitives.Address = undefined;
    for (genesis.DEV_ACCOUNTS, 0..) |account, index| {
        addresses[index] = account.address;
    }
    return addresses;
}

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

/// Default block gas limit matching Hardhat/Anvil.
pub const DEFAULT_BLOCK_GAS_LIMIT: u64 = dev_runtime_mod.DEFAULT_BLOCK_GAS_LIMIT;

/// Default trusted-mode dev chain policy: Cancun active from genesis while
/// Prague/Osaka remain inactive unless explicitly configured.
pub const DEFAULT_DEV_HARDFORK_CONFIG = hardfork_schedule.ChainConfig{
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

pub fn defaultHardforkConfigForChainId(chain_id: u64) hardfork_schedule.ChainConfig {
    return if (chain_id == 1) hardfork_schedule.MAINNET_CHAIN_CONFIG else DEFAULT_DEV_HARDFORK_CONFIG;
}

pub const Mode = enum { trusted, light };

pub const LightNetwork = enum {
    mainnet,
    sepolia,
    holesky,

    pub fn fromString(value: []const u8) !LightNetwork {
        if (std.mem.eql(u8, value, "mainnet")) return .mainnet;
        if (std.mem.eql(u8, value, "sepolia")) return .sepolia;
        if (std.mem.eql(u8, value, "holesky")) return .holesky;
        return error.InvalidLightNetwork;
    }

    pub fn name(self: LightNetwork) []const u8 {
        return switch (self) {
            .mainnet => "mainnet",
            .sepolia => "sepolia",
            .holesky => "holesky",
        };
    }

    pub fn networkConfig(self: LightNetwork, consensus_rpc_url: []const u8) consensus_sync.NetworkConfig {
        return switch (self) {
            .mainnet => consensus_sync.NetworkConfig.mainnet(consensus_rpc_url),
            .sepolia => consensus_sync.NetworkConfig.sepolia(consensus_rpc_url),
            .holesky => consensus_sync.NetworkConfig.holesky(consensus_rpc_url),
        };
    }
};

pub const CheckpointSource = enum {
    explicit,
    persisted,
    default,

    pub fn name(self: CheckpointSource) []const u8 {
        return switch (self) {
            .explicit => "explicit",
            .persisted => "persisted",
            .default => "default",
        };
    }
};

pub const LightConfig = struct {
    network: LightNetwork = .mainnet,
    consensus_rpc_url: []const u8 = "",
    proof_rpc_url: ?[]const u8 = null,
    proof_resolver: ?light_proof.RpcResolver = null,
    advance_on_request: bool = true,
    checkpoint: ?[32]u8 = null,
    checkpoint_dir: ?[]const u8 = null,
    checkpoint_source: ?CheckpointSource = null,
    max_checkpoint_age_seconds: ?u64 = null,
    strict_checkpoint_age: bool = false,
};

pub const ForkConfig = struct {
    url: []const u8,
    block_number: ?u64 = null,
};

pub const ForkRpcRequest = struct {
    url: []const u8,
    method: []const u8,
    params_json: []const u8,
};

pub const ForkRpcResolver = struct {
    context: ?*anyopaque,
    resolve: *const fn (
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        request: ForkRpcRequest,
    ) anyerror![]u8,
};

pub const ResetForkMode = union(enum) {
    keep_current,
    disable,
    replace: ForkConfig,
};

pub const NodeConfig = struct {
    mode: Mode = .trusted,
    chain_id: u64 = DEFAULT_CHAIN_ID,
    coinbase_index: u8 = 0,
    initial_balance: u256 = DEFAULT_BALANCE,
    gas_price: u256 = DEFAULT_GAS_PRICE,
    base_fee: u256 = DEFAULT_BASE_FEE,
    blob_base_fee: u256 = DEFAULT_BLOB_BASE_FEE,
    max_priority_fee: u256 = DEFAULT_MAX_PRIORITY_FEE,
    block_gas_limit: u64 = DEFAULT_BLOCK_GAS_LIMIT,
    mining_config: mining.MiningConfig = mining.MiningConfig.default(),
    hardfork_config: ?hardfork_schedule.ChainConfig = null,
    fork_url: ?[]const u8 = null,
    fork_block_number: ?u64 = null,
    fork_rpc_resolver: ?ForkRpcResolver = null,
    genesis_alloc_path: ?[]const u8 = null,
    chain_rlp_path: ?[]const u8 = null,
    light: LightConfig = .{},
};

pub const LIGHT_RETAINED_HISTORY_BACKTRACK: u64 = 8190;

pub const LightReadHead = struct {
    state_root: [32]u8,
    block_number: u64,
};

pub const LightModeState = struct {
    network: LightNetwork,
    checkpoint_source: CheckpointSource,
    startup_checkpoint: [32]u8,
    engine: consensus_sync.ConsensusSyncEngine,
    safe_slot: u64,
    safe_head: LightReadHead,
    retained_heads: std.ArrayList(LightReadHead),
    proof_source: light_proof.ProofSource,
    advance_on_request: bool,

    pub fn deinit(self: *LightModeState, allocator: std.mem.Allocator) void {
        self.retained_heads.deinit(allocator);
        allocator.free(self.engine.config.consensus_rpc);
        allocator.free(self.proof_source.url);
    }

    pub fn effectiveStatus(self: *const LightModeState) consensus_sync.SyncStatus {
        if (self.engine.status == .synced and !self.slotCoherent()) {
            return .err;
        }
        return self.engine.status;
    }

    pub fn ready(self: *const LightModeState) bool {
        return self.effectiveStatus() == .synced;
    }

    pub fn optimisticSlot(self: *const LightModeState) u64 {
        return self.engine.store.optimistic_header.beacon.slot;
    }

    pub fn finalizedSlot(self: *const LightModeState) u64 {
        return self.engine.store.finalized_header.beacon.slot;
    }

    pub fn slotCoherent(self: *const LightModeState) bool {
        return self.finalizedSlot() <= self.safe_slot and self.safe_slot <= self.optimisticSlot();
    }

    pub fn optimisticHead(self: *const LightModeState) LightReadHead {
        return .{
            .state_root = self.engine.store.optimistic_header.execution.state_root,
            .block_number = self.engine.store.optimistic_header.execution.block_number,
        };
    }

    pub fn finalizedHead(self: *const LightModeState) LightReadHead {
        return .{
            .state_root = self.engine.store.finalized_header.execution.state_root,
            .block_number = self.engine.store.finalized_header.execution.block_number,
        };
    }

    pub fn findRetainedHead(self: *const LightModeState, block_number: u64) ?LightReadHead {
        for (self.retained_heads.items) |head| {
            if (head.block_number == block_number) return head;
        }
        return null;
    }

    pub fn recordCurrentHeads(self: *LightModeState, allocator: std.mem.Allocator) !void {
        self.refreshSafeHeadFromSlots();
        const current_head_number = self.optimisticHead().block_number;
        try self.recordRetainedHead(allocator, self.finalizedHead(), current_head_number);
        try self.recordRetainedHead(allocator, self.safe_head, current_head_number);
        try self.recordRetainedHead(allocator, self.optimisticHead(), current_head_number);
    }

    pub fn recordRetainedHead(self: *LightModeState, allocator: std.mem.Allocator, head: LightReadHead, current_head_number: u64) !void {
        const prune_head_number = @max(current_head_number, head.block_number);
        for (self.retained_heads.items) |*retained| {
            if (retained.block_number == head.block_number) {
                retained.* = head;
                self.pruneRetainedHeads(prune_head_number);
                return;
            }
        }

        try self.retained_heads.append(allocator, head);
        self.pruneRetainedHeads(prune_head_number);
    }

    fn refreshSafeHeadFromSlots(self: *LightModeState) void {
        const optimistic = self.optimisticHead();
        const finalized = self.finalizedHead();
        if (self.safe_slot == self.optimisticSlot()) {
            self.safe_head = optimistic;
            return;
        }
        if (self.safe_slot == self.finalizedSlot()) {
            self.safe_head = finalized;
            return;
        }
        if (self.safe_head.block_number < finalized.block_number or self.safe_head.block_number > optimistic.block_number) {
            self.safe_head = finalized;
        }
    }

    fn pruneRetainedHeads(self: *LightModeState, current_head_number: u64) void {
        const low = if (current_head_number > LIGHT_RETAINED_HISTORY_BACKTRACK)
            current_head_number - LIGHT_RETAINED_HISTORY_BACKTRACK
        else
            1;

        var index: usize = 0;
        while (index < self.retained_heads.items.len) {
            const block_number = self.retained_heads.items[index].block_number;
            if (block_number != 0 and (block_number < low or block_number > current_head_number)) {
                _ = self.retained_heads.orderedRemove(index);
                continue;
            }
            index += 1;
        }
    }
};

pub const LightReadSelector = union(enum) {
    latest,
    safe,
    finalized,
    earliest,
    number: u64,
};

const OwnedBlockBody = chain_import.OwnedBlockBody;

const QueryIndexSnapshot = struct {
    blockchain: blockchain_mod.Blockchain,
    owned_block_bodies: std.ArrayList(OwnedBlockBody),
    receipt_index: receipt_index_mod.ReceiptIndex,
    log_index: log_index_mod.LogIndex,

    fn deinit(self: *QueryIndexSnapshot, allocator: std.mem.Allocator) void {
        self.log_index.deinit(allocator);
        self.receipt_index.deinit(allocator);
        self.blockchain.deinit();
        clearOwnedBlockBodyList(allocator, &self.owned_block_bodies);
        self.owned_block_bodies.deinit(allocator);
    }
};

const SnapshotEntry = struct {
    state_snapshot_id: u64,
    head_block_number: u64,
    head_block_timestamp: u64,
    coinbase: primitives.Address,
    gas_price: u256,
    base_fee: u256,
    blob_base_fee: u256,
    max_priority_fee: u256,
    mining_config: mining.MiningConfig,
    pool: txpool.TransactionPool,
    time_offset: i128,
    next_block_timestamp: ?u64,
    block_timestamp_interval: ?u64,
    dev_config: dev_runtime_mod.NodeDevConfig,
    fork_config: ?ForkConfig,
    query_indexes: QueryIndexSnapshot,
    impersonated_accounts: std.AutoHashMap(primitives.Address, bool),
    auto_impersonate_account: bool,
};

pub const NodeRuntime = struct {
    allocator: std.mem.Allocator,
    mode: Mode,
    light: ?LightModeState,
    chain_id: u64,
    initial_balance: u256,
    managed_accounts: [genesis.DEV_ACCOUNTS.len]genesis.DevAccount,
    default_coinbase: primitives.Address,
    default_gas_price: u256,
    default_base_fee: u256,
    default_blob_base_fee: u256,
    default_max_priority_fee: u256,
    default_mining_config: mining.MiningConfig,
    hardfork_config: hardfork_schedule.ChainConfig,
    coinbase: primitives.Address,
    head_block_number: u64,
    head_block_timestamp: u64,
    gas_price: u256,
    base_fee: u256,
    blob_base_fee: u256,
    max_priority_fee: u256,
    mining_config: mining.MiningConfig,
    pool: txpool.TransactionPool,
    time_offset: i128,
    next_block_timestamp: ?u64,
    block_timestamp_interval: ?u64,
    dev_runtime: dev_runtime_mod.DevRuntime,
    state: state_manager.StateManager,
    blockchain: blockchain_mod.Blockchain,
    owned_block_bodies: std.ArrayList(OwnedBlockBody),
    genesis_extra_data: ?[]u8,
    receipt_index: receipt_index_mod.ReceiptIndex,
    log_index: log_index_mod.LogIndex,
    fork_config: ?ForkConfig,
    fork_backend: ?*state_manager.ForkBackend,
    fork_rpc_resolver: ?ForkRpcResolver,
    snapshots: std.AutoHashMap(u64, SnapshotEntry),
    next_snapshot_id: u64,
    impersonated_accounts: std.AutoHashMap(primitives.Address, bool),
    auto_impersonate_account: bool,
    runtime_mutex: std.Thread.Mutex,
    interval_thread: ?std.Thread,
    interval_stop_requested: std.atomic.Value(bool),
    light_sync_thread: ?std.Thread,

    pub fn init(allocator: std.mem.Allocator, config_opt: ?NodeConfig) !NodeRuntime {
        const config = config_opt orelse NodeConfig{};

        if (config.fork_block_number != null and config.fork_url == null) {
            return error.InvalidForkConfig;
        }
        if (config.coinbase_index >= DEFAULT_DEV_ACCOUNTS.len) {
            return error.InvalidCoinbaseIndex;
        }

        var light_state: ?LightModeState = if (config.mode == .light)
            try initLightModeState(allocator, config.light)
        else
            null;
        errdefer if (light_state) |*state| state.deinit(allocator);

        const runtime_chain_id = if (light_state) |state| state.engine.config.chain_id else config.chain_id;
        const runtime_hardfork_config = config.hardfork_config orelse defaultHardforkConfigForChainId(runtime_chain_id);

        const initial_fork_config = try allocForkConfig(allocator, if (config.mode == .trusted and config.fork_url != null) .{
            .url = config.fork_url.?,
            .block_number = config.fork_block_number,
        } else null);
        errdefer freeForkConfig(allocator, initial_fork_config);

        const fork_backend = try createForkBackend(allocator, initial_fork_config);
        errdefer destroyForkBackend(allocator, fork_backend);

        var state = try state_manager.StateManager.init(allocator, fork_backend);
        errdefer state.deinit();

        const managed_accounts = genesis.DEV_ACCOUNTS;
        const default_coinbase = managed_accounts[config.coinbase_index].address;

        var genesis_header = genesis_alloc.HeaderConfig{};
        var genesis_extra_data: ?[]u8 = null;
        errdefer if (genesis_extra_data) |bytes| allocator.free(bytes);

        const genesis_account_count = if (config.genesis_alloc_path) |path| blk: {
            const loaded = try genesis_alloc.loadGenesisFile(allocator, &state, path);
            genesis_header = loaded.header;
            genesis_extra_data = genesis_header.extra_data;
            break :blk loaded.account_count;
        } else blk: {
            // Seed deterministic dev accounts as the local writable overlay.
            // Use initAccount to bypass fork backend reads — dev accounts are
            // unconditional local overrides regardless of remote state.
            for (&managed_accounts) |account| {
                try state.initAccount(account.address, config.initial_balance);
            }
            break :blk managed_accounts.len;
        };
        const genesis_state_root = try block_builder.computeStateRoot(allocator, &state);
        if (config.genesis_alloc_path) |path| {
            const genesis_state_root_hex = std.fmt.bytesToHex(genesis_state_root, .lower);
            log.info(.startup, "genesis_allocation_loaded path={s} account_count={} state_root=0x{s}", .{
                path,
                genesis_account_count,
                &genesis_state_root_hex,
            });
        }
        const genesis_gas_limit = genesis_header.gas_limit orelse config.block_gas_limit;
        var blockchain = try initBlockchainWithGenesis(
            allocator,
            runtime_chain_id,
            genesis_state_root,
            default_coinbase,
            genesis_gas_limit,
            genesis_header,
        );
        errdefer blockchain.deinit();

        var owned_block_bodies = std.ArrayList(OwnedBlockBody){};
        errdefer {
            clearOwnedBlockBodyList(allocator, &owned_block_bodies);
            owned_block_bodies.deinit(allocator);
        }

        var startup_head_block_number: u64 = 0;
        var startup_head_block_timestamp: u64 = genesis_header.timestamp;
        var startup_base_fee = config.base_fee;
        if (config.chain_rlp_path) |path| {
            const stats = try chain_import.importChainFile(allocator, &blockchain, &owned_block_bodies, path);
            const imported_head = (try blockchain.getBlockByNumber(stats.head_block_number)) orelse return error.ImportedChainHeadMissing;
            startup_head_block_number = imported_head.header.number;
            startup_head_block_timestamp = imported_head.header.timestamp;
            startup_base_fee = imported_head.header.base_fee_per_gas orelse startup_base_fee;
            const head_hash_hex = std.fmt.bytesToHex(stats.head_hash, .lower);
            log.warn(.startup, "chain_rlp_query_only_imported path={s} block_count={} tx_count={} head_block_number={} head_hash=0x{s} state_materialized=false receipts_indexed=false logs_indexed=false", .{
                path,
                stats.block_count,
                stats.transaction_count,
                stats.head_block_number,
                &head_hash_hex,
            });
        }

        var receipt_index = receipt_index_mod.ReceiptIndex.init(allocator);
        errdefer receipt_index.deinit(allocator);

        var log_index = log_index_mod.LogIndex.init();
        errdefer log_index.deinit(allocator);

        var snapshots = std.AutoHashMap(u64, SnapshotEntry).init(allocator);
        errdefer snapshots.deinit();

        var impersonated_accounts = std.AutoHashMap(primitives.Address, bool).init(allocator);
        errdefer impersonated_accounts.deinit();

        const resolver: ?ForkRpcResolver = if (initial_fork_config != null) blk: {
            if (config.fork_rpc_resolver) |custom| {
                break :blk custom;
            }
            break :blk ForkRpcResolver{
                .context = null,
                .resolve = &resolveForkRpcViaHttp,
            };
        } else null;

        return .{
            .allocator = allocator,
            .mode = config.mode,
            .light = light_state,
            .chain_id = runtime_chain_id,
            .initial_balance = config.initial_balance,
            .managed_accounts = managed_accounts,
            .default_coinbase = default_coinbase,
            .default_gas_price = config.gas_price,
            .default_base_fee = config.base_fee,
            .default_blob_base_fee = config.blob_base_fee,
            .default_max_priority_fee = config.max_priority_fee,
            .default_mining_config = config.mining_config,
            .hardfork_config = runtime_hardfork_config,
            .coinbase = default_coinbase,
            .head_block_number = startup_head_block_number,
            .head_block_timestamp = startup_head_block_timestamp,
            .gas_price = config.gas_price,
            .base_fee = startup_base_fee,
            .blob_base_fee = config.blob_base_fee,
            .max_priority_fee = config.max_priority_fee,
            .mining_config = config.mining_config,
            .pool = txpool.TransactionPool.init(allocator),
            .time_offset = 0,
            .next_block_timestamp = null,
            .block_timestamp_interval = null,
            .dev_runtime = dev_runtime_mod.DevRuntime.initWithCoinbaseAndBlockGasLimit(
                default_coinbase,
                genesis_gas_limit,
            ),
            .state = state,
            .blockchain = blockchain,
            .owned_block_bodies = owned_block_bodies,
            .genesis_extra_data = genesis_extra_data,
            .receipt_index = receipt_index,
            .log_index = log_index,
            .fork_config = initial_fork_config,
            .fork_backend = fork_backend,
            .fork_rpc_resolver = resolver,
            .snapshots = snapshots,
            .next_snapshot_id = 1,
            .impersonated_accounts = impersonated_accounts,
            .auto_impersonate_account = false,
            .runtime_mutex = .{},
            .interval_thread = null,
            .interval_stop_requested = std.atomic.Value(bool).init(false),
            .light_sync_thread = null,
        };
    }

    pub fn startBackgroundServices(self: *NodeRuntime) !void {
        switch (self.mode) {
            .trusted => {
                if (self.interval_thread != null) return;
                switch (self.mining_config) {
                    .interval => |interval| try self.startIntervalMiningTimer(interval.block_time),
                    .auto, .manual => {},
                }
            },
            .light => try self.startLightSyncThread(),
        }
    }

    pub fn setMiningConfig(self: *NodeRuntime, config: mining.MiningConfig) !void {
        switch (config) {
            .interval => |interval| {
                if (interval.block_time == 0) {
                    self.stopIntervalMiningTimer();
                    self.mining_config = .manual;
                    return;
                }
                self.stopIntervalMiningTimer();
                self.mining_config = config;
                if (self.mode == .trusted) try self.startIntervalMiningTimer(interval.block_time);
            },
            .auto, .manual => {
                self.stopIntervalMiningTimer();
                self.mining_config = config;
            },
        }
    }

    fn startIntervalMiningTimer(self: *NodeRuntime, block_time: u64) !void {
        if (block_time == 0 or self.interval_thread != null) return;
        self.interval_stop_requested.store(false, .seq_cst);
        self.interval_thread = try std.Thread.spawn(.{}, intervalMiningLoop, .{ self, block_time });
        log.info(.mining, "interval_mining_started block_time_seconds={}", .{block_time});
    }

    fn stopIntervalMiningTimer(self: *NodeRuntime) void {
        const thread = self.interval_thread orelse return;
        self.interval_stop_requested.store(true, .seq_cst);
        thread.join();
        self.interval_thread = null;
        log.info(.mining, "interval_mining_stopped", .{});
    }

    fn intervalMiningLoop(self: *NodeRuntime, block_time: u64) void {
        while (!self.interval_stop_requested.load(.seq_cst)) {
            if (sleepUntilIntervalStop(&self.interval_stop_requested, block_time)) break;
            if (!self.lockRuntimeUntilIntervalStop()) break;
            defer self.runtime_mutex.unlock();

            if (self.interval_stop_requested.load(.seq_cst)) break;
            const active_block_time: ?u64 = switch (self.mining_config) {
                .interval => |interval| interval.block_time,
                .auto, .manual => null,
            };
            if (active_block_time == null or active_block_time.? != block_time) break;

            self.mineIntervalTick(block_time) catch |err| {
                log.err(.mining, "interval_mining_tick_failed block_time_seconds={} error={s}", .{ block_time, @errorName(err) });
            };
        }
    }

    fn sleepUntilIntervalStop(stop_requested: *std.atomic.Value(bool), seconds: u64) bool {
        const total_ns = std.math.mul(u64, seconds, std.time.ns_per_s) catch std.math.maxInt(u64);
        const chunk_ns: u64 = 50 * std.time.ns_per_ms;
        var remaining = total_ns;
        while (remaining > 0) {
            if (stop_requested.load(.seq_cst)) return true;
            const sleep_ns = @min(remaining, chunk_ns);
            std.Thread.sleep(sleep_ns);
            remaining -= sleep_ns;
        }
        return stop_requested.load(.seq_cst);
    }

    fn lockRuntimeUntilIntervalStop(self: *NodeRuntime) bool {
        while (!self.interval_stop_requested.load(.seq_cst)) {
            if (self.runtime_mutex.tryLock()) return true;
            std.Thread.sleep(std.time.ns_per_ms);
        }
        return false;
    }

    fn mineIntervalTick(self: *NodeRuntime, block_time: u64) !void {
        if (self.block_timestamp_interval != null) {
            return self.mineBlocksWithTimestampInterval(1, null);
        }

        const had_next_block_timestamp = self.next_block_timestamp != null;
        if (!had_next_block_timestamp) {
            const step = @max(block_time, 1);
            const next_timestamp = std.math.add(u64, self.head_block_timestamp, step) catch return error.InvalidParams;
            self.setNextBlockTimestamp(next_timestamp);
        }

        self.mineBlocks(1, block_time) catch |err| {
            if (!had_next_block_timestamp) {
                self.next_block_timestamp = null;
                self.dev_runtime.config.next_block_timestamp = null;
            }
            return err;
        };
    }

    fn startLightSyncThread(self: *NodeRuntime) !void {
        if (self.mode != .light) return error.NotLightMode;
        if (self.light_sync_thread != null) return;

        self.light_sync_thread = try std.Thread.spawn(.{}, lightSyncStartupLoop, .{self});
        log.info(.consensus_sync, "light_sync_background_started", .{});
    }

    fn stopLightSyncThread(self: *NodeRuntime) void {
        const thread = self.light_sync_thread orelse return;
        thread.join();
        self.light_sync_thread = null;
        log.info(.consensus_sync, "light_sync_background_stopped", .{});
    }

    fn lightSyncStartupLoop(self: *NodeRuntime) void {
        self.runLightStartupSyncDetached() catch |err| {
            self.runtime_mutex.lock();
            if (self.light) |*light| {
                light.engine.status = .err;
            }
            self.runtime_mutex.unlock();
            log.err(.consensus_sync, "light_sync_background_failed error={s}", .{@errorName(err)});
        };
    }

    fn runLightStartupSyncDetached(self: *NodeRuntime) !void {
        const StartupSnapshot = struct {
            engine: consensus_sync.ConsensusSyncEngine,
            startup_checkpoint: [32]u8,
            checkpoint_source: CheckpointSource,
        };

        const startup_snapshot: StartupSnapshot = blk: {
            self.runtime_mutex.lock();
            defer self.runtime_mutex.unlock();
            const light = if (self.light) |*state| state else return error.NotLightMode;
            break :blk .{
                .engine = light.engine,
                .startup_checkpoint = light.startup_checkpoint,
                .checkpoint_source = light.checkpoint_source,
            };
        };

        var engine = startup_snapshot.engine;
        try engine.sync(self.allocator, startup_snapshot.startup_checkpoint, .{
            .source = startup_snapshot.checkpoint_source.name(),
        });
        const safe_slot = engine.safeSlot();
        const head_block_number = engine.store.optimistic_header.execution.block_number;

        self.runtime_mutex.lock();
        defer self.runtime_mutex.unlock();

        const light = if (self.light) |*state| state else return error.NotLightMode;
        light.engine = engine;
        light.safe_slot = safe_slot;
        self.head_block_number = head_block_number;
        try light.recordCurrentHeads(self.allocator);
        log.info(.consensus_sync, "light_sync_background_completed head_block_number={} safe_slot={}", .{
            head_block_number,
            safe_slot,
        });
    }

    pub fn isLightReady(self: *const NodeRuntime) bool {
        const light = self.light orelse return false;
        return light.ready();
    }

    pub fn lightStatus(self: *const NodeRuntime) consensus_sync.SyncStatus {
        const light = self.light orelse return .err;
        return light.effectiveStatus();
    }

    pub fn lightCheckpointSource(self: *const NodeRuntime) ?CheckpointSource {
        const light = self.light orelse return null;
        return light.checkpoint_source;
    }

    pub fn lightNetwork(self: *const NodeRuntime) ?LightNetwork {
        const light = self.light orelse return null;
        return light.network;
    }

    pub fn lightLastCheckpoint(self: *const NodeRuntime) ?[32]u8 {
        const light = self.light orelse return null;
        return light.engine.lastCheckpoint();
    }

    pub fn lightOptimisticSlot(self: *const NodeRuntime) u64 {
        const light = self.light orelse return 0;
        return light.optimisticSlot();
    }

    pub fn lightSafeSlot(self: *const NodeRuntime) u64 {
        const light = self.light orelse return 0;
        return light.safe_slot;
    }

    pub fn lightFinalizedSlot(self: *const NodeRuntime) u64 {
        const light = self.light orelse return 0;
        return light.finalizedSlot();
    }

    pub fn startLightSync(self: *NodeRuntime) !void {
        const light = if (self.light) |*state| state else return error.NotLightMode;
        try light.engine.sync(self.allocator, light.startup_checkpoint, .{
            .source = light.checkpoint_source.name(),
        });
        light.safe_slot = light.engine.safeSlot();
        self.head_block_number = light.engine.store.optimistic_header.execution.block_number;
        try light.recordCurrentHeads(self.allocator);
    }

    pub fn advanceLightSync(self: *NodeRuntime) !void {
        const light = if (self.light) |*state| state else return error.NotLightMode;
        try light.engine.advance(self.allocator);
        light.safe_slot = light.engine.safeSlot();
        self.head_block_number = light.engine.store.optimistic_header.execution.block_number;
        try light.recordCurrentHeads(self.allocator);
    }

    pub fn refreshLightSyncForRequest(self: *NodeRuntime) !void {
        const light = if (self.light) |*state| state else return error.NotLightMode;
        if (!light.advance_on_request or !light.ready()) return;
        self.advanceLightSync() catch return error.LightNotReady;
    }

    pub fn refreshLightSyncForStatus(self: *NodeRuntime) void {
        const light = if (self.light) |*state| state else return;
        if (!light.advance_on_request or !light.ready()) return;
        self.advanceLightSync() catch {};
    }

    pub fn resolveLightReadHead(self: *const NodeRuntime, selector: LightReadSelector) !LightReadHead {
        const light = self.light orelse return error.NotLightMode;
        return switch (selector) {
            .latest => light.optimisticHead(),
            .safe => light.safe_head,
            .finalized => light.finalizedHead(),
            .earliest => light.findRetainedHead(0) orelse error.ProofVerifyFailed,
            .number => |block_number| blk: {
                if (block_number == 0) {
                    if (light.findRetainedHead(0)) |head| break :blk head;
                    break :blk error.ProofVerifyFailed;
                }
                const optimistic = light.optimisticHead();
                if (block_number == optimistic.block_number) break :blk optimistic;
                if (block_number == light.safe_head.block_number) break :blk light.safe_head;
                const finalized = light.finalizedHead();
                if (block_number == finalized.block_number) break :blk finalized;
                if (light.findRetainedHead(block_number)) |head| break :blk head;
                break :blk error.ProofVerifyFailed;
            },
        };
    }

    pub fn lightGetBalance(self: *NodeRuntime, selector: LightReadSelector, address: primitives.Address) !u256 {
        const light = if (self.light) |*state| state else return error.NotLightMode;
        const head = try self.resolveLightReadHead(selector);
        const block_tag = try std.fmt.allocPrint(self.allocator, "0x{x}", .{head.block_number});
        defer self.allocator.free(block_tag);
        return light_proof.readBalance(self.allocator, light.proof_source, head.state_root, address, block_tag);
    }

    pub fn lightGetNonce(self: *NodeRuntime, selector: LightReadSelector, address: primitives.Address) !u64 {
        const light = if (self.light) |*state| state else return error.NotLightMode;
        const head = try self.resolveLightReadHead(selector);
        const block_tag = try std.fmt.allocPrint(self.allocator, "0x{x}", .{head.block_number});
        defer self.allocator.free(block_tag);
        return light_proof.readTransactionCount(self.allocator, light.proof_source, head.state_root, address, block_tag);
    }

    pub fn lightGetCode(self: *NodeRuntime, selector: LightReadSelector, address: primitives.Address) ![]u8 {
        const light = if (self.light) |*state| state else return error.NotLightMode;
        const head = try self.resolveLightReadHead(selector);
        const block_tag = try std.fmt.allocPrint(self.allocator, "0x{x}", .{head.block_number});
        defer self.allocator.free(block_tag);
        return light_proof.readCode(self.allocator, light.proof_source, head.state_root, address, block_tag);
    }

    pub fn lightGetStorage(self: *NodeRuntime, selector: LightReadSelector, address: primitives.Address, slot: u256) !u256 {
        const light = if (self.light) |*state| state else return error.NotLightMode;
        const head = try self.resolveLightReadHead(selector);
        const block_tag = try std.fmt.allocPrint(self.allocator, "0x{x}", .{head.block_number});
        defer self.allocator.free(block_tag);
        return light_proof.readStorage(self.allocator, light.proof_source, head.state_root, address, slot, block_tag);
    }

    pub fn setLightSyncProgress(
        self: *NodeRuntime,
        status: consensus_sync.SyncStatus,
        optimistic_slot: u64,
        safe_slot: u64,
        finalized_slot: u64,
        latest_block_number: u64,
    ) !void {
        const light = if (self.light) |*state| state else return error.NotLightMode;
        light.engine.status = status;
        light.engine.store.optimistic_header.beacon.slot = optimistic_slot;
        light.engine.store.finalized_header.beacon.slot = finalized_slot;
        light.safe_slot = safe_slot;
        light.engine.store.optimistic_header.execution.block_number = latest_block_number;
        self.head_block_number = latest_block_number;
        try light.recordCurrentHeads(self.allocator);
    }

    pub fn recordLightReadHead(self: *NodeRuntime, head: LightReadHead) !void {
        const light = if (self.light) |*state| state else return error.NotLightMode;
        try light.recordRetainedHead(self.allocator, head, self.head_block_number);
    }

    pub fn setLightSafeReadHead(self: *NodeRuntime, head: LightReadHead) !void {
        const light = if (self.light) |*state| state else return error.NotLightMode;
        light.safe_head = head;
        try light.recordRetainedHead(self.allocator, head, self.head_block_number);
    }

    pub fn effectiveCurrentTime(self: *const NodeRuntime) u64 {
        const effective = @as(i128, currentUnixSeconds()) + self.time_offset;
        if (effective <= 0) return 0;
        if (effective > std.math.maxInt(u64)) return std.math.maxInt(u64);
        return @intCast(effective);
    }

    pub fn hardforkAt(self: *const NodeRuntime, block_number: u64, timestamp: u64) guillotine_mini.Hardfork {
        return hardfork_schedule.resolveHardforkWithConfig(self.hardfork_config, block_number, timestamp);
    }

    pub fn hardforkForBlockContext(self: *const NodeRuntime, block_ctx: guillotine_mini.BlockContext) guillotine_mini.Hardfork {
        return self.hardforkAt(block_ctx.block_number, block_ctx.block_timestamp);
    }

    pub fn pendingHardfork(self: *const NodeRuntime) guillotine_mini.Hardfork {
        const block_number = self.head_block_number +| 1;
        const timestamp = self.pendingBlockTimestamp();
        return self.hardforkAt(block_number, timestamp);
    }

    fn pendingBlockTimestamp(self: *const NodeRuntime) u64 {
        const minimum = self.head_block_timestamp +| 1;
        if (self.next_block_timestamp) |timestamp| {
            return @max(minimum, timestamp);
        }
        if (self.block_timestamp_interval) |interval| {
            return self.head_block_timestamp +| @max(interval, 1);
        }
        return @max(minimum, self.effectiveCurrentTime());
    }

    pub fn increaseTime(self: *NodeRuntime, seconds: u64) !u64 {
        const next_offset = std.math.add(i128, self.time_offset, @as(i128, seconds)) catch return error.InvalidParams;
        if (next_offset < 0 or next_offset > std.math.maxInt(u64)) return error.InvalidParams;
        self.time_offset = next_offset;
        return @intCast(next_offset);
    }

    pub fn setTime(self: *NodeRuntime, timestamp: u64) !u64 {
        self.time_offset = @as(i128, timestamp) - @as(i128, currentUnixSeconds());
        return timestamp;
    }

    pub fn setNextBlockTimestamp(self: *NodeRuntime, timestamp: u64) void {
        self.next_block_timestamp = timestamp;
        self.dev_runtime.config.next_block_timestamp = timestamp;
    }

    pub fn setBlockTimestampInterval(self: *NodeRuntime, seconds: u64) void {
        self.block_timestamp_interval = seconds;
    }

    pub fn removeBlockTimestampInterval(self: *NodeRuntime) void {
        self.block_timestamp_interval = null;
    }

    pub fn nextBlockTimestamp(self: *NodeRuntime, parent_timestamp: u64) !u64 {
        const minimum = std.math.add(u64, parent_timestamp, 1) catch return error.InvalidParams;
        if (self.next_block_timestamp) |timestamp| {
            if (timestamp < minimum) return error.InvalidParams;
            self.next_block_timestamp = null;
            self.dev_runtime.config.next_block_timestamp = null;
            return timestamp;
        }
        return @max(minimum, self.effectiveCurrentTime());
    }

    pub fn setAutomine(self: *NodeRuntime, enabled: bool) !void {
        try self.setMiningConfig(if (enabled) .auto else .manual);
    }

    pub fn setIntervalMining(self: *NodeRuntime, seconds: u64) !void {
        var coordinator = miningCoordinatorFromConfig(self.mining_config);
        defer coordinator.deinit(self.allocator);

        coordinator.setIntervalMining(seconds);
        try self.setMiningConfig(miningConfigFromCoordinator(coordinator));
    }

    pub fn mineBlocks(self: *NodeRuntime, count: u64, interval: u64) !void {
        if (count == 0) return;

        const had_next_block_timestamp = self.next_block_timestamp != null;
        const first_timestamp = try self.nextBlockTimestamp(self.head_block_timestamp);
        errdefer {
            if (had_next_block_timestamp) {
                self.next_block_timestamp = first_timestamp;
                self.dev_runtime.config.next_block_timestamp = first_timestamp;
            }
        }

        var coordinator = miningCoordinatorFromRuntime(self);
        defer coordinator.deinit(self.allocator);
        coordinator.current_timestamp = first_timestamp;

        var adapter = host_adapter.HostAdapter{ .state = &self.state };
        var i: u64 = 0;
        while (i < count) : (i += 1) {
            if (i > 0 and interval > 0) {
                coordinator.current_timestamp += interval - 1;
            }

            const ready = try self.pool.getReady(self.allocator);
            defer self.allocator.free(ready);

            for (ready) |pooled| {
                try coordinator.pending_txs.append(self.allocator, NodeRuntime.executionTransactionFromPooled(pooled));
            }

            var block_options = mining_coordinator.MiningBlockOptions{
                .prevrandao = coordinator.next_prevrandao,
                .dev_runtime = &self.dev_runtime,
            };
            var block_ctx = block_builder.blockContextWithEnvironmentOverrides(
                &self.dev_runtime,
                coordinator.blockContext(block_options),
            );
            var recent_block_hashes: [256][32]u8 = undefined;
            block_ctx.block_hashes = try self.recentBlockHashesForExecution(block_ctx.block_number, &recent_block_hashes);
            block_options.block_hashes = block_ctx.block_hashes;
            const block_excess_blob_gas = coordinator.current_excess_blob_gas;

            var result = try coordinator.mineBlockWithOptions(
                self.allocator,
                &self.state,
                adapter.hostInterface(),
                block_options,
            );
            _ = &result;

            const block_hash = try self.persistMinedBlock(block_ctx, block_excess_blob_gas, &result, ready);

            const mined_hashes = try self.minedHashesFromResult(result, ready);
            defer self.allocator.free(mined_hashes);
            const included_tx_count = mined_hashes.len;
            self.pool.removeMined(mined_hashes);

            const block = (try self.blockchain.getBlockByHash(block_hash)) orelse return error.MinedBlockMissing;
            self.head_block_number = block.header.number;
            self.head_block_timestamp = block.header.timestamp;
            const block_hash_hex = std.fmt.bytesToHex(block.hash, .lower);
            log.info(
                .mining,
                "block_mined number={} hash=0x{s} tx_count={} gas_used={} pool_pending={} pool_queued={} mode={s}",
                .{
                    block.header.number,
                    &block_hash_hex,
                    included_tx_count,
                    block.header.gas_used,
                    self.pool.pendingCount(),
                    self.pool.queuedCount(),
                    miningConfigName(self.mining_config),
                },
            );
        }

        if (coordinator.current_base_fee_per_gas) |base_fee| {
            self.base_fee = base_fee;
        }
    }

    pub fn mineBlocksWithTimestampInterval(self: *NodeRuntime, count: u64, explicit_interval: ?u64) !void {
        if (explicit_interval) |interval| {
            return self.mineBlocks(count, interval);
        }
        const interval = self.block_timestamp_interval orelse return self.mineBlocks(count, 0);
        if (count == 0) return;

        const had_next_block_timestamp = self.next_block_timestamp != null;
        if (!had_next_block_timestamp) {
            const step = @max(interval, 1);
            const next_timestamp = std.math.add(u64, self.head_block_timestamp, step) catch return error.InvalidParams;
            self.setNextBlockTimestamp(next_timestamp);
        }

        self.mineBlocks(count, interval) catch |err| {
            if (!had_next_block_timestamp) {
                self.next_block_timestamp = null;
                self.dev_runtime.config.next_block_timestamp = null;
            }
            return err;
        };
    }

    fn executionTransactionFromPooled(pooled: txpool.PooledTransaction) tx_processor.ExecutionTx {
        return .{
            .caller = pooled.sender,
            .tx = .{
                .nonce = pooled.nonce,
                .gas_price = pooled.max_fee_per_gas,
                .gas_limit = pooled.gas_limit,
                .to = pooled.to,
                .value = pooled.value,
                .data = pooled.input,
                .v = pooled.v,
                .r = pooled.r,
                .s = pooled.s,
            },
        };
    }

    pub fn isForkingEnabled(self: *const NodeRuntime) bool {
        return self.fork_config != null;
    }

    pub fn impersonateAccount(self: *NodeRuntime, address: primitives.Address) !void {
        try self.impersonated_accounts.put(address, true);
    }

    pub fn stopImpersonatingAccount(self: *NodeRuntime, address: primitives.Address) void {
        _ = self.impersonated_accounts.remove(address);
    }

    pub fn setAutoImpersonateAccount(self: *NodeRuntime, enabled: bool) void {
        self.auto_impersonate_account = enabled;
    }

    pub fn isImpersonatingAccount(self: *const NodeRuntime, address: primitives.Address) bool {
        return self.impersonated_accounts.get(address) orelse false;
    }

    pub fn canSignForAccount(self: *const NodeRuntime, address: primitives.Address) bool {
        return self.isManagedAccount(address) or
            self.auto_impersonate_account or
            self.isImpersonatingAccount(address);
    }

    pub fn managedAccountCount(self: *const NodeRuntime) usize {
        _ = self;
        return genesis.DEV_ACCOUNTS.len;
    }

    pub fn managedAccountAddress(self: *const NodeRuntime, index: usize) primitives.Address {
        return self.managed_accounts[index].address;
    }

    pub fn managedPrivateKey(self: *const NodeRuntime, address: primitives.Address) ?[32]u8 {
        for (&self.managed_accounts) |account| {
            if (std.mem.eql(u8, &account.address.bytes, &address.bytes)) return account.private_key;
        }
        return null;
    }

    pub fn isManagedAccount(self: *const NodeRuntime, address: primitives.Address) bool {
        return self.managedPrivateKey(address) != null;
    }

    pub fn getBalance(self: *NodeRuntime, address: primitives.Address) !u256 {
        while (true) {
            return self.state.getBalance(address) catch |err| switch (err) {
                error.RpcPending => {
                    try self.serviceForkRequests();
                    continue;
                },
                else => return err,
            };
        }
    }

    pub fn getNonce(self: *NodeRuntime, address: primitives.Address) !u64 {
        while (true) {
            return self.state.getNonce(address) catch |err| switch (err) {
                error.RpcPending => {
                    try self.serviceForkRequests();
                    continue;
                },
                else => return err,
            };
        }
    }

    pub fn getCode(self: *NodeRuntime, address: primitives.Address) ![]const u8 {
        while (true) {
            return self.state.getCode(address) catch |err| switch (err) {
                error.RpcPending => {
                    try self.serviceForkRequests();
                    continue;
                },
                else => return err,
            };
        }
    }

    pub fn getStorage(self: *NodeRuntime, address: primitives.Address, slot: u256) !u256 {
        while (true) {
            return self.state.getStorage(address, slot) catch |err| switch (err) {
                error.RpcPending => {
                    try self.serviceForkRequests();
                    continue;
                },
                else => return err,
            };
        }
    }

    pub fn recentBlockHashesForExecution(
        self: *NodeRuntime,
        execution_block_number: u64,
        out: *[256][32]u8,
    ) ![]const [32]u8 {
        if (execution_block_number == 0) return out[0..0];
        const tip_number = execution_block_number - 1;
        const tip_hash = self.blockchain.getCanonicalHash(tip_number) orelse return error.MissingParentBlock;
        return try self.blockchain.last256BlockHashesLocal(tip_hash, out);
    }

    pub fn setBalance(self: *NodeRuntime, address: primitives.Address, balance: u256) !void {
        while (true) {
            self.state.setBalance(address, balance) catch |err| switch (err) {
                error.RpcPending => {
                    try self.serviceForkRequests();
                    continue;
                },
                else => return err,
            };
            return;
        }
    }

    pub fn setNonce(self: *NodeRuntime, address: primitives.Address, nonce: u64) !void {
        while (true) {
            self.state.setNonce(address, nonce) catch |err| switch (err) {
                error.RpcPending => {
                    try self.serviceForkRequests();
                    continue;
                },
                else => return err,
            };
            return;
        }
    }

    pub fn setCode(self: *NodeRuntime, address: primitives.Address, code: []const u8) !void {
        try self.state.setCode(address, code);
    }

    pub fn setStorage(self: *NodeRuntime, address: primitives.Address, slot: u256, value: u256) !void {
        try self.state.setStorage(address, slot, value);
    }

    pub fn snapshot(self: *NodeRuntime) !u64 {
        const snapshot_id = self.next_snapshot_id;
        self.next_snapshot_id += 1;

        const state_snapshot_id = try self.state.snapshot();
        const fork_copy = try allocForkConfig(self.allocator, self.fork_config);
        errdefer freeForkConfig(self.allocator, fork_copy);
        var pool_copy = try self.pool.clone(self.allocator);
        errdefer pool_copy.deinit();
        var impersonated_copy = try self.impersonated_accounts.clone();
        errdefer impersonated_copy.deinit();
        var query_indexes = try self.cloneQueryIndexes();
        errdefer query_indexes.deinit(self.allocator);

        try self.snapshots.put(snapshot_id, .{
            .state_snapshot_id = state_snapshot_id,
            .head_block_number = self.head_block_number,
            .head_block_timestamp = self.head_block_timestamp,
            .coinbase = self.coinbase,
            .gas_price = self.gas_price,
            .base_fee = self.base_fee,
            .blob_base_fee = self.blob_base_fee,
            .max_priority_fee = self.max_priority_fee,
            .mining_config = self.mining_config,
            .pool = pool_copy,
            .time_offset = self.time_offset,
            .next_block_timestamp = self.next_block_timestamp,
            .block_timestamp_interval = self.block_timestamp_interval,
            .dev_config = self.dev_runtime.config,
            .fork_config = fork_copy,
            .query_indexes = query_indexes,
            .impersonated_accounts = impersonated_copy,
            .auto_impersonate_account = self.auto_impersonate_account,
        });

        return snapshot_id;
    }

    pub fn revertToSnapshot(self: *NodeRuntime, snapshot_id: u64) !bool {
        const entry = self.snapshots.get(snapshot_id) orelse return false;
        var pool_copy = try entry.pool.clone(self.allocator);
        var pool_assigned = false;
        defer {
            if (!pool_assigned) pool_copy.deinit();
        }
        var impersonated_copy = try entry.impersonated_accounts.clone();
        var impersonation_assigned = false;
        defer {
            if (!impersonation_assigned) impersonated_copy.deinit();
        }
        var query_copy = try cloneQueryIndexSnapshot(
            self.allocator,
            &entry.query_indexes.blockchain,
            &entry.query_indexes.receipt_index,
            &entry.query_indexes.log_index,
        );
        var query_assigned = false;
        defer {
            if (!query_assigned) query_copy.deinit(self.allocator);
        }

        self.state.revertToSnapshot(entry.state_snapshot_id) catch return false;
        self.stopIntervalMiningTimer();

        self.head_block_number = entry.head_block_number;
        self.head_block_timestamp = entry.head_block_timestamp;
        self.coinbase = entry.coinbase;
        self.gas_price = entry.gas_price;
        self.base_fee = entry.base_fee;
        self.blob_base_fee = entry.blob_base_fee;
        self.max_priority_fee = entry.max_priority_fee;
        self.mining_config = entry.mining_config;
        self.pool.deinit();
        self.pool = pool_copy;
        pool_assigned = true;
        self.replaceQueryIndexes(query_copy);
        query_assigned = true;
        self.time_offset = entry.time_offset;
        self.next_block_timestamp = entry.next_block_timestamp;
        self.block_timestamp_interval = entry.block_timestamp_interval;
        self.dev_runtime.config = entry.dev_config;

        try self.restoreForkStateFromSnapshot(entry.fork_config);
        self.impersonated_accounts.deinit();
        self.impersonated_accounts = impersonated_copy;
        impersonation_assigned = true;
        self.auto_impersonate_account = entry.auto_impersonate_account;

        var to_remove = std.ArrayList(u64){};
        defer to_remove.deinit(self.allocator);

        var it = self.snapshots.iterator();
        while (it.next()) |kv| {
            if (kv.key_ptr.* >= snapshot_id) {
                try to_remove.append(self.allocator, kv.key_ptr.*);
            }
        }

        for (to_remove.items) |id| {
            if (self.snapshots.fetchRemove(id)) |removed| {
                var removed_value = removed.value;
                deinitSnapshotEntry(self.allocator, &removed_value);
            }
        }

        try self.startBackgroundServices();
        return true;
    }

    pub fn reset(self: *NodeRuntime, mode: ResetForkMode) !void {
        const restart_interval_on_error = self.interval_thread != null;
        self.stopIntervalMiningTimer();
        errdefer if (restart_interval_on_error) {
            self.startBackgroundServices() catch |err| {
                log.err(.mining, "interval_mining_restart_failed_after_reset_error error={s}", .{@errorName(err)});
            };
        };

        const target_fork: ?ForkConfig = switch (mode) {
            .keep_current => self.fork_config,
            .disable => null,
            .replace => |fork| fork,
        };

        if (target_fork) |fork| {
            try validateForkUrl(fork.url);
        }

        try self.rebuildState(target_fork);
        self.coinbase = self.default_coinbase;
        self.head_block_number = 0;
        self.head_block_timestamp = 0;
        self.gas_price = self.default_gas_price;
        self.base_fee = self.default_base_fee;
        self.blob_base_fee = self.default_blob_base_fee;
        self.max_priority_fee = self.default_max_priority_fee;
        self.mining_config = self.default_mining_config;
        self.pool.clear();
        self.time_offset = 0;
        self.next_block_timestamp = null;
        self.block_timestamp_interval = null;
        self.dev_runtime.resetConfig(self.default_coinbase);
        self.impersonated_accounts.clearRetainingCapacity();
        self.auto_impersonate_account = false;
        try self.resetQueryIndexes();
        self.clearSnapshots();
        try self.startBackgroundServices();
    }

    pub fn setRpcUrl(self: *NodeRuntime, new_url: []const u8) !void {
        try validateForkUrl(new_url);

        var fork_cfg = self.fork_config orelse return error.ForkNotEnabled;
        const new_url_owned = try self.allocator.dupe(u8, new_url);
        self.allocator.free(fork_cfg.url);
        fork_cfg.url = new_url_owned;
        self.fork_config = fork_cfg;

        // Upstream changed; clear only remote cache while preserving local overlays.
        self.state.clearForkCache();
    }

    pub fn deinit(self: *NodeRuntime) void {
        self.stopLightSyncThread();
        self.stopIntervalMiningTimer();
        if (self.light) |*light| {
            light.deinit(self.allocator);
            self.light = null;
        }
        self.clearSnapshots();
        self.pool.deinit();
        self.dev_runtime.deinit(self.allocator);
        self.snapshots.deinit();
        self.impersonated_accounts.deinit();
        self.log_index.deinit(self.allocator);
        self.receipt_index.deinit(self.allocator);
        self.blockchain.deinit();
        if (self.genesis_extra_data) |bytes| {
            self.allocator.free(bytes);
            self.genesis_extra_data = null;
        }
        self.clearOwnedBlockBodies();
        self.owned_block_bodies.deinit(self.allocator);
        self.state.deinit();
        destroyForkBackend(self.allocator, self.fork_backend);
        freeForkConfig(self.allocator, self.fork_config);
        self.fork_backend = null;
        self.fork_config = null;
    }

    fn rebuildState(self: *NodeRuntime, target_fork: ?ForkConfig) !void {
        const new_fork_config = try allocForkConfig(self.allocator, target_fork);
        errdefer freeForkConfig(self.allocator, new_fork_config);

        const new_backend = try createForkBackend(self.allocator, new_fork_config);
        errdefer destroyForkBackend(self.allocator, new_backend);

        var new_state = try state_manager.StateManager.init(self.allocator, new_backend);
        errdefer new_state.deinit();

        for (&self.managed_accounts) |account| {
            try new_state.initAccount(account.address, self.initial_balance);
        }

        self.state.deinit();
        destroyForkBackend(self.allocator, self.fork_backend);
        freeForkConfig(self.allocator, self.fork_config);

        self.state = new_state;
        self.fork_backend = new_backend;
        self.fork_config = new_fork_config;
        if (new_fork_config != null and self.fork_rpc_resolver == null) {
            self.fork_rpc_resolver = .{
                .context = null,
                .resolve = &resolveForkRpcViaHttp,
            };
        }
    }

    fn restoreForkStateFromSnapshot(self: *NodeRuntime, snapshot_fork: ?ForkConfig) !void {
        if (self.fork_config == null and snapshot_fork == null) {
            return;
        }
        if (self.fork_config == null or snapshot_fork == null) {
            return error.ForkSnapshotMismatch;
        }

        var current = self.fork_config.?;
        const target = snapshot_fork.?;
        if (current.block_number != target.block_number or !std.mem.eql(u8, current.url, target.url)) {
            const updated_url = try self.allocator.dupe(u8, target.url);
            self.allocator.free(current.url);
            current.url = updated_url;
            current.block_number = target.block_number;
            self.fork_config = current;
            self.state.clearForkCache();
        }
    }

    fn serviceForkRequests(self: *NodeRuntime) !void {
        const resolver = self.fork_rpc_resolver orelse return error.ForkResolverUnavailable;
        const backend = self.fork_backend orelse return error.ForkNotEnabled;
        const fork_cfg = self.fork_config orelse return error.ForkNotEnabled;

        while (backend.nextRequest()) |request| {
            const method_name: []const u8 = switch (request.kind) {
                .code => "eth_getCode",
                .account_proof, .storage_proof => "eth_getProof",
            };

            const response_payload = resolver.resolve(
                resolver.context,
                self.allocator,
                .{
                    .url = fork_cfg.url,
                    .method = method_name,
                    .params_json = request.params_json,
                },
            ) catch |err| {
                log.warn(.fork, "fork upstream request failed method={s} error={s}", .{ method_name, @errorName(err) });
                return err;
            };
            defer self.allocator.free(response_payload);

            backend.continueRequest(request.id, response_payload) catch |err| {
                log.warn(.fork, "fork upstream response rejected method={s} error={s}", .{ method_name, @errorName(err) });
                return err;
            };
        }
    }

    fn cloneQueryIndexes(self: *const NodeRuntime) !QueryIndexSnapshot {
        return cloneQueryIndexSnapshot(
            self.allocator,
            &self.blockchain,
            &self.receipt_index,
            &self.log_index,
        );
    }

    fn replaceQueryIndexes(self: *NodeRuntime, query_indexes: QueryIndexSnapshot) void {
        self.log_index.deinit(self.allocator);
        self.receipt_index.deinit(self.allocator);
        self.blockchain.deinit();
        self.clearOwnedBlockBodies();
        self.owned_block_bodies.deinit(self.allocator);

        self.blockchain = query_indexes.blockchain;
        self.owned_block_bodies = query_indexes.owned_block_bodies;
        self.receipt_index = query_indexes.receipt_index;
        self.log_index = query_indexes.log_index;
    }

    fn clearSnapshots(self: *NodeRuntime) void {
        var it = self.snapshots.valueIterator();
        while (it.next()) |entry| {
            deinitSnapshotEntry(self.allocator, entry);
        }
        self.snapshots.clearRetainingCapacity();
        self.next_snapshot_id = 1;
    }

    fn resetQueryIndexes(self: *NodeRuntime) !void {
        const genesis_state_root = try block_builder.computeStateRoot(self.allocator, &self.state);
        var new_blockchain = try initBlockchainWithGenesis(
            self.allocator,
            self.chain_id,
            genesis_state_root,
            self.default_coinbase,
            self.dev_runtime.default_block_gas_limit,
            .{},
        );
        errdefer new_blockchain.deinit();

        var new_receipt_index = receipt_index_mod.ReceiptIndex.init(self.allocator);
        errdefer new_receipt_index.deinit(self.allocator);

        var new_log_index = log_index_mod.LogIndex.init();
        errdefer new_log_index.deinit(self.allocator);

        self.log_index.deinit(self.allocator);
        self.receipt_index.deinit(self.allocator);
        self.blockchain.deinit();
        self.clearOwnedBlockBodies();

        self.blockchain = new_blockchain;
        self.receipt_index = new_receipt_index;
        self.log_index = new_log_index;
    }

    fn persistMinedBlock(
        self: *NodeRuntime,
        block_ctx: guillotine_mini.BlockContext,
        block_excess_blob_gas: u64,
        result: *block_builder.BlockResult,
        ready: []const txpool.PooledTransaction,
    ) ![32]u8 {
        const transactions = try self.cloneIncludedBlockTransactions(result, ready);
        var transactions_owned_by_runtime = false;
        errdefer if (!transactions_owned_by_runtime) freeBlockTransactions(self.allocator, transactions);

        const parent = (try self.blockchain.getBlockByNumber(self.head_block_number)) orelse return error.MissingParentBlock;
        const hardfork = self.hardforkForBlockContext(block_ctx);
        const transactions_root = try block_builder.computeRawTransactionsRoot(self.allocator, transactions);

        var header = primitives.BlockHeader.BlockHeader{
            .parent_hash = parent.hash,
            .ommers_hash = primitives.BlockHeader.EMPTY_OMMERS_HASH,
            .beneficiary = block_ctx.block_coinbase,
            .state_root = result.state_root,
            .transactions_root = transactions_root,
            .receipts_root = result.receipts_root,
            .logs_bloom = result.logs_bloom,
            .difficulty = 0,
            .number = block_ctx.block_number,
            .gas_limit = block_ctx.block_gas_limit,
            .gas_used = result.total_gas_used,
            .timestamp = block_ctx.block_timestamp,
            .base_fee_per_gas = if (hardfork.isAtLeast(.LONDON)) block_ctx.block_base_fee else null,
            .withdrawals_root = if (hardfork.isAtLeast(.SHANGHAI))
                (result.withdrawals_root orelse primitives.BlockHeader.EMPTY_WITHDRAWALS_ROOT)
            else
                null,
            .blob_gas_used = if (hardfork.isAtLeast(.CANCUN)) result.blob_gas_used else null,
            .excess_blob_gas = if (hardfork.isAtLeast(.CANCUN)) block_excess_blob_gas else null,
            .parent_beacon_block_root = if (hardfork.isAtLeast(.CANCUN)) primitives.Hash.ZERO else null,
        };
        _ = &header;

        const empty_withdrawals: []const primitives.BlockBody.Withdrawal = &.{};
        const body = primitives.BlockBody.BlockBody{
            .transactions = transactions,
            .ommers = &.{},
            .withdrawals = if (header.withdrawals_root != null) empty_withdrawals else null,
        };

        const block = try primitives.Block.from(&header, &body, self.allocator);
        try finalizeReceiptsForBlock(result, ready, block.hash, block.header.number);

        try self.blockchain.putBlock(block);
        try self.blockchain.setCanonicalHead(block.hash);
        try self.owned_block_bodies.append(self.allocator, .{ .transactions = transactions });
        transactions_owned_by_runtime = true;

        try self.receipt_index.putBlockReceipts(self.allocator, block.hash, result.receipts);
        try self.log_index.appendBlockLogs(self.allocator, block.header.number, block.hash, result.receipts);

        return block.hash;
    }

    fn cloneIncludedBlockTransactions(
        self: *NodeRuntime,
        result: *const block_builder.BlockResult,
        ready: []const txpool.PooledTransaction,
    ) ![]primitives.BlockBody.TransactionData {
        const transactions = try self.allocator.alloc(primitives.BlockBody.TransactionData, result.included_tx_indexes.len);
        var initialized: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < initialized) : (i += 1) {
                self.allocator.free(transactions[i].raw);
            }
            self.allocator.free(transactions);
        }

        for (result.included_tx_indexes, 0..) |ready_index, out_index| {
            if (ready_index >= ready.len) return error.InvalidIncludedTransactionIndex;
            const pooled = ready[ready_index];
            const raw = if (pooled.raw.len > 0)
                try self.allocator.dupe(u8, pooled.raw)
            else
                try tx_encoding.encodeLegacyTransactionEnvelope(
                    self.allocator,
                    NodeRuntime.executionTransactionFromPooled(pooled).tx,
                );
            transactions[out_index] = .{ .raw = raw };
            initialized += 1;
        }

        return transactions;
    }

    fn minedHashesFromResult(
        self: *NodeRuntime,
        result: block_builder.BlockResult,
        ready: []const txpool.PooledTransaction,
    ) ![][32]u8 {
        const hashes = try self.allocator.alloc([32]u8, result.included_tx_indexes.len);
        for (result.included_tx_indexes, 0..) |ready_index, i| {
            if (ready_index >= ready.len) return error.InvalidIncludedTransactionIndex;
            hashes[i] = ready[ready_index].hash;
        }
        return hashes;
    }

    fn clearOwnedBlockBodies(self: *NodeRuntime) void {
        clearOwnedBlockBodyList(self.allocator, &self.owned_block_bodies);
    }
};

fn deinitSnapshotEntry(allocator: std.mem.Allocator, entry: *SnapshotEntry) void {
    freeForkConfig(allocator, entry.fork_config);
    entry.query_indexes.deinit(allocator);
    entry.pool.deinit();
    entry.impersonated_accounts.deinit();
}

fn cloneQueryIndexSnapshot(
    allocator: std.mem.Allocator,
    source_blockchain: *const blockchain_mod.Blockchain,
    source_receipt_index: *const receipt_index_mod.ReceiptIndex,
    source_log_index: *const log_index_mod.LogIndex,
) !QueryIndexSnapshot {
    var blockchain = try blockchain_mod.Blockchain.init(allocator, null);
    errdefer blockchain.deinit();

    var owned_block_bodies = std.ArrayList(OwnedBlockBody){};
    errdefer {
        clearOwnedBlockBodyList(allocator, &owned_block_bodies);
        owned_block_bodies.deinit(allocator);
    }

    try cloneBlockStore(
        allocator,
        &source_blockchain.block_store,
        &blockchain.block_store,
        &owned_block_bodies,
    );

    var receipt_index = try source_receipt_index.clone(allocator);
    errdefer receipt_index.deinit(allocator);

    var log_index = try source_log_index.clone(allocator);
    errdefer log_index.deinit(allocator);

    return .{
        .blockchain = blockchain,
        .owned_block_bodies = owned_block_bodies,
        .receipt_index = receipt_index,
        .log_index = log_index,
    };
}

fn cloneBlockStore(
    allocator: std.mem.Allocator,
    source: anytype,
    target: anytype,
    owned_block_bodies: *std.ArrayList(OwnedBlockBody),
) !void {
    var block_it = source.blocks.iterator();
    while (block_it.next()) |entry| {
        var block = entry.value_ptr.*;
        const owned_body = try chain_import.cloneBlockBody(allocator, &block);
        var owned = false;
        errdefer if (!owned) {
            var mutable = owned_body;
            mutable.deinit(allocator);
        };
        try owned_block_bodies.append(allocator, owned_body);
        owned = true;
        try target.blocks.put(entry.key_ptr.*, block);
    }

    var canonical_it = source.canonical_chain.iterator();
    while (canonical_it.next()) |entry| {
        try target.canonical_chain.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    var orphan_it = source.orphans.iterator();
    while (orphan_it.next()) |entry| {
        try target.orphans.put(entry.key_ptr.*, entry.value_ptr.*);
    }
}

fn clearOwnedBlockBodyList(
    allocator: std.mem.Allocator,
    owned_block_bodies: *std.ArrayList(OwnedBlockBody),
) void {
    for (owned_block_bodies.items) |*entry| {
        entry.deinit(allocator);
    }
    owned_block_bodies.clearRetainingCapacity();
}

fn finalizeReceiptsForBlock(
    result: *block_builder.BlockResult,
    ready: []const txpool.PooledTransaction,
    block_hash: [32]u8,
    block_number: u64,
) !void {
    var log_index: u32 = 0;
    for (result.receipts, 0..) |*receipt, receipt_index| {
        const ready_index = result.included_tx_indexes[receipt_index];
        if (ready_index >= ready.len) return error.InvalidIncludedTransactionIndex;
        receipt.transaction_hash = ready[ready_index].hash;
        receipt.transaction_index = @intCast(receipt_index);
        receipt.block_hash = block_hash;
        receipt.block_number = block_number;

        const logs = @constCast(receipt.logs);
        for (logs) |*event_log| {
            event_log.block_number = block_number;
            event_log.transaction_hash = receipt.transaction_hash;
            event_log.transaction_index = receipt.transaction_index;
            event_log.log_index = log_index;
            log_index += 1;
        }
    }
}

fn freeBlockTransactions(
    allocator: std.mem.Allocator,
    transactions: []const primitives.BlockBody.TransactionData,
) void {
    chain_import.freeTransactions(allocator, transactions);
}

fn initBlockchainWithGenesis(
    allocator: std.mem.Allocator,
    chain_id: u64,
    state_root: [32]u8,
    coinbase: primitives.Address,
    gas_limit: u64,
    genesis_header: genesis_alloc.HeaderConfig,
) !blockchain_mod.Blockchain {
    _ = chain_id;
    var blockchain = try blockchain_mod.Blockchain.init(allocator, null);
    errdefer blockchain.deinit();

    const header = primitives.BlockHeader.BlockHeader{
        .parent_hash = genesis_header.parent_hash,
        .ommers_hash = primitives.BlockHeader.EMPTY_OMMERS_HASH,
        .beneficiary = genesis_header.beneficiary orelse coinbase,
        .state_root = state_root,
        .transactions_root = primitives.BlockHeader.EMPTY_TRANSACTIONS_ROOT,
        .receipts_root = primitives.BlockHeader.EMPTY_RECEIPTS_ROOT,
        .logs_bloom = [_]u8{0} ** primitives.BlockHeader.BLOOM_SIZE,
        .difficulty = genesis_header.difficulty,
        .number = 0,
        .gas_limit = gas_limit,
        .gas_used = 0,
        .timestamp = genesis_header.timestamp,
        .extra_data = genesis_header.extraData(),
        .mix_hash = genesis_header.mix_hash,
        .nonce = genesis_header.nonce,
        .base_fee_per_gas = genesis_header.base_fee_per_gas,
        .withdrawals_root = genesis_header.withdrawals_root,
        .blob_gas_used = genesis_header.blob_gas_used,
        .excess_blob_gas = genesis_header.excess_blob_gas,
        .parent_beacon_block_root = genesis_header.parent_beacon_block_root,
    };
    const body = primitives.BlockBody.init();
    const genesis_block = try primitives.Block.from(&header, &body, allocator);
    try blockchain.putBlock(genesis_block);
    try blockchain.setCanonicalHead(genesis_block.hash);
    return blockchain;
}

pub fn isManagedDevAccount(address: primitives.Address) bool {
    for (&DEFAULT_DEV_ACCOUNTS) |managed| {
        if (std.mem.eql(u8, &managed.bytes, &address.bytes)) return true;
    }
    return false;
}

fn miningCoordinatorFromRuntime(rt: *const NodeRuntime) mining_coordinator.MiningCoordinator {
    var coordinator = miningCoordinatorFromConfig(rt.mining_config);
    coordinator.current_block_number = rt.head_block_number + 1;
    coordinator.current_timestamp = rt.pendingBlockTimestamp();
    coordinator.chain_id = rt.chain_id;
    coordinator.chain_config = rt.hardfork_config;
    coordinator.coinbase = rt.coinbase;
    coordinator.block_gas_limit = rt.dev_runtime.config.block_gas_limit;
    coordinator.current_base_fee_per_gas = rt.base_fee;
    return coordinator;
}

fn miningCoordinatorFromConfig(config: mining.MiningConfig) mining_coordinator.MiningCoordinator {
    var coordinator = mining_coordinator.MiningCoordinator.init();
    switch (config) {
        .auto => coordinator.setMode(.auto),
        .manual => coordinator.setMode(.manual),
        .interval => |interval| {
            coordinator.mode = .interval;
            coordinator.interval_seconds = interval.block_time;
        },
    }
    return coordinator;
}

fn miningConfigFromCoordinator(coordinator: mining_coordinator.MiningCoordinator) mining.MiningConfig {
    return switch (coordinator.mode) {
        .auto => .auto,
        .manual => .manual,
        .interval => .{ .interval = .{ .block_time = coordinator.interval_seconds } },
    };
}

fn miningConfigName(config: mining.MiningConfig) []const u8 {
    return switch (config) {
        .auto => "auto",
        .manual => "manual",
        .interval => "interval",
    };
}

fn initLightModeState(allocator: std.mem.Allocator, config: LightConfig) !LightModeState {
    if (config.consensus_rpc_url.len == 0) return error.MissingConsensusRpcUrl;

    const consensus_rpc_url = try allocator.dupe(u8, config.consensus_rpc_url);
    errdefer allocator.free(consensus_rpc_url);

    const proof_rpc_url = try allocator.dupe(u8, config.proof_rpc_url orelse config.consensus_rpc_url);
    errdefer allocator.free(proof_rpc_url);

    var network_config = config.network.networkConfig(consensus_rpc_url);
    if (config.max_checkpoint_age_seconds) |max_age| {
        network_config.max_checkpoint_age = max_age;
    }
    network_config.strict_checkpoint_age = config.strict_checkpoint_age;

    const selected = try selectStartupCheckpoint(allocator, network_config.default_checkpoint, config);

    var engine = consensus_sync.ConsensusSyncEngine.init(network_config);
    engine.last_checkpoint = selected.checkpoint_hash;
    const finalized_head = LightReadHead{
        .state_root = engine.store.finalized_header.execution.state_root,
        .block_number = engine.store.finalized_header.execution.block_number,
    };

    const checkpoint_hex = std.fmt.bytesToHex(selected.checkpoint_hash, .lower);
    log.info(.startup, "light checkpoint resolved network={s} source={s} checkpoint=0x{s}", .{
        config.network.name(),
        selected.source.name(),
        checkpoint_hex[0..],
    });

    return .{
        .network = config.network,
        .checkpoint_source = selected.source,
        .startup_checkpoint = selected.checkpoint_hash,
        .engine = engine,
        .safe_slot = engine.safeSlot(),
        .safe_head = finalized_head,
        .retained_heads = .{},
        .proof_source = .{
            .url = proof_rpc_url,
            .resolver = config.proof_resolver,
        },
        .advance_on_request = config.advance_on_request,
    };
}

const SelectedCheckpoint = struct {
    checkpoint_hash: [32]u8,
    source: CheckpointSource,
};

fn selectStartupCheckpoint(
    allocator: std.mem.Allocator,
    default_checkpoint: [32]u8,
    config: LightConfig,
) !SelectedCheckpoint {
    if (config.checkpoint) |explicit| {
        return .{
            .checkpoint_hash = explicit,
            .source = config.checkpoint_source orelse .explicit,
        };
    }

    if (config.checkpoint_dir) |dir_path| {
        if (checkpoint.checkpointExists(dir_path)) {
            return .{
                .checkpoint_hash = try checkpoint.loadCheckpoint(allocator, dir_path),
                .source = config.checkpoint_source orelse .persisted,
            };
        }
    }

    return .{
        .checkpoint_hash = default_checkpoint,
        .source = config.checkpoint_source orelse .default,
    };
}

fn validateForkUrl(url: []const u8) !void {
    if (url.len == 0) return error.InvalidForkUrl;

    for (url) |byte| {
        if (byte <= ' ' or byte == 0x7f) return error.InvalidForkUrl;
    }

    const uri = std.Uri.parse(url) catch return error.InvalidForkUrl;
    if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) {
        return error.InvalidForkUrl;
    }

    const host = uri.host orelse return error.InvalidForkUrl;
    if (host.isEmpty()) return error.InvalidForkUrl;
}

fn allocForkConfig(allocator: std.mem.Allocator, fork: ?ForkConfig) !?ForkConfig {
    if (fork) |value| {
        try validateForkUrl(value.url);
        return .{
            .url = try allocator.dupe(u8, value.url),
            .block_number = value.block_number,
        };
    }
    return null;
}

fn freeForkConfig(allocator: std.mem.Allocator, fork: ?ForkConfig) void {
    if (fork) |value| {
        allocator.free(value.url);
    }
}

fn createForkBackend(
    allocator: std.mem.Allocator,
    fork: ?ForkConfig,
) !?*state_manager.ForkBackend {
    if (fork) |fork_cfg| {
        _ = fork_cfg.url;

        const block_tag = if (fork_cfg.block_number) |block_number|
            try std.fmt.allocPrint(allocator, "0x{x}", .{block_number})
        else
            try allocator.dupe(u8, "latest");
        defer allocator.free(block_tag);

        const backend = try allocator.create(state_manager.ForkBackend);
        errdefer allocator.destroy(backend);
        backend.* = try state_manager.ForkBackend.init(allocator, block_tag, .{});
        return backend;
    }
    return null;
}

fn destroyForkBackend(allocator: std.mem.Allocator, backend: ?*state_manager.ForkBackend) void {
    if (backend) |fork_backend| {
        fork_backend.deinit();
        allocator.destroy(fork_backend);
    }
}

fn currentUnixSeconds() u64 {
    const now = std.time.timestamp();
    if (now <= 0) return 0;
    return @intCast(now);
}

fn resolveForkRpcViaHttp(
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    request: ForkRpcRequest,
) ![]u8 {
    _ = context;

    const request_body = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\",\"params\":{s}}}",
        .{ request.method, request.params_json },
    );
    defer allocator.free(request_body);

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var response_writer = std.Io.Writer.Allocating.init(allocator);
    defer response_writer.deinit();

    const response = try client.fetch(.{
        .location = .{ .url = request.url },
        .method = .POST,
        .payload = request_body,
        .extra_headers = &[_]std.http.Header{
            .{
                .name = "content-type",
                .value = "application/json",
            },
        },
        .response_writer = &response_writer.writer,
    });
    if (response.status != .ok) {
        return error.UpstreamRpcFailed;
    }

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_writer.written(), .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidUpstreamRpcResponse;
    const result = parsed.value.object.get("result") orelse return error.InvalidUpstreamRpcResponse;
    return try stringifyJsonValue(allocator, result);
}

fn stringifyJsonValue(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    try std.json.Stringify.value(value, .{}, &writer.writer);
    return writer.toOwnedSlice();
}
