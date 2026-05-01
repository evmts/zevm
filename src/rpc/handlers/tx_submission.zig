const std = @import("std");
const primitives = @import("primitives");
const crypto = @import("crypto");
const jsonrpc = @import("jsonrpc");
const runtime = @import("../../node/runtime.zig");
const genesis = @import("../../genesis.zig");

pub const TxSubmissionError = error{
    InvalidHexData,
    DecodeFailed,
    UnsupportedTxType,
    SenderRecoveryFailed,
    ChainIdMismatch,
    NonceMismatch,
    InsufficientBalance,
    IntrinsicGasExceedsLimit,
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

const INTRINSIC_TX: u64 = 21_000;
const INTRINSIC_CREATE: u64 = 32_000;
const CALLDATA_ZERO_GAS: u64 = 4;
const CALLDATA_NONZERO_GAS: u64 = 16;
const INITCODE_WORD_GAS: u64 = 2;

// Phase 1 transaction boundary: only legacy RLP envelopes are accepted on the
// public RPC surface. EIP-2718 typed envelopes (type bytes 0x01..=0x7f, including
// 0x01 EIP-2930, 0x02 EIP-1559, 0x03 EIP-4844, 0x04 EIP-7702) are rejected with
// `UnsupportedTxType`. The dispatcher maps `UnsupportedTxType` to JSON-RPC -32602.
//
// `eth_sendTransaction` similarly rejects request fields that imply typed
// submission (`type`, `accessList`, `maxFeePerGas`, `maxPriorityFeePerGas`,
// `maxFeePerBlobGas`, `blobVersionedHashes`, `blobs`, `commitments`, `proofs`,
// `authorizationList`, `chainId`).
//
// When phase-1 scope changes to admit typed submission, both rejection paths
// must be revisited together with the pool, mining, and signing surfaces.

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

    // EIP-2718 type byte range is 0x00..=0x7f; 0xc0..=0xff is RLP list (legacy).
    // Anything in 0x80..=0xbf is RLP string and not a valid top-level tx encoding.
    if (raw_bytes[0] <= 0x7f) return TxSubmissionError.UnsupportedTxType;
    if (raw_bytes[0] < 0xc0) return TxSubmissionError.DecodeFailed;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const decoded = decodeLegacy(arena_alloc, raw_bytes) catch return TxSubmissionError.DecodeFailed;

    // Chain id check (legacy may be pre-EIP-155 so chain_id is null).
    if (primitives.Transaction.getLegacyTransactionChainId(decoded)) |cid| {
        if (cid != rt.chain_id) return TxSubmissionError.ChainIdMismatch;
    }

    const sig_hash = computeLegacySigningHash(arena_alloc, decoded, rt.chain_id) catch return TxSubmissionError.DecodeFailed;
    const sender = recoverLegacySender(decoded, sig_hash) catch return TxSubmissionError.SenderRecoveryFailed;

    const is_create = decoded.to == null;

    // EIP-3860: cap initcode size for create transactions.
    if (is_create and decoded.data.len > MAX_INITCODE_SIZE) {
        return TxSubmissionError.InitcodeTooLarge;
    }

    // Nonce vs state.
    const current_nonce = rt.state.getNonce(sender) catch return TxSubmissionError.StateError;
    if (current_nonce != decoded.nonce) return TxSubmissionError.NonceMismatch;

    // Intrinsic gas.
    const intrinsic = computeLegacyIntrinsicGas(is_create, decoded.data);
    if (intrinsic > decoded.gas_limit) return TxSubmissionError.IntrinsicGasExceedsLimit;
    if (decoded.gas_limit > rt.dev_runtime.config.block_gas_limit) return TxSubmissionError.IntrinsicGasExceedsLimit;

    // Balance covers value + max gas cost.
    const max_gas_cost = decoded.gas_price * @as(u256, decoded.gas_limit);
    const total_cost = decoded.value +| max_gas_cost;
    const balance = rt.state.getBalance(sender) catch return TxSubmissionError.StateError;
    if (balance < total_cost) return TxSubmissionError.InsufficientBalance;

    const tx_hash = computeTxHash(raw_bytes);

    rt.pool.setNonce(sender, current_nonce) catch return TxSubmissionError.PoolInsertFailed;
    rt.pool.add(allocator, .{
        .sender = sender,
        .nonce = decoded.nonce,
        .gas_limit = decoded.gas_limit,
        .max_fee_per_gas = decoded.gas_price,
        .max_priority_fee_per_gas = decoded.gas_price,
        .hash = tx_hash,
        .to = decoded.to,
        .value = decoded.value,
        .input = decoded.data,
        .raw = raw_bytes,
        .v = decoded.v,
        .r = decoded.r,
        .s = decoded.s,
    }) catch |err| switch (err) {
        error.ReplacementUnderpriced => return TxSubmissionError.PoolInsertFailed,
        error.OutOfMemory => return TxSubmissionError.OutOfMemory,
    };

    switch (rt.mining_config) {
        .auto => automine(rt) catch return TxSubmissionError.MiningFailed,
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
};

const SendTransactionParseError = error{
    InvalidTransactionRequest,
    InvalidAddress,
    UnsupportedTxType,
    OutOfMemory,
};

fn parseQuantityU64Value(value: std.json.Value) SendTransactionParseError!u64 {
    return switch (value) {
        .integer => |n| if (n < 0) error.InvalidTransactionRequest else @intCast(n),
        .string => |text| parseQuantityString(u64, text),
        else => error.InvalidTransactionRequest,
    };
}

fn managedDevPrivateKey(address: primitives.Address) ?[32]u8 {
    for (genesis.DEV_ACCOUNTS) |account| {
        if (std.mem.eql(u8, &account.address.bytes, &address.bytes)) return account.private_key;
    }
    return null;
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
    if (!rt.canSignForAccount(request.from)) return TxSubmissionError.UnmanagedAccount;

    const current_nonce = rt.state.getNonce(request.from) catch return TxSubmissionError.StateError;
    const nonce = request.nonce orelse current_nonce;
    if (current_nonce != nonce) return TxSubmissionError.NonceMismatch;

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

    const intrinsic = computeLegacyIntrinsicGas(tx.to == null, tx.data);
    tx.gas_limit = request.gas orelse intrinsic;
    if (intrinsic > tx.gas_limit) return TxSubmissionError.IntrinsicGasExceedsLimit;
    if (tx.gas_limit > rt.dev_runtime.config.block_gas_limit) return TxSubmissionError.IntrinsicGasExceedsLimit;

    const max_gas_cost = gas_price * @as(u256, tx.gas_limit);
    const total_cost = tx.value +| max_gas_cost;
    const balance = rt.state.getBalance(request.from) catch return TxSubmissionError.StateError;
    if (balance < total_cost) return TxSubmissionError.InsufficientBalance;

    if (managedDevPrivateKey(request.from)) |private_key| {
        tx = primitives.Transaction.signLegacyTransaction(allocator, tx, private_key, rt.chain_id) catch return TxSubmissionError.SigningFailed;
    }

    const raw = primitives.Transaction.encodeLegacyForSigning(allocator, tx, rt.chain_id) catch return TxSubmissionError.SigningFailed;
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

    switch (rt.mining_config) {
        .auto => automine(rt) catch return TxSubmissionError.MiningFailed,
        .manual, .interval => {},
    }

    return .{ .value = .{ .bytes = tx_hash } };
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
    request.data = data_value orelse input_value orelse &.{};
    return request;
}

fn parseAddressValue(value: std.json.Value) SendTransactionParseError!primitives.Address {
    return switch (value) {
        .string => |text| parseAddressString(text),
        else => error.InvalidTransactionRequest,
    };
}

fn parseAddressString(text: []const u8) SendTransactionParseError!primitives.Address {
    if (text.len != 42) return error.InvalidAddress;
    if (text[0] != '0' or (text[1] != 'x' and text[1] != 'X')) return error.InvalidAddress;

    var bytes: [20]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, text[2..]) catch return error.InvalidAddress;
    return .{ .bytes = bytes };
}

