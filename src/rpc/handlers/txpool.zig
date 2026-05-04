const std = @import("std");
const primitives = @import("primitives");
const runtime = @import("../../node/runtime.zig");
const tx_encoding = @import("../../transaction_encoding.zig");
const txpool_mod = @import("../../txpool.zig");

pub fn handleContent(
    allocator: std.mem.Allocator,
    rt: *const runtime.NodeRuntime,
    params: ?std.json.Value,
) !std.json.Value {
    try validateNoParams(params);
    return poolEntries(allocator, rt, .content);
}

pub fn handleContentFrom(
    allocator: std.mem.Allocator,
    rt: *const runtime.NodeRuntime,
    params: ?std.json.Value,
) !std.json.Value {
    return poolEntriesFrom(allocator, rt, .content, try parseSingleAddressArg(params));
}

pub fn handleStatus(
    allocator: std.mem.Allocator,
    rt: *const runtime.NodeRuntime,
    params: ?std.json.Value,
) !std.json.Value {
    try validateNoParams(params);

    var obj = std.json.ObjectMap.init(allocator);
    try putOwnedJson(&obj, allocator, "pending", .{ .string = try quantityHex(allocator, rt.pool.pendingCount()) });
    try putOwnedJson(&obj, allocator, "queued", .{ .string = try quantityHex(allocator, rt.pool.queuedCount()) });
    return .{ .object = obj };
}

pub fn handleInspect(
    allocator: std.mem.Allocator,
    rt: *const runtime.NodeRuntime,
    params: ?std.json.Value,
) !std.json.Value {
    try validateNoParams(params);
    return poolEntries(allocator, rt, .inspect);
}

const EntryShape = enum {
    content,
    inspect,
};

fn poolEntries(
    allocator: std.mem.Allocator,
    rt: *const runtime.NodeRuntime,
    shape: EntryShape,
) !std.json.Value {
    var pending = std.json.ObjectMap.init(allocator);
    var queued = std.json.ObjectMap.init(allocator);

    for (rt.pool.items()) |tx| {
        const section = switch (rt.pool.statusOf(tx.sender, tx.nonce)) {
            .pending => &pending,
            .queued => &queued,
        };

        switch (shape) {
            .content => try appendContentTx(allocator, section, tx),
            .inspect => try appendInspectTx(allocator, section, tx),
        }
    }

    var obj = std.json.ObjectMap.init(allocator);
    try putOwnedJson(&obj, allocator, "pending", .{ .object = pending });
    try putOwnedJson(&obj, allocator, "queued", .{ .object = queued });
    return .{ .object = obj };
}

fn poolEntriesFrom(
    allocator: std.mem.Allocator,
    rt: *const runtime.NodeRuntime,
    shape: EntryShape,
    sender: primitives.Address,
) !std.json.Value {
    var pending = std.json.ObjectMap.init(allocator);
    var queued = std.json.ObjectMap.init(allocator);

    for (rt.pool.items()) |tx| {
        if (!std.mem.eql(u8, &tx.sender.bytes, &sender.bytes)) continue;
        const section = switch (rt.pool.statusOf(tx.sender, tx.nonce)) {
            .pending => &pending,
            .queued => &queued,
        };

        switch (shape) {
            .content => try appendContentTx(allocator, section, tx),
            .inspect => try appendInspectTx(allocator, section, tx),
        }
    }

    var obj = std.json.ObjectMap.init(allocator);
    try putOwnedJson(&obj, allocator, "pending", .{ .object = pending });
    try putOwnedJson(&obj, allocator, "queued", .{ .object = queued });
    return .{ .object = obj };
}

fn appendContentTx(
    allocator: std.mem.Allocator,
    section: *std.json.ObjectMap,
    tx: txpool_mod.PooledTransaction,
) !void {
    var sender_buf: [42]u8 = undefined;
    const sender_key = checksumAddressHex(&sender_buf, tx.sender);
    const account = try getOrCreateAccount(allocator, section, sender_key);
    try putJsonOwnedKey(account, allocator, try decimalKey(allocator, tx.nonce), try transactionObject(allocator, tx));
}

