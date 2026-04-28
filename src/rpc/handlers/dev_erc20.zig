const std = @import("std");
const primitives = @import("primitives");
const runtime = @import("../../node/runtime.zig");

pub fn handleSetERC20Balance(
    rt: *runtime.NodeRuntime,
    params: ?std.json.Value,
) !std.json.Value {
    const args = try parseBalanceArgs(params);
    try rt.setStorage(args.token, balanceSlot(args.holder), args.value);
    return .{ .bool = true };
}

pub fn handleSetERC20Allowance(
    rt: *runtime.NodeRuntime,
    params: ?std.json.Value,
) !std.json.Value {
    const args = try parseAllowanceArgs(params);
    try rt.setStorage(args.token, allowanceSlot(args.owner, args.spender), args.value);
    return .{ .bool = true };
}

pub fn balanceSlot(holder: primitives.Address) u256 {
    return mappingSlot(holder, 0);
}

pub fn allowanceSlot(owner: primitives.Address, spender: primitives.Address) u256 {
    return mappingSlot(spender, mappingSlot(owner, 1));
}

const BalanceArgs = struct {
    token: primitives.Address,
    holder: primitives.Address,
    value: u256,
};

const AllowanceArgs = struct {
    token: primitives.Address,
    owner: primitives.Address,
    spender: primitives.Address,
    value: u256,
};

fn parseBalanceArgs(params: ?std.json.Value) !BalanceArgs {
    const items = try paramsArrayItems(params);
    if (items.len != 3) return error.InvalidParams;
    return .{
        .token = try parseAddressJson(items[0]),
        .holder = try parseAddressJson(items[1]),
        .value = try parseU256Json(items[2]),
    };
}

fn parseAllowanceArgs(params: ?std.json.Value) !AllowanceArgs {
    const items = try paramsArrayItems(params);
    if (items.len != 4) return error.InvalidParams;
    return .{
        .token = try parseAddressJson(items[0]),
        .owner = try parseAddressJson(items[1]),
        .spender = try parseAddressJson(items[2]),
        .value = try parseU256Json(items[3]),
    };
}

fn paramsArrayItems(params: ?std.json.Value) ![]const std.json.Value {
    const value = params orelse return error.InvalidParams;
    return switch (value) {
        .array => |array| array.items,
        else => error.InvalidParams,
    };
}

fn parseAddressJson(value: std.json.Value) !primitives.Address {
    return switch (value) {
        .string => |s| parseAddressString(s),
        else => error.InvalidParams,
    };
}

fn parseAddressString(text: []const u8) !primitives.Address {
    if (!hasHexPrefix(text)) return error.InvalidParams;
    const hex = text[2..];
    if (hex.len != 40) return error.InvalidParams;
    var bytes: [20]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, hex) catch return error.InvalidParams;
    return .{ .bytes = bytes };
}

fn parseU256Json(value: std.json.Value) !u256 {
    return switch (value) {
        .integer => |n| if (n < 0) error.InvalidParams else @intCast(n),
        .string => |s| parseU256String(s),
        else => error.InvalidParams,
    };
}

fn parseU256String(text: []const u8) !u256 {
    if (!isQuantityHex(text)) return error.InvalidParams;
    return std.fmt.parseInt(u256, text[2..], 16) catch error.InvalidParams;
}

fn mappingSlot(key: primitives.Address, slot: u256) u256 {
    var input = [_]u8{0} ** 64;
    @memcpy(input[12..32], &key.bytes);
    std.mem.writeInt(u256, input[32..64], slot, .big);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(&input, &digest, .{});
    return std.mem.readInt(u256, &digest, .big);
}

fn hasHexPrefix(text: []const u8) bool {
    return text.len >= 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X');
}

fn isQuantityHex(text: []const u8) bool {
    return text.len > 2 and hasHexPrefix(text);
}