fn parseQuantityU256Value(value: std.json.Value) SendTransactionParseError!u256 {
    return switch (value) {
        .integer => |n| if (n < 0) error.InvalidTransactionRequest else @intCast(n),
        .string => |text| parseQuantityString(u256, text),
        else => error.InvalidTransactionRequest,
    };
}

fn parseQuantityString(comptime T: type, text: []const u8) SendTransactionParseError!T {
    if (text.len <= 2 or text[0] != '0' or (text[1] != 'x' and text[1] != 'X')) return error.InvalidTransactionRequest;
    return std.fmt.parseInt(T, text[2..], 16) catch error.InvalidTransactionRequest;
}

fn parseHexDataValue(allocator: std.mem.Allocator, value: std.json.Value) SendTransactionParseError![]const u8 {
    const text = switch (value) {
        .string => |s| s,
        else => return error.InvalidTransactionRequest,
    };
    if (text.len < 2 or text[0] != '0' or (text[1] != 'x' and text[1] != 'X')) return error.InvalidTransactionRequest;
    if ((text.len - 2) % 2 != 0) return error.InvalidTransactionRequest;
    return primitives.Hex.hexToBytes(allocator, text) catch error.InvalidTransactionRequest;
}

// --- Legacy envelope decoding -------------------------------------------

