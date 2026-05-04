//! Wires the JSON-RPC dispatcher to the live NodeRuntime.

const std = @import("std");
const crypto = @import("crypto");
const jsonrpc = @import("jsonrpc");
const log = @import("../log.zig");
const primitives = @import("primitives");
const guillotine_mini = @import("guillotine_mini");
const rpc_parse = @import("parse.zig");
const block_builder = @import("../block_builder.zig");
const dispatcher_mod = @import("dispatcher.zig");
const block_query_handlers = @import("handlers/block_query_handlers.zig");
const debug_raw_handlers = @import("handlers/debug_raw.zig");
const eth_read = @import("handlers/eth_read.zig");
const host_adapter = @import("../host_adapter.zig");
const mining_coordinator = @import("../mining_coordinator.zig");
const runtime_mod = @import("../node/runtime.zig");
const simulation = @import("handlers/simulation.zig");
const trusted_fork_handlers = @import("trusted_fork_handlers.zig");
const tx_encoding = @import("../transaction_encoding.zig");
const tx_processor = @import("../tx_processor.zig");
const tx_submission = @import("handlers/tx_submission.zig");
const txpool_handlers = @import("handlers/txpool.zig");
const dev_erc20_handlers = @import("handlers/dev_erc20.zig");

var next_filter_id: u64 = 1;

pub fn install(registry: *dispatcher_mod.HandlerRegistry, rt: *runtime_mod.NodeRuntime) void {
    registry.context = rt;
    registry.on_method_with_context = dispatchMethod;
    registry.mode_name = runtimeModeName;
}

