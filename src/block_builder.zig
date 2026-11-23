const std = @import("std");
const primitives = @import("primitives");
const state_manager = @import("state-manager");
const guillotine_mini = @import("guillotine_mini");
const tx_processor = @import("tx_processor.zig");
const tx_encoding = @import("transaction_encoding.zig");
const dev_runtime = @import("rpc/dev_runtime.zig");
const hardfork_schedule = @import("hardfork_schedule.zig");
const blob_fee = @import("blob_fee.zig");
const host_adapter = @import("host_adapter.zig");
const system_contracts = @import("system_contracts.zig");

const INITIAL_BASE_FEE_PER_GAS: u256 = 1_000_000_000;
const BASE_FEE_CHANGE_DENOMINATOR: u256 = 8;
const GAS_LIMIT_ELASTICITY_MULTIPLIER: u64 = 2;
const WEI_PER_GWEI: u256 = 1_000_000_000;
const WEI_PER_ETHER: u256 = 1_000_000_000_000_000_000;
const SYSTEM_CALL_GAS_LIMIT: u64 = 30_000_000;
const DEPOSIT_REQUEST_TYPE: u8 = 0x00;
const WITHDRAWAL_REQUEST_TYPE: u8 = 0x01;
const CONSOLIDATION_REQUEST_TYPE: u8 = 0x02;
/// Lowest block gas limit a header may carry (Yellow Paper eq. 47).
const MIN_GAS_LIMIT: u64 = 5000;
const GAS_LIMIT_ADJUSTMENT_FACTOR: u64 = 1024;

/// EIP-6110 size of one deposit request: pubkey (48) || withdrawal
/// credentials (32) || amount (8) || signature (96) || index (8).
pub const DEPOSIT_REQUEST_SIZE: usize = 192;
/// EIP-6110 size of the ABI-encoded `DepositEvent` log data.
pub const DEPOSIT_EVENT_DATA_SIZE: usize = 576;

/// EIP-7934 block size bound shared with the consensus gossip limit.
pub const MAX_BLOCK_SIZE: usize = 10_485_760;
/// EIP-7934 allowance reserved for the beacon block that wraps the payload.
pub const BLOCK_SIZE_SAFETY_MARGIN: usize = 2_097_152;
/// EIP-7934 maximum RLP-encoded execution block size, enforced from Osaka.
pub const MAX_RLP_BLOCK_SIZE: usize = MAX_BLOCK_SIZE - BLOCK_SIZE_SAFETY_MARGIN;
/// EIP-7935 recommended default block gas limit for Osaka networks. The limit
/// is client configuration, not consensus: nothing here applies it implicitly.
pub const OSAKA_DEFAULT_BLOCK_GAS_LIMIT: u64 = 60_000_000;

/// Upper bound of an RLP-encoded post-Prague header: 21 fields, a 32-byte
/// `extraData`, and every integer at its widest encoding.
const MAX_HEADER_RLP_SIZE: usize = 742;

pub const BEACON_ROOTS_ADDRESS = system_contracts.BEACON_ROOTS_ADDRESS;
pub const HISTORY_STORAGE_ADDRESS = system_contracts.HISTORY_STORAGE_ADDRESS;
pub const WITHDRAWAL_REQUESTS_ADDRESS = system_contracts.WITHDRAWAL_REQUESTS_ADDRESS;
pub const CONSOLIDATION_REQUESTS_ADDRESS = system_contracts.CONSOLIDATION_REQUESTS_ADDRESS;
pub const SYSTEM_ADDRESS = system_contracts.SYSTEM_ADDRESS;

/// EIP-6110 mainnet deposit contract, 0x00000000219ab540356cBB839Cbe05303d7705Fa.
pub const DEPOSIT_CONTRACT_ADDRESS = primitives.Address{ .bytes = .{
    0x00, 0x00, 0x00, 0x00, 0x21, 0x9a, 0xb5, 0x40, 0x35, 0x6c,
    0xbb, 0x83, 0x9c, 0xbe, 0x05, 0x30, 0x3d, 0x77, 0x05, 0xfa,
} };

/// keccak256("DepositEvent(bytes,bytes,bytes,bytes,bytes)"), topic 0 of the
/// deposit contract's only event (EIP-6110 `DEPOSIT_EVENT_SIGNATURE_HASH`).
pub const DEPOSIT_EVENT_TOPIC: [32]u8 = .{
    0x64, 0x9b, 0xbc, 0x62, 0xd0, 0xe3, 0x13, 0x42, 0xaf, 0xea, 0x4e, 0x5c, 0xd8, 0x2d, 0x40, 0x49,
    0xe7, 0xe1, 0xee, 0x91, 0x2f, 0xc0, 0x88, 0x9a, 0xa7, 0x90, 0x80, 0x3b, 0xe3, 0x90, 0x38, 0xc5,
};

pub const Hardfork = enum(u8) {
    frontier,
    homestead,
    /// EIP-161 state clearing activates here, not at Byzantium.
    spurious_dragon,
    byzantium,
    constantinople,
    istanbul,
    berlin,
    london,
    paris,
    shanghai,
    cancun,
    prague,
    osaka,
};

pub const RequestsByType = struct {
    deposits: []const u8 = &.{},
    withdrawals: []const u8 = &.{},
    consolidations: []const u8 = &.{},
};

/// Request payloads produced by executing a Prague block. A null field means
/// its source produced nothing: no deposit log, or no code at the predeploy.
pub const PragueSystemRequests = struct {
    /// EIP-6110 deposits extracted from receipt logs.
    deposits: ?[]u8 = null,
    withdrawals: ?[]u8 = null,
    consolidations: ?[]u8 = null,

    pub fn deinit(self: *PragueSystemRequests, allocator: std.mem.Allocator) void {
        if (self.deposits) |bytes| allocator.free(bytes);
        if (self.withdrawals) |bytes| allocator.free(bytes);
        if (self.consolidations) |bytes| allocator.free(bytes);
        self.* = .{};
    }
};

/// Request payloads of a Prague block: `PragueSystemRequests` under the name
/// the shared `collectPragueRequestsWithOptions` contract uses.
pub const PragueRequests = PragueSystemRequests;

pub const PragueRequestsOptions = struct {
    /// EIP-6110 deposit contract whose `DepositEvent` logs become deposits.
    deposit_contract_address: primitives.Address = DEPOSIT_CONTRACT_ADDRESS,
    /// True makes an EIP-7002 or EIP-7251 predeploy without code an error
    /// (`error.SystemContractMissingCode`), as both EIPs require. False keeps
    /// the no-op that chains without the predeploys (dev chains) rely on.
    require_system_contracts: bool = false,
};

pub const BuildBlockOptions = struct {
    fork: Hardfork = .paris,
    hardfork_config: ?hardfork_schedule.ChainConfig = null,
    withdrawals: ?[]const primitives.BlockBody.Withdrawal = null,
    parent_beacon_block_root: ?[32]u8 = null,
    parent_hash: ?[32]u8 = null,
    requests: RequestsByType = .{},
    state_root: ?[32]u8 = null,
    dev_runtime: ?*dev_runtime.DevRuntime = null,
    skip_invalid_transactions: bool = false,
    /// EIP-7934: size of each transaction as encoded in the block body's
    /// transaction list, parallel to the `transactions` argument. Callers that
    /// hold the raw envelopes pass exact sizes; when null the builder derives
    /// the sizes from the execution transactions (`executionTxRlpSize`).
    transaction_rlp_sizes: ?[]const usize = null,
    /// EIP-7934: exact RLP size of the block header (`headerRlpSize`), when
    /// the caller already knows the header. Null uses the conservative
    /// `MAX_HEADER_RLP_SIZE` bound, which suits candidate selection but can
    /// reject a supplied block within about 150 bytes of the cap.
    header_rlp_size: ?usize = null,
    /// EIP-6110 deposit contract whose `DepositEvent` logs become deposit
    /// requests. Chains other than mainnet deploy it at their own address.
    /// Null falls back to `hardfork_config.deposit_contract_address`, then
    /// to mainnet's `DEPOSIT_CONTRACT_ADDRESS`.
    deposit_contract_address: ?primitives.Address = null,
    /// Prague+: reject the block with `error.SystemContractMissingCode` when
    /// the EIP-7002 or EIP-7251 predeploy has no code. Replay of a real
    /// chain sets this; dev chains without the predeploys leave it false.
    require_system_contracts: bool = false,

    /// The deposit contract this build reads EIP-6110 logs from.
    pub fn effectiveDepositContractAddress(self: BuildBlockOptions) primitives.Address {
        if (self.deposit_contract_address) |address| return address;
        if (self.hardfork_config) |config| {
            if (config.deposit_contract_address) |address| return address;
        }
        return DEPOSIT_CONTRACT_ADDRESS;
    }
};

pub const BlockCommitments = struct {
    transactions_root: [32]u8,
    receipts_root: [32]u8,
    withdrawals_root: ?[32]u8,
    state_root: ?[32]u8,
    logs_bloom: [256]u8,
    blob_gas_used: u64,
    excess_blob_gas: ?u64,
    requests_hash: ?[32]u8,
};

pub const BlockResult = struct {
    receipts: []primitives.Receipt.Receipt,
    included_tx_indexes: []usize = &.{},
    total_gas_used: u64,
    block_number: u64,
    transactions_root: [32]u8,
    receipts_root: [32]u8,
    withdrawals_root: ?[32]u8,
    state_root: [32]u8,
    logs_bloom: [256]u8,
    blob_gas_used: u64,
    requests_hash: ?[32]u8,
    /// Upper bound of the RLP-encoded execution block built from the included
    /// transactions (EIP-7934 accounting). Never below the encoded size.
    rlp_size_upper_bound: usize = 0,
    /// EIP-7685 requests produced by the block, in ascending type order. Each
    /// element is `[type_byte || payload]`; empty payloads are omitted. Owned.
    execution_requests: [][]u8 = &.{},
    /// Prague+: SHA-256 commitment over `execution_requests` (EIP-6110
    /// deposit logs, EIP-7002 withdrawals, EIP-7251 consolidations).
    computed_requests_hash: ?[32]u8 = null,

    pub fn deinit(self: *BlockResult, allocator: std.mem.Allocator) void {
        for (self.receipts) |receipt| {
            receipt.deinit(allocator);
        }
        allocator.free(self.receipts);
        allocator.free(self.included_tx_indexes);
        freeExecutionRequests(allocator, self.execution_requests);
        self.execution_requests = &.{};
    }
};

pub const BlockValidationInput = struct {
    header: *const primitives.BlockHeader.BlockHeader,
    parent_header: *const primitives.BlockHeader.BlockHeader,
    fork: Hardfork = .paris,
    /// Source of EIP-7892 blob parameters. Null uses `MAINNET_CHAIN_CONFIG`.
    hardfork_config: ?hardfork_schedule.ChainConfig = null,
    execution_transactions: []const tx_processor.ExecutionTx = &.{},
    transaction_envelopes: ?[]const primitives.BlockBody.TransactionData = null,
    receipts: []const primitives.Receipt.Receipt = &.{},
    withdrawals: ?[]const primitives.BlockBody.Withdrawal = null,
    state_root: ?[32]u8 = null,
    /// The requests hash the block commits to (the header's claim).
    requests_hash: ?[32]u8 = null,
    /// The requests hash recomputed from execution. On Prague+ a non-null
    /// value must equal `requests_hash`, else `error.InvalidRequestsHash`.
    computed_requests_hash: ?[32]u8 = null,
    /// Hash of `parent_header`. When set, `header.parent_hash` must equal it.
    parent_hash: ?[32]u8 = null,
    /// keccak256 of the RLP-encoded ommers list of the block body. When set,
    /// `header.ommers_hash` must equal it.
    ommers_hash: ?[32]u8 = null,
};

pub fn buildBlock(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    host_iface: guillotine_mini.HostInterface,
    transactions: []const tx_processor.ExecutionTx,
    block_ctx: guillotine_mini.BlockContext,
) !BlockResult {
    return buildBlockWithOptions(allocator, sm, host_iface, transactions, block_ctx, .{});
}

