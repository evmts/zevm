const std = @import("std");
const primitives = @import("primitives");
const runtime = @import("../../node/runtime.zig");
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
    var obj = std.json.ObjectMap.init(allocator);
    try putOwnedJson(&obj, allocator, "blockHash", .null);
    try putOwnedJson(&obj, allocator, "blockNumber", .null);
    try putOwnedJson(&obj, allocator, "from", .{ .string = try addressString(allocator, tx.sender) });
    try putOwnedJson(&obj, allocator, "gas", .{ .string = try quantityHex(allocator, tx.gas_limit) });
    try putOwnedJson(&obj, allocator, "gasPrice", .{ .string = try quantityHex(allocator, tx.max_fee_per_gas) });
    try putOwnedJson(&obj, allocator, "hash", .{ .string = try hashString(allocator, tx.hash) });
    try putOwnedJson(&obj, allocator, "input", .{ .string = try bytesHex(allocator, tx.input) });
    try putOwnedJson(&obj, allocator, "nonce", .{ .string = try quantityHex(allocator, tx.nonce) });
    if (tx.to) |to| {
        try putOwnedJson(&obj, allocator, "to", .{ .string = try addressString(allocator, to) });
    } else {
        try putOwnedJson(&obj, allocator, "to", .null);
    }
    try putOwnedJson(&obj, allocator, "transactionIndex", .null);
    try putOwnedJson(&obj, allocator, "type", .{ .string = try allocator.dupe(u8, "0x0") });
    try putOwnedJson(&obj, allocator, "value", .{ .string = try quantityHex(allocator, tx.value) });
    return .{ .object = obj };
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
