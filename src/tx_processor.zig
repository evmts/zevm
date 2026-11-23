const std = @import("std");
const primitives = @import("primitives");
const state_manager = @import("state-manager");
const guillotine_mini = @import("guillotine_mini");
const host_adapter = @import("host_adapter.zig");
const blob_fee = @import("blob_fee.zig");
const tx_encoding = @import("transaction_encoding.zig");
const hardfork_schedule = @import("hardfork_schedule.zig");
const evm_backend = @import("evm_backend.zig");
const INTRINSIC_GAS: u64 = 21_000;
const CALLDATA_ZERO_BYTE_GAS: u64 = 4;
const CALLDATA_NONZERO_BYTE_GAS: u64 = 16;
const CALLDATA_ZERO_TOKEN_COUNT: u64 = 1;
const CALLDATA_NONZERO_TOKEN_COUNT: u64 = 4;
const PRAGUE_CALLDATA_FLOOR_GAS_PER_TOKEN: u64 = 10;
/// Contract-creation surcharge (EIP-2), charged from Homestead.
const CREATE_GAS: u64 = 32_000;
const INITCODE_WORD_GAS: u64 = 2;
const AUTH_PER_EMPTY_ACCOUNT_GAS: u64 = 25_000;
const REFUND_AUTH_PER_EXISTING_ACCOUNT_GAS: u64 = 12_500;
const EOA_DELEGATION_MARKER = [_]u8{ 0xef, 0x01, 0x00 };
const EOA_DELEGATED_CODE_LENGTH: usize = EOA_DELEGATION_MARKER.len + 20;

/// EIP-7825 maximum declared transaction gas limit, enforced from Osaka.
pub const MAX_TRANSACTION_GAS_LIMIT: u64 = primitives.GasConstants.TxGasLimitOsaka;

/// EIP-3860 maximum init code size for creation transactions, enforced from Shanghai.
pub const MAX_INITCODE_SIZE: usize = 49_152;

/// EIP-4844 `VERSIONED_HASH_VERSION_KZG`: required first byte of every blob versioned hash.
const BLOB_VERSIONED_HASH_VERSION_KZG: u8 = 0x01;

pub const ExecutionTx = struct {
    caller: primitives.Address,
    tx: primitives.Transaction.LegacyTransaction,
    access_list: ?primitives.AccessList.AccessList = null,
    receipt_type: primitives.Receipt.TransactionType = .legacy,
    max_fee_per_gas: ?u256 = null,
    max_priority_fee_per_gas: ?u256 = null,
    authorization_list: ?[]const primitives.Authorization.Authorization = null,
    blob_gas_used: ?u256 = null,
    blob_gas_price: ?u256 = null,
    max_fee_per_blob_gas: ?u256 = null,
    blob_versioned_hashes: ?[]const [32]u8 = null,
    /// Canonical EIP-2718 signed envelope bytes, when known. Block building
    /// uses them for the canonical `transactions_root`.
    raw: ?[]const u8 = null,
    /// Canonical transaction hash, forwarded to
    /// `ProcessTransactionOptions.canonical_tx_hash`.
    tx_hash: ?[32]u8 = null,
};

pub const ProcessTransactionOptions = struct {
    access_list: ?primitives.AccessList.AccessList = null,
    receipt_type: primitives.Receipt.TransactionType = .legacy,
    max_fee_per_gas: ?u256 = null,
    max_priority_fee_per_gas: ?u256 = null,
    authorization_list: ?[]const primitives.Authorization.Authorization = null,
    blob_gas_used: ?u256 = null,
    blob_gas_price: ?u256 = null,
    max_fee_per_blob_gas: ?u256 = null,
    blob_versioned_hashes: ?[]const [32]u8 = null,
    precompile_overrides: []const guillotine_mini.PrecompileOverride = &.{},
    hardfork_override: ?guillotine_mini.Hardfork = null,
    skip_sender_eoa_check: bool = false,
    skip_nonce_validation: bool = false,
    skip_fee_validation: bool = false,
    /// Only non-validating simulations may bypass the Osaka transaction cap.
    /// Block execution and transaction admission must enforce it.
    skip_transaction_gas_limit_validation: bool = false,
    skip_fee_balance_check: bool = false,
    skip_nonce_state_increment: bool = false,
    capture_output: ?*[]u8 = null,
    /// Gas still available in the block. A transaction whose gas limit exceeds
    /// it is rejected with `BlockGasLimitExceeded` before any state change.
    remaining_block_gas: ?u64 = null,
    /// Canonical transaction hash for the receipt. Typed transactions must
    /// pass it: without it the receipt hash falls back to the legacy envelope
    /// hash of the execution fields, which is only right for legacy transactions.
    canonical_tx_hash: ?[32]u8 = null,
    /// EVM that executes the top-level message. Defaults to guillotine-mini.
    backend: evm_backend.Backend = evm_backend.default_backend,
    /// EIP-161 touch set. When set, a transaction that completes adds every
    /// account it touched outside nested EVM calls: the sender, the block
    /// beneficiary (fee settlement touches it even when the tip is zero),
    /// each authority whose EIP-7702 tuple was applied and, when execution
    /// succeeded, the recipient. A transaction that returns an error adds
    /// nothing. The block builder deletes the touched accounts that are
    /// empty, including ones that were already empty before the block.
    touched_accounts: ?*std.AutoHashMap(primitives.Address, void) = null,

    pub fn withHardfork(self: ProcessTransactionOptions, hardfork: guillotine_mini.Hardfork) ProcessTransactionOptions {
        var options = self;
        options.hardfork_override = hardfork;
        return options;
    }
};

