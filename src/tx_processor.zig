const std = @import("std");
const primitives = @import("primitives");
const state_manager = @import("state-manager");
const guillotine_mini = @import("guillotine_mini");
const host_adapter = @import("host_adapter.zig");
const tx_encoding = @import("transaction_encoding.zig");
const hardfork_schedule = @import("hardfork_schedule.zig");
const INTRINSIC_GAS: u64 = 21_000;
const CALLDATA_ZERO_BYTE_GAS: u64 = 4;
const CALLDATA_NONZERO_BYTE_GAS: u64 = 16;
const CREATE_GAS: u64 = 32_000;
const INITCODE_WORD_GAS: u64 = 2;

pub const ExecutionTx = struct {
    caller: primitives.Address,
    tx: primitives.Transaction.LegacyTransaction,
};

pub const ProcessTransactionOptions = struct {
    access_list: ?primitives.AccessList.AccessList = null,
    receipt_type: primitives.Receipt.TransactionType = .legacy,
    max_fee_per_gas: ?u256 = null,
    max_priority_fee_per_gas: ?u256 = null,
    hardfork_override: ?guillotine_mini.Hardfork = null,

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
    if (!transactionTypeSupported(options.receipt_type, hardfork)) return TxError.UnsupportedTransactionType;
    if (tx.gas_limit > block_ctx.block_gas_limit) return TxError.BlockGasLimitExceeded;

    const sender_code = sm.getCode(caller) catch return TxError.StateError;
    if (sender_code.len != 0) return TxError.SenderNotEOA;

    const current_nonce = sm.getNonce(caller) catch return TxError.StateError;
    if (current_nonce != tx.nonce) return TxError.NonceMismatch;

    var intrinsic = intrinsicGasForFork(tx.data, tx.to == null, hardfork);
    if (options.access_list) |access_list| {
        intrinsic = std.math.add(u64, intrinsic, primitives.AccessList.calculateAccessListGasCost(access_list)) catch return TxError.IntrinsicGasExceedsLimit;
    }
    if (intrinsic > tx.gas_limit) return TxError.IntrinsicGasExceedsLimit;

    if (options.receipt_type == .eip1559) {
        const max_fee_per_gas = options.max_fee_per_gas orelse tx.gas_price;
        const max_priority_fee_per_gas = options.max_priority_fee_per_gas orelse 0;
        if (max_priority_fee_per_gas > max_fee_per_gas) return TxError.TipExceedsFeeCap;
        if (max_fee_per_gas < block_ctx.block_base_fee) return TxError.GasPriceBelowBaseFee;
    }

    // EIP-1559 base-fee floor: non-dynamic-fee txs must pay at least the block base fee.
    const base_fee: u256 = if (hardfork.isAtLeast(.LONDON)) block_ctx.block_base_fee else 0;
    if (options.receipt_type != .eip1559 and tx.gas_price < base_fee) return TxError.GasPriceBelowBaseFee;

    const effective_gas_price: u256 = tx.gas_price;
    const balance_check_gas_price: u256 = if (options.receipt_type == .eip1559)
        options.max_fee_per_gas orelse tx.gas_price
    else
        effective_gas_price;
    const max_gas_cost = effective_gas_price * @as(u256, tx.gas_limit);
    const total_cost = tx.value + balance_check_gas_price * @as(u256, tx.gas_limit);
    const balance = sm.getBalance(caller) catch return TxError.StateError;
    if (balance < total_cost) return TxError.InsufficientBalance;

    sm.checkpoint() catch return TxError.StateError;
    var transaction_checkpoint_open = true;
    errdefer if (transaction_checkpoint_open) sm.revert();

    sm.setBalance(caller, balance - max_gas_cost) catch return TxError.StateError;
    sm.setNonce(caller, current_nonce + 1) catch return TxError.StateError;

    sm.checkpoint() catch return TxError.StateError;
    var evm_checkpoint_open = true;
    errdefer if (evm_checkpoint_open) sm.revert();

    const execution_gas = tx.gas_limit - intrinsic;

    var result = blk: {
        const EvmType = guillotine_mini.Evm(.{});
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

        break :blk evm.call(call_params).toOwnedResult(allocator) catch return TxError.OutOfMemory;
    };
    defer result.deinit(allocator);

    try consumeHostError(adapter);

    if (result.success) {
        sm.commit();
    } else {
        sm.revert();
    }
    evm_checkpoint_open = false;

    const gas_consumed = if (result.gas_left > execution_gas) 0 else execution_gas - result.gas_left;
    const total_gas_used = intrinsic + gas_consumed;
    const max_refund = if (hardfork.isAtLeast(.LONDON))
        total_gas_used / 5
    else
        total_gas_used / 2;
    const refund = @min(result.refund_counter, max_refund);
    const effective_gas_used = total_gas_used - refund;
    const effective_gas_used_u256: u256 = @as(u256, effective_gas_used);

    const gas_refund_wei = effective_gas_price * @as(u256, tx.gas_limit - effective_gas_used);
    const caller_balance = sm.getBalance(caller) catch return TxError.StateError;
    sm.setBalance(caller, caller_balance + gas_refund_wei) catch return TxError.StateError;

    // EIP-1559 settlement: coinbase only earns the priority tip
    // (effective_gas_price - base_fee). Base fee is burned (not credited to
    // anyone). When base_fee == 0 (pre-London or test contexts) this collapses
    // to the legacy "all of gas_price goes to the miner" behavior.
    const priority_per_gas: u256 = effective_gas_price - base_fee;
    if (priority_per_gas > 0) {
        const coinbase_payment = priority_per_gas * effective_gas_used_u256;
        const coinbase_balance = sm.getBalance(block_ctx.block_coinbase) catch return TxError.StateError;
        sm.setBalance(block_ctx.block_coinbase, coinbase_balance + coinbase_payment) catch return TxError.StateError;
    }

    var logs_bloom: [256]u8 = undefined;
    @memset(&logs_bloom, 0);

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
        .logs = try allocateEventLogs(allocator, result.logs),
        .logs_bloom = logs_bloom,
        .status = primitives.Receipt.TransactionStatus{ .success = result.success, .gas_used = effective_gas_used_u256 },
        .root = null,
        .effective_gas_price = effective_gas_price,
        .type = options.receipt_type,
        .blob_gas_used = null,
        .blob_gas_price = null,
    };

    sm.commit();
    transaction_checkpoint_open = false;

    return receipt;
}
