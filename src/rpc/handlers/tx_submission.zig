const std = @import("std");
const primitives = @import("primitives");
const crypto = @import("crypto");
const jsonrpc = @import("jsonrpc");
const guillotine_mini = @import("guillotine_mini");
const runtime = @import("../../node/runtime.zig");
const host_adapter = @import("../../host_adapter.zig");
const tx_processor = @import("../../tx_processor.zig");
const receipt_index = @import("../../receipt_index.zig");
const log_index = @import("../../log_index.zig");

pub const TxSubmissionError = error{
    InvalidHexData,
    DecodeFailed,
    SenderRecoveryFailed,
    ChainIdMismatch,
    NonceMismatch,
    InsufficientBalance,
    IntrinsicGasExceedsLimit,
    PoolInsertFailed,
    UnmanagedAccount,
    SigningFailed,
    OutOfMemory,
    StateError,
};

const HostForkResolverContext = struct {
    allocator: std.mem.Allocator,
    node_runtime: *runtime.NodeRuntime,
};

fn resolveHostForkPending(context: *anyopaque) bool {
    const typed_context: *HostForkResolverContext = @ptrCast(@alignCast(context));
    return typed_context.node_runtime.processForkRequests(typed_context.allocator) catch false;
}

pub const MiningIndexes = struct {
    receipt_index: *receipt_index.ReceiptIndex,
    log_index: *log_index.LogIndex,
};

fn runAutomineForSubmission(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    indexes: ?MiningIndexes,
) TxSubmissionError!void {
    automine(allocator, rt, indexes) catch |err| switch (err) {
        error.OutOfMemory => return TxSubmissionError.OutOfMemory,
        else => return TxSubmissionError.StateError,
    };
}

pub fn handleSendRawTransaction(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: jsonrpc.eth.SendRawTransaction.Params,
) TxSubmissionError!jsonrpc.eth.SendRawTransaction.Result {
    return handleSendRawTransactionWithIndexes(allocator, rt, params, null);
}

pub fn handleSendRawTransactionWithIndexes(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: jsonrpc.eth.SendRawTransaction.Params,
    indexes: ?MiningIndexes,
) TxSubmissionError!jsonrpc.eth.SendRawTransaction.Result {
    // Extract hex string from the Quantity param
    const hex_str = switch (params.transaction.value) {
        .string => |s| s,
        else => return TxSubmissionError.InvalidHexData,
    };

    // Decode hex to bytes
    const raw_bytes = primitives.Hex.hexToBytes(allocator, hex_str) catch return TxSubmissionError.InvalidHexData;
    defer allocator.free(raw_bytes);

    // Decode the raw transaction
    const decoded = primitives.Transaction.decodeRawTransaction(allocator, raw_bytes) catch return TxSubmissionError.DecodeFailed;
    defer primitives.Transaction.deinitDecodedTransaction(allocator, decoded);

    // Validate chain ID
    primitives.Transaction.validateChainId(decoded, rt.chain_id) catch return TxSubmissionError.ChainIdMismatch;

    // Recover sender
    const sender = primitives.Transaction.recoverSender(allocator, decoded) catch return TxSubmissionError.SenderRecoveryFailed;

    // Extract fields needed for validation and pool insertion
    const nonce = extractNonce(decoded);
    const gas_limit = extractGasLimit(decoded);
    const gas_price = extractGasPrice(decoded);
    const value = extractValue(decoded);
    const data = extractData(decoded);

    // Validate nonce against state
    const current_nonce = rt.getNonceWithFork(allocator, sender) catch return TxSubmissionError.StateError;
    if (current_nonce != nonce) return TxSubmissionError.NonceMismatch;

    // Validate intrinsic gas
    const is_create = extractTo(decoded) == null;
    const intrinsic = tx_processor.intrinsicGas(data, is_create);
    if (intrinsic > gas_limit) return TxSubmissionError.IntrinsicGasExceedsLimit;

    // Validate balance covers value + gas cost
    const max_gas_cost = gas_price * @as(u256, gas_limit);
    const total_cost = value + max_gas_cost;
    const balance = rt.getBalanceWithFork(allocator, sender) catch return TxSubmissionError.StateError;
    if (balance < total_cost) return TxSubmissionError.InsufficientBalance;

    // Compute tx hash from raw bytes
    const tx_hash = computeTxHash(raw_bytes);

    // Insert into txpool
    rt.pool.setNonce(sender, current_nonce) catch return TxSubmissionError.PoolInsertFailed;
    rt.pool.add(allocator, .{
        .sender = sender,
        .nonce = nonce,
        .gas_limit = gas_limit,
        .max_fee_per_gas = gas_price,
        .max_priority_fee_per_gas = extractPriorityFee(decoded),
        .hash = tx_hash,
    }) catch |err| switch (err) {
        error.ReplacementUnderpriced => return TxSubmissionError.PoolInsertFailed,
        error.OutOfMemory => return TxSubmissionError.OutOfMemory,
    };
    rt.putTransactionRecord(allocator, tx_hash, sender, raw_bytes) catch return TxSubmissionError.OutOfMemory;
    rt.recordPendingTransaction(allocator, tx_hash) catch return TxSubmissionError.OutOfMemory;

    // Automine if in auto mode
    if (rt.mining_mode == .auto) {
        try runAutomineForSubmission(allocator, rt, indexes);
    }

    return .{ .value = .{ .bytes = tx_hash } };
}

pub fn handleSendTransaction(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: jsonrpc.eth.SendTransaction.Params,
) TxSubmissionError!jsonrpc.eth.SendTransaction.Result {
    return handleSendTransactionWithIndexes(allocator, rt, params, null);
}