pub const TxError = error{
    /// EIP-7594 / Fusaka: blob transaction carries more than 6 blobs on Osaka+.
    TooManyBlobs,
    InsufficientBalance,
    NonceMismatch,
    SenderNotEOA,
    UnsupportedTransactionType,
    BlockGasLimitExceeded,
    /// Declared gas exceeds EIP-7825's 2^24 limit on Osaka or later.
    TransactionGasLimitExceeded,
    IntrinsicGasExceedsLimit,
    GasPriceBelowBaseFee,
    TipExceedsFeeCap,
    StateError,
    EvmInitError,
    OutOfMemory,
    /// EIP-3860: creation init code exceeds 49,152 bytes on Shanghai or later.
    InitcodeTooLarge,
    /// EIP-4844: type-3 transaction carries no blob versioned hashes.
    EmptyBlobHashes,
    /// EIP-4844: a blob versioned hash does not start with 0x01.
    InvalidBlobVersionedHash,
    /// EIP-7702: type-4 transaction carries no authorizations.
    EmptyAuthorizationList,
    /// EIP-4844 / EIP-7702: type-3 and type-4 transactions cannot create contracts.
    ContractCreationNotAllowed,
};

fn findPrecompileOverride(overrides: []const guillotine_mini.PrecompileOverride, address: primitives.Address) ?guillotine_mini.PrecompileOverride {
    for (overrides) |override| {
        if (override.address.equals(address)) return override;
    }
    return null;
}

fn executePrecompileOverrideOwned(
    allocator: std.mem.Allocator,
    override: guillotine_mini.PrecompileOverride,
    input: []const u8,
    gas_limit: u64,
) TxError!evm_backend.ExecutionResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const precompile_result = override.execute(override.context, arena.allocator(), input, gas_limit) catch |err| {
        // Allocation failure is a node fault, not a failed precompile call.
        if (stateError(err) == TxError.OutOfMemory) return TxError.OutOfMemory;
        return evm_backend.ExecutionResult.initOwned(allocator, .{ .success = false, .gas_left = 0 });
    };
    const gas_left = if (precompile_result.gas_used > gas_limit) 0 else gas_limit - precompile_result.gas_used;
    return evm_backend.ExecutionResult.initOwned(allocator, .{
        .success = precompile_result.success,
        .gas_left = gas_left,
        .output = precompile_result.output,
    });
}

/// Map a state-manager failure to `TxError` without hiding allocation failure.
fn stateError(err: anyerror) TxError {
    return if (err == error.OutOfMemory) TxError.OutOfMemory else TxError.StateError;
}

/// Validate EIP-7825's declared gas limit independently of the block gas limit.
/// Historical forks have no separate per-transaction cap. This check performs
/// no allocation or state access and is shared with RPC transaction admission.
pub fn validateTransactionGasLimit(gas_limit: u64, hardfork: guillotine_mini.Hardfork) error{TransactionGasLimitExceeded}!void {
    if (hardfork.isAtLeast(.OSAKA) and gas_limit > MAX_TRANSACTION_GAS_LIMIT) {
        return error.TransactionGasLimitExceeded;
    }
}

/// Calculates the intrinsic gas cost for a transaction.
pub fn intrinsicGas(data: []const u8, is_create: bool) u64 {
    return intrinsicGasForFork(data, is_create, .CANCUN);
}

pub fn intrinsicGasForFork(data: []const u8, is_create: bool, hardfork: guillotine_mini.Hardfork) u64 {
    var gas: u64 = INTRINSIC_GAS;
    if (is_create) {
        // Frontier charged no creation surcharge; EIP-2 added it in Homestead.
        if (hardfork.isAtLeast(.HOMESTEAD)) gas += CREATE_GAS;
        if (hardfork.isAtLeast(.SHANGHAI)) {
            gas += INITCODE_WORD_GAS * @as(u64, @intCast((data.len + 31) / 32));
        }
    }
    const nonzero_byte_gas = if (hardfork.isBefore(.ISTANBUL)) 68 else CALLDATA_NONZERO_BYTE_GAS;
    for (data) |byte| {
        gas += if (byte == 0) CALLDATA_ZERO_BYTE_GAS else nonzero_byte_gas;
    }
    return gas;
}

fn calldataTokenCount(data: []const u8) error{IntrinsicGasExceedsLimit}!u64 {
    var tokens: u64 = 0;
    for (data) |byte| {
        tokens = std.math.add(
            u64,
            tokens,
            if (byte == 0) CALLDATA_ZERO_TOKEN_COUNT else CALLDATA_NONZERO_TOKEN_COUNT,
        ) catch return TxError.IntrinsicGasExceedsLimit;
    }
    return tokens;
}

/// EIP-7623 calldata floor: the minimum gas a transaction is billed on Prague
/// or later. Returns 0 on earlier forks.
pub fn transactionGasFloorForFork(data: []const u8, hardfork: guillotine_mini.Hardfork) error{IntrinsicGasExceedsLimit}!u64 {
    if (hardfork.isBefore(.PRAGUE)) return 0;
    const data_floor = std.math.mul(
        u64,
        try calldataTokenCount(data),
        PRAGUE_CALLDATA_FLOOR_GAS_PER_TOKEN,
    ) catch return TxError.IntrinsicGasExceedsLimit;
    return std.math.add(u64, INTRINSIC_GAS, data_floor) catch return TxError.IntrinsicGasExceedsLimit;
}

