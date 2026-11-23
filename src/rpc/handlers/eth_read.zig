const std = @import("std");
const builtin = @import("builtin");
const jsonrpc = @import("jsonrpc");
const primitives = @import("primitives");
const state_manager = @import("state-manager");
const runtime = @import("../../node/runtime.zig");
const block_builder = @import("../../block_builder.zig");
const blob_fee = @import("../../blob_fee.zig");
const mpt_proof = @import("../../mpt_proof.zig");
const rpc_parse = @import("../parse.zig");

pub const PRUNED_HISTORY_ERROR_CODE: i32 = 4444;
pub const MAX_FEE_HISTORY_BLOCK_COUNT: u64 = 1024;
pub const MAX_REWARD_PERCENTILES: usize = 100;
/// Maximum number of storage keys one eth_getProof request may name.
pub const MAX_PROOF_KEYS: usize = 256;

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
    const selected = resolveStateReadBlockNumber(rt, params.block) catch |err| return stateSelectorError(err);
    const read_state = try rt.readStateAtBlock(selected);
    const balance = try read_state.getBalance(.{ .bytes = params.address.bytes });
    return .{ .value = try quantityHexU256(allocator, balance) };
}

pub fn handleEthGetCode(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: jsonrpc.eth.GetCode.Params,
) !jsonrpc.eth.GetCode.Result {
    const selected = resolveStateReadBlockNumber(rt, params.block) catch |err| return stateSelectorError(err);
    const read_state = try rt.readStateAtBlock(selected);
    const code = try read_state.getCode(.{ .bytes = params.address.bytes });
    return .{ .value = try dataHexBytes(allocator, code) };
}

pub fn handleEthGetStorageAt(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: jsonrpc.eth.GetStorageAt.Params,
) !jsonrpc.eth.GetStorageAt.Result {
    const selected = resolveStateReadBlockNumber(rt, params.block) catch |err| return stateSelectorError(err);
    const slot = parseStorageSlotToU256(params.storage_slot) catch return error.InvalidParams;
    const read_state = try rt.readStateAtBlock(selected);
    const value = try read_state.getStorage(.{ .bytes = params.address.bytes }, slot);
    return .{ .value = try dataHexU256(allocator, value) };
}

pub fn handleEthGetTransactionCount(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: jsonrpc.eth.GetTransactionCount.Params,
) !jsonrpc.eth.GetTransactionCount.Result {
    const selected = resolveStateReadBlockNumber(rt, params.block) catch |err| return stateSelectorError(err);
    const read_state = try rt.readStateAtBlock(selected);
    const address = primitives.Address{ .bytes = params.address.bytes };
    const nonce = try read_state.getNonce(address);
    // For the "pending" tag, eth_getTransactionCount must return the next usable
    // nonce, accounting for transactions already accepted into the mempool but not
    // yet mined (Geth/Anvil semantics). Under manual/interval mining the pool
    // persists between calls, so returning only the committed state nonce yields a
    // stale value and causes nonce collisions. Consult the pool for the next
    // consecutive pending nonce.
    if (isPendingBlockTag(params.block.value)) {
        const next = rt.pool.pendingNonce(address, nonce);
        return .{ .value = try quantityHexU64(allocator, next) };
    }
    return .{ .value = try quantityHexU64(allocator, nonce) };
}

fn isPendingBlockTag(value: std.json.Value) bool {
    return switch (value) {
        .string => |text| std.mem.eql(u8, text, "pending"),
        else => false,
    };
}

pub fn handleEthGetStorageValuesValue(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: ?std.json.Value,
) !std.json.Value {
    const items = try paramsArrayItems(params);
    if (items.len != 2) return error.InvalidParams;

    const selected = resolveStateReadBlockNumberValue(rt, items[1]) catch |err| return stateSelectorError(err);
    const read_state = try rt.readStateAtBlock(selected);

    const requests = switch (items[0]) {
        .object => |object| object,
        else => return error.InvalidParams,
    };
    if (requests.count() == 0) return error.InvalidParams;

    var result = std.json.ObjectMap.init(allocator);
    errdefer {
        var cleanup = std.json.Value{ .object = result };
        deinitJsonValue(allocator, &cleanup);
    }

    var address_it = requests.iterator();
    while (address_it.next()) |entry| {
        const address = try rpc_parse.parseAddressString(entry.key_ptr.*);
        const slots = switch (entry.value_ptr.*) {
            .array => |array| array.items,
            else => return error.InvalidParams,
        };

        var values = std.json.Array.init(allocator);
        errdefer {
            for (values.items) |*item| deinitJsonValue(allocator, item);
            values.deinit();
        }

        for (slots) |slot_value| {
            const slot_hash = try rpc_parse.parseHash32Value(slot_value);
            const slot = std.mem.readInt(u256, &slot_hash, .big);
            try values.append(try dataValueHexU256(allocator, try read_state.getStorage(address, slot)));
        }

        const owned_key = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(owned_key);
        try result.put(owned_key, .{ .array = values });
    }

    return .{ .object = result };
}

