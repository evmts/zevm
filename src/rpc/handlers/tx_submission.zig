const std = @import("std");
const primitives = @import("primitives");
const jsonrpc = @import("jsonrpc");
const guillotine_mini = @import("guillotine_mini");
const runtime = @import("../../node/runtime.zig");
const tx_encoding = @import("../../transaction_encoding.zig");
const tx_processor = @import("../../tx_processor.zig");
const mining = @import("../../mining.zig");
const log = @import("../../log.zig");
const rpc_parse = @import("../parse.zig");

pub const TxSubmissionError = error{
    InvalidHexData,
    DecodeFailed,
    UnsupportedTxType,
    SenderRecoveryFailed,
    ChainIdMismatch,
    NonceMismatch,
    InsufficientBalance,
    IntrinsicGasExceedsLimit,
    GasPriceBelowMinimum,
    InitcodeTooLarge,
    PoolInsertFailed,
    UnmanagedAccount,
    SigningFailed,
    MiningFailed,
    OutOfMemory,
    StateError,
};

// EIP-3860: 49152 = 2 * MAX_CODE_SIZE
const MAX_INITCODE_SIZE: usize = 49152;

pub fn handleSendRawTransaction(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: jsonrpc.eth.SendRawTransaction.Params,
) TxSubmissionError!jsonrpc.eth.SendRawTransaction.Result {
    const hex_str = switch (params.transaction.value) {
        .string => |s| s,
        else => return TxSubmissionError.InvalidHexData,
    };

    const raw_bytes = primitives.Hex.hexToBytes(allocator, hex_str) catch return TxSubmissionError.InvalidHexData;
    defer allocator.free(raw_bytes);

    if (raw_bytes.len == 0) return TxSubmissionError.InvalidHexData;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const decoded = tx_encoding.decodeEnvelope(arena_alloc, raw_bytes) catch |err| switch (err) {
        error.InvalidTransactionType => return if (raw_bytes[0] <= 0x7f)
            TxSubmissionError.UnsupportedTxType
        else
            TxSubmissionError.DecodeFailed,
        else => return TxSubmissionError.DecodeFailed,
    };
    const tx = tx_encoding.envelopeToLegacyLikeTx(decoded);

    if (tx_encoding.envelopeChainId(decoded)) |cid| {
        if (cid != rt.chain_id) return TxSubmissionError.ChainIdMismatch;
    }

    const sender = tx_encoding.recoverEnvelopeSender(arena_alloc, decoded) catch return TxSubmissionError.SenderRecoveryFailed;

    const is_create = tx.to == null;
    const hardfork = rt.pendingHardfork();
    if (!rawTransactionTypeSupported(tx_encoding.envelopeReceiptType(decoded), hardfork)) {
        return TxSubmissionError.UnsupportedTxType;
    }

    // EIP-3860: cap initcode size for create transactions.
    if (hardfork.isAtLeast(.SHANGHAI) and is_create and tx.data.len > MAX_INITCODE_SIZE) {
        return TxSubmissionError.InitcodeTooLarge;
    }

    const current_nonce = rt.state.getNonce(sender) catch return TxSubmissionError.StateError;
    if (tx.nonce < current_nonce) return TxSubmissionError.NonceMismatch;

    const intrinsic = computeEnvelopeIntrinsicGas(decoded, is_create, hardfork) catch return TxSubmissionError.IntrinsicGasExceedsLimit;
    if (intrinsic > tx.gas_limit) return TxSubmissionError.IntrinsicGasExceedsLimit;
    if (tx.gas_limit > rt.dev_runtime.config.block_gas_limit) return TxSubmissionError.IntrinsicGasExceedsLimit;

    // Balance covers value + max gas cost.
    const max_fee_per_gas = tx_encoding.envelopeMaxFeePerGas(decoded) orelse tx.gas_price;
    const max_priority_fee_per_gas = tx_encoding.envelopeMaxPriorityFeePerGas(decoded) orelse tx.gas_price;
    const max_gas_cost = max_fee_per_gas * @as(u256, tx.gas_limit);
    const total_cost = tx.value +| max_gas_cost;
    const balance = rt.state.getBalance(sender) catch return TxSubmissionError.StateError;
    if (balance < total_cost) return TxSubmissionError.InsufficientBalance;

    const canonical = tx_encoding.canonicalTransactionEnvelope(allocator, raw_bytes) catch |err| switch (err) {
        error.OutOfMemory => return TxSubmissionError.OutOfMemory,
        else => return TxSubmissionError.DecodeFailed,
    };
    defer canonical.deinit(allocator);

    const tx_hash = computeTxHash(canonical.bytes);

    rt.pool.setNonce(sender, current_nonce) catch return TxSubmissionError.PoolInsertFailed;
    rt.pool.add(allocator, .{
        .sender = sender,
        .nonce = tx.nonce,
        .gas_limit = tx.gas_limit,
        .max_fee_per_gas = max_fee_per_gas,
        .max_priority_fee_per_gas = max_priority_fee_per_gas,
        .hash = tx_hash,
        .to = tx.to,
        .value = tx.value,
        .input = tx.data,
        .raw = canonical.bytes,
        .v = tx.v,
        .r = tx.r,
        .s = tx.s,
    }) catch |err| switch (err) {
        error.ReplacementUnderpriced => return TxSubmissionError.PoolInsertFailed,
        error.OutOfMemory => return TxSubmissionError.OutOfMemory,
    };

    logTxAccepted(rt, "sendRawTransaction", sender, tx.nonce, tx.gas_limit, tx_hash);

    switch (rt.mining_config) {
        .auto => if (tx.nonce == current_nonce) automine(rt) catch return TxSubmissionError.MiningFailed,
        .manual, .interval => {},
    }

    return .{ .value = .{ .bytes = tx_hash } };
}

