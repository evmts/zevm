const std = @import("std");
const builtin = @import("builtin");
const jsonrpc = @import("jsonrpc");
const log = @import("../log.zig");
const simulation = @import("handlers/simulation.zig");

pub const HandlerRegistry = struct {
    on_method: ?*const fn (allocator: std.mem.Allocator, method_name: []const u8, params: ?std.json.Value) anyerror!std.json.Value = null,
    context: ?*anyopaque = null,
    on_method_with_context: ?*const fn (context: ?*anyopaque, allocator: std.mem.Allocator, method_name: []const u8, params: ?std.json.Value) anyerror!std.json.Value = null,
    mode_name: ?*const fn (context: ?*anyopaque) []const u8 = null,
};

pub const RuntimeErrorCode = struct {
    pub const BUILD_BLOCK_FAILED: i32 = -32000;
    pub const MODE_UNSUPPORTED: i32 = -32010;
    pub const LIGHT_NOT_READY: i32 = -32011;
    pub const PROOF_VERIFY_FAILED: i32 = -32014;
    pub const MALFORMED_PROOF: i32 = -32015;
    pub const ENGINE_UNKNOWN_PAYLOAD: i32 = -38001;
    pub const ENGINE_INVALID_FORKCHOICE_STATE: i32 = -38002;
    pub const ENGINE_INVALID_PAYLOAD_ATTRIBUTES: i32 = -38003;
    pub const ENGINE_TOO_LARGE_REQUEST: i32 = -38004;
    pub const ENGINE_UNSUPPORTED_FORK: i32 = -38005;
};

pub fn dispatch(allocator: std.mem.Allocator, request: jsonrpc.envelope.RequestEnvelope, handlers: *const HandlerRegistry) !jsonrpc.envelope.ResponseEnvelope {
    validateParamsForMethod(allocator, request.method, request.params) catch |err| switch (err) {
        error.UnknownMethod => {
            return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, jsonrpc.envelope.ErrorCode.METHOD_NOT_FOUND, "Method not found");
        },
        else => {
            return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, jsonrpc.envelope.ErrorCode.INVALID_PARAMS, "Invalid params");
        },
    };

    if (handlers.on_method == null and handlers.on_method_with_context == null) {
        return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, jsonrpc.envelope.ErrorCode.METHOD_NOT_FOUND, "Method not found");
    }

    const result = if (handlers.on_method_with_context) |handler|
        handler(handlers.context, allocator, request.method, request.params)
    else
        handlers.on_method.?(allocator, request.method, request.params);

    const unwrapped_result = result catch |err| switch (err) {
        error.MethodNotFound => {
            return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, jsonrpc.envelope.ErrorCode.METHOD_NOT_FOUND, "Method not found");
        },
        error.InvalidParams => {
            return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, jsonrpc.envelope.ErrorCode.INVALID_PARAMS, "Invalid params");
        },
        error.TransactionGasLimitExceeded => {
            return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, -32000, "transaction gas limit exceeds Osaka cap (16777216)");
        },
        error.BuildBlockFailed => {
            return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, RuntimeErrorCode.BUILD_BLOCK_FAILED, "Block building failed");
        },
        error.ExecutionFailed => {
            if (simulation.takeLastSimulationRpcError()) |rpc_error| return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, rpc_error.code, rpc_error.message);
            var response = jsonrpc.envelope.ResponseEnvelope.makeError(request.id, 3, "execution reverted");
            if (simulation.takeLastExecutionErrorData()) |data| {
                response.error_value.?.data = .{ .string = data };
            }
            return response;
        },
        error.SimulationRpcError => {
            if (simulation.takeLastSimulationRpcError()) |rpc_error| {
                return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, rpc_error.code, rpc_error.message);
            }
            return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, jsonrpc.envelope.ErrorCode.INTERNAL_ERROR, "Internal error");
        },
        error.ModeUnsupported => {
            return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, RuntimeErrorCode.MODE_UNSUPPORTED, "Method unsupported in active mode");
        },
        error.LightNotReady => {
            return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, RuntimeErrorCode.LIGHT_NOT_READY, "Light mode not ready");
        },
        error.MalformedProof => {
            return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, RuntimeErrorCode.MALFORMED_PROOF, "Malformed proof payload");
        },
        error.ProofVerifyFailed => {
            return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, RuntimeErrorCode.PROOF_VERIFY_FAILED, "Proof verification failed");
        },
        error.UnknownPayload => {
            return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, RuntimeErrorCode.ENGINE_UNKNOWN_PAYLOAD, "Unknown payload");
        },
        error.InvalidForkchoiceState => {
            return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, RuntimeErrorCode.ENGINE_INVALID_FORKCHOICE_STATE, "Invalid forkchoice state");
        },
        error.InvalidPayloadAttributes => {
            return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, RuntimeErrorCode.ENGINE_INVALID_PAYLOAD_ATTRIBUTES, "Invalid payload attributes");
        },
        error.TooLargeRequest => {
            return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, RuntimeErrorCode.ENGINE_TOO_LARGE_REQUEST, "Too large request");
        },
        error.UnsupportedFork => {
            return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, RuntimeErrorCode.ENGINE_UNSUPPORTED_FORK, "Unsupported fork");
        },
        error.BlockUnavailable => {
            return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, RuntimeErrorCode.BUILD_BLOCK_FAILED, "Block not available");
        },
        error.GasPriceBelowBaseFee => {
            return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, RuntimeErrorCode.BUILD_BLOCK_FAILED, "Max fee per gas less than block base fee");
        },
        error.SenderNotEOA => {
            return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, RuntimeErrorCode.BUILD_BLOCK_FAILED, "Sender is not an EOA");
        },
        error.NonceTooHigh => {
            return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, RuntimeErrorCode.BUILD_BLOCK_FAILED, "Nonce too high");
        },
        error.TooManyFilters => {
            return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, RuntimeErrorCode.BUILD_BLOCK_FAILED, "Too many active filters");
        },
        else => {
            if (!isTestBuild()) {
                if (builtin.mode == .Debug) {
                    log.warn(.rpc, "rpc internal error method={s} error={s}", .{ request.method, @errorName(err) });
                } else {
                    log.err(.rpc, "rpc internal error method={s} error={s}", .{ request.method, @errorName(err) });
                }
            }
            return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, jsonrpc.envelope.ErrorCode.INTERNAL_ERROR, "Internal error");
        },
    };

    return jsonrpc.envelope.ResponseEnvelope.makeSuccess(request.id, unwrapped_result);
}