pub fn handleSendTransactionWithIndexes(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: jsonrpc.eth.SendTransaction.Params,
    indexes: ?MiningIndexes,
) TxSubmissionError!jsonrpc.eth.SendTransaction.Result {
    // Parse the transaction object from the JSON value
    const tx_obj = switch (params.transaction.value) {
        .object => |obj| obj,
        else => return TxSubmissionError.InvalidHexData,
    };

    // Extract 'from' address
    const from_val = tx_obj.get("from") orelse return TxSubmissionError.InvalidHexData;
    const from_str = switch (from_val) {
        .string => |s| s,
        else => return TxSubmissionError.InvalidHexData,
    };
    const from_addr = primitives.Address.fromHex(from_str) catch return TxSubmissionError.InvalidHexData;

    // Managed accounts are signed locally. Impersonated accounts bypass signature checks.
    const private_key = runtime.NodeRuntime.lookupManagedAccount(from_addr);
    if (private_key == null and !rt.isImpersonated(from_addr)) {
        return TxSubmissionError.UnmanagedAccount;
    }

    // Extract fields
    const nonce = blk: {
        if (tx_obj.get("nonce")) |nonce_val| {
            break :blk parseJsonQuantityToU64(nonce_val) catch return TxSubmissionError.InvalidHexData;
        }
        break :blk rt.getNonceWithFork(allocator, from_addr) catch return TxSubmissionError.StateError;
    };

    const gas_limit: u64 = blk: {
        if (tx_obj.get("gas")) |gas_val| {
            break :blk parseJsonQuantityToU64(gas_val) catch return TxSubmissionError.InvalidHexData;
        }
        break :blk 21_000;
    };

    const gas_price: u256 = blk: {
        if (tx_obj.get("gasPrice")) |gp_val| {
            break :blk parseJsonQuantityToU256(gp_val) catch return TxSubmissionError.InvalidHexData;
        }
        break :blk rt.gas_price;
    };

    const max_priority_fee_per_gas: u256 = blk: {
        if (tx_obj.get("maxPriorityFeePerGas")) |priority_val| {
            break :blk parseJsonQuantityToU256(priority_val) catch return TxSubmissionError.InvalidHexData;
        }
        break :blk rt.max_priority_fee;
    };

    const max_fee_per_gas: u256 = blk: {
        if (tx_obj.get("maxFeePerGas")) |max_fee_val| {
            break :blk parseJsonQuantityToU256(max_fee_val) catch return TxSubmissionError.InvalidHexData;
        }
        break :blk gas_price;
    };

    const max_fee_per_blob_gas: u256 = blk: {
        if (tx_obj.get("maxFeePerBlobGas")) |blob_fee_val| {
            break :blk parseJsonQuantityToU256(blob_fee_val) catch return TxSubmissionError.InvalidHexData;
        }
        break :blk 0;
    };

    const value: u256 = blk: {
        if (tx_obj.get("value")) |v_val| {
            break :blk parseJsonQuantityToU256(v_val) catch return TxSubmissionError.InvalidHexData;
        }
        break :blk 0;
    };

    const to: ?primitives.Address = blk: {
        if (tx_obj.get("to")) |to_val| {
            break :blk switch (to_val) {
                .null => null,
                .string => |to_str| primitives.Address.fromHex(to_str) catch return TxSubmissionError.InvalidHexData,
                else => return TxSubmissionError.InvalidHexData,
            };
        }
        break :blk null;
    };

    const data_bytes: []const u8 = blk: {
        if (tx_obj.get("data") orelse tx_obj.get("input")) |data_val| {
            const data_str = switch (data_val) {
                .string => |s| s,
                else => return TxSubmissionError.InvalidHexData,
            };
            break :blk primitives.Hex.hexToBytes(allocator, data_str) catch return TxSubmissionError.InvalidHexData;
        }
        break :blk &[_]u8{};
    };
    defer if (data_bytes.len > 0) allocator.free(data_bytes);

    const tx_type = parseSendTransactionType(tx_obj) catch return TxSubmissionError.InvalidHexData;
    const access_list = parseAccessList(allocator, tx_obj) catch return TxSubmissionError.InvalidHexData;
    defer deinitAccessList(allocator, access_list);
    const blob_versioned_hashes = parseBlobVersionedHashes(allocator, tx_obj, tx_type == .eip4844) catch return TxSubmissionError.InvalidHexData;
    defer allocator.free(blob_versioned_hashes);
    const authorization_list = parseAuthorizationList(allocator, tx_obj) catch return TxSubmissionError.InvalidHexData;
    defer allocator.free(authorization_list);

    if (tx_type == .eip4844 and max_fee_per_blob_gas == 0) {
        return TxSubmissionError.InvalidHexData;
    }

    // Encode the transaction to raw bytes.
    // Impersonated accounts keep unsigned legacy compatibility semantics.
    const encoded = blk: {
        if (private_key == null and rt.isImpersonated(from_addr)) {
            const unsigned_legacy = primitives.Transaction.LegacyTransaction{
                .nonce = nonce,
                .gas_price = gas_price,
                .gas_limit = gas_limit,
                .to = to,
                .value = value,
                .data = data_bytes,
                .v = 0,
                .r = [_]u8{0} ** 32,
                .s = [_]u8{0} ** 32,
            };
            break :blk primitives.Transaction.encodeLegacyForSigning(allocator, unsigned_legacy, rt.chain_id) catch
                return TxSubmissionError.OutOfMemory;
        }

        const pk = private_key orelse return TxSubmissionError.SigningFailed;
        switch (tx_type) {
            .legacy => {
                const unsigned_legacy = primitives.Transaction.LegacyTransaction{
                    .nonce = nonce,
                    .gas_price = gas_price,
                    .gas_limit = gas_limit,
                    .to = to,
                    .value = value,
                    .data = data_bytes,
                    .v = 0,
                    .r = [_]u8{0} ** 32,
                    .s = [_]u8{0} ** 32,
                };
                const signed_legacy = primitives.Transaction.signLegacyTransaction(allocator, unsigned_legacy, pk, rt.chain_id) catch
                    return TxSubmissionError.SigningFailed;
                break :blk primitives.Transaction.encodeLegacyForSigning(allocator, signed_legacy, rt.chain_id) catch
                    return TxSubmissionError.OutOfMemory;
            },
            .eip2930 => {
                const unsigned_2930 = primitives.Transaction.Eip2930Transaction{
                    .chain_id = rt.chain_id,
                    .nonce = nonce,
                    .gas_price = gas_price,
                    .gas_limit = gas_limit,
                    .to = to,
                    .value = value,
                    .data = data_bytes,
                    .access_list = access_list,
                    .y_parity = 0,
                    .r = [_]u8{0} ** 32,
                    .s = [_]u8{0} ** 32,
                };
                const signed_2930 = primitives.Transaction.signEip2930Transaction(allocator, unsigned_2930, pk) catch
                    return TxSubmissionError.SigningFailed;
                break :blk primitives.Transaction.encodeEip2930ForSigning(allocator, signed_2930) catch
                    return TxSubmissionError.OutOfMemory;
            },
            .eip1559 => {
                var signed_1559 = primitives.Transaction.Eip1559Transaction{
                    .chain_id = rt.chain_id,
                    .nonce = nonce,
                    .max_priority_fee_per_gas = max_priority_fee_per_gas,
                    .max_fee_per_gas = max_fee_per_gas,
                    .gas_limit = gas_limit,
                    .to = to,
                    .value = value,
                    .data = data_bytes,
                    .access_list = access_list,
                    .y_parity = 0,
                    .r = [_]u8{0} ** 32,
                    .s = [_]u8{0} ** 32,
                };
                const signing_payload = primitives.Transaction.encodeEip1559ForSigning(allocator, signed_1559) catch
                    return TxSubmissionError.OutOfMemory;
                defer allocator.free(signing_payload);

                const signing_hash = crypto.Hash.keccak256(signing_payload);
                const signature = crypto.Crypto.unaudited_signHash(signing_hash, pk) catch
                    return TxSubmissionError.SigningFailed;
                signed_1559.y_parity = signature.recoveryId();
                std.mem.writeInt(u256, &signed_1559.r, signature.r, .big);
                std.mem.writeInt(u256, &signed_1559.s, signature.s, .big);

                break :blk primitives.Transaction.encodeEip1559ForSigning(allocator, signed_1559) catch
                    return TxSubmissionError.OutOfMemory;
            },
            .eip4844 => {
                var signed_4844 = primitives.Transaction.Eip4844Transaction{
                    .chain_id = rt.chain_id,
                    .nonce = nonce,
                    .max_priority_fee_per_gas = max_priority_fee_per_gas,
                    .max_fee_per_gas = max_fee_per_gas,
                    .gas_limit = gas_limit,
                    .to = to orelse return TxSubmissionError.InvalidHexData,
                    .value = value,
                    .data = data_bytes,
                    .access_list = access_list,
                    .max_fee_per_blob_gas = max_fee_per_blob_gas,
                    .blob_versioned_hashes = blob_versioned_hashes,
                    .y_parity = 0,
                    .r = [_]u8{0} ** 32,
                    .s = [_]u8{0} ** 32,
                };
                const signing_payload = primitives.Transaction.encodeEip4844ForSigning(allocator, signed_4844) catch
                    return TxSubmissionError.OutOfMemory;
                defer allocator.free(signing_payload);

                const signing_hash = crypto.Hash.keccak256(signing_payload);
                const signature = crypto.Crypto.unaudited_signHash(signing_hash, pk) catch
                    return TxSubmissionError.SigningFailed;
                signed_4844.y_parity = signature.recoveryId();
                std.mem.writeInt(u256, &signed_4844.r, signature.r, .big);
                std.mem.writeInt(u256, &signed_4844.s, signature.s, .big);

                break :blk primitives.Transaction.encodeEip4844ForSigning(allocator, signed_4844) catch
                    return TxSubmissionError.OutOfMemory;
            },
            .eip7702 => {
                var signed_7702 = primitives.Transaction.Eip7702Transaction{
                    .chain_id = rt.chain_id,
                    .nonce = nonce,
                    .max_priority_fee_per_gas = max_priority_fee_per_gas,
                    .max_fee_per_gas = max_fee_per_gas,
                    .gas_limit = gas_limit,
                    .to = to,
                    .value = value,
                    .data = data_bytes,
                    .access_list = access_list,
                    .authorization_list = authorization_list,
                    .y_parity = 0,
                    .r = [_]u8{0} ** 32,
                    .s = [_]u8{0} ** 32,
                };
                const signing_payload = primitives.Transaction.encodeEip7702ForSigning(allocator, signed_7702) catch
                    return TxSubmissionError.OutOfMemory;
                defer allocator.free(signing_payload);

                const signing_hash = crypto.Hash.keccak256(signing_payload);
                const signature = crypto.Crypto.unaudited_signHash(signing_hash, pk) catch
                    return TxSubmissionError.SigningFailed;
                signed_7702.y_parity = signature.recoveryId();
                std.mem.writeInt(u256, &signed_7702.r, signature.r, .big);
                std.mem.writeInt(u256, &signed_7702.s, signature.s, .big);

                break :blk primitives.Transaction.encodeEip7702ForSigning(allocator, signed_7702) catch
                    return TxSubmissionError.OutOfMemory;
            },
        }
    };
    defer allocator.free(encoded);

    // Compute tx hash
    const tx_hash = computeTxHash(encoded);

    // Validate nonce
    const current_nonce = rt.getNonceWithFork(allocator, from_addr) catch return TxSubmissionError.StateError;
    if (current_nonce != nonce) return TxSubmissionError.NonceMismatch;

    // Validate intrinsic gas
    const intrinsic = tx_processor.intrinsicGas(data_bytes, to == null);
    if (intrinsic > gas_limit) return TxSubmissionError.IntrinsicGasExceedsLimit;

    // Validate balance
    const max_gas_cost = (switch (tx_type) {
        .legacy => gas_price,
        .eip2930 => gas_price,
        .eip1559 => max_fee_per_gas,
        .eip4844 => max_fee_per_gas,
        .eip7702 => max_fee_per_gas,
    }) * @as(u256, gas_limit);
    const total_cost = value + max_gas_cost;
    const balance = rt.getBalanceWithFork(allocator, from_addr) catch return TxSubmissionError.StateError;
    if (balance < total_cost) return TxSubmissionError.InsufficientBalance;

    // Insert into txpool
    rt.pool.setNonce(from_addr, current_nonce) catch return TxSubmissionError.PoolInsertFailed;
    rt.pool.add(allocator, .{
        .sender = from_addr,
        .nonce = nonce,
        .gas_limit = gas_limit,
        .max_fee_per_gas = switch (tx_type) {
            .legacy => gas_price,
            .eip2930 => gas_price,
            .eip1559 => max_fee_per_gas,
            .eip4844 => max_fee_per_gas,
            .eip7702 => max_fee_per_gas,
        },
        .max_priority_fee_per_gas = switch (tx_type) {
            .legacy => gas_price,
            .eip2930 => gas_price,
            .eip1559 => max_priority_fee_per_gas,
            .eip4844 => max_priority_fee_per_gas,
            .eip7702 => max_priority_fee_per_gas,
        },
        .hash = tx_hash,
    }) catch |err| switch (err) {
        error.ReplacementUnderpriced => return TxSubmissionError.PoolInsertFailed,
        error.OutOfMemory => return TxSubmissionError.OutOfMemory,
    };
    rt.putTransactionRecord(allocator, tx_hash, from_addr, encoded) catch return TxSubmissionError.OutOfMemory;
    rt.recordPendingTransaction(allocator, tx_hash) catch return TxSubmissionError.OutOfMemory;

    // Automine if in auto mode
    if (rt.mining_mode == .auto) {
        try runAutomineForSubmission(allocator, rt, indexes);
    }

    return .{ .value = .{ .bytes = tx_hash } };
}

