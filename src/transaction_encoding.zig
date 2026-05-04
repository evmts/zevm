const std = @import("std");
const primitives = @import("primitives");
const crypto = @import("crypto");

pub const TransactionEncodingError = error{
    InputTooShort,
    InputTooLong,
    LeadingZeros,
    NonCanonicalSize,
    NonCanonicalInteger,
    InvalidLength,
    UnexpectedInput,
    InvalidRemainder,
    InvalidSignatureV,
    InvalidTransactionType,
    RlpPayloadTooLarge,
    OutOfMemory,
};

const RlpItem = union(enum) {
    string: []const u8,
    list: []const u8,
};

pub const DecodedEnvelope = union(enum) {
    legacy: primitives.Transaction.LegacyTransaction,
    eip2930: primitives.Transaction.Eip2930Transaction,
    eip1559: primitives.Transaction.Eip1559Transaction,
    eip4844: primitives.Transaction.Eip4844Transaction,
    eip7702: primitives.Transaction.Eip7702Transaction,

    pub fn deinit(self: DecodedEnvelope, allocator: std.mem.Allocator) void {
        switch (self) {
            .legacy => {},
            .eip2930 => |tx| freeTransactionAccessList(allocator, tx.access_list),
            .eip1559 => |tx| freeTransactionAccessList(allocator, tx.access_list),
            .eip4844 => |tx| {
                freeTransactionAccessList(allocator, tx.access_list);
                allocator.free(tx.blob_versioned_hashes);
            },
            .eip7702 => |tx| {
                freeTransactionAccessList(allocator, tx.access_list);
                allocator.free(tx.authorization_list);
            },
        }
    }
};

pub const CanonicalEnvelope = struct {
    bytes: []const u8,
    owned: ?[]u8 = null,

    pub fn deinit(self: CanonicalEnvelope, allocator: std.mem.Allocator) void {
        if (self.owned) |buffer| allocator.free(buffer);
    }
};

pub fn decodeEnvelope(
    allocator: std.mem.Allocator,
    raw: []const u8,
) TransactionEncodingError!DecodedEnvelope {
    if (raw.len == 0) return error.InputTooShort;
    if (raw[0] >= 0xc0) return .{ .legacy = try decodeLegacyEnvelope(raw) };
    if (raw[0] > 0x7f) return error.InvalidTransactionType;

    return switch (raw[0]) {
        0x01 => .{ .eip2930 = try decodeEip2930Envelope(allocator, raw) },
        0x02 => .{ .eip1559 = try decodeEip1559Envelope(allocator, raw) },
        0x03 => .{ .eip4844 = try decodeEip4844Envelope(allocator, raw) },
        0x04 => .{ .eip7702 = try decodeEip7702Envelope(allocator, raw) },
        else => error.InvalidTransactionType,
    };
}

pub fn canonicalTransactionEnvelope(
    allocator: std.mem.Allocator,
    raw: []const u8,
) TransactionEncodingError!CanonicalEnvelope {
    if (raw.len == 0 or raw[0] != 0x03) return .{ .bytes = raw };
    const tx_payload = try eip4844WrapperTransactionPayload(raw) orelse return .{ .bytes = raw };

    const canonical = try allocator.alloc(u8, tx_payload.len + 1);
    canonical[0] = 0x03;
    @memcpy(canonical[1..], tx_payload);
    return .{ .bytes = canonical, .owned = canonical };
}

pub fn envelopeToLegacyLikeTx(decoded: DecodedEnvelope) primitives.Transaction.LegacyTransaction {
    return switch (decoded) {
        .legacy => |tx| tx,
        .eip2930 => |tx| .{
            .nonce = tx.nonce,
            .gas_price = tx.gas_price,
            .gas_limit = tx.gas_limit,
            .to = tx.to,
            .value = tx.value,
            .data = tx.data,
            .v = @as(u64, tx.y_parity) + 27,
            .r = tx.r,
            .s = tx.s,
        },
        .eip1559 => |tx| .{
            .nonce = tx.nonce,
            .gas_price = tx.max_fee_per_gas,
            .gas_limit = tx.gas_limit,
            .to = tx.to,
            .value = tx.value,
            .data = tx.data,
            .v = @as(u64, tx.y_parity) + 27,
            .r = tx.r,
            .s = tx.s,
        },
        .eip4844 => |tx| .{
            .nonce = tx.nonce,
            .gas_price = tx.max_fee_per_gas,
            .gas_limit = tx.gas_limit,
            .to = tx.to,
            .value = tx.value,
            .data = tx.data,
            .v = @as(u64, tx.y_parity) + 27,
            .r = tx.r,
            .s = tx.s,
        },
        .eip7702 => |tx| .{
            .nonce = tx.nonce,
            .gas_price = tx.max_fee_per_gas,
            .gas_limit = tx.gas_limit,
            .to = tx.to,
            .value = tx.value,
            .data = tx.data,
            .v = @as(u64, tx.y_parity) + 27,
            .r = tx.r,
            .s = tx.s,
        },
    };
}