/// Compute the final gas billed for a transaction per EIP-7623.
///
/// The refund cap is derived from the non-floored gas used
/// (`intrinsic + execution gas consumed`); the capped refund is subtracted
/// from that non-floored value; and only THEN is the calldata floor
/// (`gas_floor`) applied as a hard lower bound. Applying the floor before the
/// refund would both inflate the refund cap and let the billed gas drop below
/// the mandated floor, undercharging the sender and corrupting the base-fee
/// burn, coinbase tip, and cumulative gas used (a Prague+ consensus divergence).
pub fn effectiveGasUsed(
    gas_used_without_floor: u64,
    gas_floor: u64,
    refund_counter: u64,
    hardfork: guillotine_mini.Hardfork,
) u64 {
    const max_refund = if (hardfork.isAtLeast(.LONDON))
        gas_used_without_floor / 5
    else
        gas_used_without_floor / 2;
    const refund = @min(refund_counter, max_refund);
    return @max(gas_used_without_floor - refund, gas_floor);
}

/// Resolve the EVM hardfork from an explicit chain schedule.
pub fn resolveHardforkWithConfig(config: hardfork_schedule.ChainConfig, block_ctx: guillotine_mini.BlockContext) guillotine_mini.Hardfork {
    return hardfork_schedule.resolveHardforkWithConfig(config, block_ctx.block_number, block_ctx.block_timestamp);
}

/// Resolve the EVM hardfork from the canonical mainnet activation schedule.
/// Runtime execution paths should pass an explicit chain schedule through
/// ProcessTransactionOptions instead of relying on this helper.
pub fn resolveHardfork(block_ctx: guillotine_mini.BlockContext) guillotine_mini.Hardfork {
    return hardfork_schedule.resolveHardfork(block_ctx.block_number, block_ctx.block_timestamp);
}

fn transactionTypeSupported(receipt_type: primitives.Receipt.TransactionType, hardfork: guillotine_mini.Hardfork) bool {
    return switch (receipt_type) {
        .legacy => true,
        .eip2930 => hardfork.isAtLeast(.BERLIN),
        .eip1559 => hardfork.isAtLeast(.LONDON),
        .eip4844 => hardfork.isAtLeast(.CANCUN),
        .eip7702 => hardfork.isAtLeast(.PRAGUE),
    };
}

/// Gas charged before execution, including the envelope's access and authorization lists.
fn envelopeIntrinsicGas(decoded: tx_encoding.DecodedEnvelope, hardfork: guillotine_mini.Hardfork) error{IntrinsicGasExceedsLimit}!u64 {
    const tx = tx_encoding.envelopeToLegacyLikeTx(decoded);
    var gas = intrinsicGasForFork(tx.data, tx.to == null, hardfork);
    for (tx_encoding.envelopeAccessList(decoded)) |entry| {
        gas = std.math.add(u64, gas, primitives.AccessList.ACCESS_LIST_ADDRESS_COST) catch return error.IntrinsicGasExceedsLimit;
        const keys = std.math.mul(u64, primitives.AccessList.ACCESS_LIST_STORAGE_KEY_COST, entry.storage_keys.len) catch return error.IntrinsicGasExceedsLimit;
        gas = std.math.add(u64, gas, keys) catch return error.IntrinsicGasExceedsLimit;
    }
    const auth = std.math.mul(u64, AUTH_PER_EMPTY_ACCOUNT_GAS, tx_encoding.envelopeAuthorizationList(decoded).len) catch return error.IntrinsicGasExceedsLimit;
    return std.math.add(u64, gas, auth) catch return error.IntrinsicGasExceedsLimit;
}

/// Validate a decoded signed envelope without block context or account state.
pub fn validateEnvelope(
    decoded: tx_encoding.DecodedEnvelope,
    hardfork: guillotine_mini.Hardfork,
    chain_id: u64,
) error{
    UnsupportedTransactionType,
    ChainIdMismatch,
    InitcodeTooLarge,
    NonceTooLarge,
    TipExceedsFeeCap,
    GasCostOverflow,
    IntrinsicGasExceedsLimit,
    TransactionGasLimitExceeded,
}!u64 {
    const receipt_type = tx_encoding.envelopeReceiptType(decoded);
    if (!transactionTypeSupported(receipt_type, hardfork)) return error.UnsupportedTransactionType;
    if (tx_encoding.envelopeChainId(decoded)) |id| {
        if (id != chain_id or (receipt_type == .legacy and hardfork.isBefore(.SPURIOUS_DRAGON))) return error.ChainIdMismatch;
    }

    const tx = tx_encoding.envelopeToLegacyLikeTx(decoded);
    if (hardfork.isAtLeast(.SHANGHAI) and tx.to == null and tx.data.len > MAX_INITCODE_SIZE) return error.InitcodeTooLarge;
    if (tx.nonce == std.math.maxInt(u64)) return error.NonceTooLarge;
    const max_fee = tx_encoding.envelopeMaxFeePerGas(decoded) orelse tx.gas_price;
    if (tx_encoding.envelopeMaxPriorityFeePerGas(decoded)) |tip| {
        if (tip > max_fee) return error.TipExceedsFeeCap;
    }
    _ = std.math.mul(u256, max_fee, tx.gas_limit) catch return error.GasCostOverflow;

    const intrinsic = try envelopeIntrinsicGas(decoded, hardfork);
    const floor = try transactionGasFloorForFork(tx.data, hardfork);
    try validateTransactionGasLimit(tx.gas_limit, hardfork);
    if (tx.gas_limit < @max(intrinsic, floor)) return error.IntrinsicGasExceedsLimit;
    return intrinsic;
}

