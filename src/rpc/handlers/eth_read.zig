const std = @import("std");
const builtin = @import("builtin");
const jsonrpc = @import("jsonrpc");
const runtime = @import("../../node/runtime.zig");
const block_spec = @import("block_spec.zig");
const rpc_parse = @import("../parse.zig");

pub const PRUNED_HISTORY_ERROR_CODE: i32 = 4444;
pub const MAX_FEE_HISTORY_BLOCK_COUNT: u64 = 1024;
pub const MAX_REWARD_PERCENTILES: usize = 100;

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

pub const AccountsResult = struct {
    value: []jsonrpc.types.Address,
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
    const slot = parseStorageSlotToU256(params.storage_slot) catch return error.InvalidParams;
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
) !AccountsResult {
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
    const range = try resolveFeeHistoryRange(rt, params);

    const base_fees = try allocator.alloc(jsonrpc.types.Quantity, range.count + 1);
    for (base_fees) |*fee| {
        fee.* = try quantityHexU256(allocator, rt.base_fee);
    }
    const gas_ratios = try allocator.alloc(f64, range.count);
    @memset(gas_ratios, 0.0);

    const rewards = if (params.reward_percentiles) |percentiles|
        try zeroRewards(allocator, range.count, percentiles.len)
    else
        null;

    return .{
        .oldest_block = try quantityHexU64(allocator, range.oldest),
        .base_fee_per_gas = base_fees,
        .gas_used_ratio = gas_ratios,
        .reward = rewards,
    };
}

pub fn parseEthFeeHistoryParams(
    allocator: std.mem.Allocator,
    params: ?std.json.Value,
) !FeeHistoryParams {
    const items = try paramsArrayItems(params);
    if (items.len != 2 and items.len != 3) return error.InvalidParams;

    return .{
        .block_count = .{ .value = items[0] },
        .newest_block = .{ .value = items[1] },
        .reward_percentiles = if (items.len == 3)
            try parseRewardPercentiles(allocator, items[2])
        else
            null,
    };
}

pub fn deinitEthFeeHistoryParams(allocator: std.mem.Allocator, params: FeeHistoryParams) void {
    if (params.reward_percentiles) |percentiles| {
        allocator.free(percentiles);
    }
}

pub fn handleEthFeeHistoryValue(
    allocator: std.mem.Allocator,
    rt: *const runtime.NodeRuntime,
    params: FeeHistoryParams,
) !std.json.Value {
    const range = try resolveFeeHistoryRange(rt, params);

    var obj = std.json.ObjectMap.init(allocator);
    errdefer {
        var cleanup = std.json.Value{ .object = obj };
        deinitJsonValue(allocator, &cleanup);
    }

    try putOwnedJsonValue(&obj, allocator, "oldestBlock", try quantityValueHexU64(allocator, range.oldest));
    try putOwnedJsonValue(&obj, allocator, "baseFeePerGas", try repeatedQuantityValueArray(allocator, range.count + 1, rt.base_fee));
    try putOwnedJsonValue(&obj, allocator, "gasUsedRatio", try zeroRatioValueArray(allocator, range.count));
    if (params.reward_percentiles) |percentiles| {
        try putOwnedJsonValue(&obj, allocator, "reward", try zeroRewardsValue(allocator, range.count, percentiles.len));
    }

    return .{ .object = obj };
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

const FeeHistoryRange = struct {
    oldest: u64,
    count: usize,
};

fn resolveFeeHistoryRange(rt: *const runtime.NodeRuntime, params: FeeHistoryParams) !FeeHistoryRange {
    const requested_count = parseQuantityToU64(params.block_count) catch return error.InvalidParams;
    if (requested_count == 0) return error.InvalidParams;
    if (params.reward_percentiles) |percentiles| {
        try validateRewardPercentiles(percentiles);
    }

    const effective_count = @min(requested_count, MAX_FEE_HISTORY_BLOCK_COUNT);
    const newest = try resolveBlockParam(rt, params.newest_block);
    const available = if (newest == std.math.maxInt(u64)) std.math.maxInt(u64) else newest + 1;
    const returned_count = @min(effective_count, available);

    return .{
        .oldest = newest - (returned_count - 1),
        .count = @intCast(returned_count),
    };
}

fn paramsArrayItems(params: ?std.json.Value) ![]const std.json.Value {
    const value = params orelse return error.InvalidParams;
    return switch (value) {
        .array => |array| array.items,
        else => error.InvalidParams,
    };
}

fn parseQuantityToU64(q: jsonrpc.types.Quantity) !u64 {
    return rpc_parse.parseQuantity(u64, q) catch return error.InvalidQuantity;
}

fn parseQuantityToU256(q: jsonrpc.types.Quantity) !u256 {
    return rpc_parse.parseQuantity(u256, q) catch return error.InvalidQuantity;
}

fn parseStorageSlotToU256(q: jsonrpc.types.Quantity) !u256 {
    switch (q.value) {
        .string => |text| {
            if (rpc_parse.isHash32(text)) {
                const bytes = try rpc_parse.parseHash32String(text);
                return std.mem.readInt(u256, &bytes, .big);
            }
        },
        else => {},
    }
    return parseQuantityToU256(q);
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

fn parseRewardPercentiles(allocator: std.mem.Allocator, value: std.json.Value) ![]f64 {
    const items = switch (value) {
        .array => |array| array.items,
        else => return error.InvalidParams,
    };
    if (items.len > MAX_REWARD_PERCENTILES) return error.InvalidParams;

    const percentiles = try allocator.alloc(f64, items.len);
    errdefer allocator.free(percentiles);
    for (items, 0..) |item, i| {
        percentiles[i] = try parseRewardPercentile(item);
    }
    try validateRewardPercentiles(percentiles);
    return percentiles;
}

fn parseRewardPercentile(value: std.json.Value) !f64 {
    return switch (value) {
        .integer => |n| blk: {
            if (n < 0) return error.InvalidParams;
            break :blk @floatFromInt(n);
        },
        .float => |n| n,
        else => error.InvalidParams,
    };
}

fn validateRewardPercentiles(percentiles: []const f64) !void {
    if (percentiles.len > MAX_REWARD_PERCENTILES) return error.InvalidParams;
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
    return rt.dev_runtime.config.blob_base_fee orelse rt.blob_base_fee;
}

fn quantityValueHexU64(allocator: std.mem.Allocator, value: u64) !std.json.Value {
    return .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{value}) };
}