pub fn buildBlockWithOptions(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    host_iface: guillotine_mini.HostInterface,
    transactions: []const tx_processor.ExecutionTx,
    block_ctx: guillotine_mini.BlockContext,
    options: BuildBlockOptions,
) !BlockResult {
    const effective_block_ctx = blockContextWithEnvironmentOverrides(options.dev_runtime, block_ctx);
    const effective_fork = effectiveBlockBuilderFork(options, effective_block_ctx);

    const execution_fork = if (options.hardfork_config) |config|
        tx_processor.resolveHardforkWithConfig(config, effective_block_ctx)
    else
        tx_processor.resolveHardfork(effective_block_ctx);
    // Osaka block rules apply when either the builder fork or the fork that
    // executes the transactions is Osaka, so a caller that sets only one of
    // `fork` and the schedule cannot build a block Osaka rejects.
    const osaka_rules = atLeast(effective_fork, .osaka) or execution_fork.isAtLeast(.OSAKA);

    if (options.transaction_rlp_sizes) |sizes| {
        if (sizes.len != transactions.len) return error.TransactionSizeCountMismatch;
    }

    // Validate included transactions before packing: an oversized transaction
    // must invalidate a supplied block even when it would not fit remaining gas.
    if (!options.skip_invalid_transactions) {
        for (transactions) |item| {
            tx_processor.validateTransactionGasLimit(item.tx.gas_limit, execution_fork) catch
                return error.InvalidIncludedTransaction;
        }
    }

    // EIP-7934: account for the encoded block while packing. The payload
    // starts with everything that is not a transaction.
    const block_rlp_payload_size: usize = blockRlpFixedPayloadSize(options.withdrawals, options.header_rlp_size);
    var transactions_rlp_payload_size: usize = 0;
    if (osaka_rules and !options.skip_invalid_transactions) {
        // A supplied transaction list is the block: reject it whole, before
        // any state change, instead of silently dropping its tail.
        var supplied_size: usize = 0;
        for (transactions, 0..) |item, tx_index| {
            supplied_size +|= transactionRlpSize(options, item, tx_index, effective_block_ctx.chain_id);
        }
        if (blockRlpSize(block_rlp_payload_size, supplied_size) > MAX_RLP_BLOCK_SIZE) {
            return error.BlockRlpSizeExceeded;
        }
    }

    try sm.checkpoint();
    var block_committed = false;
    errdefer if (!block_committed) sm.revert();

    // EIP-161 (Spurious Dragon): remember which accounts were already empty
    // before anything in this block runs, system calls included, so every
    // empty account the block creates is cleared at the end.
    var preserved_empty_accounts = if (atLeast(effective_fork, .spurious_dragon))
        try collectEmptyAccounts(allocator, sm)
    else
        null;
    defer if (preserved_empty_accounts) |*accounts| accounts.deinit();

    // EIP-161 also deletes an account that was already empty once a
    // transaction touches it. Only transactions that complete add to the set.
    var touched_accounts = std.AutoHashMap(primitives.Address, void).init(allocator);
    defer touched_accounts.deinit();

    const system_call_fork = evmHardforkFromBlockBuilderFork(effective_fork);

    if (options.parent_beacon_block_root) |root| {
        if (!atLeast(effective_fork, .cancun)) return error.BeaconRootBeforeCancun;
        try applyBeaconRootsSystemCallWithContext(allocator, sm, host_iface, effective_block_ctx, system_call_fork, root);
    }

    if (atLeast(effective_fork, .prague)) {
        const parent_hash = options.parent_hash orelse return error.MissingParentHash;
        try applyHistoricalBlockHashSystemCallWithContext(allocator, sm, host_iface, effective_block_ctx, system_call_fork, parent_hash);
    }

    var receipts = std.array_list.Managed(primitives.Receipt.Receipt).init(allocator);
    errdefer {
        for (receipts.items) |r| r.deinit(allocator);
        receipts.deinit();
    }
    var included_tx_indexes = std.array_list.Managed(usize).init(allocator);
    errdefer included_tx_indexes.deinit();

    var total_gas_used: u64 = 0;
    var total_blob_gas_used: u64 = 0;
    const blob_gas_cap: ?u64 = if (atLeast(effective_fork, .cancun))
        blob_fee.blobParamsForFork(
            options.hardfork_config orelse hardfork_schedule.MAINNET_CHAIN_CONFIG,
            evmHardforkFromBlockBuilderFork(effective_fork),
            effective_block_ctx.block_timestamp,
        ).max_blob_gas
    else
        null;

    for (transactions, 0..) |item, tx_index| {
        // A transaction that does not fit the remaining gas or blob gas makes
        // a supplied block invalid. Only candidate selection
        // (`skip_invalid_transactions`) may leave it out.
        const remaining = effective_block_ctx.block_gas_limit -| total_gas_used;
        if (item.tx.gas_limit > remaining) {
            if (!options.skip_invalid_transactions) return error.InvalidIncludedTransaction;
            if (remaining == 0) break;
            continue;
        }

        const item_blob_gas_used = try executionTxBlobGasUsed(item);
        if (blob_gas_cap) |cap| {
            if (item_blob_gas_used > cap or total_blob_gas_used > cap - item_blob_gas_used) {
                if (!options.skip_invalid_transactions) return error.InvalidIncludedTransaction;
                continue;
            }
        }

        // EIP-7934: leave out a transaction that would push the encoded block
        // past the cap. Smaller transactions later in the list may still fit.
        // A supplied list was already checked whole above.
        const item_rlp_size = transactionRlpSize(options, item, tx_index, effective_block_ctx.chain_id);
        if (osaka_rules and
            blockRlpSize(block_rlp_payload_size, transactions_rlp_payload_size +| item_rlp_size) > MAX_RLP_BLOCK_SIZE)
        {
            if (!options.skip_invalid_transactions) return error.BlockRlpSizeExceeded;
            continue;
        }

        const tx_options = tx_processor.ProcessTransactionOptions{
            .access_list = item.access_list,
            .receipt_type = item.receipt_type,
            .max_fee_per_gas = item.max_fee_per_gas,
            .max_priority_fee_per_gas = item.max_priority_fee_per_gas,
            .authorization_list = item.authorization_list,
            .blob_gas_used = item.blob_gas_used,
            .blob_gas_price = item.blob_gas_price,
            .max_fee_per_blob_gas = item.max_fee_per_blob_gas,
            .blob_versioned_hashes = item.blob_versioned_hashes,
            .hardfork_override = if (options.hardfork_config) |config|
                tx_processor.resolveHardforkWithConfig(config, effective_block_ctx)
            else
                null,
            .remaining_block_gas = remaining,
            .canonical_tx_hash = item.tx_hash,
            .touched_accounts = if (preserved_empty_accounts != null) &touched_accounts else null,
        };

        // Reserve both list slots before executing: once the receipt exists,
        // storing it and its index cannot fail, so no error path can free a
        // receipt the list already owns.
        try receipts.ensureUnusedCapacity(1);
        try included_tx_indexes.ensureUnusedCapacity(1);

        var receipt = tx_processor.processTransactionWithOptions(
            allocator,
            sm,
            host_iface,
            item.caller,
            item.tx,
            effective_block_ctx,
            tx_options,
        ) catch |err| switch (err) {
            tx_processor.TxError.NonceMismatch,
            tx_processor.TxError.SenderNotEOA,
            tx_processor.TxError.UnsupportedTransactionType,
            tx_processor.TxError.IntrinsicGasExceedsLimit,
            tx_processor.TxError.InitcodeTooLarge,
            tx_processor.TxError.TransactionGasLimitExceeded,
            tx_processor.TxError.BlockGasLimitExceeded,
            tx_processor.TxError.InsufficientBalance,
            tx_processor.TxError.GasPriceBelowBaseFee,
            tx_processor.TxError.TipExceedsFeeCap,
            tx_processor.TxError.TooManyBlobs,
            tx_processor.TxError.EmptyBlobHashes,
            tx_processor.TxError.InvalidBlobVersionedHash,
            tx_processor.TxError.EmptyAuthorizationList,
            tx_processor.TxError.ContractCreationNotAllowed,
            => {
                if (options.skip_invalid_transactions) continue;
                return error.InvalidIncludedTransaction;
            },
            else => return err,
        };

        // The receipt is owned locally until the infallible append below.
        {
            errdefer receipt.deinit(allocator);
            const gas_used_u64 = std.math.cast(u64, receipt.gas_used) orelse return error.GasOverflow;
            const next_gas_used = std.math.add(u64, total_gas_used, gas_used_u64) catch return error.GasOverflow;
            const next_blob_gas_used = std.math.add(u64, total_blob_gas_used, try receiptBlobGasUsed(receipt)) catch
                return error.BlobGasOverflow;
            if (receipts.items.len > std.math.maxInt(u32)) return error.TooManyTransactions;
            // Before Byzantium (EIP-658) a receipt commits to the state
            // root right after its transaction instead of a status code.
            // From Spurious Dragon the transaction's EIP-161 clearing comes
            // first, so the root excludes the empty accounts it touched.
            if (!atLeast(effective_fork, .byzantium)) {
                if (preserved_empty_accounts) |*accounts| {
                    try pruneEmptyAccounts(allocator, sm, accounts, &touched_accounts);
                }
                receipt.status = null;
                receipt.root = try computeStateRootForFork(allocator, sm, effective_fork);
            }
            total_gas_used = next_gas_used;
            total_blob_gas_used = next_blob_gas_used;
        }
        receipt.cumulative_gas_used = @as(u256, total_gas_used);
        receipt.transaction_index = @as(u32, @intCast(receipts.items.len));
        receipts.appendAssumeCapacity(receipt);
        included_tx_indexes.appendAssumeCapacity(tx_index);
        transactions_rlp_payload_size +|= item_rlp_size;
    }

    // Execution-specs `apply_body` order: transactions, withdrawals (EIP-4895),
    // then general purpose requests (EIP-7685).
    var withdrawals_root: ?[32]u8 = null;
    if (atLeast(effective_fork, .shanghai)) {
        const withdrawals = options.withdrawals orelse return error.MissingWithdrawals;
        try applyWithdrawals(sm, withdrawals);
        withdrawals_root = try computeWithdrawalsRoot(allocator, withdrawals);
    } else if (options.withdrawals != null) {
        return error.WithdrawalsBeforeShanghai;
    }

    const prague_rules = atLeast(effective_fork, .prague);
    var system_requests = PragueSystemRequests{};
    defer system_requests.deinit(allocator);
    if (prague_rules) {
        system_requests = try collectPragueSystemCallRequests(
            allocator,
            sm,
            host_iface,
            effective_block_ctx,
            system_call_fork,
            options.require_system_contracts,
        );
        system_requests.deposits = try extractDepositRequestsFrom(
            allocator,
            receipts.items,
            options.effectiveDepositContractAddress(),
        );
    }

    // EIP-161 clearing runs after withdrawals and system calls, so neither
    // can leave a new empty account in the state trie. It also deletes the
    // already-empty accounts a transaction touched.
    if (preserved_empty_accounts) |*accounts| {
        try pruneEmptyAccounts(allocator, sm, accounts, &touched_accounts);
    }

    if (!atLeast(effective_fork, .paris)) {
        try applyMinerReward(sm, block_ctx.block_coinbase, effective_fork);
    }

    const transactions_root = try computeIncludedTransactionsRoot(allocator, transactions, included_tx_indexes.items);
    const receipts_root = try computeReceiptsRoot(allocator, receipts.items);
    const logs_bloom = aggregateLogsBloom(receipts.items);
    const effective_requests = requestsWithPragueSystemOutputs(options.requests, system_requests);
    const requests_hash = if (prague_rules or hasAnyRequests(effective_requests))
        computeRequestsHash(effective_requests)
    else
        null;
    var execution_requests: [][]u8 = &.{};
    errdefer freeExecutionRequests(allocator, execution_requests);
    if (prague_rules) execution_requests = try encodeExecutionRequests(allocator, effective_requests);

    const state_root = try computeStateRootForFork(allocator, sm, effective_fork);
    if (options.state_root) |expected_state_root| {
        if (!std.mem.eql(u8, &state_root, &expected_state_root)) return error.InvalidStateRoot;
    }

    // Take ownership of the result slices before committing: a failure after
    // `sm.commit()` would report a failed build with the state already moved.
    const owned_receipts = try receipts.toOwnedSlice();
    errdefer {
        for (owned_receipts) |receipt| receipt.deinit(allocator);
        allocator.free(owned_receipts);
    }
    const owned_included_tx_indexes = try included_tx_indexes.toOwnedSlice();

    // Nothing below can fail.
    sm.commit();
    block_committed = true;

    if (options.dev_runtime) |runtime| {
        runtime.clearNextBlockOverrides();
    }

    return BlockResult{
        .receipts = owned_receipts,
        .included_tx_indexes = owned_included_tx_indexes,
        .total_gas_used = total_gas_used,
        .block_number = effective_block_ctx.block_number,
        .transactions_root = transactions_root,
        .receipts_root = receipts_root,
        .withdrawals_root = withdrawals_root,
        .state_root = state_root,
        .logs_bloom = logs_bloom,
        .blob_gas_used = total_blob_gas_used,
        .requests_hash = requests_hash,
        .rlp_size_upper_bound = blockRlpSize(block_rlp_payload_size, transactions_rlp_payload_size),
        .execution_requests = execution_requests,
        .computed_requests_hash = if (prague_rules) requests_hash else null,
    };
}

/// EIP-7934: reject an RLP-encoded execution block larger than
/// `MAX_RLP_BLOCK_SIZE` from Osaka. Earlier forks have no size rule.
pub fn validateBlockRlpSize(block_rlp_size: usize, fork: Hardfork) error{BlockRlpSizeExceeded}!void {
    if (atLeast(fork, .osaka) and block_rlp_size > MAX_RLP_BLOCK_SIZE) return error.BlockRlpSizeExceeded;
}

/// Size of a transaction as one item of the block body's transaction list:
/// the RLP list for a legacy transaction, and the RLP byte string wrapping
/// `type || rlp(payload)` for a typed one. Exact when the signature fields and
/// `chain_id` are those of the signed envelope; performs no allocation.
pub fn executionTxRlpSize(item: tx_processor.ExecutionTx, chain_id: u256) usize {
    const tx = item.tx;
    // Fields common to every type: nonce, gas limit, to, value, data, r, s.
    var payload: usize = rlpUintSize(tx.nonce) +| rlpUintSize(tx.gas_limit) +|
        (if (tx.to == null) @as(usize, 1) else 21) +|
        rlpUintSize(tx.value) +| rlpBytesSize(tx.data) +|
        rlpUintSize(std.mem.readInt(u256, &tx.r, .big)) +|
        rlpUintSize(std.mem.readInt(u256, &tx.s, .big));

    if (item.receipt_type == .legacy) {
        payload +|= rlpUintSize(tx.gas_price) +| rlpUintSize(tx.v);
        return rlpItemSize(payload);
    }

    // Typed payloads carry the chain id, a one-byte y parity and an access list.
    payload +|= rlpUintSize(chain_id) +| 1 +| accessListRlpSize(item.access_list orelse &.{});
    switch (item.receipt_type) {
        .legacy => unreachable,
        .eip2930 => payload +|= rlpUintSize(tx.gas_price),
        .eip1559, .eip4844, .eip7702 => {
            payload +|= rlpUintSize(item.max_priority_fee_per_gas orelse tx.gas_price) +|
                rlpUintSize(item.max_fee_per_gas orelse tx.gas_price);
        },
    }
    if (item.receipt_type == .eip4844) {
        const hashes = item.blob_versioned_hashes orelse &.{};
        payload +|= rlpUintSize(item.max_fee_per_blob_gas orelse 0) +| rlpItemSize(hashes.len *| 33);
    }
    if (item.receipt_type == .eip7702) {
        var authorizations: usize = 0;
        for (item.authorization_list orelse &.{}) |authorization| {
            authorizations +|= rlpItemSize(rlpUintSize(authorization.chain_id) +| 21 +|
                rlpUintSize(authorization.nonce) +| rlpUintSize(authorization.v) +|
                rlpUintSize(std.mem.readInt(u256, &authorization.r, .big)) +|
                rlpUintSize(std.mem.readInt(u256, &authorization.s, .big)));
        }
        payload +|= rlpItemSize(authorizations);
    }
    // The type byte and payload list form one byte string in the body.
    return rlpItemSize(1 +| rlpItemSize(payload));
}

fn transactionRlpSize(
    options: BuildBlockOptions,
    item: tx_processor.ExecutionTx,
    tx_index: usize,
    chain_id: u256,
) usize {
    if (options.transaction_rlp_sizes) |sizes| return sizes[tx_index];
    return executionTxRlpSize(item, chain_id);
}

/// Payload of the block list excluding transactions: the header (exact size
/// when known, else the upper bound), empty ommers list, and the withdrawals
/// list when the block carries one.
fn blockRlpFixedPayloadSize(
    withdrawals: ?[]const primitives.BlockBody.Withdrawal,
    header_rlp_size: ?usize,
) usize {
    var size: usize = (header_rlp_size orelse MAX_HEADER_RLP_SIZE) +| 1;
    if (withdrawals) |items| {
        var payload: usize = 0;
        for (items) |withdrawal| {
            payload +|= rlpItemSize(rlpUintSize(withdrawal.index) +| rlpUintSize(withdrawal.validator_index) +|
                21 +| rlpUintSize(withdrawal.amount));
        }
        size +|= rlpItemSize(payload);
    }
    return size;
}

fn blockRlpSize(fixed_payload_size: usize, transactions_payload_size: usize) usize {
    return rlpItemSize(fixed_payload_size +| rlpItemSize(transactions_payload_size));
}

/// Exact size of the canonical RLP encoding of `header`; performs no
/// allocation. From Prague the encoding carries the EIP-7685 requests hash as
/// its 21st field: pass the hash kept beside the header in `requests_hash`
/// when `header.requests_hash` is null.
pub fn headerRlpSize(
    header: *const primitives.BlockHeader.BlockHeader,
    fork: Hardfork,
    requests_hash: ?[32]u8,
) usize {
    const hash_size: usize = 33;
    var payload: usize = hash_size * 2 + 21 + hash_size * 3 + rlpItemSize(256) +
        rlpUintSize(header.difficulty) + rlpUintSize(header.number) +
        rlpUintSize(header.gas_limit) + rlpUintSize(header.gas_used) +
        rlpUintSize(header.timestamp) + rlpBytesSize(header.extra_data) +
        hash_size + 9;
    if (header.base_fee_per_gas) |base_fee| payload += rlpUintSize(base_fee);
    if (header.withdrawals_root != null) payload += hash_size;
    if (header.blob_gas_used) |blob_gas_used| payload += rlpUintSize(blob_gas_used);
    if (header.excess_blob_gas) |excess_blob_gas| payload += rlpUintSize(excess_blob_gas);
    if (header.parent_beacon_block_root != null) payload += hash_size;
    if (atLeast(fork, .prague) and (header.requests_hash != null or requests_hash != null)) payload += hash_size;
    return rlpItemSize(payload);
}

/// EIP-7934 size of a block whose measured encoding left the Prague
/// requests hash out of the header (the hash travelled beside the header, as
/// in an Engine payload). Returns `measured_size` unchanged when the header
/// already carries the hash, when there is none, or before Prague.
pub fn blockRlpSizeWithRequestsHash(
    measured_size: usize,
    header: *const primitives.BlockHeader.BlockHeader,
    fork: Hardfork,
    requests_hash: ?[32]u8,
) usize {
    if (!atLeast(fork, .prague) or requests_hash == null or header.requests_hash != null) return measured_size;

    const header_without = headerRlpSize(header, fork, null);
    const header_with = headerRlpSize(header, fork, requests_hash);
    const measured_payload = rlpItemPayloadSize(measured_size) orelse return measured_size +| (header_with - header_without);
    return rlpItemSize(measured_payload +| (header_with - header_without));
}

/// Inverse of `rlpItemSize`: the payload length of a list whose whole
/// encoding is `item_size` bytes, or null when no payload has that size.
fn rlpItemPayloadSize(item_size: usize) ?usize {
    if (item_size == 0) return null;
    if (item_size <= 56) return item_size - 1;
    var length_bytes: usize = 1;
    while (length_bytes <= @sizeOf(usize)) : (length_bytes += 1) {
        if (item_size <= 1 + length_bytes) return null;
        const payload = item_size - 1 - length_bytes;
        if (payload >= 56 and rlpItemSize(payload) == item_size) return payload;
    }
    return null;
}

fn accessListRlpSize(access_list: primitives.AccessList.AccessList) usize {
    var payload: usize = 0;
    for (access_list) |entry| {
        payload +|= rlpItemSize(21 +| rlpItemSize(entry.storage_keys.len *| 33));
    }
    return rlpItemSize(payload);
}