pub fn handleEthGetProofValue(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: ?std.json.Value,
) !std.json.Value {
    const items = try paramsArrayItems(params);
    if (items.len != 3) return error.InvalidParams;

    const address = try rpc_parse.parseAddressValue(items[0]);
    const storage_keys = switch (items[1]) {
        .array => |array| array.items,
        else => return error.InvalidParams,
    };
    if (storage_keys.len > MAX_PROOF_KEYS) return error.InvalidParams;
    const selected = resolveStateReadBlockNumberValue(rt, items[2]) catch |err| return stateSelectorError(err);
    const read_state = try rt.readStateAtBlock(selected);

    const balance = try read_state.getBalance(address);
    const nonce = try read_state.getNonce(address);
    const code = try read_state.getCode(address);
    const code_hash = codeHash(code);
    const storage_hash = try block_builder.computeStorageRoot(allocator, read_state, address);

    var obj = std.json.ObjectMap.init(allocator);
    errdefer {
        var cleanup = std.json.Value{ .object = obj };
        deinitJsonValue(allocator, &cleanup);
    }

    try putOwnedJsonValue(&obj, allocator, "address", try addressValue(allocator, address));
    try putOwnedJsonValue(&obj, allocator, "accountProof", try accountProofValue(allocator, read_state, address));
    try putOwnedJsonValue(&obj, allocator, "balance", try quantityValueHexU256(allocator, balance));
    try putOwnedJsonValue(&obj, allocator, "codeHash", try hash32Value(allocator, code_hash));
    try putOwnedJsonValue(&obj, allocator, "nonce", try quantityValueHexU64(allocator, nonce));
    try putOwnedJsonValue(&obj, allocator, "storageHash", try hash32Value(allocator, storage_hash));
    try putOwnedJsonValue(&obj, allocator, "storageProof", try storageProofValue(allocator, read_state, address, storage_keys));
    return .{ .object = obj };
}

pub fn parseEthGetBalanceParams(params: ?std.json.Value) !jsonrpc.eth.GetBalance.Params {
    const items = try rpc_parse.paramsArrayItems(params);
    if (items.len != 2) return error.InvalidParams;
    return .{
        .address = .{ .bytes = (try rpc_parse.parseAddressValue(items[0])).bytes },
        .block = .{ .value = items[1] },
    };
}

pub fn parseEthGetCodeParams(params: ?std.json.Value) !jsonrpc.eth.GetCode.Params {
    const items = try rpc_parse.paramsArrayItems(params);
    if (items.len != 2) return error.InvalidParams;
    return .{
        .address = .{ .bytes = (try rpc_parse.parseAddressValue(items[0])).bytes },
        .block = .{ .value = items[1] },
    };
}

pub fn parseEthGetStorageAtParams(params: ?std.json.Value) !jsonrpc.eth.GetStorageAt.Params {
    const items = try rpc_parse.paramsArrayItems(params);
    if (items.len != 3) return error.InvalidParams;
    return .{
        .address = .{ .bytes = (try rpc_parse.parseAddressValue(items[0])).bytes },
        .storage_slot = .{ .value = items[1] },
        .block = .{ .value = items[2] },
    };
}

