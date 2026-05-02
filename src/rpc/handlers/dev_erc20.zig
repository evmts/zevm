const std = @import("std");
const primitives = @import("primitives");
const runtime = @import("../../node/runtime.zig");
const rpc_parse = @import("../parse.zig");

pub fn handleDealErc20(
    rt: *runtime.NodeRuntime,
    params: ?std.json.Value,
) !std.json.Value {
    const args = try parseBalanceArgs(params);
    try rt.setStorage(args.token, balanceSlot(args.holder), args.value);
    return .{ .bool = true };
}

pub fn handleSetErc20Allowance(
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
    return rpc_parse.paramsArrayItems(params);
}

fn parseAddressJson(value: std.json.Value) !primitives.Address {
    return rpc_parse.parseAddressValue(value);
}

fn parseAddressString(text: []const u8) !primitives.Address {
    return rpc_parse.parseAddressString(text);
}

fn parseU256Json(value: std.json.Value) !u256 {
    return rpc_parse.parseQuantityValue(u256, value);
}

fn parseU256String(text: []const u8) !u256 {
    return rpc_parse.parseQuantityString(u256, text);
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
    return rpc_parse.hasHexPrefix(text);
}

fn isQuantityHex(text: []const u8) bool {
    return rpc_parse.isQuantityHex(text);
}
