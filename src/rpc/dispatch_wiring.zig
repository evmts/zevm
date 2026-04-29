//! Wires the JSON-RPC dispatcher to the live NodeRuntime.

const std = @import("std");
const jsonrpc = @import("jsonrpc");
const primitives = @import("primitives");
const dispatcher_mod = @import("dispatcher.zig");
const block_query_handlers = @import("handlers/block_query_handlers.zig");
const eth_read = @import("handlers/eth_read.zig");
const runtime_mod = @import("../node/runtime.zig");
const simulation = @import("handlers/simulation.zig");
const trusted_fork_handlers = @import("trusted_fork_handlers.zig");
const tx_submission = @import("handlers/tx_submission.zig");
const txpool_handlers = @import("handlers/txpool.zig");
const dev_erc20_handlers = @import("handlers/dev_erc20.zig");

var runtime_ptr: ?*runtime_mod.NodeRuntime = null;

pub fn install(registry: *dispatcher_mod.HandlerRegistry, rt: *runtime_mod.NodeRuntime) void {
    runtime_ptr = rt;
    registry.on_method = dispatchMethod;
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

fn parseSendTransactionParams(params: ?std.json.Value) !jsonrpc.eth.SendTransaction.Params {
    const items = try paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    if (items[0] != .object) return error.InvalidParams;
    return .{ .transaction = .{ .value = items[0] } };
}

fn dispatchMethod(
    allocator: std.mem.Allocator,
    method_name: []const u8,
    params: ?std.json.Value,
) anyerror!std.json.Value {
    const rt = runtime_ptr orelse return error.MethodNotFound;

    if (rt.mode == .light) {
        return dispatchLightMethod(allocator, rt, method_name, params);
    }
    if (std.mem.eql(u8, method_name, "zevm_lightSyncStatus")) {
        try validateNoParams(params);
        return error.ModeUnsupported;
    }

    if (std.mem.eql(u8, method_name, "web3_clientVersion")) {
        return .{ .string = try allocator.dupe(u8, "zevm/0.1.0") };
    }
    if (std.mem.eql(u8, method_name, "web3_sha3")) {
        const items = try paramsArrayItems(params);
        if (items.len != 1) return error.InvalidParams;
        const input = switch (items[0]) {
            .string => |s| try hexStringToBytes(allocator, s),
            else => return error.InvalidParams,
        };
        defer allocator.free(input);

        var digest: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(input, &digest, .{});
        return hexBytes(allocator, &digest);
    }
    if (std.mem.eql(u8, method_name, "net_version")) {
        return .{ .string = try std.fmt.allocPrint(allocator, "{d}", .{rt.chain_id}) };
    }
    if (std.mem.eql(u8, method_name, "net_listening")) {
        return .{ .bool = true };
    }
    if (std.mem.eql(u8, method_name, "net_peerCount")) {
        return hexQuantity(allocator, 0);
    }

    if (std.mem.eql(u8, method_name, "eth_chainId")) {
        return hexQuantity(allocator, rt.chain_id);
    }
    if (std.mem.eql(u8, method_name, "eth_blockNumber")) {
        return hexQuantity(allocator, rt.head_block_number);
    }
    if (std.mem.eql(u8, method_name, "eth_gasPrice")) {
        return hexU256(allocator, rt.gas_price);
    }
    if (std.mem.eql(u8, method_name, "eth_maxPriorityFeePerGas")) {
        return hexU256(allocator, rt.max_priority_fee);
    }
    if (std.mem.eql(u8, method_name, "eth_blobBaseFee")) {
        return hexU256(allocator, currentBlobBaseFee(rt));
    }
    if (std.mem.eql(u8, method_name, "eth_feeHistory")) {
        const fee_history_params = try eth_read.parseEthFeeHistoryParams(allocator, params);
        defer eth_read.deinitEthFeeHistoryParams(allocator, fee_history_params);
        return eth_read.handleEthFeeHistoryValue(allocator, rt, fee_history_params);
    }
    if (std.mem.eql(u8, method_name, "eth_coinbase")) {
        return addressString(allocator, rt.coinbase);
    }
    if (std.mem.eql(u8, method_name, "eth_accounts")) {
        return accountsResponse(allocator);
    }
    if (std.mem.eql(u8, method_name, "eth_mining")) {
        return .{ .bool = std.meta.activeTag(rt.mining_config) != .manual };
    }
    if (std.mem.eql(u8, method_name, "eth_syncing")) {
        return .{ .bool = false };
    }
    if (std.mem.eql(u8, method_name, "eth_protocolVersion")) {
        return .{ .string = try allocator.dupe(u8, "0x41") };
    }
    if (std.mem.eql(u8, method_name, "eth_getBalance")) {
        const args = try parseAddrAndBlockArgs(params);
        const balance = try rt.getBalance(args.address);
        return hexU256(allocator, balance);
    }
    if (std.mem.eql(u8, method_name, "eth_getTransactionCount")) {
        const args = try parseAddrAndBlockArgs(params);
        const nonce = try rt.getNonce(args.address);
        return hexQuantity(allocator, nonce);
    }
    if (std.mem.eql(u8, method_name, "eth_getCode")) {
        const args = try parseAddrAndBlockArgs(params);
        const code = try rt.getCode(args.address);
        return hexBytes(allocator, code);
    }
    if (std.mem.eql(u8, method_name, "eth_getStorageAt")) {
        const args = try parseStorageArgs(params);
        const value = try rt.getStorage(args.address, args.slot);
        return dataHexU256(allocator, value);
    }
    if (std.mem.eql(u8, method_name, "eth_sendTransaction")) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const parsed_params = try parseSendTransactionParams(params);
        const result = tx_submission.handleSendTransaction(arena.allocator(), rt, parsed_params) catch |err| switch (err) {
            error.InvalidHexData,
            error.DecodeFailed,
            error.UnsupportedTxType,
            => return error.InvalidParams,
            else => return err,
        };
        return typedResultToJsonValue(allocator, result);
    }
    if (std.mem.eql(u8, method_name, "eth_sendRawTransaction")) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const parsed_params = try parseSendRawTransactionParams(params);
        const result = tx_submission.handleSendRawTransaction(arena.allocator(), rt, parsed_params) catch |err| switch (err) {
            error.InvalidHexData,
            error.DecodeFailed,
            error.UnsupportedTxType,
            error.SenderRecoveryFailed,
            => return error.InvalidParams,
            else => return err,
        };
        return typedResultToJsonValue(allocator, result);
    }
    if (std.mem.eql(u8, method_name, "eth_getBlockByNumber")) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var ctx = blockQueryContext(rt);
        const result = try block_query_handlers.handleGetBlockByNumber(
            arena.allocator(),
            &ctx,
            try parseGetBlockByNumberParams(params),
        );
        return typedResultToJsonValue(allocator, result);
    }
    if (std.mem.eql(u8, method_name, "eth_getBlockByHash")) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var ctx = blockQueryContext(rt);
        const result = try block_query_handlers.handleGetBlockByHash(
            arena.allocator(),
            &ctx,
            try parseGetBlockByHashParams(allocator, params),
        );
        return typedResultToJsonValue(allocator, result);
    }
    if (std.mem.eql(u8, method_name, "eth_getBlockTransactionCountByHash")) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var ctx = blockQueryContext(rt);
        const result = try block_query_handlers.handleGetBlockTransactionCountByHash(
            arena.allocator(),
            &ctx,
            try parseGetBlockTransactionCountByHashParams(allocator, params),
        );
        return typedResultToJsonValue(allocator, result);
    }
    if (std.mem.eql(u8, method_name, "eth_getBlockTransactionCountByNumber")) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var ctx = blockQueryContext(rt);
        const result = try block_query_handlers.handleGetBlockTransactionCountByNumber(
            arena.allocator(),
            &ctx,
            try parseGetBlockTransactionCountByNumberParams(params),
        );
        return typedResultToJsonValue(allocator, result);
    }
    if (std.mem.eql(u8, method_name, "eth_getTransactionByHash")) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var ctx = blockQueryContext(rt);
        const result = try block_query_handlers.handleGetTransactionByHash(
            arena.allocator(),
            &ctx,
            try parseGetTransactionByHashParams(allocator, params),
        );
        return typedResultToJsonValue(allocator, result);
    }
    if (std.mem.eql(u8, method_name, "eth_getTransactionByBlockHashAndIndex")) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var ctx = blockQueryContext(rt);
        const result = try block_query_handlers.handleGetTransactionByBlockHashAndIndex(
            arena.allocator(),
            &ctx,
            try parseGetTransactionByBlockHashAndIndexParams(allocator, params),
        );
        return typedResultToJsonValue(allocator, result);
    }
    if (std.mem.eql(u8, method_name, "eth_getTransactionByBlockNumberAndIndex")) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var ctx = blockQueryContext(rt);
        const result = try block_query_handlers.handleGetTransactionByBlockNumberAndIndex(
            arena.allocator(),
            &ctx,
            try parseGetTransactionByBlockNumberAndIndexParams(params),
        );
        return typedResultToJsonValue(allocator, result);
    }
    if (std.mem.eql(u8, method_name, "eth_getTransactionReceipt")) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var ctx = blockQueryContext(rt);
        const result = try block_query_handlers.handleGetTransactionReceipt(
            arena.allocator(),
            &ctx,
            try parseGetTransactionReceiptParams(allocator, params),
        );
        return typedResultToJsonValue(allocator, result);
    }
    if (std.mem.eql(u8, method_name, "eth_getBlockReceipts")) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var ctx = blockQueryContext(rt);
        const result = try block_query_handlers.handleGetBlockReceipts(
            arena.allocator(),
            &ctx,
            try parseGetBlockReceiptsParams(params),
        );
        return typedResultToJsonValue(allocator, result);
    }
    if (std.mem.eql(u8, method_name, "eth_getLogs")) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var ctx = blockQueryContext(rt);
        const result = try block_query_handlers.handleGetLogs(
            arena.allocator(),
            &ctx,
            try parseGetLogsParams(params),
        );
        return typedResultToJsonValue(allocator, result);
    }
    if (std.mem.eql(u8, method_name, "txpool_content")) {
        return txpool_handlers.handleContent(allocator, rt, params);
    }
    if (std.mem.eql(u8, method_name, "txpool_status")) {
        return txpool_handlers.handleStatus(allocator, rt, params);
    }
    if (std.mem.eql(u8, method_name, "txpool_inspect")) {
        return txpool_handlers.handleInspect(allocator, rt, params);
    }
    if (std.mem.eql(u8, method_name, "eth_call")) {
        return simulation.handleEthCall(allocator, rt, params);
    }
    if (std.mem.eql(u8, method_name, "eth_estimateGas")) {
        return simulation.handleEthEstimateGas(allocator, rt, params);
    }

    if (methodIs(method_name, &.{ "zevm_reset", "anvil_reset", "hardhat_reset" })) {
        return trusted_fork_handlers.handleZevmReset(rt, params);
    }
    if (methodIs(method_name, &.{ "zevm_setRpcUrl", "anvil_setRpcUrl" })) {
        return trusted_fork_handlers.handleZevmSetRpcUrl(allocator, rt, params);
    }
    if (methodIs(method_name, &.{ "zevm_setBalance", "anvil_setBalance", "hardhat_setBalance" })) {
        const args = try parseAddrU256Args(params);
        try rt.setBalance(args.address, args.value);
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_setNonce", "anvil_setNonce", "hardhat_setNonce" })) {
        const args = try parseAddrU64Args(params);
        try rt.setNonce(args.address, args.value);
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_setCode", "anvil_setCode", "hardhat_setCode" })) {
        const args = try parseSetCodeArgs(allocator, params);
        defer allocator.free(args.code);
        try rt.setCode(args.address, args.code);
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_setStorageAt", "anvil_setStorageAt", "hardhat_setStorageAt" })) {
        const args = try parseSetStorageArgs(params);
        try rt.setStorage(args.address, args.slot, args.value);
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_setERC20Balance", "anvil_setERC20Balance", "hardhat_setERC20Balance" })) {
        return dev_erc20_handlers.handleSetERC20Balance(rt, params);
    }
    if (methodIs(method_name, &.{ "zevm_setERC20Allowance", "anvil_setERC20Allowance", "hardhat_setERC20Allowance" })) {
        return dev_erc20_handlers.handleSetERC20Allowance(rt, params);
    }
    if (methodIs(method_name, &.{ "zevm_setCoinbase", "anvil_setCoinbase", "hardhat_setCoinbase" })) {
        const items = try paramsArrayItems(params);
        if (items.len != 1) return error.InvalidParams;
        rt.coinbase = try parseAddressJson(items[0]);
        rt.dev_runtime.config.coinbase = rt.coinbase;
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_setBlockGasLimit", "anvil_setBlockGasLimit", "hardhat_setBlockGasLimit", "evm_setBlockGasLimit" })) {
        const items = try paramsArrayItems(params);
        if (items.len != 1) return error.InvalidParams;
        rt.dev_runtime.config.block_gas_limit = try parseU64Json(items[0]);
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_setNextBlockBaseFeePerGas", "anvil_setNextBlockBaseFeePerGas", "hardhat_setNextBlockBaseFeePerGas" })) {
        const items = try paramsArrayItems(params);
        if (items.len != 1) return error.InvalidParams;
        rt.dev_runtime.config.next_block_base_fee_per_gas = try parseU256Json(items[0]);
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_setNextBlockTimestamp", "anvil_setNextBlockTimestamp", "hardhat_setNextBlockTimestamp", "evm_setNextBlockTimestamp" })) {
        rt.setNextBlockTimestamp(try parseTimeControlQuantity(params));
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_setBlobBaseFee", "anvil_setBlobBaseFee", "hardhat_setBlobBaseFee" })) {
        const items = try paramsArrayItems(params);
        if (items.len != 1) return error.InvalidParams;
        const blob_base_fee = try parseU256Json(items[0]);
        rt.dev_runtime.config.blob_base_fee = blob_base_fee;
        rt.blob_base_fee = blob_base_fee;
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_impersonateAccount", "anvil_impersonateAccount", "hardhat_impersonateAccount" })) {
        const address = try parseSingleAddressArg(params);
        try rt.impersonateAccount(address);
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_stopImpersonatingAccount", "anvil_stopImpersonatingAccount", "hardhat_stopImpersonatingAccount" })) {
        const address = try parseSingleAddressArg(params);
        rt.stopImpersonatingAccount(address);
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{
        "zevm_setAutoImpersonateAccount",
        "anvil_setAutoImpersonateAccount",
        "hardhat_setAutoImpersonateAccount",
        "zevm_autoImpersonateAccount",
        "anvil_autoImpersonateAccount",
    })) {
        const enabled = try parseSingleBoolArg(params);
        rt.setAutoImpersonateAccount(enabled);
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_increaseTime", "anvil_increaseTime", "evm_increaseTime" })) {
        const seconds = try parseTimeControlQuantity(params);
        return hexQuantity(allocator, try rt.increaseTime(seconds));
    }
    if (methodIs(method_name, &.{ "zevm_setTime", "anvil_setTime", "evm_setTime" })) {
        const timestamp = try parseTimeControlQuantity(params);
        return hexQuantity(allocator, try rt.setTime(timestamp));
    }
    if (methodIs(method_name, &.{ "zevm_snapshot", "anvil_snapshot", "evm_snapshot" })) {
        return hexQuantity(allocator, try rt.snapshot());
    }
    if (methodIs(method_name, &.{ "zevm_revert", "anvil_revert", "evm_revert" })) {
        const snapshot_id = try parseSnapshotId(params);
        return .{ .bool = try rt.revertToSnapshot(snapshot_id) };
    }
    if (methodIs(method_name, &.{ "zevm_mine", "anvil_mine", "evm_mine", "hardhat_mine" })) {
        const args = try parseMineArgs(params);
        try rt.mineBlocks(args.count, args.interval_seconds);
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_setAutomine", "anvil_setAutomine", "evm_setAutomine" })) {
        const enabled = try parseSetAutomineArgs(params);
        rt.setAutomine(enabled);
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_setIntervalMining", "anvil_setIntervalMining", "evm_setIntervalMining" })) {
        const seconds = try parseSetIntervalMiningArgs(params);
        rt.setIntervalMining(seconds);
        return .{ .bool = true };
    }

    return error.MethodNotFound;
}