fn isTestBuild() bool {
    if (builtin.is_test) return true;
    const root = @import("root");
    return if (@hasDecl(root, "is_test")) root.is_test else false;
}

/// Tracing, filter lifecycle and subscriptions are outside the public RPC contract.
pub fn isDeferredMethod(method: []const u8) bool {
    const names = std.StaticStringMap(void).initComptime(.{
        .{ "eth_newBlockFilter", {} },
        .{ "eth_newPendingTransactionFilter", {} },
        .{ "eth_newFilter", {} },
        .{ "eth_getFilterChanges", {} },
        .{ "eth_getFilterLogs", {} },
        .{ "eth_uninstallFilter", {} },
        .{ "eth_subscribe", {} },
        .{ "eth_unsubscribe", {} },
    });
    return names.has(method) or std.mem.startsWith(u8, method, "debug_trace");
}

fn validateParamsForMethod(allocator: std.mem.Allocator, method_name: []const u8, params: ?std.json.Value) !void {
    _ = allocator;
    if (isDeferredMethod(method_name)) return error.UnknownMethod;

    if (jsonrpc.eth.EthMethod.fromMethodName(method_name)) |_| {
        if (std.mem.eql(u8, method_name, "eth_getBalance")) {
            const params_value = params orelse return error.InvalidParams;
            const items = switch (params_value) {
                .array => |array| array.items,
                else => return error.InvalidParams,
            };

            if (items.len < 2) {
                return error.InvalidParams;
            }
        }
        return;
    } else |_| {}

    if (jsonrpc.debug.DebugMethod.fromMethodName(method_name)) |_| {
        return;
    } else |_| {}

    if (isEngineNamespaceMethod(method_name)) {
        return;
    }

    if (isZevmResetMethod(method_name)) {
        try validateResetParams(params);
        return;
    }

    if (isZevmSetRpcUrlMethod(method_name)) {
        try validateSetRpcUrlParams(params);
        return;
    }

    if (isLocallyHandledMethod(method_name)) {
        return;
    }

    return error.UnknownMethod;
}

