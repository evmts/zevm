const std = @import("std");
const primitives = @import("primitives");
const crypto = @import("crypto");

pub const CELLS_PER_EXT_BLOB: usize = 128;
pub const MAX_BLOBS_PER_TRANSACTION: usize = 6;
pub const BYTES_PER_COMMITMENT: usize = 48;
pub const BYTES_PER_PROOF: usize = 48;

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
    UnsupportedBlobWrapperVersion,
    RlpPayloadTooLarge,
    OutOfMemory,
};

pub const BlobWrapperVersion = enum(u8) {
    v0 = 0,
    v1 = 1,

    pub fn proofsPerBlob(self: BlobWrapperVersion) usize {
        return switch (self) {
            .v0 => 1,
            .v1 => CELLS_PER_EXT_BLOB,
        };
    }

    pub fn activeAt(self: BlobWrapperVersion, fork: primitives.Hardfork) bool {
        if (fork.isBefore(.CANCUN)) return false;
        return switch (self) {
            .v0 => fork.isBefore(.OSAKA),
            .v1 => fork.isAtLeast(.OSAKA),
        };
    }
};

pub const BlobSidecar = struct {
    blob: [primitives.Blob.BYTES_PER_BLOB]u8,
    commitment: [BYTES_PER_COMMITMENT]u8,
    proofs: union(enum) {
        blob: [BYTES_PER_PROOF]u8,
        cells: [CELLS_PER_EXT_BLOB][BYTES_PER_PROOF]u8,
    },
};

/// Zero-copy validated view over a type-3 network wrapper (EIP-4844 v0 or
/// EIP-7594 PeerDAS v1). Slices borrow the input buffer; all structural checks
/// run before any allocation.
pub const BlobNetworkWrapper = struct {
    version: BlobWrapperVersion,
    /// RLP-encoded `[tx_payload]` bytes (without the leading `0x03` type byte).
    tx_payload: []const u8,
    blob_count: usize,
    blobs: []const u8,
    commitments: []const u8,
    proofs: []const u8,

    pub fn canonicalEnvelope(self: BlobNetworkWrapper, allocator: std.mem.Allocator) TransactionEncodingError!CanonicalEnvelope {
        const canonical = try allocator.alloc(u8, self.tx_payload.len + 1);
        canonical[0] = 0x03;
        @memcpy(canonical[1..], self.tx_payload);
        return .{ .bytes = canonical, .owned = canonical };
    }

    pub fn sidecars(self: BlobNetworkWrapper, allocator: std.mem.Allocator) TransactionEncodingError![]BlobSidecar {
        const result = try allocator.alloc(BlobSidecar, self.blob_count);
        errdefer allocator.free(result);
        var bi: usize = 0;
        var ci: usize = 0;
        var pi: usize = 0;
        for (result) |*sidecar| {
            @memcpy(&sidecar.blob, try nextFixedBytes(primitives.Blob.BYTES_PER_BLOB, self.blobs, &bi));
            sidecar.commitment = (try nextFixedBytes(BYTES_PER_COMMITMENT, self.commitments, &ci)).*;
            switch (self.version) {
                .v0 => sidecar.proofs = .{ .blob = (try nextFixedBytes(BYTES_PER_PROOF, self.proofs, &pi)).* },
                .v1 => {
                    sidecar.proofs = .{ .cells = undefined };
                    for (&sidecar.proofs.cells) |*proof| {
                        proof.* = (try nextFixedBytes(BYTES_PER_PROOF, self.proofs, &pi)).*;
                    }
                },
            }
        }
        return result;
    }
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
    const wrapper = try decodeBlobNetworkWrapper(raw) orelse return .{ .bytes = raw };
    return wrapper.canonicalEnvelope(allocator);
}

