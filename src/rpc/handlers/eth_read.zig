const std = @import("std");
const builtin = @import("builtin");
const jsonrpc = @import("jsonrpc");
const primitives = @import("primitives");
const runtime = @import("../../node/runtime.zig");
const block_spec = @import("block_spec.zig");

pub const PRUNED_HISTORY_ERROR_CODE: i32 = 4444;
pub const ETH_GET_PROOF_UNSUPPORTED_MESSAGE = "TODO: eth_getProof requires an MPT proof API; StateManager does not expose account/storage proofs";

pub const FeeHistoryParams = struct {
    block_count: jsonrpc.types.Quantity,
    newest_block: jsonrpc.types.BlockSpec,
    reward_percentiles: ?[]const f64 = null,
};

pub const FeeHistoryResult = struct {
    oldest_block: jsonrpc.types.Quantity,
    base_fee_per_gas: []jsonrpc.types.Quantity,
    gas_used_ratio: []f64,
    reward: ?[][]jsonrpc.types.Quantity = null,
    base_fee_per_blob_gas: ?[]jsonrpc.types.Quantity = null,
    blob_gas_used_ratio: ?[]f64 = null,

    pub fn jsonStringify(self: FeeHistoryResult, jws: *std.json.Stringify) !void {
        try jws.beginObject();
        try jws.objectField("oldestBlock");
        try jws.write(self.oldest_block);
        try jws.objectField("baseFeePerGas");
        try jws.write(self.base_fee_per_gas);
        try jws.objectField("gasUsedRatio");
        try jws.write(self.gas_used_ratio);
        if (self.reward) |reward| {
            try jws.objectField("reward");
            try jws.beginArray();
            for (reward) |block_rewards| {
                try jws.beginArray();
                for (block_rewards) |item| {
                    try jws.write(item);
                }
                try jws.endArray();
            }
            try jws.endArray();
        }
        if (self.base_fee_per_blob_gas) |blob_fees| {
            try jws.objectField("baseFeePerBlobGas");
            try jws.write(blob_fees);
        }
        if (self.blob_gas_used_ratio) |ratios| {
            try jws.objectField("blobGasUsedRatio");
            try jws.write(ratios);
        }
        try jws.endObject();
    }
};

pub const GetProofParams = struct {
    address: jsonrpc.types.Address,
    storage_keys: []const jsonrpc.types.Quantity,
    block: jsonrpc.types.BlockSpec,
};

pub fn handleEthChainId(
    allocator: std.mem.Allocator,
    rt: *const runtime.NodeRuntime,
    _: jsonrpc.eth.ChainId.Params,
) !jsonrpc.eth.ChainId.Result {
    return .{ .value = try quantityHexU64(allocator, rt.chain_id) };
}

pub fn handleEthBlockNumber(
    allocator: std.mem.Allocator,
    rt: *const runtime.NodeRuntime,
    _: jsonrpc.eth.BlockNumber.Params,
) !jsonrpc.eth.BlockNumber.Result {
    return .{ .value = try quantityHexU64(allocator, rt.head_block_number) };
}

pub fn handleEthGetBalance(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: jsonrpc.eth.GetBalance.Params,
) !jsonrpc.eth.GetBalance.Result {
    _ = try resolveBlockParam(rt, params.block);
    const balance = try rt.getBalance(.{ .bytes = params.address.bytes });
    return .{ .value = try quantityHexU256(allocator, balance) };
}

pub fn handleEthGetCode(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: jsonrpc.eth.GetCode.Params,
) !jsonrpc.eth.GetCode.Result {
    _ = try resolveBlockParam(rt, params.block);
    const code = try rt.getCode(.{ .bytes = params.address.bytes });
    return .{ .value = try dataHexBytes(allocator, code) };
}

pub fn handleEthGetStorageAt(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: jsonrpc.eth.GetStorageAt.Params,
) !jsonrpc.eth.GetStorageAt.Result {
    _ = try resolveBlockParam(rt, params.block);
    const slot = parseQuantityToU256(params.storage_slot) catch return error.InvalidParams;
    const value = try rt.getStorage(.{ .bytes = params.address.bytes }, slot);
    return .{ .value = try dataHexU256(allocator, value) };
}