fn appendInspectTx(
    allocator: std.mem.Allocator,
    section: *std.json.ObjectMap,
    tx: txpool_mod.PooledTransaction,
) !void {
    var sender_buf: [42]u8 = undefined;
    const sender_key = checksumAddressHex(&sender_buf, tx.sender);
    const account = try getOrCreateAccount(allocator, section, sender_key);
    try putJsonOwnedKey(account, allocator, try decimalKey(allocator, tx.nonce), .{
        .string = try inspectSummary(allocator, tx),
    });
}

fn transactionObject(allocator: std.mem.Allocator, tx: txpool_mod.PooledTransaction) !std.json.Value {
    if (tx.raw.len != 0) {
        var decoded = tx_encoding.decodeEnvelope(allocator, tx.raw) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return fallbackTransactionObject(allocator, tx),
        };
        defer decoded.deinit(allocator);
        return decodedTransactionObject(allocator, tx, decoded);
    }
    return fallbackTransactionObject(allocator, tx);
}

fn fallbackTransactionObject(allocator: std.mem.Allocator, tx: txpool_mod.PooledTransaction) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    try putCommonTransactionFields(&obj, allocator, tx, tx.nonce, tx.gas_limit, tx.to, tx.value, tx.input, 0);
    try putOwnedJson(&obj, allocator, "gasPrice", .{ .string = try quantityHex(allocator, tx.max_fee_per_gas) });
    if (tx.v != 0) try putOwnedJson(&obj, allocator, "v", .{ .string = try quantityHex(allocator, tx.v) });
    if (!std.mem.allEqual(u8, &tx.r, 0)) try putOwnedJson(&obj, allocator, "r", .{ .string = try quantityHex(allocator, tx_encoding.bytes32ToU256(tx.r)) });
    if (!std.mem.allEqual(u8, &tx.s, 0)) try putOwnedJson(&obj, allocator, "s", .{ .string = try quantityHex(allocator, tx_encoding.bytes32ToU256(tx.s)) });
    return .{ .object = obj };
}