pub fn minePendingTransactions(allocator: std.mem.Allocator, rt: *runtime.NodeRuntime) !void {
    try automine(allocator, rt, null);
}

pub fn minePendingTransactionsWithIndexes(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    indexes: ?MiningIndexes,
) !void {
    try automine(allocator, rt, indexes);
}

fn automine(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    indexes: ?MiningIndexes,
) !void {
    const ready = try rt.pool.getReady(allocator);
    defer allocator.free(ready);

    if (ready.len == 0) return;

    const parent_hash = rt.head_block_hash;
    const next_block_number = rt.head_block_number + 1;
    const next_timestamp: u64 = rt.next_block_timestamp_override orelse if (rt.mining_mode == .interval and rt.interval_seconds > 0)
        rt.current_timestamp + rt.interval_seconds
    else
        rt.current_timestamp + 1;
    const next_base_fee = rt.next_block_base_fee_override orelse rt.base_fee;
    const block_ctx = guillotine_mini.BlockContext{
        .chain_id = rt.chain_id,
        .block_number = next_block_number,
        .block_timestamp = next_timestamp,
        .block_difficulty = 0,
        .block_prevrandao = rt.prev_randao,
        .block_coinbase = rt.coinbase,
        .block_gas_limit = rt.block_gas_limit,
        .block_base_fee = next_base_fee,
        .blob_base_fee = rt.blob_base_fee,
    };
    var host_fork_resolver_context = HostForkResolverContext{
        .allocator = allocator,
        .node_runtime = rt,
    };
    var adapter = host_adapter.HostAdapter{
        .state = &rt.state,
        .fork_resolver = .{
            .context = @ptrCast(&host_fork_resolver_context),
            .resolve = resolveHostForkPending,
        },
    };
    const host_iface = adapter.hostInterface();

    var mined_hashes = std.ArrayList([32]u8).empty;
    defer mined_hashes.deinit(allocator);
    var mined_receipts = std.ArrayList(primitives.Receipt.Receipt).empty;
    defer {
        for (mined_receipts.items) |receipt| {
            receipt.deinit(allocator);
        }
        mined_receipts.deinit(allocator);
    }
    var block_transactions = std.ArrayList(primitives.BlockBody.TransactionData).empty;
    defer block_transactions.deinit(allocator);

    var remaining_block_gas = rt.block_gas_limit;
    var cumulative_gas_used: u64 = 0;
    var global_log_index: u32 = 0;
    for (ready) |pooled_tx| {
        const record = rt.getTransactionRecord(pooled_tx.hash) orelse continue;
        const decoded = primitives.Transaction.decodeRawTransaction(allocator, record.raw) catch continue;
        defer primitives.Transaction.deinitDecodedTransaction(allocator, decoded);

        const tx_gas_limit = extractGasLimit(decoded);
        if (tx_gas_limit > remaining_block_gas) {
            continue;
        }

        const exec_tx = executionTxFromDecoded(record.sender, decoded, next_base_fee);
        var receipt = tx_processor.processTransaction(
            allocator,
            &rt.state,
            host_iface,
            exec_tx.caller,
            exec_tx.tx,
            block_ctx,
        ) catch continue;
        errdefer receipt.deinit(allocator);

        remaining_block_gas -= tx_gas_limit;
        const gas_used_u64 = std.math.cast(u64, receipt.gas_used) orelse return error.GasOverflow;
        cumulative_gas_used +%= gas_used_u64;
        receipt.cumulative_gas_used = @as(u256, cumulative_gas_used);
        receipt.transaction_hash = pooled_tx.hash;
        receipt.transaction_index = @intCast(mined_hashes.items.len);
        receipt.block_number = next_block_number;
        receipt.type = transactionTypeFromDecoded(decoded);
        receipt.effective_gas_price = effectiveGasPriceFromDecoded(decoded, next_base_fee);

        const receipt_logs = @constCast(receipt.logs);
        for (receipt_logs) |*log| {
            log.block_number = next_block_number;
            log.transaction_hash = pooled_tx.hash;
            log.transaction_index = receipt.transaction_index;
            log.log_index = global_log_index;
            global_log_index += 1;
        }

        const raw_for_block = try rt.retainBlockTransactionRaw(allocator, record.raw);
        try block_transactions.append(allocator, .{ .raw = raw_for_block });
        try mined_hashes.append(allocator, pooled_tx.hash);
        try mined_receipts.append(allocator, receipt);
    }

    if (mined_hashes.items.len == 0) return;

    const block = try sealCanonicalBlock(
        allocator,
        rt,
        parent_hash,
        next_block_number,
        next_timestamp,
        next_base_fee,
        block_transactions.items,
        mined_receipts.items,
        cumulative_gas_used,
    );

    for (mined_receipts.items, 0..) |*receipt, tx_index| {
        receipt.block_hash = block.hash;
        rt.markTransactionMined(
            mined_hashes.items[tx_index],
            block.hash,
            next_block_number,
            next_timestamp,
            @intCast(tx_index),
        );
    }

    if (indexes) |resolved_indexes| {
        try resolved_indexes.receipt_index.putBlockReceipts(allocator, block.hash, mined_receipts.items);
        try resolved_indexes.log_index.appendBlockLogs(
            allocator,
            next_block_number,
            block.hash,
            mined_receipts.items,
        );
    }

    rt.head_block_number = next_block_number;
    rt.current_timestamp = next_timestamp;
    rt.base_fee = next_base_fee;
    rt.next_block_timestamp_override = null;
    rt.next_block_base_fee_override = null;
    try rt.recordMinedBlock(
        allocator,
        next_block_number,
        block.hash,
        parent_hash,
        next_timestamp,
        next_base_fee,
    );

    // Remove mined txs from pool
    rt.pool.removeMined(mined_hashes.items);
}