fn allocateEventLogs(
    allocator: std.mem.Allocator,
    src_logs: []const guillotine_mini.Log,
) TxError![]primitives.EventLog.EventLog {
    const logs = allocator.alloc(primitives.EventLog.EventLog, src_logs.len) catch return TxError.OutOfMemory;
    var initialized: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < initialized) : (i += 1) {
            allocator.free(logs[i].topics);
            allocator.free(logs[i].data);
        }
        allocator.free(logs);
    }

    for (src_logs, 0..) |log, i| {
        const topics = allocator.alloc(primitives.Hash.Hash, log.topics.len) catch return TxError.OutOfMemory;
        for (log.topics, 0..) |topic, j| {
            var topic_hash: primitives.Hash.Hash = undefined;
            std.mem.writeInt(u256, &topic_hash, topic, .big);
            topics[j] = topic_hash;
        }

        const data = if (log.data.len > 0)
            allocator.dupe(u8, log.data) catch {
                allocator.free(topics);
                return TxError.OutOfMemory;
            }
        else
            allocator.alloc(u8, 0) catch {
                allocator.free(topics);
                return TxError.OutOfMemory;
            };

        logs[i] = .{
            .address = log.address,
            .topics = topics,
            .data = data,
            .block_number = null,
            .transaction_hash = null,
            .transaction_index = null,
            .log_index = null,
            .removed = false,
        };
        initialized += 1;
    }

    return logs;
}

pub fn computeLogsBloom(logs: []const primitives.EventLog.EventLog) [256]u8 {
    var bloom: [256]u8 = [_]u8{0} ** 256;
    for (logs) |event_log| {
        addBloomValue(&bloom, event_log.address.bytes[0..]);
        for (event_log.topics) |topic| {
            addBloomValue(&bloom, topic[0..]);
        }
    }
    return bloom;
}

fn addBloomValue(bloom: *[256]u8, value: []const u8) void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(value, &digest, .{});
    inline for (.{ 0, 2, 4 }) |offset| {
        const bit = std.mem.readInt(u16, digest[offset..][0..2], .big) & 0x07ff;
        bloom[255 - (bit / 8)] |= @as(u8, 1) << @intCast(bit & 0x07);
    }
}

fn computeLegacyTxHash(
    allocator: std.mem.Allocator,
    tx: primitives.Transaction.LegacyTransaction,
) TxError!primitives.Hash.Hash {
    const encoded = tx_encoding.encodeLegacyTransactionEnvelope(allocator, tx) catch return TxError.OutOfMemory;
    defer allocator.free(encoded);
    return tx_encoding.transactionHash(encoded);
}

fn hostErrorToTxError(host_error: host_adapter.HostAdapter.HostError) TxError {
    return switch (host_error) {
        .out_of_memory => TxError.OutOfMemory,
        else => TxError.StateError,
    };
}

fn consumeHostError(adapter: ?*host_adapter.HostAdapter) TxError!void {
    if (adapter) |a| {
        if (a.takeHostError()) |host_error| return hostErrorToTxError(host_error);
    }
}

/// Processes a single transaction against the state.
///
/// Gas deduction and nonce increment persist regardless of EVM outcome.
/// Only EVM state changes (storage writes, value transfers, code deploys)
/// are reverted on failure.
pub fn processTransaction(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    host_iface: guillotine_mini.HostInterface,
    caller: primitives.Address,
    tx: primitives.Transaction.LegacyTransaction,
    block_ctx: guillotine_mini.BlockContext,
) TxError!primitives.Receipt.Receipt {
    return processTransactionWithOptions(
        allocator,
        sm,
        host_iface,
        caller,
        tx,
        block_ctx,
        .{},
    );
}