fn decodedTransactionObject(
    allocator: std.mem.Allocator,
    pooled: txpool_mod.PooledTransaction,
    decoded: tx_encoding.DecodedEnvelope,
) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    switch (decoded) {
        .legacy => |tx| {
            try putCommonTransactionFields(&obj, allocator, pooled, tx.nonce, tx.gas_limit, tx.to, tx.value, tx.data, 0);
            try putOwnedJson(&obj, allocator, "gasPrice", .{ .string = try quantityHex(allocator, tx.gas_price) });
            if (tx_encoding.legacyChainId(tx)) |chain_id| try putOwnedJson(&obj, allocator, "chainId", .{ .string = try quantityHex(allocator, chain_id) });
            try putOwnedJson(&obj, allocator, "v", .{ .string = try quantityHex(allocator, tx.v) });
            try putOwnedJson(&obj, allocator, "r", .{ .string = try quantityHex(allocator, tx_encoding.bytes32ToU256(tx.r)) });
            try putOwnedJson(&obj, allocator, "s", .{ .string = try quantityHex(allocator, tx_encoding.bytes32ToU256(tx.s)) });
        },
        .eip2930 => |tx| {
            try putCommonTransactionFields(&obj, allocator, pooled, tx.nonce, tx.gas_limit, tx.to, tx.value, tx.data, 1);
            try putOwnedJson(&obj, allocator, "gasPrice", .{ .string = try quantityHex(allocator, tx.gas_price) });
            try putOwnedJson(&obj, allocator, "chainId", .{ .string = try quantityHex(allocator, tx.chain_id) });
            try putOwnedJson(&obj, allocator, "accessList", try accessListValue(allocator, tx.access_list));
            try putOwnedJson(&obj, allocator, "yParity", .{ .string = try quantityHex(allocator, tx.y_parity) });
            try putOwnedJson(&obj, allocator, "v", .{ .string = try quantityHex(allocator, tx.y_parity) });
            try putOwnedJson(&obj, allocator, "r", .{ .string = try quantityHex(allocator, tx_encoding.bytes32ToU256(tx.r)) });
            try putOwnedJson(&obj, allocator, "s", .{ .string = try quantityHex(allocator, tx_encoding.bytes32ToU256(tx.s)) });
        },
        .eip1559 => |tx| {
            try putCommonTransactionFields(&obj, allocator, pooled, tx.nonce, tx.gas_limit, tx.to, tx.value, tx.data, 2);
            try putOwnedJson(&obj, allocator, "gasPrice", .{ .string = try quantityHex(allocator, tx.max_fee_per_gas) });
            try putDynamicFeeFields(&obj, allocator, tx.chain_id, tx.max_priority_fee_per_gas, tx.max_fee_per_gas, tx.access_list, tx.y_parity, tx.r, tx.s);
        },
        .eip4844 => |tx| {
            try putCommonTransactionFields(&obj, allocator, pooled, tx.nonce, tx.gas_limit, tx.to, tx.value, tx.data, 3);
            try putOwnedJson(&obj, allocator, "gasPrice", .{ .string = try quantityHex(allocator, tx.max_fee_per_gas) });
            try putDynamicFeeFields(&obj, allocator, tx.chain_id, tx.max_priority_fee_per_gas, tx.max_fee_per_gas, tx.access_list, tx.y_parity, tx.r, tx.s);
            try putOwnedJson(&obj, allocator, "maxFeePerBlobGas", .{ .string = try quantityHex(allocator, tx.max_fee_per_blob_gas) });
            try putOwnedJson(&obj, allocator, "blobVersionedHashes", try blobVersionedHashesValue(allocator, tx.blob_versioned_hashes));
        },
        .eip7702 => |tx| {
            try putCommonTransactionFields(&obj, allocator, pooled, tx.nonce, tx.gas_limit, tx.to, tx.value, tx.data, 4);
            try putOwnedJson(&obj, allocator, "gasPrice", .{ .string = try quantityHex(allocator, tx.max_fee_per_gas) });
            try putDynamicFeeFields(&obj, allocator, tx.chain_id, tx.max_priority_fee_per_gas, tx.max_fee_per_gas, tx.access_list, tx.y_parity, tx.r, tx.s);
            try putOwnedJson(&obj, allocator, "authorizationList", try authorizationListValue(allocator, tx.authorization_list));
        },
    }
    return .{ .object = obj };
}

fn putCommonTransactionFields(
    obj: *std.json.ObjectMap,
    allocator: std.mem.Allocator,
    pooled: txpool_mod.PooledTransaction,
    nonce: u64,
    gas_limit: u64,
    to: ?primitives.Address,
    value: u256,
    input: []const u8,
    type_field: u8,
) !void {
    try putOwnedJson(obj, allocator, "blockHash", .null);
    try putOwnedJson(obj, allocator, "blockNumber", .null);
    try putOwnedJson(obj, allocator, "blockTimestamp", .null);
    try putOwnedJson(obj, allocator, "from", .{ .string = try addressString(allocator, pooled.sender) });
    try putOwnedJson(obj, allocator, "gas", .{ .string = try quantityHex(allocator, gas_limit) });
    try putOwnedJson(obj, allocator, "hash", .{ .string = try hashString(allocator, pooled.hash) });
    try putOwnedJson(obj, allocator, "input", .{ .string = try bytesHex(allocator, input) });
    try putOwnedJson(obj, allocator, "nonce", .{ .string = try quantityHex(allocator, nonce) });
    if (to) |addr| {
        try putOwnedJson(obj, allocator, "to", .{ .string = try addressString(allocator, addr) });
    } else {
        try putOwnedJson(obj, allocator, "to", .null);
    }
    try putOwnedJson(obj, allocator, "transactionIndex", .null);
    try putOwnedJson(obj, allocator, "type", .{ .string = try quantityHex(allocator, type_field) });
    try putOwnedJson(obj, allocator, "value", .{ .string = try quantityHex(allocator, value) });
}