pub fn handleEthGetTransactionCount(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: jsonrpc.eth.GetTransactionCount.Params,
) !jsonrpc.eth.GetTransactionCount.Result {
    _ = try resolveBlockParam(rt, params.block);
    const nonce = try rt.getNonce(.{ .bytes = params.address.bytes });
    return .{ .value = try quantityHexU64(allocator, nonce) };
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
    return .{ .value = try quantityHexU256(allocator, rt.gas_price) };
}

pub fn handleEthMaxPriorityFeePerGas(
    allocator: std.mem.Allocator,
    rt: *const runtime.NodeRuntime,
    _: jsonrpc.eth.MaxPriorityFeePerGas.Params,
) !jsonrpc.eth.MaxPriorityFeePerGas.Result {
    return .{ .value = try quantityHexU256(allocator, rt.max_priority_fee) };
}

pub fn handleEthBlobBaseFee(
    allocator: std.mem.Allocator,
    rt: *const runtime.NodeRuntime,
    _: jsonrpc.eth.BlobBaseFee.Params,
) !jsonrpc.eth.BlobBaseFee.Result {
    return .{ .value = try quantityHexU256(allocator, currentBlobBaseFee(rt)) };
}

pub fn handleEthFeeHistory(
    allocator: std.mem.Allocator,
    rt: *const runtime.NodeRuntime,
    params: FeeHistoryParams,
) !FeeHistoryResult {
    const requested_count = parseQuantityToU64(params.block_count) catch return error.InvalidParams;
    if (requested_count == 0 or requested_count > 1024) return error.InvalidParams;
    if (params.reward_percentiles) |percentiles| {
        try validateRewardPercentiles(percentiles);
    }

    const newest = try resolveBlockParam(rt, params.newest_block);
    const available = if (newest == std.math.maxInt(u64)) std.math.maxInt(u64) else newest + 1;
    const actual_count = @min(requested_count, available);
    const count: usize = @intCast(actual_count);
    const oldest = newest - actual_count + 1;

    const base_fees = try allocator.alloc(jsonrpc.types.Quantity, count + 1);
    for (base_fees) |*fee| {
        fee.* = try quantityHexU256(allocator, rt.base_fee);
    }
    const gas_ratios = try allocator.alloc(f64, count);
    @memset(gas_ratios, 0.0);

    const blob_fees = try allocator.alloc(jsonrpc.types.Quantity, count + 1);
    for (blob_fees) |*fee| {
        fee.* = try quantityHexU256(allocator, currentBlobBaseFee(rt));
    }
    const blob_ratios = try allocator.alloc(f64, count);
    @memset(blob_ratios, 0.0);

    const rewards = if (params.reward_percentiles) |percentiles|
        try zeroRewards(allocator, count, percentiles.len)
    else
        null;

    return .{
        .oldest_block = try quantityHexU64(allocator, oldest),
        .base_fee_per_gas = base_fees,
        .gas_used_ratio = gas_ratios,
        .reward = rewards,
        .base_fee_per_blob_gas = blob_fees,
        .blob_gas_used_ratio = blob_ratios,
    };
}

pub fn handleEthSyncing(
    allocator: std.mem.Allocator,
    rt: *const runtime.NodeRuntime,
    _: void,
) !std.json.Value {
    if (rt.fork_config) |fork| {
        if (fork.block_number) |highest| {
            if (highest > rt.head_block_number) {
                var obj = std.json.ObjectMap.init(allocator);
                errdefer obj.deinit();
                try putOwnedJson(&obj, allocator, "startingBlock", .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{@as(u64, 0)}) });
                try putOwnedJson(&obj, allocator, "currentBlock", .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{rt.head_block_number}) });
                try putOwnedJson(&obj, allocator, "highestBlock", .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{highest}) });
                return .{ .object = obj };
            }
        }
    }
    return .{ .bool = false };
}

pub fn handleNetVersion(
    allocator: std.mem.Allocator,
    rt: *const runtime.NodeRuntime,
    _: void,
) !std.json.Value {
    return .{ .string = try std.fmt.allocPrint(allocator, "{d}", .{rt.chain_id}) };
}

pub fn handleWeb3ClientVersion(
    allocator: std.mem.Allocator,
    _: *const runtime.NodeRuntime,
    _: void,
) !std.json.Value {
    return .{ .string = try std.fmt.allocPrint(allocator, "zevm/v0.1.0/{s}/{s}/zig0.15.2", .{
        @tagName(builtin.os.tag),
        @tagName(builtin.cpu.arch),
    }) };
}

