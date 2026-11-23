const std = @import("std");
const builtin = @import("builtin");
const primitives = @import("primitives");
const crypto = @import("crypto");
const encoding = @import("../transaction_encoding.zig");

const Format = enum { pre155, eip155, eip2930, eip1559, eip4844, eip7702 };
const formats = std.enums.values(Format);
/// Unoptimized secp256k1 makes the full count take ~7 minutes in Debug, so the
/// default `zig build test` graph runs a reduced count that still covers every
/// format and all 32 signature byte widths. `zig build fuzz -Doptimize=ReleaseSafe`
/// (CI fuzz job) runs the full count.
const trials = if (builtin.mode == .Debug) 36 else 312;
/// Byte stride for the exhaustive wire-position mutation pass on the seeds.
const mutation_stride: usize = if (builtin.mode == .Debug) 7 else 1;
const zero_scalar = [_]u8{0} ** 32;

fn quantity(random: std.Random, comptime T: type) T {
    return switch (random.uintLessThan(u8, 8)) {
        0 => 0,
        1 => 1,
        2 => 0x7f,
        3 => 0x80,
        4 => std.math.maxInt(T),
        else => random.int(T),
    };
}

fn randomAddress(random: std.Random) primitives.Address {
    var result: primitives.Address = undefined;
    random.bytes(&result.bytes);
    return result;
}

// Full-width scalars exercise all fields without conflating round trips with
// the separate short-scalar regression cases below.
fn fullWidthScalar(random: std.Random) [32]u8 {
    var bytes: [32]u8 = undefined;
    random.bytes(&bytes);
    bytes[0] = random.intRangeAtMost(u8, 1, 0x7e);
    return bytes;
}

// Generated slices borrow this storage until the next call to make().
const Fixture = struct {
    calldata: [256]u8,
    entries: [3]primitives.Transaction.AccessListItem,
    keys: [3][3][32]u8,
    hashes: [encoding.MAX_BLOBS_PER_TRANSACTION]primitives.Blob.VersionedHash,
    authorizations: [3]primitives.Authorization.Authorization,

    fn make(self: *Fixture, random: std.Random, comptime format: Format) encoding.DecodedEnvelope {
        const tag = switch (format) {
            .pre155, .eip155 => "legacy",
            else => @tagName(format),
        };
        const T = @FieldType(encoding.DecodedEnvelope, tag);
        var tx: T = undefined;
        tx.nonce = quantity(random, u64);
        tx.value = quantity(random, u256);
        tx.gas_limit = quantity(random, u64);
        const lengths = [_]usize{ 0, 1, 55, 56, 127, 128, 255, 256 };
        const len = if (random.boolean()) lengths[random.uintLessThan(usize, lengths.len)] else random.uintAtMost(usize, self.calldata.len);
        random.bytes(self.calldata[0..len]);
        tx.data = self.calldata[0..len];
        if (format == .eip4844 or format == .eip7702) {
            tx.to = randomAddress(random);
        } else {
            tx.to = if (random.boolean()) randomAddress(random) else null;
        }
        tx.r = fullWidthScalar(random);
        tx.s = fullWidthScalar(random);
        if (@hasField(T, "gas_price")) {
            tx.gas_price = quantity(random, u256);
        } else {
            const a = quantity(random, u256);
            const b = quantity(random, u256);
            tx.max_fee_per_gas = @max(a, b);
            tx.max_priority_fee_per_gas = @min(a, b);
        }
        const parity: u8 = random.int(u1);
        if (format == .pre155 or format == .eip155) {
            // Leave room in v for the EIP-155 offset and parity.
            tx.v = if (format == .pre155) 27 + parity else 35 + 2 * @as(u64, random.int(u62)) + parity;
        } else {
            tx.y_parity = parity;
            tx.chain_id = quantity(random, u64);
            const entries = self.entries[0..random.uintAtMost(usize, self.entries.len)];
            for (entries, 0..) |*entry, i| {
                const keys = self.keys[i][0..random.uintAtMost(usize, self.keys[i].len)];
                for (keys) |*key| random.bytes(key);
                entry.* = .{ .address = randomAddress(random), .storage_keys = keys };
            }
            tx.access_list = entries;
        }
        if (format == .eip4844) {
            tx.max_fee_per_blob_gas = quantity(random, u256);
            const hashes = self.hashes[0..random.intRangeAtMost(usize, 1, self.hashes.len)];
            for (hashes) |*hash| {
                random.bytes(&hash.bytes);
                hash.bytes[0] = 1;
            }
            tx.blob_versioned_hashes = hashes;
        }
        if (format == .eip7702) {
            const auths = self.authorizations[0..random.intRangeAtMost(usize, 1, self.authorizations.len)];
            for (auths) |*auth| auth.* = .{
                .chain_id = if (random.boolean()) tx.chain_id else 0,
                .address = randomAddress(random),
                .nonce = quantity(random, u64),
                .v = random.int(u1),
                .r = fullWidthScalar(random),
                .s = fullWidthScalar(random),
            };
            tx.authorization_list = auths;
        }
        return @unionInit(encoding.DecodedEnvelope, tag, tx);
    }
};