pub fn mineEmptyBlock(allocator: std.mem.Allocator, rt: *runtime.NodeRuntime) ![32]u8 {
    return mineEmptyBlockWithIndexes(allocator, rt, null);
}

pub fn mineEmptyBlockWithIndexes(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    indexes: ?MiningIndexes,
) ![32]u8 {
    const parent_hash = rt.head_block_hash;
    const next_block_number = rt.head_block_number + 1;
    const next_timestamp: u64 = rt.next_block_timestamp_override orelse if (rt.mining_mode == .interval and rt.interval_seconds > 0)
        rt.current_timestamp + rt.interval_seconds
    else
        rt.current_timestamp + 1;
    const next_base_fee = rt.next_block_base_fee_override orelse rt.base_fee;

    const block = try sealCanonicalBlock(
        allocator,
        rt,
        parent_hash,
        next_block_number,
        next_timestamp,
        next_base_fee,
        &[_]primitives.BlockBody.TransactionData{},
        &[_]primitives.Receipt.Receipt{},
        0,
    );

    rt.head_block_number = next_block_number;
    rt.current_timestamp = next_timestamp;
    rt.base_fee = next_base_fee;
    rt.next_block_timestamp_override = null;
    rt.next_block_base_fee_override = null;
    try rt.recordMinedBlock(
        allocator,
        next_block_number,
        block.hash,
        parent_hash,
        next_timestamp,
        next_base_fee,
    );

    if (indexes) |resolved_indexes| {
        const empty_receipts: []const primitives.Receipt.Receipt = &.{};
        try resolved_indexes.receipt_index.putBlockReceipts(allocator, block.hash, empty_receipts);
        try resolved_indexes.log_index.appendBlockLogs(
            allocator,
            next_block_number,
            block.hash,
            empty_receipts,
        );
    }

    return block.hash;
}

