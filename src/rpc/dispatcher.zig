const std = @import("std");
const builtin = @import("builtin");
const jsonrpc = @import("jsonrpc");
const log = @import("../log.zig");

pub const HandlerRegistry = struct {
    on_method: ?*const fn (allocator: std.mem.Allocator, method_name: []const u8, params: ?std.json.Value) anyerror!std.json.Value = null,
};

pub const RuntimeErrorCode = struct {
    pub const MODE_UNSUPPORTED: i32 = -32010;
    pub const LIGHT_NOT_READY: i32 = -32011;
    pub const PROOF_VERIFY_FAILED: i32 = -32014;
    pub const MALFORMED_PROOF: i32 = -32015;
    pub const PRUNED_HISTORY: i32 = 4444;
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

    if (handlers.on_method == null) {
        return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, jsonrpc.envelope.ErrorCode.METHOD_NOT_FOUND, "Method not found");
    }

    const result = handlers.on_method.?(allocator, request.method, request.params) catch |err| switch (err) {
        error.MethodNotFound => {
            return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, jsonrpc.envelope.ErrorCode.METHOD_NOT_FOUND, "Method not found");
        },
        error.InvalidParams => {
            return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, jsonrpc.envelope.ErrorCode.INVALID_PARAMS, "Invalid params");
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
        error.PrunedHistory => {
            return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, RuntimeErrorCode.PRUNED_HISTORY, "Requested block is outside locally available state history");
        },
        else => {
            if (builtin.mode == .Debug or isTestBuild()) {
                log.warn(.rpc, "rpc internal error method={s} error={s}", .{ request.method, @errorName(err) });
            } else {
                log.err(.rpc, "rpc internal error method={s} error={s}", .{ request.method, @errorName(err) });
            }
            return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, jsonrpc.envelope.ErrorCode.INTERNAL_ERROR, "Internal error");
        },
    };

    return jsonrpc.envelope.ResponseEnvelope.makeSuccess(request.id, result);
}