fn encode(allocator: std.mem.Allocator, envelope: encoding.DecodedEnvelope) ![]u8 {
    return switch (envelope) {
        .legacy => |tx| encoding.encodeLegacyTransactionEnvelope(allocator, tx),
        .eip2930 => |tx| primitives.Transaction.encodeEip2930ForSigning(allocator, tx),
        .eip1559 => |tx| primitives.Transaction.encodeEip1559ForSigning(allocator, tx),
        .eip4844 => |tx| primitives.Transaction.encodeEip4844ForSigning(allocator, tx),
        .eip7702 => |tx| primitives.Transaction.encodeEip7702ForSigning(allocator, tx),
    };
}

fn encodeSigned(allocator: std.mem.Allocator, envelope: encoding.DecodedEnvelope) ![]u8 {
    const encoded = try encode(allocator, envelope);
    switch (envelope) {
        .legacy => return encoded,
        inline else => |tx| {
            if (tx.y_parity == 0 and std.mem.eql(u8, &tx.r, &zero_scalar) and std.mem.eql(u8, &tx.s, &zero_scalar)) {
                defer allocator.free(encoded);
                return listEnvelope(allocator, encoded[0..1], &.{ listPayload(encoded[1..]), "\x80\x80\x80" });
            }
            return encoded;
        },
    }
}

fn checkRoundTrip(sample: encoding.DecodedEnvelope) !void {
    const allocator = std.testing.allocator;
    const raw = try encode(allocator, sample);
    defer allocator.free(raw);
    const decoded = try encoding.decodeEnvelope(allocator, raw);
    defer decoded.deinit(allocator);
    try std.testing.expectEqualDeep(sample, decoded);
    const again = try encode(allocator, decoded);
    defer allocator.free(again);
    try std.testing.expectEqualSlices(u8, raw, again);
    try encoding.requireCanonicalEnvelope(raw);
}

test "property: all six signing formats preserve every field and canonical wire byte" {
    var prng = std.Random.DefaultPrng.init(0xdb4e_93c3_0447_8cb1);
    var fixture: Fixture = undefined;
    for (0..trials) |_| {
        inline for (formats) |format| try checkRoundTrip(fixture.make(prng.random(), format));
    }
}

test "property: canonical signature integers round trip at every significant byte width" {
    var prng = std.Random.DefaultPrng.init(0x52_4c_50_72_73);
    const random = prng.random();
    var fixture: Fixture = undefined;
    for (0..trials) |i| {
        inline for (formats) |format| {
            var sample = fixture.make(random, format);
            switch (sample) {
                inline else => |*tx| {
                    const scalar = if (random.boolean()) &tx.r else &tx.s;
                    const padding = i % scalar.len;
                    @memset(scalar[0..padding], 0);
                    scalar[padding] = random.intRangeAtMost(u8, 1, 127);
                },
            }
            try checkRoundTrip(sample);
        }
    }
}

// These two helpers operate only on well-formed fixture lists. listEnvelope
// accepts already encoded fields, so tests can also build deliberately
// non-minimal fields inside a correctly sized outer list.
fn listPayload(list: []const u8) []const u8 {
    const header_len: usize = if (list[0] <= 0xf7) 1 else @as(usize, list[0] - 0xf7) + 1;
    return list[header_len..];
}