fn dispatchLightMethod(
    allocator: std.mem.Allocator,
    rt: *runtime_mod.NodeRuntime,
    method_name: []const u8,
    params: ?std.json.Value,
) !std.json.Value {
    if (std.mem.eql(u8, method_name, "zevm_lightSyncStatus")) {
        try validateNoParams(params);
        rt.refreshLightSyncForStatus();
        return lightSyncStatusValue(allocator, rt);
    }
    if (std.mem.eql(u8, method_name, "eth_chainId")) {
        try validateNoParams(params);
        return hexQuantity(allocator, rt.chain_id);
    }
    if (std.mem.eql(u8, method_name, "eth_blockNumber")) {
        try validateNoParams(params);
        try rt.refreshLightSyncForRequest();
        if (!rt.isLightReady()) return error.LightNotReady;
        return hexQuantity(allocator, rt.head_block_number);
    }
    if (methodIs(method_name, &.{ "eth_getBalance", "eth_getCode", "eth_getStorageAt", "eth_getTransactionCount" })) {
        return dispatchLightProofRead(allocator, rt, method_name, params);
    }

    if (isLightModeUnsupportedMethod(method_name)) {
        try validateLightUnsupportedParams(allocator, method_name, params);
        return error.ModeUnsupported;
    }

    return error.MethodNotFound;
}

