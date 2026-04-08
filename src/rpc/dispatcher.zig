const std = @import("std");
const jsonrpc = @import("jsonrpc");

pub const HandlerRegistry = struct {
    context: ?*anyopaque = null,
    on_method_with_context: ?*const fn (context: *anyopaque, allocator: std.mem.Allocator, method_name: []const u8, params: ?std.json.Value) anyerror!std.json.Value = null,
    on_method: ?*const fn (allocator: std.mem.Allocator, method_name: []const u8, params: ?std.json.Value) anyerror!std.json.Value = null,
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

    if (handlers.on_method_with_context == null and handlers.on_method == null) {
        return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, jsonrpc.envelope.ErrorCode.METHOD_NOT_FOUND, "Method not found");
    }

    const result = if (handlers.on_method_with_context) |with_context| blk: {
        const context = handlers.context orelse {
            return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, jsonrpc.envelope.ErrorCode.INTERNAL_ERROR, "Internal error");
        };
        break :blk with_context(context, allocator, request.method, request.params) catch |err| switch (err) {
            error.MethodNotFound => return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, jsonrpc.envelope.ErrorCode.METHOD_NOT_FOUND, "Method not found"),
            error.InvalidParams => return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, jsonrpc.envelope.ErrorCode.INVALID_PARAMS, "Invalid params"),
            error.FilterNotFound => return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, jsonrpc.envelope.ErrorCode.SERVER_ERROR, "Filter not found"),
            else => return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, jsonrpc.envelope.ErrorCode.INTERNAL_ERROR, "Internal error"),
        };
    } else handlers.on_method.?(allocator, request.method, request.params) catch |err| switch (err) {
        error.MethodNotFound => return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, jsonrpc.envelope.ErrorCode.METHOD_NOT_FOUND, "Method not found"),
        error.InvalidParams => return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, jsonrpc.envelope.ErrorCode.INVALID_PARAMS, "Invalid params"),
        error.FilterNotFound => return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, jsonrpc.envelope.ErrorCode.SERVER_ERROR, "Filter not found"),
        else => return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, jsonrpc.envelope.ErrorCode.INTERNAL_ERROR, "Internal error"),
    };

    return jsonrpc.envelope.ResponseEnvelope.makeSuccess(request.id, result);
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

    if (jsonrpc.evm.EvmMethod.fromMethodName(method_name)) |_| {
        return;
    } else |_| {}

    if (jsonrpc.hardhat.HardhatMethod.fromMethodName(method_name)) |_| {
        return;
    } else |_| {}

    if (jsonrpc.anvil.AnvilMethod.fromMethodName(method_name)) |_| {
        return;
    } else |_| {}

    if (std.mem.eql(u8, method_name, "zevm_mine") or
        std.mem.eql(u8, method_name, "anvil_mine") or
        std.mem.eql(u8, method_name, "evm_mine") or
        std.mem.eql(u8, method_name, "hardhat_mine") or
        std.mem.eql(u8, method_name, "evm_increaseTime") or
        std.mem.eql(u8, method_name, "evm_setNextBlockTimestamp") or
        std.mem.eql(u8, method_name, "hardhat_setAutomine") or
        std.mem.eql(u8, method_name, "evm_setAutomine") or
        std.mem.eql(u8, method_name, "anvil_setAutomine") or
        std.mem.eql(u8, method_name, "hardhat_setIntervalMining") or
        std.mem.eql(u8, method_name, "evm_setIntervalMining") or
        std.mem.eql(u8, method_name, "anvil_setIntervalMining") or
        std.mem.eql(u8, method_name, "hardhat_setPrevRandao") or
        std.mem.eql(u8, method_name, "hardhat_impersonateAccount") or
        std.mem.eql(u8, method_name, "hardhat_stopImpersonatingAccount") or
        std.mem.eql(u8, method_name, "debug_traceCall") or
        std.mem.eql(u8, method_name, "debug_traceTransaction") or
        std.mem.eql(u8, method_name, "eth_subscribe") or
        std.mem.eql(u8, method_name, "eth_unsubscribe"))
    {
        return;
    }

    return error.UnknownMethod;
}