fn runtimeModeName(context: ?*anyopaque) []const u8 {
    const rt: *runtime_mod.NodeRuntime = @ptrCast(@alignCast(context orelse return "unknown"));
    return switch (rt.mode) {
        .trusted => "trusted",
        .light => "light",
    };
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
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    method_name: []const u8,
    params: ?std.json.Value,
) anyerror!std.json.Value {
    const rt: *runtime_mod.NodeRuntime = @ptrCast(@alignCast(context orelse return error.MethodNotFound));
    rt.runtime_mutex.lock();
    defer rt.runtime_mutex.unlock();

    if (rt.mode == .light) {
        return dispatchLightMethod(allocator, rt, method_name, params);
    }
    if (std.mem.eql(u8, method_name, "zevm_lightSyncStatus")) {
        try validateNoParams(params);
        return error.ModeUnsupported;
    }
    if (isEngineNamespaceMethod(method_name)) {
        return dispatchEngineMethod(allocator, rt, method_name, params);
    }

    if (std.mem.eql(u8, method_name, "web3_clientVersion")) {
        try validateNoParams(params);
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
        try validateNoParams(params);
        return .{ .string = try std.fmt.allocPrint(allocator, "{d}", .{rt.chain_id}) };
    }
    if (std.mem.eql(u8, method_name, "net_listening")) {
        try validateNoParams(params);
        return .{ .bool = true };
    }
    if (std.mem.eql(u8, method_name, "net_peerCount")) {
        try validateNoParams(params);
        return hexQuantity(allocator, 0);
    }

    if (std.mem.eql(u8, method_name, "eth_chainId")) {
        try validateNoParams(params);
        return hexQuantity(allocator, rt.chain_id);
    }
    if (std.mem.eql(u8, method_name, "eth_blockNumber")) {
        try validateNoParams(params);
        return hexQuantity(allocator, rt.head_block_number);
    }
    if (std.mem.eql(u8, method_name, "eth_gasPrice")) {
        try validateNoParams(params);
        return hexU256(allocator, rt.gas_price);
    }
    if (std.mem.eql(u8, method_name, "eth_maxPriorityFeePerGas")) {
        try validateNoParams(params);
        return hexU256(allocator, rt.max_priority_fee);
    }
    if (std.mem.eql(u8, method_name, "eth_blobBaseFee")) {
        try validateNoParams(params);
        return hexU256(allocator, currentBlobBaseFee(rt));
    }
    if (std.mem.eql(u8, method_name, "eth_feeHistory")) {
        const fee_history_params = try eth_read.parseEthFeeHistoryParams(allocator, params);
        defer eth_read.deinitEthFeeHistoryParams(allocator, fee_history_params);
        return eth_read.handleEthFeeHistoryValue(allocator, rt, fee_history_params);
    }
    if (std.mem.eql(u8, method_name, "eth_coinbase")) {
        try validateNoParams(params);
        return addressString(allocator, rt.coinbase);
    }
    if (std.mem.eql(u8, method_name, "eth_accounts")) {
        try validateNoParams(params);
        return accountsResponse(allocator, rt);
    }
    if (std.mem.eql(u8, method_name, "eth_mining")) {
        try validateNoParams(params);
        return .{ .bool = std.meta.activeTag(rt.mining_config) != .manual };
    }
    if (std.mem.eql(u8, method_name, "eth_syncing")) {
        try validateNoParams(params);
        return .{ .bool = false };
    }
    if (std.mem.eql(u8, method_name, "eth_protocolVersion")) {
        try validateNoParams(params);
        return .{ .string = try allocator.dupe(u8, "0x41") };
    }
    if (std.mem.eql(u8, method_name, "eth_getBalance")) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const result = try eth_read.handleEthGetBalance(
            arena.allocator(),
            rt,
            try eth_read.parseEthGetBalanceParams(params),
        );
        return typedResultToJsonValue(allocator, result);
    }
    if (std.mem.eql(u8, method_name, "eth_getTransactionCount")) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const result = try eth_read.handleEthGetTransactionCount(
            arena.allocator(),
            rt,
            try eth_read.parseEthGetTransactionCountParams(params),
        );
        return typedResultToJsonValue(allocator, result);
    }
    if (std.mem.eql(u8, method_name, "eth_getCode")) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const result = try eth_read.handleEthGetCode(
            arena.allocator(),
            rt,
            try eth_read.parseEthGetCodeParams(params),
        );
        return typedResultToJsonValue(allocator, result);
    }
    if (std.mem.eql(u8, method_name, "eth_getStorageAt")) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const result = try eth_read.handleEthGetStorageAt(
            arena.allocator(),
            rt,
            try eth_read.parseEthGetStorageAtParams(params),
        );
        return typedResultToJsonValue(allocator, result);
    }
    if (std.mem.eql(u8, method_name, "eth_getStorageValues")) {
        return eth_read.handleEthGetStorageValuesValue(allocator, rt, params);
    }
    if (std.mem.eql(u8, method_name, "eth_getProof")) {
        return eth_read.handleEthGetProofValue(allocator, rt, params);
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
    if (std.mem.eql(u8, method_name, "eth_sign")) {
        return handleEthSign(allocator, rt, params);
    }
    if (std.mem.eql(u8, method_name, "eth_signTransaction")) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const parsed_params = try parseSendTransactionParams(params);
        const result = tx_submission.handleSignTransaction(arena.allocator(), rt, parsed_params) catch |err| switch (err) {
            error.InvalidHexData,
            error.UnsupportedTxType,
            error.UnmanagedAccount,
            => return error.InvalidParams,
            else => return err,
        };
        return typedResultToJsonValue(allocator, result);
    }
    if (std.mem.eql(u8, method_name, "eth_newBlockFilter")) {
        try validateNoParams(params);
        return nextFilterIdValue(allocator);
    }
    if (std.mem.eql(u8, method_name, "eth_newPendingTransactionFilter")) {
        try validateNoParams(params);
        return nextFilterIdValue(allocator);
    }
    if (std.mem.eql(u8, method_name, "eth_newFilter")) {
        _ = try parseGetLogsParams(params);
        return nextFilterIdValue(allocator);
    }
    if (std.mem.eql(u8, method_name, "eth_getFilterChanges")) {
        _ = try parseFilterId(params);
        return .{ .array = std.json.Array.init(allocator) };
    }
    if (std.mem.eql(u8, method_name, "eth_getFilterLogs")) {
        _ = try parseFilterId(params);
        return .{ .array = std.json.Array.init(allocator) };
    }
    if (std.mem.eql(u8, method_name, "eth_uninstallFilter")) {
        _ = try parseFilterId(params);
        return .{ .bool = true };
    }
    if (std.mem.eql(u8, method_name, "eth_getBlockByNumber")) {
        var ctx = blockQueryContext(rt);
        return try block_query_handlers.handleGetBlockByNumberValue(
            allocator,
            &ctx,
            try parseGetBlockByNumberParams(params),
        );
    }
    if (std.mem.eql(u8, method_name, "eth_getBlockByHash")) {
        var ctx = blockQueryContext(rt);
        return try block_query_handlers.handleGetBlockByHashValue(
            allocator,
            &ctx,
            try parseGetBlockByHashParams(allocator, params),
        );
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
    if (std.mem.eql(u8, method_name, "eth_getUncleCountByBlockHash")) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var ctx = blockQueryContext(rt);
        const result = try block_query_handlers.handleGetUncleCountByBlockHash(
            arena.allocator(),
            &ctx,
            try parseGetUncleCountByBlockHashParams(allocator, params),
        );
        return typedResultToJsonValue(allocator, result);
    }
    if (std.mem.eql(u8, method_name, "eth_getUncleCountByBlockNumber")) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var ctx = blockQueryContext(rt);
        const result = try block_query_handlers.handleGetUncleCountByBlockNumber(
            arena.allocator(),
            &ctx,
            try parseGetUncleCountByBlockNumberParams(params),
        );
        return typedResultToJsonValue(allocator, result);
    }
    if (std.mem.eql(u8, method_name, "eth_getTransactionByHash")) {
        var ctx = blockQueryContext(rt);
        return try block_query_handlers.handleGetTransactionByHashValue(
            allocator,
            &ctx,
            try parseGetTransactionByHashParams(allocator, params),
        );
    }
    if (std.mem.eql(u8, method_name, "eth_getTransactionByBlockHashAndIndex")) {
        var ctx = blockQueryContext(rt);
        return try block_query_handlers.handleGetTransactionByBlockHashAndIndexValue(
            allocator,
            &ctx,
            try parseGetTransactionByBlockHashAndIndexParams(allocator, params),
        );
    }
    if (std.mem.eql(u8, method_name, "eth_getTransactionByBlockNumberAndIndex")) {
        var ctx = blockQueryContext(rt);
        return try block_query_handlers.handleGetTransactionByBlockNumberAndIndexValue(
            allocator,
            &ctx,
            try parseGetTransactionByBlockNumberAndIndexParams(params),
        );
    }
    if (std.mem.eql(u8, method_name, "eth_getTransactionReceipt")) {
        var ctx = blockQueryContext(rt);
        return try block_query_handlers.handleGetTransactionReceiptValue(
            allocator,
            &ctx,
            try parseGetTransactionReceiptParams(allocator, params),
        );
    }
    if (std.mem.eql(u8, method_name, "eth_getBlockReceipts")) {
        var ctx = blockQueryContext(rt);
        return try block_query_handlers.handleGetBlockReceiptsValue(
            allocator,
            &ctx,
            try parseGetBlockReceiptsParams(params),
        );
    }
    if (std.mem.eql(u8, method_name, "eth_getBlockAccessList")) {
        return try handleEthGetBlockAccessList(allocator, rt, params);
    }
    if (std.mem.eql(u8, method_name, "eth_getLogs")) {
        var ctx = blockQueryContext(rt);
        return try block_query_handlers.handleGetLogsValue(
            allocator,
            &ctx,
            try parseGetLogsParams(params),
        );
    }
    if (std.mem.eql(u8, method_name, "debug_getRawBlock")) {
        return debug_raw_handlers.handleGetRawBlock(allocator, rt, params);
    }
    if (std.mem.eql(u8, method_name, "debug_getRawHeader")) {
        return debug_raw_handlers.handleGetRawHeader(allocator, rt, params);
    }
    if (std.mem.eql(u8, method_name, "debug_getRawReceipts")) {
        return debug_raw_handlers.handleGetRawReceipts(allocator, rt, params);
    }
    if (std.mem.eql(u8, method_name, "debug_getRawTransaction")) {
        return debug_raw_handlers.handleGetRawTransaction(allocator, rt, params);
    }
    if (std.mem.eql(u8, method_name, "debug_getBadBlocks")) {
        try validateNoParams(params);
        return emptyArrayValue(allocator);
    }
    if (std.mem.eql(u8, method_name, "txpool_content")) {
        return txpool_handlers.handleContent(allocator, rt, params);
    }
    if (std.mem.eql(u8, method_name, "txpool_contentFrom")) {
        return txpool_handlers.handleContentFrom(allocator, rt, params);
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
    if (std.mem.eql(u8, method_name, "eth_createAccessList")) {
        return simulation.handleEthCreateAccessList(allocator, rt, params);
    }
    if (std.mem.eql(u8, method_name, "eth_simulateV1")) {
        return simulation.handleEthSimulateV1(allocator, rt, params);
    }
    if (std.mem.eql(u8, method_name, "testing_buildBlockV1")) {
        return handleTestingBuildBlockV1(allocator, rt, params);
    }

    if (methodIs(method_name, &.{ "zevm_reset", "anvil_reset", "hardhat_reset" })) {
        return trusted_fork_handlers.handleZevmReset(rt, params);
    }
    if (methodIs(method_name, &.{ "zevm_setRpcUrl", "anvil_setRpcUrl" })) {
        return trusted_fork_handlers.handleZevmSetRpcUrl(allocator, rt, params);
    }
    if (std.mem.eql(u8, method_name, "zevm_getAccount")) {
        const args = try parseGetAccountArgs(params);
        return accountStateValue(allocator, rt, args.address);
    }
    if (std.mem.eql(u8, method_name, "zevm_setAccount")) {
        try setAccountFromParams(allocator, rt, params);
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_dumpState", "anvil_dumpState" })) {
        try validateNoParams(params);
        return dumpStateValue(allocator, rt);
    }
    if (methodIs(method_name, &.{ "zevm_loadState", "anvil_loadState" })) {
        try loadStateFromParams(allocator, rt, params);
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_setBalance", "anvil_setBalance", "hardhat_setBalance", "zevm_deal", "anvil_deal" })) {
        const args = try parseAddrU256Args(params);
        try rt.setBalance(args.address, args.value);
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_addBalance", "anvil_addBalance" })) {
        const args = try parseAddrU256Args(params);
        const current = try rt.getBalance(args.address);
        const next = std.math.add(u256, current, args.value) catch return error.InvalidParams;
        try rt.setBalance(args.address, next);
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
    if (methodIs(method_name, &.{ "zevm_dealErc20", "anvil_dealErc20" })) {
        return dev_erc20_handlers.handleDealErc20(rt, params);
    }
    if (methodIs(method_name, &.{ "zevm_setErc20Allowance", "anvil_setErc20Allowance" })) {
        return dev_erc20_handlers.handleSetErc20Allowance(rt, params);
    }
    if (methodIs(method_name, &.{ "zevm_setCoinbase", "anvil_setCoinbase", "hardhat_setCoinbase" })) {
        const items = try paramsArrayItems(params);
        if (items.len != 1) return error.InvalidParams;
        rt.coinbase = try parseAddressJson(items[0]);
        rt.dev_runtime.config.coinbase = rt.coinbase;
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_setChainId", "anvil_setChainId" })) {
        rt.chain_id = try parseSingleQuantityU64Arg(params);
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_setBlockGasLimit", "anvil_setBlockGasLimit", "evm_setBlockGasLimit" })) {
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
    if (methodIs(method_name, &.{ "zevm_setMinGasPrice", "anvil_setMinGasPrice", "hardhat_setMinGasPrice" })) {
        rt.gas_price = try parseSingleQuantityU256Arg(params);
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_setNextBlockTimestamp", "anvil_setNextBlockTimestamp", "evm_setNextBlockTimestamp" })) {
        rt.setNextBlockTimestamp(try parseTimeControlQuantity(params));
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_setBlockTimestampInterval", "anvil_setBlockTimestampInterval" })) {
        rt.setBlockTimestampInterval(try parseTimeControlQuantity(params));
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_removeBlockTimestampInterval", "anvil_removeBlockTimestampInterval" })) {
        try validateNoParams(params);
        rt.removeBlockTimestampInterval();
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
    if (methodIs(method_name, &.{ "zevm_setTime", "anvil_setTime" })) {
        const timestamp = try parseTimeControlQuantity(params);
        return hexQuantity(allocator, try rt.setTime(timestamp));
    }
    if (methodIs(method_name, &.{ "zevm_snapshot", "anvil_snapshot", "evm_snapshot" })) {
        try validateNoParams(params);
        return hexQuantity(allocator, try rt.snapshot());
    }
    if (methodIs(method_name, &.{ "zevm_revert", "anvil_revert", "evm_revert" })) {
        const snapshot_id = try parseSnapshotId(params);
        return .{ .bool = try rt.revertToSnapshot(snapshot_id) };
    }
    if (methodIs(method_name, &.{ "zevm_mine", "anvil_mine", "evm_mine", "hardhat_mine" })) {
        const args = try parseMineArgs(params);
        try rt.mineBlocksWithTimestampInterval(args.count, args.interval_seconds);
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_mineDetailed", "anvil_mineDetailed" })) {
        return mineDetailedValue(allocator, rt, params);
    }
    if (methodIs(method_name, &.{ "zevm_dropTransaction", "anvil_dropTransaction", "hardhat_dropTransaction" })) {
        const hash = try parseSingleHashArg(params);
        return .{ .bool = rt.pool.removeByHash(hash) };
    }
    if (methodIs(method_name, &.{ "zevm_dropAllTransactions", "anvil_dropAllTransactions" })) {
        try validateNoParams(params);
        const removed = rt.pool.items().len;
        rt.pool.clear();
        return hexQuantity(allocator, removed);
    }
    if (methodIs(method_name, &.{ "zevm_removePoolTransactions", "anvil_removePoolTransactions" })) {
        return hexQuantity(allocator, try removePoolTransactions(rt, params));
    }
    if (methodIs(method_name, &.{ "zevm_getAutomine", "anvil_getAutomine", "hardhat_getAutomine" })) {
        try validateNoParams(params);
        return .{ .bool = std.meta.activeTag(rt.mining_config) == .auto };
    }
    if (methodIs(method_name, &.{ "zevm_setAutomine", "anvil_setAutomine", "evm_setAutomine" })) {
        const enabled = try parseSetAutomineArgs(params);
        try rt.setAutomine(enabled);
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_getIntervalMining", "anvil_getIntervalMining" })) {
        try validateNoParams(params);
        return hexQuantity(allocator, intervalMiningSeconds(rt));
    }
    if (methodIs(method_name, &.{ "zevm_setIntervalMining", "anvil_setIntervalMining", "evm_setIntervalMining" })) {
        const seconds = try parseSetIntervalMiningArgs(params);
        try rt.setIntervalMining(seconds);
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_metadata", "anvil_metadata", "hardhat_metadata" })) {
        try validateNoParams(params);
        return metadataValue(allocator, rt);
    }
    if (methodIs(method_name, &.{ "zevm_nodeInfo", "anvil_nodeInfo" })) {
        try validateNoParams(params);
        return nodeInfoValue(allocator, rt);
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
    if (isKnownEngineMethod(method_name)) {
        try validateEngineMethodParams(method_name, params);
        return error.ModeUnsupported;
    }
    if (isKnownDebugMethod(method_name)) {
        try validateDebugMethodParams(method_name, params);
        return error.ModeUnsupported;
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

const engine_supported_methods = [_][]const u8{
    "engine_exchangeCapabilities",
    "engine_exchangeTransitionConfigurationV1",
    "engine_getClientVersionV1",
    "engine_forkchoiceUpdatedV1",
    "engine_forkchoiceUpdatedV2",
    "engine_forkchoiceUpdatedV3",
    "engine_forkchoiceUpdatedV4",
    "engine_newPayloadV1",
    "engine_newPayloadV2",
    "engine_newPayloadV3",
    "engine_newPayloadV4",
    "engine_newPayloadV5",
    "engine_getPayloadV1",
    "engine_getPayloadV2",
    "engine_getPayloadV3",
    "engine_getPayloadV4",
    "engine_getPayloadV5",
    "engine_getPayloadV6",
    "engine_getPayloadBodiesByHashV1",
    "engine_getPayloadBodiesByHashV2",
    "engine_getPayloadBodiesByRangeV1",
    "engine_getPayloadBodiesByRangeV2",
    "engine_getBlobsV1",
    "engine_getBlobsV2",
    "engine_getBlobsV3",
};

const EngineForkchoiceState = struct {
    head_hash: [32]u8,
    safe_hash: [32]u8,
    finalized_hash: [32]u8,
};

fn isEngineNamespaceMethod(method_name: []const u8) bool {
    return std.mem.startsWith(u8, method_name, "engine_");
}

fn isKnownEngineMethod(method_name: []const u8) bool {
    if (jsonrpc.engine.EngineMethod.fromMethodName(method_name)) |_| {
        return true;
    } else |_| {
        return methodIs(method_name, &.{
            "engine_getClientVersionV1",
            "engine_forkchoiceUpdatedV4",
            "engine_getPayloadBodiesByHashV2",
            "engine_getPayloadBodiesByRangeV2",
            "engine_getBlobsV3",
        });
    }
}

fn isKnownDebugMethod(method_name: []const u8) bool {
    _ = jsonrpc.debug.DebugMethod.fromMethodName(method_name) catch return false;
    return true;
}

fn dispatchEngineMethod(
    allocator: std.mem.Allocator,
    rt: *runtime_mod.NodeRuntime,
    method_name: []const u8,
    params: ?std.json.Value,
) !std.json.Value {
    if (std.mem.eql(u8, method_name, "engine_getClientVersionV1")) {
        try validateEngineClientVersionParams(params);
        return engineClientVersionValue(allocator);
    }
    if (std.mem.eql(u8, method_name, "engine_exchangeCapabilities")) {
        try validateEngineCapabilitiesParams(params);
        return engineCapabilitiesValue(allocator);
    }
    if (std.mem.eql(u8, method_name, "engine_exchangeTransitionConfigurationV1")) {
        const transition_config = try parseEngineTransitionConfig(params);
        return cloneJsonValue(allocator, transition_config);
    }
    if (methodIs(method_name, &.{
        "engine_forkchoiceUpdatedV1",
        "engine_forkchoiceUpdatedV2",
        "engine_forkchoiceUpdatedV3",
        "engine_forkchoiceUpdatedV4",
    })) {
        const state = try parseEngineForkchoiceParams(params);
        return applyEngineForkchoice(allocator, rt, method_name, state);
    }
    if (isEngineNewPayloadMethod(method_name)) {
        try validateEngineNewPayloadParams(method_name, params);
        return enginePayloadStatusValue(allocator, "SYNCING", null, null);
    }
    if (isEngineGetPayloadMethod(method_name)) {
        try validateEnginePayloadIdParams(params);
        return error.UnknownPayload;
    }
    if (methodIs(method_name, &.{ "engine_getPayloadBodiesByHashV1", "engine_getPayloadBodiesByHashV2" })) {
        return enginePayloadBodiesByHashValue(allocator, rt, params, std.mem.eql(u8, method_name, "engine_getPayloadBodiesByHashV2"));
    }
    if (methodIs(method_name, &.{ "engine_getPayloadBodiesByRangeV1", "engine_getPayloadBodiesByRangeV2" })) {
        return enginePayloadBodiesByRangeValue(allocator, rt, params, std.mem.eql(u8, method_name, "engine_getPayloadBodiesByRangeV2"));
    }
    if (methodIs(method_name, &.{ "engine_getBlobsV1", "engine_getBlobsV2", "engine_getBlobsV3" })) {
        return engineBlobsValue(allocator, params);
    }

    return error.MethodNotFound;
}

fn validateEngineClientVersionParams(params: ?std.json.Value) !void {
    const items = try paramsArrayItems(params);
    if (items.len != 1 or items[0] != .object) return error.InvalidParams;
    const obj = items[0].object;
    if (obj.get("code")) |value| try validateStringLen(value, 2);
    if (obj.get("name")) |value| try validateStringValue(value);
    if (obj.get("version")) |value| try validateStringValue(value);
    if (obj.get("commit")) |value| {
        const text = switch (value) {
            .string => |s| s,
            else => return error.InvalidParams,
        };
        try validateHexData(text);
        if (text.len != 10) return error.InvalidParams;
    }
}

fn validateEngineCapabilitiesParams(params: ?std.json.Value) !void {
    const items = try paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    const capabilities = switch (items[0]) {
        .array => |array| array.items,
        else => return error.InvalidParams,
    };
    for (capabilities) |capability| {
        if (capability != .string) return error.InvalidParams;
    }
}

fn engineCapabilitiesValue(allocator: std.mem.Allocator) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer {
        for (array.items) |*item| {
            deinitJsonValue(allocator, item);
        }
        array.deinit();
    }
    for (engine_supported_methods) |method| {
        try array.append(.{ .string = try allocator.dupe(u8, method) });
    }
    return .{ .array = array };
}

fn engineClientVersionValue(allocator: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    errdefer {
        var value = std.json.Value{ .object = obj };
        deinitJsonValue(allocator, &value);
    }
    try putOwnedJson(&obj, allocator, "code", .{ .string = try allocator.dupe(u8, "ZE") });
    try putOwnedJson(&obj, allocator, "name", .{ .string = try allocator.dupe(u8, "zevm") });
    try putOwnedJson(&obj, allocator, "version", .{ .string = try allocator.dupe(u8, "v0.1.0") });
    try putOwnedJson(&obj, allocator, "commit", .{ .string = try allocator.dupe(u8, "0x00000000") });

    var array = std.json.Array.init(allocator);
    errdefer {
        var item = std.json.Value{ .object = obj };
        deinitJsonValue(allocator, &item);
        array.deinit();
    }
    try array.append(.{ .object = obj });
    return .{ .array = array };
}

fn parseEngineTransitionConfig(params: ?std.json.Value) !std.json.Value {
    const items = try paramsArrayItems(params);
    if (items.len != 1 or items[0] != .object) return error.InvalidParams;
    return items[0];
}

fn parseEngineForkchoiceParams(params: ?std.json.Value) !EngineForkchoiceState {
    const items = try paramsArrayItems(params);
    if (items.len < 1 or items.len > 2) return error.InvalidParams;
    if (items.len == 2 and items[1] != .null) return error.InvalidParams;

    const object = switch (items[0]) {
        .object => |object| object,
        else => return error.InvalidParams,
    };
    return .{
        .head_hash = try rpc_parse.parseHash32Value(object.get("headBlockHash") orelse return error.InvalidParams),
        .safe_hash = try rpc_parse.parseHash32Value(object.get("safeBlockHash") orelse return error.InvalidParams),
        .finalized_hash = try rpc_parse.parseHash32Value(object.get("finalizedBlockHash") orelse return error.InvalidParams),
    };
}

fn validateEngineMethodParams(method_name: []const u8, params: ?std.json.Value) !void {
    if (std.mem.eql(u8, method_name, "engine_exchangeCapabilities")) {
        try validateEngineCapabilitiesParams(params);
        return;
    }
    if (std.mem.eql(u8, method_name, "engine_exchangeTransitionConfigurationV1")) {
        _ = try parseEngineTransitionConfig(params);
        return;
    }
    if (methodIs(method_name, &.{
        "engine_forkchoiceUpdatedV1",
        "engine_forkchoiceUpdatedV2",
        "engine_forkchoiceUpdatedV3",
        "engine_forkchoiceUpdatedV4",
    })) {
        _ = try parseEngineForkchoiceParams(params);
        return;
    }
    if (isEngineNewPayloadMethod(method_name)) {
        try validateEngineNewPayloadParams(method_name, params);
        return;
    }
    if (isEngineGetPayloadMethod(method_name)) {
        try validateEnginePayloadIdParams(params);
        return;
    }
    if (std.mem.eql(u8, method_name, "engine_getClientVersionV1")) {
        try validateEngineClientVersionParams(params);
        return;
    }
    if (methodIs(method_name, &.{
        "engine_getPayloadBodiesByHashV1",
        "engine_getPayloadBodiesByHashV2",
        "engine_getBlobsV1",
        "engine_getBlobsV2",
        "engine_getBlobsV3",
    })) {
        _ = try engineHashArrayItems(params);
        return;
    }
    if (methodIs(method_name, &.{ "engine_getPayloadBodiesByRangeV1", "engine_getPayloadBodiesByRangeV2" })) {
        _ = try parseEnginePayloadBodiesRangeParams(params);
        return;
    }
    return error.MethodNotFound;
}

fn validateDebugMethodParams(method_name: []const u8, params: ?std.json.Value) !void {
    if (std.mem.eql(u8, method_name, "debug_getBadBlocks")) {
        try validateNoParams(params);
        return;
    }
    if (methodIs(method_name, &.{ "debug_getRawBlock", "debug_getRawHeader", "debug_getRawReceipts" })) {
        _ = try parseSingleQuantityU64Arg(params);
        return;
    }
    if (std.mem.eql(u8, method_name, "debug_getRawTransaction")) {
        _ = try parseSingleHashArg(params);
        return;
    }
    return error.MethodNotFound;
}

fn applyEngineForkchoice(
    allocator: std.mem.Allocator,
    rt: *runtime_mod.NodeRuntime,
    method_name: []const u8,
    state: EngineForkchoiceState,
) !std.json.Value {
    const head_block = rt.blockchain.getBlockLocal(state.head_hash) orelse {
        return engineForkchoiceResult(allocator, "SYNCING", null, null);
    };
    if (!hashIsZero(state.safe_hash) and rt.blockchain.getBlockLocal(state.safe_hash) == null) {
        return engineForkchoiceResult(allocator, "SYNCING", null, null);
    }
    if (!hashIsZero(state.finalized_hash) and rt.blockchain.getBlockLocal(state.finalized_hash) == null) {
        return engineForkchoiceResult(allocator, "SYNCING", null, null);
    }

    try rt.blockchain.setCanonicalHead(state.head_hash);
    rt.head_block_number = head_block.header.number;
    rt.head_block_timestamp = head_block.header.timestamp;
    if (head_block.header.base_fee_per_gas) |base_fee| {
        rt.base_fee = base_fee;
    }

    const head_hash_hex = std.fmt.bytesToHex(state.head_hash, .lower);
    log.info(.rpc, "engine_forkchoice_updated method={s} head_block_number={} head_hash=0x{s}", .{
        method_name,
        head_block.header.number,
        &head_hash_hex,
    });
    return engineForkchoiceResult(allocator, "VALID", state.head_hash, null);
}

fn engineForkchoiceResult(
    allocator: std.mem.Allocator,
    status: []const u8,
    latest_valid_hash: ?[32]u8,
    validation_error: ?[]const u8,
) !std.json.Value {
    var payload_status = std.json.ObjectMap.init(allocator);
    errdefer {
        var value = std.json.Value{ .object = payload_status };
        deinitJsonValue(allocator, &value);
    }
    try putOwnedJson(&payload_status, allocator, "status", .{ .string = try allocator.dupe(u8, status) });
    if (latest_valid_hash) |hash| {
        try putOwnedJson(&payload_status, allocator, "latestValidHash", try hexHash32(allocator, hash));
    } else {
        try putOwnedJson(&payload_status, allocator, "latestValidHash", .null);
    }
    if (validation_error) |message| {
        try putOwnedJson(&payload_status, allocator, "validationError", .{ .string = try allocator.dupe(u8, message) });
    } else {
        try putOwnedJson(&payload_status, allocator, "validationError", .null);
    }

    var result = std.json.ObjectMap.init(allocator);
    errdefer {
        var value = std.json.Value{ .object = result };
        deinitJsonValue(allocator, &value);
    }
    try putOwnedJson(&result, allocator, "payloadStatus", .{ .object = payload_status });
    try putOwnedJson(&result, allocator, "payloadId", .null);
    return .{ .object = result };
}

fn isEngineNewPayloadMethod(method_name: []const u8) bool {
    return methodIs(method_name, &.{
        "engine_newPayloadV1",
        "engine_newPayloadV2",
        "engine_newPayloadV3",
        "engine_newPayloadV4",
        "engine_newPayloadV5",
    });
}

fn isEngineGetPayloadMethod(method_name: []const u8) bool {
    return methodIs(method_name, &.{
        "engine_getPayloadV1",
        "engine_getPayloadV2",
        "engine_getPayloadV3",
        "engine_getPayloadV4",
        "engine_getPayloadV5",
        "engine_getPayloadV6",
    });
}

fn validateEngineNewPayloadParams(method_name: []const u8, params: ?std.json.Value) !void {
    const items = try paramsArrayItems(params);
    const expected_len: usize = if (methodIs(method_name, &.{ "engine_newPayloadV1", "engine_newPayloadV2" }))
        1
    else if (std.mem.eql(u8, method_name, "engine_newPayloadV3"))
        3
    else
        4;
    if (items.len != expected_len) return error.InvalidParams;
    if (items[0] != .object) return error.InvalidParams;
    if (expected_len >= 3) {
        try validateHashArrayValue(items[1]);
        try validateHash32Json(items[2]);
    }
    if (expected_len == 4 and items[3] != .array) return error.InvalidParams;
}

fn validateEnginePayloadIdParams(params: ?std.json.Value) !void {
    const items = try paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    const text = switch (items[0]) {
        .string => |s| s,
        else => return error.InvalidParams,
    };
    try validateHexData(text);
    if (text.len != 18) return error.InvalidParams;
}

const EnginePayloadBodiesRange = struct {
    start: u64,
    count: u64,
};

fn parseEnginePayloadBodiesRangeParams(params: ?std.json.Value) !EnginePayloadBodiesRange {
    const items = try paramsArrayItems(params);
    if (items.len != 2) return error.InvalidParams;
    const start = try parseQuantityU64Json(items[0]);
    const count = try parseQuantityU64Json(items[1]);
    if (count == 0 or count > 1024) return error.InvalidParams;
    return .{ .start = start, .count = count };
}

fn engineHashArrayItems(params: ?std.json.Value) ![]const std.json.Value {
    const items = try paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    const hashes = switch (items[0]) {
        .array => |array| array.items,
        else => return error.InvalidParams,
    };
    if (hashes.len > 1024) return error.InvalidParams;
    for (hashes) |hash| try validateHash32Json(hash);
    return hashes;
}

fn validateHashArrayValue(value: std.json.Value) !void {
    const hashes = switch (value) {
        .array => |array| array.items,
        else => return error.InvalidParams,
    };
    if (hashes.len > 1024) return error.InvalidParams;
    for (hashes) |hash| try validateHash32Json(hash);
}

fn enginePayloadStatusValue(
    allocator: std.mem.Allocator,
    status: []const u8,
    latest_valid_hash: ?[32]u8,
    validation_error: ?[]const u8,
) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    errdefer {
        var value = std.json.Value{ .object = obj };
        deinitJsonValue(allocator, &value);
    }
    try putOwnedJson(&obj, allocator, "status", .{ .string = try allocator.dupe(u8, status) });
    try putOwnedJson(&obj, allocator, "latestValidHash", if (latest_valid_hash) |hash| try hexHash32(allocator, hash) else .null);
    try putOwnedJson(&obj, allocator, "validationError", if (validation_error) |message| .{ .string = try allocator.dupe(u8, message) } else .null);
    return .{ .object = obj };
}

fn enginePayloadBodiesByHashValue(
    allocator: std.mem.Allocator,
    rt: *runtime_mod.NodeRuntime,
    params: ?std.json.Value,
    include_block_access_list: bool,
) !std.json.Value {
    const hashes = try engineHashArrayItems(params);
    var array = std.json.Array.init(allocator);
    errdefer {
        for (array.items) |*item| deinitJsonValue(allocator, item);
        array.deinit();
    }
    for (hashes) |hash_value| {
        const hash = try rpc_parse.parseHash32Value(hash_value);
        if (rt.blockchain.getBlockLocal(hash)) |block| {
            try array.append(try enginePayloadBodyValue(allocator, block, include_block_access_list));
        } else {
            try array.append(.null);
        }
    }
    return .{ .array = array };
}

fn enginePayloadBodiesByRangeValue(
    allocator: std.mem.Allocator,
    rt: *runtime_mod.NodeRuntime,
    params: ?std.json.Value,
    include_block_access_list: bool,
) !std.json.Value {
    const range = try parseEnginePayloadBodiesRangeParams(params);
    var array = std.json.Array.init(allocator);
    errdefer {
        for (array.items) |*item| deinitJsonValue(allocator, item);
        array.deinit();
    }
    var offset: u64 = 0;
    while (offset < range.count) : (offset += 1) {
        const number = std.math.add(u64, range.start, offset) catch return error.InvalidParams;
        if (try rt.blockchain.getBlockByNumber(number)) |block| {
            try array.append(try enginePayloadBodyValue(allocator, block, include_block_access_list));
        } else {
            try array.append(.null);
        }
    }
    return .{ .array = array };
}

fn enginePayloadBodyValue(
    allocator: std.mem.Allocator,
    block: primitives.Block.Block,
    include_block_access_list: bool,
) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    errdefer {
        var value = std.json.Value{ .object = obj };
        deinitJsonValue(allocator, &value);
    }
    try putOwnedJson(&obj, allocator, "transactions", try rawTransactionArrayValue(allocator, block.body.transactions));
    if (block.body.withdrawals) |withdrawals| {
        try putOwnedJson(&obj, allocator, "withdrawals", try withdrawalsArrayValue(allocator, withdrawals));
    } else {
        try putOwnedJson(&obj, allocator, "withdrawals", .null);
    }
    if (include_block_access_list) {
        try putOwnedJson(&obj, allocator, "blockAccessList", .null);
    }
    return .{ .object = obj };
}

fn engineBlobsValue(allocator: std.mem.Allocator, params: ?std.json.Value) !std.json.Value {
    const hashes = try engineHashArrayItems(params);
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    for (hashes) |_| try array.append(.null);
    return .{ .array = array };
}

fn handleEthGetBlockAccessList(
    allocator: std.mem.Allocator,
    rt: *runtime_mod.NodeRuntime,
    params: ?std.json.Value,
) !std.json.Value {
    _ = allocator;
    const selector = try parseGetBlockAccessListSelector(params);
    if (!try blockAccessListBlockExists(rt, selector)) return .null;

    // Amsterdam block access lists are not retained by the current local
    // block store. Expose the method and spec-compatible "not available" value.
    return .null;
}

fn parseGetBlockAccessListSelector(params: ?std.json.Value) !std.json.Value {
    const items = try paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    try validateBlockNumberOrTagOrHashValue(items[0]);
    return items[0];
}

fn blockAccessListBlockExists(rt: *runtime_mod.NodeRuntime, selector: std.json.Value) !bool {
    switch (selector) {
        .string => |s| {
            if (rpc_parse.parseHash32String(s)) |hash| {
                return rt.blockchain.getBlockLocal(hash) != null;
            } else |_| {}
            return blockNumberSelectorExists(rt, s);
        },
        .object => |obj| {
            if (obj.get("blockHash")) |hash_value| {
                const hash = try rpc_parse.parseHash32Value(hash_value);
                return rt.blockchain.getBlockLocal(hash) != null;
            }
            if (obj.get("blockNumber")) |number_value| {
                const text = switch (number_value) {
                    .string => |s| s,
                    else => return error.InvalidParams,
                };
                return blockNumberSelectorExists(rt, text);
            }
            return false;
        },
        else => return error.InvalidParams,
    }
}

fn blockNumberSelectorExists(rt: *runtime_mod.NodeRuntime, selector: []const u8) !bool {
    const number = blockNumberFromTrustedSelector(rt, selector) catch return error.InvalidParams;
    return (try rt.blockchain.getBlockByNumber(number)) != null;
}

fn blockNumberFromTrustedSelector(rt: *const runtime_mod.NodeRuntime, selector: []const u8) !u64 {
    if (std.mem.eql(u8, selector, "latest") or
        std.mem.eql(u8, selector, "safe") or
        std.mem.eql(u8, selector, "finalized") or
        std.mem.eql(u8, selector, "pending"))
    {
        return rt.head_block_number;
    }
    if (std.mem.eql(u8, selector, "earliest")) return 0;
    return parseU64String(selector);
}

fn hashIsZero(hash: [32]u8) bool {
    return std.mem.eql(u8, hash[0..], primitives.Hash.ZERO[0..]);
}

const LightBlockSelector = rpc_parse.LightBlockSelector;

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

fn handleEthSign(
    allocator: std.mem.Allocator,
    rt: *runtime_mod.NodeRuntime,
    params: ?std.json.Value,
) !std.json.Value {
    const items = try paramsArrayItems(params);
    if (items.len != 2) return error.InvalidParams;

    const address = try parseAddressJson(items[0]);
    const message = switch (items[1]) {
        .string => |text| try hexStringToBytes(allocator, text),
        else => return error.InvalidParams,
    };
    defer allocator.free(message);

    const private_key = rt.managedPrivateKey(address) orelse return error.InvalidParams;
    const signature = crypto.Crypto.unaudited_signMessage(message, private_key) catch return error.InvalidParams;
    return signatureValue(allocator, signature);
}

fn signatureValue(allocator: std.mem.Allocator, signature: crypto.Crypto.Signature) !std.json.Value {
    var bytes: [65]u8 = undefined;
    std.mem.writeInt(u256, bytes[0..32], signature.r, .big);
    std.mem.writeInt(u256, bytes[32..64], signature.s, .big);
    bytes[64] = signature.v;
    return hexBytes(allocator, &bytes);
}

fn nextFilterIdValue(allocator: std.mem.Allocator) !std.json.Value {
    const id = next_filter_id;
    next_filter_id +|= 1;
    return hexQuantity(allocator, id);
}

fn parseFilterId(params: ?std.json.Value) !u64 {
    const items = try paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    return parseQuantityU64Json(items[0]);
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
            const low = if (head > runtime_mod.LIGHT_RETAINED_HISTORY_BACKTRACK)
                head - runtime_mod.LIGHT_RETAINED_HISTORY_BACKTRACK
            else
                1;
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
    return rpc_parse.parseLightBlockSelectorValue(value);
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
        "eth_createAccessList",
        "eth_simulateV1",
        "eth_getProof",
        "testing_buildBlockV1",
        "eth_sendTransaction",
        "eth_sendRawTransaction",
        "eth_sign",
        "eth_signTransaction",
        "eth_newBlockFilter",
        "eth_newFilter",
        "eth_newPendingTransactionFilter",
        "eth_getFilterChanges",
        "eth_getFilterLogs",
        "eth_uninstallFilter",
        "eth_getBlockByNumber",
        "eth_getBlockByHash",
        "eth_getBlockTransactionCountByHash",
        "eth_getBlockTransactionCountByNumber",
        "eth_getUncleCountByBlockHash",
        "eth_getUncleCountByBlockNumber",
        "eth_getTransactionByHash",
        "eth_getTransactionByBlockHashAndIndex",
        "eth_getTransactionByBlockNumberAndIndex",
        "eth_getTransactionReceipt",
        "eth_getBlockReceipts",
        "eth_getBlockAccessList",
        "eth_getLogs",
        "eth_getStorageValues",
        "txpool_content",
        "txpool_contentFrom",
        "txpool_status",
        "txpool_inspect",
        "zevm_reset",
        "anvil_reset",
        "hardhat_reset",
        "zevm_setRpcUrl",
        "anvil_setRpcUrl",
        "zevm_setBalance",
        "anvil_setBalance",
        "hardhat_setBalance",
        "zevm_getAccount",
        "zevm_setAccount",
        "zevm_dumpState",
        "anvil_dumpState",
        "zevm_loadState",
        "anvil_loadState",
        "zevm_deal",
        "anvil_deal",
        "zevm_addBalance",
        "anvil_addBalance",
        "zevm_setNonce",
        "anvil_setNonce",
        "hardhat_setNonce",
        "zevm_setCode",
        "anvil_setCode",
        "hardhat_setCode",
        "zevm_setStorageAt",
        "anvil_setStorageAt",
        "hardhat_setStorageAt",
        "zevm_dealErc20",
        "anvil_dealErc20",
        "zevm_setErc20Allowance",
        "anvil_setErc20Allowance",
        "zevm_setCoinbase",
        "anvil_setCoinbase",
        "hardhat_setCoinbase",
        "zevm_setChainId",
        "anvil_setChainId",
        "zevm_setBlockGasLimit",
        "anvil_setBlockGasLimit",
        "evm_setBlockGasLimit",
        "zevm_setNextBlockBaseFeePerGas",
        "anvil_setNextBlockBaseFeePerGas",
        "hardhat_setNextBlockBaseFeePerGas",
        "zevm_setMinGasPrice",
        "anvil_setMinGasPrice",
        "hardhat_setMinGasPrice",
        "zevm_impersonateAccount",
        "anvil_impersonateAccount",
        "hardhat_impersonateAccount",
        "zevm_stopImpersonatingAccount",
        "anvil_stopImpersonatingAccount",
        "hardhat_stopImpersonatingAccount",
        "zevm_autoImpersonateAccount",
        "anvil_autoImpersonateAccount",
        "zevm_increaseTime",
        "anvil_increaseTime",
        "evm_increaseTime",
        "zevm_setTime",
        "anvil_setTime",
        "zevm_setNextBlockTimestamp",
        "anvil_setNextBlockTimestamp",
        "evm_setNextBlockTimestamp",
        "zevm_setBlockTimestampInterval",
        "anvil_setBlockTimestampInterval",
        "zevm_removeBlockTimestampInterval",
        "anvil_removeBlockTimestampInterval",
        "zevm_snapshot",
        "anvil_snapshot",
        "evm_snapshot",
        "zevm_revert",
        "anvil_revert",
        "evm_revert",
        "zevm_mine",
        "anvil_mine",
        "evm_mine",
        "hardhat_mine",
        "zevm_mineDetailed",
        "anvil_mineDetailed",
        "zevm_dropTransaction",
        "anvil_dropTransaction",
        "hardhat_dropTransaction",
        "zevm_dropAllTransactions",
        "anvil_dropAllTransactions",
        "zevm_removePoolTransactions",
        "anvil_removePoolTransactions",
        "zevm_getAutomine",
        "anvil_getAutomine",
        "hardhat_getAutomine",
        "zevm_setAutomine",
        "anvil_setAutomine",
        "evm_setAutomine",
        "zevm_getIntervalMining",
        "anvil_getIntervalMining",
        "zevm_setIntervalMining",
        "anvil_setIntervalMining",
        "evm_setIntervalMining",
        "zevm_metadata",
        "anvil_metadata",
        "hardhat_metadata",
        "zevm_nodeInfo",
        "anvil_nodeInfo",
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
        "eth_newBlockFilter",
        "eth_newPendingTransactionFilter",
        "txpool_content",
        "txpool_status",
        "txpool_inspect",
        "zevm_dumpState",
        "anvil_dumpState",
        "zevm_getAutomine",
        "anvil_getAutomine",
        "hardhat_getAutomine",
        "zevm_getIntervalMining",
        "anvil_getIntervalMining",
        "zevm_metadata",
        "anvil_metadata",
        "hardhat_metadata",
        "zevm_nodeInfo",
        "anvil_nodeInfo",
        "zevm_removeBlockTimestampInterval",
        "anvil_removeBlockTimestampInterval",
    })) {
        return validateNoParams(params);
    }
    if (std.mem.eql(u8, method_name, "txpool_contentFrom")) {
        _ = try parseSingleAddressArg(params);
        return;
    }
    if (std.mem.eql(u8, method_name, "eth_getStorageValues")) {
        try validateGetStorageValuesParams(params);
        return;
    }
    if (methodIs(method_name, &.{ "zevm_deal", "anvil_deal", "zevm_addBalance", "anvil_addBalance" })) {
        _ = try parseAddrU256Args(params);
        return;
    }
    if (std.mem.eql(u8, method_name, "zevm_getAccount")) {
        _ = try parseGetAccountArgs(params);
        return;
    }
    if (std.mem.eql(u8, method_name, "zevm_setAccount")) {
        try validateSetAccountParams(params);
        return;
    }
    if (methodIs(method_name, &.{ "zevm_loadState", "anvil_loadState" })) {
        const bytes = try parseSingleHexDataBytesArg(allocator, params);
        allocator.free(bytes);
        return;
    }
    if (methodIs(method_name, &.{ "zevm_setChainId", "anvil_setChainId" })) {
        _ = try parseSingleQuantityU64Arg(params);
        return;
    }
    if (methodIs(method_name, &.{ "zevm_setMinGasPrice", "anvil_setMinGasPrice", "hardhat_setMinGasPrice" })) {
        _ = try parseSingleQuantityU256Arg(params);
        return;
    }
    if (methodIs(method_name, &.{ "zevm_setBlockTimestampInterval", "anvil_setBlockTimestampInterval" })) {
        _ = try parseTimeControlQuantity(params);
        return;
    }
    if (methodIs(method_name, &.{ "zevm_dropTransaction", "anvil_dropTransaction", "hardhat_dropTransaction" })) {
        _ = try parseSingleHashArg(params);
        return;
    }
    if (methodIs(method_name, &.{ "zevm_dropAllTransactions", "anvil_dropAllTransactions" })) {
        try validateNoParams(params);
        return;
    }
    if (methodIs(method_name, &.{ "zevm_removePoolTransactions", "anvil_removePoolTransactions" })) {
        try validateHashArrayArg(params);
        return;
    }
    if (methodIs(method_name, &.{ "zevm_mine", "anvil_mine", "evm_mine", "hardhat_mine", "zevm_mineDetailed", "anvil_mineDetailed" })) {
        _ = try parseMineArgs(params);
        return;
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
    if (std.mem.eql(u8, method_name, "eth_createAccessList")) {
        const items = try paramsArrayItems(params);
        if (items.len < 1 or items.len > 2) return error.InvalidParams;
        try validateTransactionRequestJson(items[0]);
        if (items.len == 2) _ = try parseLightBlockSelectorJson(items[1]);
        return;
    }
    if (std.mem.eql(u8, method_name, "eth_simulateV1")) {
        const items = try paramsArrayItems(params);
        if (items.len < 1 or items.len > 2) return error.InvalidParams;
        if (items[0] != .object) return error.InvalidParams;
        if (items.len == 2) _ = try parseLightBlockSelectorJson(items[1]);
        return;
    }
    if (std.mem.eql(u8, method_name, "eth_getProof")) {
        const items = try paramsArrayItems(params);
        if (items.len != 3) return error.InvalidParams;
        _ = try parseAddressJson(items[0]);
        const keys = switch (items[1]) {
            .array => |array| array.items,
            else => return error.InvalidParams,
        };
        for (keys) |key| try validateHash32Json(key);
        _ = try parseLightBlockSelectorJson(items[2]);
        return;
    }
    if (std.mem.eql(u8, method_name, "testing_buildBlockV1")) {
        try validateTestingBuildBlockParams(params);
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
    if (std.mem.eql(u8, method_name, "eth_sign")) {
        const items = try paramsArrayItems(params);
        if (items.len != 2) return error.InvalidParams;
        _ = try parseAddressJson(items[0]);
        try validateHexDataValue(items[1]);
        return;
    }
    if (std.mem.eql(u8, method_name, "eth_signTransaction")) {
        const items = try paramsArrayItems(params);
        if (items.len != 1) return error.InvalidParams;
        try validateTransactionRequestJson(items[0]);
        return;
    }
    if (std.mem.eql(u8, method_name, "eth_newFilter")) {
        const items = try paramsArrayItems(params);
        if (items.len != 1 or items[0] != .object) return error.InvalidParams;
        return;
    }
    if (methodIs(method_name, &.{ "eth_getFilterChanges", "eth_getFilterLogs", "eth_uninstallFilter" })) {
        _ = try parseFilterId(params);
        return;
    }
    if (std.mem.eql(u8, method_name, "eth_getBlockByNumber")) {
        const items = try paramsArrayItems(params);
        if (items.len != 2) return error.InvalidParams;
        _ = try parseLightBlockSelectorJson(items[0]);
        if (items[1] != .bool) return error.InvalidParams;
        return;
    }
    if (methodIs(method_name, &.{ "eth_getBlockTransactionCountByNumber", "eth_getUncleCountByBlockNumber" })) {
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
    if (std.mem.eql(u8, method_name, "eth_getBlockAccessList")) {
        const items = try paramsArrayItems(params);
        if (items.len != 1) return error.InvalidParams;
        try validateBlockNumberOrTagOrHashValue(items[0]);
        return;
    }
    if (std.mem.eql(u8, method_name, "eth_getLogs")) {
        const items = try paramsArrayItems(params);
        if (items.len != 1 or items[0] != .object) return error.InvalidParams;
        return;
    }
    if (std.mem.eql(u8, method_name, "eth_getBlockByHash")) {
        const items = try paramsArrayItems(params);
        if (items.len != 2) return error.InvalidParams;
        try validateHash32Json(items[0]);
        if (items[1] != .bool) return error.InvalidParams;
        return;
    }
    if (methodIs(method_name, &.{
        "eth_getBlockTransactionCountByHash",
        "eth_getUncleCountByBlockHash",
        "eth_getTransactionByHash",
        "eth_getTransactionReceipt",
    })) {
        const items = try paramsArrayItems(params);
        if (items.len != 1) return error.InvalidParams;
        try validateHash32Json(items[0]);
        return;
    }
    if (std.mem.eql(u8, method_name, "eth_getTransactionByBlockHashAndIndex")) {
        const items = try paramsArrayItems(params);
        if (items.len != 2) return error.InvalidParams;
        try validateHash32Json(items[0]);
        _ = try parseU64Json(items[1]);
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

fn validateStringValue(value: std.json.Value) !void {
    if (value != .string) return error.InvalidParams;
}

fn validateStringLen(value: std.json.Value, expected_len: usize) !void {
    const text = switch (value) {
        .string => |s| s,
        else => return error.InvalidParams,
    };
    if (text.len != expected_len) return error.InvalidParams;
}

fn validateBlockNumberOrTagOrHashValue(value: std.json.Value) !void {
    switch (value) {
        .string => |s| {
            if (isTrustedBlockSelectorString(s) or isHashString(s)) return;
            return error.InvalidParams;
        },
        .object => |obj| {
            const block_number = obj.get("blockNumber");
            const block_hash = obj.get("blockHash");
            if ((block_number == null and block_hash == null) or (block_number != null and block_hash != null)) return error.InvalidParams;
            if (block_number) |number_value| {
                switch (number_value) {
                    .string => |s| if (!isTrustedBlockSelectorString(s)) return error.InvalidParams,
                    else => return error.InvalidParams,
                }
            }
            if (block_hash) |hash_value| try validateHash32Json(hash_value);
            if (obj.get("requireCanonical")) |canonical| {
                if (canonical != .bool) return error.InvalidParams;
            }
        },
        else => return error.InvalidParams,
    }
}

fn validateGetStorageValuesParams(params: ?std.json.Value) !void {
    const items = try paramsArrayItems(params);
    if (items.len != 2) return error.InvalidParams;
    const requests = switch (items[0]) {
        .object => |object| object,
        else => return error.InvalidParams,
    };
    if (requests.count() == 0) return error.InvalidParams;

    var it = requests.iterator();
    while (it.next()) |entry| {
        _ = try parseAddressString(entry.key_ptr.*);
        const slots = switch (entry.value_ptr.*) {
            .array => |array| array.items,
            else => return error.InvalidParams,
        };
        for (slots) |slot| {
            try validateHash32Json(slot);
        }
    }
    _ = try parseLightBlockSelectorJson(items[1]);
}

fn validateTestingBuildBlockParams(params: ?std.json.Value) !void {
    const items = try paramsArrayItems(params);
    if (items.len != 4) return error.InvalidParams;
    try validateHash32Json(items[0]);
    if (items[1] != .object) return error.InvalidParams;
    switch (items[2]) {
        .null => {},
        .array => |array| {
            for (array.items) |item| try validateHexDataValue(item);
        },
        else => return error.InvalidParams,
    }
    try validateHexDataValue(items[3]);
}

fn validateHexData(text: []const u8) !void {
    return rpc_parse.validateHexData(text);
}

fn isHash32(text: []const u8) bool {
    return rpc_parse.isHash32(text);
}

const GetAccountArgs = struct {
    address: primitives.Address,
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
    interval_seconds: ?u64,
};

fn paramsArrayItems(params: ?std.json.Value) ![]const std.json.Value {
    return rpc_parse.paramsArrayItems(params);
}

fn parseGetAccountArgs(params: ?std.json.Value) !GetAccountArgs {
    const items = try paramsArrayItems(params);
    if (items.len != 1 and items.len != 2) return error.InvalidParams;
    if (items.len == 2) try validateBlockSpecJson(items[1]);
    return .{ .address = try parseAddressJson(items[0]) };
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
        .slot = try parseStorageSlotJson(items[1]),
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

fn parseSingleHashArg(params: ?std.json.Value) ![32]u8 {
    const items = try paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    return rpc_parse.parseHash32Value(items[0]);
}

fn parseSingleBoolArg(params: ?std.json.Value) !bool {
    const items = try paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    return switch (items[0]) {
        .bool => |enabled| enabled,
        else => error.InvalidParams,
    };
}

fn parseSingleQuantityU64Arg(params: ?std.json.Value) !u64 {
    const items = try paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    return parseQuantityU64Json(items[0]);
}

fn parseSingleQuantityU256Arg(params: ?std.json.Value) !u256 {
    const items = try paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    return parseU256Json(items[0]);
}

fn parseMineArgs(params: ?std.json.Value) !MineArgs {
    const items = try paramsArrayItems(params);
    if (items.len > 2) return error.InvalidParams;
    if (items.len == 0) {
        return .{
            .count = 1,
            .interval_seconds = null,
        };
    }

    return .{
        .count = try parseQuantityU64Json(items[0]),
        .interval_seconds = if (items.len == 2) try parseQuantityU64Json(items[1]) else null,
    };
}

fn validateHashArrayArg(params: ?std.json.Value) !void {
    const items = try paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    const hashes = switch (items[0]) {
        .array => |array| array.items,
        else => return error.InvalidParams,
    };
    for (hashes) |hash_value| {
        _ = try rpc_parse.parseHash32Value(hash_value);
    }
}

fn removePoolTransactions(rt: *runtime_mod.NodeRuntime, params: ?std.json.Value) !usize {
    const items = try paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    const hashes = switch (items[0]) {
        .array => |array| array.items,
        else => return error.InvalidParams,
    };

    var removed: usize = 0;
    for (hashes) |hash_value| {
        if (rt.pool.removeByHash(try rpc_parse.parseHash32Value(hash_value))) removed += 1;
    }
    return removed;
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

const TestingBuildBlockAttrs = struct {
    parent_beacon_block_root: [32]u8,
    prev_randao: [32]u8,
    fee_recipient: primitives.Address,
    timestamp: u64,
    withdrawals: []const primitives.BlockBody.Withdrawal,
    extra_data: []const u8,
};

fn handleTestingBuildBlockV1(
    allocator: std.mem.Allocator,
    rt: *runtime_mod.NodeRuntime,
    params: ?std.json.Value,
) !std.json.Value {
    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();
    const temp = temp_arena.allocator();

    const items = try paramsArrayItems(params);
    if (items.len != 4) return error.InvalidParams;

    const parent_hash = try rpc_parse.parseHash32Value(items[0]);
    const parent_block = rt.blockchain.getBlockLocal(parent_hash) orelse return error.BuildBlockFailed;
    const attrs = try parseTestingBuildBlockAttrs(temp, items[1], items[3]);

    var raw_txs = std.ArrayList(primitives.BlockBody.TransactionData){};
    defer raw_txs.deinit(temp);
    var exec_txs = std.ArrayList(tx_processor.ExecutionTx){};
    defer exec_txs.deinit(temp);

    const block_number = parent_block.header.number +| 1;
    const hardfork = rt.hardforkAt(block_number, attrs.timestamp);
    const excess_blob_gas = if (hardfork.isAtLeast(.CANCUN))
        mining_coordinator.nextExcessBlobGasForChild(parent_block.header, block_number, attrs.timestamp)
    else
        0;
    const blob_base_fee = mining_coordinator.nextBlobBaseFee(excess_blob_gas, hardfork);

    switch (items[2]) {
        .null => {
            const ready = try rt.pool.getReady(temp);
            for (ready) |pooled| {
                try appendTestingBuildBlockTx(temp, pooled.raw, &raw_txs, &exec_txs, blob_base_fee);
            }
        },
        .array => |array| {
            for (array.items) |tx_value| {
                const raw = try rpc_parse.parseHexDataBytes(temp, tx_value);
                try appendTestingBuildBlockTx(temp, raw, &raw_txs, &exec_txs, blob_base_fee);
            }
        },
        else => return error.InvalidParams,
    }

    var recent_block_hashes: [256][32]u8 = undefined;
    const block_hashes = rt.blockchain.last256BlockHashesLocal(parent_hash, &recent_block_hashes) catch return error.BuildBlockFailed;
    const block_base_fee = if (hardfork.isAtLeast(.LONDON))
        block_builder.expectedBaseFeePerGas(&parent_block.header) catch return error.BuildBlockFailed
    else
        0;
    const block_gas_limit = childTestingBlockGasLimit(parent_block.header.gas_limit, rt.dev_runtime.config.block_gas_limit);

    const block_ctx = guillotine_mini.BlockContext{
        .chain_id = rt.chain_id,
        .block_number = block_number,
        .block_timestamp = attrs.timestamp,
        .block_difficulty = 0,
        .block_prevrandao = std.mem.readInt(u256, &attrs.prev_randao, .big),
        .block_coinbase = attrs.fee_recipient,
        .block_gas_limit = block_gas_limit,
        .block_base_fee = block_base_fee,
        .blob_base_fee = blob_base_fee,
        .block_hashes = block_hashes,
    };

    try rt.state.checkpoint();
    var reverted = false;
    defer if (!reverted) rt.state.revert();

    var adapter = host_adapter.HostAdapter{ .state = &rt.state };
    var result = block_builder.buildBlockWithOptions(
        temp,
        &rt.state,
        adapter.hostInterface(),
        exec_txs.items,
        block_ctx,
        .{
            .fork = blockBuilderFork(hardfork),
            .hardfork_config = rt.hardfork_config,
            .withdrawals = attrs.withdrawals,
            .parent_beacon_block_root = if (hardfork.isAtLeast(.CANCUN)) attrs.parent_beacon_block_root else null,
            .parent_hash = parent_hash,
        },
    ) catch return error.BuildBlockFailed;
    defer result.deinit(temp);

    rt.state.revert();
    reverted = true;

    const transactions_root = block_builder.computeRawTransactionsRoot(temp, raw_txs.items) catch return error.BuildBlockFailed;
    var header = primitives.BlockHeader.BlockHeader{
        .parent_hash = parent_hash,
        .ommers_hash = primitives.BlockHeader.EMPTY_OMMERS_HASH,
        .beneficiary = attrs.fee_recipient,
        .state_root = result.state_root,
        .transactions_root = transactions_root,
        .receipts_root = result.receipts_root,
        .logs_bloom = result.logs_bloom,
        .difficulty = 0,
        .number = block_number,
        .gas_limit = block_ctx.block_gas_limit,
        .gas_used = result.total_gas_used,
        .timestamp = attrs.timestamp,
        .extra_data = attrs.extra_data,
        .mix_hash = attrs.prev_randao,
        .nonce = [_]u8{0} ** primitives.BlockHeader.NONCE_SIZE,
        .base_fee_per_gas = if (hardfork.isAtLeast(.LONDON)) block_base_fee else null,
        .withdrawals_root = if (hardfork.isAtLeast(.SHANGHAI))
            (result.withdrawals_root orelse primitives.BlockHeader.EMPTY_WITHDRAWALS_ROOT)
        else
            null,
        .blob_gas_used = if (hardfork.isAtLeast(.CANCUN)) result.blob_gas_used else null,
        .excess_blob_gas = if (hardfork.isAtLeast(.CANCUN)) excess_blob_gas else null,
        .parent_beacon_block_root = if (hardfork.isAtLeast(.CANCUN)) attrs.parent_beacon_block_root else null,
    };
    _ = &header;
    const block_hash = block_builder.computeHeaderHashWithRequestsHash(temp, &header, result.requests_hash) catch return error.BuildBlockFailed;

    return testingBuildBlockResultValue(
        allocator,
        attrs,
        block_ctx,
        result,
        block_hash,
        raw_txs.items,
        blockValueFromReceipts(result.receipts, block_base_fee),
        excess_blob_gas,
    );
}

fn childTestingBlockGasLimit(parent_limit: u64, desired_limit: u64) u64 {
    if (parent_limit == desired_limit) return parent_limit;
    const delta = (parent_limit / 1024) -| 1;
    if (desired_limit > parent_limit) {
        return @min(parent_limit +| delta, desired_limit);
    }
    return @max(parent_limit - delta, desired_limit);
}

fn parseTestingBuildBlockAttrs(
    allocator: std.mem.Allocator,
    payload_attrs_value: std.json.Value,
    extra_data_value: std.json.Value,
) !TestingBuildBlockAttrs {
    const obj = switch (payload_attrs_value) {
        .object => |object| object,
        else => return error.InvalidParams,
    };
    const extra_data = try rpc_parse.parseHexDataBytes(allocator, extra_data_value);
    if (extra_data.len > primitives.BlockHeader.MAX_EXTRA_DATA_SIZE) return error.InvalidParams;

    return .{
        .parent_beacon_block_root = try rpc_parse.parseHash32Value(obj.get("parentBeaconBlockRoot") orelse return error.InvalidParams),
        .prev_randao = try rpc_parse.parseHash32Value(obj.get("prevRandao") orelse return error.InvalidParams),
        .fee_recipient = try parseAddressJson(obj.get("suggestedFeeRecipient") orelse return error.InvalidParams),
        .timestamp = try parseU64Json(obj.get("timestamp") orelse return error.InvalidParams),
        .withdrawals = try parseTestingBuildBlockWithdrawals(allocator, obj.get("withdrawals") orelse return error.InvalidParams),
        .extra_data = extra_data,
    };
}

fn parseTestingBuildBlockWithdrawals(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) ![]const primitives.BlockBody.Withdrawal {
    const items = switch (value) {
        .array => |array| array.items,
        else => return error.InvalidParams,
    };
    if (items.len == 0) return &.{};

    const withdrawals = try allocator.alloc(primitives.BlockBody.Withdrawal, items.len);
    for (items, 0..) |item, index| {
        const obj = switch (item) {
            .object => |object| object,
            else => return error.InvalidParams,
        };
        withdrawals[index] = .{
            .index = try parseU64Json(obj.get("index") orelse return error.InvalidParams),
            .validator_index = try parseU64Json(obj.get("validatorIndex") orelse return error.InvalidParams),
            .address = try parseAddressJson(obj.get("address") orelse return error.InvalidParams),
            .amount = try parseU64Json(obj.get("amount") orelse return error.InvalidParams),
        };
    }
    return withdrawals;
}

fn appendTestingBuildBlockTx(
    allocator: std.mem.Allocator,
    raw: []const u8,
    raw_txs: *std.ArrayList(primitives.BlockBody.TransactionData),
    exec_txs: *std.ArrayList(tx_processor.ExecutionTx),
    blob_base_fee: u256,
) !void {
    if (raw.len == 0) return error.InvalidParams;
    const canonical = tx_encoding.canonicalTransactionEnvelope(allocator, raw) catch return error.BuildBlockFailed;
    const decoded = tx_encoding.decodeEnvelope(allocator, canonical.bytes) catch return error.BuildBlockFailed;
    const sender = tx_encoding.recoverEnvelopeSender(allocator, decoded) catch return error.BuildBlockFailed;
    const tx = tx_encoding.envelopeToLegacyLikeTx(decoded);
    const blob_gas_used = tx_encoding.envelopeBlobGasUsed(decoded);
    const authorization_list = tx_encoding.envelopeAuthorizationList(decoded);

    try raw_txs.append(allocator, .{ .raw = canonical.bytes });
    try exec_txs.append(allocator, .{
        .caller = sender,
        .tx = tx,
        .receipt_type = tx_encoding.envelopeReceiptType(decoded),
        .max_fee_per_gas = tx_encoding.envelopeMaxFeePerGas(decoded),
        .max_priority_fee_per_gas = tx_encoding.envelopeMaxPriorityFeePerGas(decoded),
        .authorization_list = if (authorization_list.len == 0) null else authorization_list,
        .blob_gas_used = blob_gas_used,
        .blob_gas_price = if (blob_gas_used != null) blob_base_fee else null,
        .max_fee_per_blob_gas = tx_encoding.envelopeMaxFeePerBlobGas(decoded),
    });
}

fn testingBuildBlockResultValue(
    allocator: std.mem.Allocator,
    attrs: TestingBuildBlockAttrs,
    block_ctx: guillotine_mini.BlockContext,
    result: block_builder.BlockResult,
    block_hash: [32]u8,
    raw_txs: []const primitives.BlockBody.TransactionData,
    block_value: u256,
    excess_blob_gas: u64,
) !std.json.Value {
    var payload = std.json.ObjectMap.init(allocator);
    var payload_transferred = false;
    errdefer if (!payload_transferred) {
        var value = std.json.Value{ .object = payload };
        deinitJsonValue(allocator, &value);
    };

    try putOwnedJson(&payload, allocator, "parentHash", try hexHash32(allocator, block_ctx.block_hashes[block_ctx.block_hashes.len - 1]));
    try putOwnedJson(&payload, allocator, "feeRecipient", try addressString(allocator, attrs.fee_recipient));
    try putOwnedJson(&payload, allocator, "stateRoot", try hexHash32(allocator, result.state_root));
    try putOwnedJson(&payload, allocator, "receiptsRoot", try hexHash32(allocator, result.receipts_root));
    try putOwnedJson(&payload, allocator, "logsBloom", try hexBytes(allocator, &result.logs_bloom));
    try putOwnedJson(&payload, allocator, "prevRandao", try hexHash32(allocator, attrs.prev_randao));
    try putOwnedJson(&payload, allocator, "blockNumber", try hexQuantity(allocator, block_ctx.block_number));
    try putOwnedJson(&payload, allocator, "gasLimit", try hexQuantity(allocator, block_ctx.block_gas_limit));
    try putOwnedJson(&payload, allocator, "gasUsed", try hexQuantity(allocator, result.total_gas_used));
    try putOwnedJson(&payload, allocator, "timestamp", try hexQuantity(allocator, block_ctx.block_timestamp));
    try putOwnedJson(&payload, allocator, "extraData", try hexBytes(allocator, attrs.extra_data));
    try putOwnedJson(&payload, allocator, "baseFeePerGas", try hexU256(allocator, block_ctx.block_base_fee));
    try putOwnedJson(&payload, allocator, "blockHash", try hexHash32(allocator, block_hash));
    try putOwnedJson(&payload, allocator, "transactions", try rawTransactionArrayValue(allocator, raw_txs));
    try putOwnedJson(&payload, allocator, "withdrawals", try withdrawalsArrayValue(allocator, attrs.withdrawals));
    try putOwnedJson(&payload, allocator, "blobGasUsed", try hexQuantity(allocator, result.blob_gas_used));
    try putOwnedJson(&payload, allocator, "excessBlobGas", try hexQuantity(allocator, excess_blob_gas));

    var blobs_bundle = std.json.ObjectMap.init(allocator);
    var blobs_bundle_transferred = false;
    errdefer if (!blobs_bundle_transferred) {
        var value = std.json.Value{ .object = blobs_bundle };
        deinitJsonValue(allocator, &value);
    };
    try putOwnedJson(&blobs_bundle, allocator, "commitments", emptyArrayValue(allocator));
    try putOwnedJson(&blobs_bundle, allocator, "proofs", emptyArrayValue(allocator));
    try putOwnedJson(&blobs_bundle, allocator, "blobs", emptyArrayValue(allocator));

    var obj = std.json.ObjectMap.init(allocator);
    errdefer {
        var value = std.json.Value{ .object = obj };
        deinitJsonValue(allocator, &value);
    }
    try putOwnedJson(&obj, allocator, "executionPayload", .{ .object = payload });
    payload_transferred = true;
    try putOwnedJson(&obj, allocator, "blockValue", try hexU256(allocator, block_value));
    try putOwnedJson(&obj, allocator, "blobsBundle", .{ .object = blobs_bundle });
    blobs_bundle_transferred = true;
    try putOwnedJson(&obj, allocator, "executionRequests", emptyArrayValue(allocator));
    try putOwnedJson(&obj, allocator, "shouldOverrideBuilder", .{ .bool = false });
    return .{ .object = obj };
}

fn rawTransactionArrayValue(
    allocator: std.mem.Allocator,
    raw_txs: []const primitives.BlockBody.TransactionData,
) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer {
        for (array.items) |*item| {
            deinitJsonValue(allocator, item);
        }
        array.deinit();
    }
    for (raw_txs) |tx| {
        try array.append(try hexBytes(allocator, tx.raw));
    }
    return .{ .array = array };
}

fn withdrawalsArrayValue(
    allocator: std.mem.Allocator,
    withdrawals: []const primitives.BlockBody.Withdrawal,
) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer {
        for (array.items) |*item| {
            deinitJsonValue(allocator, item);
        }
        array.deinit();
    }
    for (withdrawals) |withdrawal| {
        var obj = std.json.ObjectMap.init(allocator);
        errdefer {
            var value = std.json.Value{ .object = obj };
            deinitJsonValue(allocator, &value);
        }
        try putOwnedJson(&obj, allocator, "index", try hexQuantity(allocator, withdrawal.index));
        try putOwnedJson(&obj, allocator, "validatorIndex", try hexQuantity(allocator, withdrawal.validator_index));
        try putOwnedJson(&obj, allocator, "address", try addressString(allocator, withdrawal.address));
        try putOwnedJson(&obj, allocator, "amount", try hexQuantity(allocator, withdrawal.amount));
        try array.append(.{ .object = obj });
    }
    return .{ .array = array };
}

fn emptyArrayValue(allocator: std.mem.Allocator) std.json.Value {
    return .{ .array = std.json.Array.init(allocator) };
}

fn blockValueFromReceipts(
    receipts: []const primitives.Receipt.Receipt,
    base_fee: u256,
) u256 {
    var total: u256 = 0;
    for (receipts) |receipt| {
        const priority = if (receipt.effective_gas_price > base_fee) receipt.effective_gas_price - base_fee else 0;
        const payment = priority *| receipt.gas_used;
        total = total +| payment;
    }
    return total;
}

fn blockBuilderFork(fork: guillotine_mini.Hardfork) block_builder.Hardfork {
    if (fork.isAtLeast(.PRAGUE)) return .prague;
    if (fork.isAtLeast(.CANCUN)) return .cancun;
    if (fork.isAtLeast(.SHANGHAI)) return .shanghai;
    if (fork.isAtLeast(.MERGE)) return .paris;
    if (fork.isAtLeast(.LONDON)) return .london;
    if (fork.isAtLeast(.BERLIN)) return .berlin;
    if (fork.isAtLeast(.ISTANBUL)) return .istanbul;
    if (fork.isAtLeast(.CONSTANTINOPLE)) return .constantinople;
    if (fork.isAtLeast(.BYZANTIUM)) return .byzantium;
    if (fork.isAtLeast(.HOMESTEAD)) return .homestead;
    return .frontier;
}

fn typedResultToJsonValue(allocator: std.mem.Allocator, result: anytype) !std.json.Value {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();

    var writer = std.Io.Writer.Allocating.init(scratch.allocator());
    defer writer.deinit();

    try std.json.Stringify.value(result, .{}, &writer.writer);
    // ResponseEnvelope owns and recursively frees result values.
    return try std.json.parseFromSliceLeaky(std.json.Value, allocator, writer.written(), .{
        .allocate = .alloc_always,
    });
}

fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();

    var writer = std.Io.Writer.Allocating.init(scratch.allocator());
    defer writer.deinit();

    try std.json.Stringify.value(value, .{}, &writer.writer);
    return try std.json.parseFromSliceLeaky(std.json.Value, allocator, writer.written(), .{
        .allocate = .alloc_always,
    });
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

fn parseGetUncleCountByBlockHashParams(
    allocator: std.mem.Allocator,
    params: ?std.json.Value,
) !jsonrpc.eth.GetUncleCountByBlockHash.Params {
    const items = try paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    return .{ .block_hash = try parseHashJson(allocator, items[0]) };
}

fn parseGetUncleCountByBlockNumberParams(params: ?std.json.Value) !jsonrpc.eth.GetUncleCountByBlockNumber.Params {
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
    return rpc_parse.parseJsonRpcHash32Value(value);
}

fn parseBoolJson(value: std.json.Value) !bool {
    return switch (value) {
        .bool => |b| b,
        else => error.InvalidParams,
    };
}

fn validateTrustedBlockSelectorValue(value: std.json.Value) !void {
    return rpc_parse.validateTrustedBlockSelectorValue(value);
}

fn validateReceiptSelectorValue(value: std.json.Value) !void {
    switch (value) {
        .string => |s| {
            if (!isTrustedBlockSelectorString(s) and !isHashString(s)) return error.InvalidParams;
        },
        else => return error.InvalidParams,
    }
}

fn validateQuantityValue(value: std.json.Value) !void {
    _ = try rpc_parse.parseQuantityValue(u64, value);
}

fn validateHexDataValue(value: std.json.Value) !void {
    return rpc_parse.validateHexDataValue(value);
}

fn isTrustedBlockSelectorString(text: []const u8) bool {
    return rpc_parse.isTrustedBlockSelectorString(text);
}

fn isHashString(text: []const u8) bool {
    return rpc_parse.isHash32(text);
}

fn validateBlockSpecJson(value: std.json.Value) !void {
    return rpc_parse.validateTrustedBlockSelectorValue(value);
}

fn parseAddressJson(value: std.json.Value) !primitives.Address {
    return rpc_parse.parseAddressValue(value);
}

fn parseAddressString(text: []const u8) !primitives.Address {
    return rpc_parse.parseAddressString(text);
}

fn parseU64Json(value: std.json.Value) !u64 {
    return rpc_parse.parseQuantityValue(u64, value);
}

fn parseQuantityU64Json(value: std.json.Value) !u64 {
    return rpc_parse.parseQuantityValue(u64, value);
}

fn parseU64String(text: []const u8) !u64 {
    return rpc_parse.parseQuantityString(u64, text);
}

fn parseU256Json(value: std.json.Value) !u256 {
    return rpc_parse.parseQuantityValue(u256, value);
}

fn parseStorageSlotJson(value: std.json.Value) !u256 {
    switch (value) {
        .string => |text| {
            if (rpc_parse.isHash32(text)) {
                const bytes = try rpc_parse.parseHash32String(text);
                return std.mem.readInt(u256, &bytes, .big);
            }
        },
        else => {},
    }
    return parseU256Json(value);
}

fn parseU256String(text: []const u8) !u256 {
    return rpc_parse.parseQuantityString(u256, text);
}

fn hexStringToBytes(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return rpc_parse.parseHexDataBytes(allocator, .{ .string = text });
}

fn hasHexPrefix(text: []const u8) bool {
    return rpc_parse.hasHexPrefix(text);
}

fn isQuantityHex(text: []const u8) bool {
    return rpc_parse.isQuantityHex(text);
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

fn accountsResponse(allocator: std.mem.Allocator, rt: *const runtime_mod.NodeRuntime) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer {
        for (array.items) |*item| {
            deinitJsonValue(allocator, item);
        }
        array.deinit();
    }
    for (0..rt.managedAccountCount()) |index| {
        try array.append(try addressString(allocator, rt.managedAccountAddress(index)));
    }
    return .{ .array = array };
}

fn accountStateValue(
    allocator: std.mem.Allocator,
    rt: *runtime_mod.NodeRuntime,
    address: primitives.Address,
) !std.json.Value {
    const account = try rt.state.journaled_state.getAccount(address);
    const code = try rt.getCode(address);

    var obj = std.json.ObjectMap.init(allocator);
    errdefer {
        var value = std.json.Value{ .object = obj };
        deinitJsonValue(allocator, &value);
    }

    try putOwnedJson(&obj, allocator, "balance", try hexU256(allocator, account.balance));
    try putOwnedJson(&obj, allocator, "nonce", try hexQuantity(allocator, account.nonce));
    try putOwnedJson(&obj, allocator, "code", try hexBytes(allocator, code));
    try putOwnedJson(&obj, allocator, "storage", try accountStorageValue(allocator, rt, address));
    return .{ .object = obj };
}

fn accountStorageValue(
    allocator: std.mem.Allocator,
    rt: *runtime_mod.NodeRuntime,
    address: primitives.Address,
) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    errdefer {
        var value = std.json.Value{ .object = obj };
        deinitJsonValue(allocator, &value);
    }

    if (rt.state.journaled_state.storage_cache.cache.getPtr(address)) |slots| {
        var iterator = slots.iterator();
        while (iterator.next()) |entry| {
            const key_value = try dataHexU256(allocator, entry.key_ptr.*);
            const key = key_value.string;
            errdefer allocator.free(key);
            try obj.put(key, try dataHexU256(allocator, entry.value_ptr.*));
        }
    }

    return .{ .object = obj };
}

fn setAccountFromParams(
    allocator: std.mem.Allocator,
    rt: *runtime_mod.NodeRuntime,
    params: ?std.json.Value,
) !void {
    const items = try paramsArrayItems(params);
    if (items.len != 2) return error.InvalidParams;
    const address = try parseAddressJson(items[0]);
    const account_obj = switch (items[1]) {
        .object => |object| object,
        else => return error.InvalidParams,
    };

    try rt.state.checkpoint();
    var committed = false;
    defer if (!committed) rt.state.revert();

    try replaceAccountFromObject(allocator, rt, address, account_obj);
    rt.state.commit();
    committed = true;
}

fn replaceAccountFromObject(
    allocator: std.mem.Allocator,
    rt: *runtime_mod.NodeRuntime,
    address: primitives.Address,
    account_obj: std.json.ObjectMap,
) !void {
    try validateAccountStateObject(account_obj);

    const balance = try parseU256Json(account_obj.get("balance").?);
    const nonce = try parseU64Json(account_obj.get("nonce").?);
    const code = switch (account_obj.get("code").?) {
        .string => |text| try hexStringToBytes(allocator, text),
        else => return error.InvalidParams,
    };
    defer allocator.free(code);
    const storage_obj = account_obj.get("storage").?.object;

    try rt.setBalance(address, balance);
    try rt.setNonce(address, nonce);
    try rt.setCode(address, code);
    clearAccountStorage(rt, address);

    var storage_iterator = storage_obj.iterator();
    while (storage_iterator.next()) |entry| {
        const slot = try parseBytes32StringAsU256(entry.key_ptr.*);
        const value = try parseBytes32ValueAsU256(entry.value_ptr.*);
        try rt.setStorage(address, slot, value);
    }
}

fn validateSetAccountParams(params: ?std.json.Value) !void {
    const items = try paramsArrayItems(params);
    if (items.len != 2) return error.InvalidParams;
    _ = try parseAddressJson(items[0]);
    const account_obj = switch (items[1]) {
        .object => |object| object,
        else => return error.InvalidParams,
    };
    try validateAccountStateObject(account_obj);
}

fn validateAccountStateObject(account_obj: std.json.ObjectMap) !void {
    var has_balance = false;
    var has_nonce = false;
    var has_code = false;
    var has_storage = false;

    var iterator = account_obj.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "balance")) {
            has_balance = true;
            _ = try parseU256Json(entry.value_ptr.*);
        } else if (std.mem.eql(u8, key, "nonce")) {
            has_nonce = true;
            _ = try parseU64Json(entry.value_ptr.*);
        } else if (std.mem.eql(u8, key, "code")) {
            switch (entry.value_ptr.*) {
                .string => |text| try validateHexData(text),
                else => return error.InvalidParams,
            }
            has_code = true;
        } else if (std.mem.eql(u8, key, "storage")) {
            const storage_obj = switch (entry.value_ptr.*) {
                .object => |object| object,
                else => return error.InvalidParams,
            };
            var storage_iterator = storage_obj.iterator();
            while (storage_iterator.next()) |storage_entry| {
                _ = try parseBytes32StringAsU256(storage_entry.key_ptr.*);
                _ = try parseBytes32ValueAsU256(storage_entry.value_ptr.*);
            }
            has_storage = true;
        } else {
            return error.InvalidParams;
        }
    }

    if (!has_balance or !has_nonce or !has_code or !has_storage) return error.InvalidParams;
}

fn clearAccountStorage(rt: *runtime_mod.NodeRuntime, address: primitives.Address) void {
    if (rt.state.journaled_state.storage_cache.cache.fetchRemove(address)) |entry| {
        var slots = entry.value;
        slots.deinit();
    }
}

fn parseBytes32StringAsU256(text: []const u8) !u256 {
    const bytes = try rpc_parse.parseHash32String(text);
    return std.mem.readInt(u256, &bytes, .big);
}

fn parseBytes32ValueAsU256(value: std.json.Value) !u256 {
    const bytes = try rpc_parse.parseHash32Value(value);
    return std.mem.readInt(u256, &bytes, .big);
}

fn dumpStateValue(allocator: std.mem.Allocator, rt: *runtime_mod.NodeRuntime) !std.json.Value {
    var dump_json = try stateDumpJsonValue(allocator, rt);
    defer deinitJsonValue(allocator, &dump_json);

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try std.json.Stringify.value(dump_json, .{}, &writer.writer);
    return hexBytes(allocator, writer.written());
}

fn stateDumpJsonValue(allocator: std.mem.Allocator, rt: *runtime_mod.NodeRuntime) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    errdefer {
        var value = std.json.Value{ .object = obj };
        deinitJsonValue(allocator, &value);
    }

    try putOwnedJson(&obj, allocator, "version", .{ .integer = 1 });
    try putOwnedJson(&obj, allocator, "accounts", try stateDumpAccountsValue(allocator, rt));
    return .{ .object = obj };
}