fn listEnvelope(allocator: std.mem.Allocator, prefix: []const u8, fields: []const []const u8) ![]u8 {
    var size: usize = 0;
    for (fields) |field| size += field.len;
    var header: [1 + @sizeOf(usize)]u8 = undefined;
    const header_len: usize = if (size <= 55) blk: {
        header[0] = 0xc0 + @as(u8, @intCast(size));
        break :blk 1;
    } else blk: {
        var length: [@sizeOf(usize)]u8 = undefined;
        std.mem.writeInt(usize, &length, size, .big);
        const minimal = std.mem.trimStart(u8, &length, &.{0});
        header[0] = 0xf7 + @as(u8, @intCast(minimal.len));
        @memcpy(header[1..][0..minimal.len], minimal);
        break :blk 1 + minimal.len;
    };
    const result = try allocator.alloc(u8, prefix.len + header_len + size);
    @memcpy(result[0..prefix.len], prefix);
    @memcpy(result[prefix.len..][0..header_len], header[0..header_len]);
    var i = prefix.len + header_len;
    for (fields) |field| {
        @memcpy(result[i..][0..field.len], field);
        i += field.len;
    }
    return result;
}

fn validKey(random: std.Random) crypto.Crypto.PrivateKey {
    var key: crypto.Crypto.PrivateKey = undefined;
    while (true) {
        random.bytes(&key);
        const scalar = std.mem.readInt(u256, &key, .big);
        if (scalar != 0 and scalar < crypto.Crypto.SECP256K1_N) return key;
    }
}

fn signedBytes(allocator: std.mem.Allocator, sample: encoding.DecodedEnvelope, key: crypto.Crypto.PrivateKey) ![]u8 {
    if (sample == .legacy) {
        var tx = sample.legacy;
        if (encoding.legacyChainId(tx)) |id| {
            tx = try encoding.signLegacyTransaction(allocator, tx, key, id);
        } else {
            const preimage = try encoding.encodeLegacySigningPreimage(allocator, tx, null);
            defer allocator.free(preimage);
            const sig = try crypto.Crypto.unaudited_signHash(encoding.transactionHash(preimage), key);
            tx.v = sig.v;
            std.mem.writeInt(u256, &tx.r, sig.r, .big);
            std.mem.writeInt(u256, &tx.s, sig.s, .big);
        }
        return encoding.encodeLegacyTransactionEnvelope(allocator, tx);
    }
    var unsigned = sample;
    switch (unsigned) {
        .legacy => unreachable,
        inline else => |*tx| {
            tx.y_parity = 0;
            tx.r = zero_scalar;
            tx.s = zero_scalar;
        },
    }
    const preimage = try encode(allocator, unsigned);
    defer allocator.free(preimage);
    const sig = try crypto.Crypto.unaudited_signHash(encoding.transactionHash(preimage), key);
    // Serialize the actual signature as RLP integers even if r or s is short.
    const r = try primitives.Rlp.encode(allocator, sig.r);
    defer allocator.free(r);
    const s = try primitives.Rlp.encode(allocator, sig.s);
    defer allocator.free(s);
    const parity = [_]u8{if (sig.v == 27) 0x80 else 1};
    return listEnvelope(allocator, preimage[0..1], &.{ listPayload(preimage[1..]), &parity, r, s });
}

fn checkMutation(raw: []u8, position: usize, delta: u8, sender: primitives.Address) !void {
    const allocator = std.testing.allocator;
    raw[position] ^= delta;
    defer raw[position] ^= delta;
    const decoded = encoding.decodeEnvelope(allocator, raw) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    defer decoded.deinit(allocator);
    const recovered = encoding.recoverEnvelopeSender(allocator, decoded) catch |err| {
        if (err == error.OutOfMemory) return err;
        return;
    };
    try std.testing.expect(!std.mem.eql(u8, &sender.bytes, &recovered.bytes));
}