fn lightSyncStatusValue(allocator: std.mem.Allocator, rt: *const runtime_mod.NodeRuntime) !std.json.Value {
    const network = rt.lightNetwork() orelse return error.ModeUnsupported;
    const checkpoint_source = rt.lightCheckpointSource() orelse return error.ModeUnsupported;
    const last_checkpoint = rt.lightLastCheckpoint() orelse return error.InternalError;

    var obj = std.json.ObjectMap.init(allocator);
    errdefer {
        var value = std.json.Value{ .object = obj };
        deinitJsonValue(allocator, &value);
    }

    try putOwnedJson(&obj, allocator, "status", .{ .string = try allocator.dupe(u8, lightStatusText(rt.lightStatus())) });
    try putOwnedJson(&obj, allocator, "ready", .{ .bool = rt.isLightReady() });
    try putOwnedJson(&obj, allocator, "network", .{ .string = try allocator.dupe(u8, network.name()) });
    try putOwnedJson(&obj, allocator, "checkpointSource", .{ .string = try allocator.dupe(u8, checkpoint_source.name()) });
    try putOwnedJson(&obj, allocator, "lastCheckpoint", try hexHash32(allocator, last_checkpoint));
    try putOwnedJson(&obj, allocator, "optimisticSlot", try hexQuantity(allocator, rt.lightOptimisticSlot()));
    try putOwnedJson(&obj, allocator, "safeSlot", try hexQuantity(allocator, rt.lightSafeSlot()));
    try putOwnedJson(&obj, allocator, "finalizedSlot", try hexQuantity(allocator, rt.lightFinalizedSlot()));

    return .{ .object = obj };
}