pub fn parseEthGetTransactionCountParams(params: ?std.json.Value) !jsonrpc.eth.GetTransactionCount.Params {
    const items = try rpc_parse.paramsArrayItems(params);
    if (items.len != 2) return error.InvalidParams;
    return .{
        .address = .{ .bytes = (try rpc_parse.parseAddressValue(items[0])).bytes },
        .block = .{ .value = items[1] },
    };
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
    rt: *const runtime.NodeRuntime,
    _: jsonrpc.eth.Accounts.Params,
) !AccountsResult {
    const addrs = try allocator.alloc(jsonrpc.types.Address, rt.managedAccountCount());
    for (addrs, 0..) |*out, index| {
        out.* = .{ .bytes = rt.managedAccountAddress(index).bytes };
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
    rt: *runtime.NodeRuntime,
    params: FeeHistoryParams,
) !FeeHistoryResult {
    const range = try resolveFeeHistoryRange(rt, params);

    const base_fees = try allocator.alloc(jsonrpc.types.Quantity, range.count + 1);
    var base_fees_initialized: usize = 0;
    errdefer {
        for (base_fees[0..base_fees_initialized]) |fee| allocator.free(fee.value.string);
        allocator.free(base_fees);
    }
    for (base_fees, 0..) |*fee, index| {
        const block_number = range.oldest + @as(u64, @intCast(index));
        fee.* = try quantityHexU256(allocator, try feeHistoryBaseFee(rt, block_number));
        base_fees_initialized += 1;
    }

    const gas_ratios = try allocator.alloc(f64, range.count);
    errdefer allocator.free(gas_ratios);
    for (gas_ratios, 0..) |*ratio, index| {
        const block_number = range.oldest + @as(u64, @intCast(index));
        ratio.* = try feeHistoryGasUsedRatio(rt, block_number);
    }

    const blob_base_fees = try allocator.alloc(jsonrpc.types.Quantity, range.count + 1);
    var blob_base_fees_initialized: usize = 0;
    errdefer {
        for (blob_base_fees[0..blob_base_fees_initialized]) |fee| allocator.free(fee.value.string);
        allocator.free(blob_base_fees);
    }
    for (blob_base_fees, 0..) |*fee, index| {
        const block_number = range.oldest + @as(u64, @intCast(index));
        fee.* = try quantityHexU256(allocator, try feeHistoryBlobBaseFee(rt, block_number));
        blob_base_fees_initialized += 1;
    }

    const blob_ratios = try allocator.alloc(f64, range.count);
    errdefer allocator.free(blob_ratios);
    for (blob_ratios, 0..) |*ratio, index| {
        const block_number = range.oldest + @as(u64, @intCast(index));
        ratio.* = try feeHistoryBlobGasUsedRatio(rt, block_number);
    }

    const rewards = if (params.reward_percentiles) |percentiles|
        try feeHistoryRewards(allocator, rt, range, percentiles)
    else
        null;
    errdefer if (rewards) |rows| freeRewardRows(allocator, rows, rows.len);

    return .{
        .oldest_block = try quantityHexU64(allocator, range.oldest),
        .base_fee_per_gas = base_fees,
        .gas_used_ratio = gas_ratios,
        .reward = rewards,
        .base_fee_per_blob_gas = blob_base_fees,
        .blob_gas_used_ratio = blob_ratios,
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
    rt: *runtime.NodeRuntime,
    params: FeeHistoryParams,
) !std.json.Value {
    const range = try resolveFeeHistoryRange(rt, params);

    var obj = std.json.ObjectMap.init(allocator);
    errdefer {
        var cleanup = std.json.Value{ .object = obj };
        deinitJsonValue(allocator, &cleanup);
    }

    try putOwnedJsonValue(&obj, allocator, "oldestBlock", try quantityValueHexU64(allocator, range.oldest));
    try putOwnedJsonValue(&obj, allocator, "baseFeePerGas", try feeHistoryBaseFeeArray(allocator, rt, range));
    try putOwnedJsonValue(&obj, allocator, "gasUsedRatio", try feeHistoryGasUsedRatioArray(allocator, rt, range));
    try putOwnedJsonValue(&obj, allocator, "baseFeePerBlobGas", try feeHistoryBlobBaseFeeArray(allocator, rt, range));
    try putOwnedJsonValue(&obj, allocator, "blobGasUsedRatio", try feeHistoryBlobGasUsedRatioArray(allocator, rt, range));
    if (params.reward_percentiles) |percentiles| {
        try putOwnedJsonValue(&obj, allocator, "reward", try feeHistoryRewardsValue(allocator, rt, range, percentiles));
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

fn resolveFeeHistoryRange(rt: *runtime.NodeRuntime, params: FeeHistoryParams) !FeeHistoryRange {
    const requested_count = parseQuantityToU64(params.block_count) catch return error.InvalidParams;
    if (requested_count == 0) return error.InvalidParams;
    if (params.reward_percentiles) |percentiles| {
        try validateRewardPercentiles(percentiles);
    }

    const effective_count = @min(requested_count, MAX_FEE_HISTORY_BLOCK_COUNT);
    const newest = try resolveBlockParam(rt, params.newest_block);
    if ((try rt.blockchain.getBlockByNumber(newest)) == null) return error.InvalidParams;
    const available = if (newest == std.math.maxInt(u64)) std.math.maxInt(u64) else newest + 1;
    const returned_count = @min(effective_count, available);

    return .{
        .oldest = newest - (returned_count - 1),
        .count = @intCast(returned_count),
    };
}

fn feeHistoryBaseFee(rt: *runtime.NodeRuntime, block_number: u64) !u256 {
    if (try rt.blockchain.getBlockByNumber(block_number)) |block| {
        if (block.header.base_fee_per_gas) |base_fee| return base_fee;
        // A pre-London block has no base fee, so the history reports 0. A
        // London block whose stored header lacks the field (the dev genesis)
        // falls back to the runtime base fee.
        if (rt.hardforkAt(block.header.number, block.header.timestamp).isBefore(.LONDON)) return 0;
        return rt.base_fee;
    }
    // The entry after the newest block is the next block's base fee.
    if (rt.hardforkAt(block_number, rt.pendingBlockTimestamp()).isBefore(.LONDON)) return 0;
    return rt.base_fee;
}

const RewardSample = struct {
    reward: u256,
    gas_used: u64,

    fn lessThan(_: void, a: RewardSample, b: RewardSample) bool {
        return a.reward < b.reward;
    }
};

/// Fills `out[i]` with the effective priority fee per gas at
/// `percentiles[i]` of the block's gas, weighted by gas used. Transactions are
/// ordered by ascending effective priority fee; the reward at percentile `p`
/// is the fee of the transaction that contains the `p`% point of cumulative
/// gas. A block without transactions reports 0 for every percentile.
fn feeHistoryBlockRewards(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    block_number: u64,
    percentiles: []const f64,
    out: []u256,
) !void {
    std.debug.assert(out.len == percentiles.len);
    @memset(out, 0);
    if (percentiles.len == 0) return;
    const block = (try rt.blockchain.getBlockByNumber(block_number)) orelse return;
    const receipts = rt.receipt_index.getByBlockHash(block.hash) orelse return;
    if (receipts.len == 0) return;

    const base_fee = block.header.base_fee_per_gas orelse 0;
    const samples = try allocator.alloc(RewardSample, receipts.len);
    defer allocator.free(samples);
    var block_gas_used: u64 = 0;
    for (receipts, samples) |receipt, *sample| {
        sample.* = .{
            .reward = receipt.effective_gas_price -| base_fee,
            .gas_used = std.math.cast(u64, receipt.gas_used) orelse std.math.maxInt(u64),
        };
        block_gas_used +|= sample.gas_used;
    }
    std.mem.sort(RewardSample, samples, {}, RewardSample.lessThan);

    var tx_index: usize = 0;
    var cumulative_gas: u64 = samples[0].gas_used;
    for (percentiles, out) |percentile, *reward| {
        const threshold = std.math.lossyCast(u64, @as(f64, @floatFromInt(block_gas_used)) * percentile / 100.0);
        while (cumulative_gas < threshold and tx_index < samples.len - 1) {
            tx_index += 1;
            cumulative_gas +|= samples[tx_index].gas_used;
        }
        reward.* = samples[tx_index].reward;
    }
}

fn freeRewardRows(allocator: std.mem.Allocator, rows: [][]jsonrpc.types.Quantity, initialized: usize) void {
    for (rows[0..initialized]) |row| {
        for (row) |reward| allocator.free(reward.value.string);
        allocator.free(row);
    }
    allocator.free(rows);
}

fn feeHistoryRewards(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    range: FeeHistoryRange,
    percentiles: []const f64,
) ![][]jsonrpc.types.Quantity {
    var block_rewards: [MAX_REWARD_PERCENTILES]u256 = undefined;
    const rows = try allocator.alloc([]jsonrpc.types.Quantity, range.count);
    var rows_initialized: usize = 0;
    errdefer freeRewardRows(allocator, rows, rows_initialized);

    for (rows, 0..) |*row, index| {
        const block_number = range.oldest + @as(u64, @intCast(index));
        try feeHistoryBlockRewards(allocator, rt, block_number, percentiles, block_rewards[0..percentiles.len]);

        const quantities = try allocator.alloc(jsonrpc.types.Quantity, percentiles.len);
        var quantities_initialized: usize = 0;
        errdefer {
            for (quantities[0..quantities_initialized]) |reward| allocator.free(reward.value.string);
            allocator.free(quantities);
        }
        for (quantities, block_rewards[0..percentiles.len]) |*quantity, reward| {
            quantity.* = try quantityHexU256(allocator, reward);
            quantities_initialized += 1;
        }
        row.* = quantities;
        rows_initialized += 1;
    }
    return rows;
}

fn feeHistoryRewardsValue(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    range: FeeHistoryRange,
    percentiles: []const f64,
) !std.json.Value {
    var block_rewards: [MAX_REWARD_PERCENTILES]u256 = undefined;
    var outer = std.json.Array.init(allocator);
    errdefer {
        for (outer.items) |*item| deinitJsonValue(allocator, item);
        outer.deinit();
    }

    for (0..range.count) |index| {
        const block_number = range.oldest + @as(u64, @intCast(index));
        try feeHistoryBlockRewards(allocator, rt, block_number, percentiles, block_rewards[0..percentiles.len]);

        var inner = std.json.Array.init(allocator);
        errdefer {
            for (inner.items) |*item| deinitJsonValue(allocator, item);
            inner.deinit();
        }
        try inner.ensureTotalCapacity(percentiles.len);
        for (block_rewards[0..percentiles.len]) |reward| {
            inner.appendAssumeCapacity(try quantityValueHexU256(allocator, reward));
        }
        try outer.ensureUnusedCapacity(1);
        outer.appendAssumeCapacity(.{ .array = inner });
    }
    return .{ .array = outer };
}

fn feeHistoryGasUsedRatio(rt: *runtime.NodeRuntime, block_number: u64) !f64 {
    const block = (try rt.blockchain.getBlockByNumber(block_number)) orelse return 0.0;
    if (block.header.gas_limit == 0) return 0.0;
    return @as(f64, @floatFromInt(block.header.gas_used)) /
        @as(f64, @floatFromInt(block.header.gas_limit));
}

fn feeHistoryBlobBaseFee(rt: *runtime.NodeRuntime, block_number: u64) !u256 {
    if (try rt.blockchain.getBlockByNumber(block_number)) |block| {
        const excess = block.header.excess_blob_gas orelse return 0;
        return blob_fee.blobBaseFeeAt(rt.hardfork_config, block.header.number, block.header.timestamp, excess);
    }
    if (rt.dev_runtime.config.blob_base_fee) |override| return override;
    if (block_number > 0) {
        if (try rt.blockchain.getBlockByNumber(block_number - 1)) |parent| {
            const next_timestamp = if (block_number == rt.head_block_number +| 1)
                rt.pendingBlockTimestamp()
            else
                parent.header.timestamp +| rt.hardfork_config.seconds_per_slot;
            const next_excess = blob_fee.nextExcessBlobGasForHeader(
                rt.hardfork_config,
                parent.header,
                block_number,
                next_timestamp,
            );
            return blob_fee.blobBaseFeeAt(rt.hardfork_config, block_number, next_timestamp, next_excess);
        }
    }
    return currentBlobBaseFee(rt);
}

fn feeHistoryBlobGasUsedRatio(rt: *runtime.NodeRuntime, block_number: u64) !f64 {
    const block = (try rt.blockchain.getBlockByNumber(block_number)) orelse return 0.0;
    const blob_gas_used = block.header.blob_gas_used orelse return 0.0;
    const max_blob_gas = blob_fee.resolveBlobParams(
        rt.hardfork_config,
        block.header.number,
        block.header.timestamp,
    ).max_blob_gas;
    if (max_blob_gas == 0) return 0.0;
    return @as(f64, @floatFromInt(blob_gas_used)) /
        @as(f64, @floatFromInt(max_blob_gas));
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
    return resolveTrustedRuntimeBlockSelector(rt, spec.value) catch return error.InvalidParams;
}

fn resolveStateReadBlockNumber(rt: *runtime.NodeRuntime, spec: jsonrpc.types.BlockSpec) !u64 {
    return resolveStateReadBlockNumberValue(rt, spec.value);
}

fn resolveStateReadBlockNumberValue(rt: *runtime.NodeRuntime, value: std.json.Value) !u64 {
    switch (value) {
        .string => |text| {
            if (rpc_parse.isHash32(text)) {
                const hash = try rpc_parse.parseHash32String(text);
                return resolveBlockHashSelector(rt, hash, true);
            }
            const selected = resolveTrustedRuntimeBlockSelector(rt, value) catch return error.InvalidParams;
            if (selected > rt.head_block_number) return error.InvalidParams;
            return selected;
        },
        .object => |object| return resolveStateReadBlockObject(rt, object),
        else => return error.InvalidParams,
    }
}

fn resolveStateReadBlockObject(rt: *runtime.NodeRuntime, object: std.json.ObjectMap) !u64 {
    const block_number = object.get("blockNumber");
    const block_hash = object.get("blockHash");
    if (block_number != null and block_hash != null) return error.InvalidParams;

    if (block_number) |value| {
        const selected = rpc_parse.parseQuantityValue(u64, value) catch return error.InvalidParams;
        if (selected > rt.head_block_number) return error.InvalidParams;
        return selected;
    }

    if (block_hash) |value| {
        const hash = try rpc_parse.parseHash32Value(value);
        const require_canonical = if (object.get("requireCanonical")) |canonical| switch (canonical) {
            .bool => |flag| flag,
            else => return error.InvalidParams,
        } else false;
        return resolveBlockHashSelector(rt, hash, require_canonical);
    }

    return error.InvalidParams;
}

/// Resolves an EIP-1898 `blockHash` selector to a canonical block number.
/// State is stored per canonical height, so a hash that names a
/// non-canonical block has no state to serve: with `requireCanonical` the
/// request is invalid, and without it the block is unavailable. Returning the
/// block's number would answer from the canonical block at that height.
fn resolveBlockHashSelector(rt: *runtime.NodeRuntime, hash: [32]u8, require_canonical: bool) !u64 {
    const block = (try rt.blockchain.getBlockByHash(hash)) orelse return error.InvalidParams;
    const canonical = rt.blockchain.getCanonicalHash(block.header.number) orelse return error.InvalidParams;
    if (!std.mem.eql(u8, &canonical, &hash)) {
        return if (require_canonical) error.InvalidParams else error.BlockUnavailable;
    }
    return block.header.number;
}

/// Keeps `BlockUnavailable` distinct; every other selector failure is a
/// malformed or out-of-range parameter.
fn stateSelectorError(err: anyerror) error{ InvalidParams, BlockUnavailable } {
    return if (err == error.BlockUnavailable) error.BlockUnavailable else error.InvalidParams;
}

fn resolveTrustedRuntimeBlockSelector(rt: *const runtime.NodeRuntime, value: std.json.Value) !u64 {
    switch (value) {
        .string => |text| {
            if (std.mem.eql(u8, text, "safe")) return rt.engineSafeBlockNumber() orelse error.InvalidParams;
            if (std.mem.eql(u8, text, "finalized")) return rt.engineFinalizedBlockNumber() orelse error.InvalidParams;
        },
        else => {},
    }
    return rpc_parse.resolveTrustedBlockSelector(rt.head_block_number, value);
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

fn dataValueHexU256(allocator: std.mem.Allocator, value: u256) !std.json.Value {
    return .{ .string = try std.fmt.allocPrint(allocator, "0x{x:0>64}", .{value}) };
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

pub fn currentBlobBaseFee(rt: *const runtime.NodeRuntime) u256 {
    if (rt.dev_runtime.config.blob_base_fee) |override| return override;

    const pending_fork = rt.pendingHardfork();
    if (pending_fork.isBefore(.CANCUN)) return 0;

    var chain = @constCast(&rt.blockchain);
    if (chain.getCanonicalHash(rt.head_block_number)) |head_hash| {
        if (chain.getBlockLocal(head_hash)) |head_block| {
            const next_block_number = rt.head_block_number +| 1;
            const next_timestamp = rt.pendingBlockTimestamp();
            const next_excess = blob_fee.nextExcessBlobGasForHeader(
                rt.hardfork_config,
                head_block.header,
                next_block_number,
                next_timestamp,
            );
            const computed = blob_fee.blobBaseFeeAt(
                rt.hardfork_config,
                next_block_number,
                next_timestamp,
                next_excess,
            );
            if (next_excess > 0 or rt.blob_base_fee == runtime.DEFAULT_BLOB_BASE_FEE) {
                return computed;
            }
        }
    }
    return rt.blob_base_fee;
}

fn quantityValueHexU64(allocator: std.mem.Allocator, value: u64) !std.json.Value {
    return .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{value}) };
}

fn quantityValueHexU256(allocator: std.mem.Allocator, value: u256) !std.json.Value {
    return .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{value}) };
}

fn addressValue(allocator: std.mem.Allocator, address: primitives.Address) !std.json.Value {
    const out = try allocator.alloc(u8, 42);
    out[0] = '0';
    out[1] = 'x';
    writeHexLower(out[2..], &address.bytes);
    return .{ .string = out };
}

fn hash32Value(allocator: std.mem.Allocator, hash: [32]u8) !std.json.Value {
    const out = try allocator.alloc(u8, 66);
    out[0] = '0';
    out[1] = 'x';
    writeHexLower(out[2..], &hash);
    return .{ .string = out };
}

fn bytesValueHex(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Value {
    const out = try allocator.alloc(u8, 2 + bytes.len * 2);
    out[0] = '0';
    out[1] = 'x';
    writeHexLower(out[2..], bytes);
    return .{ .string = out };
}

fn storageProofValue(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    address: primitives.Address,
    keys: []const std.json.Value,
) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer {
        for (array.items) |*item| {
            deinitJsonValue(allocator, item);
        }
        array.deinit();
    }

    // Collect and RLP-encode the account's storage entries once for the whole
    // request instead of once per requested key.
    var trie_keys = std.ArrayList([]const u8){};
    defer {
        for (trie_keys.items) |key| allocator.free(key);
        trie_keys.deinit(allocator);
    }
    var trie_values = std.ArrayList([]const u8){};
    defer {
        for (trie_values.items) |value| allocator.free(value);
        trie_values.deinit(allocator);
    }
    try collectStorageTrieEntries(allocator, sm, address, &trie_keys, &trie_values);

    for (keys) |key_value| {
        const slot = try parseProofStorageKey(key_value);
        const value = try sm.getStorage(address, slot);
        var slot_bytes: [32]u8 = undefined;
        std.mem.writeInt(u256, &slot_bytes, slot, .big);
        var proof = try mpt_proof.secureProof(allocator, trie_keys.items, trie_values.items, &slot_bytes);
        defer proof.deinit(allocator);

        var entry = std.json.ObjectMap.init(allocator);
        errdefer {
            var cleanup = std.json.Value{ .object = entry };
            deinitJsonValue(allocator, &cleanup);
        }
        try putOwnedJsonValue(&entry, allocator, "key", try quantityValueHexU256(allocator, slot));
        try putOwnedJsonValue(&entry, allocator, "value", try quantityValueHexU256(allocator, value));
        try putOwnedJsonValue(&entry, allocator, "proof", try proofNodesValue(allocator, proof.nodes));
        try array.append(.{ .object = entry });
    }

    return .{ .array = array };
}

fn accountProofValue(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    address: primitives.Address,
) !std.json.Value {
    var keys = std.ArrayList([]const u8){};
    defer {
        for (keys.items) |key| allocator.free(key);
        keys.deinit(allocator);
    }
    var values = std.ArrayList([]const u8){};
    defer {
        for (values.items) |value| allocator.free(value);
        values.deinit(allocator);
    }

    try collectAccountTrieEntries(allocator, sm, &keys, &values);
    var proof = try mpt_proof.secureProof(allocator, keys.items, values.items, &address.bytes);
    defer proof.deinit(allocator);

    return proofNodesValue(allocator, proof.nodes);
}

fn proofNodesValue(allocator: std.mem.Allocator, nodes: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer {
        for (array.items) |*item| deinitJsonValue(allocator, item);
        array.deinit();
    }

    for (nodes) |node| {
        try array.append(try bytesValueHex(allocator, node));
    }

    return .{ .array = array };
}

fn collectAccountTrieEntries(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    keys: *std.ArrayList([]const u8),
    values: *std.ArrayList([]const u8),
) !void {
    var addresses = std.AutoHashMap(primitives.Address, void).init(allocator);
    defer addresses.deinit();

    var account_it = sm.accountIterator();
    while (account_it.next()) |entry| {
        try addresses.put(entry.key_ptr.*, {});
    }

    var code_it = sm.journaled_state.contract_cache.cache.keyIterator();
    while (code_it.next()) |address| {
        try addresses.put(address.*, {});
    }

    var storage_it = sm.journaled_state.storage_cache.cache.keyIterator();
    while (storage_it.next()) |address| {
        try addresses.put(address.*, {});
    }

    var address_it = addresses.keyIterator();
    while (address_it.next()) |address_ptr| {
        const address = address_ptr.*;
        const account = sm.journaled_state.account_cache.get(address) orelse state_manager.AccountState.init();
        const storage_root = try computeAccountStorageRootForProof(allocator, sm, address, account.storage_root);
        const account_code_hash = computeAccountCodeHashForProof(sm, address, account.code_hash);

        const encoded_account = primitives.AccountState.AccountState.from(.{
            .nonce = account.nonce,
            .balance = account.balance,
            .storage_root = storage_root,
            .code_hash = account_code_hash,
        });
        const key = try allocator.dupe(u8, &address.bytes);
        var key_owned = true;
        errdefer if (key_owned) allocator.free(key);
        const value = try encoded_account.rlpEncode(allocator);
        var value_owned = true;
        errdefer if (value_owned) allocator.free(value);

        try keys.append(allocator, key);
        key_owned = false;
        try values.append(allocator, value);
        value_owned = false;
    }
}

fn collectStorageTrieEntries(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    address: primitives.Address,
    keys: *std.ArrayList([]const u8),
    values: *std.ArrayList([]const u8),
) !void {
    const slots = sm.journaled_state.storage_cache.cache.getPtr(address) orelse return;

    var it = slots.iterator();
    while (it.next()) |entry| {
        const value = entry.value_ptr.*;
        if (value == 0) continue;

        var slot_bytes: [32]u8 = undefined;
        std.mem.writeInt(u256, &slot_bytes, entry.key_ptr.*, .big);
        const key = try allocator.dupe(u8, &slot_bytes);
        var key_owned = true;
        errdefer if (key_owned) allocator.free(key);
        const encoded_value = try primitives.Rlp.encode(allocator, value);
        var value_owned = true;
        errdefer if (value_owned) allocator.free(encoded_value);

        try keys.append(allocator, key);
        key_owned = false;
        try values.append(allocator, encoded_value);
        value_owned = false;
    }
}

fn computeAccountStorageRootForProof(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    address: primitives.Address,
    fallback_root: [32]u8,
) ![32]u8 {
    var keys = std.ArrayList([]const u8){};
    defer {
        for (keys.items) |key| allocator.free(key);
        keys.deinit(allocator);
    }
    var values = std.ArrayList([]const u8){};
    defer {
        for (values.items) |value| allocator.free(value);
        values.deinit(allocator);
    }

    // No cached slots means storage was never loaded or written here, so the
    // account's recorded root still stands.
    if (sm.journaled_state.storage_cache.cache.getPtr(address) == null) return normalizedStorageRoot(fallback_root);

    try collectStorageTrieEntries(allocator, sm, address, &keys, &values);
    // Cached slots that are all zero mean the storage was cleared. The
    // recorded root is stale; the trie is empty (matches block_builder).
    if (keys.items.len == 0) return primitives.State.EMPTY_TRIE_ROOT;
    return primitives.TrieHash.secure_trie_root(allocator, keys.items, values.items);
}

fn computeAccountCodeHashForProof(
    sm: *state_manager.StateManager,
    address: primitives.Address,
    fallback_hash: [32]u8,
) [32]u8 {
    if (sm.journaled_state.contract_cache.get(address)) |code| {
        if (code.len == 0) return primitives.State.EMPTY_CODE_HASH;
        return codeHash(code);
    }

    return normalizedCodeHash(fallback_hash);
}

fn normalizedStorageRoot(root: [32]u8) [32]u8 {
    if (std.mem.eql(u8, &root, &primitives.Hash.ZERO)) return primitives.State.EMPTY_TRIE_ROOT;
    return root;
}

fn normalizedCodeHash(hash: [32]u8) [32]u8 {
    if (std.mem.eql(u8, &hash, &primitives.Hash.ZERO)) return primitives.State.EMPTY_CODE_HASH;
    return hash;
}

fn codeHash(code: []const u8) [32]u8 {
    if (code.len == 0) return primitives.State.EMPTY_CODE_HASH;
    var out: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(code, &out, .{});
    return out;
}

fn parseProofStorageKey(value: std.json.Value) !u256 {
    if (value == .string and rpc_parse.isHash32(value.string)) {
        const bytes = try rpc_parse.parseHash32String(value.string);
        return std.mem.readInt(u256, &bytes, .big);
    }
    return rpc_parse.parseQuantityValue(u256, value) catch {
        const text = switch (value) {
            .string => |s| s,
            else => return error.InvalidParams,
        };
        if (!rpc_parse.hasHexPrefix(text)) return error.InvalidParams;
        const hex = text[2..];
        if (hex.len == 0 or hex.len > 64 or hex.len % 2 != 0) return error.InvalidParams;
        var bytes: [32]u8 = [_]u8{0} ** 32;
        _ = std.fmt.hexToBytes(bytes[32 - hex.len / 2 ..], hex) catch return error.InvalidParams;
        return std.mem.readInt(u256, &bytes, .big);
    };
}

fn feeHistoryBaseFeeArray(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    range: FeeHistoryRange,
) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer {
        for (array.items) |*item| {
            deinitJsonValue(allocator, item);
        }
        array.deinit();
    }

    for (0..(range.count + 1)) |index| {
        const block_number = range.oldest + @as(u64, @intCast(index));
        try array.append(try quantityValueHexU256(allocator, try feeHistoryBaseFee(rt, block_number)));
    }
    return .{ .array = array };
}

fn feeHistoryGasUsedRatioArray(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    range: FeeHistoryRange,
) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer {
        for (array.items) |*item| {
            deinitJsonValue(allocator, item);
        }
        array.deinit();
    }

    for (0..range.count) |index| {
        const block_number = range.oldest + @as(u64, @intCast(index));
        try array.append(ratioValue(try feeHistoryGasUsedRatio(rt, block_number)));
    }
    return .{ .array = array };
}