/// Decodes and structurally validates a type-3 network wrapper (EIP-4844 v0 or
/// EIP-7594 PeerDAS v1). Returns `null` for a bare canonical type-3 envelope.
pub fn decodeBlobNetworkWrapper(raw: []const u8) TransactionEncodingError!?BlobNetworkWrapper {
    if (raw.len == 0 or raw[0] != 0x03) return null;
    const payload = try decodeTypedPayload(raw, 0x03);
    var index: usize = 0;
    switch (try parseRlpItem(payload, &index)) {
        .string => return null,
        .list => {},
    }
    const tx_payload = payload[0..index];

    var items: [4]RlpItem = undefined;
    var item_count: usize = 0;
    while (index < payload.len) : (item_count += 1) {
        if (item_count == items.len) return error.InvalidLength;
        items[item_count] = try parseRlpItem(payload, &index);
    }

    const version: BlobWrapperVersion, const sections: []const RlpItem = switch (item_count) {
        3 => .{ .v0, items[0..3] },
        4 => blk: {
            const version_bytes = try rlpItemString(items[0]);
            if (version_bytes.len != 1 or version_bytes[0] != @intFromEnum(BlobWrapperVersion.v1)) {
                return error.UnsupportedBlobWrapperVersion;
            }
            break :blk .{ .v1, items[1..4] };
        },
        else => return error.InvalidLength,
    };

    const blobs = try rlpItemList(sections[0]);
    const commitments = try rlpItemList(sections[1]);
    const proofs = try rlpItemList(sections[2]);

    const blob_count = try rlpFixedStringListCount(blobs, primitives.Blob.BYTES_PER_BLOB);
    const commitment_count = try rlpFixedStringListCount(commitments, BYTES_PER_COMMITMENT);
    const proof_count = try rlpFixedStringListCount(proofs, BYTES_PER_PROOF);
    if (blob_count == 0 or commitment_count != blob_count) return error.InvalidLength;
    const expected_proofs = std.math.mul(usize, blob_count, version.proofsPerBlob()) catch return error.InvalidLength;
    if (proof_count != expected_proofs) return error.InvalidLength;

    return .{
        .version = version,
        .tx_payload = tx_payload,
        .blob_count = blob_count,
        .blobs = blobs,
        .commitments = commitments,
        .proofs = proofs,
    };
}

/// Checks that the wrapper carries one commitment per versioned hash and that
/// every commitment hashes to the transaction's corresponding versioned hash.
pub fn validateWrapperCommitments(
    wrapper: BlobNetworkWrapper,
    expected_hashes: []const primitives.Blob.VersionedHash,
) TransactionEncodingError!void {
    if (wrapper.blob_count != expected_hashes.len) return error.InvalidLength;
    var commitment_index: usize = 0;
    for (expected_hashes) |expected| {
        const commitment = try nextFixedBytes(BYTES_PER_COMMITMENT, wrapper.commitments, &commitment_index);
        const versioned_hash = primitives.Blob.commitmentToVersionedHash(commitment.*);
        if (!std.mem.eql(u8, &versioned_hash.bytes, &expected.bytes)) return error.InvalidLength;
    }
}

/// Rejects network-wrapped blob transactions in canonical block bodies and
/// Engine execution payloads.
pub fn requireCanonicalEnvelope(raw: []const u8) TransactionEncodingError!void {
    if (raw.len == 0 or raw[0] != 0x03) return;
    const payload = try decodeTypedPayload(raw, 0x03);
    var index: usize = 0;
    if ((try parseRlpItem(payload, &index)) == .list) return error.UnexpectedInput;
}