test "property: sender recovery binds signed payload and signature bytes to the private key" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xdd59_1550_2930_7702);
    const random = prng.random();
    var fixture: Fixture = undefined;
    for (0..trials) |i| {
        const key = validKey(random);
        const pubkey = try std.crypto.ecc.Secp256k1.basePoint.mul(key, .big);
        const uncompressed = pubkey.toUncompressedSec1();
        const digest = primitives.Hash.keccak256(uncompressed[1..]);
        const expected = primitives.Address{ .bytes = digest[12..32].* };
        const format = formats[i % formats.len];
        const sample = if (i < formats.len) try encoding.decodeEnvelope(allocator, wire_seeds[i]) else switch (format) {
            inline else => |f| fixture.make(random, f),
        };
        defer if (i < formats.len) sample.deinit(allocator);
        const raw = try signedBytes(allocator, sample, key);
        defer allocator.free(raw);
        const decoded = try encoding.decodeEnvelope(allocator, raw);
        defer decoded.deinit(allocator);
        try std.testing.expectEqual(expected, try encoding.recoverEnvelopeSender(allocator, decoded));

        if (i < formats.len) {
            // Cover every wire position once per format, including the type,
            // nested lists, RLP headers, parity, and both signature scalars.
            var pos: usize = 0;
            while (pos < raw.len) : (pos += mutation_stride) {
                try checkMutation(raw, pos, random.intRangeAtMost(u8, 1, 255), expected);
            }
        } else {
            // Exclude all three signature fields and the outer header when
            // choosing the payload position, even when r or s is short.
            const tx = encoding.envelopeToLegacyLikeTx(decoded);
            const v = try primitives.Rlp.encode(allocator, if (decoded == .legacy) tx.v else @as(u64, encoding.legacyRecoveryId(tx.v)));
            defer allocator.free(v);
            const r = try primitives.Rlp.encode(allocator, encoding.bytes32ToU256(tx.r));
            defer allocator.free(r);
            const s = try primitives.Rlp.encode(allocator, encoding.bytes32ToU256(tx.s));
            defer allocator.free(s);
            const sig_start = raw.len - v.len - r.len - s.len;
            const payload_start = raw.len - listPayload(raw[@intFromBool(decoded != .legacy)..]).len;
            try checkMutation(raw, random.intRangeLessThan(usize, payload_start, sig_start), random.intRangeAtMost(u8, 1, 255), expected);
            try checkMutation(raw, random.intRangeLessThan(usize, sig_start, raw.len), random.intRangeAtMost(u8, 1, 255), expected);
        }
    }
}

// Independent wire fixtures. The length is computed from the encoded fields
// so a short scalar can be substituted without invalidating ancestor lengths.
fn seedList(comptime fields: []const u8) []const u8 {
    return if (fields.len < 56)
        std.fmt.comptimePrint("{c}{s}", .{ @as(u8, 0xc0 + fields.len), fields })
    else
        std.fmt.comptimePrint("{c}{c}{s}", .{ @as(u8, 0xf8), @as(u8, fields.len), fields });
}

const address = "\x94" ++ "\x22" ** 20;
// This r is the x coordinate of a secp256k1 point, and s is in the low half.
// Recovery therefore reaches address comparison on these hand-built seeds.
const full_rs = "\xa0" ++ "\x22" ** 32 ++ "\xa0" ++ "\x33" ** 32;
const legacy_fields = "\x01\x02\x82\x52\x08\x80\x80\x80";
const dynamic_fields = "\x01\x80\x01\x02\x82\x52\x08" ++ address ++ "\x80\x82\x00\xff";
const key_list = seedList("\xa0" ++ "\x00" ** 31 ++ "\x01");
const access_list = seedList(seedList(address ++ key_list));
const blob_hash_list = seedList("\xa0\x01" ++ "\x42" ** 31);
const auth_fields = "\x01" ++ address ++ "\x80\x01";
const auth_list = seedList(seedList(auth_fields ++ full_rs));
const short_auth_list = seedList(seedList(auth_fields ++ "\x01\x02"));
const wire_seeds = [_][]const u8{
    seedList(legacy_fields ++ "\x1b" ++ full_rs),
    seedList(legacy_fields ++ "\x25" ++ full_rs),
    "\x01" ++ seedList("\x01\x80\x01\x82\x52\x08" ++ address ++ "\x80\x80" ++ access_list ++ "\x80" ++ full_rs),
    "\x02" ++ seedList(dynamic_fields ++ "\xc0\x01" ++ full_rs),
    "\x03" ++ seedList(dynamic_fields ++ "\xc0\x01" ++ blob_hash_list ++ "\x01" ++ full_rs),
    "\x04" ++ seedList(dynamic_fields ++ "\xc0" ++ auth_list ++ "\x01" ++ full_rs),
};
const short_typed = "\x02" ++ seedList(dynamic_fields ++ "\xc0\x01\x01\x02");
const short_auth = "\x04" ++ seedList(dynamic_fields ++ "\xc0" ++ short_auth_list ++ "\x01" ++ full_rs);
const zero_signature = "\x02" ++ seedList(dynamic_fields ++ "\xc0\x80\x80\x80");
const malformed_seeds = [_][]const u8{
    "\x00",
    "\x7f\xc0",
    "\x03\xc2\xc0\x01",
    "\xff" ++ "\xff" ** 8,
    "\x01\xf8\x00",
    seedList("\x82\x00\x01" ++ legacy_fields[1..] ++ "\x1b\x01\x02"),
};