fn putDynamicFeeFields(
    obj: *std.json.ObjectMap,
    allocator: std.mem.Allocator,
    chain_id: u64,
    max_priority_fee_per_gas: u256,
    max_fee_per_gas: u256,
    access_list: []const primitives.Transaction.AccessListItem,
    y_parity: u8,
    r: [32]u8,
    s: [32]u8,
) !void {
    try putOwnedJson(obj, allocator, "maxPriorityFeePerGas", .{ .string = try quantityHex(allocator, max_priority_fee_per_gas) });
    try putOwnedJson(obj, allocator, "maxFeePerGas", .{ .string = try quantityHex(allocator, max_fee_per_gas) });
    try putOwnedJson(obj, allocator, "chainId", .{ .string = try quantityHex(allocator, chain_id) });
    try putOwnedJson(obj, allocator, "accessList", try accessListValue(allocator, access_list));
    try putOwnedJson(obj, allocator, "yParity", .{ .string = try quantityHex(allocator, y_parity) });
    try putOwnedJson(obj, allocator, "v", .{ .string = try quantityHex(allocator, y_parity) });
    try putOwnedJson(obj, allocator, "r", .{ .string = try quantityHex(allocator, tx_encoding.bytes32ToU256(r)) });
    try putOwnedJson(obj, allocator, "s", .{ .string = try quantityHex(allocator, tx_encoding.bytes32ToU256(s)) });
}

fn accessListValue(
    allocator: std.mem.Allocator,
    access_list: []const primitives.Transaction.AccessListItem,
) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (access_list) |entry| {
        var obj = std.json.ObjectMap.init(allocator);
        try putOwnedJson(&obj, allocator, "address", .{ .string = try addressString(allocator, entry.address) });
        try putOwnedJson(&obj, allocator, "storageKeys", try hashArrayValue(allocator, entry.storage_keys));
        try array.append(.{ .object = obj });
    }
    return .{ .array = array };
}

fn authorizationListValue(
    allocator: std.mem.Allocator,
    authorization_list: []const primitives.Authorization.Authorization,
) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (authorization_list) |entry| {
        var obj = std.json.ObjectMap.init(allocator);
        try putOwnedJson(&obj, allocator, "chainId", .{ .string = try quantityHex(allocator, entry.chain_id) });
        try putOwnedJson(&obj, allocator, "address", .{ .string = try addressString(allocator, entry.address) });
        try putOwnedJson(&obj, allocator, "nonce", .{ .string = try quantityHex(allocator, entry.nonce) });
        try putOwnedJson(&obj, allocator, "yParity", .{ .string = try quantityHex(allocator, entry.v) });
        try putOwnedJson(&obj, allocator, "r", .{ .string = try quantityHex(allocator, tx_encoding.bytes32ToU256(entry.r)) });
        try putOwnedJson(&obj, allocator, "s", .{ .string = try quantityHex(allocator, tx_encoding.bytes32ToU256(entry.s)) });
        try array.append(.{ .object = obj });
    }
    return .{ .array = array };
}

fn blobVersionedHashesValue(
    allocator: std.mem.Allocator,
    hashes: []const primitives.Blob.VersionedHash,
) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (hashes) |hash| {
        try array.append(.{ .string = try hashString(allocator, hash.bytes) });
    }
    return .{ .array = array };
}

fn hashArrayValue(allocator: std.mem.Allocator, hashes: []const [32]u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (hashes) |hash| {
        try array.append(.{ .string = try hashString(allocator, hash) });
    }
    return .{ .array = array };
}

fn inspectSummary(allocator: std.mem.Allocator, tx: txpool_mod.PooledTransaction) ![]u8 {
    if (tx.to) |to| {
        var to_buf: [42]u8 = undefined;
        return std.fmt.allocPrint(allocator, "{s}: {d} wei + {d} gas x {d} wei", .{
            checksumAddressHex(&to_buf, to),
            tx.value,
            tx.gas_limit,
            tx.max_fee_per_gas,
        });
    }

    return std.fmt.allocPrint(allocator, "contract creation: {d} wei + {d} gas x {d} wei", .{
        tx.value,
        tx.gas_limit,
        tx.max_fee_per_gas,
    });
}