/// Size of an RLP list or of a byte string longer than one byte, given its
/// payload length.
fn rlpItemSize(payload_size: usize) usize {
    if (payload_size < 56) return payload_size + 1;
    const length_bytes: usize = (@as(usize, @bitSizeOf(usize)) - @clz(payload_size) + 7) / 8;
    return payload_size +| (1 + length_bytes);
}

fn rlpBytesSize(bytes: []const u8) usize {
    if (bytes.len == 1 and bytes[0] < 0x80) return 1;
    return rlpItemSize(bytes.len);
}

fn rlpUintSize(value: u256) usize {
    if (value < 0x80) return 1;
    return 1 + (@as(usize, 256) - @clz(value) + 7) / 8;
}

pub fn blockContextWithEnvironmentOverrides(
    runtime: ?*const dev_runtime.DevRuntime,
    block_ctx: guillotine_mini.BlockContext,
) guillotine_mini.BlockContext {
    const rt = runtime orelse return block_ctx;
    var effective = block_ctx;
    effective.block_gas_limit = rt.config.block_gas_limit;
    if (rt.config.next_block_base_fee_per_gas) |base_fee| {
        effective.block_base_fee = base_fee;
    }
    if (rt.config.next_block_timestamp) |timestamp| {
        effective.block_timestamp = timestamp;
    }
    if (rt.config.prev_randao) |prev_randao| {
        effective.block_prevrandao = prev_randao;
    }
    if (rt.config.blob_base_fee) |blob_base_fee| {
        effective.blob_base_fee = blob_base_fee;
    }
    return effective;
}

pub fn validateBlock(allocator: std.mem.Allocator, input: BlockValidationInput) !BlockCommitments {
    try validateHeader(input.header, input.parent_header, input.fork);

    if (input.parent_hash) |parent_hash| {
        if (!std.mem.eql(u8, &input.header.parent_hash, &parent_hash)) return error.InvalidParentHash;
    }
    if (input.ommers_hash) |ommers_hash| {
        if (!std.mem.eql(u8, &input.header.ommers_hash, &ommers_hash)) return error.InvalidOmmersHash;
    }
    // EIP-4788: a Cancun block without a parent beacon block root is invalid.
    if (atLeast(input.fork, .cancun) and input.header.parent_beacon_block_root == null) {
        return error.MissingParentBeaconBlockRoot;
    }

    // EIP-7825: an Osaka block holding a transaction above the cap is invalid
    // whatever its roots say.
    for (input.execution_transactions) |item| {
        tx_processor.validateTransactionGasLimit(item.tx.gas_limit, evmHardforkFromBlockBuilderFork(input.fork)) catch
            return error.TransactionGasLimitExceeded;
    }

    const tx_count = if (input.transaction_envelopes) |envelopes| envelopes.len else input.execution_transactions.len;
    if (tx_count != input.receipts.len) return error.TransactionReceiptCountMismatch;

    const transactions_root = if (input.transaction_envelopes) |envelopes|
        try computeRawTransactionsRoot(allocator, envelopes)
    else
        try computeTransactionsRoot(allocator, input.execution_transactions);

    if (!std.mem.eql(u8, &transactions_root, &input.header.transactions_root)) {
        return error.InvalidTransactionsRoot;
    }

    const receipts_root = try computeReceiptsRoot(allocator, input.receipts);
    if (!std.mem.eql(u8, &receipts_root, &input.header.receipts_root)) {
        return error.InvalidReceiptsRoot;
    }

    const logs_bloom = aggregateLogsBloom(input.receipts);
    if (!std.mem.eql(u8, &logs_bloom, &input.header.logs_bloom)) {
        return error.InvalidLogsBloom;
    }

    const gas_used = try receiptGasUsed(input.receipts);
    if (gas_used != input.header.gas_used) return error.InvalidGasUsed;

    const withdrawals_root = try validateWithdrawalsRoot(allocator, input.header, input.withdrawals, input.fork);

    if (input.state_root) |state_root| {
        if (!std.mem.eql(u8, &state_root, &input.header.state_root)) return error.InvalidStateRoot;
    }

    const blob_gas_used = try validateBlobGas(
        input.header,
        input.parent_header,
        input.receipts,
        input.fork,
        input.hardfork_config orelse hardfork_schedule.MAINNET_CHAIN_CONFIG,
    );
    const requests_hash = try validateRequestsHash(input);

    return .{
        .transactions_root = transactions_root,
        .receipts_root = receipts_root,
        .withdrawals_root = withdrawals_root,
        .state_root = input.state_root,
        .logs_bloom = logs_bloom,
        .blob_gas_used = blob_gas_used,
        .excess_blob_gas = input.header.excess_blob_gas,
        .requests_hash = requests_hash,
    };
}

/// EIP-7685: on Prague+ the hash the block commits to must equal the hash
/// recomputed from execution. Returns the committed hash.
///
/// The header field does not exist before Prague and is mandatory from
/// Prague: a hash committed earlier, or a Prague+ block without one, is
/// invalid.
fn validateRequestsHash(input: BlockValidationInput) error{InvalidRequestsHash}!?[32]u8 {
    const committed = input.requests_hash orelse input.header.requests_hash;
    if (!atLeast(input.fork, .prague)) {
        if (committed != null) return error.InvalidRequestsHash;
        return null;
    }
    if (committed == null) return error.InvalidRequestsHash;

    if (input.requests_hash) |claimed| {
        if (input.header.requests_hash) |header_hash| {
            if (!std.mem.eql(u8, &claimed, &header_hash)) return error.InvalidRequestsHash;
        }
    }
    if (input.computed_requests_hash) |computed| {
        const claimed = committed orelse return error.InvalidRequestsHash;
        if (!std.mem.eql(u8, &computed, &claimed)) return error.InvalidRequestsHash;
    }
    return committed;
}

/// Gas limit rule of the header validity function, without overflow: the
/// limit must move by less than `parent / 1024` and stay at or above 5000.
/// On the first London block the parent limit is first multiplied by the
/// EIP-1559 elasticity multiplier.
pub fn validateGasLimit(
    header: *const primitives.BlockHeader.BlockHeader,
    parent: *const primitives.BlockHeader.BlockHeader,
    fork: Hardfork,
) error{InvalidGasLimitDelta}!void {
    // A parent without a base fee is pre-London, which makes `header` the
    // London fork block (the same test `expectedBaseFeePerGas` uses).
    const london_fork_block = atLeast(fork, .london) and parent.base_fee_per_gas == null;
    const parent_gas_limit = if (london_fork_block)
        parent.gas_limit *| GAS_LIMIT_ELASTICITY_MULTIPLIER
    else
        parent.gas_limit;

    const max_delta = parent_gas_limit / GAS_LIMIT_ADJUSTMENT_FACTOR;
    const delta = if (header.gas_limit > parent_gas_limit)
        header.gas_limit - parent_gas_limit
    else
        parent_gas_limit - header.gas_limit;
    if (delta >= max_delta) return error.InvalidGasLimitDelta;
    if (header.gas_limit < MIN_GAS_LIMIT) return error.InvalidGasLimitDelta;
}

/// Header validity against the parent header. `validateBlock` adds the
/// checks that need more than the two headers: parent hash, ommers hash,
/// the Cancun parent beacon block root, and the Prague requests hash.
pub fn validateHeader(
    header: *const primitives.BlockHeader.BlockHeader,
    parent: *const primitives.BlockHeader.BlockHeader,
    fork: Hardfork,
) !void {
    if (header.gas_used > header.gas_limit) return error.HeaderGasUsedExceedsLimit;
    try validateGasLimit(header, parent, fork);
    primitives.BlockHeader.validateTimestampStrictlyGreater(header, parent) catch return error.InvalidTimestamp;
    if (parent.number == std.math.maxInt(u64)) return error.InvalidBlockNumber;
    if (header.number != parent.number + 1) return error.InvalidBlockNumber;
    if (header.extra_data.len > primitives.BlockHeader.MAX_EXTRA_DATA_SIZE) return error.ExtraDataTooLarge;

    if (atLeast(fork, .paris)) {
        if (header.difficulty != 0) return error.InvalidPostParisDifficulty;
        if (!std.mem.eql(u8, &header.nonce, &([_]u8{0} ** 8))) return error.InvalidPostParisNonce;
        if (!std.mem.eql(u8, &header.ommers_hash, &primitives.BlockHeader.EMPTY_OMMERS_HASH)) {
            return error.InvalidPostParisOmmersHash;
        }
    }

    if (atLeast(fork, .london)) {
        const actual_base_fee = header.base_fee_per_gas orelse return error.MissingBaseFeePerGas;
        const expected_base_fee = try expectedBaseFeePerGas(parent);
        if (actual_base_fee != expected_base_fee) return error.InvalidBaseFeePerGas;
    } else if (header.base_fee_per_gas != null) {
        return error.BaseFeeBeforeLondon;
    }

    if (!atLeast(fork, .shanghai) and header.withdrawals_root != null) return error.WithdrawalsRootBeforeShanghai;
    if (!atLeast(fork, .cancun) and (header.blob_gas_used != null or header.excess_blob_gas != null or header.parent_beacon_block_root != null)) {
        return error.BlobFieldsBeforeCancun;
    }
    // EIP-7685. The Prague+ presence check lives in `validateBlock`, because
    // callers may keep the hash beside the header (`BlockValidationInput.requests_hash`).
    if (!atLeast(fork, .prague) and header.requests_hash != null) return error.InvalidRequestsHash;
}

pub fn expectedBaseFeePerGas(parent: *const primitives.BlockHeader.BlockHeader) !u256 {
    const parent_base_fee = parent.base_fee_per_gas orelse return INITIAL_BASE_FEE_PER_GAS;
    const parent_gas_target = parent.gas_limit / GAS_LIMIT_ELASTICITY_MULTIPLIER;
    if (parent_gas_target == 0) return error.InvalidGasLimit;

    if (parent.gas_used == parent_gas_target) return parent_base_fee;

    if (parent.gas_used > parent_gas_target) {
        const gas_delta = parent.gas_used - parent_gas_target;
        const raw_delta = (@as(u512, parent_base_fee) * @as(u512, gas_delta)) /
            @as(u512, parent_gas_target) /
            @as(u512, BASE_FEE_CHANGE_DENOMINATOR);
        if (raw_delta > std.math.maxInt(u256)) return error.BaseFeeOverflow;
        const base_fee_delta = @max(@as(u256, 1), @as(u256, @intCast(raw_delta)));
        return std.math.add(u256, parent_base_fee, base_fee_delta) catch return error.BaseFeeOverflow;
    }

    const gas_delta = parent_gas_target - parent.gas_used;
    const raw_delta = (@as(u512, parent_base_fee) * @as(u512, gas_delta)) /
        @as(u512, parent_gas_target) /
        @as(u512, BASE_FEE_CHANGE_DENOMINATOR);
    const base_fee_delta = @as(u256, @intCast(raw_delta));
    if (parent_base_fee > base_fee_delta) return parent_base_fee - base_fee_delta;
    return 0;
}

pub fn computeTransactionsRoot(
    allocator: std.mem.Allocator,
    transactions: []const tx_processor.ExecutionTx,
) ![32]u8 {
    if (transactions.len == 0) return primitives.BlockHeader.EMPTY_TRANSACTIONS_ROOT;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const keys = try arena_alloc.alloc([]const u8, transactions.len);
    const values = try arena_alloc.alloc([]const u8, transactions.len);

    for (transactions, 0..) |item, i| {
        keys[i] = try primitives.Rlp.encode(arena_alloc, @as(u64, @intCast(i)));
        // The trie commits to the signed EIP-2718 envelope. Re-encoding as
        // legacy is correct only for a legacy transaction, so it is the
        // fallback for callers that carry no canonical bytes.
        values[i] = item.raw orelse try tx_encoding.encodeLegacyTransactionEnvelope(arena_alloc, item.tx);
    }

    return primitives.TrieHash.trie_root(arena_alloc, keys, values);
}

fn computeIncludedTransactionsRoot(
    allocator: std.mem.Allocator,
    transactions: []const tx_processor.ExecutionTx,
    included_tx_indexes: []const usize,
) ![32]u8 {
    const included = try allocator.alloc(tx_processor.ExecutionTx, included_tx_indexes.len);
    defer allocator.free(included);

    for (included_tx_indexes, 0..) |tx_index, out_index| {
        if (tx_index >= transactions.len) return error.InvalidIncludedTransactionIndex;
        included[out_index] = transactions[tx_index];
    }

    return computeTransactionsRoot(allocator, included);
}

pub fn computeRawTransactionsRoot(
    allocator: std.mem.Allocator,
    transactions: []const primitives.BlockBody.TransactionData,
) ![32]u8 {
    // One arena owns every key: a single free on both the success and the
    // error path, so no key can be freed twice or leaked.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const keys = try arena_alloc.alloc([]const u8, transactions.len);
    const values = try arena_alloc.alloc([]const u8, transactions.len);

    for (transactions, 0..) |item, i| {
        keys[i] = try primitives.Rlp.encode(arena_alloc, @as(u64, @intCast(i)));
        values[i] = item.raw;
    }

    return primitives.TrieHash.trie_root(arena_alloc, keys, values);
}

pub fn computeReceiptsRoot(
    allocator: std.mem.Allocator,
    receipts: []const primitives.Receipt.Receipt,
) ![32]u8 {
    if (receipts.len == 0) return primitives.BlockHeader.EMPTY_RECEIPTS_ROOT;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const keys = try arena_alloc.alloc([]const u8, receipts.len);
    const values = try arena_alloc.alloc([]const u8, receipts.len);

    for (receipts, 0..) |receipt, i| {
        keys[i] = try primitives.Rlp.encode(arena_alloc, @as(u64, @intCast(i)));
        values[i] = try encodeReceiptEnvelope(arena_alloc, receipt);
    }

    return primitives.TrieHash.trie_root(arena_alloc, keys, values);
}

pub fn computeStateRoot(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
) ![32]u8 {
    return computeStateRootForFork(allocator, sm, .paris);
}

pub fn computeStateRootForFork(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    fork: Hardfork,
) ![32]u8 {
    _ = fork;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var addresses = std.AutoHashMap(primitives.Address, void).init(arena_alloc);

    var account_it = sm.accountIterator();
    while (account_it.next()) |entry| {
        try addresses.put(entry.key_ptr.*, {});
    }

    var code_it = sm.journaled_state.contract_cache.cache.keyIterator();
    while (code_it.next()) |address| {
        try addresses.put(address.*, {});
    }

    var storage_it = sm.journaled_state.storage_cache.cache.keyIterator();
    while (storage_it.next()) |address| {
        try addresses.put(address.*, {});
    }

    const cap = addresses.count();
    var keys = try std.ArrayList([]const u8).initCapacity(arena_alloc, cap);
    var values = try std.ArrayList([]const u8).initCapacity(arena_alloc, cap);

    var address_it = addresses.keyIterator();
    while (address_it.next()) |address_ptr| {
        const address = address_ptr.*;
        const account = sm.journaled_state.account_cache.get(address) orelse state_manager.AccountState.init();
        const storage_root = try computeAccountStorageRoot(arena_alloc, sm, address, account.storage_root);
        const code_hash = computeAccountCodeHash(sm, address, account.code_hash);

        try appendAccountTrieEntry(
            arena_alloc,
            &keys,
            &values,
            address,
            account.nonce,
            account.balance,
            storage_root,
            code_hash,
        );
    }

    return try primitives.TrieHash.secure_trie_root(arena_alloc, keys.items, values.items);
}

pub fn computeStorageRoot(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    address: primitives.Address,
) ![32]u8 {
    return computeAccountStorageRoot(allocator, sm, address, primitives.State.EMPTY_TRIE_ROOT);
}

pub fn collectEmptyAccounts(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
) !std.AutoHashMap(primitives.Address, void) {
    var preserved = std.AutoHashMap(primitives.Address, void).init(allocator);
    errdefer preserved.deinit();

    var account_it = sm.accountIterator();
    while (account_it.next()) |entry| {
        if (cachedAccountIsEmpty(sm, entry.key_ptr.*)) {
            try preserved.put(entry.key_ptr.*, {});
        }
    }

    return preserved;
}

/// Delete every empty account the block created. Accounts in `preserved`
/// (empty before the block) survive, touched or not; callers that track
/// touches use `pruneEmptyAccounts`.
pub fn pruneNewEmptyAccounts(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    preserved: *const std.AutoHashMap(primitives.Address, void),
) !void {
    return pruneEmptyAccounts(allocator, sm, preserved, null);
}

