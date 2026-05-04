const std = @import("std");
const primitives = @import("primitives");
const state_manager = @import("state-manager");
const guillotine_mini = @import("guillotine_mini");
const host_adapter = @import("host_adapter.zig");
const tx_encoding = @import("transaction_encoding.zig");
const hardfork_schedule = @import("hardfork_schedule.zig");
const precompile_compat = @import("precompile_compat.zig");
const evm_overrides = @import("evm_overrides.zig");
const INTRINSIC_GAS: u64 = 21_000;
const CALLDATA_ZERO_BYTE_GAS: u64 = 4;
const CALLDATA_NONZERO_BYTE_GAS: u64 = 16;
const CALLDATA_ZERO_TOKEN_COUNT: u64 = 1;
const CALLDATA_NONZERO_TOKEN_COUNT: u64 = 4;
const PRAGUE_CALLDATA_FLOOR_GAS_PER_TOKEN: u64 = 10;
const CREATE_GAS: u64 = 32_000;
const INITCODE_WORD_GAS: u64 = 2;
const AUTH_PER_EMPTY_ACCOUNT_GAS: u64 = 25_000;
const REFUND_AUTH_PER_EXISTING_ACCOUNT_GAS: u64 = 12_500;
const EOA_DELEGATION_MARKER = [_]u8{ 0xef, 0x01, 0x00 };
const EOA_DELEGATED_CODE_LENGTH: usize = EOA_DELEGATION_MARKER.len + 20;

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
    skip_fee_balance_check: bool = false,
    skip_nonce_state_increment: bool = false,
    capture_output: ?*[]u8 = null,

    pub fn withHardfork(self: ProcessTransactionOptions, hardfork: guillotine_mini.Hardfork) ProcessTransactionOptions {
        var options = self;
        options.hardfork_override = hardfork;
        return options;
    }
};

pub const TxError = error{
    InsufficientBalance,
    NonceMismatch,
    SenderNotEOA,
    UnsupportedTransactionType,
    BlockGasLimitExceeded,
    IntrinsicGasExceedsLimit,
    GasPriceBelowBaseFee,
    TipExceedsFeeCap,
    StateError,
    EvmInitError,
    OutOfMemory,
};

const StandardPrecompileContext = struct {
    address: primitives.Address,
    fork: guillotine_mini.Hardfork,
};

fn findPrecompileOverride(overrides: []const guillotine_mini.PrecompileOverride, address: primitives.Address) ?guillotine_mini.PrecompileOverride {
    for (overrides) |override| {
        if (override.address.equals(address)) return override;
    }
    return null;
}

fn executeStandardPrecompile(
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    input: []const u8,
    gas_limit: u64,
) anyerror!guillotine_mini.PrecompileOutput {
    const standard: *const StandardPrecompileContext = @ptrCast(@alignCast(ctx.?));
    return precompile_compat.execute(allocator, standard.address, input, gas_limit, standard.fork);
}

fn executePrecompileOverrideOwned(
    comptime ResultType: type,
    allocator: std.mem.Allocator,
    override: guillotine_mini.PrecompileOverride,
    input: []const u8,
    gas_limit: u64,
) TxError!ResultType {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const precompile_result = override.execute(override.context, arena.allocator(), input, gas_limit) catch {
        return (ResultType{
            .success = false,
            .gas_left = 0,
            .output = &.{},
        }).toOwnedResult(allocator) catch return TxError.OutOfMemory;
    };
    const gas_left = if (precompile_result.gas_used > gas_limit) 0 else gas_limit - precompile_result.gas_used;
    return (ResultType{
        .success = precompile_result.success,
        .gas_left = gas_left,
        .output = precompile_result.output,
    }).toOwnedResult(allocator) catch return TxError.OutOfMemory;
}

/// Calculates the intrinsic gas cost for a transaction.
pub fn intrinsicGas(data: []const u8, is_create: bool) u64 {
    return intrinsicGasForFork(data, is_create, .CANCUN);
}