fn feeHistoryBlobBaseFeeArray(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    range: FeeHistoryRange,
) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer {
        for (array.items) |*item| {
            deinitJsonValue(allocator, item);
        }
        array.deinit();
    }

    for (0..(range.count + 1)) |index| {
        const block_number = range.oldest + @as(u64, @intCast(index));
        try array.append(try quantityValueHexU256(allocator, try feeHistoryBlobBaseFee(rt, block_number)));
    }
    return .{ .array = array };
}

fn feeHistoryBlobGasUsedRatioArray(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    range: FeeHistoryRange,
) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer {
        for (array.items) |*item| {
            deinitJsonValue(allocator, item);
        }
        array.deinit();
    }

    for (0..range.count) |index| {
        const block_number = range.oldest + @as(u64, @intCast(index));
        try array.append(ratioValue(try feeHistoryBlobGasUsedRatio(rt, block_number)));
    }
    return .{ .array = array };
}

fn ratioValue(value: f64) std.json.Value {
    return .{ .float = value };
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

test "account proof storage root: recorded root without cached slots, empty root once slots are cleared" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const recorded_root = [_]u8{0x11} ** 32;

    // Storage never loaded: the account's recorded root stands.
    const untouched = primitives.Address{ .bytes = [_]u8{0xa1} ** 20 };
    try std.testing.expectEqualSlices(
        u8,
        &recorded_root,
        &(try computeAccountStorageRootForProof(std.testing.allocator, &rt.state, untouched, recorded_root)),
    );
    try std.testing.expectEqualSlices(
        u8,
        &primitives.State.EMPTY_TRIE_ROOT,
        &(try computeAccountStorageRootForProof(std.testing.allocator, &rt.state, untouched, primitives.Hash.ZERO)),
    );

    // Every cached slot is zero: the storage was cleared, so the recorded
    // root is stale and the trie is empty.
    const cleared = primitives.Address{ .bytes = [_]u8{0xa2} ** 20 };
    try rt.state.setStorage(cleared, 1, 5);
    const populated = try computeAccountStorageRootForProof(std.testing.allocator, &rt.state, cleared, recorded_root);
    try std.testing.expect(!std.mem.eql(u8, &populated, &recorded_root));
    try std.testing.expect(!std.mem.eql(u8, &populated, &primitives.State.EMPTY_TRIE_ROOT));

    try rt.state.setStorage(cleared, 1, 0);
    try std.testing.expectEqualSlices(
        u8,
        &primitives.State.EMPTY_TRIE_ROOT,
        &(try computeAccountStorageRootForProof(std.testing.allocator, &rt.state, cleared, recorded_root)),
    );
}