/// EIP-161 state clearing. Deletes an empty account when the block created
/// it (it is not in `preserved`) or when a transaction touched it (it is in
/// `touched`). An account that was empty before the block and that nothing
/// touched stays in the state trie.
pub fn pruneEmptyAccounts(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    preserved: *const std.AutoHashMap(primitives.Address, void),
    touched: ?*const std.AutoHashMap(primitives.Address, void),
) !void {
    var addresses = std.AutoHashMap(primitives.Address, void).init(allocator);
    defer addresses.deinit();

    var account_it = sm.accountIterator();
    while (account_it.next()) |entry| {
        try addresses.put(entry.key_ptr.*, {});
    }
    var code_it = sm.journaled_state.contract_cache.cache.keyIterator();
    while (code_it.next()) |address| {
        try addresses.put(address.*, {});
    }
    var storage_it = sm.journaled_state.storage_cache.cache.keyIterator();
    while (storage_it.next()) |address| {
        try addresses.put(address.*, {});
    }

    var address_it = addresses.keyIterator();
    while (address_it.next()) |address_ptr| {
        const address = address_ptr.*;
        if (!cachedAccountIsEmpty(sm, address)) continue;
        const was_touched = if (touched) |set| set.contains(address) else false;
        if (preserved.contains(address) and !was_touched) continue;
        removeCachedAccount(sm, address);
    }
}

fn cachedAccountIsEmpty(sm: *state_manager.StateManager, address: primitives.Address) bool {
    const account = sm.journaled_state.account_cache.get(address) orelse state_manager.AccountState.init();
    if (account.nonce != 0 or account.balance != 0) return false;

    if (sm.journaled_state.contract_cache.get(address)) |code| {
        if (code.len != 0) return false;
    } else if (!std.mem.eql(u8, &account.code_hash, &primitives.Hash.ZERO) and
        !std.mem.eql(u8, &account.code_hash, &primitives.State.EMPTY_CODE_HASH))
    {
        return false;
    }

    if (sm.journaled_state.storage_cache.cache.getPtr(address)) |slots| {
        var it = slots.valueIterator();
        while (it.next()) |value| {
            if (value.* != 0) return false;
        }
    } else if (!std.mem.eql(u8, &account.storage_root, &primitives.Hash.ZERO) and
        !std.mem.eql(u8, &account.storage_root, &primitives.State.EMPTY_TRIE_ROOT))
    {
        return false;
    }

    return true;
}

pub fn computeWithdrawalsRoot(
    allocator: std.mem.Allocator,
    withdrawals: []const primitives.BlockBody.Withdrawal,
) ![32]u8 {
    // One arena owns every key and value: a single free on both the success
    // and the error path, so nothing can be freed twice or leaked.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const keys = try arena_alloc.alloc([]const u8, withdrawals.len);
    const values = try arena_alloc.alloc([]const u8, withdrawals.len);

    for (withdrawals, 0..) |withdrawal, i| {
        keys[i] = try primitives.Rlp.encode(arena_alloc, @as(u64, @intCast(i)));
        values[i] = try encodeWithdrawal(arena_alloc, withdrawal);
    }

    return primitives.TrieHash.trie_root(arena_alloc, keys, values);
}

pub fn aggregateLogsBloom(receipts: []const primitives.Receipt.Receipt) [256]u8 {
    var logs_bloom: [256]u8 = [_]u8{0} ** 256;
    for (receipts) |receipt| {
        for (receipt.logs_bloom, 0..) |byte, i| {
            logs_bloom[i] |= byte;
        }
    }
    return logs_bloom;
}

pub fn applyWithdrawals(
    sm: *state_manager.StateManager,
    withdrawals: []const primitives.BlockBody.Withdrawal,
) !void {
    for (withdrawals) |withdrawal| {
        // EIP-4895: a zero-amount withdrawal changes no balance. Writing the
        // unchanged balance would create an empty account for a recipient
        // that does not exist, and that account would enter the state trie.
        if (withdrawal.amount == 0) continue;
        const credit = std.math.mul(u256, @as(u256, withdrawal.amount), WEI_PER_GWEI) catch return error.WithdrawalAmountOverflow;
        const balance = try sm.getBalance(withdrawal.address);
        const new_balance = std.math.add(u256, balance, credit) catch return error.BalanceOverflow;
        try sm.setBalance(withdrawal.address, new_balance);
    }
}

/// EIP-4788 with only a timestamp to go on. Builds its own host adapter over
/// `sm`, a block context carrying `timestamp`, and allocates EVM scratch from
/// the state manager's allocator. Callers that hold the block context should
/// use `applyBeaconRootsSystemCallWithContext`.
pub fn applyBeaconRootsSystemCall(
    sm: *state_manager.StateManager,
    timestamp: u64,
    parent_beacon_block_root: [32]u8,
) !void {
    var adapter = host_adapter.HostAdapter{ .state = sm };
    var block_ctx = systemCallBlockContext();
    block_ctx.block_timestamp = timestamp;
    try applyBeaconRootsSystemCallWithContext(
        sm.allocator,
        sm,
        adapter.hostInterface(),
        block_ctx,
        .CANCUN,
        parent_beacon_block_root,
    );
}

/// EIP-4788: call `BEACON_ROOTS_ADDRESS` as `SYSTEM_ADDRESS` with the parent
/// beacon block root as calldata and 30M gas. An address without code makes
/// the call a no-op: nothing is written, so a chain that never deployed the
/// contract gets no phantom storage. A reverting call is ignored, as the EIP
/// specifies; only a host failure is an error.
pub fn applyBeaconRootsSystemCallWithContext(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    host_iface: guillotine_mini.HostInterface,
    block_ctx: guillotine_mini.BlockContext,
    hardfork: guillotine_mini.Hardfork,
    parent_beacon_block_root: [32]u8,
) !void {
    const output = try runSystemContractCallWithMode(
        allocator,
        sm,
        host_iface,
        block_ctx,
        hardfork,
        BEACON_ROOTS_ADDRESS,
        &parent_beacon_block_root,
        .unchecked,
        false,
    );
    if (output) |bytes| allocator.free(bytes);
}

/// EIP-2935 with only a block number to go on. See
/// `applyBeaconRootsSystemCall` for the adapter, context, and allocator used.
pub fn applyHistoricalBlockHashSystemCall(
    sm: *state_manager.StateManager,
    block_number: u64,
    parent_hash: [32]u8,
) !void {
    var adapter = host_adapter.HostAdapter{ .state = sm };
    var block_ctx = systemCallBlockContext();
    block_ctx.block_number = block_number;
    try applyHistoricalBlockHashSystemCallWithContext(
        sm.allocator,
        sm,
        adapter.hostInterface(),
        block_ctx,
        .PRAGUE,
        parent_hash,
    );
}

/// EIP-2935: call `HISTORY_STORAGE_ADDRESS` as `SYSTEM_ADDRESS` with the
/// parent hash as calldata and 30M gas. Same empty-code and failure rules as
/// `applyBeaconRootsSystemCallWithContext`. The genesis block has no parent.
pub fn applyHistoricalBlockHashSystemCallWithContext(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    host_iface: guillotine_mini.HostInterface,
    block_ctx: guillotine_mini.BlockContext,
    hardfork: guillotine_mini.Hardfork,
    parent_hash: [32]u8,
) !void {
    if (block_ctx.block_number == 0) return;

    const output = try runSystemContractCallWithMode(
        allocator,
        sm,
        host_iface,
        block_ctx,
        hardfork,
        HISTORY_STORAGE_ADDRESS,
        &parent_hash,
        .unchecked,
        false,
    );
    if (output) |bytes| allocator.free(bytes);
}

/// Block context for a system call made by a caller that knows only one
/// block field. The system contracts read `TIMESTAMP` (EIP-4788) or `NUMBER`
/// (EIP-2935) and nothing else from the environment.
fn systemCallBlockContext() guillotine_mini.BlockContext {
    return .{
        .chain_id = 1,
        .block_number = 0,
        .block_timestamp = 0,
        .block_difficulty = 0,
        .block_prevrandao = 0,
        .block_coinbase = primitives.Address{ .bytes = [_]u8{0} ** 20 },
        .block_gas_limit = SYSTEM_CALL_GAS_LIMIT,
        .block_base_fee = 0,
        .blob_base_fee = 0,
    };
}

/// EIP-7002 and EIP-7251 system calls. A predeploy without code yields a
/// null field and changes no state.
///
/// This departs from the EIPs, which make a Prague block invalid when either
/// predeploy has no code. Chains that never deployed the contracts (dev
/// chains) need the no-op to produce blocks at all; a chain that has them
/// deployed is unaffected.
pub fn collectPragueRequestsSystemCalls(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    host_iface: guillotine_mini.HostInterface,
    block_ctx: guillotine_mini.BlockContext,
    hardfork: guillotine_mini.Hardfork,
) !PragueSystemRequests {
    return collectPragueSystemCallRequests(allocator, sm, host_iface, block_ctx, hardfork, false);
}

/// The EIP-7002 and EIP-7251 system calls. With `require_system_contracts` a
/// predeploy without code is `error.SystemContractMissingCode`; without it
/// the call is a no-op that yields a null field.
fn collectPragueSystemCallRequests(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    host_iface: guillotine_mini.HostInterface,
    block_ctx: guillotine_mini.BlockContext,
    hardfork: guillotine_mini.Hardfork,
    require_system_contracts: bool,
) !PragueSystemRequests {
    var requests = PragueSystemRequests{};
    errdefer requests.deinit(allocator);

    requests.withdrawals = try runSystemContractCallWithMode(
        allocator,
        sm,
        host_iface,
        block_ctx,
        hardfork,
        WITHDRAWAL_REQUESTS_ADDRESS,
        &.{},
        .checked,
        require_system_contracts,
    );
    requests.consolidations = try runSystemContractCallWithMode(
        allocator,
        sm,
        host_iface,
        block_ctx,
        hardfork,
        CONSOLIDATION_REQUESTS_ADDRESS,
        &.{},
        .checked,
        require_system_contracts,
    );
    return requests;
}

/// EIP-7685 request payloads of a Prague block with default options: the
/// mainnet deposit contract and a no-op for a predeploy without code.
pub fn collectPragueRequests(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    host_iface: guillotine_mini.HostInterface,
    block_ctx: guillotine_mini.BlockContext,
    hardfork: guillotine_mini.Hardfork,
    logs: []const primitives.EventLog.EventLog,
) !PragueRequests {
    return collectPragueRequestsWithOptions(allocator, sm, host_iface, block_ctx, hardfork, logs, .{});
}

/// EIP-7685 request payloads of a Prague block: EIP-6110 deposits from the
/// block's `logs`, in log order, then the EIP-7002 withdrawal and EIP-7251
/// consolidation system calls, which mutate `sm`. The caller owns the result
/// and frees it with `deinit`.
///
/// `options.require_system_contracts` selects between the EIP rule (a
/// predeploy without code is `error.SystemContractMissingCode`) and the
/// dev-chain no-op (a null field, no state change).
pub fn collectPragueRequestsWithOptions(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    host_iface: guillotine_mini.HostInterface,
    block_ctx: guillotine_mini.BlockContext,
    hardfork: guillotine_mini.Hardfork,
    logs: []const primitives.EventLog.EventLog,
    options: PragueRequestsOptions,
) !PragueRequests {
    var requests = try collectPragueSystemCallRequests(
        allocator,
        sm,
        host_iface,
        block_ctx,
        hardfork,
        options.require_system_contracts,
    );
    errdefer requests.deinit(allocator);
    requests.deposits = try extractDepositRequestsFromLogs(allocator, logs, options.deposit_contract_address);
    return requests;
}

/// EIP-6110: concatenate the deposit requests logged by the deposit contract
/// in `receipts`, in log order. Returns null when no receipt carries a
/// deposit log. Caller owns the result.
///
/// A log from the deposit contract with the `DepositEvent` topic whose data
/// is not the fixed 576-byte layout makes the block invalid
/// (`error.InvalidDepositEventLayout`).
pub fn extractDepositRequests(
    allocator: std.mem.Allocator,
    receipts: []const primitives.Receipt.Receipt,
) !?[]u8 {
    return extractDepositRequestsFrom(allocator, receipts, DEPOSIT_CONTRACT_ADDRESS);
}

/// `extractDepositRequests` for a chain whose deposit contract lives at
/// `deposit_contract_address`.
pub fn extractDepositRequestsFrom(
    allocator: std.mem.Allocator,
    receipts: []const primitives.Receipt.Receipt,
    deposit_contract_address: primitives.Address,
) !?[]u8 {
    var deposits = std.ArrayList(u8){};
    errdefer deposits.deinit(allocator);

    for (receipts) |receipt| {
        try appendDepositRequests(allocator, &deposits, receipt.logs, deposit_contract_address);
    }

    if (deposits.items.len == 0) {
        deposits.deinit(allocator);
        return null;
    }
    return try deposits.toOwnedSlice(allocator);
}

/// `extractDepositRequestsFrom` over a flat list of the block's logs.
pub fn extractDepositRequestsFromLogs(
    allocator: std.mem.Allocator,
    logs: []const primitives.EventLog.EventLog,
    deposit_contract_address: primitives.Address,
) !?[]u8 {
    var deposits = std.ArrayList(u8){};
    errdefer deposits.deinit(allocator);

    try appendDepositRequests(allocator, &deposits, logs, deposit_contract_address);

    if (deposits.items.len == 0) {
        deposits.deinit(allocator);
        return null;
    }
    return try deposits.toOwnedSlice(allocator);
}

fn appendDepositRequests(
    allocator: std.mem.Allocator,
    deposits: *std.ArrayList(u8),
    logs: []const primitives.EventLog.EventLog,
    deposit_contract_address: primitives.Address,
) !void {
    for (logs) |event_log| {
        if (!event_log.address.equals(deposit_contract_address)) continue;
        if (event_log.topics.len == 0) continue;
        if (!std.mem.eql(u8, &event_log.topics[0], &DEPOSIT_EVENT_TOPIC)) continue;

        const request = try parseDepositEventData(event_log.data);
        try deposits.appendSlice(allocator, &request);
    }
}

/// Decode one ABI-encoded `DepositEvent(bytes,bytes,bytes,bytes,bytes)` into
/// the 192-byte EIP-6110 request. The layout is fixed: five head offsets,
/// then each field as a 32-byte length word followed by padded data.
fn parseDepositEventData(data: []const u8) error{InvalidDepositEventLayout}![DEPOSIT_REQUEST_SIZE]u8 {
    if (data.len != DEPOSIT_EVENT_DATA_SIZE) return error.InvalidDepositEventLayout;

    const Field = struct { offset: usize, size: usize };
    // pubkey, withdrawal_credentials, amount, signature, index.
    const fields = [_]Field{
        .{ .offset = 160, .size = 48 },
        .{ .offset = 256, .size = 32 },
        .{ .offset = 320, .size = 8 },
        .{ .offset = 384, .size = 96 },
        .{ .offset = 512, .size = 8 },
    };

    var request: [DEPOSIT_REQUEST_SIZE]u8 = undefined;
    var written: usize = 0;
    for (fields, 0..) |field, index| {
        const head = std.mem.readInt(u256, data[index * 32 ..][0..32], .big);
        if (head != field.offset) return error.InvalidDepositEventLayout;
        const size = std.mem.readInt(u256, data[field.offset..][0..32], .big);
        if (size != field.size) return error.InvalidDepositEventLayout;

        @memcpy(request[written..][0..field.size], data[field.offset + 32 ..][0..field.size]);
        written += field.size;
    }
    std.debug.assert(written == DEPOSIT_REQUEST_SIZE);
    return request;
}

/// EIP-7685 requests of a Prague+ block: EIP-6110 deposits from the logs in
/// `receipts`, then the EIP-7002 withdrawal and EIP-7251 consolidation system
/// calls, which mutate `sm`. Returns `[type || payload]` elements in ascending
/// type order with empty payloads omitted, or an empty slice before Prague.
/// Free with `freeExecutionRequests`.
///
/// The calls run through a host adapter built over `sm`. A predeploy without
/// code contributes nothing (see `collectPragueRequestsSystemCalls`).
pub fn collectBlockExecutionRequests(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    receipts: []const primitives.Receipt.Receipt,
    hardfork: Hardfork,
    block_ctx: guillotine_mini.BlockContext,
) ![][]u8 {
    return collectBlockExecutionRequestsFrom(allocator, sm, receipts, hardfork, block_ctx, DEPOSIT_CONTRACT_ADDRESS);
}

