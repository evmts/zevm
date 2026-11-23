const std = @import("std");
const primitives = @import("primitives");
const runtime = @import("../../node/runtime.zig");
const block_builder = @import("../../block_builder.zig");
const rpc_parse = @import("../parse.zig");
const block_query_handlers = @import("block_query_handlers.zig");

pub fn handleGetRawBlock(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: ?std.json.Value,
) !std.json.Value {
    const block_number = try resolveSingleBlockNumber(rt, params);
    const block = (try rt.blockchain.getBlockByNumber(block_number)) orelse return .null;
    const encoded = try encodeBlock(allocator, block, requestsHash(rt, block));
    defer allocator.free(encoded);
    return hexBytes(allocator, encoded);
}

pub fn handleGetRawHeader(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: ?std.json.Value,
) !std.json.Value {
    const block_number = try resolveSingleBlockNumber(rt, params);
    const block = (try rt.blockchain.getBlockByNumber(block_number)) orelse return .null;
    const encoded = try encodeHeader(allocator, &block.header, requestsHash(rt, block));
    defer allocator.free(encoded);
    return hexBytes(allocator, encoded);
}

fn requestsHash(rt: *const runtime.NodeRuntime, block: primitives.Block.Block) ?[32]u8 {
    return block_query_handlers.requestsHashForHeader(rt, block.hash, block.header.number, block.header.timestamp);
}

pub fn handleGetRawReceipts(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: ?std.json.Value,
) !std.json.Value {
    const block_number = try resolveSingleBlockNumber(rt, params);
    const block = (try rt.blockchain.getBlockByNumber(block_number)) orelse return .null;
    const receipts = rt.receipt_index.getByBlockHash(block.hash) orelse &.{};

    var array = std.json.Array.init(allocator);
    errdefer {
        for (array.items) |*item| deinitJsonValue(allocator, item);
        array.deinit();
    }

    for (receipts) |receipt| {
        const encoded = try block_builder.encodeReceiptEnvelope(allocator, receipt);
        defer allocator.free(encoded);
        try array.append(try hexBytes(allocator, encoded));
    }
    return .{ .array = array };
}

pub fn handleGetRawTransaction(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: ?std.json.Value,
) !std.json.Value {
    const tx_hash = try parseSingleHash(params);
    // Fast path: the receipt index maps a mined hash to its block and
    // position. The entry is trusted only when the block is canonical and the
    // transaction at that position hashes to the request.
    if (rt.receipt_index.locateByTxHash(tx_hash)) |locator| {
        if (try rt.blockchain.getBlockByHash(locator.block_hash)) |block| {
            const canonical = rt.blockchain.getCanonicalHash(block.header.number);
            const is_canonical = if (canonical) |hash| std.mem.eql(u8, &hash, &locator.block_hash) else false;
            if (is_canonical and locator.tx_index < block.body.transactions.len) {
                const tx = block.body.transactions[locator.tx_index];
                if (std.mem.eql(u8, &transactionHash(tx.raw), &tx_hash)) return hexBytes(allocator, tx.raw);
            }
        }
    }

    // Fallback for transactions the index does not cover. Skip the O(chain)
    // Keccak scan when the receipt index already covers the canonical head.
    const head = rt.blockchain.getHeadBlockNumber() orelse return .null;
    const head_indexed = if (rt.blockchain.getCanonicalHash(head)) |head_hash|
        rt.receipt_index.getByBlockHash(head_hash) != null
    else
        false;
    if (head_indexed) return .null;

    var block_number: u64 = 0;
    while (true) {
        if (try rt.blockchain.getBlockByNumber(block_number)) |block| {
            for (block.body.transactions) |tx| {
                if (!std.mem.eql(u8, &transactionHash(tx.raw), &tx_hash)) continue;
                return hexBytes(allocator, tx.raw);
            }
        }
        if (block_number == head) break;
        block_number += 1;
    }
    return .null;
}

