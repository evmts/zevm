const std = @import("std");
const primitives = @import("primitives");
const crypto = @import("crypto");
const jsonrpc = @import("jsonrpc");
const runtime = @import("../../node/runtime.zig");
const tx_processor = @import("../../tx_processor.zig");

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
const ACCESS_LIST_ADDR_GAS: u64 = 2400;
const ACCESS_LIST_KEY_GAS: u64 = 1900;
const PER_AUTH_GAS: u64 = 25_000;

pub const DecodedEnvelope = union(enum) {
    legacy: primitives.Transaction.LegacyTransaction,
    eip2930: primitives.Transaction.Eip2930Transaction,
    eip1559: primitives.Transaction.Eip1559Transaction,
    eip4844: primitives.Transaction.Eip4844Transaction,
    eip7702: primitives.Transaction.Eip7702Transaction,
};

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

    const decoded = decodeEnvelope(arena_alloc, raw_bytes) catch return TxSubmissionError.DecodeFailed;

    // Chain id check (legacy may be pre-EIP-155 so chain_id is null).
    if (envelopeChainId(decoded)) |cid| {
        if (cid != rt.chain_id) return TxSubmissionError.ChainIdMismatch;
    }

    const sig_hash = computeSigningHash(arena_alloc, decoded, rt.chain_id) catch return TxSubmissionError.DecodeFailed;
    const sender = recoverSender(decoded, sig_hash) catch return TxSubmissionError.SenderRecoveryFailed;

    const nonce = envelopeNonce(decoded);
    const gas_limit = envelopeGasLimit(decoded);
    const max_fee = envelopeMaxFeePerGas(decoded);
    const priority_fee = envelopePriorityFee(decoded);
    const value = envelopeValue(decoded);
    const data = envelopeData(decoded);
    const is_create = envelopeTo(decoded) == null;

    // EIP-3860: cap initcode size for create transactions.
    if (is_create and data.len > MAX_INITCODE_SIZE) {
        return TxSubmissionError.InitcodeTooLarge;
    }

    // Nonce vs state.
    const current_nonce = rt.state.getNonce(sender) catch return TxSubmissionError.StateError;
    if (current_nonce != nonce) return TxSubmissionError.NonceMismatch;

    // Intrinsic gas.
    const intrinsic = computeIntrinsicGas(decoded, is_create, data);
    if (intrinsic > gas_limit) return TxSubmissionError.IntrinsicGasExceedsLimit;

    // Balance covers value + max gas cost. For 4844 we additionally require blob gas budget.
    const max_gas_cost = max_fee * @as(u256, gas_limit);
    var total_cost = value +| max_gas_cost;
    switch (decoded) {
        .eip4844 => |t| {
            const blob_gas: u256 = @as(u256, t.blob_versioned_hashes.len) * 131072;
            total_cost = total_cost +| (t.max_fee_per_blob_gas *| blob_gas);
        },
        else => {},
    }
    const balance = rt.state.getBalance(sender) catch return TxSubmissionError.StateError;
    if (balance < total_cost) return TxSubmissionError.InsufficientBalance;

    const tx_hash = computeTxHash(raw_bytes);

    _ = priority_fee;

    switch (rt.mining_config) {
        .auto => automine(allocator, rt, decoded, sender) catch {},
        .manual, .interval => {},
    }

    return .{ .value = .{ .bytes = tx_hash } };
}

pub fn handleSendTransaction(
    _: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: jsonrpc.eth.SendTransaction.Params,
) TxSubmissionError!jsonrpc.eth.SendTransaction.Result {
    const from = parseSendTransactionFrom(params) catch return TxSubmissionError.InvalidHexData;
    if (!rt.canSignForAccount(from)) return TxSubmissionError.UnmanagedAccount;

    // The current NodeRuntime-backed RPC path does not yet expose the pending
    // pool used by raw transaction submission in this dormant handler. Keep the
    // signer-scope gate accurate so managed and impersonated accounts follow
    // the same authorization semantics when transaction construction is wired.
    return TxSubmissionError.SigningFailed;
}

fn parseSendTransactionFrom(params: jsonrpc.eth.SendTransaction.Params) !primitives.Address {
    const tx_object = switch (params.transaction.value) {
        .object => |object| object,
        else => return error.InvalidTransactionRequest,
    };
    const from_value = tx_object.get("from") orelse return error.InvalidTransactionRequest;
    return switch (from_value) {
        .string => |text| parseAddressString(text),
        else => error.InvalidTransactionRequest,
    };
}

