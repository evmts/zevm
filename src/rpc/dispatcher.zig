const std = @import("std");
const jsonrpc = @import("jsonrpc");

pub const HandlerRegistry = struct {
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

    if (handlers.on_method == null) {
        return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, jsonrpc.envelope.ErrorCode.METHOD_NOT_FOUND, "Method not found");
    }

    const result = handlers.on_method.?(allocator, request.method, request.params) catch {
        return jsonrpc.envelope.ResponseEnvelope.makeError(request.id, jsonrpc.envelope.ErrorCode.INTERNAL_ERROR, "Internal error");
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

    if (isZevmResetMethod(method_name)) {
        try validateResetParams(params);
        return;
    }

    if (isZevmSetRpcUrlMethod(method_name)) {
        try validateSetRpcUrlParams(params);
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