/// Encodes a signed canonical type-3 envelope with the supplied sidecars into
/// either a v0 (EIP-4844) or v1 (EIP-7594) network wrapper.
pub fn encodeBlobNetworkEnvelope(
    allocator: std.mem.Allocator,
    canonical: []const u8,
    sidecars: []const BlobSidecar,
) TransactionEncodingError![]u8 {
    try requireCanonicalEnvelope(canonical);
    const fields = try decodeTypedPayloadFields(14, canonical, 0x03);
    const hashes = try rlpItemList(fields[10]);
    if (sidecars.len == 0) return error.InvalidLength;
    const is_v1 = sidecars[0].proofs == .cells;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temp = arena.allocator();

    const blobs = try temp.alloc([]const u8, sidecars.len);
    const commitments = try temp.alloc([]const u8, sidecars.len);
    var proofs = std.ArrayList([]const u8){};
    var hash_index: usize = 0;
    for (sidecars, blobs, commitments) |*sidecar, *blob_encoded, *commitment_encoded| {
        if ((sidecar.proofs == .cells) != is_v1) return error.UnexpectedInput;
        const expected = try nextFixedBytes(32, hashes, &hash_index);
        const calculated = primitives.Blob.commitmentToVersionedHash(sidecar.commitment);
        if (!std.mem.eql(u8, expected, &calculated.bytes)) return error.InvalidLength;
        blob_encoded.* = primitives.Rlp.encodeBytes(temp, &sidecar.blob) catch return error.OutOfMemory;
        commitment_encoded.* = primitives.Rlp.encodeBytes(temp, &sidecar.commitment) catch return error.OutOfMemory;
        switch (sidecar.proofs) {
            .blob => |*proof| try proofs.append(temp, primitives.Rlp.encodeBytes(temp, proof) catch return error.OutOfMemory),
            .cells => |*cell_proofs| for (cell_proofs) |*proof| {
                try proofs.append(temp, primitives.Rlp.encodeBytes(temp, proof) catch return error.OutOfMemory);
            },
        }
    }
    if (hash_index != hashes.len) return error.InvalidLength;

    const blob_list = try encodeRlpListFromEncodedFields(temp, blobs);
    const commitment_list = try encodeRlpListFromEncodedFields(temp, commitments);
    const proof_list = try encodeRlpListFromEncodedFields(temp, proofs.items);
    const wrapper_payload = if (is_v1)
        try encodeRlpListFromEncodedFields(temp, &.{ canonical[1..], &.{@intFromEnum(BlobWrapperVersion.v1)}, blob_list, commitment_list, proof_list })
    else
        try encodeRlpListFromEncodedFields(temp, &.{ canonical[1..], blob_list, commitment_list, proof_list });

    const out = try allocator.alloc(u8, wrapper_payload.len + 1);
    out[0] = 0x03;
    @memcpy(out[1..], wrapper_payload);
    return out;
}

/// Compatibility reader returning EIP-4844 single-proof sidecars for v0 network
/// wrappers. Returns `null` for bare envelopes and for v1 PeerDAS wrappers
/// (which carry 128 cell proofs per blob; use `BlobNetworkWrapper.sidecars`).
pub fn eip4844BlobSidecars(
    allocator: std.mem.Allocator,
    raw: []const u8,
    expected_hashes: []const primitives.Blob.VersionedHash,
) TransactionEncodingError!?[]const primitives.Blob.BlobSidecar {
    if (raw.len == 0 or raw[0] != 0x03) return null;
    const wrapper = try decodeBlobNetworkWrapper(raw) orelse return null;
    try validateWrapperCommitments(wrapper, expected_hashes);
    if (wrapper.version != .v0) return null;

    const sidecars = try allocator.alloc(primitives.Blob.BlobSidecar, wrapper.blob_count);
    errdefer allocator.free(sidecars);

    var blob_index: usize = 0;
    var commitment_index: usize = 0;
    var proof_index: usize = 0;
    for (sidecars) |*sidecar| {
        @memcpy(sidecar.blob[0..], try nextFixedBytes(primitives.Blob.BYTES_PER_BLOB, wrapper.blobs, &blob_index));
        sidecar.commitment = (try nextFixedBytes(BYTES_PER_COMMITMENT, wrapper.commitments, &commitment_index)).*;
        sidecar.proof = (try nextFixedBytes(BYTES_PER_PROOF, wrapper.proofs, &proof_index)).*;
    }
    return sidecars;
}