fn parseAddressString(text: []const u8) !primitives.Address {
    if (text.len != 42) return error.InvalidAddress;
    if (text[0] != '0' or (text[1] != 'x' and text[1] != 'X')) return error.InvalidAddress;

    var bytes: [20]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, text[2..]) catch return error.InvalidAddress;
    return .{ .bytes = bytes };
}

// --- Envelope decoding ---------------------------------------------------

fn decodeEnvelope(allocator: std.mem.Allocator, raw: []const u8) !DecodedEnvelope {
    const first = raw[0];
    if (first >= 0xc0) {
        return .{ .legacy = try decodeLegacy(allocator, raw) };
    }
    if (raw.len < 2) return error.InputTooShort;
    const body = raw[1..];
    return switch (first) {
        0x01 => DecodedEnvelope{ .eip2930 = try decodeEip2930(allocator, body) },
        0x02 => DecodedEnvelope{ .eip1559 = try decodeEip1559(allocator, body) },
        0x03 => DecodedEnvelope{ .eip4844 = try decodeEip4844Canonical(allocator, body) },
        0x04 => DecodedEnvelope{ .eip7702 = try decodeEip7702(allocator, body) },
        else => error.UnsupportedTxType,
    };
}

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

fn rlpToAddress(d: primitives.Rlp.Data) !primitives.Address {
    const bytes = try rlpAsString(d);
    if (bytes.len != 20) return error.InvalidLength;
    var addr: primitives.Address = undefined;
    @memcpy(&addr.bytes, bytes);
    return addr;
}

fn rlpToHash32(d: primitives.Rlp.Data) ![32]u8 {
    const bytes = try rlpAsString(d);
    if (bytes.len != 32) return error.InvalidLength;
    var h: [32]u8 = undefined;
    @memcpy(&h, bytes);
    return h;
}

fn decodeAccessList(
    allocator: std.mem.Allocator,
    items: []primitives.Rlp.Data,
) ![]const primitives.Transaction.AccessListItem {
    if (items.len == 0) return &[_]primitives.Transaction.AccessListItem{};
    const out = try allocator.alloc(primitives.Transaction.AccessListItem, items.len);
    for (items, 0..) |item, i| {
        const fields = try rlpAsList(item);
        if (fields.len != 2) return error.InvalidLength;
        const addr = try rlpToAddress(fields[0]);
        const key_items = try rlpAsList(fields[1]);
        const keys = try allocator.alloc([32]u8, key_items.len);
        for (key_items, 0..) |k, j| {
            keys[j] = try rlpToHash32(k);
        }
        out[i] = .{ .address = addr, .storage_keys = keys };
    }
    return out;
}

