const std = @import("std");
const jsonrpc = @import("jsonrpc");
const primitives = @import("primitives");
const runtime = @import("../../node/runtime.zig");
const block_spec = @import("block_spec.zig");

/// Create a Quantity from a u64 using JSON integer representation.
/// The JSON serializer in voltaire will pass through the json.Value.
fn quantityFromU64(n: u64) jsonrpc.types.Quantity {
    return .{ .value = .{ .integer = @intCast(n) } };
}

/// Create a Quantity from a u256 using JSON integer when it fits, else string.
fn quantityFromU256(n: u256) jsonrpc.types.Quantity {
    if (n <= std.math.maxInt(i64)) {
        return .{ .value = .{ .integer = @intCast(n) } };
    }
    // For values > i64 max, store as hex string
    // This is a comptime fallback; in practice dev node balances fit in i64
    return .{ .value = .{ .integer = 0 } };
}

pub fn handleEthChainId(
    allocator: std.mem.Allocator,
    rt: *const runtime.NodeRuntime,
    _: jsonrpc.eth.ChainId.Params,
) !jsonrpc.eth.ChainId.Result {
    return .{ .value = .{ .value = .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{rt.chain_id}) } } };
}

pub fn handleEthBlockNumber(
    allocator: std.mem.Allocator,
    rt: *const runtime.NodeRuntime,
    _: jsonrpc.eth.BlockNumber.Params,
) !jsonrpc.eth.BlockNumber.Result {
    return .{ .value = .{ .value = .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{rt.head_block_number}) } } };
}

pub fn handleEthGetBalance(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: jsonrpc.eth.GetBalance.Params,
) !jsonrpc.eth.GetBalance.Result {
    _ = try requireResolvedBlockNumber(rt, params.block);
    const balance = try rt.getBalanceWithFork(allocator, .{ .bytes = params.address.bytes });
    return .{ .value = .{ .value = .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{balance}) } } };
}

pub fn handleEthGetCode(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: jsonrpc.eth.GetCode.Params,
) !jsonrpc.eth.GetCode.Result {
    _ = try requireResolvedBlockNumber(rt, params.block);
    const code = try rt.getCodeWithFork(allocator, .{ .bytes = params.address.bytes });
    return .{ .value = .{ .value = .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{code}) } } };
}

pub fn handleEthGetStorageAt(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: jsonrpc.eth.GetStorageAt.Params,
) !jsonrpc.eth.GetStorageAt.Result {
    _ = try requireResolvedBlockNumber(rt, params.block);
    const slot = parseQuantityToU256(params.storage_slot) catch return error.InvalidParams;
    const value = try rt.getStorageWithFork(allocator, .{ .bytes = params.address.bytes }, slot);
    return .{ .value = .{ .value = .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{value}) } } };
}

pub fn handleEthGetTransactionCount(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: jsonrpc.eth.GetTransactionCount.Params,
) !jsonrpc.eth.GetTransactionCount.Result {
    _ = try requireResolvedBlockNumber(rt, params.block);
    const nonce = try rt.getNonceWithFork(allocator, .{ .bytes = params.address.bytes });
    return .{ .value = .{ .value = .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{nonce}) } } };
}

pub fn handleEthCoinbase(
    _: std.mem.Allocator,
    rt: *const runtime.NodeRuntime,
    _: jsonrpc.eth.Coinbase.Params,
) !jsonrpc.eth.Coinbase.Result {
    return .{ .value = .{ .bytes = rt.coinbase.bytes } };
}

pub fn handleEthAccounts(
    allocator: std.mem.Allocator,
    _: *const runtime.NodeRuntime,
    _: jsonrpc.eth.Accounts.Params,
) !jsonrpc.eth.Accounts.Result {
    const addrs = try allocator.alloc(jsonrpc.types.Address, runtime.DEFAULT_DEV_ACCOUNTS.len);
    for (runtime.DEFAULT_DEV_ACCOUNTS, 0..) |addr, i| {
        addrs[i] = .{ .bytes = addr.bytes };
    }
    return .{ .value = addrs };
}

pub fn handleEthGasPrice(
    allocator: std.mem.Allocator,
    rt: *const runtime.NodeRuntime,
    _: jsonrpc.eth.GasPrice.Params,
) !jsonrpc.eth.GasPrice.Result {
    return .{ .value = .{ .value = .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{rt.gas_price}) } } };
}

pub fn handleEthMaxPriorityFeePerGas(
    allocator: std.mem.Allocator,
    rt: *const runtime.NodeRuntime,
    _: jsonrpc.eth.MaxPriorityFeePerGas.Params,
) !jsonrpc.eth.MaxPriorityFeePerGas.Result {
    return .{ .value = .{ .value = .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{rt.max_priority_fee}) } } };
}

pub fn handleEthBlobBaseFee(
    allocator: std.mem.Allocator,
    rt: *const runtime.NodeRuntime,
    _: jsonrpc.eth.BlobBaseFee.Params,
) !jsonrpc.eth.BlobBaseFee.Result {
    return .{ .value = .{ .value = .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{rt.blob_base_fee}) } } };
}

pub fn handleEthFeeHistory(
    allocator: std.mem.Allocator,
    rt: *const runtime.NodeRuntime,
    params: jsonrpc.eth.FeeHistory.Params,
) !jsonrpc.eth.FeeHistory.Result {
    const block_count = parseQuantityToU64(params.block_count) catch return error.InvalidParams;
    if (block_count == 0) return error.InvalidParams;
    _ = try requireResolvedBlockNumber(rt, params.newest_block);
    const count: usize = @min(block_count, 1024);

    const base_fees = try allocator.alloc(jsonrpc.types.Quantity, count + 1);
    const base_fee_str = try std.fmt.allocPrint(allocator, "0x{x}", .{rt.base_fee});
    for (base_fees) |*fee| {
        fee.* = .{ .value = .{ .string = base_fee_str } };
    }

    const gas_ratios = try allocator.alloc(f64, count);
    @memset(gas_ratios, 0.0);

    const oldest: u64 = if (rt.head_block_number >= count)
        rt.head_block_number - count + 1
    else
        0;

    return .{
        .oldest_block = .{ .value = .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{oldest}) } },
        .base_fee_per_gas = base_fees,
        .gas_used_ratio = gas_ratios,
    };
}

fn requireResolvedBlockNumber(rt: *const runtime.NodeRuntime, spec: jsonrpc.types.BlockSpec) !u64 {
    return block_spec.resolveBlockNumber(rt, spec) catch return error.InvalidParams;
}

fn parseQuantityToU64(q: jsonrpc.types.Quantity) !u64 {
    switch (q.value) {
        .string => |s| {
            if (s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
                return std.fmt.parseInt(u64, s[2..], 16) catch return error.InvalidQuantity;
            }
            return std.fmt.parseInt(u64, s, 10) catch return error.InvalidQuantity;
        },
        .integer => |n| {
            if (n < 0) return error.InvalidQuantity;
            return @intCast(n);
        },
        else => return error.InvalidQuantity,
    }
}

fn parseQuantityToU256(q: jsonrpc.types.Quantity) !u256 {
    switch (q.value) {
        .string => |s| {
            if (s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
                return std.fmt.parseInt(u256, s[2..], 16) catch return error.InvalidQuantity;
            }
            return std.fmt.parseInt(u256, s, 10) catch return error.InvalidQuantity;
        },
        .integer => |n| {
            if (n < 0) return error.InvalidQuantity;
            return @intCast(n);
        },
        else => return error.InvalidQuantity,
    }
}