fn rlpFixedStringListCount(list_payload: []const u8, item_len: usize) TransactionEncodingError!usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < list_payload.len) : (count += 1) {
        const item = try rlpItemString(try parseRlpItem(list_payload, &index));
        if (item.len != item_len) return error.InvalidLength;
    }
    return count;
}

fn nextFixedBytes(comptime size: usize, payload: []const u8, index: *usize) TransactionEncodingError!*const [size]u8 {
    const bytes = try rlpItemString(try parseRlpItem(payload, index));
    if (bytes.len != size) return error.InvalidLength;
    return bytes[0..size];
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

pub fn envelopeBlobVersionedHashes(decoded: DecodedEnvelope) ?[]const primitives.Blob.VersionedHash {
    return switch (decoded) {
        .eip4844 => |tx| tx.blob_versioned_hashes,
        else => null,
    };
}

pub fn envelopeBlobVersionedHashBytes(
    allocator: std.mem.Allocator,
    decoded: DecodedEnvelope,
) !?[]const [32]u8 {
    const hashes = envelopeBlobVersionedHashes(decoded) orelse return null;
    const out = try allocator.alloc([32]u8, hashes.len);
    for (hashes, 0..) |hash, index| {
        out[index] = hash.bytes;
    }
    return out;
}

pub fn envelopeAuthorizationList(decoded: DecodedEnvelope) []const primitives.Authorization.Authorization {
    return switch (decoded) {
        .eip7702 => |tx| tx.authorization_list,
        else => &.{},
    };
}

fn rlpLenOfLen(len: usize) usize {
    var tmp = len;
    var n: usize = 0;
    while (tmp > 0) : (tmp >>= 8) n += 1;
    return n;
}

fn rlpHeaderLen(payload_len: usize) usize {
    return if (payload_len < 56) 1 else 1 + rlpLenOfLen(payload_len);
}

fn rlpBytesLen(bytes: []const u8) usize {
    if (bytes.len == 1 and bytes[0] < 0x80) return 1;
    return rlpHeaderLen(bytes.len) + bytes.len;
}

fn uintByteLen(comptime T: type, value: T) usize {
    if (value == 0) return 0;
    const bits = @bitSizeOf(T) - @clz(value);
    return (bits + 7) / 8;
}

fn rlpUintLen(comptime T: type, value: T) usize {
    if (value == 0) return 1;
    if (value < 0x80) return 1;
    return 1 + uintByteLen(T, value);
}

fn writeRlpHeader(out: []u8, offset: *usize, base: u8, payload_len: usize) void {
    if (payload_len < 56) {
        out[offset.*] = base + @as(u8, @intCast(payload_len));
        offset.* += 1;
    } else {
        const len_bytes = rlpLenOfLen(payload_len);
        out[offset.*] = (base + 55) + @as(u8, @intCast(len_bytes));
        offset.* += 1;
        var shift = (len_bytes - 1) * 8;
        for (0..len_bytes) |_| {
            out[offset.*] = @as(u8, @intCast((payload_len >> @intCast(shift)) & 0xff));
            offset.* += 1;
            if (shift >= 8) shift -= 8;
        }
    }
}

fn writeRlpBytes(out: []u8, offset: *usize, bytes: []const u8) void {
    if (bytes.len == 1 and bytes[0] < 0x80) {
        out[offset.*] = bytes[0];
        offset.* += 1;
        return;
    }
    writeRlpHeader(out, offset, 0x80, bytes.len);
    @memcpy(out[offset.* .. offset.* + bytes.len], bytes);
    offset.* += bytes.len;
}

fn writeRlpUint(comptime T: type, out: []u8, offset: *usize, value: T) void {
    if (value == 0) {
        out[offset.*] = 0x80;
        offset.* += 1;
        return;
    }
    if (value < 0x80) {
        out[offset.*] = @intCast(value);
        offset.* += 1;
        return;
    }
    const byte_len = uintByteLen(T, value);
    out[offset.*] = 0x80 + @as(u8, @intCast(byte_len));
    offset.* += 1;
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, value, .big);
    @memcpy(out[offset.* .. offset.* + byte_len], buf[@sizeOf(T) - byte_len ..]);
    offset.* += byte_len;
}

