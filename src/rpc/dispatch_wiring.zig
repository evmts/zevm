//! Wires the JSON-RPC dispatcher to the live NodeRuntime.

const std = @import("std");
const crypto = @import("crypto");
const jsonrpc = @import("jsonrpc");
const log = @import("../log.zig");
const primitives = @import("primitives");
const guillotine_mini = @import("guillotine_mini");
const rpc_parse = @import("parse.zig");
const block_builder = @import("../block_builder.zig");
const blob_fee = @import("../blob_fee.zig");
const dispatcher_mod = @import("dispatcher.zig");
const log_index_mod = @import("../log_index.zig");

const block_query_handlers = @import("handlers/block_query_handlers.zig");
const debug_raw_handlers = @import("handlers/debug_raw.zig");
const eth_read = @import("handlers/eth_read.zig");
const eth_config = @import("handlers/eth_config.zig");
const host_adapter = @import("../host_adapter.zig");
const mining_coordinator = @import("../mining_coordinator.zig");
const runtime_mod = @import("../node/runtime.zig");
const simulation = @import("handlers/simulation.zig");
const trusted_fork_handlers = @import("trusted_fork_handlers.zig");
const tx_encoding = @import("../transaction_encoding.zig");
const tx_processor = @import("../tx_processor.zig");
const txpool = @import("../txpool.zig");
const tx_submission = @import("handlers/tx_submission.zig");
const txpool_handlers = @import("handlers/txpool.zig");
const dev_erc20_handlers = @import("handlers/dev_erc20.zig");
const execution_fixture_rpc = @import("../execution_fixture_rpc.zig");

pub const FixtureCache = execution_fixture_rpc.Cache;

var installed_fixture_cache: ?*const FixtureCache = null;

pub fn installFixtureCache(cache: *const FixtureCache) void {
    installed_fixture_cache = cache;
}

pub fn loadFixtureCacheFromDir(
    allocator: std.mem.Allocator,
    dir: []const u8,
) !?*FixtureCache {
    var cache = (try execution_fixture_rpc.Cache.loadFromTestsDir(allocator, dir)) orelse return null;
    var cache_owned = true;
    errdefer if (cache_owned) cache.deinit(allocator);
    const heap_cache = try allocator.create(FixtureCache);
    heap_cache.* = cache;
    cache_owned = false;
    return heap_cache;
}

pub fn install(registry: *dispatcher_mod.HandlerRegistry, rt: *runtime_mod.NodeRuntime) void {
    rt.enableSynchronousForkReads();
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
    // putOwnedJson takes ownership of `value`: on success it is stored in `obj`, and
    // on any failure it is freed here. This errdefer must be registered BEFORE the
    // `dupe(key)` below, otherwise a failure of that dupe would return before `value`
    // is protected and leak the caller-allocated value.
    errdefer {
        var orphaned = value;
        deinitJsonValue(allocator, &orphaned);
    }
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

    var result = try dispatchLocked(allocator, rt, method_name, params);
    errdefer deinitJsonValue(allocator, &result);
    if (rt.execution_api_timestamps and methodIs(method_name, &.{
        "eth_getBlockByHash",                    "eth_getBlockByNumber",                    "eth_getBlockReceipts",     "eth_getLogs",
        "eth_getTransactionByBlockHashAndIndex", "eth_getTransactionByBlockNumberAndIndex", "eth_getTransactionByHash", "eth_getTransactionReceipt",
        "eth_simulateV1",                        "txpool_content",                          "txpool_contentFrom",
    })) try addExecutionApiTimestamps(allocator, rt, &result, null);
    return result;
}

// The execution-apis wire profile extends transactions and logs with their block
// time. Simulated block hashes do not exist in the chain, so their children use
// the containing simulated block's timestamp. Pending transactions use null.
fn addExecutionApiTimestamps(allocator: std.mem.Allocator, rt: *runtime_mod.NodeRuntime, value: *std.json.Value, parent_time: ?u64) !void {
    switch (value.*) {
        .array => |array| for (array.items) |*item| try addExecutionApiTimestamps(allocator, rt, item, parent_time),
        .object => |*obj| {
            if (obj.get("blockHash")) |hash| {
                if ((obj.contains("nonce") and obj.contains("transactionIndex")) or (obj.contains("logIndex") and obj.contains("topics"))) {
                    const timestamp = if (hash == .null) null else parent_time orelse blk: {
                        const block_hash = try rpc_parse.parseHash32Value(hash);
                        const block = (try rt.blockchain.getBlockByHash(block_hash)) orelse break :blk null;
                        break :blk block.header.timestamp;
                    };
                    if (!obj.contains("blockTimestamp")) try putOwnedJson(obj, allocator, "blockTimestamp", if (timestamp) |t| try hexQuantity(allocator, t) else .null);
                    return;
                }
            }
            const block_time = if (obj.get("timestamp")) |t| try rpc_parse.parseQuantityValue(u64, t) else parent_time;
            var it = obj.iterator();
            while (it.next()) |entry| try addExecutionApiTimestamps(allocator, rt, entry.value_ptr, block_time);
        },
        else => {},
    }
}