fn rlpAsList(d: primitives.Rlp.Data) ![]primitives.Rlp.Data {
    return switch (d) {
        .List => |items| items,
        .String => error.UnexpectedInput,
    };
}

fn rlpAsString(d: primitives.Rlp.Data) ![]const u8 {
    return switch (d) {
        .String => |b| b,
        .List => error.UnexpectedInput,
    };
}

fn rlpToU64(d: primitives.Rlp.Data) !u64 {
    const bytes = try rlpAsString(d);
    if (bytes.len > 8) return error.InvalidLength;
    var out: u64 = 0;
    for (bytes) |b| {
        out = (out << 8) | b;
    }
    return out;
}

fn rlpToU256(d: primitives.Rlp.Data) !u256 {
    const bytes = try rlpAsString(d);
    if (bytes.len > 32) return error.InvalidLength;
    var out: u256 = 0;
    for (bytes) |b| {
        out = (out << 8) | b;
    }
    return out;
}

fn rlpToFixed32(d: primitives.Rlp.Data) ![32]u8 {
    const bytes = try rlpAsString(d);
    if (bytes.len > 32) return error.InvalidLength;
    var out: [32]u8 = [_]u8{0} ** 32;
    @memcpy(out[32 - bytes.len ..], bytes);
    return out;
}

fn rlpToOptionalAddress(d: primitives.Rlp.Data) !?primitives.Address {
    const bytes = try rlpAsString(d);
    if (bytes.len == 0) return null;
    if (bytes.len != 20) return error.InvalidLength;
    var addr: primitives.Address = undefined;
    @memcpy(&addr.bytes, bytes);
    return addr;
}

fn decodeLegacy(
    allocator: std.mem.Allocator,
    raw: []const u8,
) !primitives.Transaction.LegacyTransaction {
    const decoded = try primitives.Rlp.decode(allocator, raw, false);
    const fields = try rlpAsList(decoded.data);
    if (fields.len != 9) return error.InvalidLength;
    const data_bytes = try rlpAsString(fields[5]);
    return .{
        .nonce = try rlpToU64(fields[0]),
        .gas_price = try rlpToU256(fields[1]),
        .gas_limit = try rlpToU64(fields[2]),
        .to = try rlpToOptionalAddress(fields[3]),
        .value = try rlpToU256(fields[4]),
        .data = try allocator.dupe(u8, data_bytes),
        .v = try rlpToU64(fields[6]),
        .r = try rlpToFixed32(fields[7]),
        .s = try rlpToFixed32(fields[8]),
    };
}

// --- Intrinsic gas (legacy only; EIP-2028 calldata) ---------------------

fn computeLegacyIntrinsicGas(is_create: bool, data: []const u8) u64 {
    var gas: u64 = INTRINSIC_TX;
    if (is_create) gas += INTRINSIC_CREATE;

    for (data) |b| {
        gas += if (b == 0) CALLDATA_ZERO_GAS else CALLDATA_NONZERO_GAS;
    }

    if (is_create) {
        const word_count = (data.len + 31) / 32;
        gas += INITCODE_WORD_GAS * @as(u64, @intCast(word_count));
    }

    return gas;
}

// --- Signing hash + ecrecover (legacy only) -----------------------------

fn computeLegacySigningHash(
    allocator: std.mem.Allocator,
    tx: primitives.Transaction.LegacyTransaction,
    chain_id: u64,
) ![32]u8 {
    var unsigned = tx;
    unsigned.v = 0;
    unsigned.r = [_]u8{0} ** 32;
    unsigned.s = [_]u8{0} ** 32;
    const enc = try primitives.Transaction.encodeLegacyForSigning(allocator, unsigned, chain_id);
    defer allocator.free(enc);
    return keccak(enc);
}

fn keccak(input: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(input, &out, .{});
    return out;
}

fn recoverLegacySender(tx: primitives.Transaction.LegacyTransaction, sig_hash: [32]u8) !primitives.Address {
    const r_u256 = std.mem.readInt(u256, &tx.r, .big);
    const s_u256 = std.mem.readInt(u256, &tx.s, .big);

    const sig = crypto.Crypto.Signature{
        .r = r_u256,
        .s = s_u256,
        .v = legacyRecoveryId(tx.v) + 27,
    };

    return crypto.Crypto.unaudited_recoverAddress(sig_hash, sig);
}

fn legacyRecoveryId(v: u64) u8 {
    if (v >= 35) return @intCast((v - 35) % 2);
    if (v == 27 or v == 28) return @intCast(v - 27);
    return @intCast(v % 2);
}

// --- Hash + automine -----------------------------------------------------

fn computeTxHash(raw_bytes: []const u8) [32]u8 {
    return keccak(raw_bytes);
}

fn automine(rt: *runtime.NodeRuntime) !void {
    try rt.mineBlocks(1, 0);
}