fn stateDumpAccountsValue(allocator: std.mem.Allocator, rt: *runtime_mod.NodeRuntime) !std.json.Value {
    const addresses = try collectDumpAddresses(allocator, rt);
    defer allocator.free(addresses);

    var obj = std.json.ObjectMap.init(allocator);
    errdefer {
        var value = std.json.Value{ .object = obj };
        deinitJsonValue(allocator, &value);
    }

    for (addresses) |address| {
        const key_value = try addressString(allocator, address);
        const key = key_value.string;
        errdefer allocator.free(key);
        try obj.put(key, try accountStateValue(allocator, rt, address));
    }

    return .{ .object = obj };
}

fn collectDumpAddresses(allocator: std.mem.Allocator, rt: *runtime_mod.NodeRuntime) ![]primitives.Address {
    var seen = std.AutoHashMap(primitives.Address, void).init(allocator);
    defer seen.deinit();

    var addresses = std.ArrayList(primitives.Address){};
    errdefer addresses.deinit(allocator);

    var account_iterator = rt.state.journaled_state.account_cache.cache.keyIterator();
    while (account_iterator.next()) |address| {
        try appendDumpAddress(allocator, &seen, &addresses, address.*);
    }

    var contract_iterator = rt.state.journaled_state.contract_cache.cache.keyIterator();
    while (contract_iterator.next()) |address| {
        try appendDumpAddress(allocator, &seen, &addresses, address.*);
    }

    var storage_iterator = rt.state.journaled_state.storage_cache.cache.keyIterator();
    while (storage_iterator.next()) |address| {
        try appendDumpAddress(allocator, &seen, &addresses, address.*);
    }

    std.mem.sort(primitives.Address, addresses.items, {}, addressLessThan);
    return try addresses.toOwnedSlice(allocator);
}

