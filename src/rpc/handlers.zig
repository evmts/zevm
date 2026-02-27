const std = @import("std");
const state_manager = @import("state-manager");
const blockchain = @import("blockchain");
const envelope = @import("envelope.zig");

pub const HandlerContext = struct {
    state_manager: *state_manager.StateManager,
    blockchain: *blockchain.Blockchain,
    chain_id: u64,
};

pub const HandlerResult = union(enum) {
    success: std.json.Value,
    rpc_error: struct {
        code: i32,
        message: []const u8,
    },
};

pub const DispatchHook = *const fn (
    allocator: std.mem.Allocator,
    context: *const HandlerContext,
    method_name: []const u8,
    params: ?std.json.Value,
    id: ?envelope.Id,
) anyerror!HandlerResult;

var dispatch_hook: ?DispatchHook = null;

pub fn setTestDispatchHook(hook: DispatchHook) void {
    dispatch_hook = hook;
}

pub fn clearTestDispatchHook() void {
    dispatch_hook = null;
}

pub fn dispatch(
    allocator: std.mem.Allocator,
    context: *const HandlerContext,
    method_name: []const u8,
    params: ?std.json.Value,
    id: ?envelope.Id,
) !HandlerResult {
    if (dispatch_hook) |hook| {
        return try hook(allocator, context, method_name, params, id);
    }

    return .{
        .rpc_error = .{
            .code = -32601,
            .message = "Method not found",
        },
    };
}