pub fn envelopeReceiptType(decoded: DecodedEnvelope) primitives.Receipt.TransactionType {
    return switch (decoded) {
        .legacy => .legacy,
        .eip2930 => .eip2930,
        .eip1559 => .eip1559,
        .eip4844 => .eip4844,
        .eip7702 => .eip7702,
    };
}

pub fn envelopeChainId(decoded: DecodedEnvelope) ?u64 {
    return switch (decoded) {
        .legacy => |tx| legacyChainId(tx),
        .eip2930 => |tx| tx.chain_id,
        .eip1559 => |tx| tx.chain_id,
        .eip4844 => |tx| tx.chain_id,
        .eip7702 => |tx| tx.chain_id,
    };
}

pub fn envelopeAccessList(decoded: DecodedEnvelope) []const primitives.Transaction.AccessListItem {
    return switch (decoded) {
        .legacy => &.{},
        .eip2930 => |tx| tx.access_list,
        .eip1559 => |tx| tx.access_list,
        .eip4844 => |tx| tx.access_list,
        .eip7702 => |tx| tx.access_list,
    };
}

pub fn envelopeMaxFeePerGas(decoded: DecodedEnvelope) ?u256 {
    return switch (decoded) {
        .legacy, .eip2930 => null,
        .eip1559 => |tx| tx.max_fee_per_gas,
        .eip4844 => |tx| tx.max_fee_per_gas,
        .eip7702 => |tx| tx.max_fee_per_gas,
    };
}

pub fn envelopeMaxPriorityFeePerGas(decoded: DecodedEnvelope) ?u256 {
    return switch (decoded) {
        .legacy, .eip2930 => null,
        .eip1559 => |tx| tx.max_priority_fee_per_gas,
        .eip4844 => |tx| tx.max_priority_fee_per_gas,
        .eip7702 => |tx| tx.max_priority_fee_per_gas,
    };
}

pub fn envelopeBlobGasUsed(decoded: DecodedEnvelope) ?u256 {
    return switch (decoded) {
        .eip4844 => |tx| @as(u256, tx.blob_versioned_hashes.len) * @as(u256, 131_072),
        else => null,
    };
}

pub fn envelopeMaxFeePerBlobGas(decoded: DecodedEnvelope) ?u256 {
    return switch (decoded) {
        .eip4844 => |tx| tx.max_fee_per_blob_gas,
        else => null,
    };
}

pub fn envelopeAuthorizationList(decoded: DecodedEnvelope) []const primitives.Authorization.Authorization {
    return switch (decoded) {
        .eip7702 => |tx| tx.authorization_list,
        else => &.{},
    };
}

pub fn encodeLegacyTransactionEnvelope(
    allocator: std.mem.Allocator,
    tx: primitives.Transaction.LegacyTransaction,
) ![]u8 {
    var fields = std.ArrayList([]u8){};
    defer freeEncodedFields(allocator, &fields);

    try fields.append(allocator, try primitives.Rlp.encode(allocator, tx.nonce));
    try fields.append(allocator, try primitives.Rlp.encode(allocator, tx.gas_price));
    try fields.append(allocator, try primitives.Rlp.encode(allocator, tx.gas_limit));
    if (tx.to) |to| {
        try fields.append(allocator, try primitives.Rlp.encodeBytes(allocator, &to.bytes));
    } else {
        try fields.append(allocator, try primitives.Rlp.encodeBytes(allocator, &.{}));
    }
    try fields.append(allocator, try primitives.Rlp.encode(allocator, tx.value));
    try fields.append(allocator, try primitives.Rlp.encodeBytes(allocator, tx.data));
    try fields.append(allocator, try primitives.Rlp.encode(allocator, tx.v));
    try fields.append(allocator, try primitives.Rlp.encode(allocator, bytes32ToU256(tx.r)));
    try fields.append(allocator, try primitives.Rlp.encode(allocator, bytes32ToU256(tx.s)));

    return encodeRlpListFromEncodedFields(allocator, fields.items);
}

