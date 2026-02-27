const std = @import("std");
const jsonrpc = @import("jsonrpc");
const primitives = @import("primitives");
const runtime = @import("../../node/runtime.zig");
const block_spec = @import("block_spec.zig");

fn quantityFromU64(n: u64) jsonrpc.types.Quantity {
    var buf: [18]u8 = undefined;
    const hex = std.fmt.bufPrint(&buf, "0x{x}", .{n}) catch unreachable;
    return .{ .value = .{ .string = hex } };
}

fn quantityFromU256(n: u256) jsonrpc.types.Quantity {
    var buf: [66]u8 = undefined;
    const hex = std.fmt.bufPrint(&buf, "0x{x}", .{n}) catch unreachable;
    return .{ .value = .{ .string = hex } };
}

fn hashToHex(bytes: [32]u8) [66]u8 {
    var buf: [66]u8 = undefined;
    buf[0] = '0';
    buf[1] = 'x';
    const hex = std.fmt.bytesToHex(&bytes, .lower);
    @memcpy(buf[2..], &hex);
    return buf;
}

pub fn handleEthChainId(
    _: std.mem.Allocator,
    rt: *const runtime.NodeRuntime,
    _: jsonrpc.eth.chainId.EthChainId.Params,
) !jsonrpc.eth.chainId.EthChainId.Result {
    return .{ .value = quantityFromU64(rt.chain_id) };
}

pub fn handleEthBlockNumber(
    _: std.mem.Allocator,
    rt: *const runtime.NodeRuntime,
    _: jsonrpc.eth.blockNumber.EthBlockNumber.Params,
) !jsonrpc.eth.blockNumber.EthBlockNumber.Result {
    return .{ .value = quantityFromU64(rt.head_block_number) };
}

pub fn handleEthGetBalance(
    _: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: jsonrpc.eth.getBalance.EthGetBalance.Params,
) !jsonrpc.eth.getBalance.EthGetBalance.Result {
    // Validate block spec (we only support latest state for now)
    _ = try block_spec.resolveBlockNumber(rt, params.block);
    const balance = try rt.state.getBalance(params.address.bytes);
    return .{ .value = quantityFromU256(balance) };
}

pub fn handleEthGetCode(
    _: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: jsonrpc.eth.getCode.EthGetCode.Params,
) !jsonrpc.eth.getCode.EthGetCode.Result {
    _ = try block_spec.resolveBlockNumber(rt, params.block);
    const code = try rt.state.getCode(params.address.bytes);
    if (code.len == 0) {
        return .{ .value = .{ .value = .{ .string = "0x" } } };
    }
    // Return hex-encoded code
    var buf = std.ArrayList(u8).init(rt.state.allocator);
    errdefer buf.deinit();
    try buf.appendSlice("0x");
    const hex = std.fmt.bytesToHex(code, .lower);
    try buf.appendSlice(&hex);
    return .{ .value = .{ .value = .{ .string = buf.items } } };
}

pub fn handleEthGetStorageAt(
    _: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: jsonrpc.eth.getStorageAt.EthGetStorageAt.Params,
) !jsonrpc.eth.getStorageAt.EthGetStorageAt.Result {
    _ = try block_spec.resolveBlockNumber(rt, params.block);

    // Parse slot from quantity
    const slot = parseQuantityToU256(params.storage_slot) catch return .{ .value = quantityFromU256(0) };
    const value = try rt.state.getStorage(params.address.bytes, slot);

    // Return as 32-byte padded hex
    var bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &bytes, value, .big);
    const hex_buf = hashToHex(bytes);
    return .{ .value = .{ .value = .{ .string = &hex_buf } } };
}

pub fn handleEthGetTransactionCount(
    _: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: jsonrpc.eth.getTransactionCount.EthGetTransactionCount.Params,
) !jsonrpc.eth.getTransactionCount.EthGetTransactionCount.Result {
    _ = try block_spec.resolveBlockNumber(rt, params.block);
    const nonce = try rt.state.getNonce(params.address.bytes);
    return .{ .value = quantityFromU64(nonce) };
}

pub fn handleEthCoinbase(
    _: std.mem.Allocator,
    rt: *const runtime.NodeRuntime,
    _: jsonrpc.eth.coinbase.EthCoinbase.Params,
) !jsonrpc.eth.coinbase.EthCoinbase.Result {
    return .{ .value = .{ .bytes = rt.coinbase } };
}

pub fn handleEthAccounts(
    allocator: std.mem.Allocator,
    _: *const runtime.NodeRuntime,
    _: jsonrpc.eth.accounts.EthAccounts.Params,
) !jsonrpc.eth.accounts.EthAccounts.Result {
    const addrs = try allocator.alloc(jsonrpc.types.Address, runtime.DEFAULT_DEV_ACCOUNTS.len);
    for (runtime.DEFAULT_DEV_ACCOUNTS, 0..) |addr, i| {
        addrs[i] = .{ .bytes = addr };
    }
    return .{ .value = addrs };
}

pub fn handleEthGasPrice(
    _: std.mem.Allocator,
    rt: *const runtime.NodeRuntime,
    _: jsonrpc.eth.gasPrice.EthGasPrice.Params,
) !jsonrpc.eth.gasPrice.EthGasPrice.Result {
    return .{ .value = quantityFromU256(rt.gas_price) };
}

pub fn handleEthMaxPriorityFeePerGas(
    _: std.mem.Allocator,
    rt: *const runtime.NodeRuntime,
    _: jsonrpc.eth.maxPriorityFeePerGas.EthMaxPriorityFeePerGas.Params,
) !jsonrpc.eth.maxPriorityFeePerGas.EthMaxPriorityFeePerGas.Result {
    return .{ .value = quantityFromU256(rt.max_priority_fee) };
}

pub fn handleEthBlobBaseFee(
    _: std.mem.Allocator,
    rt: *const runtime.NodeRuntime,
    _: jsonrpc.eth.blobBaseFee.EthBlobBaseFee.Params,
) !jsonrpc.eth.blobBaseFee.EthBlobBaseFee.Result {
    return .{ .value = quantityFromU256(rt.blob_base_fee) };
}

pub fn handleEthFeeHistory(
    allocator: std.mem.Allocator,
    rt: *const runtime.NodeRuntime,
    params: jsonrpc.eth.feeHistory.EthFeeHistory.Params,
) !jsonrpc.eth.feeHistory.EthFeeHistory.Result {
    const block_count = parseQuantityToU64(params.block_count) catch 1;
    const count: usize = @min(block_count, 1024);

    // base_fee_per_gas has count + 1 entries
    const base_fees = try allocator.alloc(jsonrpc.types.Quantity, count + 1);
    for (0..count + 1) |i| {
        _ = i;
        base_fees[i] = quantityFromU256(rt.base_fee);
    }

    const gas_ratios = try allocator.alloc(f64, count);
    for (0..count) |i| {
        gas_ratios[i] = 0.0;
    }

    const oldest: u64 = if (rt.head_block_number >= count)
        rt.head_block_number - count + 1
    else
        0;

    return .{
        .oldest_block = quantityFromU64(oldest),
        .base_fee_per_gas = base_fees,
        .gas_used_ratio = gas_ratios,
    };
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