fn dispatchLocked(allocator: std.mem.Allocator, rt: *runtime_mod.NodeRuntime, method_name: []const u8, params: ?std.json.Value) anyerror!std.json.Value {
    if (installed_fixture_cache) |cache| {
        if (try matchFixtureResponse(allocator, cache, method_name, params)) |result| {
            return result;
        }
    }

    if (rt.mode == .light) {
        if (@import("builtin").os.tag == .wasi) return error.ModeUnsupported;
        return dispatchLightMethod(allocator, rt, method_name, params);
    }
    if (std.mem.eql(u8, method_name, "zevm_lightSyncStatus")) {
        try validateNoParams(params);
        return error.ModeUnsupported;
    }
    if (isEngineNamespaceMethod(method_name)) {
        if (@import("builtin").os.tag == .wasi) return error.ModeUnsupported;
        return dispatchEngineMethod(allocator, rt, method_name, params);
    }

    if (std.mem.eql(u8, method_name, "rpc_modules")) {
        try validateNoParams(params);
        return rpcModulesValue(allocator);
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
        return hexU256(allocator, eth_read.currentBlobBaseFee(rt));
    }
    if (std.mem.eql(u8, method_name, "eth_config")) {
        try validateNoParams(params);
        return ethConfigValue(allocator, rt);
    }
    if (std.mem.eql(u8, method_name, "tevm_drainConsoleLogs")) {
        try validateNoParams(params);
        return drainConsoleLogsValue(allocator, rt);
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
    if (std.mem.eql(u8, method_name, "eth_hashrate")) {
        try validateNoParams(params);
        return hexQuantity(allocator, 0);
    }
    if (std.mem.eql(u8, method_name, "eth_getWork")) {
        try validateNoParams(params);
        return powWorkValue(allocator);
    }
    if (std.mem.eql(u8, method_name, "eth_submitWork")) {
        try validateSubmitWorkParams(params);
        return .{ .bool = false };
    }
    if (std.mem.eql(u8, method_name, "eth_submitHashrate")) {
        try validateSubmitHashrateParams(params);
        return .{ .bool = true };
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
            error.BlobWrapperVersionMismatch,
            error.TooManyBlobs,
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
        return hexQuantity(allocator, try rt.createBlockFilter());
    }
    if (std.mem.eql(u8, method_name, "eth_newPendingTransactionFilter")) {
        try validateNoParams(params);
        return hexQuantity(allocator, try rt.createPendingTransactionFilter());
    }
    if (std.mem.eql(u8, method_name, "eth_newFilter")) {
        return try createLogFilterValue(allocator, rt, params);
    }
    if (std.mem.eql(u8, method_name, "eth_getFilterChanges")) {
        return try getFilterChangesValue(allocator, rt, params);
    }
    if (std.mem.eql(u8, method_name, "eth_getFilterLogs")) {
        return try getFilterLogsValue(allocator, rt, params);
    }
    if (std.mem.eql(u8, method_name, "eth_uninstallFilter")) {
        return .{ .bool = rt.removeRpcFilter(try parseFilterId(params)) };
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
    if (std.mem.eql(u8, method_name, "eth_getUncleByBlockHashAndIndex")) {
        _ = try parseGetUncleByBlockHashAndIndexParams(allocator, params);
        return .null;
    }
    if (std.mem.eql(u8, method_name, "eth_getUncleByBlockNumberAndIndex")) {
        _ = try parseGetUncleByBlockNumberAndIndexParams(params);
        return .null;
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
    if (std.mem.eql(u8, method_name, "debug_traceCall")) {
        return simulation.handleDebugTraceCall(allocator, rt, params);
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
    if (methodIs(method_name, &.{ "zevm_setPrevRandao", "anvil_setPrevRandao", "hardhat_setPrevRandao" })) {
        const hash = try parseSingleHashArg(params);
        rt.dev_runtime.config.prev_randao = std.mem.readInt(u256, &hash, .big);
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_setMinGasPrice", "anvil_setMinGasPrice", "hardhat_setMinGasPrice" })) {
        rt.gas_price = try parseSingleQuantityU256Arg(params);
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_enableTraces", "anvil_enableTraces" })) {
        try validateNoParams(params);
        return .{ .bool = true };
    }
    if (std.mem.eql(u8, method_name, "hardhat_setLoggingEnabled")) {
        _ = try parseSingleBoolArg(params);
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_addCompilationResult", "hardhat_addCompilationResult" })) {
        try validateCompilationResultParams(params);
        return .{ .bool = true };
    }
    if (methodIs(method_name, &.{ "zevm_setNextBlockTimestamp", "anvil_setNextBlockTimestamp", "evm_setNextBlockTimestamp" })) {
        const timestamp = try parseTimeControlQuantity(params);
        if (timestamp <= rt.head_block_timestamp) return error.InvalidParams;
        rt.setNextBlockTimestamp(timestamp);
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
    if (std.mem.eql(u8, method_name, "tevm_drainConsoleLogs")) {
        // Light mode executes no local EVM calls, so the buffer is always empty.
        try validateNoParams(params);
        return drainConsoleLogsValue(allocator, rt);
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

fn rpcModulesValue(allocator: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    errdefer {
        var value = std.json.Value{ .object = obj };
        deinitJsonValue(allocator, &value);
    }

    try putOwnedJson(&obj, allocator, "eth", .{ .string = try allocator.dupe(u8, "1.0") });
    try putOwnedJson(&obj, allocator, "net", .{ .string = try allocator.dupe(u8, "1.0") });
    try putOwnedJson(&obj, allocator, "web3", .{ .string = try allocator.dupe(u8, "1.0") });
    try putOwnedJson(&obj, allocator, "rpc", .{ .string = try allocator.dupe(u8, "1.0") });
    try putOwnedJson(&obj, allocator, "txpool", .{ .string = try allocator.dupe(u8, "1.0") });
    try putOwnedJson(&obj, allocator, "debug", .{ .string = try allocator.dupe(u8, "1.0") });
    try putOwnedJson(&obj, allocator, "engine", .{ .string = try allocator.dupe(u8, "1.0") });
    try putOwnedJson(&obj, allocator, "zevm", .{ .string = try allocator.dupe(u8, "1.0") });
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

const EngineForkchoiceParams = struct {
    state: EngineForkchoiceState,
    payload_attrs: ?runtime_mod.EnginePayloadAttributes = null,
};

const EngineNewPayload = struct {
    block: primitives.Block.Block,
    requests_hash: ?[32]u8 = null,
    /// `expectedBlobVersionedHashes` (V3+), checked after the fork gate so a
    /// mismatch yields `INVALID` rather than `-32602`.
    expected_blob_versioned_hashes: ?std.json.Value = null,
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
    if (std.mem.eql(u8, method_name, "debug_traceCall")) return true;
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
        return engineTransitionConfigValue(allocator, transition_config);
    }
    if (methodIs(method_name, &.{
        "engine_forkchoiceUpdatedV1",
        "engine_forkchoiceUpdatedV2",
        "engine_forkchoiceUpdatedV3",
        "engine_forkchoiceUpdatedV4",
    })) {
        var temp_arena = std.heap.ArenaAllocator.init(allocator);
        defer temp_arena.deinit();
        const parsed = try parseEngineForkchoiceParams(temp_arena.allocator(), method_name, params);
        return applyEngineForkchoice(allocator, rt, method_name, parsed);
    }
    if (isEngineNewPayloadMethod(method_name)) {
        var temp_arena = std.heap.ArenaAllocator.init(allocator);
        defer temp_arena.deinit();
        const payload = try parseEngineNewPayload(temp_arena.allocator(), method_name, params);
        try validateEngineNewPayloadForFork(rt, method_name, payload.block);
        if (payload.expected_blob_versioned_hashes) |expected| {
            validateExpectedBlobVersionedHashes(temp_arena.allocator(), payload.block.body.transactions, expected) catch |err| switch (err) {
                error.BlobVersionedHashesMismatch => return enginePayloadStatusValue(allocator, "INVALID", null, "blob versioned hashes mismatch"),
                error.EnvelopeDecodeFailed => return enginePayloadStatusValue(allocator, "INVALID", null, "invalid transaction encoding"),
                else => return err,
            };
        }
        const imported = try rt.importEnginePayloadBlock(payload.block, payload.requests_hash);
        return enginePayloadStatusFromImport(allocator, imported);
    }
    if (isEngineGetPayloadMethod(method_name)) {
        const payload_id = try parseEnginePayloadIdParams(params);
        return engineGetPayloadValue(allocator, rt, method_name, payload_id);
    }
    if (methodIs(method_name, &.{ "engine_getPayloadBodiesByHashV1", "engine_getPayloadBodiesByHashV2" })) {
        return enginePayloadBodiesByHashValue(allocator, rt, params, std.mem.eql(u8, method_name, "engine_getPayloadBodiesByHashV2"));
    }
    if (methodIs(method_name, &.{ "engine_getPayloadBodiesByRangeV1", "engine_getPayloadBodiesByRangeV2" })) {
        return enginePayloadBodiesByRangeValue(allocator, rt, params, std.mem.eql(u8, method_name, "engine_getPayloadBodiesByRangeV2"));
    }
    if (methodIs(method_name, &.{ "engine_getBlobsV1", "engine_getBlobsV2", "engine_getBlobsV3" })) {
        return engineBlobsValue(allocator, rt, method_name, params);
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

pub fn engineClientVersionValue(allocator: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    // `moved` guards a single ownership transfer of `obj` into `array`. Once the
    // append succeeds, `array` owns `obj` and only the array errdefer (which itself
    // frees every appended item) is responsible for cleanup.
    var moved = false;
    errdefer if (!moved) {
        var value = std.json.Value{ .object = obj };
        deinitJsonValue(allocator, &value);
    };
    try putOwnedJson(&obj, allocator, "code", .{ .string = try allocator.dupe(u8, "ZE") });
    try putOwnedJson(&obj, allocator, "name", .{ .string = try allocator.dupe(u8, "zevm") });
    try putOwnedJson(&obj, allocator, "version", .{ .string = try allocator.dupe(u8, "v0.1.0") });
    try putOwnedJson(&obj, allocator, "commit", .{ .string = try allocator.dupe(u8, "0x00000000") });

    var array = std.json.Array.init(allocator);
    errdefer {
        for (array.items) |*item| {
            deinitJsonValue(allocator, item);
        }
        array.deinit();
    }
    try array.append(.{ .object = obj });
    moved = true;
    return .{ .array = array };
}

pub const EngineTransitionConfig = struct {
    terminal_total_difficulty: u256,
    terminal_block_hash: [32]u8,
    terminal_block_number: u64,
};

/// Parses the three `TransitionConfigurationV1` fields. Unknown or nested
/// caller-supplied fields are rejected so the response never echoes input.
pub fn parseEngineTransitionConfig(params: ?std.json.Value) !EngineTransitionConfig {
    const items = try paramsArrayItems(params);
    if (items.len != 1 or items[0] != .object) return error.InvalidParams;
    const obj = items[0].object;
    if (obj.count() != 3) return error.InvalidParams;
    return .{
        .terminal_total_difficulty = try parseU256Json(obj.get("terminalTotalDifficulty") orelse return error.InvalidParams),
        .terminal_block_hash = try rpc_parse.parseHash32Value(obj.get("terminalBlockHash") orelse return error.InvalidParams),
        .terminal_block_number = try parseU64Json(obj.get("terminalBlockNumber") orelse return error.InvalidParams),
    };
}

fn engineTransitionConfigValue(allocator: std.mem.Allocator, config: EngineTransitionConfig) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    errdefer {
        var value = std.json.Value{ .object = obj };
        deinitJsonValue(allocator, &value);
    }
    try putOwnedJson(&obj, allocator, "terminalTotalDifficulty", try hexU256(allocator, config.terminal_total_difficulty));
    try putOwnedJson(&obj, allocator, "terminalBlockHash", try hexHash32(allocator, config.terminal_block_hash));
    try putOwnedJson(&obj, allocator, "terminalBlockNumber", try hexQuantity(allocator, config.terminal_block_number));
    return .{ .object = obj };
}

fn parseEngineForkchoiceParams(
    allocator: std.mem.Allocator,
    method_name: []const u8,
    params: ?std.json.Value,
) !EngineForkchoiceParams {
    const items = try paramsArrayItems(params);
    if (items.len < 1 or items.len > 2) return error.InvalidParams;

    const object = switch (items[0]) {
        .object => |object| object,
        else => return error.InvalidParams,
    };
    return .{
        .state = .{
            .head_hash = try rpc_parse.parseHash32Value(object.get("headBlockHash") orelse return error.InvalidParams),
            .safe_hash = try rpc_parse.parseHash32Value(object.get("safeBlockHash") orelse return error.InvalidParams),
            .finalized_hash = try rpc_parse.parseHash32Value(object.get("finalizedBlockHash") orelse return error.InvalidParams),
        },
        .payload_attrs = if (items.len == 2 and items[1] != .null)
            try parseEnginePayloadAttributes(allocator, method_name, items[1])
        else
            null,
    };
}

fn validateEngineForkchoiceParams(method_name: []const u8, params: ?std.json.Value) !void {
    const items = try paramsArrayItems(params);
    if (items.len < 1 or items.len > 2) return error.InvalidParams;
    const object = switch (items[0]) {
        .object => |object| object,
        else => return error.InvalidParams,
    };
    try validateHash32Json(object.get("headBlockHash") orelse return error.InvalidParams);
    try validateHash32Json(object.get("safeBlockHash") orelse return error.InvalidParams);
    try validateHash32Json(object.get("finalizedBlockHash") orelse return error.InvalidParams);
    if (items.len == 2 and items[1] != .null) {
        try validateEnginePayloadAttributes(method_name, items[1]);
    }
}

fn enginePayloadVersion(method_name: []const u8) u8 {
    if (std.mem.endsWith(u8, method_name, "V6")) return 6;
    if (std.mem.endsWith(u8, method_name, "V5")) return 5;
    if (std.mem.endsWith(u8, method_name, "V4")) return 4;
    if (std.mem.endsWith(u8, method_name, "V3")) return 3;
    if (std.mem.endsWith(u8, method_name, "V2")) return 2;
    return 1;
}

fn parseEnginePayloadAttributes(
    allocator: std.mem.Allocator,
    method_name: []const u8,
    value: std.json.Value,
) !runtime_mod.EnginePayloadAttributes {
    const obj = switch (value) {
        .object => |object| object,
        else => return error.InvalidParams,
    };
    const version = enginePayloadVersion(method_name);
    const withdrawals_value = obj.get("withdrawals");
    const has_withdrawals = if (withdrawals_value) |withdrawals| withdrawals != .null else false;
    const parent_beacon_block_root = if (version >= 3) blk: {
        const parent_root = obj.get("parentBeaconBlockRoot") orelse break :blk null;
        break :blk switch (parent_root) {
            .null => null,
            else => try rpc_parse.parseHash32Value(parent_root),
        };
    } else null;

    return .{
        .timestamp = try parseU64Json(obj.get("timestamp") orelse return error.InvalidParams),
        .prev_randao = try rpc_parse.parseHash32Value(obj.get("prevRandao") orelse return error.InvalidParams),
        .fee_recipient = try parseAddressJson(obj.get("suggestedFeeRecipient") orelse return error.InvalidParams),
        .withdrawals = if (has_withdrawals) try parseTestingBuildBlockWithdrawals(allocator, withdrawals_value.?) else &.{},
        .has_withdrawals = has_withdrawals,
        .parent_beacon_block_root = parent_beacon_block_root,
        .payload_version = version,
    };
}

fn validateEnginePayloadAttributes(method_name: []const u8, value: std.json.Value) !void {
    const obj = switch (value) {
        .object => |object| object,
        else => return error.InvalidParams,
    };
    const version = enginePayloadVersion(method_name);
    _ = try parseQuantityU64Json(obj.get("timestamp") orelse return error.InvalidParams);
    try validateHash32Json(obj.get("prevRandao") orelse return error.InvalidParams);
    _ = try parseAddressJson(obj.get("suggestedFeeRecipient") orelse return error.InvalidParams);
    if (version >= 2) {
        _ = switch (obj.get("withdrawals") orelse .null) {
            .array, .null => {},
            else => return error.InvalidParams,
        };
    } else if (obj.get("withdrawals")) |withdrawals| {
        _ = switch (withdrawals) {
            .array, .null => {},
            else => return error.InvalidParams,
        };
    }
    if (version >= 3) {
        if (obj.get("parentBeaconBlockRoot")) |root| {
            if (root != .null) try validateHash32Json(root);
        }
    }
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
        try validateEngineForkchoiceParams(method_name, params);
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
    if (std.mem.eql(u8, method_name, "debug_traceCall")) {
        const items = try paramsArrayItems(params);
        if (items.len < 2 or items.len > 3 or items[0] != .object) return error.InvalidParams;
        return;
    }
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
    parsed: EngineForkchoiceParams,
) !std.json.Value {
    const state = parsed.state;
    if (rt.engineInvalidPayloadResult(state.head_hash)) |invalid| {
        return engineForkchoiceResult(allocator, "INVALID", invalid.latest_valid_hash, invalid.validation_error, null);
    }
    const head_block = rt.blockchain.getBlockLocal(state.head_hash) orelse {
        return engineForkchoiceResult(allocator, "SYNCING", null, null, null);
    };
    const safe_hash = if (hashIsZero(state.safe_hash)) null else state.safe_hash;
    const finalized_hash = if (hashIsZero(state.finalized_hash)) null else state.finalized_hash;
    try validateForkchoiceAncestry(rt, state.head_hash, safe_hash, finalized_hash);

    const applied = rt.setEngineCanonicalHead(state.head_hash) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => if (runtime_mod.isDeterministicPayloadError(err))
            return engineForkchoiceResult(allocator, "INVALID", null, @errorName(err), null)
        else
            return error.InternalError,
    };
    if (applied.status == .syncing) return engineForkchoiceResult(allocator, "SYNCING", null, null, null);
    rt.setEngineFinalityHeads(safe_hash, finalized_hash);

    if (parsed.payload_attrs) |attrs| {
        if (attrs.timestamp <= head_block.header.timestamp) return error.InvalidPayloadAttributes;
        try validateEnginePayloadAttributesForFork(rt, head_block, attrs);
    }

    const payload_id = if (parsed.payload_attrs) |attrs|
        try rt.createEnginePayloadJob(state.head_hash, attrs)
    else
        null;

    const head_hash_hex = std.fmt.bytesToHex(state.head_hash, .lower);
    log.info(.rpc, "engine_forkchoice_updated method={s} head_block_number={} head_hash=0x{s}", .{
        method_name,
        head_block.header.number,
        &head_hash_hex,
    });
    return engineForkchoiceResult(allocator, "VALID", state.head_hash, null, payload_id);
}

/// Engine API forkchoice ordering: finalized is an ancestor of (or equal to)
/// safe, and safe is an ancestor of (or equal to) head. A known-but-unordered
/// or unknown safe/finalized block is `-38002 Invalid forkchoice state`.
fn validateForkchoiceAncestry(
    rt: *runtime_mod.NodeRuntime,
    head_hash: [32]u8,
    safe_hash: ?[32]u8,
    finalized_hash: ?[32]u8,
) !void {
    if (safe_hash) |hash| {
        if (rt.blockchain.getBlockLocal(hash) == null) return error.InvalidForkchoiceState;
        if (!rt.localBlockIsAncestorOf(hash, head_hash)) return error.InvalidForkchoiceState;
    }
    if (finalized_hash) |hash| {
        if (rt.blockchain.getBlockLocal(hash) == null) return error.InvalidForkchoiceState;
        if (!rt.localBlockIsAncestorOf(hash, head_hash)) return error.InvalidForkchoiceState;
        if (safe_hash) |safe| {
            if (!rt.localBlockIsAncestorOf(hash, safe)) return error.InvalidForkchoiceState;
        }
    }
}

fn validateEnginePayloadAttributesForFork(
    rt: *runtime_mod.NodeRuntime,
    parent: primitives.Block.Block,
    attrs: runtime_mod.EnginePayloadAttributes,
) !void {
    const block_number = parent.header.number +| 1;
    const fork = rt.hardforkAt(block_number, attrs.timestamp);

    // Engine API: a forkchoiceUpdated version outside its fork window is
    // -38005 Unsupported fork, not a malformed-attributes error.
    try validateEngineMethodForkWindow(attrs.payload_version, fork);

    if (fork.isAtLeast(.CANCUN)) {
        if (!attrs.has_withdrawals) return error.InvalidPayloadAttributes;
        if (attrs.parent_beacon_block_root == null) return error.InvalidPayloadAttributes;
        return;
    }

    if (attrs.parent_beacon_block_root != null or attrs.payload_version >= 3) {
        return error.InvalidPayloadAttributes;
    }

    if (fork.isAtLeast(.SHANGHAI)) {
        if (attrs.payload_version < 2) return error.InvalidPayloadAttributes;
        if (!attrs.has_withdrawals) return error.InvalidPayloadAttributes;
        return;
    }

    if (attrs.has_withdrawals) {
        return error.InvalidPayloadAttributes;
    }
}

fn validateEngineNewPayloadForFork(
    rt: *runtime_mod.NodeRuntime,
    method_name: []const u8,
    block: primitives.Block.Block,
) !void {
    const version = enginePayloadVersion(method_name);
    const fork = rt.hardforkAt(block.header.number, block.header.timestamp);
    const has_withdrawals = block.body.withdrawals != null or block.header.withdrawals_root != null;

    // Engine API fork matrix: V1/V2 end at Cancun; V3 is Cancun-only; V4+
    // carries Prague execution requests and is invalid before Prague.
    if (version < 3 and fork.isAtLeast(.CANCUN)) return error.UnsupportedFork;
    if (version == 3 and (!fork.isAtLeast(.CANCUN) or fork.isAtLeast(.PRAGUE))) return error.UnsupportedFork;
    if (version >= 4 and !fork.isAtLeast(.PRAGUE)) return error.UnsupportedFork;

    if (fork.isAtLeast(.CANCUN)) {
        if (!has_withdrawals) return error.InvalidParams;
        if (block.header.parent_beacon_block_root == null) return error.InvalidPayloadAttributes;
        return;
    }

    if (block.header.parent_beacon_block_root != null or version >= 3) {
        return error.InvalidPayloadAttributes;
    }

    if (fork.isAtLeast(.SHANGHAI)) {
        if (version < 2) return error.InvalidPayloadAttributes;
        if (!has_withdrawals) return error.InvalidParams;
        return;
    }

    if (has_withdrawals) {
        return error.InvalidParams;
    }
}

fn engineForkchoiceResult(
    allocator: std.mem.Allocator,
    status: []const u8,
    latest_valid_hash: ?[32]u8,
    validation_error: ?[]const u8,
    payload_id: ?u64,
) !std.json.Value {
    var payload_status = std.json.ObjectMap.init(allocator);
    var payload_status_transferred = false;
    errdefer if (!payload_status_transferred) {
        var value = std.json.Value{ .object = payload_status };
        deinitJsonValue(allocator, &value);
    };
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
    // `putOwnedJson` takes unconditional ownership and frees on error.
    payload_status_transferred = true;
    try putOwnedJson(&result, allocator, "payloadStatus", .{ .object = payload_status });
    try putOwnedJson(&result, allocator, "payloadId", if (payload_id) |id| try enginePayloadIdValue(allocator, id) else .null);
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

fn parseEnginePayloadIdParams(params: ?std.json.Value) !u64 {
    const items = try paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    const text = switch (items[0]) {
        .string => |s| s,
        else => return error.InvalidParams,
    };
    try validateHexData(text);
    if (text.len != 18) return error.InvalidParams;
    return std.fmt.parseInt(u64, text[2..], 16) catch return error.InvalidParams;
}

fn validateEnginePayloadIdParams(params: ?std.json.Value) !void {
    _ = try parseEnginePayloadIdParams(params);
}

fn enginePayloadIdValue(allocator: std.mem.Allocator, id: u64) !std.json.Value {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, id, .big);
    return hexBytes(allocator, &bytes);
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
    if (start == 0 or count == 0) return error.InvalidParams;
    if (count > MAX_ENGINE_PAYLOAD_BODIES) return error.TooLargeRequest;
    return .{ .start = start, .count = count };
}

/// Engine API cap on `getPayloadBodiesBy{Hash,Range}` request size; larger
/// requests return `-38004 Too large request`.
pub const MAX_ENGINE_PAYLOAD_BODIES: u64 = 1024;

fn engineHashArrayItems(params: ?std.json.Value) ![]const std.json.Value {
    const items = try paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    const hashes = switch (items[0]) {
        .array => |array| array.items,
        else => return error.InvalidParams,
    };
    if (hashes.len > MAX_ENGINE_PAYLOAD_BODIES) return error.TooLargeRequest;
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

fn enginePayloadStatusFromImport(
    allocator: std.mem.Allocator,
    result: runtime_mod.EnginePayloadImportResult,
) !std.json.Value {
    return switch (result.status) {
        .valid => enginePayloadStatusValue(allocator, "VALID", result.latest_valid_hash, result.validation_error),
        .invalid => enginePayloadStatusValue(allocator, "INVALID", result.latest_valid_hash, result.validation_error),
        .invalid_block_hash => enginePayloadStatusValue(allocator, "INVALID", result.latest_valid_hash, result.validation_error),
        .syncing => enginePayloadStatusValue(allocator, "SYNCING", null, null),
    };
}

fn parseEngineNewPayload(
    allocator: std.mem.Allocator,
    method_name: []const u8,
    params: ?std.json.Value,
) !EngineNewPayload {
    try validateEngineNewPayloadParams(method_name, params);
    const items = try paramsArrayItems(params);
    const payload_obj = items[0].object;
    const version = enginePayloadVersion(method_name);

    const parent_hash = try rpc_parse.parseHash32Value(payload_obj.get("parentHash") orelse return error.InvalidParams);
    const fee_recipient = try parseAddressJson(payload_obj.get("feeRecipient") orelse return error.InvalidParams);
    const state_root = try rpc_parse.parseHash32Value(payload_obj.get("stateRoot") orelse return error.InvalidParams);
    const receipts_root = try rpc_parse.parseHash32Value(payload_obj.get("receiptsRoot") orelse return error.InvalidParams);
    const logs_bloom = try parseFixedHexBytesValue(allocator, payload_obj.get("logsBloom") orelse return error.InvalidParams, primitives.BlockHeader.BLOOM_SIZE);
    const prev_randao = try rpc_parse.parseHash32Value(payload_obj.get("prevRandao") orelse return error.InvalidParams);
    const block_number = try parseU64Json(payload_obj.get("blockNumber") orelse return error.InvalidParams);
    const gas_limit = try parseU64Json(payload_obj.get("gasLimit") orelse return error.InvalidParams);
    const gas_used = try parseU64Json(payload_obj.get("gasUsed") orelse return error.InvalidParams);
    const timestamp = try parseU64Json(payload_obj.get("timestamp") orelse return error.InvalidParams);
    const extra_data = try rpc_parse.parseHexDataBytes(allocator, payload_obj.get("extraData") orelse return error.InvalidParams);
    if (extra_data.len > primitives.BlockHeader.MAX_EXTRA_DATA_SIZE) return error.InvalidParams;
    const base_fee = try parseU256Json(payload_obj.get("baseFeePerGas") orelse return error.InvalidParams);
    const declared_hash = try rpc_parse.parseHash32Value(payload_obj.get("blockHash") orelse return error.InvalidParams);
    const transactions = try parseEnginePayloadTransactions(allocator, payload_obj.get("transactions") orelse return error.InvalidParams);

    const withdrawals: ?[]const primitives.BlockBody.Withdrawal = if (payload_obj.get("withdrawals")) |value| blk: {
        if (value == .null) break :blk null;
        break :blk try parseTestingBuildBlockWithdrawals(allocator, value);
    } else if (version > 2)
        return error.InvalidParams
    else
        null;

    const withdrawals_root = if (withdrawals) |items_withdrawals|
        try block_builder.computeWithdrawalsRoot(allocator, items_withdrawals)
    else
        null;

    const transactions_root = try block_builder.computeRawTransactionsRoot(allocator, transactions);
    const parent_beacon_block_root = if (version >= 3)
        try rpc_parse.parseHash32Value(items[2])
    else
        null;
    const requests_hash = if (version >= 4)
        try parseExecutionRequestsHash(allocator, items[3])
    else
        null;

    if (version >= 4) {
        if (payload_obj.get("blockAccessList")) |block_access_list| {
            if (block_access_list != .array and block_access_list != .null) return error.InvalidParams;
        }
    }

    const body = primitives.BlockBody.BlockBody{
        .transactions = transactions,
        .ommers = &.{},
        .withdrawals = withdrawals,
    };
    var header = primitives.BlockHeader.BlockHeader{
        .parent_hash = parent_hash,
        .ommers_hash = primitives.BlockHeader.EMPTY_OMMERS_HASH,
        .beneficiary = fee_recipient,
        .state_root = state_root,
        .transactions_root = transactions_root,
        .receipts_root = receipts_root,
        .logs_bloom = logs_bloom,
        .difficulty = 0,
        .number = block_number,
        .gas_limit = gas_limit,
        .gas_used = gas_used,
        .timestamp = timestamp,
        .extra_data = extra_data,
        .mix_hash = prev_randao,
        .nonce = [_]u8{0} ** primitives.BlockHeader.NONCE_SIZE,
        .base_fee_per_gas = base_fee,
        .withdrawals_root = withdrawals_root,
        .blob_gas_used = if (version >= 3) try parseU64Json(payload_obj.get("blobGasUsed") orelse return error.InvalidParams) else null,
        .excess_blob_gas = if (version >= 3) try parseU64Json(payload_obj.get("excessBlobGas") orelse return error.InvalidParams) else null,
        .parent_beacon_block_root = parent_beacon_block_root,
    };
    _ = &header;
    var block = try primitives.Block.from(&header, &body, allocator);
    block.hash = declared_hash;
    block.size = try engineBlockRlpSize(allocator, &header, &body, requests_hash);
    return .{
        .block = block,
        .requests_hash = requests_hash,
        .expected_blob_versioned_hashes = if (version >= 3) items[1] else null,
    };
}

/// EIP-7934: canonical RLP size of the execution block, including the Prague
/// `requests_hash` header field when `header.requests_hash` is not already set.
pub fn engineBlockRlpSize(
    allocator: std.mem.Allocator,
    header: *const primitives.BlockHeader.BlockHeader,
    body: *const primitives.BlockBody.BlockBody,
    requests_hash: ?[32]u8,
) !u64 {
    const base_block = try primitives.Block.from(header, body, allocator);
    const fork: block_builder.Hardfork = if (requests_hash != null) .prague else .cancun;
    return @intCast(block_builder.blockRlpSizeWithRequestsHash(
        @intCast(base_block.size),
        header,
        fork,
        requests_hash,
    ));
}

/// Appends a 32-byte string item to an RLP-encoded list and re-frames it.
fn appendRlpListBytes32(allocator: std.mem.Allocator, list: []const u8, item: [32]u8) ![]u8 {
    if (list.len == 0 or list[0] < 0xc0) return error.InvalidParams;
    const payload_start: usize = if (list[0] <= 0xf7) 1 else 1 + @as(usize, list[0] - 0xf7);
    if (payload_start > list.len) return error.InvalidParams;
    const old_payload = list[payload_start..];
    const payload_len = old_payload.len + 33;

    var prefix: [9]u8 = undefined;
    var prefix_len: usize = 1;
    if (payload_len < 56) {
        prefix[0] = 0xc0 + @as(u8, @intCast(payload_len));
    } else {
        var len_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &len_bytes, payload_len, .big);
        const first = std.mem.indexOfNone(u8, &len_bytes, &.{0}) orelse 7;
        const len_of_len = 8 - first;
        prefix[0] = 0xf7 + @as(u8, @intCast(len_of_len));
        @memcpy(prefix[1 .. 1 + len_of_len], len_bytes[first..]);
        prefix_len = 1 + len_of_len;
    }

    const out = try allocator.alloc(u8, prefix_len + payload_len);
    @memcpy(out[0..prefix_len], prefix[0..prefix_len]);
    @memcpy(out[prefix_len .. prefix_len + old_payload.len], old_payload);
    out[prefix_len + old_payload.len] = 0xa0;
    @memcpy(out[prefix_len + old_payload.len + 1 ..], &item);
    return out;
}

fn parseFixedHexBytesValue(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    comptime len: usize,
) ![len]u8 {
    const bytes = try rpc_parse.parseHexDataBytes(allocator, value);
    if (bytes.len != len) return error.InvalidParams;
    return bytes[0..len].*;
}

fn parseEnginePayloadTransactions(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) ![]const primitives.BlockBody.TransactionData {
    const items = switch (value) {
        .array => |array| array.items,
        else => return error.InvalidParams,
    };
    const transactions = try allocator.alloc(primitives.BlockBody.TransactionData, items.len);
    for (items, 0..) |item, index| {
        const raw = try rpc_parse.parseHexDataBytes(allocator, item);
        if (raw.len == 0) return error.InvalidParams;
        tx_encoding.requireCanonicalEnvelope(raw) catch return error.InvalidParams;
        transactions[index] = .{ .raw = raw };
    }
    return transactions;
}

fn validateExpectedBlobVersionedHashes(
    allocator: std.mem.Allocator,
    transactions: []const primitives.BlockBody.TransactionData,
    value: std.json.Value,
) !void {
    const expected = switch (value) {
        .array => |array| array.items,
        else => return error.InvalidParams,
    };
    var expected_index: usize = 0;
    for (transactions) |transaction| {
        var decoded = tx_encoding.decodeEnvelope(allocator, transaction.raw) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.EnvelopeDecodeFailed,
        };
        defer decoded.deinit(allocator);
        if (tx_encoding.envelopeBlobVersionedHashes(decoded)) |hashes| {
            for (hashes) |hash| {
                if (expected_index >= expected.len) return error.BlobVersionedHashesMismatch;
                const expected_hash = try rpc_parse.parseHash32Value(expected[expected_index]);
                if (!std.mem.eql(u8, &hash.bytes, &expected_hash)) return error.BlobVersionedHashesMismatch;
                expected_index += 1;
            }
        }
    }
    if (expected_index != expected.len) return error.BlobVersionedHashesMismatch;
}

/// EIP-7685 `executionRequests`: each entry is `type || request_data` with
/// non-empty data, and types are unique and strictly increasing.
pub fn parseExecutionRequestsHash(allocator: std.mem.Allocator, value: std.json.Value) ![32]u8 {
    const items = switch (value) {
        .array => |array| array.items,
        else => return error.InvalidParams,
    };
    var deposits = std.ArrayList(u8){};
    defer deposits.deinit(allocator);
    var withdrawals = std.ArrayList(u8){};
    defer withdrawals.deinit(allocator);
    var consolidations = std.ArrayList(u8){};
    defer consolidations.deinit(allocator);

    var previous_type: ?u8 = null;
    for (items) |item| {
        const request = try rpc_parse.parseHexDataBytes(allocator, item);
        defer allocator.free(request);
        if (request.len < 2) return error.InvalidParams;
        if (previous_type) |previous| {
            if (request[0] <= previous) return error.InvalidParams;
        }
        previous_type = request[0];
        switch (request[0]) {
            0 => try deposits.appendSlice(allocator, request[1..]),
            1 => try withdrawals.appendSlice(allocator, request[1..]),
            2 => try consolidations.appendSlice(allocator, request[1..]),
            else => return error.InvalidParams,
        }
    }

    return block_builder.computeRequestsHash(.{
        .deposits = deposits.items,
        .withdrawals = withdrawals.items,
        .consolidations = consolidations.items,
    });
}

fn engineGetPayloadValue(
    allocator: std.mem.Allocator,
    rt: *runtime_mod.NodeRuntime,
    method_name: []const u8,
    payload_id: u64,
) !std.json.Value {
    const job = rt.enginePayloadJob(payload_id) orelse return error.UnknownPayload;
    const version = enginePayloadVersion(method_name);

    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();
    const temp = temp_arena.allocator();

    const parent_block = rt.blockchain.getBlockLocal(job.parent_hash) orelse return error.UnknownPayload;
    var raw_txs = std.ArrayList(primitives.BlockBody.TransactionData){};
    defer raw_txs.deinit(temp);
    var exec_txs = std.ArrayList(tx_processor.ExecutionTx){};
    defer exec_txs.deinit(temp);

    const block_number = parent_block.header.number +| 1;
    const hardfork = rt.hardforkAt(block_number, job.attrs.timestamp);
    try validateEngineGetPayloadForFork(version, hardfork);
    const excess_blob_gas = if (hardfork.isAtLeast(.CANCUN))
        mining_coordinator.nextExcessBlobGasForChildWithConfig(rt.hardfork_config, parent_block.header, block_number, job.attrs.timestamp)
    else
        0;
    const blob_base_fee = blob_fee.blobBaseFeeAt(rt.hardfork_config, block_number, job.attrs.timestamp, excess_blob_gas);

    const candidates = try rt.pool.getReady(temp);
    var eligible: usize = 0;
    for (candidates) |pooled| {
        if (pooled.receipt_type == .eip4844 and (pooled.blob_sidecars.len == 0 or
            (pooled.blob_sidecars[0].proofs == .cells) != hardfork.isAtLeast(.OSAKA)))
        {
            continue;
        }
        candidates[eligible] = pooled;
        eligible += 1;
    }
    const ready = candidates[0..eligible];
    // exec_ready_indexes[i] is the `ready` index of exec_txs[i]. A pooled tx
    // that fails to decode or recover is skipped alone; it must not empty
    // the whole payload.
    var exec_ready_indexes = std.ArrayList(usize){};
    defer exec_ready_indexes.deinit(temp);
    for (ready, 0..) |pooled, ready_index| {
        const len_before = exec_txs.items.len;
        appendTestingBuildBlockTx(temp, pooled.raw, &raw_txs, &exec_txs, blob_base_fee) catch |err| {
            if (err == error.OutOfMemory) return err;
            raw_txs.shrinkRetainingCapacity(len_before);
            exec_txs.shrinkRetainingCapacity(len_before);
            log.warn(.rpc, "engine_get_payload_skipped_pool_tx error={s}", .{@errorName(err)});
            continue;
        };
        try exec_ready_indexes.append(temp, ready_index);
    }

    var recent_block_hashes: [256][32]u8 = undefined;
    const block_hashes = rt.blockchain.last256BlockHashesLocal(job.parent_hash, &recent_block_hashes) catch return error.UnknownPayload;
    const block_base_fee = if (hardfork.isAtLeast(.LONDON))
        block_builder.expectedBaseFeePerGas(&parent_block.header) catch return error.BuildBlockFailed
    else
        0;
    const block_gas_limit = childTestingBlockGasLimit(parent_block.header.gas_limit, rt.dev_runtime.config.block_gas_limit);

    const block_ctx = guillotine_mini.BlockContext{
        .chain_id = rt.chain_id,
        .block_number = block_number,
        .block_timestamp = job.attrs.timestamp,
        .block_difficulty = 0,
        .block_prevrandao = std.mem.readInt(u256, &job.attrs.prev_randao, .big),
        .block_coinbase = job.attrs.fee_recipient,
        .block_gas_limit = block_gas_limit,
        .block_base_fee = block_base_fee,
        .blob_base_fee = blob_base_fee,
        .block_hashes = block_hashes,
    };

    // The job's parent may not be the current head (a later forkchoiceUpdated
    // or a fork). Build on the parent's post-state, never on rt.state blindly.
    var replayed_parent_state: ?@TypeOf(rt.state) = null;
    defer if (replayed_parent_state) |*parent_state| parent_state.deinit();
    const head_hash = rt.blockchain.getCanonicalHash(rt.head_block_number);
    const parent_is_head = if (head_hash) |hash| std.mem.eql(u8, &job.parent_hash, &hash) else false;
    const build_state = if (parent_is_head) &rt.state else parent_state: {
        replayed_parent_state = rt.replayStateToBlockHash(job.parent_hash) catch |err| {
            if (err == error.OutOfMemory) return err;
            log.warn(.rpc, "engine_get_payload_parent_replay_failed error={s}", .{@errorName(err)});
            return error.BuildBlockFailed;
        };
        break :parent_state &replayed_parent_state.?;
    };

    try build_state.checkpoint();
    var reverted = false;
    defer if (!reverted) build_state.revert();

    var adapter = host_adapter.HostAdapter{ .state = build_state };
    const withdrawals: ?[]const primitives.BlockBody.Withdrawal = if (hardfork.isAtLeast(.SHANGHAI))
        job.attrs.withdrawals
    else
        null;
    const parent_beacon_block_root: ?[32]u8 = if (hardfork.isAtLeast(.CANCUN))
        (job.attrs.parent_beacon_block_root orelse primitives.Hash.ZERO)
    else
        null;
    var result = block_builder.buildBlockWithOptions(
        temp,
        build_state,
        adapter.hostInterface(),
        exec_txs.items,
        block_ctx,
        .{
            .fork = block_builder.hardforkFromEvm(hardfork),
            .hardfork_config = rt.hardfork_config,
            .withdrawals = withdrawals,
            .parent_beacon_block_root = parent_beacon_block_root,
            .parent_hash = job.parent_hash,
            .skip_invalid_transactions = true,
            .require_system_contracts = rt.genesis_alloc_path != null,
        },
    ) catch return error.BuildBlockFailed;
    defer result.deinit(temp);

    build_state.revert();
    reverted = true;

    const included_raw_txs = try includedRawTransactions(temp, raw_txs.items, result.included_tx_indexes);
    const included_ready_indexes = try temp.alloc(usize, result.included_tx_indexes.len);
    for (result.included_tx_indexes, included_ready_indexes) |exec_index, *ready_index| {
        if (exec_index >= exec_ready_indexes.items.len) return error.BuildBlockFailed;
        ready_index.* = exec_ready_indexes.items[exec_index];
    }
    const included_blob_sidecars = try includedBlobSidecarsFromReady(temp, ready, included_ready_indexes);
    const transactions_root = block_builder.computeRawTransactionsRoot(temp, included_raw_txs) catch return error.BuildBlockFailed;
    const actual_withdrawals = withdrawals orelse &.{};
    var header = primitives.BlockHeader.BlockHeader{
        .parent_hash = job.parent_hash,
        .ommers_hash = primitives.BlockHeader.EMPTY_OMMERS_HASH,
        .beneficiary = job.attrs.fee_recipient,
        .state_root = result.state_root,
        .transactions_root = transactions_root,
        .receipts_root = result.receipts_root,
        .logs_bloom = result.logs_bloom,
        .difficulty = 0,
        .number = block_number,
        .gas_limit = block_ctx.block_gas_limit,
        .gas_used = result.total_gas_used,
        .timestamp = job.attrs.timestamp,
        .extra_data = &.{},
        .mix_hash = job.attrs.prev_randao,
        .nonce = [_]u8{0} ** primitives.BlockHeader.NONCE_SIZE,
        .base_fee_per_gas = if (hardfork.isAtLeast(.LONDON)) block_base_fee else null,
        .withdrawals_root = if (hardfork.isAtLeast(.SHANGHAI))
            (result.withdrawals_root orelse primitives.BlockHeader.EMPTY_WITHDRAWALS_ROOT)
        else
            null,
        .blob_gas_used = if (hardfork.isAtLeast(.CANCUN)) result.blob_gas_used else null,
        .excess_blob_gas = if (hardfork.isAtLeast(.CANCUN)) excess_blob_gas else null,
        .parent_beacon_block_root = parent_beacon_block_root,
    };
    _ = &header;
    const block_hash = block_builder.computeHeaderHashWithRequestsHash(temp, &header, result.requests_hash) catch return error.BuildBlockFailed;

    const payload = try engineExecutionPayloadValue(
        allocator,
        header,
        block_hash,
        included_raw_txs,
        actual_withdrawals,
        version,
    );
    if (version == 1) return payload;

    return enginePayloadEnvelopeValue(
        allocator,
        payload,
        blockValueFromReceipts(result.receipts, block_base_fee),
        version,
        included_blob_sidecars,
        result.execution_requests,
    );
}

/// Engine API `getPayloadVN` fork windows: V1 Paris, V2 Paris..Shanghai,
/// V3 Cancun, V4 Prague, V5 Osaka, V6 Amsterdam+. A payload built outside the
/// method's fork is `-38005 Unsupported fork`.
pub fn validateEngineGetPayloadForFork(version: u8, fork: guillotine_mini.Hardfork) !void {
    switch (version) {
        1 => if (fork.isAtLeast(.SHANGHAI)) return error.UnsupportedFork,
        2 => if (fork.isAtLeast(.CANCUN)) return error.UnsupportedFork,
        3 => if (!fork.isAtLeast(.CANCUN) or fork.isAtLeast(.PRAGUE)) return error.UnsupportedFork,
        4 => if (!fork.isAtLeast(.PRAGUE) or fork.isAtLeast(.OSAKA)) return error.UnsupportedFork,
        5 => if (!fork.isAtLeast(.OSAKA) or fork.isAtLeast(.AMSTERDAM)) return error.UnsupportedFork,
        6 => if (!fork.isAtLeast(.AMSTERDAM)) return error.UnsupportedFork,
        else => return error.UnsupportedFork,
    }
}

/// Engine API `forkchoiceUpdatedVN` fork windows for payload attributes:
/// V1/V2 end at Cancun, V3 starts at Cancun.
pub fn validateEngineMethodForkWindow(version: u8, fork: guillotine_mini.Hardfork) !void {
    if (version < 3 and fork.isAtLeast(.CANCUN)) return error.UnsupportedFork;
    if (version >= 3 and !fork.isAtLeast(.CANCUN)) return error.UnsupportedFork;
}

fn includedRawTransactions(
    allocator: std.mem.Allocator,
    raw_txs: []const primitives.BlockBody.TransactionData,
    included_tx_indexes: []const usize,
) ![]primitives.BlockBody.TransactionData {
    const included = try allocator.alloc(primitives.BlockBody.TransactionData, included_tx_indexes.len);
    for (included_tx_indexes, 0..) |ready_index, out_index| {
        if (ready_index >= raw_txs.len) return error.BuildBlockFailed;
        included[out_index] = raw_txs[ready_index];
    }
    return included;
}

fn includedBlobSidecarsFromReady(
    allocator: std.mem.Allocator,
    ready: []const txpool.PooledTransaction,
    included_tx_indexes: []const usize,
) ![]tx_encoding.BlobSidecar {
    var sidecars = std.ArrayList(tx_encoding.BlobSidecar){};
    errdefer sidecars.deinit(allocator);

    for (included_tx_indexes) |ready_index| {
        if (ready_index >= ready.len) return error.BuildBlockFailed;
        try sidecars.appendSlice(allocator, ready[ready_index].blob_sidecars);
    }

    return try sidecars.toOwnedSlice(allocator);
}

test "included blob sidecars are filtered by included transaction indexes" {
    var first_sidecar: tx_encoding.BlobSidecar = undefined;
    @memset(first_sidecar.blob[0..], 0x11);
    first_sidecar.commitment = [_]u8{0x12} ** 48;
    first_sidecar.proofs = .{ .blob = [_]u8{0x13} ** 48 };
    var first_sidecars = [_]tx_encoding.BlobSidecar{first_sidecar};

    var included_sidecars = [_]tx_encoding.BlobSidecar{ undefined, undefined };
    @memset(included_sidecars[0].blob[0..], 0x21);
    included_sidecars[0].commitment = [_]u8{0x22} ** 48;
    included_sidecars[0].proofs = .{ .blob = [_]u8{0x23} ** 48 };
    @memset(included_sidecars[1].blob[0..], 0x31);
    included_sidecars[1].commitment = [_]u8{0x32} ** 48;
    included_sidecars[1].proofs = .{ .blob = [_]u8{0x33} ** 48 };

    var ready = [_]txpool.PooledTransaction{
        .{
            .sender = runtime_mod.DEFAULT_DEV_ACCOUNTS[0],
            .nonce = 0,
            .gas_limit = 21_000,
            .max_fee_per_gas = 1,
            .hash = [_]u8{0xaa} ** 32,
            .blob_sidecars = &first_sidecars,
        },
        .{
            .sender = runtime_mod.DEFAULT_DEV_ACCOUNTS[0],
            .nonce = 1,
            .gas_limit = 21_000,
            .max_fee_per_gas = 1,
            .hash = [_]u8{0xbb} ** 32,
            .blob_sidecars = &included_sidecars,
        },
    };
    const included_indexes = [_]usize{1};

    const sidecars = try includedBlobSidecarsFromReady(std.testing.allocator, &ready, &included_indexes);
    defer std.testing.allocator.free(sidecars);

    try std.testing.expectEqual(@as(usize, 2), sidecars.len);
    try std.testing.expectEqual(@as(u8, 0x22), sidecars[0].commitment[0]);
    try std.testing.expectEqual(@as(u8, 0x32), sidecars[1].commitment[0]);
}

fn engineExecutionPayloadValue(
    allocator: std.mem.Allocator,
    header: primitives.BlockHeader.BlockHeader,
    block_hash: [32]u8,
    raw_txs: []const primitives.BlockBody.TransactionData,
    withdrawals: []const primitives.BlockBody.Withdrawal,
    version: u8,
) !std.json.Value {
    var payload = std.json.ObjectMap.init(allocator);
    errdefer {
        var value = std.json.Value{ .object = payload };
        deinitJsonValue(allocator, &value);
    }

    try putOwnedJson(&payload, allocator, "parentHash", try hexHash32(allocator, header.parent_hash));
    try putOwnedJson(&payload, allocator, "feeRecipient", try addressString(allocator, header.beneficiary));
    try putOwnedJson(&payload, allocator, "stateRoot", try hexHash32(allocator, header.state_root));
    try putOwnedJson(&payload, allocator, "receiptsRoot", try hexHash32(allocator, header.receipts_root));
    try putOwnedJson(&payload, allocator, "logsBloom", try hexBytes(allocator, &header.logs_bloom));
    try putOwnedJson(&payload, allocator, "prevRandao", try hexHash32(allocator, header.mix_hash));
    try putOwnedJson(&payload, allocator, "blockNumber", try hexQuantity(allocator, header.number));
    try putOwnedJson(&payload, allocator, "gasLimit", try hexQuantity(allocator, header.gas_limit));
    try putOwnedJson(&payload, allocator, "gasUsed", try hexQuantity(allocator, header.gas_used));
    try putOwnedJson(&payload, allocator, "timestamp", try hexQuantity(allocator, header.timestamp));
    try putOwnedJson(&payload, allocator, "extraData", try hexBytes(allocator, header.extra_data));
    try putOwnedJson(&payload, allocator, "baseFeePerGas", try hexU256(allocator, header.base_fee_per_gas orelse 0));
    try putOwnedJson(&payload, allocator, "blockHash", try hexHash32(allocator, block_hash));
    try putOwnedJson(&payload, allocator, "transactions", try rawTransactionArrayValue(allocator, raw_txs));
    if (version >= 2) {
        if (header.withdrawals_root != null) {
            try putOwnedJson(&payload, allocator, "withdrawals", try withdrawalsArrayValue(allocator, withdrawals));
        } else {
            try putOwnedJson(&payload, allocator, "withdrawals", .null);
        }
    }
    if (version >= 3) {
        try putOwnedJson(&payload, allocator, "blobGasUsed", try hexQuantity(allocator, header.blob_gas_used orelse 0));
        try putOwnedJson(&payload, allocator, "excessBlobGas", try hexQuantity(allocator, header.excess_blob_gas orelse 0));
    }
    if (version >= 6) {
        try putOwnedJson(&payload, allocator, "blockAccessList", emptyArrayValue(allocator));
    }
    return .{ .object = payload };
}

fn enginePayloadEnvelopeValue(
    allocator: std.mem.Allocator,
    payload: std.json.Value,
    block_value: u256,
    version: u8,
    blob_sidecars: []const tx_encoding.BlobSidecar,
    execution_requests: []const []const u8,
) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    errdefer {
        var value = std.json.Value{ .object = obj };
        deinitJsonValue(allocator, &value);
    }
    try putOwnedJson(&obj, allocator, "executionPayload", payload);
    try putOwnedJson(&obj, allocator, "blockValue", try hexU256(allocator, block_value));
    if (version >= 3) {
        try putOwnedJson(&obj, allocator, "blobsBundle", try blobsBundleValue(allocator, blob_sidecars));
        try putOwnedJson(&obj, allocator, "shouldOverrideBuilder", .{ .bool = false });
    }
    if (version >= 4) {
        try putOwnedJson(&obj, allocator, "executionRequests", try executionRequestsArrayValue(allocator, execution_requests));
    }
    return .{ .object = obj };
}

/// EIP-7685 request list as hex `type || request_data` strings.
fn executionRequestsArrayValue(allocator: std.mem.Allocator, requests: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer {
        for (array.items) |*item| deinitJsonValue(allocator, item);
        array.deinit();
    }
    try array.ensureTotalCapacity(requests.len);
    for (requests) |request| {
        array.appendAssumeCapacity(try hexBytes(allocator, request));
    }
    return .{ .array = array };
}

fn blobsBundleValue(
    allocator: std.mem.Allocator,
    sidecars: []const tx_encoding.BlobSidecar,
) !std.json.Value {
    var blobs_bundle = std.json.ObjectMap.init(allocator);
    errdefer {
        var value = std.json.Value{ .object = blobs_bundle };
        deinitJsonValue(allocator, &value);
    }
    try putOwnedJson(&blobs_bundle, allocator, "commitments", try blobSidecarArrayValue(allocator, sidecars, .commitments));
    try putOwnedJson(&blobs_bundle, allocator, "proofs", try blobSidecarArrayValue(allocator, sidecars, .proofs));
    try putOwnedJson(&blobs_bundle, allocator, "blobs", try blobSidecarArrayValue(allocator, sidecars, .blobs));
    return .{ .object = blobs_bundle };
}

const BlobSidecarArrayField = enum {
    commitments,
    proofs,
    blobs,
};

fn blobSidecarArrayValue(
    allocator: std.mem.Allocator,
    sidecars: []const tx_encoding.BlobSidecar,
    field: BlobSidecarArrayField,
) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer {
        for (array.items) |*item| deinitJsonValue(allocator, item);
        array.deinit();
    }
    for (sidecars) |*sidecar| {
        if (field == .proofs and sidecar.proofs == .cells) {
            try array.ensureUnusedCapacity(sidecar.proofs.cells.len);
            for (&sidecar.proofs.cells) |*proof| {
                array.appendAssumeCapacity(try hexBytes(allocator, proof));
            }
            continue;
        }
        const bytes: []const u8 = switch (field) {
            .commitments => sidecar.commitment[0..],
            .proofs => &sidecar.proofs.blob,
            .blobs => sidecar.blob[0..],
        };
        try array.ensureUnusedCapacity(1);
        array.appendAssumeCapacity(try hexBytes(allocator, bytes));
    }
    return .{ .array = array };
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
        const block = (try rt.blockchain.getBlockByNumber(number)) orelse break;
        try array.append(try enginePayloadBodyValue(allocator, block, include_block_access_list));
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

fn engineBlobsValue(
    allocator: std.mem.Allocator,
    rt: *runtime_mod.NodeRuntime,
    method_name: []const u8,
    params: ?std.json.Value,
) !std.json.Value {
    const hashes = try engineHashArrayItems(params);
    if (hashes.len > 128) return error.TooLargeRequest;
    if (std.mem.eql(u8, method_name, "engine_getBlobsV1") and rt.pendingHardfork().isAtLeast(.OSAKA)) {
        return error.UnsupportedFork;
    }

    const v2 = std.mem.eql(u8, method_name, "engine_getBlobsV2");
    const cells = v2 or std.mem.eql(u8, method_name, "engine_getBlobsV3");
    var array = std.json.Array.init(allocator);
    var transferred = false;
    defer if (!transferred) {
        for (array.items) |*item| deinitJsonValue(allocator, item);
        array.deinit();
    };
    try array.ensureTotalCapacity(hashes.len);
    for (hashes) |hash_value| {
        const hash = try rpc_parse.parseHash32Value(hash_value);
        if (findBlobSidecar(rt, hash, cells)) |sidecar| {
            array.appendAssumeCapacity(try blobAndProofValue(allocator, sidecar));
        } else if (v2) {
            return .null;
        } else {
            array.appendAssumeCapacity(.null);
        }
    }
    transferred = true;
    return .{ .array = array };
}

fn findBlobSidecar(
    rt: *runtime_mod.NodeRuntime,
    versioned_hash: [32]u8,
    cells: bool,
) ?*const tx_encoding.BlobSidecar {
    for (rt.pool.items()) |tx| {
        for (tx.blob_sidecars) |*sidecar| {
            if ((sidecar.proofs == .cells) != cells) continue;
            const candidate = primitives.Blob.commitmentToVersionedHash(sidecar.commitment);
            if (std.mem.eql(u8, &candidate.bytes, &versioned_hash)) return sidecar;
        }
    }
    return null;
}

fn blobAndProofValue(
    allocator: std.mem.Allocator,
    sidecar: *const tx_encoding.BlobSidecar,
) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    errdefer {
        var value = std.json.Value{ .object = obj };
        deinitJsonValue(allocator, &value);
    }
    try putOwnedJson(&obj, allocator, "blob", try hexBytes(allocator, sidecar.blob[0..]));
    if (sidecar.proofs == .cells) {
        try putOwnedJson(&obj, allocator, "proofs", try blobSidecarArrayValue(allocator, sidecar[0..1], .proofs));
    } else {
        try putOwnedJson(&obj, allocator, "proof", try hexBytes(allocator, &sidecar.proofs.blob));
    }
    return .{ .object = obj };
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
    const number = blockNumberFromTrustedSelector(rt, selector) catch |err| switch (err) {
        error.BlockUnavailable => return false,
        else => return error.InvalidParams,
    };
    return (try rt.blockchain.getBlockByNumber(number)) != null;
}

fn blockNumberFromTrustedSelector(rt: *const runtime_mod.NodeRuntime, selector: []const u8) !u64 {
    if (std.mem.eql(u8, selector, "latest") or std.mem.eql(u8, selector, "pending")) {
        return rt.head_block_number;
    }
    // `safe` and `finalized` resolve to the Engine API forkchoice heads.
    if (std.mem.eql(u8, selector, "safe")) return rt.engineSafeBlockNumber() orelse error.BlockUnavailable;
    if (std.mem.eql(u8, selector, "finalized")) return rt.engineFinalizedBlockNumber() orelse error.BlockUnavailable;
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
        defer rt.allocator.free(code);
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

fn parseFilterId(params: ?std.json.Value) !u64 {
    const items = try paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    return parseQuantityU64Json(items[0]);
}

fn createLogFilterValue(
    allocator: std.mem.Allocator,
    rt: *runtime_mod.NodeRuntime,
    params: ?std.json.Value,
) !std.json.Value {
    const parsed = try parseGetLogsParams(params);
    const filter_value = parsed.filter.value;
    const from_block_omitted = logFilterObjectField(filter_value, "fromBlock") == null;
    const to_block_omitted = logFilterObjectField(filter_value, "toBlock") == null;

    var filter = try validatedLogFilter(rt.allocator, rt, filter_value);
    var filter_owned = true;
    errdefer if (filter_owned) log_index_mod.deinitLogFilter(rt.allocator, &filter);

    const next_block_number = if (filter.block_hash != null)
        0
    else if (from_block_omitted)
        rt.head_block_number +| 1
    else
        filter.from_block orelse 0;

    const id = try rt.createLogFilterOwned(filter, next_block_number, to_block_omitted);
    filter_owned = false;
    return hexQuantity(allocator, id) catch |err| {
        _ = rt.removeRpcFilter(id);
        return err;
    };
}

fn getFilterChangesValue(
    allocator: std.mem.Allocator,
    rt: *runtime_mod.NodeRuntime,
    params: ?std.json.Value,
) !std.json.Value {
    const filter_id = try parseFilterId(params);
    const filter = rt.rpcFilter(filter_id) orelse {
        simulation.setSimulationRpcErrorStatic(-32000, "filter not found");
        return error.SimulationRpcError;
    };
    switch (filter.*) {
        .block => |*state| {
            const from = state.last_block_number +| 1;
            const to = rt.head_block_number;
            const result = try blockHashRangeValue(allocator, rt, from, to);
            state.last_block_number = to;
            return result;
        },
        .pending_transaction => |*state| {
            const events = rt.pendingTransactionFilterEventsSince(state.next_event_index);
            const result = try hashArrayFromBytesValue(allocator, events);
            state.next_event_index = rt.pending_transaction_filter_events.items.len;
            return result;
        },
        .log => |*state| {
            if (state.filter.block_hash != null) {
                if (state.block_hash_polled) return emptyArrayValue(allocator);
                var scratch = std.heap.ArenaAllocator.init(allocator);
                defer scratch.deinit();
                var ctx = blockQueryContext(rt);
                const result = try block_query_handlers.handleGetLogsFilterValue(
                    allocator,
                    scratch.allocator(),
                    &ctx,
                    state.filter,
                );
                state.block_hash_polled = true;
                return result;
            }

            const from = state.next_block_number;
            const to = if (state.to_block_omitted)
                rt.head_block_number
            else if (state.filter.to_block) |explicit_to|
                @min(explicit_to, rt.head_block_number)
            else
                rt.head_block_number;
            if (from > to) return emptyArrayValue(allocator);

            var filter_state = state.filter;
            filter_state.from_block = from;
            filter_state.to_block = to;

            var scratch = std.heap.ArenaAllocator.init(allocator);
            defer scratch.deinit();
            var ctx = blockQueryContext(rt);
            const result = try block_query_handlers.handleGetLogsFilterValue(
                allocator,
                scratch.allocator(),
                &ctx,
                filter_state,
            );
            state.next_block_number = to +| 1;
            return result;
        },
    }
}

fn getFilterLogsValue(
    allocator: std.mem.Allocator,
    rt: *runtime_mod.NodeRuntime,
    params: ?std.json.Value,
) !std.json.Value {
    const filter_id = try parseFilterId(params);
    const filter = rt.rpcFilter(filter_id) orelse return emptyArrayValue(allocator);
    switch (filter.*) {
        .block, .pending_transaction => return emptyArrayValue(allocator),
        .log => |*state| {
            var filter_state = state.filter;
            if (filter_state.block_hash == null and state.to_block_omitted) {
                filter_state.to_block = rt.head_block_number;
            }
            var scratch = std.heap.ArenaAllocator.init(allocator);
            defer scratch.deinit();
            var ctx = blockQueryContext(rt);
            return block_query_handlers.handleGetLogsFilterValue(
                allocator,
                scratch.allocator(),
                &ctx,
                filter_state,
            );
        },
    }
}

fn validatedLogFilter(
    allocator: std.mem.Allocator,
    rt: *runtime_mod.NodeRuntime,
    filter_value: std.json.Value,
) !log_index_mod.LogFilter {
    var ctx = blockQueryContext(rt);
    return block_query_handlers.rpcFilterToInternal(
        allocator,
        &ctx,
        .{ .value = filter_value },
    ) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidParams,
    };
}

fn logFilterObjectField(filter_value: std.json.Value, field_name: []const u8) ?std.json.Value {
    const object = switch (filter_value) {
        .object => |object| object,
        else => return null,
    };
    return object.get(field_name);
}

fn blockHashRangeValue(
    allocator: std.mem.Allocator,
    rt: *runtime_mod.NodeRuntime,
    from: u64,
    to: u64,
) !std.json.Value {
    var array = std.json.Array.init(allocator);
    if (from > to) return .{ .array = array };

    var number = from;
    while (number <= to) : (number += 1) {
        const hash = rt.blockchain.getCanonicalHash(number) orelse continue;
        try array.append(try hexHash32(allocator, hash));
    }
    return .{ .array = array };
}

fn hashArrayFromBytesValue(
    allocator: std.mem.Allocator,
    hashes: []const [32]u8,
) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (hashes) |hash| try array.append(try hexHash32(allocator, hash));
    return .{ .array = array };
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

fn powWorkValue(allocator: std.mem.Allocator) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer {
        for (array.items) |*item| {
            deinitJsonValue(allocator, item);
        }
        array.deinit();
    }

    try array.append(try zeroHashValue(allocator));
    try array.append(try zeroHashValue(allocator));
    try array.append(try zeroHashValue(allocator));
    return .{ .array = array };
}

fn zeroHashValue(allocator: std.mem.Allocator) !std.json.Value {
    return .{ .string = try allocator.dupe(u8, "0x0000000000000000000000000000000000000000000000000000000000000000") };
}

fn validateSubmitWorkParams(params: ?std.json.Value) !void {
    const items = try paramsArrayItems(params);
    if (items.len != 3) return error.InvalidParams;
    try validateHexStringLen(items[0], 18);
    try validateHash32Json(items[1]);
    try validateHash32Json(items[2]);
}

fn validateSubmitHashrateParams(params: ?std.json.Value) !void {
    const items = try paramsArrayItems(params);
    if (items.len != 2) return error.InvalidParams;
    try validateQuantityValue(items[0]);
    try validateHash32Json(items[1]);
}

fn isLightModeUnsupportedMethod(method_name: []const u8) bool {
    if (std.mem.eql(u8, method_name, "zevm_lightSyncStatus")) return false;
    return methodIs(method_name, &.{
        "web3_clientVersion",
        "web3_sha3",
        "rpc_modules",
        "net_version",
        "net_listening",
        "net_peerCount",
        "eth_gasPrice",
        "eth_maxPriorityFeePerGas",
        "eth_blobBaseFee",
        "eth_config",
        "eth_feeHistory",
        "eth_coinbase",
        "eth_accounts",
        "eth_mining",
        "eth_hashrate",
        "eth_getWork",
        "eth_submitWork",
        "eth_submitHashrate",
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
        "eth_getUncleByBlockHashAndIndex",
        "eth_getUncleByBlockNumberAndIndex",
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
        "zevm_setPrevRandao",
        "anvil_setPrevRandao",
        "hardhat_setPrevRandao",
        "zevm_setMinGasPrice",
        "anvil_setMinGasPrice",
        "hardhat_setMinGasPrice",
        "zevm_enableTraces",
        "anvil_enableTraces",
        "hardhat_setLoggingEnabled",
        "zevm_addCompilationResult",
        "hardhat_addCompilationResult",
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
        "rpc_modules",
        "net_version",
        "net_listening",
        "net_peerCount",
        "eth_gasPrice",
        "eth_maxPriorityFeePerGas",
        "eth_blobBaseFee",
        "eth_config",
        "eth_coinbase",
        "eth_accounts",
        "eth_mining",
        "eth_hashrate",
        "eth_getWork",
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
        "zevm_enableTraces",
        "anvil_enableTraces",
        "zevm_removeBlockTimestampInterval",
        "anvil_removeBlockTimestampInterval",
    })) {
        return validateNoParams(params);
    }
    if (std.mem.eql(u8, method_name, "hardhat_setLoggingEnabled")) {
        _ = try parseSingleBoolArg(params);
        return;
    }
    if (methodIs(method_name, &.{ "zevm_addCompilationResult", "hardhat_addCompilationResult" })) {
        try validateCompilationResultParams(params);
        return;
    }
    if (std.mem.eql(u8, method_name, "eth_submitWork")) {
        try validateSubmitWorkParams(params);
        return;
    }
    if (std.mem.eql(u8, method_name, "eth_submitHashrate")) {
        try validateSubmitHashrateParams(params);
        return;
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
    if (methodIs(method_name, &.{ "zevm_setPrevRandao", "anvil_setPrevRandao", "hardhat_setPrevRandao" })) {
        _ = try parseSingleHashArg(params);
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
    if (std.mem.eql(u8, method_name, "eth_getUncleByBlockNumberAndIndex")) {
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
    if (std.mem.eql(u8, method_name, "eth_getUncleByBlockHashAndIndex")) {
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

fn validateHexStringLen(value: std.json.Value, expected_len: usize) !void {
    const text = switch (value) {
        .string => |s| s,
        else => return error.InvalidParams,
    };
    try validateHexData(text);
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
        .value = try parseStorageSlotJson(items[2]),
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

fn validateCompilationResultParams(params: ?std.json.Value) !void {
    const items = try paramsArrayItems(params);
    if (items.len != 3) return error.InvalidParams;
    if (items[0] != .string) return error.InvalidParams;
    if (items[1] != .object) return error.InvalidParams;
    if (items[2] != .object) return error.InvalidParams;
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
    if (params == null) return .{ .count = 1, .interval_seconds = null };
    const items = try paramsArrayItems(params);
    if (items.len > 2) return error.InvalidParams;
    if (items.len == 0) {
        return .{
            .count = 1,
            .interval_seconds = null,
        };
    }

    const count = try parseQuantityU64Json(items[0]);
    if (count > MAX_MINE_BLOCKS) return error.InvalidParams;
    return .{
        .count = count,
        .interval_seconds = if (items.len == 2) try parseQuantityU64Json(items[1]) else null,
    };
}

/// Upper bound on blocks mined by one `*_mine` call; larger counts hold the
/// runtime lock for unbounded time.
pub const MAX_MINE_BLOCKS: u64 = 10_000;

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
    // Development-node APIs accept seconds as a JSON integer (viem/Anvil)
    // as well as a canonical hexadecimal quantity.
    return switch (items[0]) {
        .integer => |seconds| std.math.cast(u64, seconds) orelse error.InvalidParams,
        else => parseQuantityU64Json(items[0]),
    };
}

fn parseTimeControlQuantity(params: ?std.json.Value) !u64 {
    const items = try paramsArrayItems(params);
    if (items.len != 1) return error.InvalidParams;
    return switch (items[0]) {
        .integer => |v| if (v >= 0) @as(u64, @intCast(v)) else error.InvalidParams,
        else => parseQuantityU64Json(items[0]),
    };
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
        mining_coordinator.nextExcessBlobGasForChildWithConfig(rt.hardfork_config, parent_block.header, block_number, attrs.timestamp)
    else
        0;
    const blob_base_fee = blob_fee.blobBaseFeeAt(rt.hardfork_config, block_number, attrs.timestamp, excess_blob_gas);

    const from_pool = items[2] == .null;
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

    var replayed_parent_state: ?@TypeOf(rt.state) = null;
    defer if (replayed_parent_state) |*parent_state| parent_state.deinit();
    const head_hash = rt.blockchain.getCanonicalHash(rt.head_block_number);
    const parent_is_head = if (head_hash) |hash| std.mem.eql(u8, &parent_hash, &hash) else false;
    const build_state = if (parent_is_head) &rt.state else parent_state: {
        replayed_parent_state = rt.replayStateToBlockHash(parent_hash) catch |err| {
            if (err == error.OutOfMemory) return err;
            return error.BuildBlockFailed;
        };
        break :parent_state &replayed_parent_state.?;
    };

    try build_state.checkpoint();
    var reverted = false;
    defer if (!reverted) build_state.revert();

    var adapter = host_adapter.HostAdapter{ .state = build_state };
    var result = block_builder.buildBlockWithOptions(
        temp,
        build_state,
        adapter.hostInterface(),
        exec_txs.items,
        block_ctx,
        .{
            .fork = block_builder.hardforkFromEvm(hardfork),
            .hardfork_config = rt.hardfork_config,
            .withdrawals = attrs.withdrawals,
            .parent_beacon_block_root = if (hardfork.isAtLeast(.CANCUN)) attrs.parent_beacon_block_root else null,
            .parent_hash = parent_hash,
            .skip_invalid_transactions = from_pool,
        },
    ) catch blk: {
        if (!from_pool) return error.BuildBlockFailed;

        build_state.revert();
        reverted = true;
        raw_txs.clearRetainingCapacity();
        exec_txs.clearRetainingCapacity();

        try build_state.checkpoint();
        reverted = false;
        break :blk block_builder.buildBlockWithOptions(
            temp,
            build_state,
            adapter.hostInterface(),
            exec_txs.items,
            block_ctx,
            .{
                .fork = block_builder.hardforkFromEvm(hardfork),
                .hardfork_config = rt.hardfork_config,
                .withdrawals = attrs.withdrawals,
                .parent_beacon_block_root = if (hardfork.isAtLeast(.CANCUN)) attrs.parent_beacon_block_root else null,
                .parent_hash = parent_hash,
                .skip_invalid_transactions = true,
            },
        ) catch return error.BuildBlockFailed;
    };
    defer result.deinit(temp);

    build_state.revert();
    reverted = true;

    const included_raw_txs = try includedRawTransactions(temp, raw_txs.items, result.included_tx_indexes);
    const transactions_root = block_builder.computeRawTransactionsRoot(temp, included_raw_txs) catch return error.BuildBlockFailed;
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
        parent_hash,
        attrs,
        block_ctx,
        result,
        block_hash,
        included_raw_txs,
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
    const blob_versioned_hashes = tx_encoding.envelopeBlobVersionedHashBytes(allocator, decoded) catch return error.BuildBlockFailed;
    const authorization_list = tx_encoding.envelopeAuthorizationList(decoded);
    const envelope_access_list = tx_encoding.envelopeAccessList(decoded);
    const access_list = try allocator.alloc(primitives.AccessList.AccessListEntry, envelope_access_list.len);
    for (envelope_access_list, access_list) |entry, *out| {
        out.* = .{ .address = entry.address, .storage_keys = entry.storage_keys };
    }

    try raw_txs.append(allocator, .{ .raw = canonical.bytes });
    try exec_txs.append(allocator, .{
        .caller = sender,
        .tx = tx,
        .access_list = if (access_list.len == 0) null else access_list,
        .raw = canonical.bytes,
        .tx_hash = tx_encoding.transactionHash(canonical.bytes),
        .receipt_type = tx_encoding.envelopeReceiptType(decoded),
        .max_fee_per_gas = tx_encoding.envelopeMaxFeePerGas(decoded),
        .max_priority_fee_per_gas = tx_encoding.envelopeMaxPriorityFeePerGas(decoded),
        .authorization_list = if (authorization_list.len == 0) null else authorization_list,
        .blob_gas_used = blob_gas_used,
        .blob_gas_price = if (blob_gas_used != null) blob_base_fee else null,
        .max_fee_per_blob_gas = tx_encoding.envelopeMaxFeePerBlobGas(decoded),
        .blob_versioned_hashes = blob_versioned_hashes,
    });
}

fn testingBuildBlockResultValue(
    allocator: std.mem.Allocator,
    parent_hash: [32]u8,
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

    try putOwnedJson(&payload, allocator, "parentHash", try hexHash32(allocator, parent_hash));
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
    // `putOwnedJson` takes unconditional ownership and frees on error.
    payload_transferred = true;
    try putOwnedJson(&obj, allocator, "executionPayload", .{ .object = payload });
    try putOwnedJson(&obj, allocator, "blockValue", try hexU256(allocator, block_value));
    blobs_bundle_transferred = true;
    try putOwnedJson(&obj, allocator, "blobsBundle", .{ .object = blobs_bundle });
    try putOwnedJson(&obj, allocator, "executionRequests", try executionRequestsArrayValue(allocator, result.execution_requests));
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

fn parseGetUncleByBlockHashAndIndexParams(
    allocator: std.mem.Allocator,
    params: ?std.json.Value,
) !void {
    const items = try paramsArrayItems(params);
    if (items.len != 2) return error.InvalidParams;
    _ = try parseHashJson(allocator, items[0]);
    try validateQuantityValue(items[1]);
}

fn parseGetUncleByBlockNumberAndIndexParams(params: ?std.json.Value) !void {
    const items = try paramsArrayItems(params);
    if (items.len != 2) return error.InvalidParams;
    try validateTrustedBlockSelectorValue(items[0]);
    try validateQuantityValue(items[1]);
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

fn hexStringToBytes(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return rpc_parse.parseHexDataBytes(allocator, .{ .string = text });
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

    // Fully parse before the unjournaled storage wipe in
    // applyPreparedAccountState.
    var prepared = try prepareAccountState(allocator, address, account_obj);
    defer prepared.deinit(allocator);

    try rt.state.checkpoint();
    var committed = false;
    defer if (!committed) rt.state.revert();

    try applyPreparedAccountState(rt, &prepared);
    rt.state.commit();
    committed = true;
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

    // The hex payload bypasses the HTTP layer's JSON depth guard; enforce
    // the same bound before std.json recurses into it.
    if (!jsonNestingDepthWithin(bytes, MAX_LOAD_STATE_JSON_DEPTH)) return error.InvalidParams;

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

    // clearLocalState and clearAccountStorage bypass the journal, so a
    // checkpoint revert cannot undo them. Parse and validate every account
    // (address, balance, nonce, code bytes, storage) before wiping anything.
    const prepared = try allocator.alloc(PreparedAccountState, accounts.count());
    var prepared_len: usize = 0;
    defer {
        for (prepared[0..prepared_len]) |*account| account.deinit(allocator);
        allocator.free(prepared);
    }
    var iterator = accounts.iterator();
    while (iterator.next()) |entry| {
        const address = try parseAddressString(entry.key_ptr.*);
        const account_obj = switch (entry.value_ptr.*) {
            .object => |object| object,
            else => return error.InvalidParams,
        };
        prepared[prepared_len] = try prepareAccountState(allocator, address, account_obj);
        prepared_len += 1;
    }

    try rt.state.checkpoint();
    var committed = false;
    defer if (!committed) rt.state.revert();

    clearLocalState(rt);

    for (prepared[0..prepared_len]) |*account| {
        try applyPreparedAccountState(rt, account);
    }

    rt.state.commit();
    committed = true;
}

/// Matches the HTTP request JSON depth guard.
pub const MAX_LOAD_STATE_JSON_DEPTH: usize = 64;

/// Linear scan of `{`/`[` nesting outside JSON strings. Returns false once
/// depth exceeds `max_depth`. Malformed input is left for std.json to reject.
pub fn jsonNestingDepthWithin(bytes: []const u8, max_depth: usize) bool {
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    for (bytes) |byte| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
            continue;
        }
        switch (byte) {
            '"' => in_string = true,
            '{', '[' => {
                depth += 1;
                if (depth > max_depth) return false;
            },
            '}', ']' => depth -|= 1,
            else => {},
        }
    }
    return true;
}

/// An account fully parsed from `anvil_setAccount` / `anvil_loadState` JSON
/// so that applying it cannot fail on malformed input.
const PreparedAccountState = struct {
    address: primitives.Address,
    balance: u256,
    nonce: u64,
    code: []u8,
    storage_slots: []u256,
    storage_values: []u256,

    fn deinit(self: *PreparedAccountState, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.storage_slots);
        allocator.free(self.storage_values);
    }
};

fn prepareAccountState(
    allocator: std.mem.Allocator,
    address: primitives.Address,
    account_obj: std.json.ObjectMap,
) !PreparedAccountState {
    try validateAccountStateObject(account_obj);

    const balance = try parseU256Json(account_obj.get("balance").?);
    const nonce = try parseU64Json(account_obj.get("nonce").?);
    const code = switch (account_obj.get("code").?) {
        .string => |text| try hexStringToBytes(allocator, text),
        else => return error.InvalidParams,
    };
    errdefer allocator.free(code);
    const storage_obj = account_obj.get("storage").?.object;
    const storage_slots = try allocator.alloc(u256, storage_obj.count());
    errdefer allocator.free(storage_slots);
    const storage_values = try allocator.alloc(u256, storage_obj.count());
    errdefer allocator.free(storage_values);

    var storage_iterator = storage_obj.iterator();
    var index: usize = 0;
    while (storage_iterator.next()) |entry| : (index += 1) {
        storage_slots[index] = try parseBytes32StringAsU256(entry.key_ptr.*);
        storage_values[index] = try parseBytes32ValueAsU256(entry.value_ptr.*);
    }

    return .{
        .address = address,
        .balance = balance,
        .nonce = nonce,
        .code = code,
        .storage_slots = storage_slots,
        .storage_values = storage_values,
    };
}

fn applyPreparedAccountState(rt: *runtime_mod.NodeRuntime, account: *const PreparedAccountState) !void {
    try rt.setBalance(account.address, account.balance);
    try rt.setNonce(account.address, account.nonce);
    try rt.setCode(account.address, account.code);
    clearAccountStorage(rt, account.address);
    for (account.storage_slots, account.storage_values) |slot, value| {
        try rt.setStorage(account.address, slot, value);
    }
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
    try putOwnedJson(&obj, allocator, "forkFollow", .{ .bool = if (rt.fork_config) |fork| fork.follow else false });
    if (rt.fork_config) |fork| {
        try putOwnedJson(&obj, allocator, "forkUrl", .{ .string = try redactUrlAlloc(allocator, fork.url) });
        try putOwnedJson(&obj, allocator, "forkBlockNumber", if (fork.block_number) |number| try hexQuantity(allocator, number) else .null);
    } else {
        try putOwnedJson(&obj, allocator, "forkUrl", .null);
        try putOwnedJson(&obj, allocator, "forkBlockNumber", .null);
    }
    return .{ .object = obj };
}

/// EIP-7910 `eth_config` for the fork schedule of this node.
fn ethConfigValue(allocator: std.mem.Allocator, rt: *runtime_mod.NodeRuntime) !std.json.Value {
    const genesis = (try rt.blockchain.getBlockByNumber(0)) orelse return error.MissingGenesisBlock;
    return eth_config.ethConfigValue(allocator, rt.hardfork_config, .{
        .chain_id = rt.chain_id,
        .genesis_hash = genesis.hash,
        .genesis_timestamp = genesis.header.timestamp,
        .head_block_number = rt.head_block_number,
        .head_timestamp = rt.head_block_timestamp,
    });
}

/// `tevm_drainConsoleLogs`: returns captured Hardhat console.log calldata as
/// 0x-hex strings in FIFO order and clears the node buffer.
fn drainConsoleLogsValue(allocator: std.mem.Allocator, rt: *runtime_mod.NodeRuntime) !std.json.Value {
    var drained = rt.console_logs.drain();
    defer drained.deinit();

    var array = std.json.Array.init(allocator);
    errdefer {
        var value = std.json.Value{ .array = array };
        deinitJsonValue(allocator, &value);
    }
    try array.ensureTotalCapacity(drained.entries.items.len);
    for (drained.entries.items) |calldata| {
        array.appendAssumeCapacity(try hexBytes(allocator, calldata));
    }
    return .{ .array = array };
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
    try putOwnedJson(&obj, allocator, "follow", .{ .bool = if (rt.fork_config) |fork| fork.follow else false });
    if (rt.fork_config) |fork| {
        try putOwnedJson(&obj, allocator, "url", .{ .string = try redactUrlAlloc(allocator, fork.url) });
        try putOwnedJson(&obj, allocator, "blockNumber", if (fork.block_number) |number| try hexQuantity(allocator, number) else .null);
    } else {
        try putOwnedJson(&obj, allocator, "url", .null);
        try putOwnedJson(&obj, allocator, "blockNumber", .null);
    }
    return .{ .object = obj };
}

fn redactUrlAlloc(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    var buf: [256]u8 = undefined;
    const redacted = log.redactUrl(&buf, url);
    return allocator.dupe(u8, redacted);
}

fn intervalMiningSeconds(rt: *const runtime_mod.NodeRuntime) u64 {
    return switch (rt.mining_config) {
        .interval => |interval| interval.block_time,
        else => 0,
    };
}

pub fn deinitJsonValue(allocator: std.mem.Allocator, value: *std.json.Value) void {
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

fn matchFixtureResponse(
    allocator: std.mem.Allocator,
    cache: *const FixtureCache,
    method_name: []const u8,
    params: ?std.json.Value,
) !?std.json.Value {
    const response = (try cache.matchResponse(allocator, .{
        .jsonrpc = "2.0",
        .id = null,
        .method = method_name,
        .params = params,
    })) orelse return null;
    if (response.error_value) |err_info| {
        simulation.setSimulationRpcErrorStatic(err_info.code, err_info.message);
        return error.SimulationRpcError;
    }
    return response.result orelse .null;
}