const SendTransactionRequest = struct {
    from: primitives.Address,
    to: ?primitives.Address = null,
    gas: ?u64 = null,
    gas_price: ?u256 = null,
    value: u256 = 0,
    nonce: ?u64 = null,
    data: []const u8 = &.{},
    owns_data: bool = false,

    fn deinit(self: SendTransactionRequest, allocator: std.mem.Allocator) void {
        if (self.owns_data) allocator.free(self.data);
    }
};

const SendTransactionParseError = error{
    InvalidTransactionRequest,
    InvalidAddress,
    UnsupportedTxType,
    OutOfMemory,
};

fn parseQuantityU64Value(value: std.json.Value) SendTransactionParseError!u64 {
    return rpc_parse.parseQuantityValue(u64, value) catch error.InvalidTransactionRequest;
}

pub fn handleSendTransaction(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: jsonrpc.eth.SendTransaction.Params,
) TxSubmissionError!jsonrpc.eth.SendTransaction.Result {
    const request = parseSendTransactionRequest(allocator, params) catch |err| switch (err) {
        error.UnsupportedTxType => return TxSubmissionError.UnsupportedTxType,
        error.OutOfMemory => return TxSubmissionError.OutOfMemory,
        error.InvalidAddress, error.InvalidTransactionRequest => return TxSubmissionError.InvalidHexData,
    };
    defer request.deinit(allocator);
    if (!rt.canSignForAccount(request.from)) return TxSubmissionError.UnmanagedAccount;

    const current_nonce = rt.state.getNonce(request.from) catch return TxSubmissionError.StateError;
    const nonce = request.nonce orelse current_nonce;
    if (nonce < current_nonce) return TxSubmissionError.NonceMismatch;

    const gas_price = request.gas_price orelse rt.gas_price;
    if (gas_price < rt.gas_price) return TxSubmissionError.GasPriceBelowMinimum;
    var tx = primitives.Transaction.LegacyTransaction{
        .nonce = nonce,
        .gas_price = gas_price,
        .gas_limit = request.gas orelse 0,
        .to = request.to,
        .value = request.value,
        .data = request.data,
        .v = 0,
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
    };

    const hardfork = rt.pendingHardfork();
    if (hardfork.isAtLeast(.SHANGHAI) and tx.to == null and tx.data.len > MAX_INITCODE_SIZE) {
        return TxSubmissionError.InitcodeTooLarge;
    }
    const intrinsic = computeLegacyIntrinsicGas(tx.to == null, tx.data, hardfork);
    tx.gas_limit = request.gas orelse intrinsic;
    if (intrinsic > tx.gas_limit) return TxSubmissionError.IntrinsicGasExceedsLimit;
    if (tx.gas_limit > rt.dev_runtime.config.block_gas_limit) return TxSubmissionError.IntrinsicGasExceedsLimit;

    const max_gas_cost = gas_price * @as(u256, tx.gas_limit);
    const total_cost = tx.value +| max_gas_cost;
    const balance = rt.state.getBalance(request.from) catch return TxSubmissionError.StateError;
    if (balance < total_cost) return TxSubmissionError.InsufficientBalance;

    if (rt.managedPrivateKey(request.from)) |private_key| {
        tx = tx_encoding.signLegacyTransaction(allocator, tx, private_key, rt.chain_id) catch return TxSubmissionError.SigningFailed;
    }

    const raw = tx_encoding.encodeLegacyTransactionEnvelope(allocator, tx) catch return TxSubmissionError.SigningFailed;
    defer allocator.free(raw);
    const tx_hash = computeTxHash(raw);

    rt.pool.setNonce(request.from, current_nonce) catch return TxSubmissionError.PoolInsertFailed;
    rt.pool.add(allocator, .{
        .sender = request.from,
        .nonce = tx.nonce,
        .gas_limit = tx.gas_limit,
        .max_fee_per_gas = tx.gas_price,
        .max_priority_fee_per_gas = 0,
        .hash = tx_hash,
        .to = tx.to,
        .value = tx.value,
        .input = tx.data,
        .raw = raw,
        .v = tx.v,
        .r = tx.r,
        .s = tx.s,
    }) catch |err| switch (err) {
        error.ReplacementUnderpriced => return TxSubmissionError.PoolInsertFailed,
        error.OutOfMemory => return TxSubmissionError.OutOfMemory,
    };

    logTxAccepted(rt, "sendTransaction", request.from, tx.nonce, tx.gas_limit, tx_hash);

    switch (rt.mining_config) {
        .auto => if (tx.nonce == current_nonce) automine(rt) catch return TxSubmissionError.MiningFailed,
        .manual, .interval => {},
    }

    return .{ .value = .{ .bytes = tx_hash } };
}