pub fn encodeLegacySigningPreimage(
    allocator: std.mem.Allocator,
    tx: primitives.Transaction.LegacyTransaction,
    chain_id: ?u64,
) ![]u8 {
    var fields = std.ArrayList([]u8){};
    defer freeEncodedFields(allocator, &fields);

    try fields.append(allocator, try primitives.Rlp.encode(allocator, tx.nonce));
    try fields.append(allocator, try primitives.Rlp.encode(allocator, tx.gas_price));
    try fields.append(allocator, try primitives.Rlp.encode(allocator, tx.gas_limit));
    if (tx.to) |to| {
        try fields.append(allocator, try primitives.Rlp.encodeBytes(allocator, &to.bytes));
    } else {
        try fields.append(allocator, try primitives.Rlp.encodeBytes(allocator, &.{}));
    }
    try fields.append(allocator, try primitives.Rlp.encode(allocator, tx.value));
    try fields.append(allocator, try primitives.Rlp.encodeBytes(allocator, tx.data));

    if (chain_id) |id| {
        try fields.append(allocator, try primitives.Rlp.encode(allocator, id));
        try fields.append(allocator, try primitives.Rlp.encode(allocator, @as(u64, 0)));
        try fields.append(allocator, try primitives.Rlp.encode(allocator, @as(u64, 0)));
    }

    return encodeRlpListFromEncodedFields(allocator, fields.items);
}

pub fn signLegacyTransaction(
    allocator: std.mem.Allocator,
    tx: primitives.Transaction.LegacyTransaction,
    private_key: crypto.Crypto.PrivateKey,
    chain_id: u64,
) !primitives.Transaction.LegacyTransaction {
    const preimage = try encodeLegacySigningPreimage(allocator, tx, chain_id);
    defer allocator.free(preimage);

    const signature = try crypto.Crypto.unaudited_signHash(transactionHash(preimage), private_key);

    var signed = tx;
    signed.v = chain_id * 2 + 35 + @as(u64, signature.v - 27);
    std.mem.writeInt(u256, &signed.r, signature.r, .big);
    std.mem.writeInt(u256, &signed.s, signature.s, .big);
    return signed;
}

/// Decodes a canonical legacy transaction envelope. The returned `data` slice
/// borrows from `raw`; callers must keep `raw` alive while using the transaction.
pub fn decodeLegacyEnvelope(raw: []const u8) TransactionEncodingError!primitives.Transaction.LegacyTransaction {
    const tx = try decodeLegacyEnvelopeAllowInvalidSignature(raw);
    if (!legacyVIsValid(tx.v)) return error.InvalidSignatureV;
    return tx;
}

pub fn decodeLegacyEnvelopeAllowInvalidSignature(raw: []const u8) TransactionEncodingError!primitives.Transaction.LegacyTransaction {
    var index: usize = 0;
    const top = try parseRlpItem(raw, &index);
    if (index != raw.len) return error.InvalidRemainder;

    const payload = switch (top) {
        .list => |items| items,
        .string => return error.UnexpectedInput,
    };

    var payload_index: usize = 0;
    var fields: [9][]const u8 = undefined;
    for (&fields) |*field| {
        const item = try parseRlpItem(payload, &payload_index);
        field.* = switch (item) {
            .string => |bytes| bytes,
            .list => return error.UnexpectedInput,
        };
    }
    if (payload_index != payload.len) return error.InvalidLength;

    const v = try rlpStringToU64(fields[6]);
    return .{
        .nonce = try rlpStringToU64(fields[0]),
        .gas_price = try rlpStringToU256(fields[1]),
        .gas_limit = try rlpStringToU64(fields[2]),
        .to = try rlpStringToOptionalAddress(fields[3]),
        .value = try rlpStringToU256(fields[4]),
        .data = fields[5],
        .v = v,
        .r = try rlpStringToFixed32(fields[7]),
        .s = try rlpStringToFixed32(fields[8]),
    };
}

pub fn decodeEip2930Envelope(
    allocator: std.mem.Allocator,
    raw: []const u8,
) TransactionEncodingError!primitives.Transaction.Eip2930Transaction {
    const fields = try decodeTypedPayloadFields(11, raw, 0x01);
    const access_list = try rlpItemToTransactionAccessList(allocator, fields[7]);
    errdefer freeTransactionAccessList(allocator, access_list);
    const y_parity = try rlpStringToU8(try rlpItemString(fields[8]));
    if (y_parity > 1) return error.InvalidSignatureV;

    return .{
        .chain_id = try rlpStringToU64(try rlpItemString(fields[0])),
        .nonce = try rlpStringToU64(try rlpItemString(fields[1])),
        .gas_price = try rlpStringToU256(try rlpItemString(fields[2])),
        .gas_limit = try rlpStringToU64(try rlpItemString(fields[3])),
        .to = try rlpStringToOptionalAddress(try rlpItemString(fields[4])),
        .value = try rlpStringToU256(try rlpItemString(fields[5])),
        .data = try rlpItemString(fields[6]),
        .access_list = access_list,
        .y_parity = y_parity,
        .r = try rlpStringToFixed32(try rlpItemString(fields[9])),
        .s = try rlpStringToFixed32(try rlpItemString(fields[10])),
    };
}

