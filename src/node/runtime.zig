const browser = @import("builtin").os.tag == .wasi;
const exex = @import("../exex.zig");
const evm_backend = @import("../evm_backend.zig");
const rebase_fork = @import("../rebase_fork.zig");
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
const console_log = @import("../console_log.zig");
const host_adapter = @import("../host_adapter.zig");
const dev_runtime_mod = @import("../rpc/dev_runtime.zig");
const receipt_index_mod = @import("../receipt_index.zig");
const log_index_mod = @import("../log_index.zig");
const checkpoint = @import("../checkpoint.zig");
const consensus_sync = @import("../consensus_sync.zig");
const hardfork_schedule = @import("../hardfork_schedule.zig");
const blob_fee = @import("../blob_fee.zig");
const blob_kzg = @import("../blob_kzg.zig");
const beacon_api = @import("../beacon_api.zig");
const light_proof = @import("../light_proof.zig");
const tx_encoding = @import("../transaction_encoding.zig");
const log = @import("../log.zig");
const rpc_parse = @import("../rpc/parse.zig");
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
    .constantinople_block = 0,
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
    .blob_schedule = hardfork_schedule.BlobSchedule.empty,
};

pub fn defaultHardforkConfigForChainId(chain_id: u64) hardfork_schedule.ChainConfig {
    return if (chain_id == 1) hardfork_schedule.MAINNET_CHAIN_CONFIG else DEFAULT_DEV_HARDFORK_CONFIG;
}

pub const Mode = enum { trusted, light };