fn isTestBuild() bool {
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

    if (jsonrpc.engine.EngineMethod.fromMethodName(method_name)) |_| {
        return;
    } else |_| {}

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

    if (isModeRoutedPrefix(method_name)) {
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

fn isLocallyHandledMethod(method_name: []const u8) bool {
    return std.mem.eql(u8, method_name, "web3_clientVersion") or
        std.mem.eql(u8, method_name, "web3_sha3") or
        std.mem.eql(u8, method_name, "net_version") or
        std.mem.eql(u8, method_name, "net_listening") or
        std.mem.eql(u8, method_name, "net_peerCount") or
        std.mem.eql(u8, method_name, "txpool_content") or
        std.mem.eql(u8, method_name, "txpool_status") or
        std.mem.eql(u8, method_name, "txpool_inspect") or
        std.mem.eql(u8, method_name, "eth_mining") or
        std.mem.eql(u8, method_name, "eth_protocolVersion") or
        std.mem.eql(u8, method_name, "zevm_setBalance") or
        std.mem.eql(u8, method_name, "anvil_setBalance") or
        std.mem.eql(u8, method_name, "hardhat_setBalance") or
        std.mem.eql(u8, method_name, "zevm_setNonce") or
        std.mem.eql(u8, method_name, "anvil_setNonce") or
        std.mem.eql(u8, method_name, "hardhat_setNonce") or
        std.mem.eql(u8, method_name, "zevm_setCode") or
        std.mem.eql(u8, method_name, "anvil_setCode") or
        std.mem.eql(u8, method_name, "hardhat_setCode") or
        std.mem.eql(u8, method_name, "zevm_setStorageAt") or
        std.mem.eql(u8, method_name, "anvil_setStorageAt") or
        std.mem.eql(u8, method_name, "hardhat_setStorageAt") or
        std.mem.eql(u8, method_name, "zevm_setERC20Balance") or
        std.mem.eql(u8, method_name, "anvil_setERC20Balance") or
        std.mem.eql(u8, method_name, "hardhat_setERC20Balance") or
        std.mem.eql(u8, method_name, "zevm_setERC20Allowance") or
        std.mem.eql(u8, method_name, "anvil_setERC20Allowance") or
        std.mem.eql(u8, method_name, "hardhat_setERC20Allowance") or
        std.mem.eql(u8, method_name, "zevm_setCoinbase") or
        std.mem.eql(u8, method_name, "anvil_setCoinbase") or
        std.mem.eql(u8, method_name, "hardhat_setCoinbase") or
        std.mem.eql(u8, method_name, "zevm_setBlockGasLimit") or
        std.mem.eql(u8, method_name, "anvil_setBlockGasLimit") or
        std.mem.eql(u8, method_name, "hardhat_setBlockGasLimit") or
        std.mem.eql(u8, method_name, "evm_setBlockGasLimit") or
        std.mem.eql(u8, method_name, "zevm_setNextBlockBaseFeePerGas") or
        std.mem.eql(u8, method_name, "anvil_setNextBlockBaseFeePerGas") or
        std.mem.eql(u8, method_name, "hardhat_setNextBlockBaseFeePerGas") or
        std.mem.eql(u8, method_name, "zevm_setBlobBaseFee") or
        std.mem.eql(u8, method_name, "anvil_setBlobBaseFee") or
        std.mem.eql(u8, method_name, "hardhat_setBlobBaseFee") or
        std.mem.eql(u8, method_name, "zevm_impersonateAccount") or
        std.mem.eql(u8, method_name, "anvil_impersonateAccount") or
        std.mem.eql(u8, method_name, "hardhat_impersonateAccount") or
        std.mem.eql(u8, method_name, "zevm_stopImpersonatingAccount") or
        std.mem.eql(u8, method_name, "anvil_stopImpersonatingAccount") or
        std.mem.eql(u8, method_name, "hardhat_stopImpersonatingAccount") or
        std.mem.eql(u8, method_name, "zevm_setAutoImpersonateAccount") or
        std.mem.eql(u8, method_name, "anvil_setAutoImpersonateAccount") or
        std.mem.eql(u8, method_name, "hardhat_setAutoImpersonateAccount") or
        std.mem.eql(u8, method_name, "zevm_autoImpersonateAccount") or
        std.mem.eql(u8, method_name, "anvil_autoImpersonateAccount") or
        std.mem.eql(u8, method_name, "zevm_increaseTime") or
        std.mem.eql(u8, method_name, "anvil_increaseTime") or
        std.mem.eql(u8, method_name, "evm_increaseTime") or
        std.mem.eql(u8, method_name, "zevm_setTime") or
        std.mem.eql(u8, method_name, "anvil_setTime") or
        std.mem.eql(u8, method_name, "evm_setTime") or
        std.mem.eql(u8, method_name, "zevm_setNextBlockTimestamp") or
        std.mem.eql(u8, method_name, "anvil_setNextBlockTimestamp") or
        std.mem.eql(u8, method_name, "evm_setNextBlockTimestamp") or
        std.mem.eql(u8, method_name, "hardhat_setNextBlockTimestamp") or
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
        std.mem.eql(u8, method_name, "zevm_setAutomine") or
        std.mem.eql(u8, method_name, "anvil_setAutomine") or
        std.mem.eql(u8, method_name, "evm_setAutomine") or
        std.mem.eql(u8, method_name, "zevm_setIntervalMining") or
        std.mem.eql(u8, method_name, "anvil_setIntervalMining") or
        std.mem.eql(u8, method_name, "evm_setIntervalMining") or
        std.mem.eql(u8, method_name, "zevm_lightSyncStatus");
}

fn isModeRoutedPrefix(method_name: []const u8) bool {
    return std.mem.startsWith(u8, method_name, "zevm_") or
        std.mem.startsWith(u8, method_name, "dev_") or
        std.mem.startsWith(u8, method_name, "anvil_") or
        std.mem.startsWith(u8, method_name, "hardhat_") or
        std.mem.startsWith(u8, method_name, "evm_");
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