fn isZevmResetMethod(method_name: []const u8) bool {
    return std.mem.eql(u8, method_name, "zevm_reset") or
        std.mem.eql(u8, method_name, "anvil_reset") or
        std.mem.eql(u8, method_name, "hardhat_reset");
}

fn isZevmSetRpcUrlMethod(method_name: []const u8) bool {
    return std.mem.eql(u8, method_name, "zevm_setRpcUrl") or
        std.mem.eql(u8, method_name, "anvil_setRpcUrl");
}

pub fn isEngineNamespaceMethod(method_name: []const u8) bool {
    return std.mem.startsWith(u8, method_name, "engine_");
}

const locally_handled_methods = std.StaticStringMap(void).initComptime(.{
    .{ "web3_clientVersion", {} },
    .{ "web3_sha3", {} },
    .{ "rpc_modules", {} },
    .{ "net_version", {} },
    .{ "net_listening", {} },
    .{ "net_peerCount", {} },
    .{ "txpool_content", {} },
    .{ "txpool_contentFrom", {} },
    .{ "txpool_status", {} },
    .{ "txpool_inspect", {} },
    .{ "testing_buildBlockV1", {} },
    .{ "eth_getBlockAccessList", {} },
    .{ "eth_getStorageValues", {} },
    .{ "eth_mining", {} },
    .{ "eth_hashrate", {} },
    .{ "eth_getWork", {} },
    .{ "eth_submitWork", {} },
    .{ "eth_submitHashrate", {} },
    .{ "eth_protocolVersion", {} },
    .{ "eth_getUncleByBlockHashAndIndex", {} },
    .{ "eth_getUncleByBlockNumberAndIndex", {} },
    .{ "zevm_setBalance", {} },
    .{ "anvil_setBalance", {} },
    .{ "hardhat_setBalance", {} },
    .{ "zevm_getAccount", {} },
    .{ "zevm_setAccount", {} },
    .{ "zevm_dumpState", {} },
    .{ "anvil_dumpState", {} },
    .{ "zevm_loadState", {} },
    .{ "anvil_loadState", {} },
    .{ "zevm_deal", {} },
    .{ "anvil_deal", {} },
    .{ "zevm_addBalance", {} },
    .{ "anvil_addBalance", {} },
    .{ "zevm_setNonce", {} },
    .{ "anvil_setNonce", {} },
    .{ "hardhat_setNonce", {} },
    .{ "zevm_setCode", {} },
    .{ "anvil_setCode", {} },
    .{ "hardhat_setCode", {} },
    .{ "zevm_setStorageAt", {} },
    .{ "anvil_setStorageAt", {} },
    .{ "hardhat_setStorageAt", {} },
    .{ "zevm_dealErc20", {} },
    .{ "anvil_dealErc20", {} },
    .{ "zevm_setErc20Allowance", {} },
    .{ "anvil_setErc20Allowance", {} },
    .{ "zevm_setCoinbase", {} },
    .{ "anvil_setCoinbase", {} },
    .{ "hardhat_setCoinbase", {} },
    .{ "zevm_setChainId", {} },
    .{ "anvil_setChainId", {} },
    .{ "zevm_setBlockGasLimit", {} },
    .{ "anvil_setBlockGasLimit", {} },
    .{ "evm_setBlockGasLimit", {} },
    .{ "zevm_setNextBlockBaseFeePerGas", {} },
    .{ "anvil_setNextBlockBaseFeePerGas", {} },
    .{ "hardhat_setNextBlockBaseFeePerGas", {} },
    .{ "zevm_setPrevRandao", {} },
    .{ "anvil_setPrevRandao", {} },
    .{ "hardhat_setPrevRandao", {} },
    .{ "zevm_setMinGasPrice", {} },
    .{ "anvil_setMinGasPrice", {} },
    .{ "hardhat_setMinGasPrice", {} },
    .{ "zevm_enableTraces", {} },
    .{ "anvil_enableTraces", {} },
    .{ "hardhat_setLoggingEnabled", {} },
    .{ "zevm_addCompilationResult", {} },
    .{ "hardhat_addCompilationResult", {} },
    .{ "zevm_impersonateAccount", {} },
    .{ "anvil_impersonateAccount", {} },
    .{ "hardhat_impersonateAccount", {} },
    .{ "zevm_stopImpersonatingAccount", {} },
    .{ "anvil_stopImpersonatingAccount", {} },
    .{ "hardhat_stopImpersonatingAccount", {} },
    .{ "zevm_autoImpersonateAccount", {} },
    .{ "anvil_autoImpersonateAccount", {} },
    .{ "zevm_increaseTime", {} },
    .{ "anvil_increaseTime", {} },
    .{ "evm_increaseTime", {} },
    .{ "zevm_setTime", {} },
    .{ "anvil_setTime", {} },
    .{ "zevm_setNextBlockTimestamp", {} },
    .{ "anvil_setNextBlockTimestamp", {} },
    .{ "evm_setNextBlockTimestamp", {} },
    .{ "zevm_setBlockTimestampInterval", {} },
    .{ "anvil_setBlockTimestampInterval", {} },
    .{ "zevm_removeBlockTimestampInterval", {} },
    .{ "anvil_removeBlockTimestampInterval", {} },
    .{ "zevm_snapshot", {} },
    .{ "anvil_snapshot", {} },
    .{ "evm_snapshot", {} },
    .{ "zevm_revert", {} },
    .{ "anvil_revert", {} },
    .{ "evm_revert", {} },
    .{ "zevm_mine", {} },
    .{ "anvil_mine", {} },
    .{ "evm_mine", {} },
    .{ "hardhat_mine", {} },
    .{ "zevm_mineDetailed", {} },
    .{ "anvil_mineDetailed", {} },
    .{ "zevm_dropTransaction", {} },
    .{ "anvil_dropTransaction", {} },
    .{ "hardhat_dropTransaction", {} },
    .{ "zevm_dropAllTransactions", {} },
    .{ "anvil_dropAllTransactions", {} },
    .{ "zevm_removePoolTransactions", {} },
    .{ "anvil_removePoolTransactions", {} },
    .{ "zevm_getAutomine", {} },
    .{ "anvil_getAutomine", {} },
    .{ "hardhat_getAutomine", {} },
    .{ "zevm_setAutomine", {} },
    .{ "anvil_setAutomine", {} },
    .{ "evm_setAutomine", {} },
    .{ "zevm_getIntervalMining", {} },
    .{ "anvil_getIntervalMining", {} },
    .{ "zevm_setIntervalMining", {} },
    .{ "anvil_setIntervalMining", {} },
    .{ "evm_setIntervalMining", {} },
    .{ "zevm_metadata", {} },
    .{ "anvil_metadata", {} },
    .{ "hardhat_metadata", {} },
    .{ "zevm_nodeInfo", {} },
    .{ "anvil_nodeInfo", {} },
    .{ "zevm_lightSyncStatus", {} },
    .{ "eth_config", {} },
    .{ "tevm_drainConsoleLogs", {} },
});

fn isLocallyHandledMethod(method_name: []const u8) bool {
    return locally_handled_methods.has(method_name);
}

fn validateResetParams(params: ?std.json.Value) !void {
    // Validation and execution must accept the same native/Anvil wire forms.
    if (@import("trusted_fork_handlers.zig").parseResetMode(params) == null) return error.InvalidParams;
}

fn validateSetRpcUrlParams(params: ?std.json.Value) !void {
    const value = params orelse return error.InvalidParams;
    const items = switch (value) {
        .array => |array| array.items,
        else => return error.InvalidParams,
    };
    if (items.len != 1) return error.InvalidParams;
    if (items[0] != .string) return error.InvalidParams;
}
