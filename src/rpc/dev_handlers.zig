const std = @import("std");
const primitives = @import("primitives");
const state_manager = @import("state-manager");
const blockchain = @import("blockchain");
const dev_runtime = @import("dev_runtime.zig");

pub fn handleEvmSnapshot(
    allocator: std.mem.Allocator,
    runtime: *dev_runtime.DevRuntime,
    state: *state_manager.StateManager,
    block_number: u64,
) !std.json.Value {
    const snap_id = try runtime.takeSnapshot(allocator, state, block_number);
    var buf: [18]u8 = undefined;
    const hex = std.fmt.bufPrint(&buf, "0x{x}", .{snap_id}) catch unreachable;
    return .{ .string = try allocator.dupe(u8, hex) };
}

pub fn handleEvmRevert(
    allocator: std.mem.Allocator,
    runtime: *dev_runtime.DevRuntime,
    state: *state_manager.StateManager,
    bc: *blockchain.Blockchain,
    params: ?std.json.Value,
) !std.json.Value {
    const snapshot_id = parseSnapshotId(params) orelse return .{ .bool = false };
    const result = try runtime.revertSnapshot(allocator, state, bc, snapshot_id);
    return .{ .bool = result };
}

pub fn handleHardhatSetBalance(
    state: *state_manager.StateManager,
    params: ?std.json.Value,
) !std.json.Value {
    const items = getParamsArray(params) orelse return error.InvalidParams;
    if (items.len < 2) return error.InvalidParams;
    const addr = parseAddress(items[0]) orelse return error.InvalidParams;
    const balance = parseU256(items[1]) orelse return error.InvalidParams;
    try state.setBalance(addr, balance);
    return .{ .bool = true };
}

pub fn handleHardhatSetCode(
    allocator: std.mem.Allocator,
    state: *state_manager.StateManager,
    params: ?std.json.Value,
) !std.json.Value {
    const items = getParamsArray(params) orelse return error.InvalidParams;
    if (items.len < 2) return error.InvalidParams;
    const addr = parseAddress(items[0]) orelse return error.InvalidParams;
    const code = parseHexBytes(allocator, items[1]) orelse return error.InvalidParams;
    defer allocator.free(code);
    try state.setCode(addr, code);
    return .{ .bool = true };
}

pub fn handleHardhatSetNonce(
    state: *state_manager.StateManager,
    params: ?std.json.Value,
) !std.json.Value {
    const items = getParamsArray(params) orelse return error.InvalidParams;
    if (items.len < 2) return error.InvalidParams;
    const addr = parseAddress(items[0]) orelse return error.InvalidParams;
    const nonce = parseU64(items[1]) orelse return error.InvalidParams;
    try state.setNonce(addr, nonce);
    return .{ .bool = true };
}

pub fn handleHardhatSetStorageAt(
    state: *state_manager.StateManager,
    params: ?std.json.Value,
) !std.json.Value {
    const items = getParamsArray(params) orelse return error.InvalidParams;
    if (items.len < 3) return error.InvalidParams;
    const addr = parseAddress(items[0]) orelse return error.InvalidParams;
    const slot = parseU256(items[1]) orelse return error.InvalidParams;
    const value = parseU256(items[2]) orelse return error.InvalidParams;
    try state.setStorage(addr, slot, value);
    return .{ .bool = true };
}

pub fn handleHardhatSetCoinbase(
    runtime: *dev_runtime.DevRuntime,
    params: ?std.json.Value,
) !std.json.Value {
    const items = getParamsArray(params) orelse return error.InvalidParams;
    if (items.len < 1) return error.InvalidParams;
    const addr = parseAddress(items[0]) orelse return error.InvalidParams;
    runtime.config.coinbase = addr;
    return .{ .bool = true };
}

pub fn handleHardhatSetNextBlockBaseFeePerGas(
    runtime: *dev_runtime.DevRuntime,
    params: ?std.json.Value,
) !std.json.Value {
    const items = getParamsArray(params) orelse return error.InvalidParams;
    if (items.len < 1) return error.InvalidParams;
    const fee = parseU256(items[0]) orelse return error.InvalidParams;
    runtime.config.next_block_base_fee_per_gas = fee;
    return .{ .bool = true };
}

pub fn handleEvmSetBlockGasLimit(
    runtime: *dev_runtime.DevRuntime,
    params: ?std.json.Value,
) !std.json.Value {
    const items = getParamsArray(params) orelse return error.InvalidParams;
    if (items.len < 1) return error.InvalidParams;
    const limit = parseU64(items[0]) orelse return error.InvalidParams;
    runtime.config.block_gas_limit = limit;
    return .{ .bool = true };
}

fn getParamsArray(params: ?std.json.Value) ?[]const std.json.Value {
    const p = params orelse return null;
    return switch (p) {
        .array => |arr| arr.items,
        else => null,
    };
}