test "regression: short authorization integers preserve the EIP-7702 outer signer" {
    const allocator = std.testing.allocator;
    const decoded = try encoding.decodeEnvelope(allocator, short_auth);
    defer decoded.deinit(allocator);
    // Foundry independently decoded this exact signed envelope.
    const expected = try primitives.Address.fromHex("0xe7d156f782f5bc909887a6bc3d04f237b3b511a6");
    try std.testing.expectEqual(expected, try wireSender(short_auth, decoded));
    try std.testing.expectEqual(expected, try encoding.recoverEnvelopeSender(allocator, decoded));
}

fn expectRejected(raw: []const u8, expected: ?encoding.TransactionEncodingError) !void {
    const allocator = std.testing.allocator;
    if (encoding.decodeEnvelope(allocator, raw)) |decoded| {
        defer decoded.deinit(allocator);
        return error.ExpectedEnvelopeRejection;
    } else |err| {
        if (err == error.OutOfMemory) return err;
        if (expected) |reason| try std.testing.expectEqual(reason, err);
    }
}

test "property: malformed RLP, integer padding, remainders and unknown types are rejected" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xadd0_7bad_00ff_f811);
    const random = prng.random();
    try expectRejected("", error.InputTooShort);
    for (0..trials) |i| {
        const raw = wire_seeds[i % wire_seeds.len];
        const prefix_len: usize = @intFromBool(raw[0] < 0x80);
        const prefix = raw[0..prefix_len];
        const payload = listPayload(raw[prefix_len..]);
        // The first field in each seed is the single byte 1. All other fields
        // remain intact, including the full signature and nested lists.
        const padded = [_]u8{ 0x82, 0, random.int(u8) };
        const invalid_fields = [_][]const u8{ &padded, "\x00", "\x81\x01" };
        for (invalid_fields, 0..) |bad, n| {
            const nonminimal = try listEnvelope(allocator, prefix, &.{ bad, payload[1..] });
            defer allocator.free(nonminimal);
            try expectRejected(nonminimal, if (n == 2) error.NonCanonicalSize else error.NonCanonicalInteger);
        }
        // Non-minimal s reaches the checks after any nested allocations.
        const bad_s = try listEnvelope(allocator, prefix, &.{ payload[0 .. payload.len - 33], &padded });
        defer allocator.free(bad_s);
        try expectRejected(bad_s, error.NonCanonicalInteger);

        var tail: [17]u8 = undefined;
        random.bytes(&tail);
        const trailing = try std.mem.concat(allocator, u8, &.{ raw, tail[0..random.intRangeAtMost(usize, 1, tail.len)] });
        defer allocator.free(trailing);
        try expectRejected(trailing, error.InvalidRemainder);
        try expectRejected(raw[0..random.uintLessThan(usize, raw.len)], null);
        try expectRejected(raw[0 .. raw.len - 1], error.InputTooShort);

        const unknown = [_]u8{@intCast(0x05 + i % (0x80 - 0x05))};
        const unknown_wire = try std.mem.concat(allocator, u8, &.{ &unknown, raw[prefix_len..] });
        defer allocator.free(unknown_wire);
        try expectRejected(unknown_wire, error.InvalidTransactionType);

        var huge = [_]u8{0xff} ** 9;
        if (i % 2 == 0) {
            random.bytes(huge[2..]);
            huge[1] = 0x80;
        }
        const outer = try std.mem.concat(allocator, u8, &.{ prefix, &huge });
        defer allocator.free(outer);
        try expectRejected(outer, null);
        huge[0] = 0xbf;
        const inner = try listEnvelope(allocator, prefix, &.{ &huge, payload[1..] });
        defer allocator.free(inner);
        try expectRejected(inner, null);
    }
}

