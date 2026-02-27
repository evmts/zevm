const std = @import("std");
const primitives = @import("primitives");
const jsonrpc = @import("jsonrpc");
const runtime = @import("../../node/runtime.zig");
const tx_processor = @import("../../tx_processor.zig");

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

pub fn handleSendRawTransaction(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: jsonrpc.eth.SendRawTransaction.Params,
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
    const current_nonce = rt.state.getNonce(sender) catch return TxSubmissionError.StateError;
    if (current_nonce != nonce) return TxSubmissionError.NonceMismatch;

    // Validate intrinsic gas
    const is_create = extractTo(decoded) == null;
    const intrinsic = tx_processor.intrinsicGas(data, is_create);
    if (intrinsic > gas_limit) return TxSubmissionError.IntrinsicGasExceedsLimit;

    // Validate balance covers value + gas cost
    const max_gas_cost = gas_price * @as(u256, gas_limit);
    const total_cost = value + max_gas_cost;
    const balance = rt.state.getBalance(sender) catch return TxSubmissionError.StateError;
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

    // Automine if in auto mode
    if (rt.mining_mode == .auto) {
        automine(allocator, rt) catch {};
    }

    return .{ .value = .{ .bytes = tx_hash } };
}

pub fn handleSendTransaction(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: jsonrpc.eth.SendTransaction.Params,
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

    // Look up private key for the managed account
    const private_key = runtime.NodeRuntime.lookupManagedAccount(from_addr) orelse
        return TxSubmissionError.UnmanagedAccount;

    // Extract fields
    const nonce = blk: {
        if (tx_obj.get("nonce")) |nonce_val| {
            break :blk parseJsonQuantityToU64(nonce_val) catch return TxSubmissionError.InvalidHexData;
        }
        break :blk rt.state.getNonce(from_addr) catch return TxSubmissionError.StateError;
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

    const value: u256 = blk: {
        if (tx_obj.get("value")) |v_val| {
            break :blk parseJsonQuantityToU256(v_val) catch return TxSubmissionError.InvalidHexData;
        }
        break :blk 0;
    };

    const to: ?primitives.Address = blk: {
        if (tx_obj.get("to")) |to_val| {
            const to_str = switch (to_val) {
                .string => |s| s,
                else => break :blk null,
            };
            break :blk primitives.Address.fromHex(to_str) catch break :blk null;
        }
        break :blk null;
    };

    const data_bytes: []const u8 = blk: {
        if (tx_obj.get("data") orelse tx_obj.get("input")) |data_val| {
            const data_str = switch (data_val) {
                .string => |s| s,
                else => break :blk &[_]u8{},
            };
            break :blk primitives.Hex.hexToBytes(allocator, data_str) catch break :blk &[_]u8{};
        }
        break :blk &[_]u8{};
    };
    defer if (data_bytes.len > 0) allocator.free(data_bytes);

    // Build unsigned legacy transaction
    const unsigned_tx = primitives.Transaction.LegacyTransaction{
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

    // Sign the transaction
    const signed_tx = primitives.Transaction.signLegacyTransaction(allocator, unsigned_tx, private_key, rt.chain_id) catch
        return TxSubmissionError.SigningFailed;

    // Encode the signed transaction to RLP
    const encoded = primitives.Transaction.encodeLegacyForSigning(allocator, signed_tx, rt.chain_id) catch
        return TxSubmissionError.OutOfMemory;
    defer allocator.free(encoded);

    // Compute tx hash
    const tx_hash = computeTxHash(encoded);

    // Validate nonce
    const current_nonce = rt.state.getNonce(from_addr) catch return TxSubmissionError.StateError;
    if (current_nonce != nonce) return TxSubmissionError.NonceMismatch;

    // Validate intrinsic gas
    const intrinsic = tx_processor.intrinsicGas(data_bytes, to == null);
    if (intrinsic > gas_limit) return TxSubmissionError.IntrinsicGasExceedsLimit;

    // Validate balance
    const max_gas_cost = gas_price * @as(u256, gas_limit);
    const total_cost = value + max_gas_cost;
    const balance = rt.state.getBalance(from_addr) catch return TxSubmissionError.StateError;
    if (balance < total_cost) return TxSubmissionError.InsufficientBalance;

    // Insert into txpool
    rt.pool.setNonce(from_addr, current_nonce) catch return TxSubmissionError.PoolInsertFailed;
    rt.pool.add(allocator, .{
        .sender = from_addr,
        .nonce = nonce,
        .gas_limit = gas_limit,
        .max_fee_per_gas = gas_price,
        .max_priority_fee_per_gas = gas_price,
        .hash = tx_hash,
    }) catch |err| switch (err) {
        error.ReplacementUnderpriced => return TxSubmissionError.PoolInsertFailed,
        error.OutOfMemory => return TxSubmissionError.OutOfMemory,
    };

    // Automine if in auto mode
    if (rt.mining_mode == .auto) {
        automine(allocator, rt) catch {};
    }

    return .{ .value = .{ .bytes = tx_hash } };
}

fn automine(allocator: std.mem.Allocator, rt: *runtime.NodeRuntime) !void {
    const ready = try rt.pool.getReady(allocator);
    defer allocator.free(ready);

    if (ready.len == 0) return;

    // Convert ready pooled transactions to ExecutionTx for block building
    // For now, we create simple legacy transactions from pool entries
    var exec_txs = try allocator.alloc(tx_processor.ExecutionTx, ready.len);
    defer allocator.free(exec_txs);

    for (ready, 0..) |pooled_tx, i| {
        // Create a minimal legacy tx from pool data
        exec_txs[i] = .{
            .caller = pooled_tx.sender,
            .tx = .{
                .nonce = pooled_tx.nonce,
                .gas_price = pooled_tx.max_fee_per_gas,
                .gas_limit = pooled_tx.gas_limit,
                .to = null,
                .value = 0,
                .data = &[_]u8{},
                .v = 0,
                .r = [_]u8{0} ** 32,
                .s = [_]u8{0} ** 32,
            },
        };
    }

    rt.head_block_number += 1;

    // Remove mined txs from pool
    var mined_hashes = try allocator.alloc([32]u8, ready.len);
    defer allocator.free(mined_hashes);
    for (ready, 0..) |pooled_tx, i| {
        mined_hashes[i] = pooled_tx.hash;
    }
    rt.pool.removeMined(mined_hashes);
}

fn computeTxHash(raw_bytes: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(raw_bytes, &out, .{});
    return out;
}

fn extractNonce(decoded: primitives.Transaction.DecodedTransaction) u64 {
    return switch (decoded) {
        .legacy => |t| t.nonce,
        .eip1559 => |t| t.nonce,
        .eip4844 => |t| t.nonce,
        .eip7702 => |t| t.nonce,
    };
}

fn extractGasLimit(decoded: primitives.Transaction.DecodedTransaction) u64 {
    return switch (decoded) {
        .legacy => |t| t.gas_limit,
        .eip1559 => |t| t.gas_limit,
        .eip4844 => |t| t.gas_limit,
        .eip7702 => |t| t.gas_limit,
    };
}

fn extractGasPrice(decoded: primitives.Transaction.DecodedTransaction) u256 {
    return switch (decoded) {
        .legacy => |t| t.gas_price,
        .eip1559 => |t| t.max_fee_per_gas,
        .eip4844 => |t| t.max_fee_per_gas,
        .eip7702 => |t| t.max_fee_per_gas,
    };
}

fn extractPriorityFee(decoded: primitives.Transaction.DecodedTransaction) u256 {
    return switch (decoded) {
        .legacy => |t| t.gas_price,
        .eip1559 => |t| t.max_priority_fee_per_gas,
        .eip4844 => |t| t.max_priority_fee_per_gas,
        .eip7702 => |t| t.max_priority_fee_per_gas,
    };
}

fn extractValue(decoded: primitives.Transaction.DecodedTransaction) u256 {
    return switch (decoded) {
        .legacy => |t| t.value,
        .eip1559 => |t| t.value,
        .eip4844 => |t| t.value,
        .eip7702 => |t| t.value,
    };
}

fn extractTo(decoded: primitives.Transaction.DecodedTransaction) ?primitives.Address {
    return switch (decoded) {
        .legacy => |t| t.to,
        .eip1559 => |t| t.to,
        .eip4844 => |t| .{ .bytes = t.to.bytes },
        .eip7702 => |t| t.to,
    };
}

fn extractData(decoded: primitives.Transaction.DecodedTransaction) []const u8 {
    return switch (decoded) {
        .legacy => |t| t.data,
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