fn resolveSingleBlockNumber(rt: *runtime.NodeRuntime, params: ?std.json.Value) !u64 {
    const items = try rpc_parse.paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    return rpc_parse.resolveTrustedBlockSelector(rt.head_block_number, items[0]);
}

fn parseSingleHash(params: ?std.json.Value) ![32]u8 {
    const items = try rpc_parse.paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    return rpc_parse.parseHash32Value(items[0]);
}

fn encodeBlock(
    allocator: std.mem.Allocator,
    block: primitives.Block.Block,
    requests_hash: ?[32]u8,
) ![]u8 {
    var fields = std.ArrayList([]u8){};
    defer freeEncodedFields(allocator, &fields);

    try appendField(allocator, &fields, encodeHeader(allocator, &block.header, requests_hash));
    try appendField(allocator, &fields, encodeRawTransactionList(allocator, block.body.transactions));
    try appendField(allocator, &fields, encodeOmmers(allocator, block.body.ommers));
    if (block.body.withdrawals) |withdrawals| {
        try appendField(allocator, &fields, encodeWithdrawals(allocator, withdrawals));
    }

    return encodeRlpListFromEncodedFields(allocator, fields.items);
}

/// Takes ownership of `encoded` and frees it if the list cannot grow.
fn appendField(allocator: std.mem.Allocator, fields: *std.ArrayList([]u8), encoded: anytype) !void {
    const field: []u8 = try encoded;
    errdefer allocator.free(field);
    try fields.append(allocator, field);
}

/// Encodes a block header. A Prague or later header carries the EIP-7685
/// `requests_hash` as its 21st field, which `BlockHeader.rlpEncode` omits;
/// without it the keccak of the output does not match the block hash.
fn encodeHeader(
    allocator: std.mem.Allocator,
    header: *const primitives.BlockHeader.BlockHeader,
    requests_hash: ?[32]u8,
) ![]u8 {
    const hash = requests_hash orelse return primitives.BlockHeader.rlpEncode(header, allocator);

    var fields = std.ArrayList([]u8){};
    defer freeEncodedFields(allocator, &fields);

    try appendField(allocator, &fields, primitives.Rlp.encodeBytes(allocator, &header.parent_hash));
    try appendField(allocator, &fields, primitives.Rlp.encodeBytes(allocator, &header.ommers_hash));
    try appendField(allocator, &fields, primitives.Rlp.encodeBytes(allocator, &header.beneficiary.bytes));
    try appendField(allocator, &fields, primitives.Rlp.encodeBytes(allocator, &header.state_root));
    try appendField(allocator, &fields, primitives.Rlp.encodeBytes(allocator, &header.transactions_root));
    try appendField(allocator, &fields, primitives.Rlp.encodeBytes(allocator, &header.receipts_root));
    try appendField(allocator, &fields, primitives.Rlp.encodeBytes(allocator, &header.logs_bloom));
    try appendField(allocator, &fields, primitives.Rlp.encode(allocator, header.difficulty));
    try appendField(allocator, &fields, primitives.Rlp.encode(allocator, header.number));
    try appendField(allocator, &fields, primitives.Rlp.encode(allocator, header.gas_limit));
    try appendField(allocator, &fields, primitives.Rlp.encode(allocator, header.gas_used));
    try appendField(allocator, &fields, primitives.Rlp.encode(allocator, header.timestamp));
    try appendField(allocator, &fields, primitives.Rlp.encodeBytes(allocator, header.extra_data));
    try appendField(allocator, &fields, primitives.Rlp.encodeBytes(allocator, &header.mix_hash));
    try appendField(allocator, &fields, primitives.Rlp.encodeBytes(allocator, &header.nonce));
    try appendField(allocator, &fields, primitives.Rlp.encode(allocator, header.base_fee_per_gas orelse return error.MissingBaseFeePerGas));
    const withdrawals_root = header.withdrawals_root orelse return error.MissingWithdrawalsRoot;
    try appendField(allocator, &fields, primitives.Rlp.encodeBytes(allocator, &withdrawals_root));
    try appendField(allocator, &fields, primitives.Rlp.encode(allocator, header.blob_gas_used orelse return error.MissingBlobGasUsed));
    try appendField(allocator, &fields, primitives.Rlp.encode(allocator, header.excess_blob_gas orelse return error.MissingExcessBlobGas));
    const parent_beacon_block_root = header.parent_beacon_block_root orelse return error.MissingParentBeaconBlockRoot;
    try appendField(allocator, &fields, primitives.Rlp.encodeBytes(allocator, &parent_beacon_block_root));
    try appendField(allocator, &fields, primitives.Rlp.encodeBytes(allocator, &hash));

    return encodeRlpListFromEncodedFields(allocator, fields.items);
}