fn sealCanonicalBlock(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    parent_hash: [32]u8,
    block_number: u64,
    block_timestamp: u64,
    base_fee: u256,
    transactions: []const primitives.BlockBody.TransactionData,
    receipts: []const primitives.Receipt.Receipt,
    gas_used: u64,
) !primitives.Block.Block {
    var header = primitives.BlockHeader.init();
    header.parent_hash = parent_hash;
    header.ommers_hash = primitives.BlockHeader.EMPTY_OMMERS_HASH;
    header.beneficiary = rt.coinbase;
    header.transactions_root = try computeTransactionsTrieRoot(allocator, transactions);
    header.receipts_root = try computeReceiptsTrieRoot(allocator, receipts);
    header.difficulty = 0;
    header.number = block_number;
    header.gas_limit = rt.block_gas_limit;
    header.gas_used = gas_used;
    header.timestamp = block_timestamp;
    header.base_fee_per_gas = base_fee;
    header.mix_hash = u256ToHash(rt.prev_randao);
    header.state_root = primitives.AccountState.EMPTY_TRIE_ROOT;
    if (rt.fork_url == null) {
        header.state_root = try computeRuntimeStateRoot(allocator, rt);
    } else if (try rt.getBlockByHashWithFork(allocator, parent_hash)) |parent_block| {
        // Fork mode has incomplete remote state visibility; preserve parent root.
        header.state_root = parent_block.header.state_root;
    }

    const body = primitives.BlockBody.BlockBody{
        .transactions = transactions,
        .ommers = &[_]primitives.BlockBody.UncleHeader{},
        .withdrawals = null,
    };
    const block = try primitives.Block.from(&header, &body, allocator);
    try rt.blockchain.putBlock(block);
    try rt.blockchain.setCanonicalHead(block.hash);
    return block;
}

fn computeTxHash(raw_bytes: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(raw_bytes, &out, .{});
    return out;
}

fn executionTxFromDecoded(
    sender: primitives.Address,
    decoded: primitives.Transaction.DecodedTransaction,
    base_fee: u256,
) tx_processor.ExecutionTx {
    return switch (decoded) {
        .legacy => |tx| .{
            .caller = sender,
            .tx = tx,
        },
        .eip2930 => |tx| .{
            .caller = sender,
            .tx = .{
                .nonce = tx.nonce,
                .gas_price = tx.gas_price,
                .gas_limit = tx.gas_limit,
                .to = tx.to,
                .value = tx.value,
                .data = tx.data,
                .v = tx.y_parity,
                .r = tx.r,
                .s = tx.s,
            },
        },
        .eip1559 => |tx| .{
            .caller = sender,
            .tx = .{
                .nonce = tx.nonce,
                .gas_price = eip1559EffectiveGasPrice(tx.max_fee_per_gas, tx.max_priority_fee_per_gas, base_fee),
                .gas_limit = tx.gas_limit,
                .to = tx.to,
                .value = tx.value,
                .data = tx.data,
                .v = tx.y_parity,
                .r = tx.r,
                .s = tx.s,
            },
        },
        .eip4844 => |tx| .{
            .caller = sender,
            .tx = .{
                .nonce = tx.nonce,
                .gas_price = eip1559EffectiveGasPrice(tx.max_fee_per_gas, tx.max_priority_fee_per_gas, base_fee),
                .gas_limit = tx.gas_limit,
                .to = tx.to,
                .value = tx.value,
                .data = tx.data,
                .v = tx.y_parity,
                .r = tx.r,
                .s = tx.s,
            },
        },
        .eip7702 => |tx| .{
            .caller = sender,
            .tx = .{
                .nonce = tx.nonce,
                .gas_price = eip1559EffectiveGasPrice(tx.max_fee_per_gas, tx.max_priority_fee_per_gas, base_fee),
                .gas_limit = tx.gas_limit,
                .to = tx.to,
                .value = tx.value,
                .data = tx.data,
                .v = tx.y_parity,
                .r = tx.r,
                .s = tx.s,
            },
        },
    };
}

fn transactionTypeFromDecoded(decoded: primitives.Transaction.DecodedTransaction) primitives.Receipt.TransactionType {
    return switch (decoded) {
        .legacy => .legacy,
        .eip2930 => .eip2930,
        .eip1559 => .eip1559,
        .eip4844 => .eip4844,
        .eip7702 => .eip7702,
    };
}

fn effectiveGasPriceFromDecoded(decoded: primitives.Transaction.DecodedTransaction, base_fee: u256) u256 {
    return switch (decoded) {
        .legacy => |tx| tx.gas_price,
        .eip2930 => |tx| tx.gas_price,
        .eip1559 => |tx| eip1559EffectiveGasPrice(tx.max_fee_per_gas, tx.max_priority_fee_per_gas, base_fee),
        .eip4844 => |tx| eip1559EffectiveGasPrice(tx.max_fee_per_gas, tx.max_priority_fee_per_gas, base_fee),
        .eip7702 => |tx| eip1559EffectiveGasPrice(tx.max_fee_per_gas, tx.max_priority_fee_per_gas, base_fee),
    };
}

fn eip1559EffectiveGasPrice(max_fee_per_gas: u256, max_priority_fee_per_gas: u256, base_fee: u256) u256 {
    const priority_sum, const overflow = @addWithOverflow(base_fee, max_priority_fee_per_gas);
    if (overflow != 0) return max_fee_per_gas;
    return @min(max_fee_per_gas, priority_sum);
}

fn u256ToHash(value: u256) [32]u8 {
    var out: [32]u8 = undefined;
    std.mem.writeInt(u256, &out, value, .big);
    return out;
}

fn computeTransactionsTrieRoot(
    allocator: std.mem.Allocator,
    transactions: []const primitives.BlockBody.TransactionData,
) ![32]u8 {
    if (transactions.len == 0) return primitives.BlockHeader.EMPTY_TRANSACTIONS_ROOT;

    var encoded_keys = std.ArrayList([]u8).empty;
    defer {
        for (encoded_keys.items) |key| {
            allocator.free(key);
        }
        encoded_keys.deinit(allocator);
    }

    const trie_keys = try allocator.alloc([]const u8, transactions.len);
    defer allocator.free(trie_keys);
    const trie_values = try allocator.alloc([]const u8, transactions.len);
    defer allocator.free(trie_values);

    for (transactions, 0..) |tx, tx_index| {
        const encoded_index = try primitives.Rlp.encode(allocator, @as(u64, @intCast(tx_index)));
        try encoded_keys.append(allocator, encoded_index);
        trie_keys[tx_index] = encoded_index;
        trie_values[tx_index] = tx.raw;
    }

    return try primitives.TrieHash.trie_root(allocator, trie_keys, trie_values);
}