pub fn encodeLegacyTransactionEnvelope(
    allocator: std.mem.Allocator,
    tx: primitives.Transaction.LegacyTransaction,
) ![]u8 {
    const to_slice: []const u8 = if (tx.to) |*to| &to.bytes else &.{};
    const r_u256 = bytes32ToU256(tx.r);
    const s_u256 = bytes32ToU256(tx.s);

    const payload_len =
        rlpUintLen(u64, tx.nonce) +
        rlpUintLen(u256, tx.gas_price) +
        rlpUintLen(u64, tx.gas_limit) +
        rlpBytesLen(to_slice) +
        rlpUintLen(u256, tx.value) +
        rlpBytesLen(tx.data) +
        rlpUintLen(u64, tx.v) +
        rlpUintLen(u256, r_u256) +
        rlpUintLen(u256, s_u256);

    const total_len = rlpHeaderLen(payload_len) + payload_len;
    const out = try allocator.alloc(u8, total_len);
    var offset: usize = 0;

    writeRlpHeader(out, &offset, 0xc0, payload_len);
    writeRlpUint(u64, out, &offset, tx.nonce);
    writeRlpUint(u256, out, &offset, tx.gas_price);
    writeRlpUint(u64, out, &offset, tx.gas_limit);
    writeRlpBytes(out, &offset, to_slice);
    writeRlpUint(u256, out, &offset, tx.value);
    writeRlpBytes(out, &offset, tx.data);
    writeRlpUint(u64, out, &offset, tx.v);
    writeRlpUint(u256, out, &offset, r_u256);
    writeRlpUint(u256, out, &offset, s_u256);

    std.debug.assert(offset == total_len);
    return out;
}

pub fn encodeLegacySigningPreimage(
    allocator: std.mem.Allocator,
    tx: primitives.Transaction.LegacyTransaction,
    chain_id: ?u64,
) ![]u8 {
    const to_slice: []const u8 = if (tx.to) |*to| &to.bytes else &.{};

    var payload_len =
        rlpUintLen(u64, tx.nonce) +
        rlpUintLen(u256, tx.gas_price) +
        rlpUintLen(u64, tx.gas_limit) +
        rlpBytesLen(to_slice) +
        rlpUintLen(u256, tx.value) +
        rlpBytesLen(tx.data);
    if (chain_id) |id| {
        payload_len += rlpUintLen(u64, id) + 1 + 1; // id, 0, 0
    }

    const total_len = rlpHeaderLen(payload_len) + payload_len;
    const out = try allocator.alloc(u8, total_len);
    var offset: usize = 0;

    writeRlpHeader(out, &offset, 0xc0, payload_len);
    writeRlpUint(u64, out, &offset, tx.nonce);
    writeRlpUint(u256, out, &offset, tx.gas_price);
    writeRlpUint(u64, out, &offset, tx.gas_limit);
    writeRlpBytes(out, &offset, to_slice);
    writeRlpUint(u256, out, &offset, tx.value);
    writeRlpBytes(out, &offset, tx.data);
    if (chain_id) |id| {
        writeRlpUint(u64, out, &offset, id);
        out[offset] = 0x80;
        offset += 1;
        out[offset] = 0x80;
        offset += 1;
    }

    std.debug.assert(offset == total_len);
    return out;
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
    const wrapper = try decodeBlobNetworkWrapper(raw);
    const fields = if (wrapper) |w| blk: {
        var idx: usize = 0;
        const tx_item = try parseRlpItem(w.tx_payload, &idx);
        break :blk try decodeRlpPayloadFields(14, try rlpItemList(tx_item));
    } else try decodeTypedPayloadFields(14, raw, 0x03);
    const access_list = try rlpItemToTransactionAccessList(allocator, fields[8]);
    errdefer freeTransactionAccessList(allocator, access_list);
    const blob_hashes = try rlpItemToBlobVersionedHashes(allocator, fields[10]);
    errdefer allocator.free(blob_hashes);
    if (wrapper) |w| try validateWrapperCommitments(w, blob_hashes);
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
        .to = try rlpStringToAddress(try rlpItemString(fields[5])),
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
    return recoverLegacySenderWithRule(allocator, tx, false);
}