pub fn handleEthGetProof(
    _: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: GetProofParams,
) !std.json.Value {
    _ = try resolveBlockParam(rt, params.block);
    for (params.storage_keys) |key| {
        _ = parseQuantityToU256(key) catch return error.InvalidParams;
    }
    return error.MethodNotFound;
}

fn parseQuantityToU64(q: jsonrpc.types.Quantity) !u64 {
    return parseQuantityValue(u64, q.value);
}

fn parseQuantityToU256(q: jsonrpc.types.Quantity) !u256 {
    return parseQuantityValue(u256, q.value);
}

fn parseQuantityValue(comptime T: type, value: std.json.Value) !T {
    return switch (value) {
        .string => |s| parseQuantityString(T, s),
        else => error.InvalidQuantity,
    };
}

fn parseQuantityString(comptime T: type, text: []const u8) !T {
    if (!isQuantityHex(text)) return error.InvalidQuantity;
    return std.fmt.parseInt(T, text[2..], 16) catch return error.InvalidQuantity;
}

fn isQuantityHex(text: []const u8) bool {
    if (text.len <= 2) return false;
    if (text[0] != '0' or text[1] != 'x') return false;
    if (text.len > 3 and text[2] == '0') return false;
    for (text[2..]) |c| {
        _ = std.fmt.charToDigit(c, 16) catch return false;
    }
    return true;
}

fn resolveBlockParam(rt: *const runtime.NodeRuntime, spec: jsonrpc.types.BlockSpec) !u64 {
    return block_spec.resolveBlockNumber(rt, spec) catch return error.InvalidParams;
}

fn quantityHexU64(allocator: std.mem.Allocator, value: u64) !jsonrpc.types.Quantity {
    return .{ .value = .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{value}) } };
}

fn quantityHexU256(allocator: std.mem.Allocator, value: u256) !jsonrpc.types.Quantity {
    return .{ .value = .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{value}) } };
}

fn dataHexU256(allocator: std.mem.Allocator, value: u256) !jsonrpc.types.Quantity {
    return .{ .value = .{ .string = try std.fmt.allocPrint(allocator, "0x{x:0>64}", .{value}) } };
}

fn dataHexBytes(allocator: std.mem.Allocator, bytes: []const u8) !jsonrpc.types.Quantity {
    if (bytes.len == 0) {
        return .{ .value = .{ .string = try allocator.dupe(u8, "0x") } };
    }
    const out = try allocator.alloc(u8, 2 + bytes.len * 2);
    out[0] = '0';
    out[1] = 'x';
    writeHexLower(out[2..], bytes);
    return .{ .value = .{ .string = out } };
}

fn writeHexLower(out: []u8, bytes: []const u8) void {
    const alphabet = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        out[i * 2] = alphabet[(byte >> 4) & 0x0f];
        out[i * 2 + 1] = alphabet[byte & 0x0f];
    }
}

fn validateRewardPercentiles(percentiles: []const f64) !void {
    var previous: f64 = 0.0;
    for (percentiles, 0..) |percentile, i| {
        if (!(percentile >= 0.0) or !(percentile <= 100.0)) return error.InvalidParams;
        if (i > 0 and percentile < previous) return error.InvalidParams;
        previous = percentile;
    }
}

fn zeroRewards(
    allocator: std.mem.Allocator,
    block_count: usize,
    percentile_count: usize,
) ![][]jsonrpc.types.Quantity {
    const rewards = try allocator.alloc([]jsonrpc.types.Quantity, block_count);
    for (rewards) |*block_rewards| {
        block_rewards.* = try allocator.alloc(jsonrpc.types.Quantity, percentile_count);
        for (block_rewards.*) |*reward| {
            reward.* = try quantityHexU256(allocator, 0);
        }
    }
    return rewards;
}

fn currentBlobBaseFee(rt: *const runtime.NodeRuntime) u256 {
    return @as(u256, primitives.Blob.calculateBlobGasPrice(currentExcessBlobGas(rt)));
}

fn currentExcessBlobGas(rt: *const runtime.NodeRuntime) u64 {
    if (@hasField(runtime.NodeRuntime, "excess_blob_gas")) {
        return rt.excess_blob_gas;
    }
    if (@hasField(runtime.NodeRuntime, "head_excess_blob_gas")) {
        return rt.head_excess_blob_gas;
    }
    _ = rt;
    return 0;
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