/// Encodes the block body's transaction list. A legacy transaction is already
/// an RLP list and is embedded as-is. A typed EIP-2718 envelope
/// (`type || payload`, first byte below 0x80) is opaque bytes and is embedded
/// as an RLP byte string; embedding it raw corrupts the enclosing list.
fn encodeRawTransactionList(
    allocator: std.mem.Allocator,
    transactions: []const primitives.BlockBody.TransactionData,
) ![]u8 {
    var fields = std.ArrayList([]u8){};
    defer freeEncodedFields(allocator, &fields);

    for (transactions) |tx| {
        if (tx.raw.len > 0 and tx.raw[0] < 0x80) {
            try appendField(allocator, &fields, primitives.Rlp.encodeBytes(allocator, tx.raw));
        } else {
            try appendField(allocator, &fields, allocator.dupe(u8, tx.raw));
        }
    }
    return encodeRlpListFromEncodedFields(allocator, fields.items);
}

fn encodeOmmers(
    allocator: std.mem.Allocator,
    ommers: []const primitives.BlockBody.UncleHeader,
) ![]u8 {
    var fields = std.ArrayList([]u8){};
    defer freeEncodedFields(allocator, &fields);

    for (ommers) |ommer| {
        var header = primitives.BlockHeader.BlockHeader{
            .parent_hash = ommer.parent_hash,
            .ommers_hash = ommer.ommers_hash,
            .beneficiary = ommer.beneficiary,
            .state_root = ommer.state_root,
            .transactions_root = ommer.transactions_root,
            .receipts_root = ommer.receipts_root,
            .logs_bloom = ommer.logs_bloom,
            .difficulty = ommer.difficulty,
            .number = ommer.number,
            .gas_limit = ommer.gas_limit,
            .gas_used = ommer.gas_used,
            .timestamp = ommer.timestamp,
            .extra_data = ommer.extra_data,
            .mix_hash = ommer.mix_hash,
            .nonce = ommer.nonce,
        };
        try appendField(allocator, &fields, primitives.BlockHeader.rlpEncode(&header, allocator));
    }

    return encodeRlpListFromEncodedFields(allocator, fields.items);
}

fn encodeWithdrawals(
    allocator: std.mem.Allocator,
    withdrawals: []const primitives.BlockBody.Withdrawal,
) ![]u8 {
    var fields = std.ArrayList([]u8){};
    defer freeEncodedFields(allocator, &fields);

    for (withdrawals) |withdrawal| {
        try appendField(allocator, &fields, encodeWithdrawal(allocator, withdrawal));
    }

    return encodeRlpListFromEncodedFields(allocator, fields.items);
}

