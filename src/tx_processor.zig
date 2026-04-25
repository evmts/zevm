const std = @import("std");
const primitives = @import("primitives");
const state_manager = @import("state-manager");
const guillotine_mini = @import("guillotine_mini");
const INTRINSIC_GAS: u64 = 21_000;
const CALLDATA_ZERO_BYTE_GAS: u64 = 4;
const CALLDATA_NONZERO_BYTE_GAS: u64 = 16;
const CREATE_GAS: u64 = 32_000;

pub const ExecutionTx = struct {
    caller: primitives.Address,
    tx: primitives.Transaction.LegacyTransaction,
};

pub const TxError = error{
    InsufficientBalance,
    NonceMismatch,
    IntrinsicGasExceedsLimit,
    StateError,
    EvmInitError,
    OutOfMemory,
};

/// Calculates the intrinsic gas cost for a transaction.
pub fn intrinsicGas(data: []const u8, is_create: bool) u64 {
    var gas: u64 = INTRINSIC_GAS;
    if (is_create) {
        gas += CREATE_GAS;
    }
    for (data) |byte| {
        gas += if (byte == 0) CALLDATA_ZERO_BYTE_GAS else CALLDATA_NONZERO_BYTE_GAS;
    }
    return gas;
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
    chain_id: u64,
) TxError!primitives.Hash.Hash {
    const encoded = primitives.Transaction.encodeLegacyForSigning(allocator, tx, chain_id) catch return TxError.OutOfMemory;
    defer allocator.free(encoded);
    var out: primitives.Hash.Hash = undefined;
    std.crypto.hash.sha3.Keccak256.hash(encoded, &out, .{});
    return out;
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
    // Validate nonce
    const current_nonce = sm.getNonce(caller) catch return TxError.StateError;
    if (current_nonce != tx.nonce) return TxError.NonceMismatch;

    // Calculate intrinsic gas
    const intrinsic = intrinsicGas(tx.data, tx.to == null);
    if (intrinsic > tx.gas_limit) return TxError.IntrinsicGasExceedsLimit;

    // Validate balance covers value + gas cost
    const max_gas_cost = tx.gas_price * @as(u256, tx.gas_limit);
    const total_cost = tx.value + max_gas_cost;
    const balance = sm.getBalance(caller) catch return TxError.StateError;
    if (balance < total_cost) return TxError.InsufficientBalance;

    // Deduct gas cost upfront and increment nonce — these persist on revert
    sm.setBalance(caller, balance - max_gas_cost) catch return TxError.StateError;
    sm.setNonce(caller, current_nonce + 1) catch return TxError.StateError;

    // Checkpoint AFTER gas/nonce so revert only undoes EVM state changes
    sm.checkpoint() catch return TxError.StateError;

    // Calculate execution gas (gas available after intrinsic costs)
    const execution_gas = tx.gas_limit - intrinsic;

    // Always route through EVM — it handles value transfers, EOA calls,
    // and precompile dispatch internally.
    var result = blk: {
        const EvmType = guillotine_mini.Evm(.{});
        var evm = EvmType.init(allocator, host_iface, null, block_ctx, null) catch {
            sm.revert();
            return TxError.EvmInitError;
        };
        defer evm.deinit();
        evm.initTransactionState(null) catch {
            sm.revert();
            return TxError.EvmInitError;
        };

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

    // Commit or revert EVM state changes (gas/nonce already applied above checkpoint)
    if (result.success) {
        sm.commit();
    } else {
        sm.revert();
    }

    // Gas accounting — applied on top of final state
    const gas_consumed = execution_gas - result.gas_left;
    const total_gas_used = intrinsic + gas_consumed;
    const max_refund = total_gas_used / 5;
    const refund = @min(result.refund_counter, max_refund);
    const effective_gas_used = total_gas_used - refund;
    const effective_gas_used_u256: u256 = @as(u256, effective_gas_used);

    // Refund unused gas to caller
    const gas_refund_wei = tx.gas_price * @as(u256, tx.gas_limit - effective_gas_used);
    const caller_balance = sm.getBalance(caller) catch return TxError.StateError;
    sm.setBalance(caller, caller_balance + gas_refund_wei) catch return TxError.StateError;

    // Pay coinbase
    const coinbase_payment = tx.gas_price * @as(u256, effective_gas_used);
    const coinbase_balance = sm.getBalance(block_ctx.block_coinbase) catch return TxError.StateError;
    sm.setBalance(block_ctx.block_coinbase, coinbase_balance + coinbase_payment) catch return TxError.StateError;

    var logs_bloom: [256]u8 = undefined;
    @memset(&logs_bloom, 0);

    const tx_hash = try computeLegacyTxHash(allocator, tx, @as(u64, @intCast(block_ctx.chain_id)));

    return primitives.Receipt.Receipt{
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
        .effective_gas_price = tx.gas_price,
        .type = primitives.Receipt.TransactionType.legacy,
        .blob_gas_used = null,
        .blob_gas_price = null,
    };
}
