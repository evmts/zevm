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
        error.BuildBlockFailed => {
            return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, RuntimeErrorCode.BUILD_BLOCK_FAILED, "Block building failed");
        },
        error.ExecutionFailed => {
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

fn validateParamsForMethod(allocator: std.mem.Allocator, method_name: []const u8, params: ?std.json.Value) !void {
    _ = allocator;

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

fn isEngineNamespaceMethod(method_name: []const u8) bool {
    return std.mem.startsWith(u8, method_name, "engine_");
}

fn isLocallyHandledMethod(method_name: []const u8) bool {
    return std.mem.eql(u8, method_name, "web3_clientVersion") or
        std.mem.eql(u8, method_name, "web3_sha3") or
        std.mem.eql(u8, method_name, "rpc_modules") or
        std.mem.eql(u8, method_name, "net_version") or
        std.mem.eql(u8, method_name, "net_listening") or
        std.mem.eql(u8, method_name, "net_peerCount") or
        std.mem.eql(u8, method_name, "txpool_content") or
        std.mem.eql(u8, method_name, "txpool_contentFrom") or
        std.mem.eql(u8, method_name, "txpool_status") or
        std.mem.eql(u8, method_name, "txpool_inspect") or
        std.mem.eql(u8, method_name, "testing_buildBlockV1") or
        std.mem.eql(u8, method_name, "eth_getBlockAccessList") or
        std.mem.eql(u8, method_name, "eth_getStorageValues") or
        std.mem.eql(u8, method_name, "eth_mining") or
        std.mem.eql(u8, method_name, "eth_hashrate") or
        std.mem.eql(u8, method_name, "eth_getWork") or
        std.mem.eql(u8, method_name, "eth_submitWork") or
        std.mem.eql(u8, method_name, "eth_submitHashrate") or
        std.mem.eql(u8, method_name, "eth_protocolVersion") or
        std.mem.eql(u8, method_name, "eth_getUncleByBlockHashAndIndex") or
        std.mem.eql(u8, method_name, "eth_getUncleByBlockNumberAndIndex") or
        std.mem.eql(u8, method_name, "zevm_setBalance") or
        std.mem.eql(u8, method_name, "anvil_setBalance") or
        std.mem.eql(u8, method_name, "hardhat_setBalance") or
        std.mem.eql(u8, method_name, "zevm_getAccount") or
        std.mem.eql(u8, method_name, "zevm_setAccount") or
        std.mem.eql(u8, method_name, "zevm_dumpState") or
        std.mem.eql(u8, method_name, "anvil_dumpState") or
        std.mem.eql(u8, method_name, "zevm_loadState") or
        std.mem.eql(u8, method_name, "anvil_loadState") or
        std.mem.eql(u8, method_name, "zevm_deal") or
        std.mem.eql(u8, method_name, "anvil_deal") or
        std.mem.eql(u8, method_name, "zevm_addBalance") or
        std.mem.eql(u8, method_name, "anvil_addBalance") or
        std.mem.eql(u8, method_name, "zevm_setNonce") or
        std.mem.eql(u8, method_name, "anvil_setNonce") or
        std.mem.eql(u8, method_name, "hardhat_setNonce") or
        std.mem.eql(u8, method_name, "zevm_setCode") or
        std.mem.eql(u8, method_name, "anvil_setCode") or
        std.mem.eql(u8, method_name, "hardhat_setCode") or
        std.mem.eql(u8, method_name, "zevm_setStorageAt") or
        std.mem.eql(u8, method_name, "anvil_setStorageAt") or
        std.mem.eql(u8, method_name, "hardhat_setStorageAt") or
        std.mem.eql(u8, method_name, "zevm_dealErc20") or
        std.mem.eql(u8, method_name, "anvil_dealErc20") or
        std.mem.eql(u8, method_name, "zevm_setErc20Allowance") or
        std.mem.eql(u8, method_name, "anvil_setErc20Allowance") or
        std.mem.eql(u8, method_name, "zevm_setCoinbase") or
        std.mem.eql(u8, method_name, "anvil_setCoinbase") or
        std.mem.eql(u8, method_name, "hardhat_setCoinbase") or
        std.mem.eql(u8, method_name, "zevm_setChainId") or
        std.mem.eql(u8, method_name, "anvil_setChainId") or
        std.mem.eql(u8, method_name, "zevm_setBlockGasLimit") or
        std.mem.eql(u8, method_name, "anvil_setBlockGasLimit") or
        std.mem.eql(u8, method_name, "evm_setBlockGasLimit") or
        std.mem.eql(u8, method_name, "zevm_setNextBlockBaseFeePerGas") or
        std.mem.eql(u8, method_name, "anvil_setNextBlockBaseFeePerGas") or
        std.mem.eql(u8, method_name, "hardhat_setNextBlockBaseFeePerGas") or
        std.mem.eql(u8, method_name, "zevm_setMinGasPrice") or
        std.mem.eql(u8, method_name, "anvil_setMinGasPrice") or
        std.mem.eql(u8, method_name, "hardhat_setMinGasPrice") or
        std.mem.eql(u8, method_name, "zevm_impersonateAccount") or
        std.mem.eql(u8, method_name, "anvil_impersonateAccount") or
        std.mem.eql(u8, method_name, "hardhat_impersonateAccount") or
        std.mem.eql(u8, method_name, "zevm_stopImpersonatingAccount") or
        std.mem.eql(u8, method_name, "anvil_stopImpersonatingAccount") or
        std.mem.eql(u8, method_name, "hardhat_stopImpersonatingAccount") or
        std.mem.eql(u8, method_name, "zevm_autoImpersonateAccount") or
        std.mem.eql(u8, method_name, "anvil_autoImpersonateAccount") or
        std.mem.eql(u8, method_name, "zevm_increaseTime") or
        std.mem.eql(u8, method_name, "anvil_increaseTime") or
        std.mem.eql(u8, method_name, "evm_increaseTime") or
        std.mem.eql(u8, method_name, "zevm_setTime") or
        std.mem.eql(u8, method_name, "anvil_setTime") or
        std.mem.eql(u8, method_name, "zevm_setNextBlockTimestamp") or
        std.mem.eql(u8, method_name, "anvil_setNextBlockTimestamp") or
        std.mem.eql(u8, method_name, "evm_setNextBlockTimestamp") or
        std.mem.eql(u8, method_name, "zevm_setBlockTimestampInterval") or
        std.mem.eql(u8, method_name, "anvil_setBlockTimestampInterval") or
        std.mem.eql(u8, method_name, "zevm_removeBlockTimestampInterval") or
        std.mem.eql(u8, method_name, "anvil_removeBlockTimestampInterval") or
        std.mem.eql(u8, method_name, "zevm_snapshot") or
        std.mem.eql(u8, method_name, "anvil_snapshot") or
        std.mem.eql(u8, method_name, "evm_snapshot") or
        std.mem.eql(u8, method_name, "zevm_revert") or
        std.mem.eql(u8, method_name, "anvil_revert") or
        std.mem.eql(u8, method_name, "evm_revert") or
        std.mem.eql(u8, method_name, "zevm_mine") or
        std.mem.eql(u8, method_name, "anvil_mine") or
        std.mem.eql(u8, method_name, "evm_mine") or
        std.mem.eql(u8, method_name, "hardhat_mine") or
        std.mem.eql(u8, method_name, "zevm_mineDetailed") or
        std.mem.eql(u8, method_name, "anvil_mineDetailed") or
        std.mem.eql(u8, method_name, "zevm_dropTransaction") or
        std.mem.eql(u8, method_name, "anvil_dropTransaction") or
        std.mem.eql(u8, method_name, "hardhat_dropTransaction") or
        std.mem.eql(u8, method_name, "zevm_dropAllTransactions") or
        std.mem.eql(u8, method_name, "anvil_dropAllTransactions") or
        std.mem.eql(u8, method_name, "zevm_removePoolTransactions") or
        std.mem.eql(u8, method_name, "anvil_removePoolTransactions") or
        std.mem.eql(u8, method_name, "zevm_getAutomine") or
        std.mem.eql(u8, method_name, "anvil_getAutomine") or
        std.mem.eql(u8, method_name, "hardhat_getAutomine") or
        std.mem.eql(u8, method_name, "zevm_setAutomine") or
        std.mem.eql(u8, method_name, "anvil_setAutomine") or
        std.mem.eql(u8, method_name, "evm_setAutomine") or
        std.mem.eql(u8, method_name, "zevm_getIntervalMining") or
        std.mem.eql(u8, method_name, "anvil_getIntervalMining") or
        std.mem.eql(u8, method_name, "zevm_setIntervalMining") or
        std.mem.eql(u8, method_name, "anvil_setIntervalMining") or
        std.mem.eql(u8, method_name, "evm_setIntervalMining") or
        std.mem.eql(u8, method_name, "zevm_metadata") or
        std.mem.eql(u8, method_name, "anvil_metadata") or
        std.mem.eql(u8, method_name, "hardhat_metadata") or
        std.mem.eql(u8, method_name, "zevm_nodeInfo") or
        std.mem.eql(u8, method_name, "anvil_nodeInfo") or
        std.mem.eql(u8, method_name, "zevm_lightSyncStatus");
}

fn validateResetParams(params: ?std.json.Value) !void {
    if (params == null) return;
    const value = params.?;
    const items = switch (value) {
        .array => |array| array.items,
        else => return error.InvalidParams,
    };

    if (items.len == 0) return;
    if (items.len != 1) return error.InvalidParams;

    switch (items[0]) {
        .null => return,
        .object => |obj| {
            var has_url = false;
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, "url")) {
                    has_url = true;
                    if (entry.value_ptr.* != .string) return error.InvalidParams;
                    continue;
                }
                if (std.mem.eql(u8, entry.key_ptr.*, "blockNumber")) {
                    if (!isHexQuantity(entry.value_ptr.*)) return error.InvalidParams;
                    continue;
                }
                return error.InvalidParams;
            }
            if (!has_url) return error.InvalidParams;
            return;
        },
        else => return error.InvalidParams,
    }
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

fn isHexQuantity(value: std.json.Value) bool {
    const text = switch (value) {
        .string => |str| str,
        else => return false,
    };
    if (text.len < 3) return false;
    return text[0] == '0' and (text[1] == 'x' or text[1] == 'X');
}