pub fn processTransactionWithOptions(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    host_iface: guillotine_mini.HostInterface,
    caller: primitives.Address,
    tx: primitives.Transaction.LegacyTransaction,
    block_ctx: guillotine_mini.BlockContext,
    options: ProcessTransactionOptions,
) TxError!primitives.Receipt.Receipt {
    const adapter = host_adapter.HostAdapter.fromHostInterface(host_iface);
    if (adapter) |a| a.clearHostError();

    const hardfork = options.hardfork_override orelse resolveHardfork(block_ctx);
    if (!options.skip_transaction_gas_limit_validation) try validateTransactionGasLimit(tx.gas_limit, hardfork);
    // Only caller-supplied overrides reach the EVM, plus the Hardhat
    // console.log sink when the host adapter carries the node buffer. An
    // override supersedes the native precompile and lets account bytecode at
    // its address run, so an implicit override for 0x01 would let state
    // shadow native ECRECOVER. The console.log address is not a precompile.
    const console_logs = if (adapter) |a| a.console_logs else null;
    const owned_precompile_overrides: ?[]guillotine_mini.PrecompileOverride = if (console_logs) |buffer| blk: {
        const overrides = allocator.alloc(guillotine_mini.PrecompileOverride, options.precompile_overrides.len + 1) catch return TxError.OutOfMemory;
        @memcpy(overrides[0..options.precompile_overrides.len], options.precompile_overrides);
        overrides[options.precompile_overrides.len] = buffer.precompileOverride();
        break :blk overrides;
    } else null;
    defer if (owned_precompile_overrides) |overrides| allocator.free(overrides);
    const effective_precompile_overrides: []const guillotine_mini.PrecompileOverride = owned_precompile_overrides orelse options.precompile_overrides;

    if (!transactionTypeSupported(options.receipt_type, hardfork)) return TxError.UnsupportedTransactionType;
    if (tx.gas_limit > block_ctx.block_gas_limit) return TxError.BlockGasLimitExceeded;
    if (options.remaining_block_gas) |remaining| {
        if (tx.gas_limit > remaining) return TxError.BlockGasLimitExceeded;
    }

    // Structural validity. These checks read no state and run before the
    // first state change, so an invalid transaction leaves the state untouched.
    if (tx.to == null) {
        // EIP-3860.
        if (hardfork.isAtLeast(.SHANGHAI) and tx.data.len > MAX_INITCODE_SIZE) return TxError.InitcodeTooLarge;
        // EIP-4844 and EIP-7702 define `to` as a mandatory address.
        if (options.receipt_type == .eip4844 or options.receipt_type == .eip7702) return TxError.ContractCreationNotAllowed;
    }
    // Non-validating simulations (`skip_fee_validation`) may omit the blob
    // hashes and authorizations; block execution and admission may not.
    if (!options.skip_fee_validation and options.receipt_type == .eip7702) {
        const authorizations = options.authorization_list orelse &.{};
        if (authorizations.len == 0) return TxError.EmptyAuthorizationList;
    }

    if (!options.skip_sender_eoa_check) {
        const sender_code = sm.getCode(caller) catch |err| return stateError(err);
        if (sender_code.len != 0 and !(hardfork.isAtLeast(.PRAGUE) and isValidDelegationCode(sender_code))) {
            return TxError.SenderNotEOA;
        }
    }

    const current_nonce = sm.getNonce(caller) catch |err| return stateError(err);
    if (!options.skip_nonce_validation and current_nonce != tx.nonce) return TxError.NonceMismatch;

    var intrinsic = intrinsicGasForFork(tx.data, tx.to == null, hardfork);
    if (options.access_list) |access_list| {
        intrinsic = std.math.add(u64, intrinsic, primitives.AccessList.calculateAccessListGasCost(access_list)) catch return TxError.IntrinsicGasExceedsLimit;
    }
    if (options.receipt_type == .eip7702) {
        const authorizations = options.authorization_list orelse &.{};
        const auth_intrinsic = std.math.mul(u64, AUTH_PER_EMPTY_ACCOUNT_GAS, authorizations.len) catch return TxError.IntrinsicGasExceedsLimit;
        intrinsic = std.math.add(u64, intrinsic, auth_intrinsic) catch return TxError.IntrinsicGasExceedsLimit;
    }
    if (intrinsic > tx.gas_limit) return TxError.IntrinsicGasExceedsLimit;
    const gas_floor = try transactionGasFloorForFork(tx.data, hardfork);
    if (gas_floor > tx.gas_limit) return TxError.IntrinsicGasExceedsLimit;

    const is_dynamic_fee = switch (options.receipt_type) {
        .eip1559, .eip4844, .eip7702 => true,
        .legacy, .eip2930 => false,
    };

    if (is_dynamic_fee) {
        const max_fee_per_gas = options.max_fee_per_gas orelse tx.gas_price;
        const max_priority_fee_per_gas = options.max_priority_fee_per_gas orelse 0;
        if (!options.skip_fee_validation) {
            if (max_priority_fee_per_gas > max_fee_per_gas) return TxError.TipExceedsFeeCap;
            if (max_fee_per_gas < block_ctx.block_base_fee) return TxError.GasPriceBelowBaseFee;
        }
    }

    const blob_gas_used: u256 = if (options.receipt_type == .eip4844) options.blob_gas_used orelse 0 else 0;
    if (hardfork.isAtLeast(.OSAKA) and blob_gas_used > tx_encoding.MAX_BLOBS_PER_TRANSACTION * blob_fee.GAS_PER_BLOB) {
        return TxError.TooManyBlobs;
    }
    if (!options.skip_fee_validation and options.receipt_type == .eip4844) {
        const hashes = options.blob_versioned_hashes orelse &.{};
        if (hashes.len == 0) return TxError.EmptyBlobHashes;
        for (hashes) |hash| {
            if (hash[0] != BLOB_VERSIONED_HASH_VERSION_KZG) return TxError.InvalidBlobVersionedHash;
        }
    }
    const blob_gas_price: u256 = if (options.receipt_type == .eip4844) options.blob_gas_price orelse block_ctx.blob_base_fee else 0;
    const max_fee_per_blob_gas: u256 = if (options.receipt_type == .eip4844) options.max_fee_per_blob_gas orelse 0 else 0;
    if (!options.skip_fee_validation and options.receipt_type == .eip4844 and max_fee_per_blob_gas < blob_gas_price) return TxError.GasPriceBelowBaseFee;

    // EIP-1559 base-fee floor: non-dynamic-fee txs must pay at least the block base fee.
    const base_fee: u256 = if (hardfork.isAtLeast(.LONDON)) block_ctx.block_base_fee else 0;
    if (!options.skip_fee_validation and !is_dynamic_fee and tx.gas_price < base_fee) return TxError.GasPriceBelowBaseFee;

    const computed_effective_gas_price: u256 = if (is_dynamic_fee) blk: {
        const max_fee_per_gas = options.max_fee_per_gas orelse tx.gas_price;
        const max_priority_fee_per_gas = options.max_priority_fee_per_gas orelse 0;
        // Saturate: `base_fee + max_priority_fee_per_gas` overflows u256 for an
        // attacker-chosen tip. The result is capped by `max_fee_per_gas`, so
        // saturation is exact. When `max_fee_per_gas >= base_fee` this equals
        // `base_fee + @min(max_priority_fee_per_gas, max_fee_per_gas - base_fee)`.
        break :blk @min(max_fee_per_gas, base_fee +| max_priority_fee_per_gas);
    } else tx.gas_price;
    const balance_check_gas_price: u256 = if (is_dynamic_fee)
        options.max_fee_per_gas orelse tx.gas_price
    else
        computed_effective_gas_price;
    const potential_max_gas_cost = std.math.mul(u256, balance_check_gas_price, @as(u256, tx.gas_limit)) catch return TxError.InsufficientBalance;
    const potential_max_blob_gas_cost = std.math.mul(u256, max_fee_per_blob_gas, blob_gas_used) catch return TxError.InsufficientBalance;
    const potential_max_fee_cost = std.math.add(u256, potential_max_gas_cost, potential_max_blob_gas_cost) catch return TxError.InsufficientBalance;
    const total_cost = std.math.add(u256, tx.value, potential_max_fee_cost) catch return TxError.InsufficientBalance;
    const balance = sm.getBalance(caller) catch |err| return stateError(err);
    var charge_fees = true;
    if (balance < total_cost) {
        if (!options.skip_fee_balance_check or balance < tx.value) return TxError.InsufficientBalance;
        charge_fees = false;
    }
    const effective_gas_price: u256 = if (charge_fees) computed_effective_gas_price else 0;
    const effective_blob_gas_price: u256 = if (charge_fees) blob_gas_price else 0;
    const prepaid_gas_cost = if (charge_fees)
        std.math.mul(u256, effective_gas_price, @as(u256, tx.gas_limit)) catch return TxError.StateError
    else
        0;
    const prepaid_blob_gas_cost = if (charge_fees)
        std.math.mul(u256, effective_blob_gas_price, blob_gas_used) catch return TxError.StateError
    else
        0;
    const prepaid_fee_cost = std.math.add(u256, prepaid_gas_cost, prepaid_blob_gas_cost) catch return TxError.StateError;

    sm.checkpoint() catch |err| return stateError(err);
    var transaction_checkpoint_open = true;
    errdefer if (transaction_checkpoint_open) sm.revert();

    const balance_after_prepay = std.math.sub(u256, balance, prepaid_fee_cost) catch return TxError.InsufficientBalance;
    sm.setBalance(caller, balance_after_prepay) catch |err| return stateError(err);
    if (!options.skip_nonce_state_increment) {
        const next_nonce = if (options.skip_nonce_validation)
            current_nonce +% 1
        else
            std.math.add(u64, tx.nonce, 1) catch return TxError.NonceMismatch;
        sm.setNonce(caller, next_nonce) catch |err| return stateError(err);
    }

    // EIP-7702 step 4: every recovered authority joins `accessed_addresses`,
    // including the ones whose tuple is later skipped. Intrinsic access-list
    // gas was billed above from `options.access_list` only, so warming them
    // adds no intrinsic gas.
    var warm_authorities: std.ArrayList(primitives.Address) = .empty;
    defer warm_authorities.deinit(allocator);
    // Authorities whose tuple was applied. Their code and nonce changes
    // survive a failed execution, so they stay touched either way.
    var applied_authorities: std.ArrayList(primitives.Address) = .empty;
    defer applied_authorities.deinit(allocator);

    const authorization_refund = applySetCodeAuthorizations(
        allocator,
        sm,
        adapter,
        block_ctx.chain_id,
        if (options.receipt_type == .eip7702) options.authorization_list else null,
        &warm_authorities,
        &applied_authorities,
    ) catch |err| return stateError(err);

    sm.checkpoint() catch |err| return stateError(err);
    var evm_checkpoint_open = true;
    errdefer if (evm_checkpoint_open) sm.revert();

    const execution_gas = tx.gas_limit - intrinsic;

    var result = blk: {
        const target_code: []const u8 = if (tx.to) |to|
            sm.getCode(to) catch |err| return stateError(err)
        else
            &.{};

        if (tx.to) |to| {
            if (target_code.len == 0) {
                if (findPrecompileOverride(effective_precompile_overrides, to)) |override| {
                    if (tx.value > 0) {
                        const caller_balance = sm.getBalance(caller) catch |err| return stateError(err);
                        if (caller_balance < tx.value) return TxError.InsufficientBalance;
                        // A self-transfer moves nothing. Writing both sides
                        // from balances read before either write would mint
                        // `tx.value`.
                        if (!caller.equals(to)) {
                            const target_balance = sm.getBalance(to) catch |err| return stateError(err);
                            sm.setBalance(caller, caller_balance - tx.value) catch |err| return stateError(err);
                            sm.setBalance(to, std.math.add(u256, target_balance, tx.value) catch return TxError.StateError) catch |err| return stateError(err);
                        }
                    }
                    break :blk try executePrecompileOverrideOwned(
                        allocator,
                        override,
                        tx.data,
                        execution_gas,
                    );
                }
            }
        }

        break :blk options.backend.execute(allocator, .{
            .host = host_iface,
            .hardfork = hardfork,
            .block_context = block_ctx,
            .caller = caller,
            .to = tx.to,
            .value = tx.value,
            .input = tx.data,
            .gas = execution_gas,
            .gas_price = effective_gas_price,
            .code = target_code,
            .access_list = options.access_list,
            .warm_addresses = warm_authorities.items,
            .blob_versioned_hashes = options.blob_versioned_hashes,
            .precompile_overrides = effective_precompile_overrides,
        }) catch |err| return switch (err) {
            error.OutOfMemory => TxError.OutOfMemory,
            error.EvmInitError => TxError.EvmInitError,
        };
    };
    defer result.deinit(allocator);

    try consumeHostError(adapter);
    // The copy is handed to the caller only once nothing below can fail, so
    // a failed transaction neither leaks it nor leaves `capture_output`
    // pointing at freed memory.
    var captured_output: ?[]u8 = null;
    errdefer if (captured_output) |bytes| allocator.free(bytes);
    if (options.capture_output != null) {
        const captured = if (tx.to == null and result.success) blk: {
            if (result.created_address) |created| {
                break :blk sm.getCode(created) catch |err| return stateError(err);
            }
            break :blk result.output;
        } else result.output;
        captured_output = allocator.dupe(u8, captured) catch return TxError.OutOfMemory;
    }

    if (result.success) {
        // Write inside the EVM checkpoint. A failure here must unwind exactly
        // the two open checkpoints; writing after the commit left the flag set
        // and reverted one checkpoint too many, into the caller's journal.
        if (hardfork.isBefore(.SPURIOUS_DRAGON)) {
            if (result.created_address) |created| {
                sm.setNonce(created, 0) catch |err| return stateError(err);
            }
        }
        sm.commit();
    } else {
        sm.revert();
    }
    evm_checkpoint_open = false;

    const gas_consumed = if (result.gas_left > execution_gas) 0 else execution_gas - result.gas_left;
    // EIP-7623: the refund cap is computed on the non-floored gas
    // (intrinsic + execution gas), the refund is subtracted from that
    // non-floored value, and only THEN is the calldata floor applied as a
    // hard lower bound. Applying the floor first would both inflate the
    // refund cap and allow the final gas used to drop below the floor.
    const gas_used_without_floor = intrinsic + gas_consumed;
    const refund_counter = std.math.add(u64, result.refund_counter, authorization_refund) catch std.math.maxInt(u64);
    const effective_gas_used = effectiveGasUsed(gas_used_without_floor, gas_floor, refund_counter, hardfork);
    const effective_gas_used_u256: u256 = @as(u256, effective_gas_used);

    const charged_gas_wei = std.math.mul(u256, effective_gas_price, effective_gas_used_u256) catch return TxError.StateError;
    const gas_refund_wei = std.math.sub(u256, prepaid_gas_cost, charged_gas_wei) catch return TxError.StateError;
    const charged_blob_gas_wei = std.math.mul(u256, effective_blob_gas_price, blob_gas_used) catch return TxError.StateError;
    const blob_gas_refund_wei = std.math.sub(u256, prepaid_blob_gas_cost, charged_blob_gas_wei) catch return TxError.StateError;
    const total_refund_wei = std.math.add(u256, gas_refund_wei, blob_gas_refund_wei) catch return TxError.StateError;
    const caller_balance = sm.getBalance(caller) catch |err| return stateError(err);
    sm.setBalance(caller, std.math.add(u256, caller_balance, total_refund_wei) catch return TxError.StateError) catch |err| return stateError(err);

    // EIP-1559 settlement: coinbase only earns the priority tip
    // (effective_gas_price - base_fee). Base fee is burned (not credited to
    // anyone). When base_fee == 0 (pre-London or test contexts) this collapses
    // to the legacy "all of gas_price goes to the miner" behavior.
    const priority_per_gas: u256 = if (effective_gas_price > base_fee) effective_gas_price - base_fee else 0;
    const coinbase_payment = std.math.mul(u256, priority_per_gas, effective_gas_used_u256) catch return TxError.StateError;
    if (coinbase_payment > 0) {
        const coinbase_balance = sm.getBalance(block_ctx.block_coinbase) catch |err| return stateError(err);
        sm.setBalance(block_ctx.block_coinbase, std.math.add(u256, coinbase_balance, coinbase_payment) catch return TxError.StateError) catch |err| return stateError(err);
    } else if (hardfork.isAtLeast(.SPURIOUS_DRAGON)) {
        // EIP-161: fee settlement touches the beneficiary even when it earns
        // nothing. A beneficiary that exists and is empty is deleted here, so
        // every caller gets the rule, not only the block builder.
        try deleteTouchedEmptyAccount(sm, adapter, block_ctx.block_coinbase);
    }

    if (options.touched_accounts) |touched| {
        touched.put(caller, {}) catch return TxError.OutOfMemory;
        touched.put(block_ctx.block_coinbase, {}) catch return TxError.OutOfMemory;
        for (applied_authorities.items) |authority| {
            touched.put(authority, {}) catch return TxError.OutOfMemory;
        }
        // A failed execution reverts the touch on its recipient.
        if (result.success) {
            if (tx.to) |to| touched.put(to, {}) catch return TxError.OutOfMemory;
        }
    }

    const logs = try allocateEventLogs(allocator, result.logs);
    errdefer {
        for (logs) |event_log| {
            allocator.free(event_log.topics);
            allocator.free(event_log.data);
        }
        allocator.free(logs);
    }

    const tx_hash: primitives.Hash.Hash = options.canonical_tx_hash orelse try computeLegacyTxHash(allocator, tx);

    const receipt = primitives.Receipt.Receipt{
        .transaction_hash = tx_hash,
        .transaction_index = 0,
        .block_hash = primitives.Hash.ZERO,
        .block_number = block_ctx.block_number,
        .sender = caller,
        .to = tx.to,
        .cumulative_gas_used = effective_gas_used_u256,
        .gas_used = effective_gas_used_u256,
        .contract_address = result.created_address,
        .logs = logs,
        .logs_bloom = computeLogsBloom(logs),
        .status = primitives.Receipt.TransactionStatus{ .success = result.success, .gas_used = effective_gas_used_u256 },
        .root = null,
        .effective_gas_price = effective_gas_price,
        .type = options.receipt_type,
        .blob_gas_used = if (options.receipt_type == .eip4844) blob_gas_used else null,
        .blob_gas_price = if (options.receipt_type == .eip4844) blob_gas_price else null,
    };

    sm.commit();
    transaction_checkpoint_open = false;

    if (options.capture_output) |output| output.* = captured_output.?;
    return receipt;
}