pub fn decodeEip1559Envelope(
    allocator: std.mem.Allocator,
    raw: []const u8,
) TransactionEncodingError!primitives.Transaction.Eip1559Transaction {
    const fields = try decodeTypedPayloadFields(12, raw, 0x02);
    const access_list = try rlpItemToTransactionAccessList(allocator, fields[8]);
    errdefer freeTransactionAccessList(allocator, access_list);
    const y_parity = try rlpStringToU8(try rlpItemString(fields[9]));
    if (y_parity > 1) return error.InvalidSignatureV;

    return .{
        .chain_id = try rlpStringToU64(try rlpItemString(fields[0])),
        .nonce = try rlpStringToU64(try rlpItemString(fields[1])),
        .max_priority_fee_per_gas = try rlpStringToU256(try rlpItemString(fields[2])),
        .max_fee_per_gas = try rlpStringToU256(try rlpItemString(fields[3])),
        .gas_limit = try rlpStringToU64(try rlpItemString(fields[4])),
        .to = try rlpStringToOptionalAddress(try rlpItemString(fields[5])),
        .value = try rlpStringToU256(try rlpItemString(fields[6])),
        .data = try rlpItemString(fields[7]),
        .access_list = access_list,
        .y_parity = y_parity,
        .r = try rlpStringToFixed32(try rlpItemString(fields[10])),
        .s = try rlpStringToFixed32(try rlpItemString(fields[11])),
    };
}

pub fn decodeEip4844Envelope(
    allocator: std.mem.Allocator,
    raw: []const u8,
) TransactionEncodingError!primitives.Transaction.Eip4844Transaction {
    const fields = try decodeEip4844PayloadFields(raw);
    const access_list = try rlpItemToTransactionAccessList(allocator, fields[8]);
    errdefer freeTransactionAccessList(allocator, access_list);
    const blob_hashes = try rlpItemToBlobVersionedHashes(allocator, fields[10]);
    errdefer allocator.free(blob_hashes);
    const y_parity = try rlpStringToU8(try rlpItemString(fields[11]));
    if (y_parity > 1) return error.InvalidSignatureV;
    const to = try rlpStringToAddress(try rlpItemString(fields[5]));

    return .{
        .chain_id = try rlpStringToU64(try rlpItemString(fields[0])),
        .nonce = try rlpStringToU64(try rlpItemString(fields[1])),
        .max_priority_fee_per_gas = try rlpStringToU256(try rlpItemString(fields[2])),
        .max_fee_per_gas = try rlpStringToU256(try rlpItemString(fields[3])),
        .gas_limit = try rlpStringToU64(try rlpItemString(fields[4])),
        .to = to,
        .value = try rlpStringToU256(try rlpItemString(fields[6])),
        .data = try rlpItemString(fields[7]),
        .access_list = access_list,
        .max_fee_per_blob_gas = try rlpStringToU256(try rlpItemString(fields[9])),
        .blob_versioned_hashes = blob_hashes,
        .y_parity = y_parity,
        .r = try rlpStringToFixed32(try rlpItemString(fields[12])),
        .s = try rlpStringToFixed32(try rlpItemString(fields[13])),
    };
}

pub fn decodeEip7702Envelope(
    allocator: std.mem.Allocator,
    raw: []const u8,
) TransactionEncodingError!primitives.Transaction.Eip7702Transaction {
    const fields = try decodeTypedPayloadFields(13, raw, 0x04);
    const access_list = try rlpItemToTransactionAccessList(allocator, fields[8]);
    errdefer freeTransactionAccessList(allocator, access_list);
    const authorization_list = try rlpItemToAuthorizationList(allocator, fields[9]);
    errdefer allocator.free(authorization_list);
    const y_parity = try rlpStringToU8(try rlpItemString(fields[10]));
    if (y_parity > 1) return error.InvalidSignatureV;

    return .{
        .chain_id = try rlpStringToU64(try rlpItemString(fields[0])),
        .nonce = try rlpStringToU64(try rlpItemString(fields[1])),
        .max_priority_fee_per_gas = try rlpStringToU256(try rlpItemString(fields[2])),
        .max_fee_per_gas = try rlpStringToU256(try rlpItemString(fields[3])),
        .gas_limit = try rlpStringToU64(try rlpItemString(fields[4])),
        .to = try rlpStringToOptionalAddress(try rlpItemString(fields[5])),
        .value = try rlpStringToU256(try rlpItemString(fields[6])),
        .data = try rlpItemString(fields[7]),
        .access_list = access_list,
        .authorization_list = authorization_list,
        .y_parity = y_parity,
        .r = try rlpStringToFixed32(try rlpItemString(fields[11])),
        .s = try rlpStringToFixed32(try rlpItemString(fields[12])),
    };
}

pub fn legacyChainId(tx: primitives.Transaction.LegacyTransaction) ?u64 {
    if (tx.v >= 35) return (tx.v - 35) / 2;
    return null;
}