fn getOrCreateAccount(
    allocator: std.mem.Allocator,
    section: *std.json.ObjectMap,
    key: []const u8,
) !*std.json.ObjectMap {
    if (section.getPtr(key)) |value| {
        return switch (value.*) {
            .object => |*obj| obj,
            else => error.InvalidTxpoolShape,
        };
    }

    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    try section.put(owned_key, .{ .object = std.json.ObjectMap.init(allocator) });

    const inserted = section.getPtr(key) orelse return error.InvalidTxpoolShape;
    return switch (inserted.*) {
        .object => |*obj| obj,
        else => error.InvalidTxpoolShape,
    };
}

fn validateNoParams(params: ?std.json.Value) !void {
    const value = params orelse return;
    switch (value) {
        .array => |array| {
            if (array.items.len != 0) return error.InvalidParams;
        },
        else => return error.InvalidParams,
    }
}

fn parseSingleAddressArg(params: ?std.json.Value) !primitives.Address {
    const value = params orelse return error.InvalidParams;
    const items = switch (value) {
        .array => |array| array.items,
        else => return error.InvalidParams,
    };
    if (items.len != 1) return error.InvalidParams;
    const text = switch (items[0]) {
        .string => |s| s,
        else => return error.InvalidParams,
    };
    if (text.len != 42 or text[0] != '0' or text[1] != 'x') return error.InvalidParams;
    var bytes: [20]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, text[2..]) catch return error.InvalidParams;
    return .{ .bytes = bytes };
}

fn putOwnedJson(
    obj: *std.json.ObjectMap,
    allocator: std.mem.Allocator,
    key: []const u8,
    value: std.json.Value,
) !void {
    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    try obj.put(owned_key, value);
}

fn putJsonOwnedKey(
    obj: *std.json.ObjectMap,
    allocator: std.mem.Allocator,
    key: []const u8,
    value: std.json.Value,
) !void {
    errdefer allocator.free(key);
    try obj.put(key, value);
}

fn decimalKey(allocator: std.mem.Allocator, nonce: u64) ![]u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{nonce});
}

fn quantityHex(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return std.fmt.allocPrint(allocator, "0x{x}", .{value});
}

fn addressString(allocator: std.mem.Allocator, address: primitives.Address) ![]u8 {
    var buf: [42]u8 = undefined;
    return allocator.dupe(u8, checksumAddressHex(&buf, address));
}

fn hashString(allocator: std.mem.Allocator, hash: [32]u8) ![]u8 {
    var buf: [66]u8 = undefined;
    return allocator.dupe(u8, hashHex(&buf, hash));
}

fn bytesHex(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, 2 + bytes.len * 2);
    out[0] = '0';
    out[1] = 'x';
    const alphabet = "0123456789abcdef";
    for (bytes, 0..) |byte, index| {
        out[2 + index * 2] = alphabet[byte >> 4];
        out[3 + index * 2] = alphabet[byte & 0x0f];
    }
    return out;
}

fn addressHex(buf: *[42]u8, address: primitives.Address) []const u8 {
    buf[0] = '0';
    buf[1] = 'x';
    const hex = std.fmt.bytesToHex(&address.bytes, .lower);
    @memcpy(buf[2..], &hex);
    return buf[0..];
}

fn checksumAddressHex(buf: *[42]u8, address: primitives.Address) []const u8 {
    _ = addressHex(buf, address);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(buf[2..42], &digest, .{});
    for (buf[2..42], 0..) |*char, i| {
        if (char.* < 'a' or char.* > 'f') continue;
        const nibble = if ((i % 2) == 0)
            digest[i / 2] >> 4
        else
            digest[i / 2] & 0x0f;
        if (nibble >= 8) {
            char.* -= 'a' - 'A';
        }
    }
    return buf[0..];
}

fn hashHex(buf: *[66]u8, hash: [32]u8) []const u8 {
    buf[0] = '0';
    buf[1] = 'x';
    const hex = std.fmt.bytesToHex(&hash, .lower);
    @memcpy(buf[2..], &hex);
    return buf[0..];
}