fn appendDumpAddress(
    allocator: std.mem.Allocator,
    seen: *std.AutoHashMap(primitives.Address, void),
    addresses: *std.ArrayList(primitives.Address),
    address: primitives.Address,
) !void {
    const entry = try seen.getOrPut(address);
    if (entry.found_existing) return;
    try addresses.append(allocator, address);
}

fn addressLessThan(_: void, a: primitives.Address, b: primitives.Address) bool {
    return std.mem.order(u8, &a.bytes, &b.bytes) == .lt;
}

fn loadStateFromParams(
    allocator: std.mem.Allocator,
    rt: *runtime_mod.NodeRuntime,
    params: ?std.json.Value,
) !void {
    const bytes = try parseSingleHexDataBytesArg(allocator, params);
    defer allocator.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidParams,
    };
    defer parsed.deinit();

    try loadStateFromValue(allocator, rt, parsed.value);
}

fn loadStateFromValue(
    allocator: std.mem.Allocator,
    rt: *runtime_mod.NodeRuntime,
    value: std.json.Value,
) !void {
    const root = switch (value) {
        .object => |object| object,
        else => return error.InvalidParams,
    };
    const version = switch (root.get("version") orelse return error.InvalidParams) {
        .integer => |integer| integer,
        else => return error.InvalidParams,
    };
    if (version != 1) return error.InvalidParams;

    const accounts = switch (root.get("accounts") orelse return error.InvalidParams) {
        .object => |object| object,
        else => return error.InvalidParams,
    };

    try rt.state.checkpoint();
    var committed = false;
    defer if (!committed) rt.state.revert();

    clearLocalState(rt);

    var iterator = accounts.iterator();
    while (iterator.next()) |entry| {
        const address = try parseAddressString(entry.key_ptr.*);
        const account_obj = switch (entry.value_ptr.*) {
            .object => |object| object,
            else => return error.InvalidParams,
        };
        try replaceAccountFromObject(allocator, rt, address, account_obj);
    }

    rt.state.commit();
    committed = true;
}