fn quantityValueHexU256(allocator: std.mem.Allocator, value: u256) !std.json.Value {
    return .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{value}) };
}

fn repeatedQuantityValueArray(
    allocator: std.mem.Allocator,
    count: usize,
    value: u256,
) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer {
        for (array.items) |*item| {
            deinitJsonValue(allocator, item);
        }
        array.deinit();
    }

    for (0..count) |_| {
        try array.append(try quantityValueHexU256(allocator, value));
    }
    return .{ .array = array };
}

fn zeroRatioValueArray(allocator: std.mem.Allocator, count: usize) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer {
        for (array.items) |*item| {
            deinitJsonValue(allocator, item);
        }
        array.deinit();
    }

    for (0..count) |_| {
        try array.append(.{ .number_string = try allocator.dupe(u8, "0.0") });
    }
    return .{ .array = array };
}

fn zeroRewardsValue(
    allocator: std.mem.Allocator,
    block_count: usize,
    percentile_count: usize,
) !std.json.Value {
    var outer = std.json.Array.init(allocator);
    errdefer {
        for (outer.items) |*item| {
            deinitJsonValue(allocator, item);
        }
        outer.deinit();
    }

    for (0..block_count) |_| {
        try outer.append(try zeroRewardRowValue(allocator, percentile_count));
    }
    return .{ .array = outer };
}

fn zeroRewardRowValue(allocator: std.mem.Allocator, percentile_count: usize) !std.json.Value {
    var inner = std.json.Array.init(allocator);
    errdefer {
        for (inner.items) |*item| {
            deinitJsonValue(allocator, item);
        }
        inner.deinit();
    }

    for (0..percentile_count) |_| {
        try inner.append(try quantityValueHexU256(allocator, 0));
    }
    return .{ .array = inner };
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

fn putOwnedJsonValue(
    obj: *std.json.ObjectMap,
    allocator: std.mem.Allocator,
    key: []const u8,
    value: std.json.Value,
) !void {
    var owned_value = value;
    errdefer deinitJsonValue(allocator, &owned_value);

    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    try obj.put(owned_key, owned_value);
}

fn deinitJsonValue(allocator: std.mem.Allocator, value: *std.json.Value) void {
    switch (value.*) {
        .string => |text| allocator.free(text),
        .number_string => |text| allocator.free(text),
        .array => |*array| {
            for (array.items) |*item| {
                deinitJsonValue(allocator, item);
            }
            array.deinit();
        },
        .object => |*object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                deinitJsonValue(allocator, entry.value_ptr);
            }
            object.deinit();
        },
        else => {},
    }
}
