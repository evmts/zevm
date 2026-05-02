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
    RlpPayloadTooLarge,
};

const RlpItem = union(enum) {
    string: []const u8,
    list: []const u8,
};

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
    if (!legacyVIsValid(v)) return error.InvalidSignatureV;

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

fn rlpStringToOptionalAddress(bytes: []const u8) TransactionEncodingError!?primitives.Address {
    if (bytes.len == 0) return null;
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