fn parseSingleHexDataBytesArg(allocator: std.mem.Allocator, params: ?std.json.Value) ![]u8 {
    const items = try paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    return switch (items[0]) {
        .string => |text| hexStringToBytes(allocator, text),
        else => error.InvalidParams,
    };
}

fn clearLocalState(rt: *runtime_mod.NodeRuntime) void {
    rt.state.journaled_state.account_cache.clear();
    rt.state.journaled_state.storage_cache.clear();
    rt.state.journaled_state.contract_cache.clear();
}

fn mineDetailedValue(allocator: std.mem.Allocator, rt: *runtime_mod.NodeRuntime, params: ?std.json.Value) !std.json.Value {
    const args = try parseMineArgs(params);
    const start_block = rt.head_block_number;
    try rt.mineBlocksWithTimestampInterval(args.count, args.interval_seconds);

    var array = std.json.Array.init(allocator);
    errdefer {
        for (array.items) |*item| {
            deinitJsonValue(allocator, item);
        }
        array.deinit();
    }

    var number = start_block;
    while (number < rt.head_block_number) {
        number += 1;
        const block = (try rt.blockchain.getBlockByNumber(number)) orelse return error.MinedBlockMissing;
        try array.append(try minedBlockSummaryValue(allocator, block));
    }

    return .{ .array = array };
}