fn decodeAuthorizationList(
    allocator: std.mem.Allocator,
    items: []primitives.Rlp.Data,
) ![]const primitives.Authorization.Authorization {
    if (items.len == 0) return &[_]primitives.Authorization.Authorization{};
    const out = try allocator.alloc(primitives.Authorization.Authorization, items.len);
    for (items, 0..) |item, i| {
        const fields = try rlpAsList(item);
        if (fields.len != 6) return error.InvalidLength;
        out[i] = .{
            .chain_id = try rlpToU64(fields[0]),
            .address = try rlpToAddress(fields[1]),
            .nonce = try rlpToU64(fields[2]),
            .v = try rlpToU64(fields[3]),
            .r = try rlpToFixed32(fields[4]),
            .s = try rlpToFixed32(fields[5]),
        };
    }
    return out;
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

fn decodeEip2930(allocator: std.mem.Allocator, body: []const u8) !primitives.Transaction.Eip2930Transaction {
    const decoded = try primitives.Rlp.decode(allocator, body, false);
    const fields = try rlpAsList(decoded.data);
    if (fields.len != 11) return error.InvalidLength;
    const data_bytes = try rlpAsString(fields[6]);
    const al_items = try rlpAsList(fields[7]);
    return .{
        .chain_id = try rlpToU64(fields[0]),
        .nonce = try rlpToU64(fields[1]),
        .gas_price = try rlpToU256(fields[2]),
        .gas_limit = try rlpToU64(fields[3]),
        .to = try rlpToOptionalAddress(fields[4]),
        .value = try rlpToU256(fields[5]),
        .data = try allocator.dupe(u8, data_bytes),
        .access_list = try decodeAccessList(allocator, al_items),
        .y_parity = @intCast(try rlpToU64(fields[8])),
        .r = try rlpToFixed32(fields[9]),
        .s = try rlpToFixed32(fields[10]),
    };
}

fn decodeEip1559(
    allocator: std.mem.Allocator,
    body: []const u8,
) !primitives.Transaction.Eip1559Transaction {
    const decoded = try primitives.Rlp.decode(allocator, body, false);
    const fields = try rlpAsList(decoded.data);
    if (fields.len != 12) return error.InvalidLength;
    const data_bytes = try rlpAsString(fields[7]);
    const al_items = try rlpAsList(fields[8]);
    return .{
        .chain_id = try rlpToU64(fields[0]),
        .nonce = try rlpToU64(fields[1]),
        .max_priority_fee_per_gas = try rlpToU256(fields[2]),
        .max_fee_per_gas = try rlpToU256(fields[3]),
        .gas_limit = try rlpToU64(fields[4]),
        .to = try rlpToOptionalAddress(fields[5]),
        .value = try rlpToU256(fields[6]),
        .data = try allocator.dupe(u8, data_bytes),
        .access_list = try decodeAccessList(allocator, al_items),
        .y_parity = @intCast(try rlpToU64(fields[9])),
        .r = try rlpToFixed32(fields[10]),
        .s = try rlpToFixed32(fields[11]),
    };
}

// EIP-4844: accept either canonical envelope (RLP list of 14 fields) or
// network form (RLP list of [tx_payload, blobs, commitments, proofs]).
// Sidecar is ignored; only canonical envelope semantics are validated.
fn decodeEip4844Canonical(
    allocator: std.mem.Allocator,
    body: []const u8,
) !primitives.Transaction.Eip4844Transaction {
    const decoded = try primitives.Rlp.decode(allocator, body, false);
    const top = try rlpAsList(decoded.data);

    // Network form has exactly 4 elements where the first is itself a list.
    const fields = if (top.len == 4) blk: {
        switch (top[0]) {
            .List => |inner| break :blk inner,
            .String => break :blk top,
        }
    } else top;

    if (fields.len != 14) return error.InvalidLength;

    const data_bytes = try rlpAsString(fields[7]);
    const al_items = try rlpAsList(fields[8]);
    const blob_hash_items = try rlpAsList(fields[10]);

    const blob_hashes = try allocator.alloc(primitives.Blob.VersionedHash, blob_hash_items.len);
    for (blob_hash_items, 0..) |bh, i| {
        const h = try rlpToHash32(bh);
        blob_hashes[i] = .{ .bytes = h };
    }

    return .{
        .chain_id = try rlpToU64(fields[0]),
        .nonce = try rlpToU64(fields[1]),
        .max_priority_fee_per_gas = try rlpToU256(fields[2]),
        .max_fee_per_gas = try rlpToU256(fields[3]),
        .gas_limit = try rlpToU64(fields[4]),
        .to = try rlpToAddress(fields[5]),
        .value = try rlpToU256(fields[6]),
        .data = try allocator.dupe(u8, data_bytes),
        .access_list = try decodeAccessList(allocator, al_items),
        .max_fee_per_blob_gas = try rlpToU256(fields[9]),
        .blob_versioned_hashes = blob_hashes,
        .y_parity = @intCast(try rlpToU64(fields[11])),
        .r = try rlpToFixed32(fields[12]),
        .s = try rlpToFixed32(fields[13]),
    };
}

fn decodeEip7702(
    allocator: std.mem.Allocator,
    body: []const u8,
) !primitives.Transaction.Eip7702Transaction {
    const decoded = try primitives.Rlp.decode(allocator, body, false);
    const fields = try rlpAsList(decoded.data);
    if (fields.len != 13) return error.InvalidLength;
    const data_bytes = try rlpAsString(fields[7]);
    const al_items = try rlpAsList(fields[8]);
    const auth_items = try rlpAsList(fields[9]);
    return .{
        .chain_id = try rlpToU64(fields[0]),
        .nonce = try rlpToU64(fields[1]),
        .max_priority_fee_per_gas = try rlpToU256(fields[2]),
        .max_fee_per_gas = try rlpToU256(fields[3]),
        .gas_limit = try rlpToU64(fields[4]),
        .to = try rlpToOptionalAddress(fields[5]),
        .value = try rlpToU256(fields[6]),
        .data = try allocator.dupe(u8, data_bytes),
        .access_list = try decodeAccessList(allocator, al_items),
        .authorization_list = try decodeAuthorizationList(allocator, auth_items),
        .y_parity = @intCast(try rlpToU64(fields[10])),
        .r = try rlpToFixed32(fields[11]),
        .s = try rlpToFixed32(fields[12]),
    };
}

// --- Field accessors -----------------------------------------------------

fn envelopeNonce(d: DecodedEnvelope) u64 {
    return switch (d) {
        .legacy => |t| t.nonce,
        .eip2930 => |t| t.nonce,
        .eip1559 => |t| t.nonce,
        .eip4844 => |t| t.nonce,
        .eip7702 => |t| t.nonce,
    };
}

fn envelopeGasLimit(d: DecodedEnvelope) u64 {
    return switch (d) {
        .legacy => |t| t.gas_limit,
        .eip2930 => |t| t.gas_limit,
        .eip1559 => |t| t.gas_limit,
        .eip4844 => |t| t.gas_limit,
        .eip7702 => |t| t.gas_limit,
    };
}

fn envelopeMaxFeePerGas(d: DecodedEnvelope) u256 {
    return switch (d) {
        .legacy => |t| t.gas_price,
        .eip2930 => |t| t.gas_price,
        .eip1559 => |t| t.max_fee_per_gas,
        .eip4844 => |t| t.max_fee_per_gas,
        .eip7702 => |t| t.max_fee_per_gas,
    };
}

fn envelopePriorityFee(d: DecodedEnvelope) u256 {
    return switch (d) {
        .legacy => |t| t.gas_price,
        .eip2930 => |t| t.gas_price,
        .eip1559 => |t| t.max_priority_fee_per_gas,
        .eip4844 => |t| t.max_priority_fee_per_gas,
        .eip7702 => |t| t.max_priority_fee_per_gas,
    };
}

fn envelopeValue(d: DecodedEnvelope) u256 {
    return switch (d) {
        .legacy => |t| t.value,
        .eip2930 => |t| t.value,
        .eip1559 => |t| t.value,
        .eip4844 => |t| t.value,
        .eip7702 => |t| t.value,
    };
}

fn envelopeData(d: DecodedEnvelope) []const u8 {
    return switch (d) {
        .legacy => |t| t.data,
        .eip2930 => |t| t.data,
        .eip1559 => |t| t.data,
        .eip4844 => |t| t.data,
        .eip7702 => |t| t.data,
    };
}

fn envelopeTo(d: DecodedEnvelope) ?primitives.Address {
    return switch (d) {
        .legacy => |t| t.to,
        .eip2930 => |t| t.to,
        .eip1559 => |t| t.to,
        .eip4844 => |t| primitives.Address{ .bytes = t.to.bytes },
        .eip7702 => |t| t.to,
    };
}

fn envelopeChainId(d: DecodedEnvelope) ?u64 {
    return switch (d) {
        .legacy => |t| primitives.Transaction.getLegacyTransactionChainId(t),
        .eip2930 => |t| t.chain_id,
        .eip1559 => |t| t.chain_id,
        .eip4844 => |t| t.chain_id,
        .eip7702 => |t| t.chain_id,
    };
}

fn envelopeAccessList(d: DecodedEnvelope) []const primitives.Transaction.AccessListItem {
    return switch (d) {
        .legacy => &[_]primitives.Transaction.AccessListItem{},
        .eip2930 => |t| t.access_list,
        .eip1559 => |t| t.access_list,
        .eip4844 => |t| t.access_list,
        .eip7702 => |t| t.access_list,
    };
}

fn envelopeAuthList(d: DecodedEnvelope) []const primitives.Authorization.Authorization {
    return switch (d) {
        .eip7702 => |t| t.authorization_list,
        else => &[_]primitives.Authorization.Authorization{},
    };
}

// --- Intrinsic gas (EIP-2028, 2930, 3860, 7702) --------------------------

fn computeIntrinsicGas(d: DecodedEnvelope, is_create: bool, data: []const u8) u64 {
    var gas: u64 = INTRINSIC_TX;
    if (is_create) gas += INTRINSIC_CREATE;

    for (data) |b| {
        gas += if (b == 0) CALLDATA_ZERO_GAS else CALLDATA_NONZERO_GAS;
    }

    if (is_create) {
        const word_count = (data.len + 31) / 32;
        gas += INITCODE_WORD_GAS * @as(u64, @intCast(word_count));
    }

    const al = envelopeAccessList(d);
    for (al) |item| {
        gas += ACCESS_LIST_ADDR_GAS;
        gas += ACCESS_LIST_KEY_GAS * @as(u64, @intCast(item.storage_keys.len));
    }

    const auths = envelopeAuthList(d);
    gas += PER_AUTH_GAS * @as(u64, @intCast(auths.len));

    return gas;
}

// --- Signing hash + ecrecover --------------------------------------------

fn computeSigningHash(
    allocator: std.mem.Allocator,
    d: DecodedEnvelope,
    chain_id: u64,
) ![32]u8 {
    return switch (d) {
        .legacy => |t| blk: {
            var unsigned = t;
            unsigned.v = 0;
            unsigned.r = [_]u8{0} ** 32;
            unsigned.s = [_]u8{0} ** 32;
            const enc = try primitives.Transaction.encodeLegacyForSigning(allocator, unsigned, chain_id);
            defer allocator.free(enc);
            break :blk keccak(enc);
        },
        .eip2930 => |t| blk: {
            var unsigned = t;
            unsigned.y_parity = 0;
            unsigned.r = [_]u8{0} ** 32;
            unsigned.s = [_]u8{0} ** 32;
            const enc = try primitives.Transaction.encodeEip2930ForSigning(allocator, unsigned);
            defer allocator.free(enc);
            break :blk keccak(enc);
        },
        .eip1559 => |t| blk: {
            var unsigned = t;
            unsigned.y_parity = 0;
            unsigned.r = [_]u8{0} ** 32;
            unsigned.s = [_]u8{0} ** 32;
            const enc = try primitives.Transaction.encodeEip1559ForSigning(allocator, unsigned);
            defer allocator.free(enc);
            break :blk keccak(enc);
        },
        .eip4844 => |t| blk: {
            var unsigned = t;
            unsigned.y_parity = 0;
            unsigned.r = [_]u8{0} ** 32;
            unsigned.s = [_]u8{0} ** 32;
            const enc = try primitives.Transaction.encodeEip4844ForSigning(allocator, unsigned);
            defer allocator.free(enc);
            break :blk keccak(enc);
        },
        .eip7702 => |t| blk: {
            var unsigned = t;
            unsigned.y_parity = 0;
            unsigned.r = [_]u8{0} ** 32;
            unsigned.s = [_]u8{0} ** 32;
            const enc = try primitives.Transaction.encodeEip7702ForSigning(allocator, unsigned);
            defer allocator.free(enc);
            break :blk keccak(enc);
        },
    };
}


fn keccak(input: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(input, &out, .{});
    return out;
}

fn recoverSender(d: DecodedEnvelope, sig_hash: [32]u8) !primitives.Address {
    var r_bytes: [32]u8 = undefined;
    var s_bytes: [32]u8 = undefined;
    var recovery_id: u8 = 0;
    switch (d) {
        .legacy => |t| {
            r_bytes = t.r;
            s_bytes = t.s;
            recovery_id = legacyRecoveryId(t.v);
        },
        .eip2930 => |t| {
            r_bytes = t.r;
            s_bytes = t.s;
            recovery_id = t.y_parity;
        },
        .eip1559 => |t| {
            r_bytes = t.r;
            s_bytes = t.s;
            recovery_id = t.y_parity;
        },
        .eip4844 => |t| {
            r_bytes = t.r;
            s_bytes = t.s;
            recovery_id = t.y_parity;
        },
        .eip7702 => |t| {
            r_bytes = t.r;
            s_bytes = t.s;
            recovery_id = t.y_parity;
        },
    }

    const r_u256 = std.mem.readInt(u256, &r_bytes, .big);
    const s_u256 = std.mem.readInt(u256, &s_bytes, .big);

    const sig = crypto.Crypto.Signature{
        .r = r_u256,
        .s = s_u256,
        .v = recovery_id + 27,
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

fn automine(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    decoded: DecodedEnvelope,
    sender: primitives.Address,
) !void {
    _ = allocator;
    const exec_tx = tx_processor.ExecutionTx{
        .caller = sender,
        .tx = legacyShapeFromEnvelope(decoded),
    };
    _ = exec_tx;

    rt.head_block_number += 1;
}

// Project typed envelopes onto the legacy execution shape (`ExecutionTx.tx`
// is `LegacyTransaction`). Preserves to/value/data/nonce/gas semantics; the
// signature fields are not used downstream by tx_processor.
fn legacyShapeFromEnvelope(d: DecodedEnvelope) primitives.Transaction.LegacyTransaction {
    const to_opt = envelopeTo(d);
    return .{
        .nonce = envelopeNonce(d),
        .gas_price = envelopeMaxFeePerGas(d),
        .gas_limit = envelopeGasLimit(d),
        .to = to_opt,
        .value = envelopeValue(d),
        .data = envelopeData(d),
        .v = 0,
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
    };
}
