const std = @import("std");
const primitives = @import("primitives");
const crypto = @import("crypto");
const zevm = @import("zevm");
const harness = @import("harness");

fn encodeListFromEncoded(allocator: std.mem.Allocator, fields: []const []const u8) ![]u8 {
    var total_len: usize = 0;
    for (fields) |f| total_len += f.len;
    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);
    if (total_len < 56) {
        try out.append(allocator, 0xc0 + @as(u8, @intCast(total_len)));
    } else {
        const len_bytes = try primitives.Rlp.encodeLength(allocator, total_len);
        defer allocator.free(len_bytes);
        try out.append(allocator, 0xf7 + @as(u8, @intCast(len_bytes.len)));
        try out.appendSlice(allocator, len_bytes);
    }
    for (fields) |f| try out.appendSlice(allocator, f);
    return try out.toOwnedSlice(allocator);
}

fn buildSignedEip1559(allocator: std.mem.Allocator, priv_key: [32]u8, nonce: u64) ![]u8 {
    var payload = std.ArrayList(u8){};
    defer payload.deinit(allocator);
    // Build canonical EIP-1559 fields for signing
    var fields = std.ArrayList([]const u8){};
    defer {
        for (fields.items) |f| allocator.free(f);
        fields.deinit(allocator);
    }

    try fields.append(allocator, try primitives.Rlp.encode(allocator, @as(u64, 1))); // chain_id
    try fields.append(allocator, try primitives.Rlp.encode(allocator, nonce));
    try fields.append(allocator, try primitives.Rlp.encode(allocator, @as(u64, 1_000_000_000))); // priority fee
    try fields.append(allocator, try primitives.Rlp.encode(allocator, @as(u64, 30_000_000_000))); // max fee
    try fields.append(allocator, try primitives.Rlp.encode(allocator, @as(u64, 100_000))); // gas limit
    const to_bytes = [_]u8{0xab} ** 20;
    try fields.append(allocator, try primitives.Rlp.encode(allocator, to_bytes[0..]));
    try fields.append(allocator, try primitives.Rlp.encode(allocator, @as(u64, 1_000_000_000_000_000)));
    const calldata = [_]u8{ 0xa9, 0x05, 0x9c, 0xbb } ++ ([_]u8{0x00} ** 12) ++ ([_]u8{0xcd} ** 20) ++ ([_]u8{0x00} ** 31) ++ [_]u8{0x64};
    try fields.append(allocator, try primitives.Rlp.encode(allocator, calldata[0..]));
    try fields.append(allocator, try allocator.dupe(u8, &[_]u8{0xc0})); // empty access list

    const unsigned_list = try encodeListFromEncoded(allocator, fields.items);
    defer allocator.free(unsigned_list);

    var preimage = try allocator.alloc(u8, 1 + unsigned_list.len);
    defer allocator.free(preimage);
    preimage[0] = 0x02;
    @memcpy(preimage[1..], unsigned_list);

    var hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(preimage, &hash, .{});
    const sig = try crypto.Crypto.unaudited_signHash(hash, priv_key);

    try fields.append(allocator, try primitives.Rlp.encode(allocator, @as(u8, sig.v - 27)));
    try fields.append(allocator, try primitives.Rlp.encode(allocator, sig.r));
    try fields.append(allocator, try primitives.Rlp.encode(allocator, sig.s));

    const signed_list = try encodeListFromEncoded(allocator, fields.items);
    defer allocator.free(signed_list);

    const out = try allocator.alloc(u8, 1 + signed_list.len);
    out[0] = 0x02;
    @memcpy(out[1..], signed_list);
    return out;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cfg = try harness.parseArgs(allocator, "tx-encoding");
    var runner = harness.Runner.init(allocator, cfg);
    defer runner.deinit();

    const priv_key = [_]u8{0x11} ** 32;
    const to_addr = primitives.Address{ .bytes = [_]u8{0x42} ** 20 };
    const calldata = [_]u8{ 0xa9, 0x05, 0x9c, 0xbb } ++ ([_]u8{0x12} ** 64);

    const unsigned_legacy = primitives.Transaction.LegacyTransaction{
        .nonce = 7,
        .gas_price = 20_000_000_000,
        .gas_limit = 65_000,
        .to = to_addr,
        .value = 1_000_000_000_000_000,
        .data = &calldata,
        .v = 1,
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
    };

    const signed_legacy = try zevm.transaction_encoding.signLegacyTransaction(allocator, unsigned_legacy, priv_key, 1);
    const raw_legacy = try zevm.transaction_encoding.encodeLegacyTransactionEnvelope(allocator, signed_legacy);
    defer allocator.free(raw_legacy);

    const raw_1559 = try buildSignedEip1559(allocator, priv_key, 42);
    defer allocator.free(raw_1559);

    const Ctx = struct {
        allocator: std.mem.Allocator,
        signed_legacy: primitives.Transaction.LegacyTransaction,
        raw_legacy: []const u8,
        raw_1559: []const u8,
        priv_key: [32]u8,
    };
    var ctx = Ctx{
        .allocator = allocator,
        .signed_legacy = signed_legacy,
        .raw_legacy = raw_legacy,
        .raw_1559 = raw_1559,
        .priv_key = priv_key,
    };

    try runner.run("tx_encoding/encode_legacy", &ctx, struct {
        fn f(c: *Ctx) !void {
            const enc = try zevm.transaction_encoding.encodeLegacyTransactionEnvelope(c.allocator, c.signed_legacy);
            defer c.allocator.free(enc);
            std.mem.doNotOptimizeAway(&enc);
        }
    }.f, .{ .bytes_per_op = raw_legacy.len });

    try runner.run("tx_encoding/decode_legacy", &ctx, struct {
        fn f(c: *Ctx) !void {
            const dec = try zevm.transaction_encoding.decodeLegacyEnvelope(c.raw_legacy);
            std.mem.doNotOptimizeAway(&dec);
        }
    }.f, .{ .bytes_per_op = raw_legacy.len });

    try runner.run("tx_encoding/decode_eip1559", &ctx, struct {
        fn f(c: *Ctx) !void {
            var dec = try zevm.transaction_encoding.decodeEnvelope(c.allocator, c.raw_1559);
            defer dec.deinit(c.allocator);
            std.mem.doNotOptimizeAway(&dec);
        }
    }.f, .{ .bytes_per_op = raw_1559.len });

    try runner.run("tx_encoding/tx_hash", &ctx, struct {
        fn f(c: *Ctx) !void {
            const h = zevm.transaction_encoding.transactionHash(c.raw_1559);
            std.mem.doNotOptimizeAway(&h);
        }
    }.f, .{ .bytes_per_op = raw_1559.len });

    try runner.run("tx_encoding/recover_legacy_sender", &ctx, struct {
        fn f(c: *Ctx) !void {
            const sender = try zevm.transaction_encoding.recoverLegacySender(c.allocator, c.signed_legacy);
            std.mem.doNotOptimizeAway(&sender);
        }
    }.f, .{});

    try runner.run("tx_encoding/recover_eip1559_sender", &ctx, struct {
        fn f(c: *Ctx) !void {
            var dec = try zevm.transaction_encoding.decodeEnvelope(c.allocator, c.raw_1559);
            defer dec.deinit(c.allocator);
            const sender = try zevm.transaction_encoding.recoverEnvelopeSender(c.allocator, dec);
            std.mem.doNotOptimizeAway(&sender);
        }
    }.f, .{});

    try runner.run("tx_encoding/sign_legacy", &ctx, struct {
        fn f(c: *Ctx) !void {
            const signed = try zevm.transaction_encoding.signLegacyTransaction(c.allocator, c.signed_legacy, c.priv_key, 1);
            std.mem.doNotOptimizeAway(&signed);
        }
    }.f, .{});

    try runner.finish();
}