fn computeReceiptsTrieRoot(
    allocator: std.mem.Allocator,
    receipts: []const primitives.Receipt.Receipt,
) ![32]u8 {
    if (receipts.len == 0) return primitives.BlockHeader.EMPTY_RECEIPTS_ROOT;

    var encoded_keys = std.ArrayList([]u8).empty;
    defer {
        for (encoded_keys.items) |key| {
            allocator.free(key);
        }
        encoded_keys.deinit(allocator);
    }

    var encoded_values = std.ArrayList([]u8).empty;
    defer {
        for (encoded_values.items) |value| {
            allocator.free(value);
        }
        encoded_values.deinit(allocator);
    }

    const trie_keys = try allocator.alloc([]const u8, receipts.len);
    defer allocator.free(trie_keys);
    const trie_values = try allocator.alloc([]const u8, receipts.len);
    defer allocator.free(trie_values);

    for (receipts, 0..) |receipt, tx_index| {
        const encoded_index = try primitives.Rlp.encode(allocator, @as(u64, @intCast(tx_index)));
        errdefer allocator.free(encoded_index);
        try encoded_keys.append(allocator, encoded_index);
        trie_keys[tx_index] = encoded_index;

        const encoded_receipt = try encodeReceiptForTrie(allocator, receipt);
        errdefer allocator.free(encoded_receipt);
        try encoded_values.append(allocator, encoded_receipt);
        trie_values[tx_index] = encoded_receipt;
    }

    return try primitives.TrieHash.trie_root(allocator, trie_keys, trie_values);
}

fn computeRuntimeStateRoot(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
) ![32]u8 {
    var addresses = std.AutoHashMap(primitives.Address, void).init(allocator);
    defer addresses.deinit();

    var account_it = rt.state.journaled_state.account_cache.cache.iterator();
    while (account_it.next()) |entry| {
        try addresses.put(entry.key_ptr.*, {});
    }

    var contract_it = rt.state.journaled_state.contract_cache.cache.iterator();
    while (contract_it.next()) |entry| {
        try addresses.put(entry.key_ptr.*, {});
    }

    var storage_it = rt.state.journaled_state.storage_cache.cache.iterator();
    while (storage_it.next()) |entry| {
        try addresses.put(entry.key_ptr.*, {});
    }

    var account_keys = std.ArrayList([20]u8).empty;
    defer account_keys.deinit(allocator);

    var account_values = std.ArrayList([]u8).empty;
    defer {
        for (account_values.items) |value| {
            allocator.free(value);
        }
        account_values.deinit(allocator);
    }

    var address_it = addresses.iterator();
    while (address_it.next()) |entry| {
        const address = entry.key_ptr.*;
        const account_opt = rt.state.journaled_state.account_cache.get(address);

        const nonce: u64 = if (account_opt) |account| account.nonce else 0;
        const balance: u256 = if (account_opt) |account| account.balance else 0;

        var code_hash = primitives.AccountState.EMPTY_CODE_HASH;
        if (rt.state.journaled_state.contract_cache.cache.get(address)) |code| {
            if (code.len > 0) {
                std.crypto.hash.sha3.Keccak256.hash(code, &code_hash, .{});
            }
        } else if (account_opt) |account| {
            code_hash = account.code_hash;
        }

        var storage_root = primitives.AccountState.EMPTY_TRIE_ROOT;
        if (rt.state.journaled_state.storage_cache.cache.getPtr(address)) |slots| {
            storage_root = try computeStorageTrieRoot(allocator, slots);
        } else if (account_opt) |account| {
            storage_root = account.storage_root;
        }

        const is_empty_account = nonce == 0 and
            balance == 0 and
            std.mem.eql(u8, &code_hash, &primitives.AccountState.EMPTY_CODE_HASH) and
            std.mem.eql(u8, &storage_root, &primitives.AccountState.EMPTY_TRIE_ROOT);
        if (is_empty_account) continue;

        const account_state = primitives.AccountState.AccountState.from(.{
            .nonce = nonce,
            .balance = balance,
            .storage_root = storage_root,
            .code_hash = code_hash,
        });

        const encoded_account = try account_state.rlpEncode(allocator);
        errdefer allocator.free(encoded_account);

        try account_keys.append(allocator, address.bytes);
        try account_values.append(allocator, encoded_account);
    }

    if (account_keys.items.len == 0) return primitives.AccountState.EMPTY_TRIE_ROOT;

    const trie_keys = try allocator.alloc([]const u8, account_keys.items.len);
    defer allocator.free(trie_keys);
    for (account_keys.items, 0..) |key, index| {
        trie_keys[index] = key[0..];
    }

    return try primitives.TrieHash.secure_trie_root(allocator, trie_keys, account_values.items);
}

fn computeStorageTrieRoot(
    allocator: std.mem.Allocator,
    slots: *const std.AutoHashMap(u256, u256),
) ![32]u8 {
    var slot_keys = std.ArrayList([32]u8).empty;
    defer slot_keys.deinit(allocator);

    var slot_values = std.ArrayList([]u8).empty;
    defer {
        for (slot_values.items) |value| {
            allocator.free(value);
        }
        slot_values.deinit(allocator);
    }

    var slot_it = slots.iterator();
    while (slot_it.next()) |entry| {
        const slot_value = entry.value_ptr.*;
        if (slot_value == 0) continue;

        var slot_key: [32]u8 = undefined;
        std.mem.writeInt(u256, &slot_key, entry.key_ptr.*, .big);
        try slot_keys.append(allocator, slot_key);

        const encoded_value = try primitives.Rlp.encode(allocator, slot_value);
        errdefer allocator.free(encoded_value);
        try slot_values.append(allocator, encoded_value);
    }

    if (slot_keys.items.len == 0) return primitives.AccountState.EMPTY_TRIE_ROOT;

    const trie_keys = try allocator.alloc([]const u8, slot_keys.items.len);
    defer allocator.free(trie_keys);
    for (slot_keys.items, 0..) |key, index| {
        trie_keys[index] = key[0..];
    }

    return try primitives.TrieHash.secure_trie_root(allocator, trie_keys, slot_values.items);
}

fn encodeReceiptForTrie(
    allocator: std.mem.Allocator,
    receipt: primitives.Receipt.Receipt,
) ![]u8 {
    var encoded_logs = std.ArrayList([]u8).empty;
    defer {
        for (encoded_logs.items) |encoded_log| {
            allocator.free(encoded_log);
        }
        encoded_logs.deinit(allocator);
    }

    for (receipt.logs) |log| {
        const encoded_log = try encodeLogForReceiptTrie(allocator, log);
        errdefer allocator.free(encoded_log);
        try encoded_logs.append(allocator, encoded_log);
    }

    const logs_payload = try encodeRlpListFromEncodedItems(allocator, encoded_logs.items);
    errdefer allocator.free(logs_payload);

    var encoded_fields = std.ArrayList([]u8).empty;
    defer {
        for (encoded_fields.items) |field| {
            allocator.free(field);
        }
        encoded_fields.deinit(allocator);
    }

    const status_or_root = blk: {
        if (receipt.root) |root| break :blk try primitives.Rlp.encodeBytes(allocator, &root);
        const status = receipt.status orelse return error.InvalidReceiptEncoding;
        break :blk try primitives.Rlp.encode(allocator, @as(u8, if (status.success) 1 else 0));
    };
    errdefer allocator.free(status_or_root);
    try encoded_fields.append(allocator, status_or_root);

    const cumulative_gas_used = try primitives.Rlp.encode(allocator, receipt.cumulative_gas_used);
    errdefer allocator.free(cumulative_gas_used);
    try encoded_fields.append(allocator, cumulative_gas_used);

    const logs_bloom = try primitives.Rlp.encodeBytes(allocator, &receipt.logs_bloom);
    errdefer allocator.free(logs_bloom);
    try encoded_fields.append(allocator, logs_bloom);

    try encoded_fields.append(allocator, logs_payload);

    const receipt_payload = try encodeRlpListFromEncodedItems(allocator, encoded_fields.items);

    const type_byte = switch (receipt.type) {
        .legacy => return receipt_payload,
        .eip2930 => @as(u8, 0x01),
        .eip1559 => @as(u8, 0x02),
        .eip4844 => @as(u8, 0x03),
        .eip7702 => @as(u8, 0x04),
    };

    const typed = try allocator.alloc(u8, receipt_payload.len + 1);
    typed[0] = type_byte;
    @memcpy(typed[1..], receipt_payload);
    allocator.free(receipt_payload);
    return typed;
}