pub fn legacySigningHash(
    allocator: std.mem.Allocator,
    tx: primitives.Transaction.LegacyTransaction,
) ![32]u8 {
    const preimage = try encodeLegacySigningPreimage(allocator, tx, legacyChainId(tx));
    defer allocator.free(preimage);
    return transactionHash(preimage);
}

pub fn recoverLegacySender(
    allocator: std.mem.Allocator,
    tx: primitives.Transaction.LegacyTransaction,
) !primitives.Address {
    const signing_hash = try legacySigningHash(allocator, tx);
    const sig = crypto.Crypto.Signature{
        .r = bytes32ToU256(tx.r),
        .s = bytes32ToU256(tx.s),
        .v = legacyRecoveryId(tx.v) + 27,
    };
    return crypto.Crypto.unaudited_recoverAddress(signing_hash, sig);
}

pub fn recoverEnvelopeSender(
    allocator: std.mem.Allocator,
    decoded: DecodedEnvelope,
) !primitives.Address {
    return switch (decoded) {
        .legacy => |tx| recoverLegacySender(allocator, tx),
        .eip2930 => |tx| recoverTypedSender(allocator, 0x01, tx.y_parity, tx.r, tx.s, tx),
        .eip1559 => |tx| recoverTypedSender(allocator, 0x02, tx.y_parity, tx.r, tx.s, tx),
        .eip4844 => |tx| recoverTypedSender(allocator, 0x03, tx.y_parity, tx.r, tx.s, tx),
        .eip7702 => |tx| recoverTypedSender(allocator, 0x04, tx.y_parity, tx.r, tx.s, tx),
    };
}

fn recoverTypedSender(
    allocator: std.mem.Allocator,
    comptime tx_type: u8,
    y_parity: u8,
    r: [32]u8,
    s: [32]u8,
    tx: anytype,
) !primitives.Address {
    const signing_hash = try typedSigningHash(allocator, tx_type, tx);
    const sig = crypto.Crypto.Signature{
        .r = bytes32ToU256(r),
        .s = bytes32ToU256(s),
        .v = y_parity + 27,
    };
    return crypto.Crypto.unaudited_recoverAddress(signing_hash, sig);
}

fn typedSigningHash(
    allocator: std.mem.Allocator,
    comptime tx_type: u8,
    tx: anytype,
) ![32]u8 {
    var unsigned = tx;
    unsigned.y_parity = 0;
    unsigned.r = [_]u8{0} ** 32;
    unsigned.s = [_]u8{0} ** 32;

    const encoded = switch (tx_type) {
        0x01 => try primitives.Transaction.encodeEip2930ForSigning(allocator, unsigned),
        0x02 => try primitives.Transaction.encodeEip1559ForSigning(allocator, unsigned),
        0x03 => try primitives.Transaction.encodeEip4844ForSigning(allocator, unsigned),
        0x04 => try primitives.Transaction.encodeEip7702ForSigning(allocator, unsigned),
        else => unreachable,
    };
    defer allocator.free(encoded);
    return transactionHash(encoded);
}

pub fn transactionHash(raw: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(raw, &out, .{});
    return out;
}

pub fn bytes32ToU256(bytes: [32]u8) u256 {
    return std.mem.readInt(u256, &bytes, .big);
}

pub fn legacyRecoveryId(v: u64) u8 {
    if (v >= 35) return @intCast((v - 35) % 2);
    if (v == 27 or v == 28) return @intCast(v - 27);
    return @intCast(v % 2);
}

fn legacyVIsValid(v: u64) bool {
    return v == 27 or v == 28 or v >= 35;
}

fn parseRlpItem(input: []const u8, index: *usize) TransactionEncodingError!RlpItem {
    if (index.* >= input.len) return error.InputTooShort;

    const prefix = input[index.*];
    index.* += 1;

    if (prefix <= 0x7f) {
        return .{ .string = input[index.* - 1 .. index.*] };
    }

    if (prefix <= 0xb7) {
        const len: usize = prefix - 0x80;
        const start = index.*;
        const end = try checkedEnd(input, start, len);
        if (len == 1 and input[start] < 0x80) return error.NonCanonicalSize;
        index.* = end;
        return .{ .string = input[start..end] };
    }

    if (prefix <= 0xbf) {
        const len_of_len: usize = prefix - 0xb7;
        const len = try readLongLength(input, index, len_of_len);
        if (len < 56) return error.NonCanonicalSize;
        const start = index.*;
        const end = try checkedEnd(input, start, len);
        index.* = end;
        return .{ .string = input[start..end] };
    }

    if (prefix <= 0xf7) {
        const len: usize = prefix - 0xc0;
        const start = index.*;
        const end = try checkedEnd(input, start, len);
        index.* = end;
        return .{ .list = input[start..end] };
    }

    const len_of_len: usize = prefix - 0xf7;
    const len = try readLongLength(input, index, len_of_len);
    if (len < 56) return error.NonCanonicalSize;
    const start = index.*;
    const end = try checkedEnd(input, start, len);
    index.* = end;
    return .{ .list = input[start..end] };
}

