const std = @import("std");
const primitives = @import("primitives");
const runtime = @import("../../node/runtime.zig");
const block_builder = @import("../../block_builder.zig");
const rpc_parse = @import("../parse.zig");

pub fn handleGetRawBlock(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: ?std.json.Value,
) !std.json.Value {
    const block_number = try parseSingleBlockNumber(params);
    const block = (try rt.blockchain.getBlockByNumber(block_number)) orelse return .null;
    const encoded = try encodeBlock(allocator, block);
    defer allocator.free(encoded);
    return hexBytes(allocator, encoded);
}

pub fn handleGetRawHeader(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: ?std.json.Value,
) !std.json.Value {
    const block_number = try parseSingleBlockNumber(params);
    const block = (try rt.blockchain.getBlockByNumber(block_number)) orelse return .null;
    const encoded = try primitives.BlockHeader.rlpEncode(&block.header, allocator);
    defer allocator.free(encoded);
    return hexBytes(allocator, encoded);
}

pub fn handleGetRawReceipts(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: ?std.json.Value,
) !std.json.Value {
    const block_number = try parseSingleBlockNumber(params);
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
    const head = rt.blockchain.getHeadBlockNumber() orelse return .null;
    var block_number: u64 = 0;
    while (block_number <= head) : (block_number += 1) {
        const block = (try rt.blockchain.getBlockByNumber(block_number)) orelse continue;
        for (block.body.transactions) |tx| {
            if (!std.mem.eql(u8, &transactionHash(tx.raw), &tx_hash)) continue;
            return hexBytes(allocator, tx.raw);
        }
    }
    return .null;
}

fn parseSingleBlockNumber(params: ?std.json.Value) !u64 {
    const items = try rpc_parse.paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    return rpc_parse.parseQuantityValue(u64, items[0]);
}

fn parseSingleHash(params: ?std.json.Value) ![32]u8 {
    const items = try rpc_parse.paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    return rpc_parse.parseHash32Value(items[0]);
}

fn encodeBlock(
    allocator: std.mem.Allocator,
    block: primitives.Block.Block,
) ![]u8 {
    var fields = std.ArrayList([]u8){};
    defer freeEncodedFields(allocator, &fields);

    try fields.append(allocator, try primitives.BlockHeader.rlpEncode(&block.header, allocator));
    try fields.append(allocator, try encodeRawTransactionList(allocator, block.body.transactions));
    try fields.append(allocator, try encodeOmmers(allocator, block.body.ommers));
    if (block.body.withdrawals) |withdrawals| {
        try fields.append(allocator, try encodeWithdrawals(allocator, withdrawals));
    }

    return encodeRlpListFromEncodedFields(allocator, fields.items);
}

fn encodeRawTransactionList(
    allocator: std.mem.Allocator,
    transactions: []const primitives.BlockBody.TransactionData,
) ![]u8 {
    const fields = try allocator.alloc([]const u8, transactions.len);
    defer allocator.free(fields);
    for (transactions, 0..) |tx, i| {
        fields[i] = tx.raw;
    }
    return encodeRlpListFromEncodedFields(allocator, fields);
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
        try fields.append(allocator, try primitives.BlockHeader.rlpEncode(&header, allocator));
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
        try fields.append(allocator, try encodeWithdrawal(allocator, withdrawal));
    }

    return encodeRlpListFromEncodedFields(allocator, fields.items);
}

fn encodeWithdrawal(
    allocator: std.mem.Allocator,
    withdrawal: primitives.BlockBody.Withdrawal,
) ![]u8 {
    var fields = std.ArrayList([]u8){};
    defer freeEncodedFields(allocator, &fields);

    try fields.append(allocator, try primitives.Rlp.encode(allocator, withdrawal.index));
    try fields.append(allocator, try primitives.Rlp.encode(allocator, withdrawal.validator_index));
    try fields.append(allocator, try primitives.Rlp.encodeBytes(allocator, &withdrawal.address.bytes));
    try fields.append(allocator, try primitives.Rlp.encode(allocator, withdrawal.amount));

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