pub const LightNetwork = enum {
    mainnet,
    sepolia,
    holesky,
    hoodi,

    pub fn fromString(value: []const u8) !LightNetwork {
        if (std.mem.eql(u8, value, "mainnet")) return .mainnet;
        if (std.mem.eql(u8, value, "sepolia")) return .sepolia;
        if (std.mem.eql(u8, value, "holesky")) return .holesky;
        if (std.mem.eql(u8, value, "hoodi")) return .hoodi;
        return error.InvalidLightNetwork;
    }

    pub fn name(self: LightNetwork) []const u8 {
        return switch (self) {
            .mainnet => "mainnet",
            .sepolia => "sepolia",
            .holesky => "holesky",
            .hoodi => "hoodi",
        };
    }

    pub fn networkConfig(self: LightNetwork, consensus_rpc_url: []const u8) consensus_sync.NetworkConfig {
        return switch (self) {
            .mainnet => consensus_sync.NetworkConfig.mainnet(consensus_rpc_url),
            .sepolia => consensus_sync.NetworkConfig.sepolia(consensus_rpc_url),
            .holesky => consensus_sync.NetworkConfig.holesky(consensus_rpc_url),
            .hoodi => consensus_sync.NetworkConfig.hoodi(consensus_rpc_url),
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
    follow: bool = false,
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
    fork_follow: bool = false,
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
    engine_sync_fallback_url: ?[]const u8 = null,
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
    /// Owned copy of `LightConfig.checkpoint_dir`; new finalized checkpoints
    /// are persisted here so restarts resume from the latest verified root.
    checkpoint_dir: ?[]u8 = null,
    /// Last checkpoint written to (or loaded from) `checkpoint_dir`.
    persisted_checkpoint: ?[32]u8 = null,

    pub fn deinit(self: *LightModeState, allocator: std.mem.Allocator) void {
        if (self.checkpoint_dir) |dir| allocator.free(dir);
        self.checkpoint_dir = null;
        self.retained_heads.deinit(allocator);
        allocator.free(self.engine.config.consensus_rpc);
        allocator.free(self.proof_source.url);
    }

    /// Writes the engine's latest finalized checkpoint to `checkpoint_dir`
    /// when it changed. Persistence failures are logged, never fatal: the
    /// verified in-memory store stays authoritative.
    pub fn persistLatestCheckpoint(self: *LightModeState, allocator: std.mem.Allocator) void {
        const dir = self.checkpoint_dir orelse return;
        const latest = self.engine.lastCheckpoint() orelse return;
        if (self.persisted_checkpoint) |saved| {
            if (std.mem.eql(u8, &saved, &latest)) return;
        }
        checkpoint.saveCheckpoint(allocator, dir, latest) catch |err| {
            log.warn(.consensus_sync, "light_checkpoint_save_failed error={s}", .{@errorName(err)});
            return;
        };
        self.persisted_checkpoint = latest;
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

pub const EnginePayloadImportStatus = enum {
    valid,
    invalid,
    invalid_block_hash,
    syncing,
};

pub const EnginePayloadImportResult = struct {
    status: EnginePayloadImportStatus,
    latest_valid_hash: ?[32]u8 = null,
    validation_error: ?[]const u8 = null,
};

const EngineInvalidPayloadRecord = struct {
    latest_valid_hash: ?[32]u8 = null,
    validation_error: ?[]const u8 = null,
};

const ENGINE_SYNC_FALLBACK_MAX_ANCESTORS: usize = 512;

/// Runtime table caps. RPC callers can create these entries at will, so each
/// table is bounded to keep a public node's memory flat.
pub const MAX_RPC_FILTERS: usize = 256;
pub const MAX_SNAPSHOTS: usize = 64;
pub const MAX_ENGINE_PAYLOAD_JOBS: usize = 32;
pub const MAX_ENGINE_INVALID_PAYLOADS: usize = 256;
pub const MAX_PENDING_TRANSACTION_FILTER_EVENTS: usize = 4096;
/// Largest fork-upstream JSON-RPC response body accepted.
pub const MAX_FORK_RPC_RESPONSE_BYTES: usize = 32 * 1024 * 1024;

/// Bounded exponential backoff for the background light-client startup sync.
pub const LIGHT_STARTUP_RETRY_MIN_MS: u64 = 1_000;
pub const LIGHT_STARTUP_RETRY_MAX_MS: u64 = 30_000;
const LIGHT_STARTUP_RETRY_POLL_MS: u64 = 100;

/// Errors that prove the payload itself violates consensus rules. Only these
/// are cached as INVALID; every other error (allocation, EVM setup, state
/// backend, RPC, or an error added later) is treated as a local fault so a
/// valid block is never permanently poisoned.
pub fn isDeterministicPayloadError(err: anyerror) bool {
    return switch (err) {
        // Block size, header, and body validation (block_builder, chain_import).
        error.BlockRlpSizeExceeded,
        error.BlockGasLimitExceeded,
        error.BaseFeeBeforeLondon,
        error.BaseFeeOverflow,
        error.BeaconRootBeforeCancun,
        error.BlobFieldsBeforeCancun,
        error.BlobGasBeforeCancun,
        error.BlobGasLimitExceeded,
        error.BlobGasOverflow,
        error.BalanceOverflow,
        error.ExtraDataTooLarge,
        error.GasOverflow,
        error.HeaderGasUsedExceedsLimit,
        error.InvalidBaseFeePerGas,
        error.InvalidBlobGasUsed,
        error.InvalidBlockNumber,
        error.InvalidDepositEventLayout,
        error.InvalidExcessBlobGas,
        error.InvalidGasLimit,
        error.InvalidGasLimitDelta,
        error.InvalidGasUsed,
        error.InvalidLogsBloom,
        error.InvalidOmmerReward,
        error.InvalidOmmersHash,
        error.InvalidParentHash,
        error.InvalidPostParisDifficulty,
        error.InvalidPostParisNonce,
        error.InvalidPostParisOmmersHash,
        error.InvalidReceipt,
        error.InvalidReceiptsRoot,
        error.InvalidRequestsHash,
        error.InvalidStateRoot,
        error.InvalidTimestamp,
        error.InvalidTransactionsRoot,
        error.InvalidWithdrawalsRoot,
        error.MissingBaseFeePerGas,
        error.MissingBlobGasUsed,
        error.MissingExcessBlobGas,
        error.MissingParentBeaconBlockRoot,
        error.MissingWithdrawals,
        error.MissingWithdrawalsRoot,
        error.SystemContractCallFailed,
        error.SystemContractMissingCode,
        error.TooManyTransactions,
        error.TransactionReceiptCountMismatch,
        error.TransactionSizeCountMismatch,
        error.WithdrawalAmountOverflow,
        error.WithdrawalsBeforeShanghai,
        error.WithdrawalsRootBeforeShanghai,
        // Transaction validity (tx_processor.TxError minus local faults).
        error.TooManyBlobs,
        error.InsufficientBalance,
        error.NonceMismatch,
        error.SenderNotEOA,
        error.UnsupportedTransactionType,
        error.TransactionGasLimitExceeded,
        error.IntrinsicGasExceedsLimit,
        error.GasPriceBelowBaseFee,
        error.TipExceedsFeeCap,
        error.InitcodeTooLarge,
        error.EmptyBlobHashes,
        error.InvalidBlobVersionedHash,
        error.EmptyAuthorizationList,
        error.ContractCreationNotAllowed,
        error.InvalidTransactionChainId,
        // Transaction envelope decoding (RLP) and signature recovery.
        error.InputTooShort,
        error.InputTooLong,
        error.LeadingZeros,
        error.NonCanonicalSize,
        error.NonCanonicalInteger,
        error.InvalidLength,
        error.UnexpectedInput,
        error.InvalidRemainder,
        error.ExtraZeros,
        error.RecursionDepthExceeded,
        error.RlpPayloadTooLarge,
        error.Overflow,
        error.InvalidTransactionType,
        error.UnsupportedBlobWrapperVersion,
        error.InvalidSignature,
        error.InvalidSignatureV,
        error.InvalidRecoveryId,
        error.InvalidPublicKey,
        error.RecoveryFailed,
        => true,
        else => false,
    };
}

const FetchedEngineFallbackBlock = struct {
    block: primitives.Block.Block,
    owned_body: OwnedBlockBody,
    requests_hash: ?[32]u8,

    fn deinit(self: *FetchedEngineFallbackBlock, allocator: std.mem.Allocator) void {
        self.owned_body.deinit(allocator);
    }
};

pub const EnginePayloadAttributes = struct {
    timestamp: u64,
    prev_randao: [32]u8,
    fee_recipient: primitives.Address,
    withdrawals: []const primitives.BlockBody.Withdrawal = &.{},
    has_withdrawals: bool = false,
    parent_beacon_block_root: ?[32]u8 = null,
    payload_version: u8 = 1,

    pub fn deinit(self: *EnginePayloadAttributes, allocator: std.mem.Allocator) void {
        if (self.withdrawals.len > 0) allocator.free(self.withdrawals);
        self.withdrawals = &.{};
    }
};

pub const EnginePayloadJob = struct {
    parent_hash: [32]u8,
    attrs: EnginePayloadAttributes,

    pub fn deinit(self: *EnginePayloadJob, allocator: std.mem.Allocator) void {
        self.attrs.deinit(allocator);
    }
};

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

const CanonicalMaterialization = struct {
    state: state_manager.StateManager,
    receipt_index: receipt_index_mod.ReceiptIndex,
    log_index: log_index_mod.LogIndex,

    fn deinit(self: *CanonicalMaterialization, allocator: std.mem.Allocator) void {
        self.state.deinit();
        self.receipt_index.deinit(allocator);
        self.log_index.deinit(allocator);
    }
};

const SnapshotEntry = struct {
    local_tx_count: usize = 0,
    state_snapshot_id: u64,
    head_block_number: u64,
    canonical_head_hash: ?[32]u8,
    head_block_timestamp: u64,
    engine_safe_hash: ?[32]u8,
    engine_finalized_hash: ?[32]u8,
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

pub const RpcFilter = union(enum) {
    block: BlockFilterState,
    pending_transaction: PendingTransactionFilterState,
    log: LogFilterState,

    pub fn deinit(self: *RpcFilter, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .block, .pending_transaction => {},
            .log => |*state| {
                log_index_mod.deinitLogFilter(allocator, &state.filter);
            },
        }
    }
};

pub const BlockFilterState = struct {
    last_block_number: u64,
};

pub const PendingTransactionFilterState = struct {
    next_event_index: usize,
};

pub const LogFilterState = struct {
    filter: log_index_mod.LogFilter,
    next_block_number: u64,
    to_block_omitted: bool,
    block_hash_polled: bool = false,
};

pub const RebaseSummary = struct {
    old_fork_block: u64,
    new_fork_block: u64,
    replayed_count: usize = 0,
    skipped_reexecution_count: usize = 0,
    dropped_count: usize = 0,
};

// Collect dynamic dependencies at the EVM host boundary. The transaction
// processor still receives its normal HostAdapter for error propagation.
const RebaseAccessObserver = struct {
    allocator: std.mem.Allocator,
    access: *rebase_fork.TxAccessSet,
    host: guillotine_mini.HostInterface = undefined,
    failed: bool = false,
    fn execute(context: ?*anyopaque, a: std.mem.Allocator, request: evm_backend.ExecutionRequest) evm_backend.ExecuteError!evm_backend.ExecutionResult {
        const self: *RebaseAccessObserver = @ptrCast(@alignCast(context.?));
        self.host = request.host;
        var traced = request;
        traced.host = .{ .ptr = self, .vtable = &vtable };
        for (request.warm_addresses) |address| try self.access.recordAccountRead(self.allocator, address.bytes);
        var result = try evm_backend.default_backend.execute(a, traced);
        if (self.failed) {
            result.deinit(a);
            return error.OutOfMemory;
        }
        return result;
    }
    fn account(self: *RebaseAccessObserver, address: primitives.Address) void {
        self.access.recordAccountRead(self.allocator, address.bytes) catch {
            self.failed = true;
        };
    }
    const vtable = guillotine_mini.HostInterface.VTable{
        .getBalance = getBalance,
        .setBalance = setBalance,
        .getCode = getCode,
        .setCode = setCode,
        .getNonce = getNonce,
        .setNonce = setNonce,
        .getStorage = getStorage,
        .setStorage = setStorage,
        .accountExists = accountExists,
        .deleteAccount = deleteAccount,
    };
    fn getBalance(ptr: *anyopaque, address: primitives.Address) u256 {
        const self: *RebaseAccessObserver = @ptrCast(@alignCast(ptr));
        self.account(address);
        return self.host.getBalance(address);
    }
    fn setBalance(ptr: *anyopaque, address: primitives.Address, balance: u256) void {
        const self: *RebaseAccessObserver = @ptrCast(@alignCast(ptr));
        self.account(address);
        return self.host.setBalance(address, balance);
    }
    fn getCode(ptr: *anyopaque, address: primitives.Address) []const u8 {
        const self: *RebaseAccessObserver = @ptrCast(@alignCast(ptr));
        self.account(address);
        return self.host.getCode(address);
    }
    fn setCode(ptr: *anyopaque, address: primitives.Address, code: []const u8) void {
        const self: *RebaseAccessObserver = @ptrCast(@alignCast(ptr));
        self.account(address);
        return self.host.setCode(address, code);
    }
    fn getNonce(ptr: *anyopaque, address: primitives.Address) u64 {
        const self: *RebaseAccessObserver = @ptrCast(@alignCast(ptr));
        self.account(address);
        return self.host.getNonce(address);
    }
    fn setNonce(ptr: *anyopaque, address: primitives.Address, nonce: u64) void {
        const self: *RebaseAccessObserver = @ptrCast(@alignCast(ptr));
        self.account(address);
        return self.host.setNonce(address, nonce);
    }
    fn getStorage(ptr: *anyopaque, address: primitives.Address, slot: u256) u256 {
        const self: *RebaseAccessObserver = @ptrCast(@alignCast(ptr));
        self.access.recordStorageRead(self.allocator, address.bytes, slot) catch {
            self.failed = true;
        };
        return self.host.getStorage(address, slot);
    }
    fn setStorage(ptr: *anyopaque, address: primitives.Address, slot: u256, value: u256) void {
        const self: *RebaseAccessObserver = @ptrCast(@alignCast(ptr));
        self.access.recordStorageRead(self.allocator, address.bytes, slot) catch {
            self.failed = true;
        };
        return self.host.setStorage(address, slot, value);
    }
    fn accountExists(ptr: *anyopaque, address: primitives.Address) bool {
        const self: *RebaseAccessObserver = @ptrCast(@alignCast(ptr));
        self.account(address);
        return self.host.accountExists(address);
    }
    fn deleteAccount(ptr: *anyopaque, address: primitives.Address) void {
        const self: *RebaseAccessObserver = @ptrCast(@alignCast(ptr));
        self.account(address);
        return self.host.deleteAccount(address);
    }
};

// RPC handlers hold this lock for a complete dispatch, including handlers
// that modify public runtime fields directly. Observe those changes before
// another request can see them. Nested runtime operations share the snapshot.
const RuntimeMutex = struct {
    const SenderNonce = struct { sender: [20]u8, nonce: u64 };
    inner: std.Thread.Mutex.Recursive = .init,
    observing: bool = false,
    chain_id: u64 = 0,
    coinbase: [20]u8 = undefined,
    gas_limit: u64 = 0,
    pool_before: std.AutoHashMapUnmanaged(SenderNonce, [32]u8) = .empty,
    pub fn lock(self: *RuntimeMutex) void {
        self.inner.lock();
        self.begin();
    }
    pub fn tryLock(self: *RuntimeMutex) bool {
        if (!self.inner.tryLock()) return false;
        self.begin();
        return true;
    }
    fn begin(self: *RuntimeMutex) void {
        const rt: *NodeRuntime = @alignCast(@fieldParentPtr("runtime_mutex", self));
        if (rt.event_hub == null or self.inner.lock_count != 1) return;
        self.observing = true;
        self.chain_id = rt.chain_id;
        self.coinbase = rt.coinbase.bytes;
        self.gas_limit = rt.dev_runtime.config.block_gas_limit;
        for (rt.pool.items()) |tx| self.pool_before.put(rt.allocator, .{ .sender = tx.sender.bytes, .nonce = tx.nonce }, tx.hash) catch break;
    }
    pub fn unlock(self: *RuntimeMutex) void {
        defer self.inner.unlock();
        if (!self.observing or self.inner.lock_count != 1) return;
        const rt: *NodeRuntime = @alignCast(@fieldParentPtr("runtime_mutex", self));
        self.observing = false;
        if (self.chain_id != rt.chain_id) rt.emitExEx(.{ .chain_id_changed = .{ .old_chain_id = self.chain_id, .new_chain_id = rt.chain_id } });
        if (!std.mem.eql(u8, &self.coinbase, &rt.coinbase.bytes)) rt.emitExEx(.{ .coinbase_changed = .{ .old_coinbase = self.coinbase, .new_coinbase = rt.coinbase.bytes } });
        if (self.gas_limit != rt.dev_runtime.config.block_gas_limit) rt.emitExEx(.{ .block_gas_limit_changed = .{ .old_gas_limit = self.gas_limit, .new_gas_limit = rt.dev_runtime.config.block_gas_limit } });
        var it = self.pool_before.valueIterator();
        while (it.next()) |hash| {
            if (!rt.pool.hash_index.contains(hash.*)) rt.emitExEx(.{ .tx_pool_drop = .{ .tx_hash = hash.*, .reason = .dropped } });
        }
        self.pool_before.clearRetainingCapacity();
    }
};
pub const NodeRuntime = struct {
    event_hub: ?*exex.EventHub = null,
    rebase_tracker: ?*rebase_fork.RebaseTracker = null,
    background_started: bool = false,
    rebase_mutex: std.Thread.Mutex = .{},
    light_last_status: ?consensus_sync.SyncStatus = null,
    light_last_ready: ?bool = null,
    light_last_checkpoint: ?[32]u8 = null,
    light_last_head_slots: ?[3]u64 = null,
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
    blob_verifier: blob_kzg.Verifier = .{},
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
    /// Hardhat console.log calldata captured since the last `tevm_drainConsoleLogs`.
    console_logs: console_log.ConsoleLogBuffer,
    state: state_manager.StateManager,
    blockchain: blockchain_mod.Blockchain,
    owned_block_bodies: std.ArrayList(OwnedBlockBody),
    genesis_alloc_path: ?[]u8,
    genesis_extra_data: ?[]u8,
    /// Genesis header overrides loaded at startup. `extra_data` aliases
    /// `genesis_extra_data`; reset rebuilds the same genesis from both.
    genesis_header: genesis_alloc.HeaderConfig,
    /// True when the chain came from a legacy RLP fixture file; replays then
    /// keep inferring the fork from header shape like the startup import did.
    legacy_fixture_chain: bool,
    receipt_index: receipt_index_mod.ReceiptIndex,
    log_index: log_index_mod.LogIndex,
    fork_config: ?ForkConfig,
    fork_backend: ?*state_manager.ForkBackend,
    fork_rpc_resolver: ?ForkRpcResolver,
    /// Latched after the fork upstream fails `eth_getProof` but answers the
    /// scalar read methods, so later reads skip the failing call. Cleared
    /// whenever the fork upstream changes.
    fork_proof_unavailable: bool = false,
    engine_sync_fallback_url: ?[]u8,
    snapshots: std.AutoHashMap(u64, SnapshotEntry),
    next_snapshot_id: u64,
    rpc_filters: std.AutoHashMap(u64, RpcFilter),
    next_rpc_filter_id: u64,
    engine_payload_jobs: std.AutoHashMap(u64, EnginePayloadJob),
    next_engine_payload_id: u64,
    engine_safe_hash: ?[32]u8,
    engine_finalized_hash: ?[32]u8,
    engine_import_state: ?state_manager.StateManager,
    engine_import_state_hash: ?[32]u8,
    replay_state_cache: ?state_manager.StateManager,
    replay_state_cache_number: ?u64,
    replay_state_cache_hash: ?[32]u8,
    engine_invalid_payloads: std.AutoHashMap([32]u8, EngineInvalidPayloadRecord),
    pending_transaction_filter_events: std.ArrayList([32]u8),
    impersonated_accounts: std.AutoHashMap(primitives.Address, bool),
    auto_impersonate_account: bool,
    runtime_mutex: RuntimeMutex,
    interval_thread: ?std.Thread,
    interval_stop_requested: std.atomic.Value(bool),
    light_sync_thread: ?std.Thread,
    light_sync_stop_requested: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator, config_opt: ?NodeConfig) !NodeRuntime {
        const config = config_opt orelse NodeConfig{};

        if (browser and (config.mode == .light or config.fork_url != null)) return error.ModeUnsupported;
        if (config.fork_block_number != null and config.fork_url == null) {
            return error.InvalidForkConfig;
        }
        if (config.coinbase_index >= DEFAULT_DEV_ACCOUNTS.len) {
            return error.InvalidCoinbaseIndex;
        }

        const owned_genesis_alloc_path = if (config.genesis_alloc_path) |path|
            try allocator.dupe(u8, path)
        else
            null;
        errdefer if (owned_genesis_alloc_path) |path| allocator.free(path);

        var light_state: ?LightModeState = if (!browser and config.mode == .light)
            try initLightModeState(allocator, config.light)
        else
            null;
        errdefer if (light_state) |*state| state.deinit(allocator);

        const runtime_chain_id = if (light_state) |state| state.engine.config.chain_id else config.chain_id;
        var runtime_hardfork_config = config.hardfork_config orelse defaultHardforkConfigForChainId(runtime_chain_id);
        // An out-of-order schedule silently resolves the wrong fork for some
        // blocks; reject it before any state is built.
        try hardfork_schedule.validateForkOrder(runtime_hardfork_config);

        const initial_fork_config = try allocForkConfig(allocator, if (config.mode == .trusted and config.fork_url != null) .{
            .url = config.fork_url.?,
            .block_number = config.fork_block_number,
            .follow = config.fork_follow,
        } else null);
        errdefer freeForkConfig(allocator, initial_fork_config);

        const owned_engine_sync_fallback_url = if (config.engine_sync_fallback_url) |url|
            try allocator.dupe(u8, url)
        else
            null;
        errdefer if (owned_engine_sync_fallback_url) |url| allocator.free(url);

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
            if (runtime_hardfork_config.deposit_contract_address == null) {
                runtime_hardfork_config.deposit_contract_address = loaded.deposit_contract_address;
            }
            break :blk loaded.account_count;
        } else blk: {
            // Seed deterministic dev accounts as the local writable overlay,
            // plus the canonical Cancun/Prague system contracts on a non-forked chain.
            try genesis.seedDevGenesisState(&state, &managed_accounts, config.initial_balance, fork_backend != null);
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
        const genesis_fallback_coinbase = if (config.genesis_alloc_path != null)
            primitives.Address.ZERO_ADDRESS
        else
            default_coinbase;
        var owned_block_bodies = std.ArrayList(OwnedBlockBody){};
        errdefer {
            clearOwnedBlockBodyList(allocator, &owned_block_bodies);
            owned_block_bodies.deinit(allocator);
        }

        var blockchain = try initBlockchainWithGenesis(
            allocator,
            runtime_chain_id,
            genesis_state_root,
            genesis_fallback_coinbase,
            genesis_gas_limit,
            genesis_header,
            runtime_hardfork_config,
            &owned_block_bodies,
        );
        errdefer blockchain.deinit();

        var receipt_index = receipt_index_mod.ReceiptIndex.init(allocator);
        errdefer receipt_index.deinit(allocator);

        var log_index = log_index_mod.LogIndex.init();
        errdefer log_index.deinit(allocator);

        var startup_head_block_number: u64 = 0;
        var startup_head_block_timestamp: u64 = genesis_header.timestamp;
        var startup_base_fee = config.base_fee;
        const genesis_blob_fee = if (genesis_header.excess_blob_gas) |excess|
            blob_fee.blobBaseFeeAt(runtime_hardfork_config, 0, genesis_header.timestamp, excess)
        else
            config.blob_base_fee;
        var startup_blob_fee = genesis_blob_fee;
        if (config.chain_rlp_path) |path| {
            const stats = try chain_import.importChainFileWithOptions(allocator, &blockchain, &owned_block_bodies, path, .{
                .hardfork_config = runtime_hardfork_config,
            });
            const imported_head = (try blockchain.getBlockByNumber(stats.head_block_number)) orelse return error.ImportedChainHeadMissing;
            startup_head_block_number = imported_head.header.number;
            startup_head_block_timestamp = imported_head.header.timestamp;
            if (imported_head.header.base_fee_per_gas != null) {
                const child_fork = hardfork_schedule.resolveHardforkWithConfig(
                    runtime_hardfork_config,
                    imported_head.header.number + 1,
                    imported_head.header.timestamp + 1,
                );
                if (child_fork.isAtLeast(.LONDON)) {
                    startup_base_fee = block_builder.expectedBaseFeePerGas(&imported_head.header) catch imported_head.header.base_fee_per_gas.?;
                } else {
                    startup_base_fee = imported_head.header.base_fee_per_gas.?;
                }
            }
            if (imported_head.header.excess_blob_gas) |excess| {
                startup_blob_fee = blob_fee.blobBaseFeeAt(
                    runtime_hardfork_config,
                    imported_head.header.number,
                    imported_head.header.timestamp,
                    excess,
                );
            }
            const head_hash_hex = std.fmt.bytesToHex(stats.head_hash, .lower);
            const materialized = try materializeImportedChain(
                allocator,
                &state,
                &blockchain,
                &receipt_index,
                &log_index,
                runtime_chain_id,
                runtime_hardfork_config,
                config.blob_base_fee,
                stats.head_block_number,
            );
            if (materialized.stopped_block_number) |stopped_block_number| {
                const last_materialized = if (stopped_block_number > 0) stopped_block_number - 1 else 0;
                startup_head_block_number = last_materialized;
                if (last_materialized > 0) {
                    const last_block = (try blockchain.getBlockByNumber(last_materialized)) orelse return error.ImportedChainHeadMissing;
                    startup_head_block_timestamp = last_block.header.timestamp;
                    if (last_block.header.base_fee_per_gas != null) {
                        const partial_child_fork = hardfork_schedule.resolveHardforkWithConfig(
                            runtime_hardfork_config,
                            last_block.header.number + 1,
                            last_block.header.timestamp + 1,
                        );
                        if (partial_child_fork.isAtLeast(.LONDON)) {
                            startup_base_fee = block_builder.expectedBaseFeePerGas(&last_block.header) catch last_block.header.base_fee_per_gas.?;
                        } else {
                            startup_base_fee = last_block.header.base_fee_per_gas.?;
                        }
                    }
                    if (last_block.header.excess_blob_gas) |excess| {
                        startup_blob_fee = blob_fee.blobBaseFeeAt(
                            runtime_hardfork_config,
                            last_block.header.number,
                            last_block.header.timestamp,
                            excess,
                        );
                    }
                } else {
                    startup_head_block_timestamp = genesis_header.timestamp;
                    startup_base_fee = config.base_fee;
                    startup_blob_fee = genesis_blob_fee;
                }
                pruneCanonicalChainAboveStatic(&blockchain, last_materialized, stats.head_block_number);
                log.warn(.startup, "chain_rlp_imported path={s} block_count={} tx_count={} head_block_number={} head_hash=0x{s} state_materialized=partial materialized_blocks={} materialized_txs={} receipts_indexed={} logs_indexed={} stopped_block_number={} receipt_root_mismatches={} logs_bloom_mismatches={} state_root_mismatches={}", .{
                    path,
                    stats.block_count,
                    stats.transaction_count,
                    stats.head_block_number,
                    &head_hash_hex,
                    materialized.block_count,
                    materialized.transaction_count,
                    materialized.receipt_count,
                    materialized.log_count,
                    stopped_block_number,
                    materialized.receipt_root_mismatch_count,
                    materialized.logs_bloom_mismatch_count,
                    materialized.state_root_mismatch_count,
                });
            } else if (materialized.state_root_mismatch_count > 0) {
                return error.ChainRlpStateRootMismatch;
            } else {
                log.warn(.startup, "chain_rlp_imported path={s} block_count={} tx_count={} head_block_number={} head_hash=0x{s} state_materialized=true materialized_blocks={} materialized_txs={} receipts_indexed={} logs_indexed={} receipt_root_mismatches={} logs_bloom_mismatches={} state_root_mismatches={}", .{
                    path,
                    stats.block_count,
                    stats.transaction_count,
                    stats.head_block_number,
                    &head_hash_hex,
                    materialized.block_count,
                    materialized.transaction_count,
                    materialized.receipt_count,
                    materialized.log_count,
                    materialized.receipt_root_mismatch_count,
                    materialized.logs_bloom_mismatch_count,
                    materialized.state_root_mismatch_count,
                });
            }
        }

        var snapshots = std.AutoHashMap(u64, SnapshotEntry).init(allocator);
        errdefer snapshots.deinit();

        var rpc_filters = std.AutoHashMap(u64, RpcFilter).init(allocator);
        errdefer rpc_filters.deinit();

        var engine_payload_jobs = std.AutoHashMap(u64, EnginePayloadJob).init(allocator);
        errdefer engine_payload_jobs.deinit();

        var engine_invalid_payloads = std.AutoHashMap([32]u8, EngineInvalidPayloadRecord).init(allocator);
        errdefer engine_invalid_payloads.deinit();

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
            .default_blob_base_fee = genesis_blob_fee,
            .default_max_priority_fee = config.max_priority_fee,
            .default_mining_config = config.mining_config,
            .hardfork_config = runtime_hardfork_config,
            .coinbase = default_coinbase,
            .head_block_number = startup_head_block_number,
            .head_block_timestamp = startup_head_block_timestamp,
            .gas_price = config.gas_price,
            .base_fee = startup_base_fee,
            .blob_base_fee = startup_blob_fee,
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
            .console_logs = console_log.ConsoleLogBuffer.init(allocator),
            .state = state,
            .blockchain = blockchain,
            .owned_block_bodies = owned_block_bodies,
            .genesis_alloc_path = owned_genesis_alloc_path,
            .genesis_extra_data = genesis_extra_data,
            .genesis_header = genesis_header,
            .legacy_fixture_chain = config.chain_rlp_path != null,
            .receipt_index = receipt_index,
            .log_index = log_index,
            .fork_config = initial_fork_config,
            .rebase_tracker = try createTracker(allocator, initial_fork_config),
            .fork_backend = fork_backend,
            .fork_rpc_resolver = resolver,
            .engine_sync_fallback_url = owned_engine_sync_fallback_url,
            .snapshots = snapshots,
            .next_snapshot_id = 1,
            .rpc_filters = rpc_filters,
            .next_rpc_filter_id = 1,
            .engine_payload_jobs = engine_payload_jobs,
            .next_engine_payload_id = 1,
            .engine_safe_hash = null,
            .engine_finalized_hash = null,
            .engine_import_state = null,
            .engine_import_state_hash = null,
            .replay_state_cache = null,
            .replay_state_cache_number = null,
            .replay_state_cache_hash = null,
            .engine_invalid_payloads = engine_invalid_payloads,
            .pending_transaction_filter_events = .{},
            .impersonated_accounts = impersonated_accounts,
            .auto_impersonate_account = false,
            .runtime_mutex = .{},
            .interval_thread = null,
            .interval_stop_requested = std.atomic.Value(bool).init(false),
            .light_sync_thread = null,
            .light_sync_stop_requested = std.atomic.Value(bool).init(false),
        };
    }

    fn createTracker(allocator: std.mem.Allocator, fork: ?ForkConfig) !?*rebase_fork.RebaseTracker {
        const cfg = fork orelse return null;
        if (!cfg.follow) return null;
        const tracker = try allocator.create(rebase_fork.RebaseTracker);
        errdefer allocator.destroy(tracker);
        tracker.* = try rebase_fork.RebaseTracker.init(allocator, cfg.url, cfg.block_number orelse 0, true);
        return tracker;
    }
    fn destroyTracker(self: *NodeRuntime) void {
        if (self.rebase_tracker) |t| {
            t.deinit();
            self.allocator.destroy(t);
            self.rebase_tracker = null;
        }
    }
    fn emitForkChanged(self: *NodeRuntime) void {
        const cfg = self.fork_config;
        self.emitExEx(.{ .fork_changed = .{ .enabled = cfg != null, .url = if (cfg) |v| @constCast(v.url) else null, .block_number = if (cfg) |v| v.block_number else null, .follow = if (cfg) |v| v.follow else false } });
    }
    pub fn setChainId(self: *NodeRuntime, id: u64) void {
        const old = self.chain_id;
        self.chain_id = id;
        if (self.runtime_mutex.observing) self.runtime_mutex.chain_id = id;
        self.emitExEx(.{ .chain_id_changed = .{ .old_chain_id = old, .new_chain_id = id } });
    }
    pub fn setCoinbase(self: *NodeRuntime, address: primitives.Address) void {
        const old = self.coinbase;
        self.coinbase = address;
        self.dev_runtime.config.coinbase = address;
        if (self.runtime_mutex.observing) self.runtime_mutex.coinbase = address.bytes;
        self.emitExEx(.{ .coinbase_changed = .{ .old_coinbase = old.bytes, .new_coinbase = address.bytes } });
    }
    pub fn setBlockGasLimit(self: *NodeRuntime, limit: u64) void {
        const old = self.dev_runtime.config.block_gas_limit;
        self.dev_runtime.config.block_gas_limit = limit;
        if (self.runtime_mutex.observing) self.runtime_mutex.gas_limit = limit;
        self.emitExEx(.{ .block_gas_limit_changed = .{ .old_gas_limit = old, .new_gas_limit = limit } });
    }
    pub fn dropTransaction(self: *NodeRuntime, hash: [32]u8) bool {
        if (self.runtime_mutex.observing) {
            if (self.pool.hash_index.get(hash)) |index| {
                const tx = self.pool.items()[index];
                _ = self.runtime_mutex.pool_before.remove(.{ .sender = tx.sender.bytes, .nonce = tx.nonce });
            }
        }
        if (!self.pool.removeByHash(hash)) return false;
        self.emitExEx(.{ .tx_pool_drop = .{ .tx_hash = hash, .reason = .dropped } });
        return true;
    }
    pub fn dropAllTransactions(self: *NodeRuntime) void {
        self.runtime_mutex.pool_before.clearRetainingCapacity();
        if (self.event_hub != null) for (self.pool.items()) |tx| self.emitExEx(.{ .tx_pool_drop = .{ .tx_hash = tx.hash, .reason = .dropped } });
        self.pool.clear();
    }
    pub fn emitExEx(self: *NodeRuntime, event: exex.Event) void {
        if (self.event_hub) |hub| hub.emit(event);
    }
    pub fn notifyNodeStarted(self: *NodeRuntime, host: []const u8, port: u16) void {
        self.emitExEx(.{ .node_started = .{ .mode = exex.ModeTag.from(self.mode), .chain_id = self.chain_id, .host = host, .port = port } });
    }
    pub fn notifyNodeStopping(self: *NodeRuntime) void {
        self.emitExEx(.{ .node_stopping = .{ .mode = exex.ModeTag.from(self.mode) } });
    }
    fn emitLightModeTransitions(self: *NodeRuntime) void {
        if (self.mode != .light or self.event_hub == null) return;
        const light = if (self.light) |*light| light else return;
        const status = light.effectiveStatus();
        const ready = light.ready();
        const previous = self.light_last_status orelse .syncing;
        if (previous != status) self.emitExEx(.{ .sync_status_changed = .{ .old_status = exex.SyncStatusTag.from(previous), .new_status = exex.SyncStatusTag.from(status), .ready = ready } });
        if (self.light_last_ready != ready) self.emitExEx(.{ .readiness_changed = .{ .ready = ready } });
        const accepted_checkpoint = if (light.engine.has_verified_store or ready) light.engine.lastCheckpoint() else null;
        if (accepted_checkpoint) |hash| {
            if (self.light_last_checkpoint == null or !std.mem.eql(u8, &self.light_last_checkpoint.?, &hash)) self.emitExEx(.{ .checkpoint_accepted = .{ .checkpoint = hash } });
        }
        const slots = [3]u64{ light.optimisticSlot(), light.safe_slot, light.finalizedSlot() };
        if (self.light_last_head_slots == null or !std.mem.eql(u64, &slots, &self.light_last_head_slots.?)) self.emitExEx(.{ .head_updated = .{ .optimistic_slot = slots[0], .safe_slot = slots[1], .finalized_slot = slots[2] } });
        self.light_last_head_slots = slots;
        self.light_last_checkpoint = accepted_checkpoint;
        self.light_last_ready = ready;
        self.light_last_status = status;
    }

    pub fn startBackgroundServices(self: *NodeRuntime) !void {
        self.background_started = true;
        if (self.rebase_tracker) |tracker| {
            if (tracker.follow and tracker.worker_thread == null) try tracker.startPolling(self, pollRebaseCallback);
        }
        self.emitLightModeTransitions();
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
        const previous = self.mining_config;
        defer if (!std.meta.eql(previous, self.mining_config)) self.emitExEx(.{ .mining_mode_changed = .{ .mode = exex.MiningModeTag.from(self.mining_config), .interval_seconds = switch (self.mining_config) {
            .interval => |v| v.block_time,
            else => 0,
        } } });
        switch (config) {
            .interval => |interval| {
                if (interval.block_time == 0) {
                    self.stopIntervalMiningTimer();
                    self.mining_config = .manual;
                    return;
                }
                if (browser) return error.ModeUnsupported;
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
        if (browser) return error.ModeUnsupported;
        if (block_time == 0 or self.interval_thread != null) return;
        self.interval_stop_requested.store(false, .seq_cst);
        self.interval_thread = try std.Thread.spawn(.{}, intervalMiningLoop, .{ self, block_time });
        log.info(.mining, "interval_mining_started block_time_seconds={}", .{block_time});
    }

    fn stopIntervalMiningTimer(self: *NodeRuntime) void {
        if (browser) return;
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
        if (browser) return error.ModeUnsupported;
        if (self.mode != .light) return error.NotLightMode;
        if (self.light_sync_thread != null) return;

        self.light_sync_stop_requested.store(false, .seq_cst);
        self.light_sync_thread = try std.Thread.spawn(.{}, lightSyncStartupLoop, .{self});
        log.info(.consensus_sync, "light_sync_background_started", .{});
    }

    fn stopLightSyncThread(self: *NodeRuntime) void {
        if (browser) return;
        const thread = self.light_sync_thread orelse return;
        // Request cancellation before joining so the background startup-sync loop
        // short-circuits at the next step boundary instead of starting further
        // blocking network work, mirroring stopIntervalMiningTimer's stop flag.
        self.light_sync_stop_requested.store(true, .seq_cst);
        thread.join();
        self.light_sync_thread = null;
        log.info(.consensus_sync, "light_sync_background_stopped", .{});
    }

    fn lightSyncStartupLoop(self: *NodeRuntime) void {
        self.runLightStartupSyncDetached() catch |err| {
            self.runtime_mutex.lock();
            if (self.light) |*light| {
                light.engine.status = .err;
                self.emitLightModeTransitions();
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

        if (self.light_sync_stop_requested.load(.seq_cst)) return error.Canceled;

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
        var backoff_ms: u64 = LIGHT_STARTUP_RETRY_MIN_MS;
        var attempt: u32 = 1;
        while (true) : (attempt += 1) {
            engine = startup_snapshot.engine;
            if (engine.sync(self.allocator, startup_snapshot.startup_checkpoint, .{
                .source = startup_snapshot.checkpoint_source.name(),
            })) |_| break else |err| {
                if (err == error.OutOfMemory) return err;
                log.warn(.consensus_sync, "light_sync_startup_retry attempt={} backoff_ms={} error={s}", .{
                    attempt,
                    backoff_ms,
                    @errorName(err),
                });
                if (!self.sleepUnlessLightSyncStopped(backoff_ms)) return error.Canceled;
                backoff_ms = @min(backoff_ms * 2, LIGHT_STARTUP_RETRY_MAX_MS);
            }
        }

        // Cancellation may have been requested while the blocking sync above ran;
        // skip committing the result so deinit can join promptly.
        if (self.light_sync_stop_requested.load(.seq_cst)) return error.Canceled;

        const safe_slot = engine.safeSlot();
        const head_block_number = engine.store.optimistic_header.execution.block_number;

        self.runtime_mutex.lock();
        defer self.runtime_mutex.unlock();

        const light = if (self.light) |*state| state else return error.NotLightMode;
        defer self.emitLightModeTransitions();
        light.engine = engine;
        light.safe_slot = safe_slot;
        self.head_block_number = head_block_number;
        try light.recordCurrentHeads(self.allocator);
        light.persistLatestCheckpoint(self.allocator);
        log.info(.consensus_sync, "light_sync_background_completed head_block_number={} safe_slot={}", .{
            head_block_number,
            safe_slot,
        });
    }

    /// Sleeps `total_ms` in short slices so a stop request is honored within
    /// LIGHT_STARTUP_RETRY_POLL_MS. Returns false once a stop is requested.
    fn sleepUnlessLightSyncStopped(self: *NodeRuntime, total_ms: u64) bool {
        var remaining = total_ms;
        while (remaining > 0) {
            if (self.light_sync_stop_requested.load(.seq_cst)) return false;
            const slice: u64 = @min(remaining, LIGHT_STARTUP_RETRY_POLL_MS);
            std.Thread.sleep(slice * std.time.ns_per_ms);
            remaining -= slice;
        }
        return !self.light_sync_stop_requested.load(.seq_cst);
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
        defer self.emitLightModeTransitions();
        const light = if (self.light) |*state| state else return error.NotLightMode;
        try light.engine.sync(self.allocator, light.startup_checkpoint, .{
            .source = light.checkpoint_source.name(),
        });
        light.safe_slot = light.engine.safeSlot();
        self.head_block_number = light.engine.store.optimistic_header.execution.block_number;
        try light.recordCurrentHeads(self.allocator);
        light.persistLatestCheckpoint(self.allocator);
    }

    pub fn advanceLightSync(self: *NodeRuntime) !void {
        defer self.emitLightModeTransitions();
        const light = if (self.light) |*state| state else return error.NotLightMode;
        try light.engine.advance(self.allocator);
        light.safe_slot = light.engine.safeSlot();
        self.head_block_number = light.engine.store.optimistic_header.execution.block_number;
        try light.recordCurrentHeads(self.allocator);
        light.persistLatestCheckpoint(self.allocator);
    }

    pub fn refreshLightSyncForRequest(self: *NodeRuntime) !void {
        defer self.emitLightModeTransitions();
        const light = if (self.light) |*state| state else return error.NotLightMode;
        if (!light.advance_on_request or !light.ready()) return;
        // A verified store already exists: a failed advance (beacon API
        // timeout, transient HTTP error) must not take reads offline. Serve
        // from the last verified heads and retry on the next request.
        self.advanceLightSync() catch |err| {
            if (err == error.OutOfMemory) return err;
            log.warn(.consensus_sync, "light_sync_refresh_failed_serving_verified_store error={s}", .{@errorName(err)});
        };
    }

    pub fn refreshLightSyncForStatus(self: *NodeRuntime) void {
        defer self.emitLightModeTransitions();
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
        defer self.emitLightModeTransitions();
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
        defer self.emitLightModeTransitions();
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

    pub fn pendingBlockTimestamp(self: *const NodeRuntime) u64 {
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
        if (next_offset > std.math.maxInt(u64)) return error.InvalidParams;
        self.time_offset = next_offset;
        self.emitTimeAdjusted(std.math.cast(i64, seconds));
        if (next_offset < 0) return 0;
        return @intCast(next_offset);
    }

    pub fn setTime(self: *NodeRuntime, timestamp: u64) !u64 {
        const old_offset = self.time_offset;
        self.time_offset = @as(i128, timestamp) - @as(i128, currentUnixSeconds());
        self.emitTimeAdjusted(std.math.cast(i64, self.time_offset - old_offset));
        return timestamp;
    }

    pub fn setNextBlockTimestamp(self: *NodeRuntime, timestamp: u64) void {
        self.next_block_timestamp = timestamp;
        self.dev_runtime.config.next_block_timestamp = timestamp;
        self.emitTimeAdjusted(null);
    }

    pub fn setBlockTimestampInterval(self: *NodeRuntime, seconds: u64) void {
        self.block_timestamp_interval = seconds;
        self.emitTimeAdjusted(null);
    }

    pub fn removeBlockTimestampInterval(self: *NodeRuntime) void {
        self.block_timestamp_interval = null;
        self.emitTimeAdjusted(null);
    }

    fn emitTimeAdjusted(self: *NodeRuntime, delta: ?i64) void {
        self.emitExEx(.{ .time_adjusted = .{ .next_timestamp = self.next_block_timestamp, .interval_seconds = self.block_timestamp_interval, .delta_seconds = delta } });
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

    // Keep independent bytecode and storage maps. Fork misses in either view
    // resolve through the same pinned backend as the original block.
    fn copyOverlay(allocator: std.mem.Allocator, state: *state_manager.StateManager) !state_manager.StateManager {
        const journal = &state.journaled_state;
        var copy = try state_manager.StateManager.init(allocator, journal.fork_backend);
        errdefer copy.deinit();
        var accounts = state.accountIterator();
        while (accounts.next()) |account| try copy.journaled_state.putAccount(account.key_ptr.*, account.value_ptr.*);
        var code = journal.contract_cache.cache.iterator();
        while (code.next()) |item| try copy.setCode(item.key_ptr.*, item.value_ptr.*);
        var storage = journal.storage_cache.cache.iterator();
        while (storage.next()) |item| {
            var slots = item.value_ptr.iterator();
            while (slots.next()) |slot| try copy.setStorage(item.key_ptr.*, slot.key_ptr.*, slot.value_ptr.*);
        }
        return copy;
    }
    fn collectChanges(allocator: std.mem.Allocator, before: *state_manager.StateManager, after: *state_manager.StateManager) ![]exex.StateChangeEvent {
        var addresses = std.AutoHashMap(primitives.Address, void).init(allocator);
        defer addresses.deinit();
        var slots = std.AutoHashMap(rebase_fork.StorageSlotKey, void).init(allocator);
        defer slots.deinit();
        for ([_]*state_manager.StateManager{ before, after }) |state| {
            const journal = &state.journaled_state;
            var accounts = journal.account_cache.cache.keyIterator();
            while (accounts.next()) |addr| try addresses.put(addr.*, {});
            var codes = journal.contract_cache.cache.keyIterator();
            while (codes.next()) |addr| try addresses.put(addr.*, {});
            var storage = journal.storage_cache.cache.iterator();
            while (storage.next()) |item| {
                var keys = item.value_ptr.keyIterator();
                while (keys.next()) |key| try slots.put(.{ .address = item.key_ptr.bytes, .slot = key.* }, {});
            }
        }
        var changes: std.ArrayList(exex.StateChangeEvent) = .empty;
        var it = addresses.keyIterator();
        while (it.next()) |addr| {
            const old = try before.journaled_state.getAccount(addr.*);
            const new = try after.journaled_state.getAccount(addr.*);
            if (old.balance != new.balance) try changes.append(allocator, .{ .address = addr.bytes, .field = .balance, .old_u256 = old.balance, .new_u256 = new.balance });
            if (old.nonce != new.nonce) try changes.append(allocator, .{ .address = addr.bytes, .field = .nonce, .old_u256 = old.nonce, .new_u256 = new.nonce });
            if (before.journaled_state.contract_cache.get(addr.*) != null or after.journaled_state.contract_cache.get(addr.*) != null) {
                const old_code = try before.getCode(addr.*);
                const new_code = try after.getCode(addr.*);
                if (!std.mem.eql(u8, old_code, new_code)) try changes.append(allocator, .{ .address = addr.bytes, .field = .code, .old_bytes = @constCast(old_code), .new_bytes = @constCast(new_code) });
            }
        }
        var keys = slots.keyIterator();
        while (keys.next()) |key| {
            const address = primitives.Address{ .bytes = key.address };
            const old = try before.getStorage(address, key.slot);
            const new = try after.getStorage(address, key.slot);
            if (old != new) try changes.append(allocator, .{ .address = key.address, .field = .storage, .storage_slot = key.slot, .old_u256 = old, .new_u256 = new });
        }
        return changes.items;
    }

    fn executeRecordedTx(
        self: *NodeRuntime,
        arena: std.mem.Allocator,
        state: *state_manager.StateManager,
        pooled: txpool.PooledTransaction,
        ctx: guillotine_mini.BlockContext,
        access: *rebase_fork.TxAccessSet,
    ) !primitives.Receipt.Receipt {
        const tx = try executionTransactionFromPooled(arena, pooled);
        var logs = console_log.ConsoleLogBuffer.init(arena);
        defer logs.deinit();
        var adapter = host_adapter.HostAdapter{ .state = state, .console_logs = &logs };
        var observer = RebaseAccessObserver{ .access = access, .allocator = arena };
        for (tx.access_list orelse &.{}) |item| {
            try access.recordAccountRead(arena, item.address.bytes);
            for (item.storage_keys) |key| try access.recordStorageRead(arena, item.address.bytes, std.mem.readInt(u256, &key, .big));
        }
        return tx_processor.processTransactionWithOptions(self.allocator, state, adapter.hostInterface(), tx.caller, tx.tx, ctx, .{
            .backend = .{ .external = .{ .context = &observer, .execute = RebaseAccessObserver.execute } },
            .access_list = tx.access_list,
            .authorization_list = tx.authorization_list,
            .receipt_type = tx.receipt_type,
            .max_fee_per_gas = tx.max_fee_per_gas,
            .max_priority_fee_per_gas = tx.max_priority_fee_per_gas,
            .blob_gas_used = tx.blob_gas_used,
            .blob_gas_price = if (tx.blob_gas_used != null) ctx.blob_base_fee else null,
            .max_fee_per_blob_gas = tx.max_fee_per_blob_gas,
            .blob_versioned_hashes = tx.blob_versioned_hashes,
            .hardfork_override = self.hardforkForBlockContext(ctx),
            .canonical_tx_hash = pooled.hash,
        });
    }
    fn captureEntry(
        self: *NodeRuntime,
        arena: std.mem.Allocator,
        before: *state_manager.StateManager,
        after: *state_manager.StateManager,
        pooled: txpool.PooledTransaction,
        receipt: primitives.Receipt.Receipt,
        ctx: guillotine_mini.BlockContext,
        access: *const rebase_fork.TxAccessSet,
    ) !rebase_fork.LocalTxEntry {
        const a = self.allocator;
        var entry = rebase_fork.LocalTxEntry{
            .tx_hash = pooled.hash,
            .caller = pooled.sender,
            .raw_tx = if (pooled.raw.len != 0) try a.dupe(u8, pooled.raw) else try tx_encoding.encodeLegacyTransactionEnvelope(a, executionTransactionBaseFromPooled(pooled).tx),
            .access_set = .{},
            .cached_gas_used = @intCast(receipt.gas_used),
            .cached_status = if (receipt.status) |status| status.success else true,
            .original_block_number = ctx.block_number,
        };
        errdefer entry.deinit(a);
        entry.access_set = try access.clone(a);
        const set = &entry.access_set;
        try set.recordAccountRead(a, pooled.sender.bytes);
        try set.recordAccountWrite(a, pooled.sender.bytes);
        if (pooled.to orelse receipt.contract_address) |to| {
            try set.recordAccountRead(a, to.bytes);
            try set.recordAccountWrite(a, to.bytes);
        }
        try set.recordAccountWrite(a, ctx.block_coinbase.bytes);
        const changes = try collectChanges(arena, before, after);
        for (changes) |change| {
            try set.recordAccountWrite(a, change.address);
            if (change.storage_slot) |slot| {
                try set.recordStorageWrite(a, change.address, slot);
                try entry.cached_storage_deltas.append(a, .{ .address = change.address, .slot = slot, .value = change.new_u256.? });
            }
        }
        for (set.accounts_written.items) |bytes| {
            const addr = primitives.Address{ .bytes = bytes };
            const account = try after.journaled_state.getAccount(addr);
            try entry.cached_account_deltas.ensureUnusedCapacity(a, 1);
            entry.cached_account_deltas.appendAssumeCapacity(.{ .address = bytes, .balance = account.balance, .nonce = account.nonce, .code = try a.dupe(u8, try after.getCode(addr)) });
        }
        return entry;
    }

    pub fn mineBlocks(self: *NodeRuntime, count: u64, interval: u64) !void {
        self.runtime_mutex.lock();
        defer self.runtime_mutex.unlock();
        if (count == 0) return;

        const had_next_block_timestamp = self.next_block_timestamp != null;
        const first_timestamp = try self.nextBlockTimestamp(self.head_block_timestamp);
        errdefer {
            if (had_next_block_timestamp) {
                self.next_block_timestamp = first_timestamp;
                self.dev_runtime.config.next_block_timestamp = first_timestamp;
            }
        }

        // Validate the last timestamp before committing any block in the batch.
        const span = std.math.mul(u64, count - 1, @max(interval, 1)) catch return error.InvalidParams;
        _ = std.math.add(u64, first_timestamp, span) catch return error.InvalidParams;

        var coordinator = miningCoordinatorFromRuntime(self);
        defer coordinator.deinit(self.allocator);
        coordinator.current_timestamp = first_timestamp;

        var adapter = host_adapter.HostAdapter{ .state = &self.state, .console_logs = &self.console_logs };
        var i: u64 = 0;
        while (i < count) : (i += 1) {
            if (i > 0 and interval > 0) {
                coordinator.current_timestamp = std.math.add(u64, coordinator.current_timestamp, interval - 1) catch return error.InvalidParams;
            }

            const ready = try self.pool.getReady(self.allocator);
            defer self.allocator.free(ready);

            // Decoded access/authorization lists live until this block is built;
            // the coordinator clears pending_txs inside mineBlockWithOptions.
            var tx_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer tx_arena.deinit();
            errdefer coordinator.pending_txs.clearRetainingCapacity();
            for (ready) |pooled| {
                try coordinator.pending_txs.append(
                    self.allocator,
                    try NodeRuntime.executionTransactionFromPooled(tx_arena.allocator(), pooled),
                );
            }

            var block_options = mining_coordinator.MiningBlockOptions{
                .prevrandao = coordinator.next_prevrandao,
                .dev_runtime = &self.dev_runtime,
                .skip_invalid_transactions = true,
                .require_system_contracts = self.genesis_alloc_path != null,
            };
            const parent_hash = self.blockchain.getCanonicalHash(self.head_block_number) orelse return error.MissingParentBlock;
            const parent_block = self.blockchain.getBlockLocal(parent_hash) orelse return error.MissingParentBlock;
            const parent_fork = self.hardforkAt(parent_block.header.number, parent_block.header.timestamp);
            coordinator.parent_blob_fees = if (parent_fork.isAtLeast(.CANCUN)) .{
                .excess = parent_block.header.excess_blob_gas orelse 0,
                .used = parent_block.header.blob_gas_used orelse 0,
                .base_fee = parent_block.header.base_fee_per_gas orelse 0,
            } else .{
                .excess = 0,
                .used = 0,
                .base_fee = parent_block.header.base_fee_per_gas orelse 0,
            };
            var block_ctx = block_builder.blockContextWithEnvironmentOverrides(
                &self.dev_runtime,
                coordinator.blockContext(block_options),
            );
            var recent_block_hashes: [256][32]u8 = undefined;
            block_ctx.block_hashes = try self.recentBlockHashesForExecution(block_ctx.block_number, &recent_block_hashes);
            block_options.block_hashes = block_ctx.block_hashes;
            block_options.parent_hash = parent_hash;
            const block_excess_blob_gas = coordinator.excessAt(block_ctx.block_number, block_ctx.block_timestamp);

            // Pre-populate system contract code through the fork resolver so
            // Cancun/Prague system calls inside buildBlock never hit RpcPending.
            if (self.fork_backend != null) {
                const block_fork = self.hardforkAt(block_ctx.block_number, block_ctx.block_timestamp);
                if (block_fork.isAtLeast(.CANCUN)) {
                    _ = try self.getCode(block_builder.BEACON_ROOTS_ADDRESS);
                }
                if (block_fork.isAtLeast(.PRAGUE)) {
                    _ = try self.getCode(block_builder.HISTORY_STORAGE_ADDRESS);
                    _ = try self.getCode(block_builder.WITHDRAWAL_REQUESTS_ADDRESS);
                    _ = try self.getCode(block_builder.CONSOLIDATION_REQUESTS_ADDRESS);
                }
            }

            const arena = tx_arena.allocator();
            if (self.event_hub != null or self.rebase_tracker != null) self.enableSynchronousForkReads();
            var before = if (self.event_hub != null or self.rebase_tracker != null) try copyOverlay(arena, &self.state) else null;
            defer if (before) |*state| state.deinit();
            var pending_checkpoint = before != null;
            if (pending_checkpoint) try self.state.checkpoint();
            errdefer if (pending_checkpoint) self.state.revert();
            var result = try coordinator.mineBlockWithOptions(
                self.allocator,
                &self.state,
                adapter.hostInterface(),
                block_options,
            );
            // mineBlockWithOptions returns a caller-owned BlockResult; the
            // coordinator keeps an independent clone in mined_blocks. persistMinedBlock
            // and the receipt/log indexes copy what they retain, so this runtime owns
            // the returned value and must free it to avoid leaking its receipts/logs.
            defer result.deinit(self.allocator);

            const changes = if (self.event_hub != null) try collectChanges(arena, &before.?, &self.state) else &.{};
            var entries: std.ArrayList(rebase_fork.LocalTxEntry) = .empty;
            defer for (entries.items) |*entry| entry.deinit(self.allocator);
            if (self.rebase_tracker != null) {
                try entries.ensureUnusedCapacity(arena, result.receipts.len);

                if (result.receipts.len > 0) {
                    // The builder returns a whole block. Reconstruct intermediate
                    // poststates on a private overlay for same-block dependencies.
                    var shadow = try copyOverlay(arena, &before.?);
                    defer shadow.deinit();
                    var observer = host_adapter.HostAdapter{ .state = &shadow };
                    const fork = self.hardforkForBlockContext(block_ctx);
                    if (fork.isAtLeast(.CANCUN)) try block_builder.applyBeaconRootsSystemCallWithContext(arena, &shadow, observer.hostInterface(), block_ctx, fork, primitives.Hash.ZERO);
                    if (fork.isAtLeast(.PRAGUE)) try block_builder.applyHistoricalBlockHashSystemCallWithContext(arena, &shadow, observer.hostInterface(), block_ctx, fork, parent_hash);
                    for (result.receipts, result.included_tx_indexes) |receipt, index| {
                        var observation_arena = std.heap.ArenaAllocator.init(self.allocator);
                        defer observation_arena.deinit();
                        const observation = observation_arena.allocator();
                        var prior = try copyOverlay(observation, &shadow);
                        defer prior.deinit();
                        var access = rebase_fork.TxAccessSet{};
                        const observed = try self.executeRecordedTx(observation, &shadow, ready[index], block_ctx, &access);
                        defer observed.deinit(self.allocator);
                        entries.appendAssumeCapacity(try self.captureEntry(observation, &prior, &shadow, ready[index], receipt, block_ctx, &access));
                    }
                }
            }
            const mined_hashes = try self.minedHashesFromResult(result, ready);
            defer self.allocator.free(mined_hashes);
            const block_hash = blk: {
                if (self.rebase_tracker) |tracker| tracker.mutex.lock();
                defer if (self.rebase_tracker) |tracker| tracker.mutex.unlock();
                if (self.rebase_tracker) |tracker| try tracker.local_txs.ensureUnusedCapacity(self.allocator, entries.items.len);
                const hash = try self.persistMinedBlock(block_ctx, block_excess_blob_gas, &result, ready);
                if (self.rebase_tracker) |tracker| {
                    tracker.local_txs.appendSliceAssumeCapacity(entries.items);
                    entries.clearRetainingCapacity();
                }
                break :blk hash;
            };
            if (pending_checkpoint) {
                self.state.commit();
                pending_checkpoint = false;
            }
            const included_tx_count = mined_hashes.len;
            if (self.runtime_mutex.observing) for (result.included_tx_indexes) |index| {
                const tx = ready[index];
                _ = self.runtime_mutex.pool_before.remove(.{ .sender = tx.sender.bytes, .nonce = tx.nonce });
            };
            self.pool.removeMined(mined_hashes);
            self.revalidatePoolNonces();

            const block = (try self.blockchain.getBlockByHash(block_hash)) orelse return error.MinedBlockMissing;
            self.head_block_number = block.header.number;
            self.head_block_timestamp = block.header.timestamp;
            self.blob_base_fee = block_ctx.blob_base_fee;
            if (coordinator.current_base_fee_per_gas) |base_fee| {
                self.base_fee = base_fee;
            }
            if (self.event_hub != null) {
                for (changes) |change| self.emitExEx(.{ .state_change = change });
                for (mined_hashes) |hash| self.emitExEx(.{ .tx_pool_drop = .{ .tx_hash = hash, .reason = .mined } });
                self.emitExEx(.{ .block_committed = .{
                    .block_number = block.header.number,
                    .block_hash = block.hash,
                    .parent_hash = parent_hash,
                    .timestamp = block.header.timestamp,
                    .gas_used = block.header.gas_used,
                    .tx_count = mined_hashes.len,
                    .tx_hashes = mined_hashes,
                    .receipt_count = result.receipts.len,
                    .state_diff_count = changes.len,
                } });
            }
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
    }

    pub fn mineBlocksWithTimestampInterval(self: *NodeRuntime, count: u64, explicit_interval: ?u64) !void {
        const interval = explicit_interval orelse self.block_timestamp_interval orelse return self.mineBlocks(count, 0);
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

    /// Builds the execution input for a pooled transaction. When the pool kept
    /// the canonical EIP-2718 envelope, decode it so typed fields the pool
    /// entry does not carry (access list, authorization list) reach the EVM,
    /// and forward the envelope and its hash for canonical roots and receipts.
    /// `arena` owns the decoded lists and must outlive block building.
    fn executionTransactionFromPooled(arena: std.mem.Allocator, pooled: txpool.PooledTransaction) !tx_processor.ExecutionTx {
        var execution_tx = executionTransactionBaseFromPooled(pooled);
        if (pooled.raw.len == 0) return execution_tx;

        const decoded = tx_encoding.decodeEnvelope(arena, pooled.raw) catch |err| switch (err) {
            error.InvalidSignatureV => {
                // Unsigned impersonated dev transactions carry v=r=s=0 in raw bytes.
                execution_tx.raw = pooled.raw;
                execution_tx.tx_hash = pooled.hash;
                return execution_tx;
            },
            else => return err,
        };
        if (decoded != .legacy) {
            execution_tx.access_list = try processorAccessListFromEnvelope(arena, tx_encoding.envelopeAccessList(decoded));
        }
        if (decoded == .eip7702) {
            execution_tx.authorization_list = tx_encoding.envelopeAuthorizationList(decoded);
        }
        execution_tx.raw = pooled.raw;
        execution_tx.tx_hash = pooled.hash;
        return execution_tx;
    }

    fn executionTransactionBaseFromPooled(pooled: txpool.PooledTransaction) tx_processor.ExecutionTx {
        const blob_gas_used: ?u256 = if (pooled.receipt_type == .eip4844)
            @as(u256, pooled.blob_versioned_hashes.len) * @as(u256, primitives.Blob.BLOB_GAS_PER_BLOB)
        else
            null;
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
            .receipt_type = pooled.receipt_type,
            .max_fee_per_gas = pooled.max_fee_per_gas,
            .max_priority_fee_per_gas = pooled.max_priority_fee_per_gas,
            .blob_gas_used = blob_gas_used,
            .max_fee_per_blob_gas = pooled.max_fee_per_blob_gas,
            .blob_versioned_hashes = if (pooled.blob_versioned_hashes.len == 0) null else pooled.blob_versioned_hashes,
        };
    }

    pub fn isForkingEnabled(self: *const NodeRuntime) bool {
        return self.fork_config != null;
    }

    pub fn impersonateAccount(self: *NodeRuntime, address: primitives.Address) !void {
        try self.impersonated_accounts.put(address, true);
        self.emitExEx(.{ .impersonation_changed = .{ .address = address.bytes, .impersonating = true, .auto_impersonate = self.auto_impersonate_account } });
    }

    pub fn stopImpersonatingAccount(self: *NodeRuntime, address: primitives.Address) void {
        _ = self.impersonated_accounts.remove(address);
        self.emitExEx(.{ .impersonation_changed = .{ .address = address.bytes, .impersonating = false, .auto_impersonate = self.auto_impersonate_account } });
    }

    pub fn setAutoImpersonateAccount(self: *NodeRuntime, enabled: bool) void {
        self.auto_impersonate_account = enabled;
        self.emitExEx(.{ .impersonation_changed = .{ .address = null, .impersonating = enabled, .auto_impersonate = self.auto_impersonate_account } });
    }

    pub fn createBlockFilter(self: *NodeRuntime) !u64 {
        if (self.rpc_filters.count() >= MAX_RPC_FILTERS) return error.TooManyFilters;
        const id = self.allocateRpcFilterId();
        try self.rpc_filters.put(id, .{ .block = .{
            .last_block_number = self.head_block_number,
        } });
        return id;
    }

    pub fn createPendingTransactionFilter(self: *NodeRuntime) !u64 {
        if (self.rpc_filters.count() >= MAX_RPC_FILTERS) return error.TooManyFilters;
        const id = self.allocateRpcFilterId();
        try self.rpc_filters.put(id, .{ .pending_transaction = .{
            .next_event_index = self.pending_transaction_filter_events.items.len,
        } });
        return id;
    }

    pub fn createLogFilterOwned(
        self: *NodeRuntime,
        filter: log_index_mod.LogFilter,
        next_block_number: u64,
        to_block_omitted: bool,
    ) !u64 {
        if (self.rpc_filters.count() >= MAX_RPC_FILTERS) return error.TooManyFilters;
        const id = self.allocateRpcFilterId();
        try self.rpc_filters.put(id, .{ .log = .{
            .filter = filter,
            .next_block_number = next_block_number,
            .to_block_omitted = to_block_omitted,
        } });
        return id;
    }

    pub fn rpcFilter(self: *NodeRuntime, id: u64) ?*RpcFilter {
        return self.rpc_filters.getPtr(id);
    }

    pub fn removeRpcFilter(self: *NodeRuntime, id: u64) bool {
        if (self.rpc_filters.fetchRemove(id)) |removed| {
            var filter = removed.value;
            filter.deinit(self.allocator);
            return true;
        }
        return false;
    }

    pub fn recordPendingTransactionFilterEvent(self: *NodeRuntime, hash: [32]u8) !void {
        try self.appendPendingFilterHash(hash);
        if (self.event_hub == null) return;
        const index = self.pool.hash_index.get(hash) orelse return;
        const tx = self.pool.items()[index];
        if (self.runtime_mutex.pool_before.fetchRemove(.{ .sender = tx.sender.bytes, .nonce = tx.nonce })) |old| {
            if (std.mem.eql(u8, &old.value, &hash)) return;
            self.emitExEx(.{ .tx_pool_drop = .{ .tx_hash = old.value, .reason = .replaced } });
        }
        self.emitExEx(.{ .tx_pool_add = .{ .tx_hash = hash, .sender = tx.sender.bytes, .nonce = tx.nonce } });
    }

    fn appendPendingFilterHash(self: *NodeRuntime, hash: [32]u8) !void {
        // Events exist only for pending-transaction filters to poll.
        var min_next_index: ?usize = null;
        var filter_it = self.rpc_filters.valueIterator();
        while (filter_it.next()) |filter| {
            switch (filter.*) {
                .pending_transaction => |state| min_next_index = @min(min_next_index orelse state.next_event_index, state.next_event_index),
                else => {},
            }
        }
        const oldest_unread = min_next_index orelse {
            self.pending_transaction_filter_events.clearRetainingCapacity();
            return;
        };

        for (self.pending_transaction_filter_events.items) |seen| {
            if (std.mem.eql(u8, &seen, &hash)) return;
        }

        // Drop events every filter already consumed, then the oldest unread
        // ones if the buffer is still full.
        const events = &self.pending_transaction_filter_events;
        var drop = @min(oldest_unread, events.items.len);
        if (events.items.len - drop >= MAX_PENDING_TRANSACTION_FILTER_EVENTS) {
            drop = events.items.len - MAX_PENDING_TRANSACTION_FILTER_EVENTS + 1;
        }
        if (drop > 0) {
            const remaining = events.items.len - drop;
            std.mem.copyForwards([32]u8, events.items[0..remaining], events.items[drop..]);
            events.shrinkRetainingCapacity(remaining);
            var shift_it = self.rpc_filters.valueIterator();
            while (shift_it.next()) |filter| {
                switch (filter.*) {
                    .pending_transaction => |*state| state.next_event_index -|= drop,
                    else => {},
                }
            }
        }
        try events.append(self.allocator, hash);
    }

    pub fn pendingTransactionFilterEventsSince(self: *const NodeRuntime, index: usize) []const [32]u8 {
        if (index >= self.pending_transaction_filter_events.items.len) return self.pending_transaction_filter_events.items[self.pending_transaction_filter_events.items.len..];
        return self.pending_transaction_filter_events.items[index..];
    }

    fn allocateRpcFilterId(self: *NodeRuntime) u64 {
        // Wrap instead of saturating so ids never stick at maxInt; 0 is
        // reserved as "no filter" and live ids are skipped after a wrap.
        var id = self.next_rpc_filter_id;
        while (id == 0 or self.rpc_filters.contains(id)) id +%= 1;
        self.next_rpc_filter_id = id +% 1;
        if (self.next_rpc_filter_id == 0) self.next_rpc_filter_id = 1;
        return id;
    }

    fn clearRpcFilters(self: *NodeRuntime) void {
        var it = self.rpc_filters.valueIterator();
        while (it.next()) |filter| filter.deinit(self.allocator);
        self.rpc_filters.clearRetainingCapacity();
        self.next_rpc_filter_id = 1;
        self.pending_transaction_filter_events.clearRetainingCapacity();
    }

    pub fn createEnginePayloadJob(
        self: *NodeRuntime,
        parent_hash: [32]u8,
        attrs: EnginePayloadAttributes,
    ) !u64 {
        var owned_attrs = try cloneEnginePayloadAttributes(self.allocator, attrs);
        errdefer owned_attrs.deinit(self.allocator);

        // Consensus clients only fetch recent payloads; evict the oldest job.
        if (self.engine_payload_jobs.count() >= MAX_ENGINE_PAYLOAD_JOBS) {
            if (minKey(u64, EnginePayloadJob, &self.engine_payload_jobs)) |oldest| {
                var removed = self.engine_payload_jobs.fetchRemove(oldest).?.value;
                removed.deinit(self.allocator);
            }
        }

        const id = self.next_engine_payload_id;
        self.next_engine_payload_id +|= 1;
        if (self.next_engine_payload_id == 0) self.next_engine_payload_id = 1;
        try self.engine_payload_jobs.put(id, .{
            .parent_hash = parent_hash,
            .attrs = owned_attrs,
        });
        return id;
    }

    pub fn enginePayloadJob(self: *NodeRuntime, id: u64) ?EnginePayloadJob {
        return self.engine_payload_jobs.get(id);
    }

    fn clearEnginePayloadJobs(self: *NodeRuntime) void {
        var it = self.engine_payload_jobs.valueIterator();
        while (it.next()) |job| job.deinit(self.allocator);
        self.engine_payload_jobs.clearRetainingCapacity();
        self.next_engine_payload_id = 1;
    }

    fn clearEngineImportState(self: *NodeRuntime) void {
        if (self.engine_import_state) |*state| {
            state.deinit();
        }
        self.engine_import_state = null;
        self.engine_import_state_hash = null;
    }

    fn clearReplayStateCache(self: *NodeRuntime) void {
        if (self.replay_state_cache) |*state| {
            state.deinit();
        }
        self.replay_state_cache = null;
        self.replay_state_cache_number = null;
        self.replay_state_cache_hash = null;
    }

    fn clearEngineInvalidPayloads(self: *NodeRuntime) void {
        self.engine_invalid_payloads.clearRetainingCapacity();
    }

    fn rememberInvalidEnginePayload(
        self: *NodeRuntime,
        hash: [32]u8,
        latest_valid_hash: ?[32]u8,
        validation_error: ?[]const u8,
    ) !void {
        if (!self.engine_invalid_payloads.contains(hash) and
            self.engine_invalid_payloads.count() >= MAX_ENGINE_INVALID_PAYLOADS)
        {
            // Any entry may go: a forgotten invalid payload is re-validated.
            var it = self.engine_invalid_payloads.keyIterator();
            if (it.next()) |evict| _ = self.engine_invalid_payloads.remove(evict.*);
        }
        try self.engine_invalid_payloads.put(hash, .{
            .latest_valid_hash = latest_valid_hash,
            .validation_error = validation_error,
        });
    }

    pub fn engineInvalidPayloadResult(self: *NodeRuntime, hash: [32]u8) ?EnginePayloadImportResult {
        const record = self.engine_invalid_payloads.get(hash) orelse return null;
        return .{
            .status = .invalid,
            .latest_valid_hash = record.latest_valid_hash,
            .validation_error = record.validation_error,
        };
    }

    fn importEngineMissingAncestors(self: *NodeRuntime, missing_hash: [32]u8) anyerror!bool {
        const fallback_url = self.engine_sync_fallback_url orelse return false;
        var fetched = std.ArrayList(FetchedEngineFallbackBlock){};
        defer {
            for (fetched.items) |*item| item.deinit(self.allocator);
            fetched.deinit(self.allocator);
        }

        var cursor = missing_hash;
        var depth: usize = 0;
        while (self.blockchain.getBlockLocal(cursor) == null) {
            if (self.engine_invalid_payloads.contains(cursor)) return true;
            if (depth >= ENGINE_SYNC_FALLBACK_MAX_ANCESTORS) {
                const cursor_hex = std.fmt.bytesToHex(cursor, .lower);
                log.warn(.rpc, "engine_sync_fallback_depth_exceeded missing_hash=0x{s} depth={}", .{ cursor_hex[0..], depth });
                return false;
            }

            var fetched_block = self.fetchEngineFallbackBlock(fallback_url, cursor) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    const cursor_hex = std.fmt.bytesToHex(cursor, .lower);
                    log.warn(.rpc, "engine_sync_fallback_fetch_failed hash=0x{s} error={s}", .{ cursor_hex[0..], @errorName(err) });
                    return false;
                },
            };
            if (!std.mem.eql(u8, &fetched_block.block.hash, &cursor)) {
                const expected_hex = std.fmt.bytesToHex(cursor, .lower);
                const actual_hex = std.fmt.bytesToHex(fetched_block.block.hash, .lower);
                fetched_block.deinit(self.allocator);
                log.warn(.rpc, "engine_sync_fallback_hash_mismatch expected=0x{s} actual=0x{s}", .{ expected_hex[0..], actual_hex[0..] });
                return false;
            }

            cursor = fetched_block.block.header.parent_hash;
            fetched.append(self.allocator, fetched_block) catch |err| {
                fetched_block.deinit(self.allocator);
                return err;
            };
            depth += 1;
        }

        var index = fetched.items.len;
        while (index > 0) {
            index -= 1;
            const item = &fetched.items[index];
            const imported = try self.importEnginePayloadBlock(item.block, item.requests_hash);
            switch (imported.status) {
                .valid, .invalid, .invalid_block_hash => {},
                .syncing => return false,
            }
        }

        return self.blockchain.getBlockLocal(missing_hash) != null or self.engine_invalid_payloads.contains(missing_hash);
    }

    fn fetchEngineFallbackBlock(
        self: *NodeRuntime,
        fallback_url: []const u8,
        block_hash: [32]u8,
    ) anyerror!FetchedEngineFallbackBlock {
        const hash_hex = std.fmt.bytesToHex(block_hash, .lower);
        const params_json = try std.fmt.allocPrint(self.allocator, "[\"0x{s}\"]", .{hash_hex[0..]});
        defer self.allocator.free(params_json);

        const result_json = try self.fetchEngineFallbackRawBlock(fallback_url, params_json);
        defer self.allocator.free(result_json);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, result_json, .{
            .allocate = .alloc_always,
        });
        defer parsed.deinit();
        if (parsed.value == .null) return error.EngineSyncFallbackBlockMissing;

        const raw = try rpc_parse.parseHexDataBytes(self.allocator, parsed.value);
        defer self.allocator.free(raw);

        var decoded = try chain_import.decodeNextBlock(self.allocator, raw);
        errdefer decoded.owned_body.deinit(self.allocator);
        return .{
            .block = decoded.block,
            .owned_body = decoded.owned_body,
            .requests_hash = decoded.owned_body.requests_hash,
        };
    }

    fn fetchEngineFallbackRawBlock(
        self: *NodeRuntime,
        fallback_url: []const u8,
        params_json: []const u8,
    ) anyerror![]u8 {
        return resolveForkRpcViaHttp(null, self.allocator, .{
            .url = fallback_url,
            .method = "debug_getRawBlockFromPeer",
            .params_json = params_json,
        }) catch |peer_err| switch (peer_err) {
            error.OutOfMemory => return peer_err,
            else => return resolveForkRpcViaHttp(null, self.allocator, .{
                .url = fallback_url,
                .method = "debug_getRawBlock",
                .params_json = params_json,
            }),
        };
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
        const old = if (self.event_hub != null) try self.getBalance(address) else null;
        while (true) {
            self.state.setBalance(address, balance) catch |err| switch (err) {
                error.RpcPending => {
                    try self.serviceForkRequests();
                    continue;
                },
                else => return err,
            };
            if (old) |before| {
                if (before != balance) self.emitExEx(.{ .state_change = .{ .address = address.bytes, .field = .balance, .old_u256 = before, .new_u256 = balance } });
            }
            return;
        }
    }

    pub fn setNonce(self: *NodeRuntime, address: primitives.Address, nonce: u64) !void {
        const old = if (self.event_hub != null) try self.getNonce(address) else null;
        while (true) {
            self.state.setNonce(address, nonce) catch |err| switch (err) {
                error.RpcPending => {
                    try self.serviceForkRequests();
                    continue;
                },
                else => return err,
            };
            if (old) |before| {
                if (before != nonce) self.emitExEx(.{ .state_change = .{ .address = address.bytes, .field = .nonce, .old_u256 = before, .new_u256 = nonce } });
            }
            return;
        }
    }

    pub fn setCode(self: *NodeRuntime, address: primitives.Address, code: []const u8) !void {
        const old = if (self.event_hub != null) try self.allocator.dupe(u8, try self.getCode(address)) else null;
        defer if (old) |before| self.allocator.free(before);
        try self.state.setCode(address, code);
        if (old) |before| {
            const current = try self.getCode(address);
            if (!std.mem.eql(u8, before, current)) self.emitExEx(.{ .state_change = .{ .address = address.bytes, .field = .code, .old_bytes = before, .new_bytes = @constCast(current) } });
        }
    }

    pub fn setStorage(self: *NodeRuntime, address: primitives.Address, slot: u256, value: u256) !void {
        const old = if (self.event_hub != null) try self.getStorage(address, slot) else null;
        try self.state.setStorage(address, slot, value);
        if (old) |before| {
            if (before != value) self.emitExEx(.{ .state_change = .{ .address = address.bytes, .field = .storage, .old_u256 = before, .new_u256 = value, .storage_slot = slot } });
        }
    }

    pub fn snapshot(self: *NodeRuntime) !u64 {
        self.runtime_mutex.lock();
        defer self.runtime_mutex.unlock();
        const state_snapshot_id = try self.state.snapshot();
        // Reverting to a snapshot taken just now only pops its checkpoint.
        errdefer self.state.revertToSnapshot(state_snapshot_id) catch {};
        const fork_copy = try allocForkConfig(self.allocator, self.fork_config);
        errdefer freeForkConfig(self.allocator, fork_copy);
        var pool_copy = try self.pool.clone(self.allocator);
        errdefer pool_copy.deinit();
        var impersonated_copy = try self.impersonated_accounts.clone();
        errdefer impersonated_copy.deinit();
        var query_indexes = try self.cloneQueryIndexes();
        errdefer query_indexes.deinit(self.allocator);

        // Reserve the map slot before evicting so a failure anywhere above
        // leaves the existing snapshots (including the oldest) intact.
        try self.snapshots.ensureUnusedCapacity(1);

        // Each snapshot clones the block store and indexes; drop the oldest.
        if (self.snapshots.count() >= MAX_SNAPSHOTS) {
            if (minKey(u64, SnapshotEntry, &self.snapshots)) |oldest| {
                var removed = self.snapshots.fetchRemove(oldest).?.value;
                deinitSnapshotEntry(self.allocator, &removed);
            }
        }
        const snapshot_id = self.next_snapshot_id;
        self.next_snapshot_id += 1;

        self.snapshots.putAssumeCapacityNoClobber(snapshot_id, .{
            .local_tx_count = if (self.rebase_tracker) |tracker| tracker.local_txs.items.len else 0,
            .state_snapshot_id = state_snapshot_id,
            .head_block_number = self.head_block_number,
            .canonical_head_hash = self.blockchain.getCanonicalHash(self.head_block_number),
            .head_block_timestamp = self.head_block_timestamp,
            .engine_safe_hash = self.engine_safe_hash,
            .engine_finalized_hash = self.engine_finalized_hash,
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

        self.emitExEx(.{ .snapshot_created = .{ .snapshot_id = snapshot_id, .block_number = self.head_block_number } });
        return snapshot_id;
    }

    pub fn revertToSnapshot(self: *NodeRuntime, snapshot_id: u64) !bool {
        self.runtime_mutex.lock();
        defer self.runtime_mutex.unlock();
        const previous_head = self.head_block_number;
        var restored = false;
        defer self.emitExEx(.{ .snapshot_reverted = .{ .snapshot_id = snapshot_id, .success = restored, .new_head_number = self.head_block_number } });
        if (!self.snapshots.contains(snapshot_id)) return false;

        // Fetch-remove and transfer ownership directly from the snapshot entry instead
        // of deep-cloning pool, impersonated_accounts, and full query indexes just to
        // immediately free the original snapshot entry.
        // Collect newer snapshot ids before mutating anything: an OOM here
        // must leave state, indexes, and snapshots untouched.
        var to_remove = std.ArrayList(u64){};
        defer to_remove.deinit(self.allocator);
        try to_remove.ensureTotalCapacity(self.allocator, self.snapshots.count());
        var newer_it = self.snapshots.keyIterator();
        while (newer_it.next()) |id| {
            if (id.* > snapshot_id) to_remove.appendAssumeCapacity(id.*);
        }

        const entry_peek = self.snapshots.get(snapshot_id).?;
        self.state.revertToSnapshot(entry_peek.state_snapshot_id) catch |err| {
            if (err == error.OutOfMemory) return err;
            return false;
        };
        self.stopIntervalMiningTimer();

        const removed_entry = self.snapshots.fetchRemove(snapshot_id).?.value;
        defer freeForkConfig(self.allocator, removed_entry.fork_config);

        self.head_block_number = removed_entry.head_block_number;
        self.head_block_timestamp = removed_entry.head_block_timestamp;
        self.engine_safe_hash = removed_entry.engine_safe_hash;
        self.engine_finalized_hash = removed_entry.engine_finalized_hash;
        self.clearEngineImportState();
        self.clearReplayStateCache();
        self.clearEngineInvalidPayloads();
        self.coinbase = removed_entry.coinbase;
        self.gas_price = removed_entry.gas_price;
        self.base_fee = removed_entry.base_fee;
        self.blob_base_fee = removed_entry.blob_base_fee;
        self.max_priority_fee = removed_entry.max_priority_fee;
        self.mining_config = removed_entry.mining_config;

        self.pool.deinit();
        self.pool = removed_entry.pool;
        self.replaceQueryIndexes(removed_entry.query_indexes);
        if (removed_entry.canonical_head_hash) |head_hash| {
            const restored_max = self.blockchain.getHeadBlockNumber() orelse removed_entry.head_block_number;
            self.blockchain.setCanonicalHead(head_hash) catch {};
            self.pruneCanonicalChainAbove(removed_entry.head_block_number, restored_max);
        }
        self.time_offset = removed_entry.time_offset;
        self.next_block_timestamp = removed_entry.next_block_timestamp;
        self.block_timestamp_interval = removed_entry.block_timestamp_interval;
        self.dev_runtime.config = removed_entry.dev_config;

        self.impersonated_accounts.deinit();
        self.impersonated_accounts = removed_entry.impersonated_accounts;
        self.auto_impersonate_account = removed_entry.auto_impersonate_account;

        for (to_remove.items) |id| {
            if (self.snapshots.fetchRemove(id)) |removed| {
                var removed_value = removed.value;
                deinitSnapshotEntry(self.allocator, &removed_value);
            }
        }

        self.restoreForkStateFromSnapshot(removed_entry.fork_config) catch |err| {
            log.err(.startup, "snapshot_fork_restore_failed error={s}", .{@errorName(err)});
        };

        if (self.rebase_tracker) |tracker| {
            tracker.mutex.lock();
            defer tracker.mutex.unlock();
            while (tracker.local_txs.items.len > removed_entry.local_tx_count) {
                var entry = tracker.local_txs.pop().?;
                entry.deinit(self.allocator);
            }
        }
        restored = true;
        if (self.event_hub != null and previous_head > self.head_block_number) {
            const hash = self.blockchain.getCanonicalHash(self.head_block_number) orelse return error.MissingParentBlock;
            var number = previous_head;
            while (number > self.head_block_number) : (number -= 1) self.emitExEx(.{ .block_reverted = .{ .reverted_block_number = number, .new_head_number = self.head_block_number, .new_head_hash = hash } });
        }
        if (self.background_started or self.mining_config == .interval) try self.startBackgroundServices();
        return true;
    }

    fn rpcResolver(ctx: ?*anyopaque) ForkRpcResolver {
        const rt: *NodeRuntime = @ptrCast(@alignCast(ctx.?));
        return rt.fork_rpc_resolver.?;
    }
    fn fetchRebaseHead(ctx: ?*anyopaque, a: std.mem.Allocator, url: []const u8) !u64 {
        return forkScalarQuantity(u64, a, rpcResolver(ctx), url, "eth_blockNumber", "[]");
    }
    fn fetchAccountChanged(ctx: ?*anyopaque, a: std.mem.Allocator, url: []const u8, addr: [20]u8, old: u64, new: u64) !bool {
        const resolver = rpcResolver(ctx);
        const hex = std.fmt.bytesToHex(addr, .lower);
        var params: [2][96]u8 = undefined;
        const lhs = try std.fmt.bufPrint(&params[0], "[\"0x{s}\",\"0x{x}\"]", .{ &hex, old });
        const rhs = try std.fmt.bufPrint(&params[1], "[\"0x{s}\",\"0x{x}\"]", .{ &hex, new });
        for ([_][]const u8{ "eth_getBalance", "eth_getTransactionCount" }) |method| {
            if (try forkScalarQuantity(u256, a, resolver, url, method, lhs) != try forkScalarQuantity(u256, a, resolver, url, method, rhs)) return true;
        }
        const left = try resolver.resolve(resolver.context, a, .{ .url = url, .method = "eth_getCode", .params_json = lhs });
        defer a.free(left);
        const right = try resolver.resolve(resolver.context, a, .{ .url = url, .method = "eth_getCode", .params_json = rhs });
        defer a.free(right);
        return !std.ascii.eqlIgnoreCase(try forkScalarString(left), try forkScalarString(right));
    }
    fn fetchStorageChanged(ctx: ?*anyopaque, a: std.mem.Allocator, url: []const u8, addr: [20]u8, slot: u256, old: u64, new: u64) !bool {
        const resolver = rpcResolver(ctx);
        const hex = std.fmt.bytesToHex(addr, .lower);
        var values: [2]u256 = undefined;
        for ([_]u64{ old, new }, &values) |block, *value| {
            var buf: [160]u8 = undefined;
            const params = try std.fmt.bufPrint(&buf, "[\"0x{s}\",\"0x{x}\",\"0x{x}\"]", .{ &hex, slot, block });
            value.* = try forkScalarQuantity(u256, a, resolver, url, "eth_getStorageAt", params);
        }
        return values[0] != values[1];
    }
    fn pooledFromEntry(a: std.mem.Allocator, entry: rebase_fork.LocalTxEntry) !txpool.PooledTransaction {
        const decoded = tx_encoding.decodeEnvelope(a, entry.raw_tx) catch |err| switch (err) {
            error.InvalidSignatureV => tx_encoding.DecodedEnvelope{ .legacy = try tx_encoding.decodeLegacyEnvelopeAllowInvalidSignature(entry.raw_tx) },
            else => return err,
        };
        const tx = tx_encoding.envelopeToLegacyLikeTx(decoded);
        return .{
            .sender = entry.caller,
            .hash = entry.tx_hash,
            .nonce = tx.nonce,
            .to = tx.to,
            .value = tx.value,
            .raw = entry.raw_tx,
            .input = tx.data,
            .gas_limit = tx.gas_limit,
            .max_fee_per_gas = tx_encoding.envelopeMaxFeePerGas(decoded) orelse tx.gas_price,
            .max_priority_fee_per_gas = tx_encoding.envelopeMaxPriorityFeePerGas(decoded) orelse tx.gas_price,
            .receipt_type = tx_encoding.envelopeReceiptType(decoded),
            .max_fee_per_blob_gas = tx_encoding.envelopeMaxFeePerBlobGas(decoded),
            .blob_versioned_hashes = (try tx_encoding.envelopeBlobVersionedHashBytes(a, decoded)) orelse &.{},
            .r = tx.r,
            .s = tx.s,
            .v = tx.v,
        };
    }
    fn pollRebaseCallback(ctx: ?*anyopaque) void {
        const self: *NodeRuntime = @ptrCast(@alignCast(ctx.?));
        // Reset joins this worker while holding the RPC lock. Never wait on it.
        if (!self.runtime_mutex.tryLock()) return;
        const tracker = self.rebase_tracker orelse {
            self.runtime_mutex.unlock();
            return;
        };
        const resolver = self.fork_rpc_resolver.?;
        const url = tracker.getUrlAlloc(self.allocator) catch {
            self.runtime_mutex.unlock();
            return;
        };
        self.runtime_mutex.unlock();
        defer self.allocator.free(url);
        const head = forkScalarQuantity(u64, self.allocator, resolver, url, "eth_blockNumber", "[]") catch return;
        if (!self.runtime_mutex.tryLock()) return;
        defer self.runtime_mutex.unlock();
        if (tracker.stop_flag.load(.acquire) or !std.mem.eql(u8, self.fork_config.?.url, url)) return;
        _ = self.rebaseToUpstreamBlock(head) catch |err| {
            log.warn(.fork, "rebase failed head={} error={s}", .{ head, @errorName(err) });
            return;
        };
    }
    pub fn pollUpstreamAndRebase(self: *NodeRuntime) !?RebaseSummary {
        self.runtime_mutex.lock();
        defer self.runtime_mutex.unlock();
        const tracker = self.rebase_tracker orelse return error.ForkFollowDisabled;
        const url = try tracker.getUrlAlloc(self.allocator);
        defer self.allocator.free(url);
        const head = try fetchRebaseHead(self, self.allocator, url);
        if (head <= tracker.current_fork_block) return null;
        return try self.rebaseToUpstreamBlock(head);
    }

    pub fn rebaseToUpstreamBlock(self: *NodeRuntime, new_upstream_head: u64) !RebaseSummary {
        self.runtime_mutex.lock();
        defer self.runtime_mutex.unlock();
        self.rebase_mutex.lock();
        defer self.rebase_mutex.unlock();
        const cfg = self.fork_config orelse return error.ForkNotEnabled;
        const tracker = self.rebase_tracker orelse return error.ForkFollowDisabled;
        const old = tracker.current_fork_block;
        var summary = RebaseSummary{ .old_fork_block = old, .new_fork_block = old };
        if (new_upstream_head <= old) return summary;
        self.emitExEx(.{ .rebase_started = .{ .old_fork_block = old, .new_upstream_head = new_upstream_head } });
        const a = self.allocator;
        var diff = try tracker.computeUpstreamDiff(a, .{ .context = self, .fetch_block_number = fetchRebaseHead, .fetch_account_changed = fetchAccountChanged, .fetch_storage_changed = fetchStorageChanged }, old, new_upstream_head);
        defer diff.deinit(a);
        const plan = try tracker.planReplay(a, &diff);
        defer a.free(plan);

        // Build and index a private chain. Allocation, upstream and pool errors
        // can abandon the candidate without invalidating the live snapshots.
        var coinbase_index: u8 = 0;
        for (self.managed_accounts, 0..) |account, index| {
            if (std.mem.eql(u8, &account.address.bytes, &self.default_coinbase.bytes)) {
                coinbase_index = @intCast(index);
                break;
            }
        }
        var stage = try NodeRuntime.init(a, .{
            .coinbase_index = coinbase_index,
            .fork_url = cfg.url,
            .fork_block_number = new_upstream_head,
            .fork_rpc_resolver = self.fork_rpc_resolver,
            .chain_id = self.chain_id,
            .initial_balance = self.initial_balance,
            .hardfork_config = self.hardfork_config,
            .genesis_alloc_path = self.genesis_alloc_path,
            .block_gas_limit = self.dev_runtime.default_block_gas_limit,
            .base_fee = self.default_base_fee,
            .blob_base_fee = self.default_blob_base_fee,
        });
        defer stage.deinit();
        stage.enableSynchronousForkReads();
        stage.coinbase = self.coinbase;
        stage.dev_runtime.config = self.dev_runtime.config;
        var pending = try self.pool.clone(a);
        defer pending.deinit();
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const outcomes = try arena.alloc(exex.Event, plan.len);
        const replacements = try arena.alloc(?rebase_fork.LocalTxEntry, plan.len);
        @memset(replacements, null);
        defer for (replacements) |*replacement| {
            if (replacement.*) |*entry| entry.deinit(a);
        };
        for (tracker.local_txs.items, plan, 0..) |entry, disposition, index| {
            var replay_arena = std.heap.ArenaAllocator.init(a);
            defer replay_arena.deinit();
            const temporary = replay_arena.allocator();
            const pooled = try pooledFromEntry(temporary, entry);
            var coordinator = miningCoordinatorFromRuntime(&stage);
            defer coordinator.deinit(a);
            const parent_hash = stage.blockchain.getCanonicalHash(stage.head_block_number) orelse return error.MissingParentBlock;
            const parent = stage.blockchain.getBlockLocal(parent_hash) orelse return error.MissingParentBlock;
            coordinator.parent_blob_fees = .{
                .excess = parent.header.excess_blob_gas orelse 0,
                .used = parent.header.blob_gas_used orelse 0,
                .base_fee = parent.header.base_fee_per_gas orelse 0,
            };
            var ctx = block_builder.blockContextWithEnvironmentOverrides(&stage.dev_runtime, coordinator.blockContext(.{}));
            var hashes: [256][32]u8 = undefined;
            ctx.block_hashes = try stage.recentBlockHashesForExecution(ctx.block_number, &hashes);
            const fork = stage.hardforkForBlockContext(ctx);
            try stage.state.checkpoint();
            var block_adapter = host_adapter.HostAdapter{ .state = &stage.state };
            var preserved_empty = if (fork.isAtLeast(.SPURIOUS_DRAGON)) try block_builder.collectEmptyAccounts(temporary, &stage.state) else null;
            if (fork.isAtLeast(.CANCUN)) try block_builder.applyBeaconRootsSystemCallWithContext(temporary, &stage.state, block_adapter.hostInterface(), ctx, fork, primitives.Hash.ZERO);
            if (fork.isAtLeast(.PRAGUE)) try block_builder.applyHistoricalBlockHashSystemCallWithContext(temporary, &stage.state, block_adapter.hostInterface(), ctx, fork, parent_hash);
            var receipt: primitives.Receipt.Receipt = undefined;
            var owns_receipt = false;
            defer if (owns_receipt) receipt.deinit(a);
            if (disposition == .carry_forward) {
                receipt = self.receipt_index.getByTxHash(entry.tx_hash) orelse return error.MissingReplayReceipt;
                // Finalization rewrites log indexes in place.
                receipt.logs = try temporary.dupe(@TypeOf(receipt.logs[0]), receipt.logs);
                for (entry.cached_account_deltas.items) |delta| {
                    const addr = primitives.Address{ .bytes = delta.address };
                    try stage.state.setBalance(addr, delta.balance);
                    try stage.state.setNonce(addr, delta.nonce);
                    if (delta.code) |code| try stage.state.setCode(addr, code);
                }
                for (entry.cached_storage_deltas.items) |delta| try stage.state.setStorage(.{ .bytes = delta.address }, delta.slot, delta.value);
                summary.skipped_reexecution_count += 1;
            } else {
                var prior = try copyOverlay(temporary, &stage.state);
                defer prior.deinit();
                var access = rebase_fork.TxAccessSet{};
                receipt = stage.executeRecordedTx(temporary, &stage.state, pooled, ctx, &access) catch |err| {
                    stage.state.revert();
                    switch (err) {
                        error.OutOfMemory, error.StateError, error.EvmInitError => return err,
                        else => {},
                    }
                    try pending.addWithBaseNonce(pooled, pooled.nonce);
                    outcomes[index] = .{ .rebase_tx_dropped = .{ .tx_hash = entry.tx_hash, .reason = @constCast(@errorName(err)) } };
                    summary.dropped_count += 1;
                    continue;
                };
                owns_receipt = true;
                replacements[index] = try stage.captureEntry(temporary, &prior, &stage.state, pooled, receipt, ctx, &access);
            }
            receipt.cumulative_gas_used = receipt.gas_used;
            var receipts = [_]primitives.Receipt.Receipt{receipt};
            var indexes = [_]usize{0};
            const builder_fork = block_builder.hardforkFromEvm(fork);
            const requests_hash = if (fork.isAtLeast(.PRAGUE)) blk: {
                const requests = try block_builder.collectBlockExecutionRequestsWithOptions(temporary, &stage.state, &receipts, builder_fork, ctx, .{
                    .deposit_contract_address = stage.hardfork_config.deposit_contract_address orelse block_builder.DEPOSIT_CONTRACT_ADDRESS,
                    .require_system_contracts = stage.genesis_alloc_path != null,
                });
                break :blk try block_builder.computeRequestsHashFromRawRequests(temporary, requests);
            } else null;
            if (preserved_empty) |*preserved| {
                var touched = std.AutoHashMap(primitives.Address, void).init(temporary);
                const access = if (replacements[index]) |new_entry| new_entry.access_set else entry.access_set;
                for (access.accounts_written.items) |address| try touched.put(.{ .bytes = address }, {});
                try block_builder.pruneEmptyAccounts(temporary, &stage.state, preserved, &touched);
            }
            if (!fork.isAtLeast(.BYZANTIUM)) {
                receipts[0].status = null;
                receipts[0].root = try block_builder.computeStateRootForFork(temporary, &stage.state, builder_fork);
            }
            if (!fork.isAtLeast(.MERGE)) try block_builder.applyMinerReward(&stage.state, ctx.block_coinbase, builder_fork);
            var result = block_builder.BlockResult{
                .receipts = &receipts,
                .included_tx_indexes = &indexes,
                .total_gas_used = @intCast(receipt.gas_used),
                .block_number = ctx.block_number,
                .transactions_root = undefined,
                .receipts_root = undefined,
                .state_root = try block_builder.computeStateRootForFork(a, &stage.state, block_builder.hardforkFromEvm(fork)),
                .logs_bloom = receipt.logs_bloom,
                .withdrawals_root = null,
                .blob_gas_used = @intCast(receipt.blob_gas_used orelse 0),
                .requests_hash = requests_hash,
            };

            result.receipts_root = try block_builder.computeReceiptsRoot(a, result.receipts);
            _ = try stage.persistMinedBlock(ctx, coordinator.excessAt(ctx.block_number, ctx.block_timestamp), &result, &.{pooled});
            stage.state.commit();
            stage.blob_base_fee = ctx.blob_base_fee;
            if (fork.isAtLeast(.LONDON)) stage.base_fee = mining_coordinator.calculateNextBaseFee(ctx.block_base_fee, result.total_gas_used, ctx.block_gas_limit);
            stage.dev_runtime.config.next_block_timestamp = null;
            stage.head_block_number = ctx.block_number;
            stage.head_block_timestamp = ctx.block_timestamp;
            outcomes[index] = .{ .rebase_tx_replayed = .{ .tx_hash = entry.tx_hash, .new_block_number = ctx.block_number, .skipped_execution = disposition == .carry_forward } };
            summary.replayed_count += 1;
        }
        const next_snapshot = self.next_snapshot_id;
        self.clearSnapshots();
        self.next_snapshot_id = next_snapshot;
        self.clearReplayStateCache();
        self.clearEngineImportState();
        self.clearEnginePayloadJobs();
        self.clearEngineInvalidPayloads();
        self.engine_safe_hash = null;
        self.engine_finalized_hash = null;
        inline for (.{ "state", "fork_backend", "blockchain", "owned_block_bodies", "receipt_index", "log_index", "head_block_number", "head_block_timestamp", "genesis_header", "genesis_extra_data", "fork_proof_unavailable", "base_fee", "blob_base_fee" }) |field|
            std.mem.swap(@FieldType(NodeRuntime, field), &@field(self, field), &@field(stage, field));
        self.fork_backend.?.sync_resolver = null;
        self.enableSynchronousForkReads();
        std.mem.swap(txpool.TransactionPool, &self.pool, &pending);
        tracker.mutex.lock();
        var retained: usize = 0;
        for (outcomes, replacements, 0..) |outcome, *replacement, index| {
            var entry = &tracker.local_txs.items[index];
            if (outcome == .rebase_tx_dropped) {
                entry.deinit(a);
                continue;
            }
            if (replacement.*) |fresh| {
                entry.deinit(a);
                entry.* = fresh;
                replacement.* = null;
            }
            entry.original_block_number = outcome.rebase_tx_replayed.new_block_number;
            tracker.local_txs.items[retained] = entry.*;
            retained += 1;
        }
        tracker.local_txs.shrinkRetainingCapacity(retained);
        tracker.current_fork_block = new_upstream_head;
        tracker.mutex.unlock();
        for (outcomes) |event| {
            if (self.event_hub != null and event == .rebase_tx_dropped) {
                const hash = event.rebase_tx_dropped.tx_hash;
                if (self.pool.hash_index.get(hash)) |index| {
                    const tx = self.pool.items()[index];
                    self.emitExEx(.{ .tx_pool_add = .{ .tx_hash = hash, .sender = tx.sender.bytes, .nonce = tx.nonce } });
                }
            }
            self.emitExEx(event);
        }
        summary.new_fork_block = new_upstream_head;
        self.emitExEx(.{ .rebase_completed = .{ .new_fork_block = new_upstream_head, .replayed_count = summary.replayed_count, .dropped_count = summary.dropped_count } });
        return summary;
    }

    pub fn reset(self: *NodeRuntime, mode: ResetForkMode) !void {
        if (browser and mode == .replace) return error.ModeUnsupported;
        self.runtime_mutex.lock();
        defer self.runtime_mutex.unlock();
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

        const replacement = try createTracker(self.allocator, target_fork);
        self.rebuildState(target_fork) catch |err| {
            if (replacement) |t| {
                t.deinit();
                self.allocator.destroy(t);
            }
            return err;
        };
        self.destroyTracker();
        self.rebase_tracker = replacement;
        self.coinbase = self.default_coinbase;
        self.head_block_number = 0;
        self.head_block_timestamp = self.genesis_header.timestamp;
        self.engine_safe_hash = null;
        self.engine_finalized_hash = null;
        self.clearEngineImportState();
        self.clearReplayStateCache();
        self.clearEngineInvalidPayloads();
        self.gas_price = self.default_gas_price;
        self.base_fee = self.default_base_fee;
        self.blob_base_fee = self.default_blob_base_fee;
        self.max_priority_fee = self.default_max_priority_fee;
        self.mining_config = self.default_mining_config;
        self.pool.clear();
        self.clearRpcFilters();
        self.clearEnginePayloadJobs();
        self.time_offset = 0;
        self.next_block_timestamp = null;
        self.block_timestamp_interval = null;
        self.dev_runtime.resetConfig(self.default_coinbase);
        self.impersonated_accounts.clearRetainingCapacity();
        self.auto_impersonate_account = false;
        try self.resetQueryIndexes();
        self.clearSnapshots();
        self.emitForkChanged();
        if (self.background_started or self.mining_config == .interval) try self.startBackgroundServices();
    }

    pub fn setRpcUrl(self: *NodeRuntime, new_url: []const u8) !void {
        self.runtime_mutex.lock();
        defer self.runtime_mutex.unlock();
        try validateForkUrl(new_url);
        if (browser) return error.ModeUnsupported;

        var fork_cfg = self.fork_config orelse return error.ForkNotEnabled;
        const new_url_owned = try self.allocator.dupe(u8, new_url);
        errdefer self.allocator.free(new_url_owned);
        if (self.rebase_tracker) |tracker| try tracker.setRpcUrl(new_url);
        self.allocator.free(fork_cfg.url);
        fork_cfg.url = new_url_owned;
        self.fork_config = fork_cfg;

        // Upstream changed; clear only remote cache while preserving local overlays.
        self.fork_proof_unavailable = false;
        self.state.clearForkCache();
        self.emitForkChanged();
    }

    pub fn stopBackgroundServices(self: *NodeRuntime) void {
        self.stopLightSyncThread();
        self.stopIntervalMiningTimer();
        if (self.rebase_tracker) |tracker| tracker.stopPolling();
        self.background_started = false;
    }

    pub fn deinit(self: *NodeRuntime) void {
        self.stopBackgroundServices();
        self.destroyTracker();
        self.runtime_mutex.pool_before.deinit(self.allocator);
        self.blob_verifier.deinit();
        if (self.light) |*light| {
            light.deinit(self.allocator);
            self.light = null;
        }
        self.clearSnapshots();
        self.clearRpcFilters();
        self.clearEnginePayloadJobs();
        self.clearEngineImportState();
        self.clearReplayStateCache();
        self.clearEngineInvalidPayloads();
        self.pool.deinit();
        self.dev_runtime.deinit(self.allocator);
        self.console_logs.deinit();
        self.snapshots.deinit();
        self.rpc_filters.deinit();
        self.engine_payload_jobs.deinit();
        self.engine_invalid_payloads.deinit();
        self.pending_transaction_filter_events.deinit(self.allocator);
        self.impersonated_accounts.deinit();
        self.log_index.deinit(self.allocator);
        self.receipt_index.deinit(self.allocator);
        self.blockchain.deinit();
        if (self.genesis_alloc_path) |path| {
            self.allocator.free(path);
            self.genesis_alloc_path = null;
        }
        if (self.genesis_extra_data) |bytes| {
            self.allocator.free(bytes);
            self.genesis_extra_data = null;
        }
        self.clearOwnedBlockBodies();
        self.owned_block_bodies.deinit(self.allocator);
        self.state.deinit();
        destroyForkBackend(self.allocator, self.fork_backend);
        freeForkConfig(self.allocator, self.fork_config);
        if (self.engine_sync_fallback_url) |url| {
            self.allocator.free(url);
            self.engine_sync_fallback_url = null;
        }
        self.fork_backend = null;
        self.fork_config = null;
    }

    fn replayMaterializeOptions(self: *const NodeRuntime) MaterializeImportedBlockOptions {
        return .{
            .infer_legacy_hardfork = self.legacy_fixture_chain,
            .allow_impersonated_legacy = self.genesis_alloc_path == null,
        };
    }

    pub fn replayStateToBlock(self: *NodeRuntime, block_number: u64) !state_manager.StateManager {
        if (self.fork_backend != null) return error.HistoricalStateUnavailable;
        if (block_number > self.head_block_number) return error.InvalidParams;

        var materialized = try self.materializeCanonicalStateAndIndexes(block_number);
        materialized.receipt_index.deinit(self.allocator);
        materialized.log_index.deinit(self.allocator);
        return materialized.state;
    }

    pub fn readStateAtBlock(self: *NodeRuntime, block_number: u64) !*state_manager.StateManager {
        if (block_number > self.head_block_number) return error.InvalidParams;
        if (block_number == self.head_block_number) return &self.state;
        if (self.fork_backend != null) return error.HistoricalStateUnavailable;
        return self.cachedReplayStateToBlock(block_number);
    }

    fn cachedReplayStateToBlock(self: *NodeRuntime, block_number: u64) !*state_manager.StateManager {
        const target_hash = self.blockchain.getCanonicalHash(block_number) orelse return error.ImportedBlockMissing;

        if (self.replay_state_cache != null) {
            const cached_number = self.replay_state_cache_number.?;
            const cached_hash = self.replay_state_cache_hash.?;
            const canonical_cached_hash = self.blockchain.getCanonicalHash(cached_number);
            const cache_still_canonical = if (canonical_cached_hash) |hash|
                std.mem.eql(u8, &hash, &cached_hash)
            else
                false;

            if (cache_still_canonical) {
                if (cached_number == block_number) return &self.replay_state_cache.?;
                if (cached_number < block_number) {
                    try self.extendReplayStateCache(cached_number + 1, block_number);
                    self.replay_state_cache_number = block_number;
                    self.replay_state_cache_hash = target_hash;
                    return &self.replay_state_cache.?;
                }
            }

            self.clearReplayStateCache();
        }

        var materialized = try self.materializeCanonicalStateAndIndexes(block_number);
        materialized.receipt_index.deinit(self.allocator);
        materialized.log_index.deinit(self.allocator);
        self.replay_state_cache = materialized.state;
        self.replay_state_cache_number = block_number;
        self.replay_state_cache_hash = target_hash;
        return &self.replay_state_cache.?;
    }

    fn extendReplayStateCache(self: *NodeRuntime, from_block_number: u64, to_block_number: u64) !void {
        if (from_block_number > to_block_number) return;
        // A failure part-way leaves the cache advanced past its recorded block
        // number; drop it so a half-advanced state is never served.
        errdefer self.clearReplayStateCache();

        var temp_receipt_index = receipt_index_mod.ReceiptIndex.init(self.allocator);
        defer temp_receipt_index.deinit(self.allocator);
        var temp_log_index = log_index_mod.LogIndex.init();
        defer temp_log_index.deinit(self.allocator);

        var number = from_block_number;
        while (number <= to_block_number) : (number += 1) {
            const block = self.blockchain.getBlockByNumberLocal(number) orelse return error.ImportedBlockMissing;
            _ = try materializeImportedBlock(
                self.allocator,
                &self.replay_state_cache.?,
                &self.blockchain,
                &temp_receipt_index,
                &temp_log_index,
                self.chain_id,
                self.hardfork_config,
                self.blob_base_fee,
                block,
                self.replayMaterializeOptions(),
            );
        }
    }

    pub fn replayStateToBlockHash(self: *NodeRuntime, block_hash: [32]u8) !state_manager.StateManager {
        if (self.fork_backend != null) return error.HistoricalStateUnavailable;

        var path = std.ArrayList(primitives.Block.Block){};
        defer path.deinit(self.allocator);

        var cursor = self.blockchain.getBlockLocal(block_hash) orelse return error.ImportedBlockMissing;
        while (cursor.header.number > 0) {
            try path.append(self.allocator, cursor);
            cursor = self.blockchain.getBlockLocal(cursor.header.parent_hash) orelse return error.MissingParentBlock;
        }

        var historical = try self.initReplayState();
        errdefer historical.deinit();

        var receipt_index = receipt_index_mod.ReceiptIndex.init(self.allocator);
        defer receipt_index.deinit(self.allocator);
        var log_index = log_index_mod.LogIndex.init();
        defer log_index.deinit(self.allocator);

        var index = path.items.len;
        while (index > 0) {
            index -= 1;
            _ = try materializeImportedBlock(
                self.allocator,
                &historical,
                &self.blockchain,
                &receipt_index,
                &log_index,
                self.chain_id,
                self.hardfork_config,
                self.blob_base_fee,
                path.items[index],
                self.replayMaterializeOptions(),
            );
        }

        return historical;
    }

    fn initReplayState(self: *NodeRuntime) !state_manager.StateManager {
        var historical = try state_manager.StateManager.init(self.allocator, null);
        errdefer historical.deinit();

        if (self.genesis_alloc_path) |path| {
            var loaded = try genesis_alloc.loadGenesisFile(self.allocator, &historical, path);
            defer loaded.deinit(self.allocator);
        } else {
            // Replay starts from the same genesis allocation `init` built.
            try genesis.seedDevGenesisState(&historical, &self.managed_accounts, self.initial_balance, self.fork_backend != null);
        }

        return historical;
    }

    fn materializeCanonicalStateAndIndexes(self: *NodeRuntime, block_number: u64) !CanonicalMaterialization {
        var historical = try self.initReplayState();
        errdefer historical.deinit();

        var receipt_index = receipt_index_mod.ReceiptIndex.init(self.allocator);
        errdefer receipt_index.deinit(self.allocator);
        var log_index = log_index_mod.LogIndex.init();
        errdefer log_index.deinit(self.allocator);

        var number: u64 = 1;
        while (number <= block_number) : (number += 1) {
            const block = (try self.blockchain.getBlockByNumber(number)) orelse return error.ImportedBlockMissing;
            _ = try materializeImportedBlock(
                self.allocator,
                &historical,
                &self.blockchain,
                &receipt_index,
                &log_index,
                self.chain_id,
                self.hardfork_config,
                self.blob_base_fee,
                block,
                self.replayMaterializeOptions(),
            );
        }

        return .{
            .state = historical,
            .receipt_index = receipt_index,
            .log_index = log_index,
        };
    }

    fn materializeCanonicalExtension(self: *NodeRuntime, from_block_number: u64, to_block_number: u64) !void {
        if (to_block_number <= from_block_number) return;

        var receipt_backup = try self.receipt_index.clone(self.allocator);
        var receipt_backup_live = true;

        // The shared restore/free defer below is not registered yet, so a
        // failed log clone must release the receipt backup itself.
        var log_backup = self.log_index.clone(self.allocator) catch |err| {
            receipt_backup.deinit(self.allocator);
            return err;
        };
        var log_backup_live = true;
        var indexes_committed = false;
        defer {
            if (!indexes_committed) {
                self.receipt_index.deinit(self.allocator);
                self.log_index.deinit(self.allocator);
                self.receipt_index = receipt_backup;
                self.log_index = log_backup;
                receipt_backup_live = false;
                log_backup_live = false;
            }
            if (receipt_backup_live) receipt_backup.deinit(self.allocator);
            if (log_backup_live) log_backup.deinit(self.allocator);
        }

        try self.state.checkpoint();
        var state_committed = false;
        defer if (!state_committed) self.state.revert();

        var number = from_block_number + 1;
        while (number <= to_block_number) : (number += 1) {
            const block = (try self.blockchain.getBlockByNumber(number)) orelse return error.ImportedBlockMissing;
            _ = try materializeImportedBlock(
                self.allocator,
                &self.state,
                &self.blockchain,
                &self.receipt_index,
                &self.log_index,
                self.chain_id,
                self.hardfork_config,
                self.blob_base_fee,
                block,
                self.replayMaterializeOptions(),
            );
        }

        self.state.commit();
        state_committed = true;
        indexes_committed = true;
        receipt_backup.deinit(self.allocator);
        receipt_backup_live = false;
        log_backup.deinit(self.allocator);
        log_backup_live = false;
    }

    pub fn importEnginePayloadBlock(
        self: *NodeRuntime,
        payload_block: primitives.Block.Block,
        requests_hash: ?[32]u8,
    ) anyerror!EnginePayloadImportResult {
        var block = payload_block;
        const computed_hash = block_builder.computeHeaderHashWithRequestsHash(self.allocator, &block.header, requests_hash) catch |err| {
            if (err == error.OutOfMemory) return err;
            return .{ .status = .invalid_block_hash, .validation_error = "invalid block hash" };
        };
        if (!std.mem.eql(u8, &computed_hash, &block.hash)) {
            return .{ .status = .invalid_block_hash, .validation_error = "blockHash does not match payload header" };
        }

        if (self.engine_invalid_payloads.get(block.hash)) |record| {
            return .{
                .status = .invalid,
                .latest_valid_hash = record.latest_valid_hash,
                .validation_error = record.validation_error,
            };
        }

        if (self.blockchain.getBlockLocal(block.hash)) |existing| {
            if (existing.header.number <= self.head_block_number) {
                return .{ .status = .valid, .latest_valid_hash = block.hash };
            }
        }

        const parent = self.blockchain.getBlockLocal(block.header.parent_hash) orelse parent: {
            if (self.engine_invalid_payloads.get(block.header.parent_hash)) |record| {
                try self.rememberInvalidEnginePayload(
                    block.hash,
                    record.latest_valid_hash,
                    record.validation_error orelse "invalid ancestor",
                );
                return .{
                    .status = .invalid,
                    .latest_valid_hash = record.latest_valid_hash,
                    .validation_error = record.validation_error orelse "invalid ancestor",
                };
            }
            if (try self.importEngineMissingAncestors(block.header.parent_hash)) {
                if (self.engine_invalid_payloads.get(block.header.parent_hash)) |record| {
                    try self.rememberInvalidEnginePayload(
                        block.hash,
                        record.latest_valid_hash,
                        record.validation_error orelse "invalid ancestor",
                    );
                    return .{
                        .status = .invalid,
                        .latest_valid_hash = record.latest_valid_hash,
                        .validation_error = record.validation_error orelse "invalid ancestor",
                    };
                }
                if (self.blockchain.getBlockLocal(block.header.parent_hash)) |resolved_parent| {
                    break :parent resolved_parent;
                }
            }
            return .{ .status = .syncing };
        };

        var replayed_state: ?state_manager.StateManager = null;
        defer if (replayed_state) |*state| state.deinit();
        var checkpointed_import_state = false;
        defer if (checkpointed_import_state) self.engine_import_state.?.revert();
        var temp_receipt_index = receipt_index_mod.ReceiptIndex.init(self.allocator);
        defer temp_receipt_index.deinit(self.allocator);
        var temp_log_index = log_index_mod.LogIndex.init();
        defer temp_log_index.deinit(self.allocator);

        const sm = blk: {
            if (self.engine_import_state_hash) |cached_hash| {
                if (self.engine_import_state != null and std.mem.eql(u8, &cached_hash, &parent.hash)) {
                    try self.engine_import_state.?.checkpoint();
                    checkpointed_import_state = true;
                    break :blk &self.engine_import_state.?;
                }
            }

            replayed_state = try self.replayStateToBlockHash(parent.hash);
            break :blk &replayed_state.?;
        };

        _ = materializeImportedBlock(
            self.allocator,
            sm,
            &self.blockchain,
            &temp_receipt_index,
            &temp_log_index,
            self.chain_id,
            self.hardfork_config,
            self.blob_base_fee,
            block,
            .{
                .strict = true,
                .validate_tx_chain_id = true,
                .requests_hash = requests_hash,
                .require_system_contracts = self.genesis_alloc_path != null,
            },
        ) catch |err| {
            // Local faults (allocation, EVM setup, state backend) say nothing
            // about the payload; caching them would make a valid block
            // permanently INVALID. Surface them as internal errors instead.
            if (!isDeterministicPayloadError(err)) return err;
            log.warn(.rpc, "engine_new_payload_invalid block_number={} error={s}", .{ block.header.number, @errorName(err) });
            try self.rememberInvalidEnginePayload(block.hash, parent.hash, @errorName(err));
            return .{ .status = .invalid, .latest_valid_hash = parent.hash, .validation_error = @errorName(err) };
        };

        var owned_body = try chain_import.cloneBlockBody(self.allocator, &block);
        owned_body.requests_hash = requests_hash;
        var owned = false;
        errdefer if (!owned) owned_body.deinit(self.allocator);
        // Reserve the body slot first: an append failure after putBlock would
        // free owned_body while the blockchain still borrows its slices.
        try self.owned_block_bodies.ensureUnusedCapacity(self.allocator, 1);
        try self.blockchain.putBlock(block);
        self.owned_block_bodies.appendAssumeCapacity(owned_body);
        owned = true;

        if (checkpointed_import_state) {
            self.engine_import_state.?.commit();
            checkpointed_import_state = false;
            self.engine_import_state_hash = block.hash;
        } else {
            const import_state = replayed_state orelse return error.ImportedBlockMissing;
            replayed_state = null;
            self.clearEngineImportState();
            self.clearReplayStateCache();
            self.engine_import_state = import_state;
            self.engine_import_state_hash = block.hash;
        }

        return .{ .status = .valid, .latest_valid_hash = block.hash };
    }

    pub fn setEngineCanonicalHead(self: *NodeRuntime, head_hash: [32]u8) !EnginePayloadImportResult {
        const head_block = self.blockchain.getBlockLocal(head_hash) orelse {
            return .{ .status = .syncing };
        };
        const current_head_hash = self.blockchain.getCanonicalHash(self.head_block_number);
        const already_current = if (current_head_hash) |hash| std.mem.eql(u8, &hash, &head_hash) else false;
        // Capture the canonical tip before setCanonicalHead moves it; afterwards
        // the store reports the new head and stale heights would survive.
        const previous_canonical_max = self.blockchain.getHeadBlockNumber() orelse self.head_block_number;

        // Collect canonical-branch tx hashes BEFORE mutating state/blockchain
        // so an OOM here never leaves new state installed under the old head.
        var pre_collected_mined_hashes = std.ArrayList([32]u8){};
        defer pre_collected_mined_hashes.deinit(self.allocator);
        if (!already_current) {
            var cursor = self.blockchain.getBlockLocal(head_hash) orelse return error.ImportedBlockMissing;
            while (true) {
                if (current_head_hash) |hash| {
                    if (std.mem.eql(u8, &cursor.hash, &hash)) break;
                }
                for (cursor.body.transactions) |tx| {
                    try pre_collected_mined_hashes.append(self.allocator, tx_encoding.transactionHash(tx.raw));
                }
                if (cursor.header.number == 0) break;
                cursor = self.blockchain.getBlockLocal(cursor.header.parent_hash) orelse return error.ImportedBlockMissing;
            }
        }

        if (!already_current) {
            const previous_head_hash = current_head_hash;
            const previous_head_number = self.head_block_number;
            const can_extend_current = if (previous_head_hash) |hash|
                head_block.header.number >= previous_head_number and self.localBlockIsAncestorOf(hash, head_hash)
            else
                false;

            try self.blockchain.setCanonicalHead(head_hash);
            if (can_extend_current) {
                self.materializeCanonicalExtension(previous_head_number, head_block.header.number) catch |err| {
                    if (previous_head_hash) |hash| {
                        self.blockchain.setCanonicalHead(hash) catch {};
                        self.pruneCanonicalChainAbove(previous_head_number, @max(previous_canonical_max, head_block.header.number));
                    }
                    return err;
                };
            } else {
                var materialized = self.materializeCanonicalStateAndIndexes(head_block.header.number) catch |err| {
                    if (previous_head_hash) |hash| {
                        self.blockchain.setCanonicalHead(hash) catch {};
                        self.pruneCanonicalChainAbove(previous_head_number, @max(previous_canonical_max, head_block.header.number));
                    }
                    return err;
                };
                var materialized_assigned = false;
                defer if (!materialized_assigned) materialized.deinit(self.allocator);
                self.clearSnapshots();
                self.state.deinit();
                self.receipt_index.deinit(self.allocator);
                self.log_index.deinit(self.allocator);
                self.state = materialized.state;
                self.receipt_index = materialized.receipt_index;
                self.log_index = materialized.log_index;
                materialized_assigned = true;
            }
        }
        self.pruneCanonicalChainAbove(head_block.header.number, @max(previous_canonical_max, self.head_block_number));

        self.pool.removeMined(pre_collected_mined_hashes.items);
        self.revalidatePoolNonces();

        self.head_block_number = head_block.header.number;
        self.head_block_timestamp = head_block.header.timestamp;
        if (head_block.header.base_fee_per_gas != null) {
            const child_fork = self.hardforkAt(head_block.header.number + 1, head_block.header.timestamp + 1);
            if (child_fork.isAtLeast(.LONDON)) {
                self.base_fee = block_builder.expectedBaseFeePerGas(&head_block.header) catch head_block.header.base_fee_per_gas.?;
            } else {
                self.base_fee = head_block.header.base_fee_per_gas.?;
            }
        }
        if (head_block.header.excess_blob_gas) |excess| {
            self.blob_base_fee = blob_fee.blobBaseFeeAt(
                self.hardfork_config,
                head_block.header.number,
                head_block.header.timestamp,
                excess,
            );
        }
        return .{ .status = .valid, .latest_valid_hash = head_hash };
    }

    fn pruneCanonicalChainAbove(self: *NodeRuntime, head_number: u64, previous_max_number: u64) void {
        // Logs are indexed by canonical height, so a reorg to a lower head must
        // drop them even when the block store had nothing left to prune.
        self.log_index.removeBlocksAbove(head_number);
        if (previous_max_number <= head_number) return;

        var number = head_number + 1;
        while (true) {
            _ = self.blockchain.block_store.canonical_chain.remove(number);
            if (number == previous_max_number) break;
            number += 1;
        }
    }

    fn removeCanonicalBranchTransactionsFromPool(
        self: *NodeRuntime,
        head_hash: [32]u8,
        stop_hash: ?[32]u8,
    ) !void {
        var mined_hashes = std.ArrayList([32]u8){};
        defer mined_hashes.deinit(self.allocator);

        var cursor = self.blockchain.getBlockLocal(head_hash) orelse return error.ImportedBlockMissing;
        while (true) {
            if (stop_hash) |hash| {
                if (std.mem.eql(u8, &cursor.hash, &hash)) break;
            }

            for (cursor.body.transactions) |tx| {
                try mined_hashes.append(self.allocator, tx_encoding.transactionHash(tx.raw));
            }

            if (cursor.header.number == 0) break;
            cursor = self.blockchain.getBlockLocal(cursor.header.parent_hash) orelse return error.ImportedBlockMissing;
        }

        self.pool.removeMined(mined_hashes.items);
    }

    fn revalidatePoolNonces(self: *NodeRuntime) void {
        var senders = std.ArrayList(primitives.Address){};
        defer senders.deinit(self.allocator);
        var nonces = std.ArrayList(u64){};
        defer nonces.deinit(self.allocator);
        var bn_it = self.pool.base_nonces.iterator();
        while (bn_it.next()) |entry| {
            const sender = primitives.Address{ .bytes = entry.key_ptr.* };
            const state_nonce = self.state.getNonce(sender) catch continue;
            if (state_nonce != entry.value_ptr.nonce) {
                senders.append(self.allocator, sender) catch continue;
                nonces.append(self.allocator, state_nonce) catch {
                    _ = senders.pop();
                    continue;
                };
            }
        }
        self.pool.revalidateAgainstState(senders.items, nonces.items);
    }

    pub fn setEngineFinalityHeads(
        self: *NodeRuntime,
        safe_hash: ?[32]u8,
        finalized_hash: ?[32]u8,
    ) void {
        self.engine_safe_hash = safe_hash;
        self.engine_finalized_hash = finalized_hash;
    }

    pub fn engineSafeBlockNumber(self: *const NodeRuntime) ?u64 {
        const hash = self.engine_safe_hash orelse return null;
        const block = @constCast(&self.blockchain).getBlockLocal(hash) orelse return null;
        return block.header.number;
    }

    pub fn engineFinalizedBlockNumber(self: *const NodeRuntime) ?u64 {
        const hash = self.engine_finalized_hash orelse return null;
        const block = @constCast(&self.blockchain).getBlockLocal(hash) orelse return null;
        return block.header.number;
    }

    pub fn localBlockIsAncestorOf(
        self: *const NodeRuntime,
        ancestor_hash: [32]u8,
        descendant_hash: [32]u8,
    ) bool {
        var chain = @constCast(&self.blockchain);
        const ancestor = chain.getBlockLocal(ancestor_hash) orelse return false;
        var cursor = chain.getBlockLocal(descendant_hash) orelse return false;
        if (ancestor.header.number > cursor.header.number) return false;

        while (cursor.header.number > ancestor.header.number) {
            cursor = chain.getBlockLocal(cursor.header.parent_hash) orelse return false;
        }
        return std.mem.eql(u8, &cursor.hash, &ancestor_hash);
    }

    fn rebuildState(self: *NodeRuntime, target_fork: ?ForkConfig) !void {
        const new_fork_config = try allocForkConfig(self.allocator, target_fork);
        errdefer freeForkConfig(self.allocator, new_fork_config);

        const new_backend = try createForkBackend(self.allocator, new_fork_config);
        errdefer destroyForkBackend(self.allocator, new_backend);

        var new_state = try state_manager.StateManager.init(self.allocator, new_backend);
        errdefer new_state.deinit();

        // Seed the same genesis as init/initReplayState so reset does not
        // silently swap a --genesis-alloc chain for the dev accounts.
        if (self.genesis_alloc_path) |path| {
            var loaded = try genesis_alloc.loadGenesisFile(self.allocator, &new_state, path);
            loaded.deinit(self.allocator);
        } else {
            try genesis.seedDevGenesisState(&new_state, &self.managed_accounts, self.initial_balance, new_backend != null);
        }

        self.state.deinit();
        destroyForkBackend(self.allocator, self.fork_backend);
        freeForkConfig(self.allocator, self.fork_config);

        self.state = new_state;
        self.fork_backend = new_backend;
        self.fork_config = new_fork_config;
        self.fork_proof_unavailable = false;
        self.enableSynchronousForkReads();
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
            // The backend pins reads to its own block tag copy; keep it in
            // step with the restored fork block.
            const block_tag: ?[]u8 = if (self.fork_backend) |backend|
                if (if (self.rebase_tracker) |tracker| @as(?u64, tracker.current_fork_block) else target.block_number) |block_number|
                    try std.fmt.allocPrint(backend.allocator, "0x{x}", .{block_number})
                else
                    try backend.allocator.dupe(u8, "latest")
            else
                null;
            errdefer if (block_tag) |tag| self.fork_backend.?.allocator.free(tag);
            const updated_url = try self.allocator.dupe(u8, target.url);
            errdefer self.allocator.free(updated_url);
            if (self.rebase_tracker) |tracker| try tracker.setRpcUrl(target.url);
            self.allocator.free(current.url);
            current.url = updated_url;
            current.block_number = target.block_number;
            self.fork_config = current;
            self.fork_proof_unavailable = false;
            if (block_tag) |tag| {
                const backend = self.fork_backend.?;
                backend.allocator.free(backend.block_tag);
                backend.block_tag = tag;
            }
            self.state.clearForkCache();
        }
    }

    /// Attach only after NodeRuntime reaches its final address; this callback
    /// allows state reads inside RPC handlers and the interpreter to complete.
    pub fn enableSynchronousForkReads(self: *NodeRuntime) void {
        if (self.fork_backend) |backend| {
            if (backend.sync_resolver == null) backend.sync_resolver = .{
                .context = self,
                .resolve = resolvePendingForkReads,
            };
        }
    }

    fn resolvePendingForkReads(context: ?*anyopaque) !void {
        const self: *NodeRuntime = @ptrCast(@alignCast(context.?));
        try self.serviceForkRequests();
    }

    fn serviceForkRequests(self: *NodeRuntime) !void {
        const resolver = self.fork_rpc_resolver orelse return error.ForkResolverUnavailable;
        const backend = self.fork_backend orelse return error.ForkNotEnabled;
        const fork_cfg = self.fork_config orelse return error.ForkNotEnabled;

        while (backend.nextRequest()) |request| {
            const response_payload = self.resolveForkRequest(resolver, fork_cfg.url, request) catch |err| {
                // Release the backend's pending entry. Otherwise the request is
                // never re-queued and every later read of this key fails.
                backend.continueRequest(request.id, "null") catch {};
                return err;
            };
            defer self.allocator.free(response_payload);

            backend.continueRequest(request.id, response_payload) catch |err| {
                log.warn(.fork, "fork upstream response rejected kind={s} error={s}", .{ @tagName(request.kind), @errorName(err) });
                return err;
            };
        }
    }

    /// Resolve one fork backend request to the JSON payload the backend expects.
    /// Account and storage reads use `eth_getProof`; when the upstream cannot
    /// serve it, they fall back to the scalar read methods.
    fn resolveForkRequest(
        self: *NodeRuntime,
        resolver: ForkRpcResolver,
        url: []const u8,
        request: anytype,
    ) ![]u8 {
        const method_name: []const u8 = switch (request.kind) {
            .code => "eth_getCode",
            .account_proof, .storage_proof => "eth_getProof",
        };
        const is_proof = request.kind != .code;

        if (!(is_proof and self.fork_proof_unavailable)) {
            if (resolver.resolve(resolver.context, self.allocator, .{
                .url = url,
                .method = method_name,
                .params_json = request.params_json,
            })) |payload| {
                return payload;
            } else |err| {
                log.warn(.fork, "fork upstream request failed method={s} error={s}", .{ method_name, @errorName(err) });
                if (!is_proof or err == error.OutOfMemory) return err;
            }
        }

        const payload = forkProofFromScalarReads(self.allocator, resolver, url, request) catch |err| {
            log.warn(.fork, "fork upstream scalar fallback failed error={s}", .{@errorName(err)});
            return err;
        };
        if (!self.fork_proof_unavailable) {
            self.fork_proof_unavailable = true;
            log.warn(.fork, "fork upstream lacks eth_getProof; using eth_getBalance/eth_getTransactionCount/eth_getCode/eth_getStorageAt", .{});
        }
        return payload;
    }

    fn cloneQueryIndexes(self: *const NodeRuntime) !QueryIndexSnapshot {
        return cloneQueryIndexSnapshot(
            self.allocator,
            &self.blockchain,
            self.owned_block_bodies.items,
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
        var new_owned_block_bodies = std.ArrayList(OwnedBlockBody){};
        errdefer {
            clearOwnedBlockBodyList(self.allocator, &new_owned_block_bodies);
            new_owned_block_bodies.deinit(self.allocator);
        }
        var new_blockchain = try initBlockchainWithGenesis(
            self.allocator,
            self.chain_id,
            genesis_state_root,
            if (self.genesis_alloc_path != null) primitives.Address.ZERO_ADDRESS else self.default_coinbase,
            self.genesis_header.gas_limit orelse self.dev_runtime.default_block_gas_limit,
            self.genesis_header,
            self.hardfork_config,
            &new_owned_block_bodies,
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
        self.owned_block_bodies.deinit(self.allocator);

        self.blockchain = new_blockchain;
        self.owned_block_bodies = new_owned_block_bodies;
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

        const header = primitives.BlockHeader.BlockHeader{
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
            .mix_hash = u256ToHash(block_ctx.block_prevrandao),
            .base_fee_per_gas = if (hardfork.isAtLeast(.LONDON)) block_ctx.block_base_fee else null,
            .withdrawals_root = if (hardfork.isAtLeast(.SHANGHAI))
                (result.withdrawals_root orelse primitives.BlockHeader.EMPTY_WITHDRAWALS_ROOT)
            else
                null,
            .blob_gas_used = if (hardfork.isAtLeast(.CANCUN)) result.blob_gas_used else null,
            .excess_blob_gas = if (hardfork.isAtLeast(.CANCUN)) block_excess_blob_gas else null,
            .parent_beacon_block_root = if (hardfork.isAtLeast(.CANCUN)) primitives.Hash.ZERO else null,
            .requests_hash = result.requests_hash,
        };

        const empty_withdrawals: []const primitives.BlockBody.Withdrawal = &.{};
        const body = primitives.BlockBody.BlockBody{
            .transactions = transactions,
            .ommers = &.{},
            .withdrawals = if (header.withdrawals_root != null) empty_withdrawals else null,
        };

        const block = try primitives.Block.from(&header, &body, self.allocator);
        try finalizeReceiptsForBlock(result, ready, block.hash, block.header.number);

        // Reserve the body slot before putBlock and transfer ownership
        // immediately after putBlock succeeds, before any further fallible
        // calls (such as setCanonicalHead), so an OOM cannot free transactions
        // that the stored block already borrows.
        try self.owned_block_bodies.ensureUnusedCapacity(self.allocator, 1);
        try self.blockchain.putBlock(block);
        self.owned_block_bodies.appendAssumeCapacity(.{
            .block_hash = block.hash,
            .transactions = transactions,
            .requests_hash = result.requests_hash,
        });
        transactions_owned_by_runtime = true;
        try self.blockchain.setCanonicalHead(block.hash);

        try self.receipt_index.putBlockReceipts(self.allocator, block.hash, result.receipts);
        // Keep the two query indexes in step: a block has receipts iff it has logs.
        errdefer self.receipt_index.removeBlockReceipts(self.allocator, block.hash);
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
                    NodeRuntime.executionTransactionBaseFromPooled(pooled).tx,
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

fn minKey(comptime K: type, comptime V: type, map: *const std.AutoHashMap(K, V)) ?K {
    var min: ?K = null;
    var it = map.keyIterator();
    while (it.next()) |key| min = if (min) |current| @min(current, key.*) else key.*;
    return min;
}

fn deinitSnapshotEntry(allocator: std.mem.Allocator, entry: *SnapshotEntry) void {
    freeForkConfig(allocator, entry.fork_config);
    entry.query_indexes.deinit(allocator);
    entry.pool.deinit();
    entry.impersonated_accounts.deinit();
}

fn cloneEnginePayloadAttributes(
    allocator: std.mem.Allocator,
    attrs: EnginePayloadAttributes,
) !EnginePayloadAttributes {
    return .{
        .timestamp = attrs.timestamp,
        .prev_randao = attrs.prev_randao,
        .fee_recipient = attrs.fee_recipient,
        .withdrawals = if (attrs.withdrawals.len == 0) &.{} else try allocator.dupe(primitives.BlockBody.Withdrawal, attrs.withdrawals),
        .has_withdrawals = attrs.has_withdrawals,
        .parent_beacon_block_root = attrs.parent_beacon_block_root,
        .payload_version = attrs.payload_version,
    };
}

fn cloneQueryIndexSnapshot(
    allocator: std.mem.Allocator,
    source_blockchain: *const blockchain_mod.Blockchain,
    source_owned_block_bodies: []const OwnedBlockBody,
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
        source_owned_block_bodies,
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
    source_owned_block_bodies: []const OwnedBlockBody,
    target: anytype,
    owned_block_bodies: *std.ArrayList(OwnedBlockBody),
) !void {
    // The EIP-7685 requests hash lives beside the block, not in its header;
    // carry it over so restored Prague blocks keep their commitment.
    var requests_hashes = std.AutoHashMap([32]u8, [32]u8).init(allocator);
    defer requests_hashes.deinit();
    for (source_owned_block_bodies) |body| {
        if (body.requests_hash) |hash| try requests_hashes.put(body.block_hash, hash);
    }

    var block_it = source.blocks.iterator();
    while (block_it.next()) |entry| {
        var block = entry.value_ptr.*;
        var owned_body = try chain_import.cloneBlockBody(allocator, &block);
        owned_body.requests_hash = requests_hashes.get(block.hash);
        var owned = false;
        errdefer if (!owned) owned_body.deinit(allocator);
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

const ImportedMaterializationStats = struct {
    block_count: usize = 0,
    transaction_count: usize = 0,
    receipt_count: usize = 0,
    log_count: usize = 0,
    receipt_root_mismatch_count: usize = 0,
    logs_bloom_mismatch_count: usize = 0,
    state_root_mismatch_count: usize = 0,
    stopped_block_number: ?u64 = null,
};

const ImportedBlockStats = struct {
    transaction_count: usize = 0,
    receipt_count: usize = 0,
    log_count: usize = 0,
    receipt_root_mismatch: bool = false,
    logs_bloom_mismatch: bool = false,
    state_root_mismatch: bool = false,
};

const MaterializeImportedBlockOptions = struct {
    strict: bool = false,
    validate_tx_chain_id: bool = false,
    requests_hash: ?[32]u8 = null,
    /// Legacy RLP fixture chains (ethereum-tests BlockchainTests) run under the
    /// default dev schedule and carry their fork only in header shape. Engine
    /// payloads and replays of locally accepted blocks must use the configured
    /// schedule, so inference is opt-in.
    infer_legacy_hardfork: bool = false,
    /// When true, a legacy transaction with an invalid signature v value is
    /// decoded with `decodeLegacyEnvelopeAllowInvalidSignature` and its sender
    /// is set to `block.header.beneficiary`. MUST remain false on Engine API
    /// payloads, external genesis imports, and any path where `strict == true`
    /// or `validate_tx_chain_id == true`.
    allow_impersonated_legacy: bool = false,
    /// When true, an EIP-7002 or EIP-7251 predeploy without code returns
    /// `error.SystemContractMissingCode`. False keeps the no-op that dev
    /// chains without the predeploys rely on.
    require_system_contracts: bool = false,
    /// When true, a state/receipt/bloom commitment mismatch reverts the block
    /// before indexing or committing so a partial import never exposes a
    /// mismatching block as head.
    reject_commitment_mismatch: bool = false,
};

fn materializeImportedChain(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    blockchain: *blockchain_mod.Blockchain,
    receipt_index: *receipt_index_mod.ReceiptIndex,
    log_index: *log_index_mod.LogIndex,
    chain_id: u64,
    hardfork_config: hardfork_schedule.ChainConfig,
    blob_base_fee: u256,
    head_block_number: u64,
) !ImportedMaterializationStats {
    var stats = ImportedMaterializationStats{};
    var block_number: u64 = 1;
    while (block_number <= head_block_number) : (block_number += 1) {
        const block = (try blockchain.getBlockByNumber(block_number)) orelse return error.ImportedBlockMissing;
        const block_stats = materializeImportedBlock(
            allocator,
            sm,
            blockchain,
            receipt_index,
            log_index,
            chain_id,
            hardfork_config,
            blob_base_fee,
            block,
            .{ .infer_legacy_hardfork = true, .reject_commitment_mismatch = true },
        ) catch |err| {
            if (err == error.OutOfMemory) return err;
            if (err == error.ChainRlpStateRootMismatch) stats.state_root_mismatch_count += 1;
            stats.stopped_block_number = block_number;
            log.warn(.startup, "chain_rlp_materialization_stopped block_number={} error={s}", .{
                block_number,
                @errorName(err),
            });
            break;
        };

        stats.block_count += 1;
        stats.transaction_count += block_stats.transaction_count;
        stats.receipt_count += block_stats.receipt_count;
        stats.log_count += block_stats.log_count;
        if (block_stats.receipt_root_mismatch) stats.receipt_root_mismatch_count += 1;
        if (block_stats.logs_bloom_mismatch) stats.logs_bloom_mismatch_count += 1;
        if (block_stats.state_root_mismatch) stats.state_root_mismatch_count += 1;
    }
    return stats;
}

fn materializeImportedBlock(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    blockchain: *blockchain_mod.Blockchain,
    receipt_index: *receipt_index_mod.ReceiptIndex,
    log_index: *log_index_mod.LogIndex,
    chain_id: u64,
    hardfork_config: hardfork_schedule.ChainConfig,
    blob_base_fee: u256,
    block: primitives.Block.Block,
    options: MaterializeImportedBlockOptions,
) !ImportedBlockStats {
    try sm.checkpoint();
    var committed = false;
    errdefer if (!committed) sm.revert();

    var adapter = host_adapter.HostAdapter{ .state = sm };
    var recent_hashes: [256][32]u8 = undefined;
    var block_ctx = try importedBlockContext(blockchain, chain_id, blob_base_fee, block, &recent_hashes);
    const hardfork = if (options.infer_legacy_hardfork)
        inferImportedBlockHardfork(hardfork_config, block_ctx, block)
    else
        tx_processor.resolveHardforkWithConfig(hardfork_config, block_ctx);
    if (block.header.excess_blob_gas) |excess| {
        const params = blob_fee.blobParamsForFork(hardfork_config, hardfork, block.header.timestamp);
        if (params.base_fee_update_fraction != 0) {
            block_ctx.blob_base_fee = blob_fee.calcBlobBaseFee(excess, params.base_fee_update_fraction);
        }
    }
    // EIP-7934: every imported or engine-supplied block passes through here
    // with its resolved fork, so the Osaka size cap is enforced once.
    try chain_import.validateBlockRlpSize(block.size, hardfork);

    // EIP-161: snapshot pre-existing empty accounts before any block-level
    // mutation so system calls, transactions, withdrawals, and rewards that
    // touch new empty accounts are all pruned against the parent state.
    var preserved_empty_accounts = if (hardfork.isAtLeast(.SPURIOUS_DRAGON))
        try block_builder.collectEmptyAccounts(allocator, sm)
    else
        null;
    defer if (preserved_empty_accounts) |*accounts| accounts.deinit();

    var touched_accounts = std.AutoHashMap(primitives.Address, void).init(allocator);
    defer touched_accounts.deinit();

    if (hardfork.isAtLeast(.CANCUN)) {
        if (block.header.parent_beacon_block_root) |root| {
            try block_builder.applyBeaconRootsSystemCallWithContext(
                allocator,
                sm,
                adapter.hostInterface(),
                block_ctx,
                hardfork,
                root,
            );
        }
    }
    if (hardfork.isAtLeast(.PRAGUE)) {
        try block_builder.applyHistoricalBlockHashSystemCallWithContext(
            allocator,
            sm,
            adapter.hostInterface(),
            block_ctx,
            hardfork,
            block.header.parent_hash,
        );
    }

    var receipts = std.ArrayList(primitives.Receipt.Receipt){};
    defer {
        for (receipts.items) |receipt| receipt.deinit(allocator);
        receipts.deinit(allocator);
    }

    var cumulative_gas_used: u64 = 0;
    var next_log_index: u32 = 0;
    for (block.body.transactions, 0..) |transaction_data, tx_index| {
        var impersonated_legacy = false;
        var decoded = tx_encoding.decodeEnvelope(allocator, transaction_data.raw) catch |err| switch (err) {
            error.InvalidSignatureV => blk: {
                if (!options.allow_impersonated_legacy) return err;
                const legacy = tx_encoding.decodeLegacyEnvelopeAllowInvalidSignature(transaction_data.raw) catch return err;
                impersonated_legacy = true;
                break :blk tx_encoding.DecodedEnvelope{ .legacy = legacy };
            },
            else => return err,
        };
        defer decoded.deinit(allocator);
        if (options.validate_tx_chain_id and !impersonated_legacy) {
            if (tx_encoding.envelopeChainId(decoded)) |tx_chain_id| {
                if (tx_chain_id != chain_id) return error.InvalidTransactionChainId;
            }
        }
        const tx = tx_encoding.envelopeToLegacyLikeTx(decoded);
        const sender = if (impersonated_legacy)
            block.header.beneficiary
        else
            try tx_encoding.recoverEnvelopeSenderForFork(allocator, decoded, hardfork);
        const access_list = try processorAccessListFromEnvelope(allocator, tx_encoding.envelopeAccessList(decoded));
        defer allocator.free(access_list);
        const blob_versioned_hashes = try tx_encoding.envelopeBlobVersionedHashBytes(allocator, decoded);
        defer if (blob_versioned_hashes) |hashes| allocator.free(hashes);
        const canonical_tx_hash = tx_encoding.transactionHash(transaction_data.raw);
        const remaining_block_gas = std.math.sub(u64, block.header.gas_limit, cumulative_gas_used) catch return error.BlockGasLimitExceeded;

        var receipt = try tx_processor.processTransactionWithOptions(
            allocator,
            sm,
            adapter.hostInterface(),
            sender,
            tx,
            block_ctx,
            .{
                .access_list = access_list,
                .receipt_type = tx_encoding.envelopeReceiptType(decoded),
                .max_fee_per_gas = tx_encoding.envelopeMaxFeePerGas(decoded),
                .max_priority_fee_per_gas = tx_encoding.envelopeMaxPriorityFeePerGas(decoded),
                .authorization_list = tx_encoding.envelopeAuthorizationList(decoded),
                .blob_gas_used = tx_encoding.envelopeBlobGasUsed(decoded),
                .blob_gas_price = if (tx_encoding.envelopeBlobGasUsed(decoded) != null) block_ctx.blob_base_fee else null,
                .max_fee_per_blob_gas = tx_encoding.envelopeMaxFeePerBlobGas(decoded),
                .blob_versioned_hashes = blob_versioned_hashes,
                .hardfork_override = hardfork,
                .remaining_block_gas = remaining_block_gas,
                .canonical_tx_hash = canonical_tx_hash,
                .touched_accounts = if (preserved_empty_accounts != null) &touched_accounts else null,
            },
        );
        var receipt_owned = true;
        errdefer if (receipt_owned) receipt.deinit(allocator);

        if (hardfork.isBefore(.BYZANTIUM)) {
            if (preserved_empty_accounts) |*accounts| {
                try block_builder.pruneEmptyAccounts(allocator, sm, accounts, &touched_accounts);
            }
            receipt.root = try block_builder.computeStateRootForFork(allocator, sm, blockBuilderHardfork(hardfork));
            receipt.status = null;
        }

        const gas_used = std.math.cast(u64, receipt.gas_used) orelse return error.GasOverflow;
        cumulative_gas_used = std.math.add(u64, cumulative_gas_used, gas_used) catch return error.GasOverflow;
        receipt.transaction_hash = canonical_tx_hash;
        receipt.transaction_index = @intCast(tx_index);
        receipt.block_hash = block.hash;
        receipt.block_number = block.header.number;
        receipt.cumulative_gas_used = @as(u256, cumulative_gas_used);

        const mutable_logs = @constCast(receipt.logs);
        for (mutable_logs) |*event_log| {
            event_log.block_number = block.header.number;
            event_log.transaction_hash = receipt.transaction_hash;
            event_log.transaction_index = receipt.transaction_index;
            event_log.log_index = next_log_index;
            next_log_index += 1;
        }

        try receipts.append(allocator, receipt);
        receipt_owned = false;
    }

    // EIP-4895 withdrawals and pre-Merge rewards settle before the Prague
    // EIP-7002/7251 dequeue system calls, matching execution-specs ordering.
    if (block.body.withdrawals) |withdrawals| {
        try block_builder.applyWithdrawals(sm, withdrawals);
    }
    if (hardfork.isBefore(.MERGE)) {
        try block_builder.applyBlockRewards(
            sm,
            block.header.beneficiary,
            block.body.ommers,
            block.header.number,
            blockBuilderHardfork(hardfork),
        );
    }

    // EIP-7685: Prague+ blocks commit to deposit logs (EIP-6110) plus the
    // EIP-7002/7251 system-call outputs. The system calls mutate state, so they
    // run on every replay; strict imports also compare the commitment.
    var computed_requests_hash: ?[32]u8 = null;
    if (hardfork.isAtLeast(.PRAGUE)) {
        const deposit_addr = if (@hasField(hardfork_schedule.ChainConfig, "deposit_contract_address"))
            hardfork_config.deposit_contract_address orelse block_builder.DEPOSIT_CONTRACT_ADDRESS
        else
            block_builder.DEPOSIT_CONTRACT_ADDRESS;
        const execution_requests = try block_builder.collectBlockExecutionRequestsWithOptions(
            allocator,
            sm,
            receipts.items,
            blockBuilderHardfork(hardfork),
            block_ctx,
            .{
                .deposit_contract_address = deposit_addr,
                .require_system_contracts = options.require_system_contracts,
            },
        );
        defer block_builder.freeExecutionRequests(allocator, execution_requests);
        computed_requests_hash = try block_builder.computeRequestsHashFromRawRequests(allocator, execution_requests);
    }

    // EIP-161 pruning runs last so every block-level touch is covered.
    if (preserved_empty_accounts) |*accounts| {
        try block_builder.pruneEmptyAccounts(allocator, sm, accounts, &touched_accounts);
    }

    var stats = ImportedBlockStats{
        .transaction_count = block.body.transactions.len,
        .receipt_count = receipts.items.len,
        .log_count = next_log_index,
    };

    const receipts_root = try block_builder.computeReceiptsRoot(allocator, receipts.items);
    stats.receipt_root_mismatch = !std.mem.eql(u8, &receipts_root, &block.header.receipts_root);
    const logs_bloom = block_builder.aggregateLogsBloom(receipts.items);
    stats.logs_bloom_mismatch = !std.mem.eql(u8, &logs_bloom, &block.header.logs_bloom);
    const state_root = try block_builder.computeStateRootForFork(allocator, sm, blockBuilderHardfork(hardfork));
    stats.state_root_mismatch = !std.mem.eql(u8, &state_root, &block.header.state_root);

    if (options.strict) {
        const parent = blockchain.getBlockLocal(block.header.parent_hash) orelse return error.MissingParentBlock;
        _ = try block_builder.validateBlock(allocator, .{
            .header = &block.header,
            .parent_header = &parent.header,
            .fork = blockBuilderHardfork(hardfork),
            .hardfork_config = hardfork_config,
            .transaction_envelopes = block.body.transactions,
            .receipts = receipts.items,
            .withdrawals = block.body.withdrawals,
            .state_root = state_root,
            .requests_hash = options.requests_hash,
            .computed_requests_hash = computed_requests_hash,
        });
    }

    if (options.reject_commitment_mismatch) {
        if (stats.state_root_mismatch) return error.ChainRlpStateRootMismatch;
        if (stats.receipt_root_mismatch or stats.logs_bloom_mismatch) return error.ChainRlpCommitmentMismatch;
    }

    try receipt_index.putBlockReceipts(allocator, block.hash, receipts.items);
    errdefer receipt_index.removeBlockReceipts(allocator, block.hash);
    try log_index.appendBlockLogs(allocator, block.header.number, block.hash, receipts.items);

    sm.commit();
    committed = true;

    return stats;
}

fn importedBlockContext(
    blockchain: *blockchain_mod.Blockchain,
    chain_id: u64,
    blob_base_fee: u256,
    block: primitives.Block.Block,
    recent_hashes: *[256][32]u8,
) !guillotine_mini.BlockContext {
    return .{
        .chain_id = chain_id,
        .block_number = block.header.number,
        .block_timestamp = block.header.timestamp,
        .block_difficulty = block.header.difficulty,
        .block_prevrandao = std.mem.readInt(u256, &block.header.mix_hash, .big),
        .block_coinbase = block.header.beneficiary,
        .block_gas_limit = block.header.gas_limit,
        .block_base_fee = block.header.base_fee_per_gas orelse 0,
        // Callers with a resolved hardfork overwrite this from the header's
        // excess blob gas using the fork/BPO update fraction.
        .blob_base_fee = if (block.header.excess_blob_gas) |excess|
            blob_fee.calcBlobBaseFee(excess, hardfork_schedule.MAINNET_CANCUN_BLOB_CONFIG.base_fee_update_fraction)
        else
            blob_base_fee,
        .block_hashes = if (block.header.number == 0)
            recent_hashes[0..0]
        else
            try blockchain.last256BlockHashesLocal(block.header.parent_hash, recent_hashes),
    };
}

fn processorAccessListFromEnvelope(
    allocator: std.mem.Allocator,
    access_list: []const primitives.Transaction.AccessListItem,
) ![]primitives.AccessList.AccessListEntry {
    const entries = try allocator.alloc(primitives.AccessList.AccessListEntry, access_list.len);
    for (access_list, 0..) |entry, i| {
        entries[i] = .{
            .address = entry.address,
            .storage_keys = entry.storage_keys,
        };
    }
    return entries;
}

fn inferImportedBlockHardfork(
    hardfork_config: hardfork_schedule.ChainConfig,
    block_ctx: guillotine_mini.BlockContext,
    block: primitives.Block.Block,
) guillotine_mini.Hardfork {
    const scheduled = tx_processor.resolveHardforkWithConfig(hardfork_config, block_ctx);
    if (!isDefaultDevHardforkConfig(hardfork_config)) return scheduled;

    if (block.header.parent_beacon_block_root != null) return .CANCUN;
    if (block.header.blob_gas_used != null or block.header.excess_blob_gas != null) return .CANCUN;
    if (block.header.withdrawals_root != null) return .SHANGHAI;
    if (block.header.base_fee_per_gas != null) return .LONDON;

    var has_eip2930 = false;
    for (block.body.transactions) |transaction_data| {
        if (transaction_data.raw.len == 0) continue;
        switch (transaction_data.raw[0]) {
            0x04 => return .PRAGUE,
            0x03 => return .CANCUN,
            0x02 => return .LONDON,
            0x01 => has_eip2930 = true,
            else => {},
        }
    }
    if (has_eip2930) return .BERLIN;
    return .FRONTIER;
}

fn isDefaultDevHardforkConfig(config: hardfork_schedule.ChainConfig) bool {
    return config.homestead_block == DEFAULT_DEV_HARDFORK_CONFIG.homestead_block and
        config.dao_block == DEFAULT_DEV_HARDFORK_CONFIG.dao_block and
        config.tangerine_whistle_block == DEFAULT_DEV_HARDFORK_CONFIG.tangerine_whistle_block and
        config.spurious_dragon_block == DEFAULT_DEV_HARDFORK_CONFIG.spurious_dragon_block and
        config.byzantium_block == DEFAULT_DEV_HARDFORK_CONFIG.byzantium_block and
        config.constantinople_block == DEFAULT_DEV_HARDFORK_CONFIG.constantinople_block and
        config.petersburg_block == DEFAULT_DEV_HARDFORK_CONFIG.petersburg_block and
        config.istanbul_block == DEFAULT_DEV_HARDFORK_CONFIG.istanbul_block and
        config.muir_glacier_block == DEFAULT_DEV_HARDFORK_CONFIG.muir_glacier_block and
        config.berlin_block == DEFAULT_DEV_HARDFORK_CONFIG.berlin_block and
        config.london_block == DEFAULT_DEV_HARDFORK_CONFIG.london_block and
        config.arrow_glacier_block == DEFAULT_DEV_HARDFORK_CONFIG.arrow_glacier_block and
        config.gray_glacier_block == DEFAULT_DEV_HARDFORK_CONFIG.gray_glacier_block and
        config.merge_block == DEFAULT_DEV_HARDFORK_CONFIG.merge_block and
        config.shanghai_timestamp == DEFAULT_DEV_HARDFORK_CONFIG.shanghai_timestamp and
        config.cancun_timestamp == DEFAULT_DEV_HARDFORK_CONFIG.cancun_timestamp and
        config.prague_timestamp == DEFAULT_DEV_HARDFORK_CONFIG.prague_timestamp and
        config.osaka_timestamp == DEFAULT_DEV_HARDFORK_CONFIG.osaka_timestamp;
}

fn blockBuilderHardfork(hardfork: guillotine_mini.Hardfork) block_builder.Hardfork {
    return block_builder.hardforkFromEvm(hardfork);
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

/// SHA-256 of the empty byte string: the EIP-7685 commitment to no requests.
fn emptyRequestsHash() [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&.{}, &out, .{});
    return out;
}

fn u256ToHash(value: u256) [32]u8 {
    var out: [32]u8 = undefined;
    std.mem.writeInt(u256, &out, value, .big);
    return out;
}

fn initBlockchainWithGenesis(
    allocator: std.mem.Allocator,
    chain_id: u64,
    state_root: [32]u8,
    coinbase: primitives.Address,
    gas_limit: u64,
    genesis_header: genesis_alloc.HeaderConfig,
    hardfork_config: hardfork_schedule.ChainConfig,
    owned_block_bodies: *std.ArrayList(OwnedBlockBody),
) !blockchain_mod.Blockchain {
    _ = chain_id;
    var blockchain = try blockchain_mod.Blockchain.init(allocator, null);
    errdefer blockchain.deinit();

    const genesis_fork = hardfork_schedule.resolveHardforkWithConfig(hardfork_config, 0, genesis_header.timestamp);
    const genesis_base_fee = genesis_header.base_fee_per_gas orelse if (genesis_fork.isAtLeast(.LONDON))
        DEFAULT_BASE_FEE
    else
        null;
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
        .base_fee_per_gas = genesis_base_fee,
        .withdrawals_root = genesis_header.withdrawals_root orelse if (genesis_fork.isAtLeast(.SHANGHAI))
            primitives.BlockHeader.EMPTY_WITHDRAWALS_ROOT
        else
            null,
        .blob_gas_used = genesis_header.blob_gas_used orelse if (genesis_fork.isAtLeast(.CANCUN)) 0 else null,
        .excess_blob_gas = genesis_header.excess_blob_gas orelse if (genesis_fork.isAtLeast(.CANCUN)) 0 else null,
        .parent_beacon_block_root = genesis_header.parent_beacon_block_root orelse if (genesis_fork.isAtLeast(.CANCUN))
            primitives.Hash.ZERO
        else
            null,
    };
    var body = primitives.BlockBody.init();
    // EIP-4895: a Shanghai+ genesis carries an empty withdrawals list so body
    // RPCs and RLP encoding match its EMPTY_WITHDRAWALS_ROOT header field.
    const empty_withdrawals: []const primitives.BlockBody.Withdrawal = &.{};
    if (header.withdrawals_root != null) body.withdrawals = empty_withdrawals;
    var genesis_block = try primitives.Block.from(&header, &body, allocator);
    const encoded = try primitives.Block.rlpEncode(&genesis_block, allocator);
    defer allocator.free(encoded);
    genesis_block.size = @intCast(encoded.len);

    // EIP-7685: a Prague+ genesis commits to an empty requests list unless
    // the genesis JSON explicitly overrides `requestsHash`.
    const genesis_requests_hash: ?[32]u8 = genesis_header.requests_hash orelse
        if (genesis_fork.isAtLeast(.PRAGUE)) emptyRequestsHash() else null;
    if (genesis_requests_hash) |requests_hash| {
        genesis_block.hash = try block_builder.computeHeaderHashWithRequestsHash(allocator, &header, requests_hash);
    }

    try blockchain.putBlock(genesis_block);
    try blockchain.setCanonicalHead(genesis_block.hash);
    if (genesis_requests_hash != null) {
        try owned_block_bodies.append(allocator, .{
            .block_hash = genesis_block.hash,
            .requests_hash = genesis_requests_hash,
        });
    }
    return blockchain;
}

test "Hive rpc-compat chain materializes canonical state roots" {
    const allocator = std.testing.allocator;
    const chain_id = 3_503_995_874_084_926;
    const hive_hardfork_config = hardfork_schedule.ChainConfig{
        .homestead_block = 0,
        .dao_block = 0,
        .tangerine_whistle_block = 3,
        .spurious_dragon_block = 6,
        .byzantium_block = 9,
        .constantinople_block = 12,
        .petersburg_block = 15,
        .istanbul_block = 18,
        .muir_glacier_block = 21,
        .berlin_block = 24,
        .london_block = 27,
        .arrow_glacier_block = 30,
        .gray_glacier_block = 33,
        .merge_block = 36,
        .shanghai_timestamp = 390,
        .cancun_timestamp = 420,
        .prague_timestamp = 450,
        .osaka_timestamp = std.math.maxInt(u64),
    };

    var state = try state_manager.StateManager.init(allocator, null);
    defer state.deinit();

    var loaded = try genesis_alloc.loadGenesisFile(allocator, &state, "lib/execution-apis/tests/genesis.json");
    defer loaded.deinit(allocator);

    const genesis_state_root = try block_builder.computeStateRoot(allocator, &state);
    var owned_block_bodies = std.ArrayList(OwnedBlockBody){};
    defer {
        clearOwnedBlockBodyList(allocator, &owned_block_bodies);
        owned_block_bodies.deinit(allocator);
    }
    var blockchain = try initBlockchainWithGenesis(
        allocator,
        chain_id,
        genesis_state_root,
        genesis.DEV_ACCOUNTS[0].address,
        loaded.header.gas_limit orelse DEFAULT_BLOCK_GAS_LIMIT,
        loaded.header,
        hive_hardfork_config,
        &owned_block_bodies,
    );
    defer blockchain.deinit();
    const import_stats = try chain_import.importChainFile(
        allocator,
        &blockchain,
        &owned_block_bodies,
        "lib/execution-apis/tests/chain.rlp",
    );

    var receipt_index = receipt_index_mod.ReceiptIndex.init(allocator);
    defer receipt_index.deinit(allocator);
    var log_index = log_index_mod.LogIndex.init();
    defer log_index.deinit(allocator);

    var block_number: u64 = 1;
    while (block_number <= import_stats.head_block_number) : (block_number += 1) {
        const block = (try blockchain.getBlockByNumber(block_number)) orelse return error.ImportedBlockMissing;
        const block_stats = try materializeImportedBlock(
            allocator,
            &state,
            &blockchain,
            &receipt_index,
            &log_index,
            chain_id,
            hive_hardfork_config,
            1,
            block,
            .{},
        );

        if (block_stats.state_root_mismatch) {
            var recent_hashes: [256][32]u8 = undefined;
            const block_ctx = try importedBlockContext(&blockchain, chain_id, 1, block, &recent_hashes);
            const hardfork = inferImportedBlockHardfork(hive_hardfork_config, block_ctx, block);
            const state_root = try block_builder.computeStateRootForFork(allocator, &state, blockBuilderHardfork(hardfork));
            const got_hex = std.fmt.bytesToHex(state_root, .lower);
            const want_hex = std.fmt.bytesToHex(block.header.state_root, .lower);
            std.debug.print(
                "state root mismatch block={} hardfork={s} txs={} ommers={} receipt_mismatch={} logs_mismatch={} got=0x{s} want=0x{s}\n",
                .{
                    block_number,
                    @tagName(hardfork),
                    block.body.transactions.len,
                    block.body.ommers.len,
                    block_stats.receipt_root_mismatch,
                    block_stats.logs_bloom_mismatch,
                    &got_hex,
                    &want_hex,
                },
            );
            try std.testing.expect(false);
        }
        try std.testing.expect(!block_stats.receipt_root_mismatch);
        try std.testing.expect(!block_stats.logs_bloom_mismatch);
    }
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

    const owned_checkpoint_dir = if (config.checkpoint_dir) |dir| try allocator.dupe(u8, dir) else null;
    errdefer if (owned_checkpoint_dir) |dir| allocator.free(dir);

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
        .checkpoint_dir = owned_checkpoint_dir,
        .persisted_checkpoint = if (selected.source == .persisted) selected.checkpoint_hash else null,
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
            .follow = value.follow,
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

/// Build an `eth_getProof`-shaped account payload from scalar reads, for fork
/// upstreams that do not serve `eth_getProof`. The storage root is unknown
/// without a proof, so `storageHash` is the zero hash.
fn forkProofFromScalarReads(
    allocator: std.mem.Allocator,
    resolver: ForkRpcResolver,
    url: []const u8,
    request: anytype,
) ![]u8 {
    // The backend encodes proof params as [address, slots, blockTag].
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, request.params_json, .{});
    defer parsed.deinit();
    if (parsed.value != .array or parsed.value.array.items.len != 3) return error.InvalidForkRequest;
    const address = switch (parsed.value.array.items[0]) {
        .string => |text| text,
        else => return error.InvalidForkRequest,
    };
    const block_tag = switch (parsed.value.array.items[2]) {
        .string => |text| text,
        else => return error.InvalidForkRequest,
    };

    const account_params = try std.fmt.allocPrint(allocator, "[\"{s}\",\"{s}\"]", .{ address, block_tag });
    defer allocator.free(account_params);

    const balance = try forkScalarQuantity(u256, allocator, resolver, url, "eth_getBalance", account_params);
    const nonce = try forkScalarQuantity(u64, allocator, resolver, url, "eth_getTransactionCount", account_params);

    const code_payload = try resolver.resolve(resolver.context, allocator, .{
        .url = url,
        .method = "eth_getCode",
        .params_json = account_params,
    });
    defer allocator.free(code_payload);
    const code_hex = try forkScalarString(code_payload);
    const code = primitives.Hex.hexToBytes(allocator, code_hex) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidUpstreamRpcResponse,
    };
    defer allocator.free(code);
    var code_hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(code, &code_hash, .{});
    const code_hash_hex = std.fmt.bytesToHex(code_hash, .lower);

    if (request.kind != .storage_proof) {
        return std.fmt.allocPrint(
            allocator,
            "{{\"nonce\":\"0x{x}\",\"balance\":\"0x{x}\",\"codeHash\":\"0x{s}\",\"storageHash\":\"0x{x:0>64}\",\"storageProof\":[]}}",
            .{ nonce, balance, &code_hash_hex, @as(u256, 0) },
        );
    }

    const storage_params = try std.fmt.allocPrint(allocator, "[\"{s}\",\"0x{x}\",\"{s}\"]", .{ address, request.slot, block_tag });
    defer allocator.free(storage_params);
    const storage_value = try forkScalarQuantity(u256, allocator, resolver, url, "eth_getStorageAt", storage_params);

    return std.fmt.allocPrint(
        allocator,
        "{{\"nonce\":\"0x{x}\",\"balance\":\"0x{x}\",\"codeHash\":\"0x{s}\",\"storageHash\":\"0x{x:0>64}\",\"storageProof\":[{{\"key\":\"0x{x:0>64}\",\"value\":\"0x{x}\"}}]}}",
        .{ nonce, balance, &code_hash_hex, @as(u256, 0), request.slot, storage_value },
    );
}

/// Call a scalar read method and decode its hex result. Accepts zero-padded
/// values because `eth_getStorageAt` returns 32-byte data, not a quantity.
fn forkScalarQuantity(
    comptime T: type,
    allocator: std.mem.Allocator,
    resolver: ForkRpcResolver,
    url: []const u8,
    method: []const u8,
    params_json: []const u8,
) !T {
    const payload = try resolver.resolve(resolver.context, allocator, .{
        .url = url,
        .method = method,
        .params_json = params_json,
    });
    defer allocator.free(payload);
    const text = try forkScalarString(payload);
    if (text.len < 2 or text[0] != '0' or text[1] != 'x') return error.InvalidUpstreamRpcResponse;
    if (text.len == 2) return 0;
    return std.fmt.parseInt(T, text[2..], 16) catch error.InvalidUpstreamRpcResponse;
}

/// Borrow the contents of a JSON string payload such as `"0x2a"`. Hex results
/// never contain escapes, so no unescaping is needed.
fn forkScalarString(payload: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    if (trimmed.len < 2 or trimmed[0] != '"' or trimmed[trimmed.len - 1] != '"') return error.InvalidUpstreamRpcResponse;
    const text = trimmed[1 .. trimmed.len - 1];
    if (std.mem.indexOfAny(u8, text, "\"\\") != null) return error.InvalidUpstreamRpcResponse;
    return text;
}

fn resolveForkRpcViaHttp(
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    request: ForkRpcRequest,
) ![]u8 {
    if (browser) return error.ModeUnsupported;
    _ = context;

    const request_body = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\",\"params\":{s}}}",
        .{ request.method, request.params_json },
    );
    defer allocator.free(request_body);

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const uri = std.Uri.parse(request.url) catch return error.InvalidForkUrl;
    var http_request = client.request(.POST, uri, .{
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .extra_headers = &[_]std.http.Header{
            .{
                .name = "content-type",
                .value = "application/json",
            },
        },
    }) catch |err| {
        if (err == error.ConnectionTimedOut) return error.UpstreamTimeout;
        return err;
    };
    defer {
        http_request.connection.?.closing = true;
        http_request.deinit();
    }

    var deadline: beacon_api.UpstreamDeadline = undefined;
    const connection = http_request.connection.?;
    try deadline.start(connection);
    defer deadline.stop();

    http_request.sendBodyComplete(request_body) catch |err| {
        try deadline.check(connection);
        return err;
    };
    var response = http_request.receiveHead(&.{}) catch |err| {
        try deadline.check(connection);
        return err;
    };
    if (response.head.status != .ok) {
        return error.UpstreamRpcFailed;
    }
    if (response.head.content_length) |content_length| {
        if (content_length > MAX_FORK_RPC_RESPONSE_BYTES) return error.UpstreamRpcResponseTooLarge;
    }

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try allocator.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try allocator.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UpstreamRpcFailed,
    };
    defer if (response.head.content_encoding != .identity) allocator.free(decompress_buffer);

    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    const response_body = reader.allocRemaining(allocator, .limited(MAX_FORK_RPC_RESPONSE_BYTES + 1)) catch |err| {
        switch (err) {
            error.ReadFailed, error.StreamTooLong => {},
            error.OutOfMemory => return error.OutOfMemory,
        }
        try deadline.check(connection);
        if (err == error.StreamTooLong) return error.UpstreamRpcResponseTooLarge;
        return err;
    };
    defer allocator.free(response_body);
    if (response_body.len > MAX_FORK_RPC_RESPONSE_BYTES) {
        return error.UpstreamRpcResponseTooLarge;
    }
    try deadline.check(connection);
    return light_proof.extractJsonRpcResult(allocator, response_body);
}

/// Collects an HTTP response body and fails the write once `limit` bytes
/// would be exceeded, so a hostile upstream cannot exhaust memory.
const BoundedResponseSink = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8),
    limit: usize,
    limit_exceeded: bool,
    writer: std.Io.Writer,

    fn init(allocator: std.mem.Allocator, limit: usize, buffer: []u8) BoundedResponseSink {
        return .{
            .allocator = allocator,
            .bytes = .{},
            .limit = limit,
            .limit_exceeded = false,
            .writer = .{ .vtable = &.{ .drain = drain }, .buffer = buffer },
        };
    }

    fn deinit(self: *BoundedResponseSink) void {
        self.bytes.deinit(self.allocator);
    }

    fn append(self: *BoundedResponseSink, bytes: []const u8) std.Io.Writer.Error!void {
        if (bytes.len > self.limit - self.bytes.items.len) {
            self.limit_exceeded = true;
            return error.WriteFailed;
        }
        self.bytes.appendSlice(self.allocator, bytes) catch return error.WriteFailed;
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *BoundedResponseSink = @alignCast(@fieldParentPtr("writer", w));
        try self.append(w.buffer[0..w.end]);
        w.end = 0;
        const slice = data[0 .. data.len - 1];
        const pattern = data[slice.len];
        var written: usize = 0;
        for (slice) |bytes| {
            try self.append(bytes);
            written += bytes.len;
        }
        for (0..splat) |_| {
            try self.append(pattern);
            written += pattern.len;
        }
        return written;
    }
};

fn stringifyJsonValue(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    try std.json.Stringify.value(value, .{}, &writer.writer);
    return writer.toOwnedSlice();
}

fn pruneCanonicalChainAboveStatic(blockchain: *blockchain_mod.Blockchain, head_number: u64, previous_max_number: u64) void {
    if (previous_max_number <= head_number) return;
    var number = head_number + 1;
    while (true) {
        _ = blockchain.block_store.canonical_chain.remove(number);
        if (number == previous_max_number) break;
        number += 1;
    }
}

test "light sync cancellation flag short-circuits startup sync before network work" {
    var rt = try NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    // Newly initialized runtimes must not have cancellation latched on.
    try std.testing.expect(!rt.light_sync_stop_requested.load(.seq_cst));

    // Requesting a stop must cause the detached startup-sync routine to bail out
    // immediately with error.Canceled, before performing any blocking network I/O,
    // so deinit can join the light-sync thread promptly.
    rt.light_sync_stop_requested.store(true, .seq_cst);
    try std.testing.expectError(error.Canceled, rt.runLightStartupSyncDetached());
}