pub fn intrinsicGasForFork(data: []const u8, is_create: bool, hardfork: guillotine_mini.Hardfork) u64 {
    var gas: u64 = INTRINSIC_GAS;
    if (is_create) {
        gas += CREATE_GAS;
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

fn calldataTokenCount(data: []const u8) TxError!u64 {
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

fn transactionGasFloorForFork(data: []const u8, hardfork: guillotine_mini.Hardfork) TxError!u64 {
    if (hardfork.isBefore(.PRAGUE)) return 0;
    const data_floor = std.math.mul(
        u64,
        try calldataTokenCount(data),
        PRAGUE_CALLDATA_FLOOR_GAS_PER_TOKEN,
    ) catch return TxError.IntrinsicGasExceedsLimit;
    return std.math.add(u64, INTRINSIC_GAS, data_floor) catch return TxError.IntrinsicGasExceedsLimit;
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
    var ecrecover_context = StandardPrecompileContext{
        .address = primitives.Address.fromU256(1),
        .fork = hardfork,
    };
    const effective_precompile_overrides = blk: {
        const overrides = allocator.alloc(guillotine_mini.PrecompileOverride, options.precompile_overrides.len + 1) catch return TxError.OutOfMemory;
        @memcpy(overrides[0..options.precompile_overrides.len], options.precompile_overrides);
        overrides[options.precompile_overrides.len] = .{
            .address = ecrecover_context.address,
            .execute = executeStandardPrecompile,
            .context = &ecrecover_context,
        };
        break :blk overrides;
    };
    defer allocator.free(effective_precompile_overrides);

    if (!transactionTypeSupported(options.receipt_type, hardfork)) return TxError.UnsupportedTransactionType;
    if (tx.gas_limit > block_ctx.block_gas_limit) return TxError.BlockGasLimitExceeded;

    if (!options.skip_sender_eoa_check) {
        const sender_code = sm.getCode(caller) catch return TxError.StateError;
        if (sender_code.len != 0 and !(hardfork.isAtLeast(.PRAGUE) and isValidDelegationCode(sender_code))) {
            return TxError.SenderNotEOA;
        }
    }

    const current_nonce = sm.getNonce(caller) catch return TxError.StateError;
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
    const blob_gas_price: u256 = if (options.receipt_type == .eip4844) options.blob_gas_price orelse block_ctx.blob_base_fee else 0;
    const max_fee_per_blob_gas: u256 = if (options.receipt_type == .eip4844) options.max_fee_per_blob_gas orelse 0 else 0;
    if (!options.skip_fee_validation and options.receipt_type == .eip4844 and max_fee_per_blob_gas < blob_gas_price) return TxError.GasPriceBelowBaseFee;

    // EIP-1559 base-fee floor: non-dynamic-fee txs must pay at least the block base fee.
    const base_fee: u256 = if (hardfork.isAtLeast(.LONDON)) block_ctx.block_base_fee else 0;
    if (!options.skip_fee_validation and !is_dynamic_fee and tx.gas_price < base_fee) return TxError.GasPriceBelowBaseFee;

    const computed_effective_gas_price: u256 = if (is_dynamic_fee) blk: {
        const max_fee_per_gas = options.max_fee_per_gas orelse tx.gas_price;
        const max_priority_fee_per_gas = options.max_priority_fee_per_gas orelse 0;
        break :blk @min(max_fee_per_gas, base_fee + max_priority_fee_per_gas);
    } else tx.gas_price;
    const balance_check_gas_price: u256 = if (is_dynamic_fee)
        options.max_fee_per_gas orelse tx.gas_price
    else
        computed_effective_gas_price;
    const potential_max_gas_cost = std.math.mul(u256, balance_check_gas_price, @as(u256, tx.gas_limit)) catch return TxError.InsufficientBalance;
    const potential_max_blob_gas_cost = std.math.mul(u256, max_fee_per_blob_gas, blob_gas_used) catch return TxError.InsufficientBalance;
    const potential_max_fee_cost = std.math.add(u256, potential_max_gas_cost, potential_max_blob_gas_cost) catch return TxError.InsufficientBalance;
    const total_cost = std.math.add(u256, tx.value, potential_max_fee_cost) catch return TxError.InsufficientBalance;
    const balance = sm.getBalance(caller) catch return TxError.StateError;
    var charge_fees = true;
    if (balance < total_cost) {
        if (!options.skip_fee_balance_check or balance < tx.value) return TxError.InsufficientBalance;
        charge_fees = false;
    }
    const effective_gas_price: u256 = if (charge_fees) computed_effective_gas_price else 0;
    const effective_blob_gas_price: u256 = if (charge_fees) blob_gas_price else 0;
    const max_gas_cost: u256 = if (charge_fees) potential_max_gas_cost else 0;
    const max_blob_gas_cost: u256 = if (charge_fees) potential_max_blob_gas_cost else 0;
    const max_fee_cost: u256 = if (charge_fees) potential_max_fee_cost else 0;

    sm.checkpoint() catch return TxError.StateError;
    var transaction_checkpoint_open = true;
    errdefer if (transaction_checkpoint_open) sm.revert();

    sm.setBalance(caller, balance - max_fee_cost) catch return TxError.StateError;
    if (!options.skip_nonce_state_increment) {
        const next_nonce = if (options.skip_nonce_validation)
            current_nonce +% 1
        else
            std.math.add(u64, tx.nonce, 1) catch return TxError.NonceMismatch;
        sm.setNonce(caller, next_nonce) catch return TxError.StateError;
    }

    const authorization_refund = applySetCodeAuthorizations(
        sm,
        adapter,
        block_ctx.chain_id,
        if (options.receipt_type == .eip7702) options.authorization_list else null,
    ) catch return TxError.StateError;

    sm.checkpoint() catch return TxError.StateError;
    var evm_checkpoint_open = true;
    errdefer if (evm_checkpoint_open) sm.revert();

    const execution_gas = tx.gas_limit - intrinsic;

    var result = blk: {
        const EvmType = evm_overrides.EvmType;
        var evm: EvmType = undefined;
        evm.init(
            allocator,
            host_iface,
            hardfork,
            block_ctx,
            caller,
            effective_gas_price,
            null,
        ) catch {
            return TxError.EvmInitError;
        };
        defer evm.deinit();
        evm.initTransactionState(null) catch {
            return TxError.EvmInitError;
        };
        evm.precompile_overrides = effective_precompile_overrides;
        if (options.blob_versioned_hashes) |hashes| {
            evm.setBlobVersionedHashes(hashes);
        }

        // The EVM's call() reads code from `pending_bytecode` for CALLs and
        // ignores it for CREATEs (init_code is in CallParams). For CALLs to a
        // contract, we must hand the EVM the deployed code; for CREATEs we
        // also seed it with the init code so the top-level frame can execute.
        if (tx.to) |to| {
            const code = sm.getCode(to) catch return TxError.StateError;
            evm.setBytecode(code);
        } else {
            evm.setBytecode(tx.data);
        }
        evm.setAccessList(options.access_list);

        const call_params: EvmType.CallParams = if (tx.to) |to|
            .{ .call = .{
                .caller = caller,
                .to = to,
                .value = tx.value,
                .input = tx.data,
                .gas = execution_gas,
            } }
        else
            .{ .create = .{
                .caller = caller,
                .value = tx.value,
                .init_code = tx.data,
                .gas = execution_gas,
            } };

        if (tx.to) |to| {
            const code = sm.getCode(to) catch return TxError.StateError;
            if (code.len == 0) {
                if (findPrecompileOverride(effective_precompile_overrides, to)) |override| {
                    if (tx.value > 0) {
                        const caller_balance = sm.getBalance(caller) catch return TxError.StateError;
                        if (caller_balance < tx.value) return TxError.InsufficientBalance;
                        const target_balance = sm.getBalance(to) catch return TxError.StateError;
                        sm.setBalance(caller, caller_balance - tx.value) catch return TxError.StateError;
                        sm.setBalance(to, std.math.add(u256, target_balance, tx.value) catch return TxError.StateError) catch return TxError.StateError;
                    }
                    break :blk try executePrecompileOverrideOwned(
                        @TypeOf(evm.call(call_params)),
                        allocator,
                        override,
                        tx.data,
                        execution_gas,
                    );
                }
            }
        }

        break :blk evm.call(call_params).toOwnedResult(allocator) catch return TxError.OutOfMemory;
    };
    defer result.deinit(allocator);

    try consumeHostError(adapter);
    if (options.capture_output) |output| {
        const captured = if (tx.to == null and result.success) blk: {
            if (result.created_address) |created| {
                break :blk sm.getCode(created) catch return TxError.StateError;
            }
            break :blk result.output;
        } else result.output;
        output.* = allocator.dupe(u8, captured) catch return TxError.OutOfMemory;
    }

    if (result.success) {
        sm.commit();
        if (hardfork.isBefore(.SPURIOUS_DRAGON)) {
            if (result.created_address) |created| {
                sm.setNonce(created, 0) catch return TxError.StateError;
            }
        }
    } else {
        sm.revert();
    }
    evm_checkpoint_open = false;

    const gas_consumed = if (result.gas_left > execution_gas) 0 else execution_gas - result.gas_left;
    const total_gas_used = @max(intrinsic + gas_consumed, gas_floor);
    const max_refund = if (hardfork.isAtLeast(.LONDON))
        total_gas_used / 5
    else
        total_gas_used / 2;
    const refund_counter = std.math.add(u64, result.refund_counter, authorization_refund) catch std.math.maxInt(u64);
    const refund = @min(refund_counter, max_refund);
    const effective_gas_used = total_gas_used - refund;
    const effective_gas_used_u256: u256 = @as(u256, effective_gas_used);

    const charged_gas_wei = std.math.mul(u256, effective_gas_price, effective_gas_used_u256) catch return TxError.StateError;
    const gas_refund_wei = max_gas_cost - charged_gas_wei;
    const charged_blob_gas_wei = std.math.mul(u256, effective_blob_gas_price, blob_gas_used) catch return TxError.StateError;
    const blob_gas_refund_wei = max_blob_gas_cost - charged_blob_gas_wei;
    const total_refund_wei = std.math.add(u256, gas_refund_wei, blob_gas_refund_wei) catch return TxError.StateError;
    const caller_balance = sm.getBalance(caller) catch return TxError.StateError;
    sm.setBalance(caller, std.math.add(u256, caller_balance, total_refund_wei) catch return TxError.StateError) catch return TxError.StateError;

    // EIP-1559 settlement: coinbase only earns the priority tip
    // (effective_gas_price - base_fee). Base fee is burned (not credited to
    // anyone). When base_fee == 0 (pre-London or test contexts) this collapses
    // to the legacy "all of gas_price goes to the miner" behavior.
    const priority_per_gas: u256 = if (effective_gas_price > base_fee) effective_gas_price - base_fee else 0;
    if (priority_per_gas > 0) {
        const coinbase_payment = std.math.mul(u256, priority_per_gas, effective_gas_used_u256) catch return TxError.StateError;
        const coinbase_balance = sm.getBalance(block_ctx.block_coinbase) catch return TxError.StateError;
        sm.setBalance(block_ctx.block_coinbase, std.math.add(u256, coinbase_balance, coinbase_payment) catch return TxError.StateError) catch return TxError.StateError;
    }

    const logs = try allocateEventLogs(allocator, result.logs);
    errdefer {
        for (logs) |event_log| {
            allocator.free(event_log.topics);
            allocator.free(event_log.data);
        }
        allocator.free(logs);
    }

    const tx_hash = try computeLegacyTxHash(allocator, tx);

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

    return receipt;
}

fn applySetCodeAuthorizations(
    sm: *state_manager.StateManager,
    adapter: ?*host_adapter.HostAdapter,
    chain_id: u256,
    maybe_authorizations: ?[]const primitives.Authorization.Authorization,
) !u64 {
    const authorizations = maybe_authorizations orelse return 0;
    var refund_counter: u64 = 0;

    for (authorizations) |auth| {
        if (auth.chain_id != 0 and @as(u256, auth.chain_id) != chain_id) continue;
        if (auth.nonce == std.math.maxInt(u64)) continue;

        const authority = auth.authority() catch continue;
        const authority_code = try sm.getCode(authority);
        if (authority_code.len != 0 and !isValidDelegationCode(authority_code)) continue;

        const authority_nonce = try sm.getNonce(authority);
        if (authority_nonce != auth.nonce) continue;

        if (try accountExists(sm, adapter, authority)) {
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
    }

    return refund_counter;
}

fn isValidDelegationCode(code: []const u8) bool {
    return code.len == EOA_DELEGATED_CODE_LENGTH and
        std.mem.eql(u8, code[0..EOA_DELEGATION_MARKER.len], &EOA_DELEGATION_MARKER);
}

fn accountExists(
    sm: *state_manager.StateManager,
    adapter: ?*host_adapter.HostAdapter,
    address: primitives.Address,
) !bool {
    if (adapter) |a| return try a.accountExists(address);

    if (sm.journaled_state.account_cache.has(address)) return true;
    if (sm.journaled_state.contract_cache.has(address)) return true;
    if (sm.journaled_state.storage_cache.cache.contains(address)) return true;

    if (sm.journaled_state.fork_backend != null) {
        _ = try sm.journaled_state.getAccount(address);
        return sm.journaled_state.account_cache.has(address);
    }

    return false;
}