fn lightStatusText(status: @import("../consensus_sync.zig").SyncStatus) []const u8 {
    return switch (status) {
        .syncing => "syncing",
        .synced => "synced",
        .err => "error",
    };
}

const LightBlockSelector = union(enum) {
    latest,
    earliest,
    pending,
    safe,
    finalized,
    number: u64,
};

const LightAddrBlockArgs = struct {
    address: primitives.Address,
    selector: LightBlockSelector,
};

const LightStorageArgs = struct {
    address: primitives.Address,
    slot: u256,
    selector: LightBlockSelector,
};

fn dispatchLightProofRead(
    allocator: std.mem.Allocator,
    rt: *runtime_mod.NodeRuntime,
    method_name: []const u8,
    params: ?std.json.Value,
) !std.json.Value {
    if (std.mem.eql(u8, method_name, "eth_getStorageAt")) {
        const args = try parseLightStorageArgs(params);
        try applyLightReadGates(rt, args.selector);
        const value = try rt.lightGetStorage(runtimeLightSelector(args.selector), args.address, args.slot);
        return dataHexU256(allocator, value);
    }

    const args = try parseLightAddrBlockArgs(params);
    try applyLightReadGates(rt, args.selector);

    if (std.mem.eql(u8, method_name, "eth_getBalance")) {
        return hexU256(allocator, try rt.lightGetBalance(runtimeLightSelector(args.selector), args.address));
    }
    if (std.mem.eql(u8, method_name, "eth_getCode")) {
        const code = try rt.lightGetCode(runtimeLightSelector(args.selector), args.address);
        defer allocator.free(code);
        return hexBytes(allocator, code);
    }
    if (std.mem.eql(u8, method_name, "eth_getTransactionCount")) {
        return hexQuantity(allocator, try rt.lightGetNonce(runtimeLightSelector(args.selector), args.address));
    }

    return error.MethodNotFound;
}

fn runtimeLightSelector(selector: LightBlockSelector) runtime_mod.LightReadSelector {
    return switch (selector) {
        .latest => .latest,
        .safe => .safe,
        .finalized => .finalized,
        .earliest => .earliest,
        .number => |block_number| .{ .number = block_number },
        .pending => unreachable,
    };
}

fn applyLightReadGates(rt: *runtime_mod.NodeRuntime, selector: LightBlockSelector) !void {
    switch (selector) {
        .pending => return error.ModeUnsupported,
        else => {},
    }
    if (!rt.isLightReady()) return error.LightNotReady;
    try rt.refreshLightSyncForRequest();
    if (!rt.isLightReady()) return error.LightNotReady;
    try validateLightRetainedWindow(rt, selector);
}

fn validateLightRetainedWindow(rt: *const runtime_mod.NodeRuntime, selector: LightBlockSelector) !void {
    switch (selector) {
        .number => |block_number| {
            if (block_number == 0) return;
            const head = rt.head_block_number;
            const low = if (head > 8190) head - 8190 else 1;
            if (block_number < low or block_number > head) return error.InvalidParams;
        },
        else => {},
    }
}

fn parseLightAddrBlockArgs(params: ?std.json.Value) !LightAddrBlockArgs {
    const items = try paramsArrayItems(params);
    if (items.len != 2) return error.InvalidParams;
    return .{
        .address = try parseAddressJson(items[0]),
        .selector = try parseLightBlockSelectorJson(items[1]),
    };
}

fn parseLightStorageArgs(params: ?std.json.Value) !LightStorageArgs {
    const items = try paramsArrayItems(params);
    if (items.len != 3) return error.InvalidParams;
    return .{
        .address = try parseAddressJson(items[0]),
        .slot = try parseU256Json(items[1]),
        .selector = try parseLightBlockSelectorJson(items[2]),
    };
}

fn parseLightBlockSelectorJson(value: std.json.Value) !LightBlockSelector {
    const text = switch (value) {
        .string => |str| str,
        else => return error.InvalidParams,
    };
    if (std.mem.eql(u8, text, "latest")) return .latest;
    if (std.mem.eql(u8, text, "earliest")) return .earliest;
    if (std.mem.eql(u8, text, "pending")) return .pending;
    if (std.mem.eql(u8, text, "safe")) return .safe;
    if (std.mem.eql(u8, text, "finalized")) return .finalized;
    if (isQuantityHex(text)) return .{ .number = try parseU64String(text) };
    return error.InvalidParams;
}

fn validateNoParams(params: ?std.json.Value) !void {
    const value = params orelse return;
    const items = switch (value) {
        .array => |array| array.items,
        else => return error.InvalidParams,
    };
    if (items.len != 0) return error.InvalidParams;
}