fn decodeTypedPayloadFields(
    comptime field_count: usize,
    raw: []const u8,
    expected_type: u8,
) TransactionEncodingError![field_count]RlpItem {
    const payload = try decodeTypedPayload(raw, expected_type);

    return decodeRlpPayloadFields(field_count, payload);
}

fn decodeTypedPayload(
    raw: []const u8,
    expected_type: u8,
) TransactionEncodingError![]const u8 {
    if (raw.len < 2) return error.InputTooShort;
    if (raw[0] != expected_type) return error.InvalidTransactionType;

    var index: usize = 1;
    const top = try parseRlpItem(raw, &index);
    if (index != raw.len) return error.InvalidRemainder;
    const payload = switch (top) {
        .list => |items| items,
        .string => return error.UnexpectedInput,
    };
    return payload;
}

fn decodeEip4844PayloadFields(raw: []const u8) TransactionEncodingError![14]RlpItem {
    const payload = try decodeTypedPayload(raw, 0x03);
    var payload_index: usize = 0;
    const first = try parseRlpItem(payload, &payload_index);
    switch (first) {
        .string => return decodeRlpPayloadFields(14, payload),
        .list => |tx_payload| {
            const blobs = try parseRlpItem(payload, &payload_index);
            const commitments = try parseRlpItem(payload, &payload_index);
            const proofs = try parseRlpItem(payload, &payload_index);
            if (payload_index != payload.len) return error.InvalidLength;
            _ = try rlpItemList(blobs);
            _ = try rlpItemList(commitments);
            _ = try rlpItemList(proofs);
            return decodeRlpPayloadFields(14, tx_payload);
        },
    }
}

fn eip4844WrapperTransactionPayload(raw: []const u8) TransactionEncodingError!?[]const u8 {
    const payload = try decodeTypedPayload(raw, 0x03);
    var payload_index: usize = 0;
    const first = try parseRlpItem(payload, &payload_index);
    switch (first) {
        .string => return null,
        .list => {
            const tx_payload = payload[0..payload_index];
            const blobs = try parseRlpItem(payload, &payload_index);
            const commitments = try parseRlpItem(payload, &payload_index);
            const proofs = try parseRlpItem(payload, &payload_index);
            if (payload_index != payload.len) return error.InvalidLength;
            _ = try rlpItemList(blobs);
            _ = try rlpItemList(commitments);
            _ = try rlpItemList(proofs);
            return tx_payload;
        },
    }
}

fn rlpItemString(item: RlpItem) TransactionEncodingError![]const u8 {
    return switch (item) {
        .string => |bytes| bytes,
        .list => error.UnexpectedInput,
    };
}

fn rlpItemList(item: RlpItem) TransactionEncodingError![]const u8 {
    return switch (item) {
        .list => |payload| payload,
        .string => error.UnexpectedInput,
    };
}

fn rlpItemToTransactionAccessList(
    allocator: std.mem.Allocator,
    item: RlpItem,
) TransactionEncodingError![]primitives.Transaction.AccessListItem {
    const payload = try rlpItemList(item);
    var entries = std.ArrayList(primitives.Transaction.AccessListItem){};
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.storage_keys);
        }
        entries.deinit(allocator);
    }

    var index: usize = 0;
    while (index < payload.len) {
        const entry_payload = try rlpItemList(try parseRlpItem(payload, &index));
        var entry_index: usize = 0;
        const address = try rlpStringToAddress(try rlpItemString(try parseRlpItem(entry_payload, &entry_index)));
        const keys_payload = try rlpItemList(try parseRlpItem(entry_payload, &entry_index));
        if (entry_index != entry_payload.len) return error.InvalidLength;

        var keys = std.ArrayList([32]u8){};
        errdefer {
            keys.deinit(allocator);
        }
        var keys_index: usize = 0;
        while (keys_index < keys_payload.len) {
            try keys.append(allocator, try rlpStringToRawFixed32(try rlpItemString(try parseRlpItem(keys_payload, &keys_index))));
        }

        const owned_keys = try keys.toOwnedSlice(allocator);
        errdefer allocator.free(owned_keys);
        try entries.append(allocator, .{
            .address = address,
            .storage_keys = owned_keys,
        });
    }

    return entries.toOwnedSlice(allocator);
}

fn freeTransactionAccessList(
    allocator: std.mem.Allocator,
    access_list: []const primitives.Transaction.AccessListItem,
) void {
    for (access_list) |entry| {
        allocator.free(entry.storage_keys);
    }
    allocator.free(access_list);
}