pub fn handleSignTransaction(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: jsonrpc.eth.SendTransaction.Params,
) TxSubmissionError!jsonrpc.eth.SignTransaction.Result {
    const request = parseSendTransactionRequest(allocator, params) catch |err| switch (err) {
        error.UnsupportedTxType => return TxSubmissionError.UnsupportedTxType,
        error.OutOfMemory => return TxSubmissionError.OutOfMemory,
        error.InvalidAddress, error.InvalidTransactionRequest => return TxSubmissionError.InvalidHexData,
    };
    defer request.deinit(allocator);

    const private_key = rt.managedPrivateKey(request.from) orelse return TxSubmissionError.UnmanagedAccount;
    const nonce = request.nonce orelse (rt.state.getNonce(request.from) catch return TxSubmissionError.StateError);
    const gas_price = request.gas_price orelse rt.gas_price;
    var tx = primitives.Transaction.LegacyTransaction{
        .nonce = nonce,
        .gas_price = gas_price,
        .gas_limit = request.gas orelse 0,
        .to = request.to,
        .value = request.value,
        .data = request.data,
        .v = 0,
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
    };

    const hardfork = rt.pendingHardfork();
    if (hardfork.isAtLeast(.SHANGHAI) and tx.to == null and tx.data.len > MAX_INITCODE_SIZE) {
        return TxSubmissionError.InitcodeTooLarge;
    }
    const intrinsic = computeLegacyIntrinsicGas(tx.to == null, tx.data, hardfork);
    tx.gas_limit = request.gas orelse intrinsic;
    if (intrinsic > tx.gas_limit) return TxSubmissionError.IntrinsicGasExceedsLimit;

    const signed = tx_encoding.signLegacyTransaction(allocator, tx, private_key, rt.chain_id) catch return TxSubmissionError.SigningFailed;
    const raw = tx_encoding.encodeLegacyTransactionEnvelope(allocator, signed) catch return TxSubmissionError.SigningFailed;
    defer allocator.free(raw);

    return .{ .value = .{ .value = .{ .string = try hexBytesString(allocator, raw) } } };
}