fn isLightModeUnsupportedMethod(method_name: []const u8) bool {
    if (std.mem.eql(u8, method_name, "zevm_lightSyncStatus")) return false;
    if (std.mem.startsWith(u8, method_name, "zevm_") or
        std.mem.startsWith(u8, method_name, "dev_") or
        std.mem.startsWith(u8, method_name, "anvil_") or
        std.mem.startsWith(u8, method_name, "hardhat_") or
        std.mem.startsWith(u8, method_name, "evm_"))
    {
        return true;
    }
    return methodIs(method_name, &.{
        "web3_clientVersion",
        "web3_sha3",
        "net_version",
        "net_listening",
        "net_peerCount",
        "eth_gasPrice",
        "eth_maxPriorityFeePerGas",
        "eth_blobBaseFee",
        "eth_feeHistory",
        "eth_coinbase",
        "eth_accounts",
        "eth_mining",
        "eth_syncing",
        "eth_protocolVersion",
        "eth_call",
        "eth_estimateGas",
        "eth_sendTransaction",
        "eth_sendRawTransaction",
        "eth_getBlockByNumber",
        "eth_getBlockByHash",
        "eth_getBlockTransactionCountByHash",
        "eth_getBlockTransactionCountByNumber",
        "eth_getTransactionByHash",
        "eth_getTransactionByBlockHashAndIndex",
        "eth_getTransactionByBlockNumberAndIndex",
        "eth_getTransactionReceipt",
        "eth_getBlockReceipts",
        "eth_getLogs",
        "txpool_content",
        "txpool_status",
        "txpool_inspect",
    });
}

fn validateLightUnsupportedParams(
    allocator: std.mem.Allocator,
    method_name: []const u8,
    params: ?std.json.Value,
) !void {
    if (methodIs(method_name, &.{
        "web3_clientVersion",
        "net_version",
        "net_listening",
        "net_peerCount",
        "eth_gasPrice",
        "eth_maxPriorityFeePerGas",
        "eth_blobBaseFee",
        "eth_coinbase",
        "eth_accounts",
        "eth_mining",
        "eth_syncing",
        "eth_protocolVersion",
        "txpool_content",
        "txpool_status",
        "txpool_inspect",
    })) {
        return validateNoParams(params);
    }
    if (std.mem.eql(u8, method_name, "web3_sha3")) {
        const items = try paramsArrayItems(params);
        if (items.len != 1) return error.InvalidParams;
        switch (items[0]) {
            .string => |s| try validateHexData(s),
            else => return error.InvalidParams,
        }
        return;
    }
    if (std.mem.eql(u8, method_name, "eth_feeHistory")) {
        const fee_history_params = try eth_read.parseEthFeeHistoryParams(allocator, params);
        eth_read.deinitEthFeeHistoryParams(allocator, fee_history_params);
        return;
    }
    if (std.mem.eql(u8, method_name, "eth_call")) {
        const items = try paramsArrayItems(params);
        if (items.len != 2 and items.len != 3) return error.InvalidParams;
        try validateTransactionRequestJson(items[0]);
        _ = try parseLightBlockSelectorJson(items[1]);
        if (items.len == 3 and items[2] != .object) return error.InvalidParams;
        return;
    }
    if (std.mem.eql(u8, method_name, "eth_estimateGas")) {
        const items = try paramsArrayItems(params);
        if (items.len < 1 or items.len > 3) return error.InvalidParams;
        try validateTransactionRequestJson(items[0]);
        if (items.len >= 2) _ = try parseLightBlockSelectorJson(items[1]);
        if (items.len == 3 and items[2] != .object) return error.InvalidParams;
        return;
    }
    if (std.mem.eql(u8, method_name, "eth_sendTransaction")) {
        const items = try paramsArrayItems(params);
        if (items.len != 1) return error.InvalidParams;
        try validateTransactionRequestJson(items[0]);
        return;
    }
    if (std.mem.eql(u8, method_name, "eth_sendRawTransaction")) {
        const items = try paramsArrayItems(params);
        if (items.len != 1) return error.InvalidParams;
        switch (items[0]) {
            .string => |s| try validateHexData(s),
            else => return error.InvalidParams,
        }
        return;
    }
    if (std.mem.eql(u8, method_name, "eth_getBlockByNumber")) {
        const items = try paramsArrayItems(params);
        if (items.len != 2) return error.InvalidParams;
        _ = try parseLightBlockSelectorJson(items[0]);
        if (items[1] != .bool) return error.InvalidParams;
        return;
    }
    if (std.mem.eql(u8, method_name, "eth_getBlockTransactionCountByNumber")) {
        const items = try paramsArrayItems(params);
        if (items.len != 1) return error.InvalidParams;
        _ = try parseLightBlockSelectorJson(items[0]);
        return;
    }
    if (std.mem.eql(u8, method_name, "eth_getTransactionByBlockNumberAndIndex")) {
        const items = try paramsArrayItems(params);
        if (items.len != 2) return error.InvalidParams;
        _ = try parseLightBlockSelectorJson(items[0]);
        _ = try parseU64Json(items[1]);
        return;
    }
    if (std.mem.eql(u8, method_name, "eth_getBlockReceipts")) {
        const items = try paramsArrayItems(params);
        if (items.len != 1) return error.InvalidParams;
        try validateReceiptSelectorJson(items[0]);
        return;
    }
    if (std.mem.eql(u8, method_name, "eth_getLogs")) {
        const items = try paramsArrayItems(params);
        if (items.len != 1 or items[0] != .object) return error.InvalidParams;
        return;
    }
    if (methodIs(method_name, &.{
        "eth_getBlockByHash",
        "eth_getBlockTransactionCountByHash",
        "eth_getTransactionByHash",
        "eth_getTransactionByBlockHashAndIndex",
        "eth_getTransactionReceipt",
    })) {
        const items = try paramsArrayItems(params);
        if (items.len == 0) return error.InvalidParams;
        try validateHash32Json(items[0]);
        return;
    }
}