fn rlpItemToBlobVersionedHashes(
    allocator: std.mem.Allocator,
    item: RlpItem,
) TransactionEncodingError![]primitives.Blob.VersionedHash {
    const payload = try rlpItemList(item);
    var hashes = std.ArrayList(primitives.Blob.VersionedHash){};
    errdefer hashes.deinit(allocator);

    var index: usize = 0;
    while (index < payload.len) {
        try hashes.append(allocator, .{
            .bytes = try rlpStringToRawFixed32(try rlpItemString(try parseRlpItem(payload, &index))),
        });
    }
    return hashes.toOwnedSlice(allocator);
}

fn rlpItemToAuthorizationList(
    allocator: std.mem.Allocator,
    item: RlpItem,
) TransactionEncodingError![]primitives.Authorization.Authorization {
    const payload = try rlpItemList(item);
    var authorizations = std.ArrayList(primitives.Authorization.Authorization){};
    errdefer authorizations.deinit(allocator);

    var index: usize = 0;
    while (index < payload.len) {
        const auth_payload = try rlpItemList(try parseRlpItem(payload, &index));
        const fields = try decodeRlpPayloadFields(6, auth_payload);
        const y_parity = try rlpStringToU64(try rlpItemString(fields[3]));
        if (y_parity > 1) return error.InvalidSignatureV;
        try authorizations.append(allocator, .{
            .chain_id = try rlpStringToU64(try rlpItemString(fields[0])),
            .address = try rlpStringToAddress(try rlpItemString(fields[1])),
            .nonce = try rlpStringToU64(try rlpItemString(fields[2])),
            .v = y_parity,
            .r = try rlpStringToFixed32(try rlpItemString(fields[4])),
            .s = try rlpStringToFixed32(try rlpItemString(fields[5])),
        });
    }
    return authorizations.toOwnedSlice(allocator);
}

fn decodeRlpPayloadFields(
    comptime field_count: usize,
    payload: []const u8,
) TransactionEncodingError![field_count]RlpItem {
    var payload_index: usize = 0;
    var fields: [field_count]RlpItem = undefined;
    for (&fields) |*field| {
        field.* = try parseRlpItem(payload, &payload_index);
    }
    if (payload_index != payload.len) return error.InvalidLength;
    return fields;
}

fn checkedEnd(input: []const u8, start: usize, len: usize) TransactionEncodingError!usize {
    const end = std.math.add(usize, start, len) catch return error.InputTooLong;
    if (end > input.len) return error.InputTooShort;
    return end;
}

fn readLongLength(
    input: []const u8,
    index: *usize,
    len_of_len: usize,
) TransactionEncodingError!usize {
    if (len_of_len == 0) return error.InvalidLength;
    const start = index.*;
    const end = try checkedEnd(input, start, len_of_len);
    if (input[start] == 0) return error.LeadingZeros;

    var len: usize = 0;
    for (input[start..end]) |byte| {
        len = std.math.mul(usize, len, 256) catch return error.InputTooLong;
        len = std.math.add(usize, len, byte) catch return error.InputTooLong;
    }
    index.* = end;
    return len;
}

fn rlpStringToU64(bytes: []const u8) TransactionEncodingError!u64 {
    if (bytes.len > 8) return error.InvalidLength;
    const value = try rlpStringToU256(bytes);
    return std.math.cast(u64, value) orelse error.InvalidLength;
}

fn rlpStringToU8(bytes: []const u8) TransactionEncodingError!u8 {
    const value = try rlpStringToU64(bytes);
    return std.math.cast(u8, value) orelse error.InvalidLength;
}

fn rlpStringToU256(bytes: []const u8) TransactionEncodingError!u256 {
    if (bytes.len > 32) return error.InvalidLength;
    if (bytes.len == 1 and bytes[0] == 0) return error.NonCanonicalInteger;
    if (bytes.len > 1 and bytes[0] == 0) return error.NonCanonicalInteger;
    var out: u256 = 0;
    for (bytes) |byte| {
        out = (out << 8) | byte;
    }
    return out;
}

fn rlpStringToFixed32(bytes: []const u8) TransactionEncodingError![32]u8 {
    if (bytes.len > 32) return error.InvalidLength;
    if (bytes.len == 1 and bytes[0] == 0) return error.NonCanonicalInteger;
    if (bytes.len > 1 and bytes[0] == 0) return error.NonCanonicalInteger;
    var out: [32]u8 = [_]u8{0} ** 32;
    @memcpy(out[32 - bytes.len ..], bytes);
    return out;
}

fn rlpStringToRawFixed32(bytes: []const u8) TransactionEncodingError![32]u8 {
    if (bytes.len != 32) return error.InvalidLength;
    return bytes[0..32].*;
}

fn rlpStringToOptionalAddress(bytes: []const u8) TransactionEncodingError!?primitives.Address {
    if (bytes.len == 0) return null;
    return try rlpStringToAddress(bytes);
}