fn blobWrappers(
    allocator: std.mem.Allocator,
    sample: primitives.Transaction.Eip4844Transaction,
    sidecars: []encoding.BlobSidecar,
    hashes: []primitives.Blob.VersionedHash,
    random: std.Random,
) !struct { bare: []u8, v0: []u8, v1: []u8 } {
    for (sidecars, hashes) |*sidecar, *hash| {
        @memset(&sidecar.blob, 0);
        random.bytes(sidecar.blob[0..32]);
        random.bytes(&sidecar.commitment);
        hash.* = primitives.Blob.commitmentToVersionedHash(sidecar.commitment);
        sidecar.proofs = .{ .blob = undefined };
        random.bytes(&sidecar.proofs.blob);
    }
    var tx = sample;
    tx.blob_versioned_hashes = hashes;
    const bare = try encode(allocator, .{ .eip4844 = tx });
    errdefer allocator.free(bare);
    const v0 = try encoding.encodeBlobNetworkEnvelope(allocator, bare, sidecars);
    errdefer allocator.free(v0);
    for (sidecars) |*sidecar| {
        sidecar.proofs = .{ .cells = undefined };
        random.bytes(std.mem.asBytes(&sidecar.proofs.cells));
    }
    return .{ .bare = bare, .v0 = v0, .v1 = try encoding.encodeBlobNetworkEnvelope(allocator, bare, sidecars) };
}

test "property: both blob network wrappers are rejected for every supported sidecar count" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x4844_7594_c011_b10b);
    const random = prng.random();
    const sidecars = try allocator.alloc(encoding.BlobSidecar, encoding.MAX_BLOBS_PER_TRANSACTION);
    defer allocator.free(sidecars);
    var hashes: [encoding.MAX_BLOBS_PER_TRANSACTION]primitives.Blob.VersionedHash = undefined;
    var fixture: Fixture = undefined;
    for (1..hashes.len + 1) |count| {
        var tx = fixture.make(random, .eip4844).eip4844;
        var data: [32]u8 = undefined;
        random.bytes(&data);
        tx.data = &data;
        const wires = try blobWrappers(allocator, tx, sidecars[0..count], hashes[0..count], random);
        defer allocator.free(wires.bare);
        defer allocator.free(wires.v0);
        defer allocator.free(wires.v1);
        const bare_tx = try encoding.decodeEnvelope(allocator, wires.bare);
        defer bare_tx.deinit(allocator);
        const data_offset = @intFromPtr(bare_tx.eip4844.data.ptr) - @intFromPtr(wires.bare.ptr);
        for ([_][]u8{ wires.v0, wires.v1 }, [_]encoding.BlobWrapperVersion{ .v0, .v1 }) |wire, version| {
            const wrapper = (try encoding.decodeBlobNetworkWrapper(wire)) orelse return error.ExpectedBlobWrapper;
            try std.testing.expectEqual(version, wrapper.version);
            try std.testing.expectEqual(count, wrapper.blob_count);
            try encoding.validateWrapperCommitments(wrapper, hashes[0..count]);
            const decoded = try encoding.decodeEnvelope(allocator, wire);
            defer decoded.deinit(allocator);
            try std.testing.expectEqualDeep(tx.data, decoded.eip4844.data);
            const payload_offset = @intFromPtr(wrapper.tx_payload.ptr) - @intFromPtr(wire.ptr);
            // The embedded payload omits the bare envelope's type byte.
            const offset = payload_offset + data_offset - 1;
            for (0..trials / hashes.len) |_| {
                var replacement: [data.len]u8 = undefined;
                random.bytes(&replacement);
                @memcpy(wires.bare[data_offset..][0..data.len], &replacement);
                @memcpy(wire[offset..][0..data.len], &replacement);
                try encoding.requireCanonicalEnvelope(wires.bare);
                try std.testing.expectError(error.UnexpectedInput, encoding.requireCanonicalEnvelope(wire));
                const canonical = try encoding.canonicalTransactionEnvelope(allocator, wire);
                defer canonical.deinit(allocator);
                try std.testing.expectEqualSlices(u8, wires.bare, canonical.bytes);
            }
            @memcpy(wires.bare[data_offset..][0..data.len], &data);
        }
    }
}