fn validateTransactionRequestJson(value: std.json.Value) !void {
    const obj = switch (value) {
        .object => |object| object,
        else => return error.InvalidParams,
    };

    var data_value: ?[]const u8 = null;
    var input_value: ?[]const u8 = null;
    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const field = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "from")) {
            _ = try parseAddressJson(field);
        } else if (std.mem.eql(u8, key, "to")) {
            if (field != .null) _ = try parseAddressJson(field);
        } else if (std.mem.eql(u8, key, "gas") or
            std.mem.eql(u8, key, "gasPrice") or
            std.mem.eql(u8, key, "value") or
            std.mem.eql(u8, key, "nonce"))
        {
            _ = try parseU256Json(field);
        } else if (std.mem.eql(u8, key, "data")) {
            data_value = switch (field) {
                .string => |s| s,
                else => return error.InvalidParams,
            };
            try validateHexData(data_value.?);
        } else if (std.mem.eql(u8, key, "input")) {
            input_value = switch (field) {
                .string => |s| s,
                else => return error.InvalidParams,
            };
            try validateHexData(input_value.?);
        } else {
            return error.InvalidParams;
        }
    }
    if (data_value != null and input_value != null and !std.mem.eql(u8, data_value.?, input_value.?)) {
        return error.InvalidParams;
    }
}

fn validateReceiptSelectorJson(value: std.json.Value) !void {
    if (value == .string) {
        if (isHash32(value.string)) return;
        _ = try parseLightBlockSelectorJson(value);
        return;
    }
    return error.InvalidParams;
}

fn validateHash32Json(value: std.json.Value) !void {
    const text = switch (value) {
        .string => |s| s,
        else => return error.InvalidParams,
    };
    if (!isHash32(text)) return error.InvalidParams;
}

fn validateHexData(text: []const u8) !void {
    if (!hasHexPrefix(text)) return error.InvalidParams;
    const hex = text[2..];
    if (hex.len % 2 != 0) return error.InvalidParams;
    var index: usize = 0;
    while (index < hex.len) : (index += 1) {
        _ = std.fmt.charToDigit(hex[index], 16) catch return error.InvalidParams;
    }
}

fn isHash32(text: []const u8) bool {
    if (!hasHexPrefix(text)) return false;
    if (text.len != 66) return false;
    for (text[2..]) |c| {
        _ = std.fmt.charToDigit(c, 16) catch return false;
    }
    return true;
}

const AddrBlockArgs = struct {
    address: primitives.Address,
};

const StorageArgs = struct {
    address: primitives.Address,
    slot: u256,
};

const AddrU256Args = struct {
    address: primitives.Address,
    value: u256,
};

const AddrU64Args = struct {
    address: primitives.Address,
    value: u64,
};

const CodeArgs = struct {
    address: primitives.Address,
    code: []u8,
};

const StorageSetArgs = struct {
    address: primitives.Address,
    slot: u256,
    value: u256,
};

const MineArgs = struct {
    count: u64,
    interval_seconds: u64,
};

fn paramsArrayItems(params: ?std.json.Value) ![]const std.json.Value {
    const value = params orelse return error.InvalidParams;
    return switch (value) {
        .array => |array| array.items,
        else => error.InvalidParams,
    };
}

fn parseAddrAndBlockArgs(params: ?std.json.Value) !AddrBlockArgs {
    const items = try paramsArrayItems(params);
    if (items.len != 2) return error.InvalidParams;
    try validateBlockSpecJson(items[1]);
    return .{ .address = try parseAddressJson(items[0]) };
}

fn parseStorageArgs(params: ?std.json.Value) !StorageArgs {
    const items = try paramsArrayItems(params);
    if (items.len != 3) return error.InvalidParams;
    try validateBlockSpecJson(items[2]);
    return .{
        .address = try parseAddressJson(items[0]),
        .slot = try parseU256Json(items[1]),
    };
}

fn parseAddrU256Args(params: ?std.json.Value) !AddrU256Args {
    const items = try paramsArrayItems(params);
    if (items.len != 2) return error.InvalidParams;
    return .{
        .address = try parseAddressJson(items[0]),
        .value = try parseU256Json(items[1]),
    };
}

fn parseAddrU64Args(params: ?std.json.Value) !AddrU64Args {
    const items = try paramsArrayItems(params);
    if (items.len != 2) return error.InvalidParams;
    return .{
        .address = try parseAddressJson(items[0]),
        .value = try parseU64Json(items[1]),
    };
}

fn parseSetCodeArgs(allocator: std.mem.Allocator, params: ?std.json.Value) !CodeArgs {
    const items = try paramsArrayItems(params);
    if (items.len != 2) return error.InvalidParams;
    const code = switch (items[1]) {
        .string => |s| try hexStringToBytes(allocator, s),
        else => return error.InvalidParams,
    };
    return .{
        .address = try parseAddressJson(items[0]),
        .code = code,
    };
}

fn parseSetStorageArgs(params: ?std.json.Value) !StorageSetArgs {
    const items = try paramsArrayItems(params);
    if (items.len != 3) return error.InvalidParams;
    return .{
        .address = try parseAddressJson(items[0]),
        .slot = try parseU256Json(items[1]),
        .value = try parseU256Json(items[2]),
    };
}

fn parseSnapshotId(params: ?std.json.Value) !u64 {
    const items = try paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    return parseU64Json(items[0]);
}

fn parseSingleAddressArg(params: ?std.json.Value) !primitives.Address {
    const items = try paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    return parseAddressJson(items[0]);
}

fn parseSingleBoolArg(params: ?std.json.Value) !bool {
    const items = try paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    return switch (items[0]) {
        .bool => |enabled| enabled,
        else => error.InvalidParams,
    };
}