/// Apply the EIP-7702 authorization list and return the gas refund.
///
/// Appends every recovered authority to `warm_authorities` before the code
/// and nonce checks: EIP-7702 adds the authority to `accessed_addresses`
/// (step 4) ahead of the checks that can skip the tuple (steps 5 and 6).
fn applySetCodeAuthorizations(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    adapter: ?*host_adapter.HostAdapter,
    chain_id: u256,
    maybe_authorizations: ?[]const primitives.Authorization.Authorization,
    warm_authorities: *std.ArrayList(primitives.Address),
    applied_authorities: *std.ArrayList(primitives.Address),
) !u64 {
    const authorizations = maybe_authorizations orelse return 0;
    var refund_counter: u64 = 0;

    for (authorizations) |auth| {
        // EIP-7702 step 1. `auth.chain_id` is a u256: a value at or above
        // 2^64 matches no chain and skips the tuple, leaving the
        // transaction valid.
        if (!(auth.chain_id == 0 or auth.chain_id == @as(u256, chain_id))) continue;
        if (auth.nonce == std.math.maxInt(u64)) continue;

        const authority = auth.authority() catch |err| {
            // An unrecoverable signature skips the tuple; allocation failure does not.
            if (stateError(err) == TxError.OutOfMemory) return error.OutOfMemory;
            continue;
        };
        try warm_authorities.append(allocator, authority);

        // Sampled before the reads below: with a fork backend a read caches
        // the account, and existence must not depend on that.
        const authority_exists = try authorityExistsInState(sm, adapter, authority);

        const authority_code = try sm.getCode(authority);
        if (authority_code.len != 0 and !isValidDelegationCode(authority_code)) continue;

        const authority_nonce = try sm.getNonce(authority);
        if (authority_nonce != auth.nonce) continue;

        if (authority_exists) {
            refund_counter = std.math.add(
                u64,
                refund_counter,
                AUTH_PER_EMPTY_ACCOUNT_GAS - REFUND_AUTH_PER_EXISTING_ACCOUNT_GAS,
            ) catch std.math.maxInt(u64);
        }

        if (primitives.Address.isZero(auth.address)) {
            const empty_code: []const u8 = &.{};
            try sm.setCode(authority, empty_code);
        } else {
            var delegated_code: [EOA_DELEGATED_CODE_LENGTH]u8 = undefined;
            @memcpy(delegated_code[0..EOA_DELEGATION_MARKER.len], &EOA_DELEGATION_MARKER);
            @memcpy(delegated_code[EOA_DELEGATION_MARKER.len..], &auth.address.bytes);
            try sm.setCode(authority, delegated_code[0..]);
        }
        try sm.setNonce(authority, authority_nonce + 1);
        try applied_authorities.append(allocator, authority);
    }

    return refund_counter;
}