fn encodeLogForReceiptTrie(
    allocator: std.mem.Allocator,
    log: primitives.EventLog.EventLog,
) ![]u8 {
    var encoded_topics = std.ArrayList([]u8).empty;
    defer {
        for (encoded_topics.items) |topic| {
            allocator.free(topic);
        }
        encoded_topics.deinit(allocator);
    }

    for (log.topics) |topic| {
        const encoded_topic = try primitives.Rlp.encodeBytes(allocator, &topic);
        errdefer allocator.free(encoded_topic);
        try encoded_topics.append(allocator, encoded_topic);
    }

    const topics_payload = try encodeRlpListFromEncodedItems(allocator, encoded_topics.items);
    errdefer allocator.free(topics_payload);

    var encoded_fields = std.ArrayList([]u8).empty;
    defer {
        for (encoded_fields.items) |field| {
            allocator.free(field);
        }
        encoded_fields.deinit(allocator);
    }

    const address = try primitives.Rlp.encodeBytes(allocator, &log.address.bytes);
    errdefer allocator.free(address);
    try encoded_fields.append(allocator, address);

    try encoded_fields.append(allocator, topics_payload);

    const data = try primitives.Rlp.encodeBytes(allocator, log.data);
    errdefer allocator.free(data);
    try encoded_fields.append(allocator, data);

    return try encodeRlpListFromEncodedItems(allocator, encoded_fields.items);
}

fn encodeRlpListFromEncodedItems(
    allocator: std.mem.Allocator,
    encoded_items: []const []const u8,
) ![]u8 {
    var payload_len: usize = 0;
    for (encoded_items) |item| {
        payload_len += item.len;
    }

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    if (payload_len < 56) {
        try out.append(allocator, 0xc0 + @as(u8, @intCast(payload_len)));
    } else {
        const len_bytes = try primitives.Rlp.encodeLength(allocator, payload_len);
        defer allocator.free(len_bytes);
        try out.append(allocator, 0xf7 + @as(u8, @intCast(len_bytes.len)));
        try out.appendSlice(allocator, len_bytes);
    }

    for (encoded_items) |item| {
        try out.appendSlice(allocator, item);
    }

    return try out.toOwnedSlice(allocator);
}

fn extractNonce(decoded: primitives.Transaction.DecodedTransaction) u64 {
    return switch (decoded) {
        .legacy => |t| t.nonce,
        .eip2930 => |t| t.nonce,
        .eip1559 => |t| t.nonce,
        .eip4844 => |t| t.nonce,
        .eip7702 => |t| t.nonce,
    };
}

fn extractGasLimit(decoded: primitives.Transaction.DecodedTransaction) u64 {
    return switch (decoded) {
        .legacy => |t| t.gas_limit,
        .eip2930 => |t| t.gas_limit,
        .eip1559 => |t| t.gas_limit,
        .eip4844 => |t| t.gas_limit,
        .eip7702 => |t| t.gas_limit,
    };
}

fn extractGasPrice(decoded: primitives.Transaction.DecodedTransaction) u256 {
    return switch (decoded) {
        .legacy => |t| t.gas_price,
        .eip2930 => |t| t.gas_price,
        .eip1559 => |t| t.max_fee_per_gas,
        .eip4844 => |t| t.max_fee_per_gas,
        .eip7702 => |t| t.max_fee_per_gas,
    };
}

fn extractPriorityFee(decoded: primitives.Transaction.DecodedTransaction) u256 {
    return switch (decoded) {
        .legacy => |t| t.gas_price,
        .eip2930 => |t| t.gas_price,
        .eip1559 => |t| t.max_priority_fee_per_gas,
        .eip4844 => |t| t.max_priority_fee_per_gas,
        .eip7702 => |t| t.max_priority_fee_per_gas,
    };
}

fn extractValue(decoded: primitives.Transaction.DecodedTransaction) u256 {
    return switch (decoded) {
        .legacy => |t| t.value,
        .eip2930 => |t| t.value,
        .eip1559 => |t| t.value,
        .eip4844 => |t| t.value,
        .eip7702 => |t| t.value,
    };
}

fn extractTo(decoded: primitives.Transaction.DecodedTransaction) ?primitives.Address {
    return switch (decoded) {
        .legacy => |t| t.to,
        .eip2930 => |t| t.to,
        .eip1559 => |t| t.to,
        .eip4844 => |t| .{ .bytes = t.to.bytes },
        .eip7702 => |t| t.to,
    };
}

fn extractData(decoded: primitives.Transaction.DecodedTransaction) []const u8 {
    return switch (decoded) {
        .legacy => |t| t.data,
        .eip2930 => |t| t.data,
        .eip1559 => |t| t.data,
        .eip4844 => |t| t.data,
        .eip7702 => |t| t.data,
    };
}

fn parseJsonQuantityToU64(val: std.json.Value) !u64 {
    switch (val) {
        .string => |s| {
            if (s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
                return std.fmt.parseInt(u64, s[2..], 16) catch return error.InvalidQuantity;
            }
            return std.fmt.parseInt(u64, s, 10) catch return error.InvalidQuantity;
        },
        .integer => |n| {
            if (n < 0) return error.InvalidQuantity;
            return @intCast(n);
        },
        else => return error.InvalidQuantity,
    }
}

fn parseJsonQuantityToU256(val: std.json.Value) !u256 {
    switch (val) {
        .string => |s| {
            if (s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
                return std.fmt.parseInt(u256, s[2..], 16) catch return error.InvalidQuantity;
            }
            return std.fmt.parseInt(u256, s, 10) catch return error.InvalidQuantity;
        },
        .integer => |n| {
            if (n < 0) return error.InvalidQuantity;
            return @intCast(n);
        },
        else => return error.InvalidQuantity,
    }
}