// Phase-1-only: keys that imply a typed/dynamic-fee/blob/auth submission. Listed
// explicitly so the rejection is visible to reviewers and stays aligned with
// the documented contract.
fn isTypedSubmissionKey(key: []const u8) bool {
    const typed_keys = [_][]const u8{
        "type",
        "accessList",
        "maxFeePerGas",
        "maxPriorityFeePerGas",
        "maxFeePerBlobGas",
        "blobVersionedHashes",
        "blobs",
        "commitments",
        "proofs",
        "authorizationList",
        "chainId",
    };
    inline for (typed_keys) |typed_key| {
        if (std.mem.eql(u8, key, typed_key)) return true;
    }
    return false;
}

fn parseSendTransactionRequest(
    allocator: std.mem.Allocator,
    params: jsonrpc.eth.SendTransaction.Params,
) SendTransactionParseError!SendTransactionRequest {
    const tx_object = switch (params.transaction.value) {
        .object => |object| object,
        else => return error.InvalidTransactionRequest,
    };

    var request = SendTransactionRequest{ .from = undefined };
    var saw_from = false;
    var data_value: ?[]const u8 = null;
    var input_value: ?[]const u8 = null;
    errdefer {
        if (data_value) |data| allocator.free(data);
        if (input_value) |input| allocator.free(input);
    }

    var it = tx_object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "from")) {
            request.from = try parseAddressValue(value);
            saw_from = true;
        } else if (std.mem.eql(u8, key, "to")) {
            request.to = if (value == .null) null else try parseAddressValue(value);
        } else if (std.mem.eql(u8, key, "gas")) {
            request.gas = try parseQuantityU64Value(value);
        } else if (std.mem.eql(u8, key, "gasPrice")) {
            request.gas_price = try parseQuantityU256Value(value);
        } else if (std.mem.eql(u8, key, "value")) {
            request.value = try parseQuantityU256Value(value);
        } else if (std.mem.eql(u8, key, "nonce")) {
            request.nonce = try parseQuantityU64Value(value);
        } else if (std.mem.eql(u8, key, "data")) {
            data_value = try parseHexDataValue(allocator, value);
        } else if (std.mem.eql(u8, key, "input")) {
            input_value = try parseHexDataValue(allocator, value);
        } else if (isTypedSubmissionKey(key)) {
            return error.UnsupportedTxType;
        } else {
            return error.InvalidTransactionRequest;
        }
    }

    if (!saw_from) return error.InvalidTransactionRequest;
    if (data_value != null and input_value != null and !std.mem.eql(u8, data_value.?, input_value.?)) {
        return error.InvalidTransactionRequest;
    }

    if (data_value) |data| {
        request.data = data;
        request.owns_data = true;
        if (input_value) |input| {
            allocator.free(input);
            input_value = null;
        }
        data_value = null;
    } else if (input_value) |input| {
        request.data = input;
        request.owns_data = true;
        input_value = null;
    }

    return request;
}

fn parseAddressValue(value: std.json.Value) SendTransactionParseError!primitives.Address {
    return rpc_parse.parseAddressValue(value) catch error.InvalidAddress;
}

fn parseAddressString(text: []const u8) SendTransactionParseError!primitives.Address {
    return rpc_parse.parseAddressString(text) catch error.InvalidAddress;
}

fn parseQuantityU256Value(value: std.json.Value) SendTransactionParseError!u256 {
    return rpc_parse.parseQuantityValue(u256, value) catch error.InvalidTransactionRequest;
}

fn parseQuantityString(comptime T: type, text: []const u8) SendTransactionParseError!T {
    return rpc_parse.parseQuantityString(T, text) catch error.InvalidTransactionRequest;
}

fn isQuantityHex(text: []const u8) bool {
    return rpc_parse.isQuantityHex(text);
}