/// EIP-161: delete `address` when it is in the state and empty (zero nonce,
/// zero balance, no code). An address the state does not hold is left alone:
/// this never creates an entry.
fn deleteTouchedEmptyAccount(
    sm: *state_manager.StateManager,
    adapter: ?*host_adapter.HostAdapter,
    address: primitives.Address,
) TxError!void {
    const journal = &sm.journaled_state;
    // Check presence before reading: a read may cache an absent account.
    if (!journal.account_cache.has(address) and
        !journal.contract_cache.cache.contains(address) and
        !journal.storage_cache.cache.contains(address)) return;

    if ((sm.getNonce(address) catch |err| return stateError(err)) != 0) return;
    if ((sm.getBalance(address) catch |err| return stateError(err)) != 0) return;
    if ((sm.getCode(address) catch |err| return stateError(err)).len != 0) return;

    if (adapter) |a| {
        a.deleteAccount(address) catch |err| return stateError(err);
        return;
    }
    // Without a fork backend the caches are the state. With one, only the
    // host adapter knows how to tombstone a remote account.
    if (journal.fork_backend != null) return;
    _ = journal.account_cache.delete(address);
    _ = journal.contract_cache.delete(address);
    if (journal.storage_cache.cache.fetchRemove(address)) |entry| {
        var slots = entry.value;
        slots.deinit();
    }
}