fn parseAddress(value: std.json.Value) ?primitives.Address.Address {
    const s = switch (value) {
        .string => |str| str,
        else => return null,
    };
    if (s.len != 42) return null;
    if (s[0] != '0' or (s[1] != 'x' and s[1] != 'X')) return null;
    var out: [20]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s[2..]) catch return null;
    return .{ .bytes = out };
}

fn parseU256(value: std.json.Value) ?u256 {
    const s = switch (value) {
        .string => |str| str,
        .integer => |i| return @intCast(@as(u256, @bitCast(@as(i256, i)))),
        else => return null,
    };
    return parseHexU256(s);
}

fn parseU64(value: std.json.Value) ?u64 {
    const v = parseU256(value) orelse return null;
    if (v > std.math.maxInt(u64)) return null;
    return @intCast(v);
}

fn parseHexU256(s: []const u8) ?u256 {
    var hex = s;
    if (hex.len >= 2 and hex[0] == '0' and (hex[1] == 'x' or hex[1] == 'X')) {
        hex = hex[2..];
    }
    if (hex.len == 0) return 0;
    if (hex.len > 64) return null;
    var result: u256 = 0;
    for (hex) |c| {
        const digit: u256 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return null,
        };
        result = result *% 16 +% digit;
    }
    return result;
}

fn parseHexBytes(allocator: std.mem.Allocator, value: std.json.Value) ?[]const u8 {
    const s = switch (value) {
        .string => |str| str,
        else => return null,
    };
    var hex = s;
    if (hex.len >= 2 and hex[0] == '0' and (hex[1] == 'x' or hex[1] == 'X')) {
        hex = hex[2..];
    }
    if (hex.len == 0) return allocator.alloc(u8, 0) catch null;
    if (hex.len % 2 != 0) return null;
    const out = allocator.alloc(u8, hex.len / 2) catch return null;
    _ = std.fmt.hexToBytes(out, hex) catch {
        allocator.free(out);
        return null;
    };
    return out;
}

fn parseSnapshotId(params: ?std.json.Value) ?u64 {
    const items = getParamsArray(params) orelse return null;
    if (items.len < 1) return null;
    return parseU64(items[0]);
}

// ============================================================================
// Tests
// ============================================================================

test "handleEvmSnapshot returns quantity-encoded snapshot id" {
    const allocator = std.testing.allocator;
    var runtime = dev_runtime.DevRuntime.init();
    defer runtime.deinit(allocator);

    var state = try state_manager.StateManager.init(allocator, null);
    defer state.deinit();

    const result = try handleEvmSnapshot(allocator, &runtime, &state, 10);
    defer allocator.free(result.string);

    try std.testing.expect(std.mem.startsWith(u8, result.string, "0x"));
}

test "handleEvmRevert returns true and rolls state back on valid id" {
    const allocator = std.testing.allocator;
    var runtime = dev_runtime.DevRuntime.init();
    defer runtime.deinit(allocator);

    var state = try state_manager.StateManager.init(allocator, null);
    defer state.deinit();

    var bc = try blockchain.Blockchain.init(allocator, null);
    defer bc.deinit();

    const addr = primitives.Address.Address{ .bytes = [_]u8{0x11} ++ [_]u8{0} ** 19 };
    try state.setBalance(addr, 1000);

    const snap_result = try handleEvmSnapshot(allocator, &runtime, &state, 0);
    defer allocator.free(snap_result.string);

    try state.setBalance(addr, 2000);
    const balance_before = try state.getBalance(addr);
    try std.testing.expectEqual(@as(u256, 2000), balance_before);

    var arr = std.json.Array.init(allocator);
    defer arr.deinit();
    try arr.append(.{ .string = "0x1" });
    const revert_result = try handleEvmRevert(allocator, &runtime, &state, &bc, .{ .array = arr });
    try std.testing.expect(revert_result.bool);

    const balance_after = try state.getBalance(addr);
    try std.testing.expectEqual(@as(u256, 1000), balance_after);
}

test "handleEvmRevert returns false on invalid id" {
    const allocator = std.testing.allocator;
    var runtime = dev_runtime.DevRuntime.init();
    defer runtime.deinit(allocator);

    var state = try state_manager.StateManager.init(allocator, null);
    defer state.deinit();

    var bc = try blockchain.Blockchain.init(allocator, null);
    defer bc.deinit();

    var arr = std.json.Array.init(allocator);
    defer arr.deinit();
    try arr.append(.{ .string = "0x999" });
    const result = try handleEvmRevert(allocator, &runtime, &state, &bc, .{ .array = arr });
    try std.testing.expect(!result.bool);
}