fn minedBlockSummaryValue(allocator: std.mem.Allocator, block: primitives.Block.Block) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    errdefer {
        var value = std.json.Value{ .object = obj };
        deinitJsonValue(allocator, &value);
    }

    try putOwnedJson(&obj, allocator, "number", try hexQuantity(allocator, block.header.number));
    try putOwnedJson(&obj, allocator, "hash", try hexHash32(allocator, block.hash));
    try putOwnedJson(&obj, allocator, "timestamp", try hexQuantity(allocator, block.header.timestamp));
    return .{ .object = obj };
}

fn metadataValue(allocator: std.mem.Allocator, rt: *const runtime_mod.NodeRuntime) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    errdefer {
        var value = std.json.Value{ .object = obj };
        deinitJsonValue(allocator, &value);
    }

    try putOwnedJson(&obj, allocator, "mode", .{ .string = try allocator.dupe(u8, "trusted") });
    try putOwnedJson(&obj, allocator, "chainId", try hexQuantity(allocator, rt.chain_id));
    try putOwnedJson(&obj, allocator, "forking", .{ .bool = rt.fork_config != null });
    if (rt.fork_config) |fork| {
        try putOwnedJson(&obj, allocator, "forkUrl", .{ .string = try allocator.dupe(u8, fork.url) });
        try putOwnedJson(&obj, allocator, "forkBlockNumber", if (fork.block_number) |number| try hexQuantity(allocator, number) else .null);
    } else {
        try putOwnedJson(&obj, allocator, "forkUrl", .null);
        try putOwnedJson(&obj, allocator, "forkBlockNumber", .null);
    }
    return .{ .object = obj };
}