fn isValidDelegationCode(code: []const u8) bool {
    return code.len == EOA_DELEGATED_CODE_LENGTH and
        std.mem.eql(u8, code[0..EOA_DELEGATION_MARKER.len], &EOA_DELEGATION_MARKER);
}

/// EIP-7702 refund rule: is `authority` in the state trie? An account that
/// exists and is empty (zero nonce, zero balance, no code) counts, as
/// `account_exists` does in the execution specs.
///
/// Without a fork backend the caches are the state, so presence in any of
/// them is existence (the rule `deleteTouchedEmptyAccount` uses). With a fork
/// backend a read caches accounts the remote state does not hold, so presence
/// proves nothing and the EIP-161 non-empty rule decides.
fn authorityExistsInState(
    sm: *state_manager.StateManager,
    adapter: ?*host_adapter.HostAdapter,
    authority: primitives.Address,
) !bool {
    const journal = &sm.journaled_state;
    if (journal.fork_backend == null) {
        if (journal.account_cache.has(authority) or
            journal.contract_cache.cache.contains(authority) or
            journal.storage_cache.cache.contains(authority)) return true;
    }
    return accountExists(sm, adapter, authority);
}

/// EIP-161 existence: an account exists when it is non-empty.
fn accountExists(
    sm: *state_manager.StateManager,
    adapter: ?*host_adapter.HostAdapter,
    address: primitives.Address,
) !bool {
    if (adapter) |a| return try a.accountExists(address);

    if (try sm.getNonce(address) != 0) return true;
    if (try sm.getBalance(address) != 0) return true;
    return (try sm.getCode(address)).len != 0;
}
