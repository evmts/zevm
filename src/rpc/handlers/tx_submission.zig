const std = @import("std");
const primitives = @import("primitives");
const crypto = @import("crypto");
const jsonrpc = @import("jsonrpc");
const guillotine_mini = @import("guillotine_mini");
const runtime = @import("../../node/runtime.zig");
const host_adapter = @import("../../host_adapter.zig");
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

const HostForkResolverContext = struct {
    allocator: std.mem.Allocator,
    node_runtime: *runtime.NodeRuntime,
};

fn resolveHostForkPending(context: *anyopaque) bool {
    const typed_context: *HostForkResolverContext = @ptrCast(@alignCast(context));
    return typed_context.node_runtime.processForkRequests(typed_context.allocator) catch false;
}

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

    const tx_type = parseSendTransactionType(tx_obj) catch return TxSubmissionError.InvalidHexData;
    const access_list = parseAccessList(allocator, tx_obj) catch return TxSubmissionError.InvalidHexData;
    defer deinitAccessList(allocator, access_list);

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
        },
        .max_priority_fee_per_gas = switch (tx_type) {
            .legacy => gas_price,
            .eip2930 => gas_price,
            .eip1559 => max_priority_fee_per_gas,
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
        automine(allocator, rt) catch {};
    }

    return .{ .value = .{ .bytes = tx_hash } };
}

pub fn minePendingTransactions(allocator: std.mem.Allocator, rt: *runtime.NodeRuntime) !void {
    try automine(allocator, rt);
}

fn automine(allocator: std.mem.Allocator, rt: *runtime.NodeRuntime) !void {
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
    const block_hash = syntheticBlockHash(next_block_number, next_timestamp);
    const block_ctx = guillotine_mini.BlockContext{
        .chain_id = rt.chain_id,
        .block_number = next_block_number,
        .block_timestamp = next_timestamp,
        .block_difficulty = 0,
        .block_prevrandao = 0,
        .block_coinbase = rt.coinbase,
        .block_gas_limit = 30_000_000,
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
    var tx_index: u64 = 0;
    for (ready) |pooled_tx| {
        const record = rt.getTransactionRecord(pooled_tx.hash) orelse continue;
        const decoded = primitives.Transaction.decodeRawTransaction(allocator, record.raw) catch continue;
        defer primitives.Transaction.deinitDecodedTransaction(allocator, decoded);

        const exec_tx = executionTxFromDecoded(record.sender, decoded);
        _ = tx_processor.processTransaction(
            allocator,
            &rt.state,
            host_iface,
            exec_tx.caller,
            exec_tx.tx,
            block_ctx,
        ) catch continue;

        rt.markTransactionMined(
            pooled_tx.hash,
            block_hash,
            next_block_number,
            next_timestamp,
            tx_index,
        );
        try mined_hashes.append(allocator, pooled_tx.hash);
        tx_index += 1;
    }

    if (mined_hashes.items.len == 0) return;

    rt.head_block_number = next_block_number;
    rt.current_timestamp = next_timestamp;
    rt.base_fee = next_base_fee;
    rt.next_block_timestamp_override = null;
    rt.next_block_base_fee_override = null;
    try rt.recordMinedBlock(
        allocator,
        next_block_number,
        block_hash,
        parent_hash,
        next_timestamp,
        next_base_fee,
    );

    // Remove mined txs from pool
    rt.pool.removeMined(mined_hashes.items);
}

fn computeTxHash(raw_bytes: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(raw_bytes, &out, .{});
    return out;
}

fn syntheticBlockHash(block_number: u64, timestamp: u64) [32]u8 {
    var bytes: [16]u8 = undefined;
    std.mem.writeInt(u64, bytes[0..8], block_number, .big);
    std.mem.writeInt(u64, bytes[8..16], timestamp, .big);
    var out: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(&bytes, &out, .{});
    return out;
}

fn executionTxFromDecoded(
    sender: primitives.Address,
    decoded: primitives.Transaction.DecodedTransaction,
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
                .gas_price = tx.max_fee_per_gas,
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
                .gas_price = tx.max_fee_per_gas,
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
                .gas_price = tx.max_fee_per_gas,
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
};

fn parseSendTransactionType(tx_obj: std.json.ObjectMap) !SendTransactionType {
    if (tx_obj.get("type")) |type_value| {
        const type_id = parseJsonQuantityToU64(type_value) catch return error.InvalidType;
        return switch (type_id) {
            0 => .legacy,
            1 => .eip2930,
            2 => .eip1559,
            else => error.InvalidType,
        };
    }

    if (tx_obj.get("maxFeePerGas") != null or tx_obj.get("maxPriorityFeePerGas") != null) {
        return .eip1559;
    }
    if (tx_obj.get("accessList") != null) {
        return .eip2930;
    }
    return .legacy;
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
    errdefer allocator.free(access_list);

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
    }

    return access_list;
}

fn deinitAccessList(allocator: std.mem.Allocator, access_list: []const primitives.Transaction.AccessListItem) void {
    for (access_list) |entry| {
        allocator.free(entry.storage_keys);
    }
    allocator.free(access_list);
}