fn nodeInfoValue(allocator: std.mem.Allocator, rt: *const runtime_mod.NodeRuntime) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    errdefer {
        var value = std.json.Value{ .object = obj };
        deinitJsonValue(allocator, &value);
    }

    try putOwnedJson(&obj, allocator, "chainId", try hexQuantity(allocator, rt.chain_id));
    try putOwnedJson(&obj, allocator, "coinbase", try addressString(allocator, rt.coinbase));
    try putOwnedJson(&obj, allocator, "blockNumber", try hexQuantity(allocator, rt.head_block_number));
    try putOwnedJson(&obj, allocator, "managedAccounts", try accountsResponse(allocator, rt));
    try putOwnedJson(&obj, allocator, "mining", try miningInfoValue(allocator, rt));
    try putOwnedJson(&obj, allocator, "fork", try forkInfoValue(allocator, rt));
    return .{ .object = obj };
}

fn miningInfoValue(allocator: std.mem.Allocator, rt: *const runtime_mod.NodeRuntime) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    errdefer {
        var value = std.json.Value{ .object = obj };
        deinitJsonValue(allocator, &value);
    }

    const mode_name: []const u8 = switch (rt.mining_config) {
        .auto => "auto",
        .manual => "manual",
        .interval => "interval",
    };
    try putOwnedJson(&obj, allocator, "type", .{ .string = try allocator.dupe(u8, mode_name) });
    try putOwnedJson(&obj, allocator, "blockTime", switch (rt.mining_config) {
        .interval => |interval| try hexQuantity(allocator, interval.block_time),
        else => .null,
    });
    return .{ .object = obj };
}

fn forkInfoValue(allocator: std.mem.Allocator, rt: *const runtime_mod.NodeRuntime) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    errdefer {
        var value = std.json.Value{ .object = obj };
        deinitJsonValue(allocator, &value);
    }

    try putOwnedJson(&obj, allocator, "enabled", .{ .bool = rt.fork_config != null });
    if (rt.fork_config) |fork| {
        try putOwnedJson(&obj, allocator, "url", .{ .string = try allocator.dupe(u8, fork.url) });
        try putOwnedJson(&obj, allocator, "blockNumber", if (fork.block_number) |number| try hexQuantity(allocator, number) else .null);
    } else {
        try putOwnedJson(&obj, allocator, "url", .null);
        try putOwnedJson(&obj, allocator, "blockNumber", .null);
    }
    return .{ .object = obj };
}

fn intervalMiningSeconds(rt: *const runtime_mod.NodeRuntime) u64 {
    return switch (rt.mining_config) {
        .interval => |interval| interval.block_time,
        else => 0,
    };
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