fn checkHelpers(decoded: encoding.DecodedEnvelope, raw: []const u8) !void {
    const allocator = std.testing.allocator;
    switch (decoded) {
        inline else => |tx, tag| {
            const receipt = @field(primitives.Receipt.TransactionType, @tagName(tag));
            try std.testing.expectEqual(receipt, encoding.envelopeReceiptType(decoded));
            const wire_type: u8 = if (raw[0] >= 0xc0) 0 else raw[0];
            try std.testing.expectEqual(wire_type, @intFromEnum(@field(primitives.Transaction.TransactionType, @tagName(tag))));
            const chain: ?u64 = if (tag != .legacy) tx.chain_id else if (tx.v >= 35) (tx.v - 35) / 2 else null;
            try std.testing.expectEqual(chain, encoding.envelopeChainId(decoded));
            const entries: []const primitives.Transaction.AccessListItem = if (tag == .legacy) &.{} else tx.access_list;
            try std.testing.expectEqualDeep(entries, encoding.envelopeAccessList(decoded));
            const auths: []const primitives.Authorization.Authorization = if (tag == .eip7702) tx.authorization_list else &.{};
            try std.testing.expectEqualDeep(auths, encoding.envelopeAuthorizationList(decoded));
        },
    }
    const hash_bytes = try encoding.envelopeBlobVersionedHashBytes(allocator, decoded);
    defer if (hash_bytes) |bytes| allocator.free(bytes);
    const hashes = encoding.envelopeBlobVersionedHashes(decoded);
    if (decoded == .eip4844) {
        const bytes = hash_bytes orelse return error.MissingBlobHashes;
        const versioned = hashes orelse return error.MissingBlobHashes;
        try std.testing.expectEqualDeep(decoded.eip4844.blob_versioned_hashes, versioned);
        try std.testing.expectEqual(versioned.len, bytes.len);
        for (versioned, bytes) |v, b| try std.testing.expectEqual(v.bytes, b);
        try std.testing.expectEqual(@as(?u256, @as(u256, bytes.len) * 131_072), encoding.envelopeBlobGasUsed(decoded));
    } else {
        try std.testing.expect(hashes == null and hash_bytes == null and encoding.envelopeBlobGasUsed(decoded) == null);
    }
}

fn fuzzDecode(_: void, input: []const u8) anyerror!void {
    const allocator = std.testing.allocator;
    const decoded = encoding.decodeEnvelope(allocator, input) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    defer decoded.deinit(allocator);
    try checkHelpers(decoded, input);
    const canonical = try encoding.canonicalTransactionEnvelope(allocator, input);
    defer canonical.deinit(allocator);
    try encoding.requireCanonicalEnvelope(canonical.bytes);
    const reencoded = try encodeSigned(allocator, decoded);
    defer allocator.free(reencoded);
    try std.testing.expectEqualSlices(u8, canonical.bytes, reencoded);
    try std.testing.expectEqual(primitives.Hash.keccak256(reencoded), encoding.transactionHash(canonical.bytes));
    const again = try encoding.decodeEnvelope(allocator, reencoded);
    defer again.deinit(allocator);
    try std.testing.expectEqualDeep(decoded, again);
}