test "hardhat_setBalance updates account balance immediately" {
    const allocator = std.testing.allocator;
    var state = try state_manager.StateManager.init(allocator, null);
    defer state.deinit();

    var arr = std.json.Array.init(allocator);
    defer arr.deinit();
    try arr.append(.{ .string = "0x0000000000000000000000000000000000000001" });
    try arr.append(.{ .string = "0x3e8" });
    const result = try handleHardhatSetBalance(&state, .{ .array = arr });
    try std.testing.expect(result.bool);

    const addr = primitives.Address.Address{ .bytes = [_]u8{0} ** 19 ++ [_]u8{0x01} };
    const balance = try state.getBalance(addr);
    try std.testing.expectEqual(@as(u256, 0x3e8), balance);
}

test "hardhat_setCode updates account code immediately" {
    const allocator = std.testing.allocator;
    var state = try state_manager.StateManager.init(allocator, null);
    defer state.deinit();

    var arr = std.json.Array.init(allocator);
    defer arr.deinit();
    try arr.append(.{ .string = "0x0000000000000000000000000000000000000001" });
    try arr.append(.{ .string = "0x6060" });
    const result = try handleHardhatSetCode(allocator, &state, .{ .array = arr });
    try std.testing.expect(result.bool);

    const addr = primitives.Address.Address{ .bytes = [_]u8{0} ** 19 ++ [_]u8{0x01} };
    const code = try state.getCode(addr);
    try std.testing.expectEqual(@as(usize, 2), code.len);
    try std.testing.expectEqual(@as(u8, 0x60), code[0]);
    try std.testing.expectEqual(@as(u8, 0x60), code[1]);
}

test "hardhat_setNonce updates account nonce immediately" {
    const allocator = std.testing.allocator;
    var state = try state_manager.StateManager.init(allocator, null);
    defer state.deinit();

    var arr = std.json.Array.init(allocator);
    defer arr.deinit();
    try arr.append(.{ .string = "0x0000000000000000000000000000000000000001" });
    try arr.append(.{ .string = "0x5" });
    const result = try handleHardhatSetNonce(&state, .{ .array = arr });
    try std.testing.expect(result.bool);

    const addr = primitives.Address.Address{ .bytes = [_]u8{0} ** 19 ++ [_]u8{0x01} };
    const nonce = try state.getNonce(addr);
    try std.testing.expectEqual(@as(u64, 5), nonce);
}

test "hardhat_setStorageAt updates storage slot immediately" {
    const allocator = std.testing.allocator;
    var state = try state_manager.StateManager.init(allocator, null);
    defer state.deinit();

    var arr = std.json.Array.init(allocator);
    defer arr.deinit();
    try arr.append(.{ .string = "0x0000000000000000000000000000000000000001" });
    try arr.append(.{ .string = "0x0" });
    try arr.append(.{ .string = "0xff" });
    const result = try handleHardhatSetStorageAt(&state, .{ .array = arr });
    try std.testing.expect(result.bool);

    const addr = primitives.Address.Address{ .bytes = [_]u8{0} ** 19 ++ [_]u8{0x01} };
    const value = try state.getStorage(addr, 0);
    try std.testing.expectEqual(@as(u256, 0xff), value);
}

test "hardhat_setCoinbase updates runtime coinbase" {
    const allocator = std.testing.allocator;
    var runtime = dev_runtime.DevRuntime.init();
    defer runtime.deinit(allocator);

    var arr = std.json.Array.init(allocator);
    defer arr.deinit();
    try arr.append(.{ .string = "0x0000000000000000000000000000000000000042" });
    const result = try handleHardhatSetCoinbase(&runtime, .{ .array = arr });
    try std.testing.expect(result.bool);
    try std.testing.expectEqual(@as(u8, 0x42), runtime.config.coinbase.bytes[19]);
}

test "hardhat_setNextBlockBaseFeePerGas updates next base fee" {
    const allocator = std.testing.allocator;
    var runtime = dev_runtime.DevRuntime.init();
    defer runtime.deinit(allocator);

    var arr = std.json.Array.init(allocator);
    defer arr.deinit();
    try arr.append(.{ .string = "0x3B9ACA00" });
    const result = try handleHardhatSetNextBlockBaseFeePerGas(&runtime, .{ .array = arr });
    try std.testing.expect(result.bool);
    try std.testing.expectEqual(@as(u256, 1_000_000_000), runtime.config.next_block_base_fee_per_gas.?);
}

test "evm_setBlockGasLimit updates next block gas limit" {
    const allocator = std.testing.allocator;
    var runtime = dev_runtime.DevRuntime.init();
    defer runtime.deinit(allocator);

    var arr = std.json.Array.init(allocator);
    defer arr.deinit();
    try arr.append(.{ .string = "0x1000000" });
    const result = try handleEvmSetBlockGasLimit(&runtime, .{ .array = arr });
    try std.testing.expect(result.bool);
    try std.testing.expectEqual(@as(u64, 0x1000000), runtime.config.block_gas_limit);
}