/// `collectBlockExecutionRequests` for a chain whose EIP-6110 deposit contract
/// lives at `deposit_contract_address`.
pub fn collectBlockExecutionRequestsFrom(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    receipts: []const primitives.Receipt.Receipt,
    hardfork: Hardfork,
    block_ctx: guillotine_mini.BlockContext,
    deposit_contract_address: primitives.Address,
) ![][]u8 {
    return collectBlockExecutionRequestsWithOptions(allocator, sm, receipts, hardfork, block_ctx, .{
        .deposit_contract_address = deposit_contract_address,
        .require_system_contracts = false,
    });
}

/// `collectBlockExecutionRequests` with the full `PragueRequestsOptions`:
/// the deposit contract address, and whether an EIP-7002 or EIP-7251
/// predeploy without code is `error.SystemContractMissingCode`
/// (`require_system_contracts`) or a no-op.
pub fn collectBlockExecutionRequestsWithOptions(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    receipts: []const primitives.Receipt.Receipt,
    hardfork: Hardfork,
    block_ctx: guillotine_mini.BlockContext,
    options: PragueRequestsOptions,
) ![][]u8 {
    if (!atLeast(hardfork, .prague)) return try allocator.alloc([]u8, 0);

    var log_count: usize = 0;
    for (receipts) |receipt| log_count += receipt.logs.len;
    const logs = try allocator.alloc(primitives.EventLog.EventLog, log_count);
    defer allocator.free(logs);
    var log_index: usize = 0;
    for (receipts) |receipt| {
        @memcpy(logs[log_index..][0..receipt.logs.len], receipt.logs);
        log_index += receipt.logs.len;
    }

    var adapter = host_adapter.HostAdapter{ .state = sm };
    var requests = try collectPragueRequestsWithOptions(
        allocator,
        sm,
        adapter.hostInterface(),
        block_ctx,
        evmHardforkFromBlockBuilderFork(hardfork),
        logs,
        options,
    );
    defer requests.deinit(allocator);

    return encodeExecutionRequests(allocator, requestsWithPragueSystemOutputs(.{}, requests));
}

/// Encode each non-empty request type as an owned `[type || payload]` slice,
/// in ascending type order. Free with `freeExecutionRequests`.
pub fn encodeExecutionRequests(allocator: std.mem.Allocator, requests: RequestsByType) ![][]u8 {
    const typed = [_]struct { request_type: u8, payload: []const u8 }{
        .{ .request_type = DEPOSIT_REQUEST_TYPE, .payload = requests.deposits },
        .{ .request_type = WITHDRAWAL_REQUEST_TYPE, .payload = requests.withdrawals },
        .{ .request_type = CONSOLIDATION_REQUEST_TYPE, .payload = requests.consolidations },
    };

    var count: usize = 0;
    for (typed) |entry| {
        if (entry.payload.len != 0) count += 1;
    }

    const out = try allocator.alloc([]u8, count);
    var written: usize = 0;
    errdefer {
        for (out[0..written]) |request| allocator.free(request);
        allocator.free(out);
    }
    for (typed) |entry| {
        if (entry.payload.len == 0) continue;
        const request = try allocator.alloc(u8, 1 + entry.payload.len);
        request[0] = entry.request_type;
        @memcpy(request[1..], entry.payload);
        out[written] = request;
        written += 1;
    }
    return out;
}

/// Free a list returned by `collectBlockExecutionRequests` or
/// `encodeExecutionRequests`.
pub fn freeExecutionRequests(allocator: std.mem.Allocator, requests: [][]u8) void {
    for (requests) |request| allocator.free(request);
    allocator.free(requests);
}

/// EIP-7685 commitment over raw `[type || payload]` requests:
/// `sha256(sha256(r_0) ++ sha256(r_1) ++ ...)` taken in ascending type order,
/// skipping every request with an empty payload. Equal to
/// `computeRequestsHash` of the same requests.
pub fn computeRequestsHashFromRawRequests(
    allocator: std.mem.Allocator,
    requests: []const []const u8,
) ![32]u8 {
    const order = try allocator.alloc(usize, requests.len);
    defer allocator.free(order);
    for (order, 0..) |*slot, index| slot.* = index;

    // Stable, so requests that share a type keep their given order.
    const Context = struct {
        requests: []const []const u8,

        fn typeOf(self: @This(), index: usize) u8 {
            const request = self.requests[index];
            return if (request.len == 0) 0 else request[0];
        }

        fn lessThan(self: @This(), lhs: usize, rhs: usize) bool {
            return self.typeOf(lhs) < self.typeOf(rhs);
        }
    };
    std.mem.sort(usize, order, Context{ .requests = requests }, Context.lessThan);

    var outer = std.crypto.hash.sha2.Sha256.init(.{});
    for (order) |index| {
        const request = requests[index];
        // A lone type byte carries no request data and is not committed.
        if (request.len <= 1) continue;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(request, &digest, .{});
        outer.update(&digest);
    }

    var out: [32]u8 = undefined;
    outer.final(&out);
    return out;
}

/// Executes `to` as `SYSTEM_ADDRESS` with the 30M system-call gas limit and
/// returns its output, owned by the caller. The call consumes no block gas
/// and pays no fees.
///
/// This is the strict EIP-7002 / EIP-7251 form: a contract without code is
/// `error.SystemContractMissingCode` and a failing call is
/// `error.SystemContractCallFailed`. A node-owned genesis carries the code
/// (`system_contracts.installGenesis`).
pub fn runSystemContractCall(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    host_iface: guillotine_mini.HostInterface,
    block_ctx: guillotine_mini.BlockContext,
    hardfork: guillotine_mini.Hardfork,
    to: primitives.Address,
    input: []const u8,
) ![]u8 {
    return (try runSystemContractCallWithMode(
        allocator,
        sm,
        host_iface,
        block_ctx,
        hardfork,
        to,
        input,
        .checked,
        true,
    )) orelse error.SystemContractMissingCode;
}

const SystemCallMode = enum {
    /// EIP-7002 / EIP-7251: a failing call invalidates the block.
    checked,
    /// EIP-4788 / EIP-2935: a failing call is ignored and leaves no trace.
    unchecked,
};

/// Execute a system contract as `SYSTEM_ADDRESS` with `SYSTEM_CALL_GAS_LIMIT`
/// gas and return its output, owned by the caller.
///
/// Returns null without touching state when `to` has no code, and, in
/// `.unchecked` mode, when the call fails (its state changes are reverted).
/// A `.checked` call with `require_system_contracts` instead fails with
/// `error.SystemContractMissingCode` when `to` has no code.
fn runSystemContractCallWithMode(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    host_iface: guillotine_mini.HostInterface,
    block_ctx: guillotine_mini.BlockContext,
    hardfork: guillotine_mini.Hardfork,
    to: primitives.Address,
    input: []const u8,
    mode: SystemCallMode,
    require_system_contracts: bool,
) !?[]u8 {
    const code = try sm.getCode(to);
    if (code.len == 0) {
        // EIP-7002 / EIP-7251: a Prague block is invalid when the predeploy
        // has no code. Dev chains that never deployed it opt out.
        if (mode == .checked and require_system_contracts) return error.SystemContractMissingCode;
        return null;
    }

    const adapter = host_adapter.HostAdapter.fromHostInterface(host_iface);
    if (adapter) |a| a.clearHostError();

    const system_account_existed = accountIsCached(sm, SYSTEM_ADDRESS);

    try sm.checkpoint();
    var settled = false;
    errdefer if (!settled) sm.revert();

    const EvmType = guillotine_mini.Evm(.{});
    var evm: EvmType = undefined;
    try evm.init(
        allocator,
        host_iface,
        hardfork,
        block_ctx,
        SYSTEM_ADDRESS,
        0,
        null,
    );
    defer evm.deinit();
    evm.setBytecode(code);

    var result = evm.call(.{ .call = .{
        .caller = SYSTEM_ADDRESS,
        .to = to,
        .value = 0,
        .input = input,
        .gas = SYSTEM_CALL_GAS_LIMIT,
    } }).toOwnedResult(allocator) catch return error.OutOfMemory;
    defer result.deinit(allocator);

    if (adapter) |a| {
        if (a.takeHostError() != null) return error.SystemContractHostError;
    }
    if (!result.success) {
        // guillotine-mini reports allocation failure as a failed call tagged
        // with the error name. That is a node fault: it must neither
        // invalidate the block (`.checked`) nor be dropped (`.unchecked`).
        if (result.error_info) |info| {
            if (std.mem.eql(u8, info, @errorName(error.OutOfMemory))) return error.OutOfMemory;
        }
        if (mode == .checked) return error.SystemContractCallFailed;
        sm.revert();
        settled = true;
        return null;
    }

    const output = try allocator.dupe(u8, result.output);
    sm.commit();
    settled = true;

    // A system call must not leave its caller behind. If executing the call
    // created an empty SYSTEM_ADDRESS account, EIP-161 deletes it; without
    // this an importer that snapshots empty accounts after the call would
    // keep it in the state trie.
    if (!system_account_existed and cachedAccountIsEmpty(sm, SYSTEM_ADDRESS)) {
        removeCachedAccount(sm, SYSTEM_ADDRESS);
    }
    return output;
}

fn accountIsCached(sm: *state_manager.StateManager, address: primitives.Address) bool {
    return sm.journaled_state.account_cache.has(address) or
        sm.journaled_state.contract_cache.cache.contains(address) or
        sm.journaled_state.storage_cache.cache.contains(address);
}

fn removeCachedAccount(sm: *state_manager.StateManager, address: primitives.Address) void {
    _ = sm.journaled_state.account_cache.delete(address);
    _ = sm.journaled_state.contract_cache.delete(address);
    if (sm.journaled_state.storage_cache.cache.fetchRemove(address)) |entry| {
        var slots = entry.value;
        slots.deinit();
    }
}

pub fn computeRequestsHash(requests: RequestsByType) [32]u8 {
    var hashes: [96]u8 = undefined;
    var len: usize = 0;

    appendRequestTypeHash(&hashes, &len, DEPOSIT_REQUEST_TYPE, requests.deposits);
    appendRequestTypeHash(&hashes, &len, WITHDRAWAL_REQUEST_TYPE, requests.withdrawals);
    appendRequestTypeHash(&hashes, &len, CONSOLIDATION_REQUEST_TYPE, requests.consolidations);

    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(hashes[0..len], &out, .{});
    return out;
}

pub fn computeHeaderHashWithRequestsHash(
    allocator: std.mem.Allocator,
    header: *const primitives.BlockHeader.BlockHeader,
    requests_hash: ?[32]u8,
) ![32]u8 {
    const encoded = if (requests_hash) |hash|
        try encodeHeaderWithRequestsHash(allocator, header, hash)
    else
        try primitives.BlockHeader.rlpEncode(header, allocator);
    defer allocator.free(encoded);

    var out: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(encoded, &out, .{});
    return out;
}

fn appendRequestTypeHash(hashes: *[96]u8, len: *usize, request_type: u8, request_data: []const u8) void {
    if (request_data.len == 0) return;

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&.{request_type});
    hasher.update(request_data);
    hasher.final(hashes[len.*..][0..32]);
    len.* += 32;
}

pub fn blockRewardWei(fork: Hardfork) ?u256 {
    return switch (fork) {
        .frontier, .homestead, .spurious_dragon => 5 * WEI_PER_ETHER,
        .byzantium => 3 * WEI_PER_ETHER,
        .constantinople, .istanbul, .berlin, .london => 2 * WEI_PER_ETHER,
        .paris, .shanghai, .cancun, .prague, .osaka => null,
    };
}

pub fn applyMinerReward(sm: *state_manager.StateManager, beneficiary: primitives.Address, fork: Hardfork) !void {
    try applyBlockRewards(sm, beneficiary, &.{}, 0, fork);
}

pub fn applyBlockRewards(
    sm: *state_manager.StateManager,
    beneficiary: primitives.Address,
    ommers: []const primitives.BlockBody.UncleHeader,
    block_number: u64,
    fork: Hardfork,
) !void {
    const reward = blockRewardWei(fork) orelse return;
    const inclusion_reward = std.math.mul(u256, reward / 32, @as(u256, @intCast(ommers.len))) catch return error.BalanceOverflow;
    try addBalance(sm, beneficiary, std.math.add(u256, reward, inclusion_reward) catch return error.BalanceOverflow);

    for (ommers) |ommer| {
        // Subtract instead of adding to `ommer.number`: `ommer.number + 8`
        // overflows u64 near the top of the range. The Yellow Paper limits
        // an ommer to six generations.
        if (ommer.number >= block_number) return error.InvalidOmmerReward;
        const distance = block_number - ommer.number;
        if (distance > 6) return error.InvalidOmmerReward;
        const numerator: u256 = 8 - distance;
        const ommer_reward = (reward * numerator) / 8;
        try addBalance(sm, ommer.beneficiary, ommer_reward);
    }
}

fn addBalance(sm: *state_manager.StateManager, address: primitives.Address, amount: u256) !void {
    const balance = try sm.getBalance(address);
    const next = std.math.add(u256, balance, amount) catch return error.BalanceOverflow;
    try sm.setBalance(address, next);
}

fn appendAccountTrieEntry(
    allocator: std.mem.Allocator,
    keys: *std.ArrayList([]const u8),
    values: *std.ArrayList([]const u8),
    address: primitives.Address,
    nonce: u64,
    balance: u256,
    storage_root: [32]u8,
    code_hash: [32]u8,
) !void {
    const account = primitives.AccountState.AccountState.from(.{
        .nonce = nonce,
        .balance = balance,
        .storage_root = storage_root,
        .code_hash = code_hash,
    });

    const key = try allocator.dupe(u8, address.bytes[0..]);
    var key_owned = true;
    errdefer if (key_owned) allocator.free(key);
    const value = try account.rlpEncode(allocator);
    var value_owned = true;
    errdefer if (value_owned) allocator.free(value);

    try keys.append(allocator, key);
    key_owned = false;
    try values.append(allocator, value);
    value_owned = false;
}

fn computeAccountStorageRoot(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    address: primitives.Address,
    fallback_root: [32]u8,
) ![32]u8 {
    const slots = sm.journaled_state.storage_cache.cache.getPtr(address) orelse return normalizedStorageRoot(fallback_root);

    var keys = std.ArrayList([]const u8){};
    defer {
        for (keys.items) |key| allocator.free(key);
        keys.deinit(allocator);
    }
    var values = std.ArrayList([]const u8){};
    defer {
        for (values.items) |value| allocator.free(value);
        values.deinit(allocator);
    }

    var it = slots.iterator();
    while (it.next()) |entry| {
        const value = entry.value_ptr.*;
        if (value == 0) continue;

        var slot_bytes: [32]u8 = undefined;
        std.mem.writeInt(u256, &slot_bytes, entry.key_ptr.*, .big);
        const key = try allocator.dupe(u8, slot_bytes[0..]);
        var key_owned = true;
        errdefer if (key_owned) allocator.free(key);
        const encoded_value = try primitives.Rlp.encode(allocator, value);
        var value_owned = true;
        errdefer if (value_owned) allocator.free(encoded_value);

        try keys.append(allocator, key);
        key_owned = false;
        try values.append(allocator, encoded_value);
        value_owned = false;
    }

    if (keys.items.len == 0) return primitives.State.EMPTY_TRIE_ROOT;
    return try primitives.TrieHash.secure_trie_root(allocator, keys.items, values.items);
}

fn computeAccountCodeHash(
    sm: *state_manager.StateManager,
    address: primitives.Address,
    fallback_hash: [32]u8,
) [32]u8 {
    if (sm.journaled_state.contract_cache.get(address)) |code| {
        if (code.len == 0) return primitives.State.EMPTY_CODE_HASH;
        var code_hash: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(code, &code_hash, .{});
        return code_hash;
    }

    return normalizedCodeHash(fallback_hash);
}

fn normalizedStorageRoot(root: [32]u8) [32]u8 {
    if (std.mem.eql(u8, &root, &primitives.Hash.ZERO)) return primitives.State.EMPTY_TRIE_ROOT;
    return root;
}

fn normalizedCodeHash(hash: [32]u8) [32]u8 {
    if (std.mem.eql(u8, &hash, &primitives.Hash.ZERO)) return primitives.State.EMPTY_CODE_HASH;
    return hash;
}