fn parseMineArgs(params: ?std.json.Value) !MineArgs {
    const items = try paramsArrayItems(params);
    if (items.len > 2) return error.InvalidParams;
    if (items.len == 0) {
        return .{
            .count = 1,
            .interval_seconds = 0,
        };
    }

    return .{
        .count = try parseQuantityU64Json(items[0]),
        .interval_seconds = if (items.len == 2) try parseQuantityU64Json(items[1]) else 0,
    };
}

fn parseSetAutomineArgs(params: ?std.json.Value) !bool {
    const items = try paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    return switch (items[0]) {
        .bool => |enabled| enabled,
        else => error.InvalidParams,
    };
}

fn parseSetIntervalMiningArgs(params: ?std.json.Value) !u64 {
    const items = try paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    return parseQuantityU64Json(items[0]);
}

fn parseTimeControlQuantity(params: ?std.json.Value) !u64 {
    const items = try paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    return parseQuantityU64Json(items[0]);
}

fn blockQueryContext(rt: *runtime_mod.NodeRuntime) block_query_handlers.BlockQueryContext {
    return .{
        .rt = rt,
        .blockchain = &rt.blockchain,
        .receipt_index = &rt.receipt_index,
        .log_index = &rt.log_index,
    };
}

fn typedResultToJsonValue(allocator: std.mem.Allocator, result: anytype) !std.json.Value {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();

    var writer = std.Io.Writer.Allocating.init(scratch.allocator());
    defer writer.deinit();

    try std.json.Stringify.value(result, .{}, &writer.writer);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, writer.written(), .{
        .allocate = .alloc_always,
    });
    return parsed.value;
}

fn parseSendRawTransactionParams(params: ?std.json.Value) !jsonrpc.eth.SendRawTransaction.Params {
    const items = try paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    try validateHexDataValue(items[0]);
    return .{ .transaction = .{ .value = items[0] } };
}

fn parseGetBlockByNumberParams(params: ?std.json.Value) !jsonrpc.eth.GetBlockByNumber.Params {
    const items = try paramsArrayItems(params);
    if (items.len != 2) return error.InvalidParams;
    try validateTrustedBlockSelectorValue(items[0]);
    return .{
        .block = .{ .value = items[0] },
        .hydrated_transactions = try parseBoolJson(items[1]),
    };
}

fn parseGetBlockByHashParams(
    allocator: std.mem.Allocator,
    params: ?std.json.Value,
) !jsonrpc.eth.GetBlockByHash.Params {
    const items = try paramsArrayItems(params);
    if (items.len != 2) return error.InvalidParams;
    return .{
        .block_hash = try parseHashJson(allocator, items[0]),
        .hydrated_transactions = try parseBoolJson(items[1]),
    };
}

fn parseGetBlockTransactionCountByHashParams(
    allocator: std.mem.Allocator,
    params: ?std.json.Value,
) !jsonrpc.eth.GetBlockTransactionCountByHash.Params {
    const items = try paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    return .{ .block_hash = try parseHashJson(allocator, items[0]) };
}

fn parseGetBlockTransactionCountByNumberParams(params: ?std.json.Value) !jsonrpc.eth.GetBlockTransactionCountByNumber.Params {
    const items = try paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    try validateTrustedBlockSelectorValue(items[0]);
    return .{ .block = .{ .value = items[0] } };
}

fn parseGetTransactionByHashParams(
    allocator: std.mem.Allocator,
    params: ?std.json.Value,
) !jsonrpc.eth.GetTransactionByHash.Params {
    const items = try paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    return .{ .transaction_hash = try parseHashJson(allocator, items[0]) };
}

fn parseGetTransactionByBlockHashAndIndexParams(
    allocator: std.mem.Allocator,
    params: ?std.json.Value,
) !jsonrpc.eth.GetTransactionByBlockHashAndIndex.Params {
    const items = try paramsArrayItems(params);
    if (items.len != 2) return error.InvalidParams;
    try validateQuantityValue(items[1]);
    return .{
        .block_hash = try parseHashJson(allocator, items[0]),
        .transaction_index = .{ .value = items[1] },
    };
}

fn parseGetTransactionByBlockNumberAndIndexParams(params: ?std.json.Value) !jsonrpc.eth.GetTransactionByBlockNumberAndIndex.Params {
    const items = try paramsArrayItems(params);
    if (items.len != 2) return error.InvalidParams;
    try validateTrustedBlockSelectorValue(items[0]);
    try validateQuantityValue(items[1]);
    return .{
        .block = .{ .value = items[0] },
        .transaction_index = .{ .value = items[1] },
    };
}

fn parseGetTransactionReceiptParams(
    allocator: std.mem.Allocator,
    params: ?std.json.Value,
) !jsonrpc.eth.GetTransactionReceipt.Params {
    const items = try paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    return .{ .transaction_hash = try parseHashJson(allocator, items[0]) };
}

fn parseGetBlockReceiptsParams(params: ?std.json.Value) !jsonrpc.eth.GetBlockReceipts.Params {
    const items = try paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    try validateReceiptSelectorValue(items[0]);
    return .{ .block = .{ .value = items[0] } };
}

fn parseGetLogsParams(params: ?std.json.Value) !jsonrpc.eth.GetLogs.Params {
    const items = try paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    if (items[0] != .object) return error.InvalidParams;
    return .{ .filter = .{ .value = items[0] } };
}

fn parseHashJson(allocator: std.mem.Allocator, value: std.json.Value) !jsonrpc.types.Hash {
    _ = allocator;
    const text = switch (value) {
        .string => |s| s,
        else => return error.InvalidParams,
    };
    if (!isHash32(text)) return error.InvalidParams;
    var bytes: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, text[2..]) catch return error.InvalidParams;
    return .{ .bytes = bytes };
}

fn parseBoolJson(value: std.json.Value) !bool {
    return switch (value) {
        .bool => |b| b,
        else => error.InvalidParams,
    };
}

fn validateTrustedBlockSelectorValue(value: std.json.Value) !void {
    switch (value) {
        .integer => |n| if (n < 0) return error.InvalidParams,
        .string => |s| if (!isTrustedBlockSelectorString(s)) return error.InvalidParams,
        else => return error.InvalidParams,
    }
}

