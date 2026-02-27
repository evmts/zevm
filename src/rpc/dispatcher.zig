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

fn validateParamsForTag(comptime MethodUnion: type, allocator: std.mem.Allocator, tag: std.meta.Tag(MethodUnion), params_value: std.json.Value) !void {
    inline for (std.meta.fields(MethodUnion)) |field| {
        if (tag == @field(std.meta.Tag(MethodUnion), field.name)) {
            _ = try @FieldType(field.type, "params").jsonParseFromValue(allocator, params_value, .{});
            return;
        }
    }

    return error.UnknownMethod;
}

fn validateParamsForMethod(allocator: std.mem.Allocator, method_name: []const u8, params: ?std.json.Value) !void {
    var arena_allocator = std.heap.ArenaAllocator.init(allocator);
    defer arena_allocator.deinit();

    const params_value = params orelse .null;

    if (jsonrpc.eth.EthMethod.fromMethodName(method_name)) |tag| {
        return validateParamsForTag(jsonrpc.eth.EthMethod, arena_allocator.allocator(), tag, params_value);
    } else |_| {}

    if (jsonrpc.debug.DebugMethod.fromMethodName(method_name)) |tag| {
        return validateParamsForTag(jsonrpc.debug.DebugMethod, arena_allocator.allocator(), tag, params_value);
    } else |_| {}

    if (jsonrpc.engine.EngineMethod.fromMethodName(method_name)) |tag| {
        return validateParamsForTag(jsonrpc.engine.EngineMethod, arena_allocator.allocator(), tag, params_value);
    } else |_| {}

    return error.UnknownMethod;
}