/// Named-fork baseline blob gas cap ignoring BPO entries. Callers with a
/// block timestamp should use `blob_fee.resolveBlobParams` or `blobParamsForFork`.
pub fn maxBlobGasPerBlock(fork: Hardfork) ?u64 {
    if (!atLeast(fork, .cancun)) return null;
    var named = hardfork_schedule.MAINNET_CHAIN_CONFIG;
    named.blob_schedule = hardfork_schedule.BlobSchedule.empty;
    return blob_fee.blobParamsForFork(named, evmHardforkFromBlockBuilderFork(fork), 0).max_blob_gas;
}

/// Named-fork excess blob gas without a parent base fee (EIP-4844/EIP-7691
/// callers). Osaka+ callers with a parent base fee and BPO schedule should use
/// `blob_fee.calcExcessBlobGas` or `blob_fee.nextExcessBlobGasForHeader`.
pub fn calculateExcessBlobGasForFork(fork: Hardfork, parent_excess_blob_gas: u64, parent_blob_gas_used: u64) u64 {
    var named = hardfork_schedule.MAINNET_CHAIN_CONFIG;
    named.blob_schedule = hardfork_schedule.BlobSchedule.empty;
    const evm_fork = evmHardforkFromBlockBuilderFork(fork);
    const params = blob_fee.blobParamsForFork(named, evm_fork, 0);
    return blob_fee.calcExcessBlobGas(evm_fork, params, parent_excess_blob_gas, parent_blob_gas_used, 0);
}

fn validateWithdrawalsRoot(
    allocator: std.mem.Allocator,
    header: *const primitives.BlockHeader.BlockHeader,
    withdrawals: ?[]const primitives.BlockBody.Withdrawal,
    fork: Hardfork,
) !?[32]u8 {
    if (!atLeast(fork, .shanghai)) {
        if (withdrawals != null) return error.WithdrawalsBeforeShanghai;
        if (header.withdrawals_root != null) return error.WithdrawalsRootBeforeShanghai;
        return null;
    }

    const actual_withdrawals = withdrawals orelse return error.MissingWithdrawals;
    const expected_root = try computeWithdrawalsRoot(allocator, actual_withdrawals);
    const header_root = header.withdrawals_root orelse return error.MissingWithdrawalsRoot;
    if (!std.mem.eql(u8, &expected_root, &header_root)) return error.InvalidWithdrawalsRoot;
    return expected_root;
}

fn validateBlobGas(
    header: *const primitives.BlockHeader.BlockHeader,
    parent: *const primitives.BlockHeader.BlockHeader,
    receipts: []const primitives.Receipt.Receipt,
    fork: Hardfork,
    config: hardfork_schedule.ChainConfig,
) !u64 {
    const actual_blob_gas = try blobGasUsedFromReceipts(receipts);

    if (!atLeast(fork, .cancun)) {
        if (actual_blob_gas != 0) return error.BlobGasBeforeCancun;
        if (header.blob_gas_used != null or header.excess_blob_gas != null) return error.BlobFieldsBeforeCancun;
        return 0;
    }

    const header_blob_gas = header.blob_gas_used orelse return error.MissingBlobGasUsed;
    if (header_blob_gas != actual_blob_gas) return error.InvalidBlobGasUsed;

    const evm_fork = evmHardforkFromBlockBuilderFork(fork);
    const params = blob_fee.blobParamsForFork(config, evm_fork, header.timestamp);
    if (actual_blob_gas > params.max_blob_gas) return error.BlobGasLimitExceeded;

    const header_excess = header.excess_blob_gas orelse return error.MissingExcessBlobGas;
    const expected_excess = blob_fee.calcExcessBlobGas(
        evm_fork,
        params,
        parent.excess_blob_gas orelse 0,
        parent.blob_gas_used orelse 0,
        parent.base_fee_per_gas orelse 0,
    );
    if (header_excess != expected_excess) return error.InvalidExcessBlobGas;

    return actual_blob_gas;
}

fn receiptGasUsed(receipts: []const primitives.Receipt.Receipt) !u64 {
    if (receipts.len == 0) return 0;
    return std.math.cast(u64, receipts[receipts.len - 1].cumulative_gas_used) orelse error.GasOverflow;
}

fn blobGasUsedFromReceipts(receipts: []const primitives.Receipt.Receipt) !u64 {
    var total: u64 = 0;
    for (receipts) |receipt| {
        total = std.math.add(u64, total, try receiptBlobGasUsed(receipt)) catch return error.BlobGasOverflow;
    }
    return total;
}

fn executionTxBlobGasUsed(tx: tx_processor.ExecutionTx) !u64 {
    const blob_gas = tx.blob_gas_used orelse return 0;
    return std.math.cast(u64, blob_gas) orelse error.BlobGasOverflow;
}

fn receiptBlobGasUsed(receipt: primitives.Receipt.Receipt) !u64 {
    const blob_gas = receipt.blob_gas_used orelse return 0;
    return std.math.cast(u64, blob_gas) orelse error.BlobGasOverflow;
}

pub fn encodeReceiptEnvelope(
    allocator: std.mem.Allocator,
    receipt: primitives.Receipt.Receipt,
) ![]u8 {
    const type_byte: ?u8 = switch (receipt.type) {
        .legacy => null,
        .eip2930 => 0x01,
        .eip1559 => 0x02,
        .eip4844 => 0x03,
        .eip7702 => 0x04,
    };

    const status_or_root_len: usize = if (receipt.root != null)
        33 // 0xa0 + 32 bytes
    else if (receipt.status != null)
        1 // 0x80 (0) or 0x01 (1)
    else
        return error.InvalidReceipt;

    const cum_gas_len = rlpUintEncodedLen(receipt.cumulative_gas_used);
    const bloom_len: usize = 3 + 256; // 0xb9, 0x01, 0x00 + 256 bytes

    var logs_payload_len: usize = 0;
    for (receipt.logs) |event_log| {
        const topics_payload_len = event_log.topics.len * 33;
        const topics_item_len = rlpListEncodedLen(topics_payload_len);
        const log_payload_len = 21 + topics_item_len + rlpBytesEncodedLen(event_log.data);
        logs_payload_len += rlpListEncodedLen(log_payload_len);
    }
    const logs_item_len = rlpListEncodedLen(logs_payload_len);

    const receipt_payload_len = status_or_root_len + cum_gas_len + bloom_len + logs_item_len;
    const receipt_rlp_len = rlpListEncodedLen(receipt_payload_len);
    const prefix_len: usize = if (type_byte != null) 1 else 0;

    const out = try allocator.alloc(u8, prefix_len + receipt_rlp_len);
    var pos: usize = 0;
    if (type_byte) |byte| {
        out[pos] = byte;
        pos += 1;
    }

    pos = writeRlpListHeader(out, pos, receipt_payload_len);
    if (receipt.root) |root| {
        pos = writeRlpBytes(out, pos, &root);
    } else if (receipt.status) |status| {
        out[pos] = if (status.success) 0x01 else 0x80;
        pos += 1;
    } else unreachable;

    pos = writeRlpUint(out, pos, receipt.cumulative_gas_used);
    pos = writeRlpBytes(out, pos, &receipt.logs_bloom);

    pos = writeRlpListHeader(out, pos, logs_payload_len);
    for (receipt.logs) |event_log| {
        const topics_payload_len = event_log.topics.len * 33;
        const topics_item_len = rlpListEncodedLen(topics_payload_len);
        const log_payload_len = 21 + topics_item_len + rlpBytesEncodedLen(event_log.data);
        pos = writeRlpListHeader(out, pos, log_payload_len);
        pos = writeRlpBytes(out, pos, &event_log.address.bytes);
        pos = writeRlpListHeader(out, pos, topics_payload_len);
        for (event_log.topics) |topic| {
            pos = writeRlpBytes(out, pos, &topic);
        }
        pos = writeRlpBytes(out, pos, event_log.data);
    }

    std.debug.assert(pos == out.len);
    return out;
}

fn rlpLengthPrefixBytes(len: usize) usize {
    if (len < 56) return 1;
    return 1 + ((@bitSizeOf(usize) - @clz(len) + 7) / 8);
}

fn rlpListEncodedLen(payload_len: usize) usize {
    return rlpLengthPrefixBytes(payload_len) + payload_len;
}

fn rlpBytesEncodedLen(bytes: []const u8) usize {
    if (bytes.len == 1 and bytes[0] < 0x80) return 1;
    return rlpLengthPrefixBytes(bytes.len) + bytes.len;
}

fn rlpUintEncodedLen(value: anytype) usize {
    if (value == 0 or value < 0x80) return 1;
    const bit_len: usize = @bitSizeOf(@TypeOf(value)) - @as(usize, @clz(value));
    return 1 + (bit_len + 7) / 8;
}

fn writeRlpHeader(out: []u8, pos: usize, payload_len: usize, short_base: u8, long_base: u8) usize {
    if (payload_len < 56) {
        out[pos] = short_base + @as(u8, @intCast(payload_len));
        return pos + 1;
    }
    const len_bytes: usize = (@bitSizeOf(usize) - @clz(payload_len) + 7) / 8;
    out[pos] = long_base + @as(u8, @intCast(len_bytes));
    var i: usize = 0;
    while (i < len_bytes) : (i += 1) {
        const shift: std.math.Log2Int(usize) = @intCast((len_bytes - 1 - i) * 8);
        out[pos + 1 + i] = @truncate(payload_len >> shift);
    }
    return pos + 1 + len_bytes;
}

fn writeRlpListHeader(out: []u8, pos: usize, payload_len: usize) usize {
    return writeRlpHeader(out, pos, payload_len, 0xc0, 0xf7);
}

fn writeRlpBytes(out: []u8, pos: usize, bytes: []const u8) usize {
    if (bytes.len == 1 and bytes[0] < 0x80) {
        out[pos] = bytes[0];
        return pos + 1;
    }
    const p = writeRlpHeader(out, pos, bytes.len, 0x80, 0xb7);
    if (bytes.len > 0) @memcpy(out[p .. p + bytes.len], bytes);
    return p + bytes.len;
}

fn writeRlpUint(out: []u8, pos: usize, value: anytype) usize {
    if (value == 0) {
        out[pos] = 0x80;
        return pos + 1;
    }
    if (value < 0x80) {
        out[pos] = @intCast(value);
        return pos + 1;
    }
    const T = @TypeOf(value);
    const bit_len: usize = @bitSizeOf(T) - @as(usize, @clz(value));
    const byte_len: usize = (bit_len + 7) / 8;
    out[pos] = 0x80 + @as(u8, @intCast(byte_len));
    var i: usize = 0;
    while (i < byte_len) : (i += 1) {
        const shift: std.math.Log2Int(T) = @intCast((byte_len - 1 - i) * 8);
        out[pos + 1 + i] = @truncate(value >> shift);
    }
    return pos + 1 + byte_len;
}

fn encodeWithdrawal(
    allocator: std.mem.Allocator,
    withdrawal: primitives.BlockBody.Withdrawal,
) ![]u8 {
    var fields = std.ArrayList([]u8){};
    defer freeEncodedFields(allocator, &fields);

    try fields.append(allocator, try primitives.Rlp.encode(allocator, withdrawal.index));
    try fields.append(allocator, try primitives.Rlp.encode(allocator, withdrawal.validator_index));
    try fields.append(allocator, try primitives.Rlp.encodeBytes(allocator, &withdrawal.address.bytes));
    try fields.append(allocator, try primitives.Rlp.encode(allocator, withdrawal.amount));

    return encodeRlpListFromEncodedFields(allocator, fields.items);
}

fn encodeHeaderWithRequestsHash(
    allocator: std.mem.Allocator,
    header: *const primitives.BlockHeader.BlockHeader,
    requests_hash: [32]u8,
) ![]u8 {
    var fields = std.ArrayList([]u8){};
    defer freeEncodedFields(allocator, &fields);

    try fields.append(allocator, try primitives.Rlp.encodeBytes(allocator, &header.parent_hash));
    try fields.append(allocator, try primitives.Rlp.encodeBytes(allocator, &header.ommers_hash));
    try fields.append(allocator, try primitives.Rlp.encodeBytes(allocator, &header.beneficiary.bytes));
    try fields.append(allocator, try primitives.Rlp.encodeBytes(allocator, &header.state_root));
    try fields.append(allocator, try primitives.Rlp.encodeBytes(allocator, &header.transactions_root));
    try fields.append(allocator, try primitives.Rlp.encodeBytes(allocator, &header.receipts_root));
    try fields.append(allocator, try primitives.Rlp.encodeBytes(allocator, &header.logs_bloom));
    try fields.append(allocator, try primitives.Rlp.encode(allocator, header.difficulty));
    try fields.append(allocator, try primitives.Rlp.encode(allocator, header.number));
    try fields.append(allocator, try primitives.Rlp.encode(allocator, header.gas_limit));
    try fields.append(allocator, try primitives.Rlp.encode(allocator, header.gas_used));
    try fields.append(allocator, try primitives.Rlp.encode(allocator, header.timestamp));
    try fields.append(allocator, try primitives.Rlp.encodeBytes(allocator, header.extra_data));
    try fields.append(allocator, try primitives.Rlp.encodeBytes(allocator, &header.mix_hash));
    try fields.append(allocator, try primitives.Rlp.encodeBytes(allocator, &header.nonce));
    try fields.append(allocator, try primitives.Rlp.encode(allocator, header.base_fee_per_gas orelse return error.MissingBaseFeePerGas));
    const withdrawals_root = header.withdrawals_root orelse return error.MissingWithdrawalsRoot;
    try fields.append(allocator, try primitives.Rlp.encodeBytes(allocator, &withdrawals_root));
    try fields.append(allocator, try primitives.Rlp.encode(allocator, header.blob_gas_used orelse return error.MissingBlobGasUsed));
    try fields.append(allocator, try primitives.Rlp.encode(allocator, header.excess_blob_gas orelse return error.MissingExcessBlobGas));
    const parent_beacon_block_root = header.parent_beacon_block_root orelse return error.MissingParentBeaconBlockRoot;
    try fields.append(allocator, try primitives.Rlp.encodeBytes(allocator, &parent_beacon_block_root));
    try fields.append(allocator, try primitives.Rlp.encodeBytes(allocator, &requests_hash));

    return encodeRlpListFromEncodedFields(allocator, fields.items);
}

fn encodeRlpListFromEncodedFields(
    allocator: std.mem.Allocator,
    fields: []const []const u8,
) ![]u8 {
    var total_len: usize = 0;
    for (fields) |field| {
        total_len = std.math.add(usize, total_len, field.len) catch return error.RlpPayloadTooLarge;
    }

    var result = std.ArrayList(u8){};
    defer result.deinit(allocator);

    if (total_len < 56) {
        try result.append(allocator, 0xc0 + @as(u8, @intCast(total_len)));
    } else {
        const len_bytes = try primitives.Rlp.encodeLength(allocator, total_len);
        defer allocator.free(len_bytes);
        try result.append(allocator, 0xf7 + @as(u8, @intCast(len_bytes.len)));
        try result.appendSlice(allocator, len_bytes);
    }

    for (fields) |field| {
        try result.appendSlice(allocator, field);
    }

    return try result.toOwnedSlice(allocator);
}

fn freeEncodedFields(allocator: std.mem.Allocator, fields: *std.ArrayList([]u8)) void {
    for (fields.items) |field| {
        allocator.free(field);
    }
    fields.deinit(allocator);
}

fn hasAnyRequests(requests: RequestsByType) bool {
    return requests.deposits.len != 0 or requests.withdrawals.len != 0 or requests.consolidations.len != 0;
}

/// Requests produced by execution take precedence. A caller-supplied payload
/// is used only for a type execution produced nothing for.
fn requestsWithPragueSystemOutputs(base: RequestsByType, system: PragueSystemRequests) RequestsByType {
    return .{
        .deposits = if (system.deposits) |bytes| bytes else base.deposits,
        .withdrawals = if (system.withdrawals) |bytes| bytes else base.withdrawals,
        .consolidations = if (system.consolidations) |bytes| bytes else base.consolidations,
    };
}

fn effectiveBlockBuilderFork(options: BuildBlockOptions, block_ctx: guillotine_mini.BlockContext) Hardfork {
    if (options.hardfork_config) |config| {
        return hardforkFromEvm(tx_processor.resolveHardforkWithConfig(config, block_ctx));
    }
    return options.fork;
}

