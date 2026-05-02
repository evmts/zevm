const std = @import("std");
const jsonrpc = @import("jsonrpc");
const primitives = @import("primitives");

pub const LightBlockSelector = union(enum) {
    latest,
    earliest,
    pending,
    safe,
    finalized,
    number: u64,
};

pub fn paramsArrayItems(params: ?std.json.Value) ![]const std.json.Value {
    const value = params orelse return error.InvalidParams;
    return switch (value) {
        .array => |array| array.items,
        else => error.InvalidParams,
    };
}

pub fn hasHexPrefix(text: []const u8) bool {
    return text.len >= 2 and text[0] == '0' and text[1] == 'x';
}

pub fn isQuantityHex(text: []const u8) bool {
    if (text.len <= 2) return false;
    if (!hasHexPrefix(text)) return false;
    if (text.len > 3 and text[2] == '0') return false;
    for (text[2..]) |c| {
        _ = std.fmt.charToDigit(c, 16) catch return false;
    }
    return true;
}

pub fn parseQuantityString(comptime T: type, text: []const u8) !T {
    if (!isQuantityHex(text)) return error.InvalidParams;
    return std.fmt.parseInt(T, text[2..], 16) catch error.InvalidParams;
}

pub fn parseQuantityValue(comptime T: type, value: std.json.Value) !T {
    return switch (value) {
        .string => |text| parseQuantityString(T, text),
        else => error.InvalidParams,
    };
}

pub fn parseQuantity(comptime T: type, quantity: jsonrpc.types.Quantity) !T {
    return parseQuantityValue(T, quantity.value);
}

pub fn validateQuantityValue(value: std.json.Value) !void {
    switch (value) {
        .string => |text| if (!isQuantityHex(text)) return error.InvalidParams,
        else => return error.InvalidParams,
    }
}

pub fn parseAddressString(text: []const u8) !primitives.Address {
    if (!hasHexPrefix(text)) return error.InvalidParams;
    const hex = text[2..];
    if (hex.len != 40) return error.InvalidParams;
    var bytes: [20]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, hex) catch return error.InvalidParams;
    return .{ .bytes = bytes };
}

pub fn parseAddressValue(value: std.json.Value) !primitives.Address {
    return switch (value) {
        .string => |text| parseAddressString(text),
        else => error.InvalidParams,
    };
}

pub fn isHash32(text: []const u8) bool {
    if (!hasHexPrefix(text)) return false;
    if (text.len != 66) return false;
    for (text[2..]) |c| {
        _ = std.fmt.charToDigit(c, 16) catch return false;
    }
    return true;
}

pub fn parseHash32String(text: []const u8) ![32]u8 {
    if (!isHash32(text)) return error.InvalidParams;
    var bytes: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, text[2..]) catch return error.InvalidParams;
    return bytes;
}

pub fn parseHash32Value(value: std.json.Value) ![32]u8 {
    return switch (value) {
        .string => |text| parseHash32String(text),
        else => error.InvalidParams,
    };
}

pub fn parseJsonRpcHash32Value(value: std.json.Value) !jsonrpc.types.Hash {
    return .{ .bytes = try parseHash32Value(value) };
}

pub fn validateHash32Value(value: std.json.Value) !void {
    _ = try parseHash32Value(value);
}

pub fn validateHexData(text: []const u8) !void {
    if (!hasHexPrefix(text)) return error.InvalidParams;
    const hex = text[2..];
    if (hex.len % 2 != 0) return error.InvalidParams;
    for (hex) |c| {
        _ = std.fmt.charToDigit(c, 16) catch return error.InvalidParams;
    }
}

pub fn validateHexDataValue(value: std.json.Value) !void {
    const text = switch (value) {
        .string => |s| s,
        else => return error.InvalidParams,
    };
    try validateHexData(text);
}

pub fn parseHexDataBytes(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    const text = switch (value) {
        .string => |s| s,
        else => return error.InvalidParams,
    };
    try validateHexData(text);
    const hex = text[2..];
    const out = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(out);
    _ = std.fmt.hexToBytes(out, hex) catch return error.InvalidParams;
    return out;
}

pub fn isBlockTagString(text: []const u8) bool {
    return std.mem.eql(u8, text, "latest") or
        std.mem.eql(u8, text, "earliest") or
        std.mem.eql(u8, text, "pending") or
        std.mem.eql(u8, text, "safe") or
        std.mem.eql(u8, text, "finalized");
}

pub fn isTrustedBlockSelectorString(text: []const u8) bool {
    return isBlockTagString(text) or isQuantityHex(text);
}

pub fn validateTrustedBlockSelectorValue(value: std.json.Value) !void {
    const text = switch (value) {
        .string => |s| s,
        else => return error.InvalidParams,
    };
    if (!isTrustedBlockSelectorString(text)) return error.InvalidParams;
}

pub fn resolveTrustedBlockSelector(head_block_number: u64, value: std.json.Value) !u64 {
    const text = switch (value) {
        .string => |s| s,
        else => return error.InvalidParams,
    };
    if (std.mem.eql(u8, text, "latest") or
        std.mem.eql(u8, text, "pending") or
        std.mem.eql(u8, text, "safe") or
        std.mem.eql(u8, text, "finalized"))
    {
        return head_block_number;
    }
    if (std.mem.eql(u8, text, "earliest")) return 0;
    return parseQuantityString(u64, text);
}

pub fn parseLightBlockSelectorValue(value: std.json.Value) !LightBlockSelector {
    const text = switch (value) {
        .string => |str| str,
        else => return error.InvalidParams,
    };
    if (std.mem.eql(u8, text, "latest")) return .latest;
    if (std.mem.eql(u8, text, "earliest")) return .earliest;
    if (std.mem.eql(u8, text, "pending")) return .pending;
    if (std.mem.eql(u8, text, "safe")) return .safe;
    if (std.mem.eql(u8, text, "finalized")) return .finalized;
    if (isQuantityHex(text)) return .{ .number = try parseQuantityString(u64, text) };
    return error.InvalidParams;
}

test "QuantityHex rejects numbers uppercase prefixes and non-minimal strings" {
    try std.testing.expectEqual(@as(u64, 0), try parseQuantityString(u64, "0x0"));
    try std.testing.expectEqual(@as(u64, 0x3B), try parseQuantityString(u64, "0x3B"));
    try std.testing.expectError(error.InvalidParams, parseQuantityString(u64, "0X1"));
    try std.testing.expectError(error.InvalidParams, parseQuantityString(u64, "0x01"));
    try std.testing.expectError(error.InvalidParams, parseQuantityValue(u64, .{ .integer = 1 }));
}

test "fixed-width hex parsers require lowercase 0x prefix" {
    const address = try parseAddressString("0x0000000000000000000000000000000000000001");
    try std.testing.expectEqual(@as(u8, 1), address.bytes[19]);
    try std.testing.expectError(error.InvalidParams, parseAddressString("0X0000000000000000000000000000000000000001"));
    try std.testing.expectError(error.InvalidParams, parseHash32String("0X0000000000000000000000000000000000000000000000000000000000000000"));
}

test "light selector parses pending separately from numeric selectors" {
    const pending = try parseLightBlockSelectorValue(.{ .string = "pending" });
    try std.testing.expect(std.meta.activeTag(pending) == .pending);
    const selector = try parseLightBlockSelectorValue(.{ .string = "0xa" });
    try std.testing.expectEqual(@as(u64, 10), selector.number);
    try std.testing.expectError(error.InvalidParams, parseLightBlockSelectorValue(.{ .string = "0x0a" }));
}
