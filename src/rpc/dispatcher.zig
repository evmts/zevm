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

    return error.UnknownMethod;
}