fn evmHardforkFromBlockBuilderFork(fork: Hardfork) guillotine_mini.Hardfork {
    return switch (fork) {
        .frontier => .FRONTIER,
        .homestead => .HOMESTEAD,
        .spurious_dragon => .SPURIOUS_DRAGON,
        .byzantium => .BYZANTIUM,
        .constantinople => .CONSTANTINOPLE,
        .istanbul => .ISTANBUL,
        .berlin => .BERLIN,
        .london => .LONDON,
        .paris => .MERGE,
        .shanghai => .SHANGHAI,
        .cancun => .CANCUN,
        .prague => .PRAGUE,
        .osaka => .OSAKA,
    };
}

/// Map an EVM hardfork to the block-rule fork that governs it.
pub fn hardforkFromEvm(fork: guillotine_mini.Hardfork) Hardfork {
    if (fork.isAtLeast(.OSAKA)) return .osaka;
    if (fork.isAtLeast(.PRAGUE)) return .prague;
    if (fork.isAtLeast(.CANCUN)) return .cancun;
    if (fork.isAtLeast(.SHANGHAI)) return .shanghai;
    if (fork.isAtLeast(.MERGE)) return .paris;
    if (fork.isAtLeast(.LONDON)) return .london;
    if (fork.isAtLeast(.BERLIN)) return .berlin;
    if (fork.isAtLeast(.ISTANBUL)) return .istanbul;
    if (fork.isAtLeast(.CONSTANTINOPLE)) return .constantinople;
    if (fork.isAtLeast(.BYZANTIUM)) return .byzantium;
    if (fork.isAtLeast(.SPURIOUS_DRAGON)) return .spurious_dragon;
    if (fork.isAtLeast(.HOMESTEAD)) return .homestead;
    return .frontier;
}

fn atLeast(fork: Hardfork, minimum: Hardfork) bool {
    return @intFromEnum(fork) >= @intFromEnum(minimum);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn testReceipt(logs: []const primitives.EventLog.EventLog) primitives.Receipt.Receipt {
    return .{
        .transaction_hash = [_]u8{0x11} ** 32,
        .transaction_index = 0,
        .block_hash = primitives.Hash.ZERO,
        .block_number = 1,
        .sender = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 },
        .to = null,
        .cumulative_gas_used = 21_000,
        .gas_used = 21_000,
        .contract_address = null,
        .logs = logs,
        .logs_bloom = [_]u8{0} ** 256,
        .status = .{ .success = true, .gas_used = 21_000 },
        .root = null,
        .effective_gas_price = 1,
        .type = .legacy,
        .blob_gas_used = null,
        .blob_gas_price = null,
    };
}

fn testLog(address: primitives.Address, topics: []const [32]u8, data: []const u8) primitives.EventLog.EventLog {
    return .{
        .address = address,
        .topics = topics,
        .data = data,
        .block_number = null,
        .transaction_hash = null,
        .transaction_index = null,
        .log_index = null,
        .removed = false,
    };
}

/// A well-formed `DepositEvent` payload whose five fields are filled with
/// `seed`, `seed + 1`, ... so each one is recognisable in the request.
fn testDepositEventData(seed: u8) [DEPOSIT_EVENT_DATA_SIZE]u8 {
    var data = [_]u8{0} ** DEPOSIT_EVENT_DATA_SIZE;
    const offsets = [_]usize{ 160, 256, 320, 384, 512 };
    const sizes = [_]usize{ 48, 32, 8, 96, 8 };
    for (offsets, sizes, 0..) |offset, size, index| {
        std.mem.writeInt(u256, data[index * 32 ..][0..32], offset, .big);
        std.mem.writeInt(u256, data[offset..][0..32], size, .big);
        @memset(data[offset + 32 ..][0..size], seed + @as(u8, @intCast(index)));
    }
    return data;
}

fn testHeaders() struct { parent: primitives.BlockHeader.BlockHeader, child: primitives.BlockHeader.BlockHeader } {
    const parent = primitives.BlockHeader.BlockHeader{
        .ommers_hash = primitives.BlockHeader.EMPTY_OMMERS_HASH,
        .transactions_root = primitives.BlockHeader.EMPTY_TRANSACTIONS_ROOT,
        .receipts_root = primitives.BlockHeader.EMPTY_RECEIPTS_ROOT,
        .number = 10,
        .gas_limit = 30_000_000,
        .gas_used = 15_000_000,
        .timestamp = 1000,
        .base_fee_per_gas = 1_000_000_000,
    };
    var child = parent;
    child.number = 11;
    child.gas_used = 0;
    child.timestamp = 1001;
    return .{ .parent = parent, .child = child };
}

test "DEPOSIT_EVENT_TOPIC is the keccak256 of the event signature" {
    var expected: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash("DepositEvent(bytes,bytes,bytes,bytes,bytes)", &expected, .{});
    try std.testing.expectEqualSlices(u8, &expected, &DEPOSIT_EVENT_TOPIC);

    const address = try primitives.Address.fromHex("0x00000000219ab540356cBB839Cbe05303d7705Fa");
    try std.testing.expectEqualSlices(u8, &address.bytes, &DEPOSIT_CONTRACT_ADDRESS.bytes);
}

test "extractDepositRequests reads deposit contract logs in order and ignores other logs" {
    const allocator = std.testing.allocator;
    const first = testDepositEventData(0x10);
    const second = testDepositEventData(0x20);
    const topics = [_][32]u8{DEPOSIT_EVENT_TOPIC};
    const other_topics = [_][32]u8{[_]u8{0x99} ** 32};
    const other_address = primitives.Address{ .bytes = [_]u8{0xab} ** 20 };

    const logs_a = [_]primitives.EventLog.EventLog{
        // Same topic from another contract, and another event from the
        // deposit contract: neither is a deposit.
        testLog(other_address, &topics, &first),
        testLog(DEPOSIT_CONTRACT_ADDRESS, &other_topics, &first),
        testLog(DEPOSIT_CONTRACT_ADDRESS, &topics, &first),
    };
    const logs_b = [_]primitives.EventLog.EventLog{testLog(DEPOSIT_CONTRACT_ADDRESS, &topics, &second)};
    const receipts = [_]primitives.Receipt.Receipt{ testReceipt(&logs_a), testReceipt(&logs_b) };

    const deposits = (try extractDepositRequests(allocator, &receipts)).?;
    defer allocator.free(deposits);
    try std.testing.expectEqual(2 * DEPOSIT_REQUEST_SIZE, deposits.len);

    // pubkey || withdrawal_credentials || amount || signature || index.
    const expected_first = [_]u8{0x10} ** 48 ++ [_]u8{0x11} ** 32 ++ [_]u8{0x12} ** 8 ++ [_]u8{0x13} ** 96 ++ [_]u8{0x14} ** 8;
    try std.testing.expectEqualSlices(u8, &expected_first, deposits[0..DEPOSIT_REQUEST_SIZE]);
    try std.testing.expectEqual(@as(u8, 0x20), deposits[DEPOSIT_REQUEST_SIZE]);
    try std.testing.expectEqual(@as(u8, 0x24), deposits[deposits.len - 1]);

    const none = [_]primitives.Receipt.Receipt{testReceipt(logs_a[0..2])};
    try std.testing.expectEqual(@as(?[]u8, null), try extractDepositRequests(allocator, &none));
}

test "extractDepositRequests rejects a deposit log with a malformed layout" {
    const allocator = std.testing.allocator;
    const topics = [_][32]u8{DEPOSIT_EVENT_TOPIC};

    var wrong_offset = testDepositEventData(0x10);
    wrong_offset[31] = 0xa1;
    var wrong_size = testDepositEventData(0x10);
    wrong_size[160 + 31] = 49;
    const good = testDepositEventData(0x10);

    for ([_][]const u8{ &wrong_offset, &wrong_size, good[0 .. good.len - 1] }) |data| {
        const logs = [_]primitives.EventLog.EventLog{testLog(DEPOSIT_CONTRACT_ADDRESS, &topics, data)};
        const receipts = [_]primitives.Receipt.Receipt{testReceipt(&logs)};
        try std.testing.expectError(error.InvalidDepositEventLayout, extractDepositRequests(allocator, &receipts));
    }
}

test "computeRequestsHashFromRawRequests sorts by type and skips empty requests" {
    const allocator = std.testing.allocator;
    const expected = computeRequestsHash(.{ .deposits = "a", .consolidations = "c" });

    const unsorted = [_][]const u8{ &.{ 0x02, 'c' }, &.{}, &.{0x01}, &.{ 0x00, 'a' } };
    try std.testing.expectEqualSlices(u8, &expected, &(try computeRequestsHashFromRawRequests(allocator, &unsorted)));

    const encoded = try encodeExecutionRequests(allocator, .{ .deposits = "a", .consolidations = "c" });
    defer freeExecutionRequests(allocator, encoded);
    try std.testing.expectEqual(@as(usize, 2), encoded.len);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 'a' }, encoded[0]);
    try std.testing.expectEqualSlices(u8, &.{ 0x02, 'c' }, encoded[1]);
    try std.testing.expectEqualSlices(u8, &expected, &(try computeRequestsHashFromRawRequests(allocator, encoded)));

    // No requests commits to sha256("").
    var empty: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("", &empty, .{});
    try std.testing.expectEqualSlices(u8, &empty, &(try computeRequestsHashFromRawRequests(allocator, &.{})));
}

test "system calls write nothing when the system address has no code" {
    const allocator = std.testing.allocator;
    var sm = try state_manager.StateManager.init(allocator, null);
    defer sm.deinit();

    const funded = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 };
    try sm.setBalance(funded, 1);
    const root_before = try computeStateRoot(allocator, &sm);

    const word = [_]u8{0x42} ** 32;
    try applyBeaconRootsSystemCall(&sm, 8193, word);
    try applyHistoricalBlockHashSystemCall(&sm, 8193, word);

    const requests = try collectBlockExecutionRequests(allocator, &sm, &.{}, .prague, systemCallBlockContext());
    defer freeExecutionRequests(allocator, requests);
    try std.testing.expectEqual(@as(usize, 0), requests.len);

    // No phantom account or storage entered the state trie.
    try std.testing.expectEqualSlices(u8, &root_before, &(try computeStateRoot(allocator, &sm)));
    try std.testing.expectEqual(@as(u256, 0), try sm.getStorage(BEACON_ROOTS_ADDRESS, 8193 % 8191));
    try std.testing.expectEqual(@as(u256, 0), try sm.getStorage(HISTORY_STORAGE_ADDRESS, 8192 % 8191));
}

test "system calls execute deployed code as SYSTEM_ADDRESS" {
    const allocator = std.testing.allocator;
    var sm = try state_manager.StateManager.init(allocator, null);
    defer sm.deinit();

    // sstore(0, calldataload(0)); sstore(1, caller()); stop
    const store_input = [_]u8{ 0x60, 0x00, 0x35, 0x60, 0x00, 0x55, 0x33, 0x60, 0x01, 0x55, 0x00 };
    // sstore(0, 1); revert(0, 0)
    const reverting = [_]u8{ 0x60, 0x01, 0x60, 0x00, 0x55, 0x60, 0x00, 0x60, 0x00, 0xfd };
    // mstore8(0, 0xaa); return(0, 1)
    const one_byte = [_]u8{ 0x60, 0xaa, 0x60, 0x00, 0x53, 0x60, 0x01, 0x60, 0x00, 0xf3 };

    const word = [_]u8{0x42} ** 32;
    try sm.setCode(BEACON_ROOTS_ADDRESS, &store_input);
    try applyBeaconRootsSystemCall(&sm, 8193, word);
    try std.testing.expectEqual(std.mem.readInt(u256, &word, .big), try sm.getStorage(BEACON_ROOTS_ADDRESS, 0));
    try std.testing.expectEqual(
        @as(u256, std.mem.readInt(u160, &SYSTEM_ADDRESS.bytes, .big)),
        try sm.getStorage(BEACON_ROOTS_ADDRESS, 1),
    );
    // The caller is not left behind as an account.
    try std.testing.expect(!accountIsCached(&sm, SYSTEM_ADDRESS));

    // EIP-2935: a reverting call is ignored and leaves no state behind.
    try sm.setCode(HISTORY_STORAGE_ADDRESS, &reverting);
    try applyHistoricalBlockHashSystemCall(&sm, 5, word);
    try std.testing.expectEqual(@as(u256, 0), try sm.getStorage(HISTORY_STORAGE_ADDRESS, 0));

    // EIP-7002: the call output becomes the type-0x01 request, after deposits.
    try sm.setCode(WITHDRAWAL_REQUESTS_ADDRESS, &one_byte);
    const deposit = testDepositEventData(0x10);
    const topics = [_][32]u8{DEPOSIT_EVENT_TOPIC};
    const logs = [_]primitives.EventLog.EventLog{testLog(DEPOSIT_CONTRACT_ADDRESS, &topics, &deposit)};
    const receipts = [_]primitives.Receipt.Receipt{testReceipt(&logs)};

    const requests = try collectBlockExecutionRequests(allocator, &sm, &receipts, .prague, systemCallBlockContext());
    defer freeExecutionRequests(allocator, requests);
    try std.testing.expectEqual(@as(usize, 2), requests.len);
    try std.testing.expectEqual(@as(usize, 1 + DEPOSIT_REQUEST_SIZE), requests[0].len);
    try std.testing.expectEqual(DEPOSIT_REQUEST_TYPE, requests[0][0]);
    try std.testing.expectEqualSlices(u8, &.{ WITHDRAWAL_REQUEST_TYPE, 0xaa }, requests[1]);

    const expected_hash = computeRequestsHash(.{ .deposits = requests[0][1..], .withdrawals = &.{0xaa} });
    try std.testing.expectEqualSlices(u8, &expected_hash, &(try computeRequestsHashFromRawRequests(allocator, requests)));

    // EIP-7251: a failing checked call invalidates the block.
    try sm.setCode(CONSOLIDATION_REQUESTS_ADDRESS, &reverting);
    try std.testing.expectError(
        error.SystemContractCallFailed,
        collectBlockExecutionRequests(allocator, &sm, &.{}, .prague, systemCallBlockContext()),
    );

    // Before Prague there are no requests and no system calls.
    const cancun = try collectBlockExecutionRequests(allocator, &sm, &receipts, .cancun, systemCallBlockContext());
    defer freeExecutionRequests(allocator, cancun);
    try std.testing.expectEqual(@as(usize, 0), cancun.len);
}

test "validateBlock rejects a requests hash that execution does not reproduce" {
    const headers = testHeaders();
    const claimed = [_]u8{0xaa} ** 32;
    const other = [_]u8{0xbb} ** 32;
    var input = BlockValidationInput{
        .header = &headers.child,
        .parent_header = &headers.parent,
        .fork = .prague,
        .requests_hash = claimed,
        .computed_requests_hash = claimed,
    };
    try std.testing.expectEqualSlices(u8, &claimed, &(try validateRequestsHash(input)).?);

    input.computed_requests_hash = other;
    try std.testing.expectError(error.InvalidRequestsHash, validateRequestsHash(input));

    // A Prague block that commits to no hash cannot match a computed one.
    input.requests_hash = null;
    try std.testing.expectError(error.InvalidRequestsHash, validateRequestsHash(input));

    // The side-channel hash must agree with the header's own field.
    var header_with_hash = headers.child;
    header_with_hash.requests_hash = other;
    input.header = &header_with_hash;
    input.requests_hash = claimed;
    input.computed_requests_hash = null;
    try std.testing.expectError(error.InvalidRequestsHash, validateRequestsHash(input));

    // A Prague block must commit to a hash even when nothing was recomputed.
    input.header = &headers.child;
    input.requests_hash = null;
    try std.testing.expectError(error.InvalidRequestsHash, validateRequestsHash(input));

    // Before Prague the field does not exist: committing to one is invalid.
    input.fork = .cancun;
    input.requests_hash = claimed;
    try std.testing.expectError(error.InvalidRequestsHash, validateRequestsHash(input));
    input.header = &header_with_hash;
    input.requests_hash = null;
    try std.testing.expectError(error.InvalidRequestsHash, validateRequestsHash(input));
    try std.testing.expectError(error.InvalidRequestsHash, validateHeader(&header_with_hash, &headers.parent, .cancun));

    // Without a committed hash the recomputed one is ignored.
    input.header = &headers.child;
    input.computed_requests_hash = other;
    try std.testing.expectEqual(@as(?[32]u8, null), try validateRequestsHash(input));
}