fn encodeWithdrawal(
    allocator: std.mem.Allocator,
    withdrawal: primitives.BlockBody.Withdrawal,
) ![]u8 {
    var fields = std.ArrayList([]u8){};
    defer freeEncodedFields(allocator, &fields);

    try appendField(allocator, &fields, primitives.Rlp.encode(allocator, withdrawal.index));
    try appendField(allocator, &fields, primitives.Rlp.encode(allocator, withdrawal.validator_index));
    try appendField(allocator, &fields, primitives.Rlp.encodeBytes(allocator, &withdrawal.address.bytes));
    try appendField(allocator, &fields, primitives.Rlp.encode(allocator, withdrawal.amount));

    return encodeRlpListFromEncodedFields(allocator, fields.items);
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

fn transactionHash(raw: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(raw, &out, .{});
    return out;
}

fn hexBytes(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Value {
    const out = try allocator.alloc(u8, 2 + bytes.len * 2);
    out[0] = '0';
    out[1] = 'x';
    const alphabet = "0123456789abcdef";
    for (bytes, 0..) |byte, index| {
        out[2 + index * 2] = alphabet[byte >> 4];
        out[3 + index * 2] = alphabet[byte & 0x0f];
    }
    return .{ .string = out };
}

fn deinitJsonValue(allocator: std.mem.Allocator, value: *std.json.Value) void {
    switch (value.*) {
        .string => |s| allocator.free(s),
        .array => |*array| {
            for (array.items) |*item| deinitJsonValue(allocator, item);
            array.deinit();
        },
        .object => |*object| {
            var it = object.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                deinitJsonValue(allocator, entry.value_ptr);
            }
            object.deinit();
        },
        else => {},
    }
}

test "debug_raw wraps typed transactions as RLP byte strings and embeds legacy lists directly" {
    const allocator = std.testing.allocator;

    // Legacy transaction: an RLP list of three single-byte items.
    const legacy = [_]u8{ 0xc3, 0x01, 0x02, 0x03 };
    // EIP-1559 envelope: type byte 0x02 followed by an RLP list payload.
    const typed = [_]u8{ 0x02, 0xc2, 0x05, 0x06 };

    const transactions = [_]primitives.BlockBody.TransactionData{
        .{ .raw = &legacy },
        .{ .raw = &typed },
    };
    const encoded = try encodeRawTransactionList(allocator, &transactions);
    defer allocator.free(encoded);

    // list(9 bytes) = legacy list (4 bytes) ++ string(4 bytes) with 0x84 prefix.
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0xc9, 0xc3, 0x01, 0x02, 0x03, 0x84, 0x02, 0xc2, 0x05, 0x06 },
        encoded,
    );

    // The output decodes as a two-item list whose second item is the envelope.
    const decoded = try primitives.Rlp.decode(allocator, encoded, false);
    defer decoded.data.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), decoded.data.List.len);
    try std.testing.expectEqualSlices(u8, &typed, decoded.data.List[1].String);
}

test "debug_raw header encoding includes requests_hash so its keccak matches the Prague block hash" {
    const allocator = std.testing.allocator;

    const header = primitives.BlockHeader.BlockHeader{
        .number = 7,
        .gas_limit = 30_000_000,
        .timestamp = 1_700_000_000,
        .base_fee_per_gas = 7,
        .withdrawals_root = primitives.BlockHeader.EMPTY_WITHDRAWALS_ROOT,
        .blob_gas_used = 0,
        .excess_blob_gas = 0,
        .parent_beacon_block_root = primitives.Hash.ZERO,
    };
    var requests_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&.{}, &requests_hash, .{});

    const with_hash = try encodeHeader(allocator, &header, requests_hash);
    defer allocator.free(with_hash);
    const without_hash = try encodeHeader(allocator, &header, null);
    defer allocator.free(without_hash);

    // The Prague header is the pre-Prague header plus one 33-byte RLP string.
    try std.testing.expectEqual(without_hash.len + 33, with_hash.len);
    try std.testing.expectEqualSlices(u8, &requests_hash, with_hash[with_hash.len - 32 ..]);
    try std.testing.expectEqual(@as(u8, 0xa0), with_hash[with_hash.len - 33]);

    const expected_hash = try block_builder.computeHeaderHashWithRequestsHash(allocator, &header, requests_hash);
    try std.testing.expectEqualSlices(u8, &expected_hash, &transactionHash(with_hash));
}