fn validateReceiptSelectorValue(value: std.json.Value) !void {
    switch (value) {
        .integer => |n| if (n < 0) return error.InvalidParams,
        .string => |s| {
            if (!isTrustedBlockSelectorString(s) and !isHashString(s)) return error.InvalidParams;
        },
        else => return error.InvalidParams,
    }
}

fn validateQuantityValue(value: std.json.Value) !void {
    switch (value) {
        .integer => |n| if (n < 0) return error.InvalidParams,
        .string => |s| {
            if (!isQuantityHex(s)) return error.InvalidParams;
            _ = std.fmt.parseInt(u64, s[2..], 16) catch return error.InvalidParams;
        },
        else => return error.InvalidParams,
    }
}

fn validateHexDataValue(value: std.json.Value) !void {
    const text = switch (value) {
        .string => |s| s,
        else => return error.InvalidParams,
    };
    if (!hasHexPrefix(text)) return error.InvalidParams;
    const hex = text[2..];
    if (hex.len % 2 != 0) return error.InvalidParams;
    var index: usize = 0;
    while (index < hex.len) : (index += 1) {
        _ = std.fmt.charToDigit(hex[index], 16) catch return error.InvalidParams;
    }
}

fn isTrustedBlockSelectorString(text: []const u8) bool {
    return std.mem.eql(u8, text, "latest") or
        std.mem.eql(u8, text, "earliest") or
        std.mem.eql(u8, text, "pending") or
        std.mem.eql(u8, text, "safe") or
        std.mem.eql(u8, text, "finalized") or
        isQuantityHex(text);
}

fn isHashString(text: []const u8) bool {
    if (text.len != 66 or !hasHexPrefix(text)) return false;
    var index: usize = 2;
    while (index < text.len) : (index += 1) {
        _ = std.fmt.charToDigit(text[index], 16) catch return false;
    }
    return true;
}

fn validateBlockSpecJson(value: std.json.Value) !void {
    switch (value) {
        .string => {},
        .integer => |n| if (n < 0) return error.InvalidParams,
        else => return error.InvalidParams,
    }
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

fn parseU64Json(value: std.json.Value) !u64 {
    return switch (value) {
        .integer => |n| if (n < 0) error.InvalidParams else @intCast(n),
        .string => |s| parseU64String(s),
        else => error.InvalidParams,
    };
}

fn parseQuantityU64Json(value: std.json.Value) !u64 {
    return switch (value) {
        .string => |s| parseU64String(s),
        else => error.InvalidParams,
    };
}

fn parseU64String(text: []const u8) !u64 {
    if (!isQuantityHex(text)) return error.InvalidParams;
    return std.fmt.parseInt(u64, text[2..], 16) catch error.InvalidParams;
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

fn hexStringToBytes(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var hex = text;
    if (hex.len >= 2 and hex[0] == '0' and (hex[1] == 'x' or hex[1] == 'X')) {
        hex = hex[2..];
    }
    if (hex.len == 0) return try allocator.alloc(u8, 0);
    if (hex.len % 2 != 0) return error.InvalidParams;
    const out = try allocator.alloc(u8, hex.len / 2);
    _ = std.fmt.hexToBytes(out, hex) catch {
        allocator.free(out);
        return error.InvalidParams;
    };
    return out;
}

fn hasHexPrefix(text: []const u8) bool {
    return text.len >= 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X');
}

fn isQuantityHex(text: []const u8) bool {
    return text.len > 2 and hasHexPrefix(text);
}

fn hexQuantity(allocator: std.mem.Allocator, n: u64) !std.json.Value {
    return .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{n}) };
}

fn hexU256(allocator: std.mem.Allocator, n: u256) !std.json.Value {
    return .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{n}) };
}

fn dataHexU256(allocator: std.mem.Allocator, n: u256) !std.json.Value {
    const buf = try allocator.alloc(u8, 66);
    buf[0] = '0';
    buf[1] = 'x';
    var bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &bytes, n, .big);
    writeHexLower(buf[2..], bytes[0..]);
    return .{ .string = buf };
}

fn hexBytes(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Value {
    if (bytes.len == 0) {
        return .{ .string = try allocator.dupe(u8, "0x") };
    }
    const buf = try allocator.alloc(u8, 2 + bytes.len * 2);
    buf[0] = '0';
    buf[1] = 'x';
    writeHexLower(buf[2..], bytes);
    return .{ .string = buf };
}

fn hexHash32(allocator: std.mem.Allocator, hash: [32]u8) !std.json.Value {
    const buf = try allocator.alloc(u8, 66);
    buf[0] = '0';
    buf[1] = 'x';
    writeHexLower(buf[2..], hash[0..]);
    return .{ .string = buf };
}

fn addressString(allocator: std.mem.Allocator, address: primitives.Address) !std.json.Value {
    const buf = try allocator.alloc(u8, 42);
    buf[0] = '0';
    buf[1] = 'x';
    writeHexLower(buf[2..], &address.bytes);
    return .{ .string = buf };
}

fn writeHexLower(out: []u8, src: []const u8) void {
    const charset = "0123456789abcdef";
    for (src, 0..) |b, i| {
        out[i * 2] = charset[(b >> 4) & 0x0f];
        out[i * 2 + 1] = charset[b & 0x0f];
    }
}

fn accountsResponse(allocator: std.mem.Allocator) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer {
        for (array.items) |*item| {
            deinitJsonValue(allocator, item);
        }
        array.deinit();
    }
    for (runtime_mod.DEFAULT_DEV_ACCOUNTS) |addr| {
        try array.append(try addressString(allocator, addr));
    }
    return .{ .array = array };
}

fn currentBlobBaseFee(rt: *const runtime_mod.NodeRuntime) u256 {
    return rt.dev_runtime.config.blob_base_fee orelse rt.blob_base_fee;
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

fn methodIs(method_name: []const u8, comptime names: []const []const u8) bool {
    inline for (names) |name| {
        if (std.mem.eql(u8, method_name, name)) return true;
    }
    return false;
}