test "validateBlock checks parent hash, ommers hash, and the Cancun beacon root" {
    const allocator = std.testing.allocator;
    const headers = testHeaders();
    var child = headers.child;
    child.parent_hash = [_]u8{0x01} ** 32;

    try std.testing.expectError(error.InvalidParentHash, validateBlock(allocator, .{
        .header = &child,
        .parent_header = &headers.parent,
        .parent_hash = [_]u8{0x02} ** 32,
    }));
    try std.testing.expectError(error.InvalidOmmersHash, validateBlock(allocator, .{
        .header = &child,
        .parent_header = &headers.parent,
        .parent_hash = child.parent_hash,
        .ommers_hash = [_]u8{0x03} ** 32,
    }));
    _ = try validateBlock(allocator, .{
        .header = &child,
        .parent_header = &headers.parent,
        .parent_hash = child.parent_hash,
        .ommers_hash = primitives.BlockHeader.EMPTY_OMMERS_HASH,
    });

    try std.testing.expectError(error.MissingParentBeaconBlockRoot, validateBlock(allocator, .{
        .header = &child,
        .parent_header = &headers.parent,
        .fork = .cancun,
    }));
}

test "validateGasLimit is overflow-safe, bounded below, and doubles the parent on the London fork block" {
    const headers = testHeaders();
    var parent = headers.parent;
    var child = headers.child;

    // Strictly less than parent / 1024 in either direction.
    const max_delta = parent.gas_limit / 1024;
    child.gas_limit = parent.gas_limit + max_delta - 1;
    try validateGasLimit(&child, &parent, .paris);
    child.gas_limit = parent.gas_limit + max_delta;
    try std.testing.expectError(error.InvalidGasLimitDelta, validateGasLimit(&child, &parent, .paris));
    child.gas_limit = parent.gas_limit - max_delta;
    try std.testing.expectError(error.InvalidGasLimitDelta, validateGasLimit(&child, &parent, .paris));

    // A parent limit near 2^64 used to trap on `parent + delta`.
    parent.gas_limit = std.math.maxInt(u64);
    child.gas_limit = std.math.maxInt(u64);
    try validateGasLimit(&child, &parent, .paris);

    // Absolute minimum: 4,999 is within the delta of 5,002 and still invalid.
    parent.gas_limit = 5_002;
    child.gas_limit = 4_999;
    try std.testing.expectError(error.InvalidGasLimitDelta, validateGasLimit(&child, &parent, .paris));
    child.gas_limit = 5_000;
    try validateGasLimit(&child, &parent, .paris);

    // London fork block: the parent has no base fee and its limit doubles.
    parent.gas_limit = 15_000_000;
    parent.base_fee_per_gas = null;
    child.gas_limit = 30_000_000;
    try validateGasLimit(&child, &parent, .london);
    try std.testing.expectError(error.InvalidGasLimitDelta, validateGasLimit(&child, &parent, .berlin));
    child.gas_limit = 15_000_000;
    try std.testing.expectError(error.InvalidGasLimitDelta, validateGasLimit(&child, &parent, .london));
    try validateGasLimit(&child, &parent, .berlin);
}

test "zero-amount withdrawals never create an account" {
    const allocator = std.testing.allocator;
    var sm = try state_manager.StateManager.init(allocator, null);
    defer sm.deinit();

    const absent = primitives.Address{ .bytes = [_]u8{0x77} ++ [_]u8{0} ** 19 };
    const paid = primitives.Address{ .bytes = [_]u8{0x78} ++ [_]u8{0} ** 19 };
    const root_before = try computeStateRoot(allocator, &sm);

    try applyWithdrawals(&sm, &.{.{ .index = 1, .validator_index = 2, .address = absent, .amount = 0 }});
    try std.testing.expect(sm.journaled_state.account_cache.get(absent) == null);
    try std.testing.expectEqualSlices(u8, &root_before, &(try computeStateRoot(allocator, &sm)));

    try applyWithdrawals(&sm, &.{
        .{ .index = 2, .validator_index = 2, .address = absent, .amount = 0 },
        .{ .index = 3, .validator_index = 2, .address = paid, .amount = 3 },
    });
    try std.testing.expect(sm.journaled_state.account_cache.get(absent) == null);
    try std.testing.expectEqual(@as(u256, 3_000_000_000), try sm.getBalance(paid));
}

test "EIP-161 pruning is keyed on Spurious Dragon" {
    try std.testing.expect(atLeast(.spurious_dragon, .spurious_dragon));
    try std.testing.expect(atLeast(.byzantium, .spurious_dragon));
    try std.testing.expect(!atLeast(.homestead, .spurious_dragon));
    try std.testing.expectEqual(Hardfork.spurious_dragon, hardforkFromEvm(.SPURIOUS_DRAGON));
    try std.testing.expectEqual(Hardfork.homestead, hardforkFromEvm(.TANGERINE_WHISTLE));
    try std.testing.expectEqual(Hardfork.byzantium, hardforkFromEvm(.BYZANTIUM));
    try std.testing.expectEqual(guillotine_mini.Hardfork.SPURIOUS_DRAGON, evmHardforkFromBlockBuilderFork(.spurious_dragon));
    try std.testing.expectEqual(@as(?u256, 5 * WEI_PER_ETHER), blockRewardWei(.spurious_dragon));
}

test "transaction and withdrawal roots free everything when an allocation fails" {
    const Harness = struct {
        fn rawTransactions(allocator: std.mem.Allocator) !void {
            const transactions = [_]primitives.BlockBody.TransactionData{
                .{ .raw = &.{ 0x02, 0xc0 } },
                .{ .raw = &.{ 0x01, 0xc0 } },
                .{ .raw = &.{ 0xc1, 0x80 } },
            };
            _ = try computeRawTransactionsRoot(allocator, &transactions);
        }

        fn withdrawals(allocator: std.mem.Allocator) !void {
            const recipient = primitives.Address{ .bytes = [_]u8{0x77} ** 20 };
            const items = [_]primitives.BlockBody.Withdrawal{
                .{ .index = 1, .validator_index = 2, .address = recipient, .amount = 3 },
                .{ .index = 2, .validator_index = 3, .address = recipient, .amount = 4 },
            };
            _ = try computeWithdrawalsRoot(allocator, &items);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.rawTransactions, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.withdrawals, .{});
}

test "computeTransactionsRoot commits to the canonical envelope when the transaction carries one" {
    const allocator = std.testing.allocator;
    const typed_envelope = [_]u8{ 0x02, 0xc3, 0x01, 0x80, 0x80 };
    const tx = primitives.Transaction.LegacyTransaction{
        .nonce = 0,
        .gas_price = 1,
        .gas_limit = 21_000,
        .to = null,
        .value = 0,
        .data = &.{},
        .v = 0,
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
    };
    const caller = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 };

    const with_raw = [_]tx_processor.ExecutionTx{.{ .caller = caller, .tx = tx, .receipt_type = .eip1559, .raw = &typed_envelope }};
    const envelopes = [_]primitives.BlockBody.TransactionData{.{ .raw = &typed_envelope }};
    const canonical = try computeRawTransactionsRoot(allocator, &envelopes);
    try std.testing.expectEqualSlices(u8, &canonical, &(try computeTransactionsRoot(allocator, &with_raw)));

    // Without canonical bytes the legacy re-encoding is the only option, and
    // it commits to a different value.
    const without_raw = [_]tx_processor.ExecutionTx{.{ .caller = caller, .tx = tx, .receipt_type = .eip1559 }};
    try std.testing.expect(!std.mem.eql(u8, &canonical, &(try computeTransactionsRoot(allocator, &without_raw))));
}

test "headerRlpSize matches the canonical encoding and counts the Prague requests hash" {
    const allocator = std.testing.allocator;
    var header = testHeaders().child;
    header.extra_data = "zevm";
    header.withdrawals_root = primitives.BlockHeader.EMPTY_WITHDRAWALS_ROOT;
    header.blob_gas_used = 131_072;
    header.excess_blob_gas = 0;
    header.parent_beacon_block_root = primitives.Hash.ZERO;

    const cancun_encoded = try primitives.BlockHeader.rlpEncode(&header, allocator);
    defer allocator.free(cancun_encoded);
    try std.testing.expectEqual(cancun_encoded.len, headerRlpSize(&header, .cancun, null));

    const requests_hash = [_]u8{0x5a} ** 32;
    const prague_encoded = try encodeHeaderWithRequestsHash(allocator, &header, requests_hash);
    defer allocator.free(prague_encoded);
    try std.testing.expectEqual(prague_encoded.len, headerRlpSize(&header, .prague, requests_hash));
    try std.testing.expectEqual(cancun_encoded.len + 33, prague_encoded.len);
    try std.testing.expect(prague_encoded.len <= MAX_HEADER_RLP_SIZE);

    // A block measured without the hash grows by the header difference, and
    // by one more byte when the list prefix widens.
    try std.testing.expectEqual(@as(usize, 1_000 + 33), blockRlpSizeWithRequestsHash(1_000, &header, .prague, requests_hash));
    try std.testing.expectEqual(@as(usize, 65_537 + 33 + 1), blockRlpSizeWithRequestsHash(65_537, &header, .prague, requests_hash));
    try std.testing.expectEqual(@as(usize, 1_000), blockRlpSizeWithRequestsHash(1_000, &header, .cancun, requests_hash));
    try std.testing.expectEqual(@as(usize, 1_000), blockRlpSizeWithRequestsHash(1_000, &header, .prague, null));
    header.requests_hash = requests_hash;
    try std.testing.expectEqual(@as(usize, 1_000), blockRlpSizeWithRequestsHash(1_000, &header, .prague, requests_hash));
}

test "strict builds reject a transaction that exceeds the remaining block gas" {
    const allocator = std.testing.allocator;
    var sm = try state_manager.StateManager.init(allocator, null);
    defer sm.deinit();
    var adapter = host_adapter.HostAdapter{ .state = &sm };

    const sender = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 };
    const recipient = primitives.Address{ .bytes = [_]u8{0x02} ++ [_]u8{0} ** 19 };
    try sm.setBalance(sender, 1_000_000);
    try sm.setNonce(sender, 0);

    var txs: [2]tx_processor.ExecutionTx = undefined;
    for (&txs, 0..) |*item, nonce| {
        item.* = .{ .caller = sender, .tx = .{
            .nonce = nonce,
            .gas_price = 1,
            .gas_limit = 21_000,
            .to = recipient,
            .value = 0,
            .data = &.{},
            .v = 0,
            .r = [_]u8{0} ** 32,
            .s = [_]u8{0} ** 32,
        } };
    }
    var block_ctx = systemCallBlockContext();
    block_ctx.block_number = 1;
    block_ctx.block_timestamp = 1000;
    block_ctx.block_gas_limit = 30_000;

    // A supplied list is the block: the second transaction cannot fit.
    try std.testing.expectError(
        error.InvalidIncludedTransaction,
        buildBlockWithOptions(allocator, &sm, adapter.hostInterface(), &txs, block_ctx, .{}),
    );
    try std.testing.expectEqual(@as(u64, 0), try sm.getNonce(sender));

    // Candidate selection leaves it out instead.
    var result = try buildBlockWithOptions(allocator, &sm, adapter.hostInterface(), &txs, block_ctx, .{
        .skip_invalid_transactions = true,
    });
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.receipts.len);
    try std.testing.expectEqual(@as(usize, 0), result.execution_requests.len);
    try std.testing.expectEqual(@as(?[32]u8, null), result.computed_requests_hash);
}

test "a missing EIP-7002 or EIP-7251 predeploy fails only when system contracts are required" {
    const allocator = std.testing.allocator;
    // mstore8(0, 0xaa); return(0, 1)
    const one_byte = [_]u8{ 0x60, 0xaa, 0x60, 0x00, 0x53, 0x60, 0x01, 0x60, 0x00, 0xf3 };
    const predeploys = [_]primitives.Address{ WITHDRAWAL_REQUESTS_ADDRESS, CONSOLIDATION_REQUESTS_ADDRESS };

    // Each round deploys exactly one predeploy and leaves the other missing.
    for (predeploys) |deployed| {
        var sm = try state_manager.StateManager.init(allocator, null);
        defer sm.deinit();
        var adapter = host_adapter.HostAdapter{ .state = &sm };
        try sm.setCode(deployed, &one_byte);

        try std.testing.expectError(error.SystemContractMissingCode, collectPragueRequestsWithOptions(
            allocator,
            &sm,
            adapter.hostInterface(),
            systemCallBlockContext(),
            .PRAGUE,
            &.{},
            .{ .require_system_contracts = true },
        ));

        // Dev chains: the missing predeploy is a no-op.
        var relaxed = try collectPragueRequestsWithOptions(
            allocator,
            &sm,
            adapter.hostInterface(),
            systemCallBlockContext(),
            .PRAGUE,
            &.{},
            .{},
        );
        defer relaxed.deinit(allocator);
        const deployed_output = if (deployed.equals(WITHDRAWAL_REQUESTS_ADDRESS)) relaxed.withdrawals else relaxed.consolidations;
        const missing_output = if (deployed.equals(WITHDRAWAL_REQUESTS_ADDRESS)) relaxed.consolidations else relaxed.withdrawals;
        try std.testing.expectEqualSlices(u8, &.{0xaa}, deployed_output.?);
        try std.testing.expect(missing_output == null);
        try std.testing.expect(relaxed.deposits == null);

        // The backward-compatible wrappers keep the no-op.
        var wrapped = try collectPragueRequests(allocator, &sm, adapter.hostInterface(), systemCallBlockContext(), .PRAGUE, &.{});
        defer wrapped.deinit(allocator);
        var system_only = try collectPragueRequestsSystemCalls(allocator, &sm, adapter.hostInterface(), systemCallBlockContext(), .PRAGUE);
        defer system_only.deinit(allocator);
    }

    // Both deployed: strict mode succeeds.
    var sm = try state_manager.StateManager.init(allocator, null);
    defer sm.deinit();
    var adapter = host_adapter.HostAdapter{ .state = &sm };
    for (predeploys) |address| try sm.setCode(address, &one_byte);
    var strict = try collectPragueRequestsWithOptions(
        allocator,
        &sm,
        adapter.hostInterface(),
        systemCallBlockContext(),
        .PRAGUE,
        &.{},
        .{ .require_system_contracts = true },
    );
    defer strict.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &.{0xaa}, strict.withdrawals.?);
    try std.testing.expectEqualSlices(u8, &.{0xaa}, strict.consolidations.?);
}

test "collectPragueRequestsWithOptions reads deposits from the configured contract" {
    const allocator = std.testing.allocator;
    var sm = try state_manager.StateManager.init(allocator, null);
    defer sm.deinit();
    var adapter = host_adapter.HostAdapter{ .state = &sm };

    const custom = primitives.Address{ .bytes = [_]u8{0xde} ** 20 };
    const deposit = testDepositEventData(0x10);
    const topics = [_][32]u8{DEPOSIT_EVENT_TOPIC};
    const logs = [_]primitives.EventLog.EventLog{testLog(custom, &topics, &deposit)};

    var defaults = try collectPragueRequests(allocator, &sm, adapter.hostInterface(), systemCallBlockContext(), .PRAGUE, &logs);
    defer defaults.deinit(allocator);
    try std.testing.expect(defaults.deposits == null);

    var configured = try collectPragueRequestsWithOptions(
        allocator,
        &sm,
        adapter.hostInterface(),
        systemCallBlockContext(),
        .PRAGUE,
        &logs,
        .{ .deposit_contract_address = custom },
    );
    defer configured.deinit(allocator);
    try std.testing.expectEqual(DEPOSIT_REQUEST_SIZE, configured.deposits.?.len);
}

test "the deposit contract address falls back from options to the chain config to mainnet" {
    const from_options = primitives.Address{ .bytes = [_]u8{0x0a} ** 20 };
    const from_config = primitives.Address{ .bytes = [_]u8{0x0b} ** 20 };
    var config = hardfork_schedule.MAINNET_CHAIN_CONFIG;

    try std.testing.expect((BuildBlockOptions{}).effectiveDepositContractAddress().equals(DEPOSIT_CONTRACT_ADDRESS));
    try std.testing.expect((BuildBlockOptions{ .hardfork_config = config }).effectiveDepositContractAddress().equals(DEPOSIT_CONTRACT_ADDRESS));

    config.deposit_contract_address = from_config;
    try std.testing.expect((BuildBlockOptions{ .hardfork_config = config }).effectiveDepositContractAddress().equals(from_config));
    try std.testing.expect((BuildBlockOptions{
        .hardfork_config = config,
        .deposit_contract_address = from_options,
    }).effectiveDepositContractAddress().equals(from_options));
}