const SendTransactionType = enum {
    legacy,
    eip2930,
    eip1559,
    eip4844,
    eip7702,
};

fn parseSendTransactionType(tx_obj: std.json.ObjectMap) !SendTransactionType {
    if (tx_obj.get("type")) |type_value| {
        const type_id = parseJsonQuantityToU64(type_value) catch return error.InvalidType;
        return switch (type_id) {
            0 => .legacy,
            1 => .eip2930,
            2 => .eip1559,
            3 => .eip4844,
            4 => .eip7702,
            else => error.InvalidType,
        };
    }

    if (tx_obj.get("authorizationList") != null) {
        return .eip7702;
    }
    if (tx_obj.get("maxFeePerBlobGas") != null or tx_obj.get("blobVersionedHashes") != null) {
        return .eip4844;
    }
    if (tx_obj.get("maxFeePerGas") != null or tx_obj.get("maxPriorityFeePerGas") != null) {
        return .eip1559;
    }
    if (tx_obj.get("accessList") != null) {
        return .eip2930;
    }
    return .legacy;
}

fn parseBlobVersionedHashes(
    allocator: std.mem.Allocator,
    tx_obj: std.json.ObjectMap,
    required: bool,
) ![]const primitives.Blob.VersionedHash {
    const hashes_value = tx_obj.get("blobVersionedHashes") orelse {
        if (required) return error.InvalidBlobVersionedHashes;
        return allocator.alloc(primitives.Blob.VersionedHash, 0);
    };
    const hash_items = switch (hashes_value) {
        .array => |array| array.items,
        else => return error.InvalidBlobVersionedHashes,
    };
    if (required and hash_items.len == 0) return error.InvalidBlobVersionedHashes;

    const hashes = try allocator.alloc(primitives.Blob.VersionedHash, hash_items.len);
    errdefer allocator.free(hashes);

    for (hash_items, 0..) |item, i| {
        const hash_string = switch (item) {
            .string => |value| value,
            else => return error.InvalidBlobVersionedHashes,
        };
        hashes[i] = .{
            .bytes = primitives.Hex.hexToBytesFixed(32, hash_string) catch return error.InvalidBlobVersionedHashes,
        };
    }

    return hashes;
}

fn parseAuthorizationList(
    allocator: std.mem.Allocator,
    tx_obj: std.json.ObjectMap,
) ![]const primitives.Authorization.Authorization {
    const auth_value = tx_obj.get("authorizationList") orelse return allocator.alloc(primitives.Authorization.Authorization, 0);
    const auth_items = switch (auth_value) {
        .array => |array| array.items,
        else => return error.InvalidAuthorizationList,
    };

    const authorizations = try allocator.alloc(primitives.Authorization.Authorization, auth_items.len);
    errdefer allocator.free(authorizations);

    for (auth_items, 0..) |entry, i| {
        const auth_obj = switch (entry) {
            .object => |obj| obj,
            else => return error.InvalidAuthorizationList,
        };

        const chain_id = parseJsonQuantityToU64(auth_obj.get("chainId") orelse return error.InvalidAuthorizationList) catch
            return error.InvalidAuthorizationList;
        const address_string = switch (auth_obj.get("address") orelse return error.InvalidAuthorizationList) {
            .string => |value| value,
            else => return error.InvalidAuthorizationList,
        };
        const address = primitives.Address.fromHex(address_string) catch return error.InvalidAuthorizationList;
        const auth_nonce = parseJsonQuantityToU64(auth_obj.get("nonce") orelse return error.InvalidAuthorizationList) catch
            return error.InvalidAuthorizationList;

        const y_parity = blk: {
            if (auth_obj.get("yParity")) |y_parity_value| {
                break :blk parseJsonQuantityToU64(y_parity_value) catch return error.InvalidAuthorizationList;
            }
            if (auth_obj.get("v")) |v_value| {
                break :blk parseJsonQuantityToU64(v_value) catch return error.InvalidAuthorizationList;
            }
            return error.InvalidAuthorizationList;
        };
        if (y_parity > 1) return error.InvalidAuthorizationList;

        const r_hex = switch (auth_obj.get("r") orelse return error.InvalidAuthorizationList) {
            .string => |value| value,
            else => return error.InvalidAuthorizationList,
        };
        const s_hex = switch (auth_obj.get("s") orelse return error.InvalidAuthorizationList) {
            .string => |value| value,
            else => return error.InvalidAuthorizationList,
        };

        authorizations[i] = .{
            .chain_id = chain_id,
            .address = address,
            .nonce = auth_nonce,
            .v = y_parity,
            .r = primitives.Hex.hexToBytesFixed(32, r_hex) catch return error.InvalidAuthorizationList,
            .s = primitives.Hex.hexToBytesFixed(32, s_hex) catch return error.InvalidAuthorizationList,
        };
    }

    return authorizations;
}

fn parseAccessList(
    allocator: std.mem.Allocator,
    tx_obj: std.json.ObjectMap,
) ![]const primitives.Transaction.AccessListItem {
    const access_list_value = tx_obj.get("accessList") orelse return allocator.alloc(primitives.Transaction.AccessListItem, 0);
    const access_items = switch (access_list_value) {
        .array => |array| array.items,
        else => return error.InvalidAccessList,
    };

    const access_list = try allocator.alloc(primitives.Transaction.AccessListItem, access_items.len);
    var initialized: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < initialized) : (i += 1) {
            allocator.free(access_list[i].storage_keys);
        }
        allocator.free(access_list);
    }

    for (access_items, 0..) |entry, i| {
        const entry_obj = switch (entry) {
            .object => |obj| obj,
            else => return error.InvalidAccessList,
        };

        const address_value = entry_obj.get("address") orelse return error.InvalidAccessList;
        const address_string = switch (address_value) {
            .string => |s| s,
            else => return error.InvalidAccessList,
        };
        const address = primitives.Address.fromHex(address_string) catch return error.InvalidAccessList;

        const storage_keys_value = entry_obj.get("storageKeys") orelse return error.InvalidAccessList;
        const storage_keys_items = switch (storage_keys_value) {
            .array => |array| array.items,
            else => return error.InvalidAccessList,
        };

        const storage_keys = try allocator.alloc([32]u8, storage_keys_items.len);
        errdefer allocator.free(storage_keys);
        for (storage_keys_items, 0..) |key, j| {
            const key_string = switch (key) {
                .string => |s| s,
                else => return error.InvalidAccessList,
            };
            storage_keys[j] = primitives.Hex.hexToBytesFixed(32, key_string) catch return error.InvalidAccessList;
        }

        access_list[i] = .{
            .address = address,
            .storage_keys = storage_keys,
        };
        initialized += 1;
    }

    return access_list;
}

fn deinitAccessList(allocator: std.mem.Allocator, access_list: []const primitives.Transaction.AccessListItem) void {
    for (access_list) |entry| {
        allocator.free(entry.storage_keys);
    }
    allocator.free(access_list);
}