fn parseHexDataValue(allocator: std.mem.Allocator, value: std.json.Value) SendTransactionParseError![]const u8 {
    return rpc_parse.parseHexDataBytes(allocator, value) catch error.InvalidTransactionRequest;
}

// --- Intrinsic gas (legacy only) ----------------------------------------

fn computeLegacyIntrinsicGas(is_create: bool, data: []const u8, hardfork: guillotine_mini.Hardfork) u64 {
    return tx_processor.intrinsicGasForFork(data, is_create, hardfork);
}

fn computeEnvelopeIntrinsicGas(
    decoded: tx_encoding.DecodedEnvelope,
    is_create: bool,
    hardfork: guillotine_mini.Hardfork,
) error{Overflow}!u64 {
    const tx = tx_encoding.envelopeToLegacyLikeTx(decoded);
    var gas = tx_processor.intrinsicGasForFork(tx.data, is_create, hardfork);
    const access_list_gas = try transactionAccessListGasCost(tx_encoding.envelopeAccessList(decoded));
    gas = try std.math.add(u64, gas, access_list_gas);
    if (tx_encoding.envelopeReceiptType(decoded) == .eip7702) {
        const auth_cost = try std.math.mul(u64, 25_000, tx_encoding.envelopeAuthorizationList(decoded).len);
        gas = try std.math.add(u64, gas, auth_cost);
    }
    return gas;
}

fn transactionAccessListGasCost(access_list: []const primitives.Transaction.AccessListItem) error{Overflow}!u64 {
    var gas: u64 = 0;
    for (access_list) |entry| {
        gas = try std.math.add(u64, gas, primitives.AccessList.ACCESS_LIST_ADDRESS_COST);
        const storage_cost = try std.math.mul(
            u64,
            primitives.AccessList.ACCESS_LIST_STORAGE_KEY_COST,
            @as(u64, @intCast(entry.storage_keys.len)),
        );
        gas = try std.math.add(u64, gas, storage_cost);
    }
    return gas;
}

fn rawTransactionTypeSupported(receipt_type: primitives.Receipt.TransactionType, hardfork: guillotine_mini.Hardfork) bool {
    return switch (receipt_type) {
        .legacy => true,
        .eip2930 => hardfork.isAtLeast(.BERLIN),
        .eip1559 => hardfork.isAtLeast(.LONDON),
        .eip4844 => hardfork.isAtLeast(.CANCUN),
        .eip7702 => hardfork.isAtLeast(.PRAGUE),
    };
}

fn keccak(input: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(input, &out, .{});
    return out;
}

// --- Hash + automine -----------------------------------------------------

fn computeTxHash(raw_bytes: []const u8) [32]u8 {
    return keccak(raw_bytes);
}

fn hexBytesString(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, 2 + bytes.len * 2);
    out[0] = '0';
    out[1] = 'x';
    const charset = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        out[2 + i * 2] = charset[(byte >> 4) & 0x0f];
        out[2 + i * 2 + 1] = charset[byte & 0x0f];
    }
    return out;
}

fn logTxAccepted(
    rt: *runtime.NodeRuntime,
    source: []const u8,
    sender: primitives.Address,
    nonce: u64,
    gas_limit: u64,
    tx_hash: [32]u8,
) void {
    const hash_hex = std.fmt.bytesToHex(tx_hash, .lower);
    const sender_hex = std.fmt.bytesToHex(sender.bytes, .lower);
    log.info(.txpool, "tx_accepted source={s} hash=0x{s} sender=0x{s} nonce={} gas_limit={} pool_pending={} pool_queued={} mining_mode={s}", .{
        source,
        hash_hex[0..],
        sender_hex[0..],
        nonce,
        gas_limit,
        rt.pool.pendingCount(),
        rt.pool.queuedCount(),
        miningConfigName(rt.mining_config),
    });
}

fn miningConfigName(config: mining.MiningConfig) []const u8 {
    return switch (config) {
        .auto => "auto",
        .manual => "manual",
        .interval => "interval",
    };
}

fn automine(rt: *runtime.NodeRuntime) !void {
    try rt.mineBlocks(1, 0);
}