// Recover against the original RLP field bytes. In particular a decoded
// EIP-7702 authorization signature may have been shorter than 32 bytes.
fn wireSender(raw: []const u8, decoded: encoding.DecodedEnvelope) !primitives.Address {
    const allocator = std.testing.allocator;
    const tx = encoding.envelopeToLegacyLikeTx(decoded);
    const parity = encoding.legacyRecoveryId(tx.v);
    const prefix = raw[0..@intFromBool(decoded != .legacy)];
    const body = listPayload(raw[prefix.len..]);
    const v = try primitives.Rlp.encode(allocator, if (decoded == .legacy) tx.v else @as(u64, parity));
    defer allocator.free(v);
    const r = try primitives.Rlp.encode(allocator, encoding.bytes32ToU256(tx.r));
    defer allocator.free(r);
    const s = try primitives.Rlp.encode(allocator, encoding.bytes32ToU256(tx.s));
    defer allocator.free(s);
    const sig_len = v.len + r.len + s.len;
    if (body.len < sig_len) return error.InconsistentSignatureLength;
    const fields = body[0 .. body.len - sig_len];
    const signature = body[fields.len..];
    try std.testing.expectEqualSlices(u8, v, signature[0..v.len]);
    try std.testing.expectEqualSlices(u8, r, signature[v.len..][0..r.len]);
    try std.testing.expectEqualSlices(u8, s, signature[v.len + r.len ..]);
    const preimage = if (decoded == .legacy and tx.v >= 35) blk: {
        const chain = try primitives.Rlp.encode(allocator, (tx.v - 35) / 2);
        defer allocator.free(chain);
        break :blk try listEnvelope(allocator, prefix, &.{ fields, chain, "\x80\x80" });
    } else try listEnvelope(allocator, prefix, &.{fields});
    defer allocator.free(preimage);
    return crypto.Crypto.unaudited_recoverAddress(primitives.Hash.keccak256(preimage), .{
        .v = 27 + parity,
        .r = encoding.bytes32ToU256(tx.r),
        .s = encoding.bytes32ToU256(tx.s),
    });
}

fn fuzzCanonicalAndRecover(_: void, input: []const u8) anyerror!void {
    const allocator = std.testing.allocator;
    const required = encoding.requireCanonicalEnvelope(input);
    const canonical = encoding.canonicalTransactionEnvelope(allocator, input) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (required) |_| return error.AcceptedMalformedWrapper else |_| {}
        return expectRejected(input, null);
    };
    defer canonical.deinit(allocator);
    if (required) |_| {
        try std.testing.expectEqualSlices(u8, input, canonical.bytes);
        try std.testing.expect(canonical.owned == null);
    } else |err| {
        try std.testing.expectEqual(error.UnexpectedInput, err);
        try std.testing.expect(canonical.owned != null);
    }
    // The wrapper helpers only check framing. Sender recovery takes the
    // result of full decoding, which can still reject a malformed body.
    const decoded = encoding.decodeEnvelope(allocator, input) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    defer decoded.deinit(allocator);
    try encoding.requireCanonicalEnvelope(canonical.bytes);
    const second = try encoding.canonicalTransactionEnvelope(allocator, canonical.bytes);
    defer second.deinit(allocator);
    try std.testing.expectEqualSlices(u8, canonical.bytes, second.bytes);
    try std.testing.expect(second.owned == null);
    const actual = encoding.recoverEnvelopeSender(allocator, decoded);
    if (wireSender(canonical.bytes, decoded)) |expected| {
        try std.testing.expectEqual(expected, try actual);
    } else |err| switch (err) {
        error.InvalidSignature, error.InvalidRecoveryId => try std.testing.expectError(err, actual),
        else => return err,
    }
}

fn fuzzWithCorpus(comptime target: fn (void, []const u8) anyerror!void) !void {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x4844_0000_0000_0003);
    var fixture: Fixture = undefined;
    const blob_tx = fixture.make(prng.random(), .eip4844).eip4844;
    const sidecar = try allocator.alloc(encoding.BlobSidecar, 1);
    defer allocator.free(sidecar);
    var hashes: [1]primitives.Blob.VersionedHash = undefined;
    const wires = try blobWrappers(allocator, blob_tx, sidecar, &hashes, prng.random());
    defer allocator.free(wires.bare);
    defer allocator.free(wires.v0);
    defer allocator.free(wires.v1);
    const corpus = wire_seeds ++ malformed_seeds ++ [_][]const u8{ wires.v0, wires.v1, short_typed, short_auth, zero_signature };
    try std.testing.fuzz({}, target, .{ .corpus = &corpus });
}

test "fuzz: decodeEnvelope preserves canonical bytes, hashes and decoded fields" {
    try fuzzWithCorpus(fuzzDecode);
}

test "fuzz: canonicalTransactionEnvelope, requireCanonicalEnvelope and recoverEnvelopeSender" {
    try fuzzWithCorpus(fuzzCanonicalAndRecover);
}