fn rlpStringToAddress(bytes: []const u8) TransactionEncodingError!primitives.Address {
    if (bytes.len != 20) return error.InvalidLength;
    return .{ .bytes = bytes[0..20].* };
}

fn encodeRlpListFromEncodedFields(
    allocator: std.mem.Allocator,
    fields: []const []const u8,
) ![]u8 {
    var total_len: usize = 0;
    for (fields) |field| {
        total_len = std.math.add(usize, total_len, field.len) catch return error.RlpPayloadTooLarge;
    }

    var result = std.ArrayList(u8){};
    defer result.deinit(allocator);

    if (total_len < 56) {
        try result.append(allocator, 0xc0 + @as(u8, @intCast(total_len)));
    } else {
        const len_bytes = try primitives.Rlp.encodeLength(allocator, total_len);
        defer allocator.free(len_bytes);
        try result.append(allocator, 0xf7 + @as(u8, @intCast(len_bytes.len)));
        try result.appendSlice(allocator, len_bytes);
    }

    for (fields) |field| {
        try result.appendSlice(allocator, field);
    }

    return try result.toOwnedSlice(allocator);
}

fn freeEncodedFields(allocator: std.mem.Allocator, fields: *std.ArrayList([]u8)) void {
    for (fields.items) |field| {
        allocator.free(field);
    }
    fields.deinit(allocator);
}

test "legacy envelope encodes signature scalars canonically" {
    const data = [_]u8{ 0xaa, 0xbb };
    var r = [_]u8{0} ** 32;
    var s = [_]u8{0} ** 32;
    r[31] = 0x01;
    s[31] = 0x80;

    const tx = primitives.Transaction.LegacyTransaction{
        .nonce = 1,
        .gas_price = 2,
        .gas_limit = 21_000,
        .to = primitives.Address{ .bytes = [_]u8{0x11} ** 20 },
        .value = 3,
        .data = &data,
        .v = 37,
        .r = r,
        .s = s,
    };

    const encoded = try encodeLegacyTransactionEnvelope(std.testing.allocator, tx);
    defer std.testing.allocator.free(encoded);

    const expected = [_]u8{
        0xe2, 0x01, 0x02, 0x82, 0x52, 0x08, 0x94,
        0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11,
        0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11,
        0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x03,
        0x82, 0xaa, 0xbb, 0x25, 0x01, 0x81, 0x80,
    };
    try std.testing.expectEqualSlices(u8, &expected, encoded);
}

test "legacy envelope decodes pre-eip155 and eip155 chain ids" {
    var r = [_]u8{0} ** 32;
    var s = [_]u8{0} ** 32;
    r[31] = 1;
    s[31] = 1;

    var tx = primitives.Transaction.LegacyTransaction{
        .nonce = 0,
        .gas_price = 1,
        .gas_limit = 21_000,
        .to = null,
        .value = 0,
        .data = &.{},
        .v = 27,
        .r = r,
        .s = s,
    };

    const pre_eip155_raw = try encodeLegacyTransactionEnvelope(std.testing.allocator, tx);
    defer std.testing.allocator.free(pre_eip155_raw);
    const pre_eip155 = try decodeLegacyEnvelope(pre_eip155_raw);
    try std.testing.expectEqual(@as(?u64, null), legacyChainId(pre_eip155));

    tx.v = 37;
    const eip155_raw = try encodeLegacyTransactionEnvelope(std.testing.allocator, tx);
    defer std.testing.allocator.free(eip155_raw);
    const eip155 = try decodeLegacyEnvelope(eip155_raw);
    try std.testing.expectEqual(@as(?u64, 1), legacyChainId(eip155));
}

test "legacy envelope rejects noncanonical rlp and invalid signature v" {
    try std.testing.expectError(error.LeadingZeros, decodeLegacyEnvelope(&[_]u8{ 0xf8, 0x00 }));

    const noncanonical_nonce = [_]u8{
        0xc9,
        0x00,
        0x01,
        0x01,
        0x80,
        0x80,
        0x80,
        0x1b,
        0x01,
        0x01,
    };
    try std.testing.expectError(error.NonCanonicalInteger, decodeLegacyEnvelope(&noncanonical_nonce));

    var r = [_]u8{0} ** 32;
    var s = [_]u8{0} ** 32;
    r[31] = 1;
    s[31] = 1;
    const invalid_v = try encodeLegacyTransactionEnvelope(std.testing.allocator, .{
        .nonce = 0,
        .gas_price = 1,
        .gas_limit = 21_000,
        .to = null,
        .value = 0,
        .data = &.{},
        .v = 29,
        .r = r,
        .s = s,
    });
    defer std.testing.allocator.free(invalid_v);
    try std.testing.expectError(error.InvalidSignatureV, decodeLegacyEnvelope(invalid_v));
}