fn recoverLegacySenderWithRule(
    allocator: std.mem.Allocator,
    tx: primitives.Transaction.LegacyTransaction,
    allow_high_s: bool,
) !primitives.Address {
    const signing_hash = try legacySigningHash(allocator, tx);
    const order = crypto.Crypto.SECP256K1_N;
    var s = bytes32ToU256(tx.s);
    var recovery_id = legacyRecoveryId(tx.v);
    // Frontier permits high-s signatures. The recovery primitive requires
    // low-s, so use the equivalent signature with the opposite parity.
    if (allow_high_s and s > order / 2 and s < order) {
        s = order - s;
        recovery_id ^= 1;
    }
    return crypto.Crypto.unaudited_recoverAddress(signing_hash, .{
        .r = bytes32ToU256(tx.r),
        .s = s,
        .v = recovery_id + 27,
    });
}

pub fn recoverEnvelopeSender(
    allocator: std.mem.Allocator,
    decoded: DecodedEnvelope,
) !primitives.Address {
    return recoverEnvelopeSenderForFork(allocator, decoded, .HOMESTEAD);
}

pub fn recoverEnvelopeSenderForFork(
    allocator: std.mem.Allocator,
    decoded: DecodedEnvelope,
    fork: primitives.Hardfork,
) !primitives.Address {
    return switch (decoded) {
        .legacy => |tx| recoverLegacySenderWithRule(allocator, tx, fork.isBefore(.HOMESTEAD)),
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
        const y_parity = try rlpStringToU8(try rlpItemString(fields[3]));
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

test "eip4844 blob sidecars decode from network wrapper" {
    const allocator = std.testing.allocator;

    const blob = try allocator.alloc(u8, primitives.Blob.BYTES_PER_BLOB);
    defer allocator.free(blob);
    @memset(blob, 0xab);
    const commitment = [_]u8{0x11} ** 48;
    const proof = [_]u8{0x22} ** 48;
    const versioned_hash = primitives.Blob.commitmentToVersionedHash(commitment);
    const versioned_hashes = [_]primitives.Blob.VersionedHash{versioned_hash};

    const tx = primitives.Transaction.Eip4844Transaction{
        .chain_id = 1,
        .nonce = 0,
        .max_priority_fee_per_gas = 1,
        .max_fee_per_gas = 2,
        .gas_limit = 21_000,
        .to = primitives.Address{ .bytes = [_]u8{0x33} ** 20 },
        .value = 0,
        .data = &.{},
        .access_list = &.{},
        .max_fee_per_blob_gas = 3,
        .blob_versioned_hashes = &versioned_hashes,
        .y_parity = 1,
        .r = [_]u8{0x44} ** 32,
        .s = [_]u8{0x55} ** 32,
    };
    const canonical = try primitives.Transaction.encodeEip4844ForSigning(allocator, tx);
    defer allocator.free(canonical);

    const encoded_blob = try primitives.Rlp.encodeBytes(allocator, blob);
    defer allocator.free(encoded_blob);
    const encoded_commitment = try primitives.Rlp.encodeBytes(allocator, &commitment);
    defer allocator.free(encoded_commitment);
    const encoded_proof = try primitives.Rlp.encodeBytes(allocator, &proof);
    defer allocator.free(encoded_proof);

    const blob_fields = [_][]const u8{encoded_blob};
    const commitment_fields = [_][]const u8{encoded_commitment};
    const proof_fields = [_][]const u8{encoded_proof};
    const blobs = try encodeRlpListFromEncodedFields(allocator, &blob_fields);
    defer allocator.free(blobs);
    const commitments = try encodeRlpListFromEncodedFields(allocator, &commitment_fields);
    defer allocator.free(commitments);
    const proofs = try encodeRlpListFromEncodedFields(allocator, &proof_fields);
    defer allocator.free(proofs);

    const wrapper_fields = [_][]const u8{ canonical[1..], blobs, commitments, proofs };
    const wrapper_payload = try encodeRlpListFromEncodedFields(allocator, &wrapper_fields);
    defer allocator.free(wrapper_payload);
    const raw = try allocator.alloc(u8, wrapper_payload.len + 1);
    defer allocator.free(raw);
    raw[0] = 0x03;
    @memcpy(raw[1..], wrapper_payload);

    const canonical_from_wrapper = try canonicalTransactionEnvelope(allocator, raw);
    defer canonical_from_wrapper.deinit(allocator);
    try std.testing.expectEqualSlices(u8, canonical, canonical_from_wrapper.bytes);

    const wrapper = (try decodeBlobNetworkWrapper(raw)).?;
    try std.testing.expectEqual(BlobWrapperVersion.v0, wrapper.version);
    try std.testing.expect(wrapper.version.activeAt(.PRAGUE));
    try std.testing.expect(!wrapper.version.activeAt(.OSAKA));
    const tagged_sidecars = try wrapper.sidecars(allocator);
    defer allocator.free(tagged_sidecars);
    try std.testing.expectEqual(@as(usize, 1), tagged_sidecars.len);
    try std.testing.expectEqualSlices(u8, blob, tagged_sidecars[0].blob[0..]);
    try std.testing.expectEqualSlices(u8, &commitment, tagged_sidecars[0].commitment[0..]);
    try std.testing.expectEqualSlices(u8, &proof, &tagged_sidecars[0].proofs.blob);
    const reencoded_v0 = try encodeBlobNetworkEnvelope(allocator, canonical, tagged_sidecars);
    defer allocator.free(reencoded_v0);
    try std.testing.expectEqualSlices(u8, raw, reencoded_v0);

    try requireCanonicalEnvelope(canonical);
    try std.testing.expectError(error.UnexpectedInput, requireCanonicalEnvelope(raw));

    const sidecars = (try eip4844BlobSidecars(allocator, raw, &versioned_hashes)).?;
    defer allocator.free(sidecars);
    try std.testing.expectEqual(@as(usize, 1), sidecars.len);
    try std.testing.expectEqualSlices(u8, blob, sidecars[0].blob[0..]);
    try std.testing.expectEqualSlices(u8, &commitment, sidecars[0].commitment[0..]);
    try std.testing.expectEqualSlices(u8, &proof, sidecars[0].proof[0..]);

    // EIP-7594 PeerDAS v1 network wrapper: 5-item list with version=1 and 128 cell proofs/blob.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temp = arena.allocator();
    var cell_fields = [_][]const u8{encoded_proof} ** CELLS_PER_EXT_BLOB;
    const last_proof = [_]u8{0x88} ** 48;
    cell_fields[127] = try primitives.Rlp.encodeBytes(temp, &last_proof);
    const cells = try encodeRlpListFromEncodedFields(temp, &cell_fields);
    const v1_payload = try encodeRlpListFromEncodedFields(temp, &.{ canonical[1..], &.{1}, blobs, commitments, cells });
    const v1_raw = try std.mem.concat(temp, u8, &.{ &.{0x03}, v1_payload });

    const v1_view = (try decodeBlobNetworkWrapper(v1_raw)).?;
    try std.testing.expectEqual(BlobWrapperVersion.v1, v1_view.version);
    try std.testing.expect(v1_view.version.activeAt(.OSAKA));
    try std.testing.expect(!v1_view.version.activeAt(.PRAGUE));
    try std.testing.expectEqual(@as(?[]const primitives.Blob.BlobSidecar, null), try eip4844BlobSidecars(allocator, v1_raw, &versioned_hashes));
    const v1_sidecars = try v1_view.sidecars(allocator);
    defer allocator.free(v1_sidecars);
    try std.testing.expectEqual(@as(usize, 1), v1_sidecars.len);
    try std.testing.expectEqualSlices(u8, &last_proof, &v1_sidecars[0].proofs.cells[127]);
    const reencoded_v1 = try encodeBlobNetworkEnvelope(allocator, canonical, v1_sidecars);
    defer allocator.free(reencoded_v1);
    try std.testing.expectEqualSlices(u8, v1_raw, reencoded_v1);
    try std.testing.expectError(error.UnexpectedInput, requireCanonicalEnvelope(v1_raw));

    const bare = try canonicalTransactionEnvelope(allocator, v1_raw);
    defer bare.deinit(allocator);
    try std.testing.expectEqualSlices(u8, canonical, bare.bytes);
    try std.testing.expectEqual(transactionHash(canonical), transactionHash(bare.bytes));
    const v1_tx = try decodeEnvelope(allocator, v1_raw);
    defer v1_tx.deinit(allocator);
    try std.testing.expectEqual(tx.nonce, v1_tx.eip4844.nonce);

    // Unsupported version encodings must fail with UnsupportedBlobWrapperVersion (or NonCanonicalSize).
    const bad_versions = [_][]const u8{ &.{0x80}, &.{0x02}, &.{ 0x82, 0x01, 0x01 } };
    for (bad_versions) |bad_ver| {
        const bad_payload = try encodeRlpListFromEncodedFields(temp, &.{ canonical[1..], bad_ver, blobs, commitments, cells });
        const bad_raw = try std.mem.concat(temp, u8, &.{ &.{0x03}, bad_payload });
        try std.testing.expectError(error.UnsupportedBlobWrapperVersion, decodeBlobNetworkWrapper(bad_raw));
    }

    // Malformed wrappers across counts, widths, commitment hash mismatch, and list types.
    const short_cells = try encodeRlpListFromEncodedFields(temp, cell_fields[0..127]);
    const extra_cells = try encodeRlpListFromEncodedFields(temp, &(cell_fields ++ .{encoded_proof}));
    const empty_list: []const u8 = &.{0xc0};
    const wrong_commitment = try encodeRlpListFromEncodedFields(temp, &.{encoded_proof});
    const malformed_cases = [_][]const []const u8{
        &.{ canonical[1..], &.{ 0x81, 1 }, blobs, commitments, cells },
        &.{ canonical[1..], &.{1}, blobs, commitments, short_cells },
        &.{ canonical[1..], &.{1}, blobs, commitments, extra_cells },
        &.{ canonical[1..], &.{1}, commitments, commitments, cells },
        &.{ canonical[1..], &.{1}, empty_list, empty_list, empty_list },
        &.{ canonical[1..], blobs, empty_list, proofs },
        &.{ canonical[1..], blobs, wrong_commitment, proofs },
        &.{ canonical[1..], blobs, commitments, blobs },
        &.{ canonical[1..], blobs, blobs, proofs },
        &.{ canonical[1..], blobs, commitments, cells },
        &.{ canonical[1..], empty_list, commitments, proofs },
        &.{ canonical[1..], blobs, commitments, proofs, empty_list },
        &.{ canonical[1..], &.{1}, blobs, commitments, cells, empty_list },
    };
    for (malformed_cases) |fields| {
        const invalid_payload = try encodeRlpListFromEncodedFields(temp, fields);
        const invalid = try std.mem.concat(temp, u8, &.{ &.{0x03}, invalid_payload });
        if (decodeEnvelope(temp, invalid)) |_| return error.ExpectedMalformedWrapper else |_| {}
    }
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
