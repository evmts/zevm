const std = @import("std");
const ZEVM_OK = 0;
const ZEVM_ERR_INVALID_ARG = 1;
const ZEVM_ERR_INTERNAL = 7;

const node_runtime = @import("node/runtime.zig");
const rpc_dispatcher = @import("rpc/dispatcher.zig");
const rpc_wiring = @import("rpc/dispatch_wiring.zig");
const rpc_server = @import("rpc/server.zig");

export fn zevm_node_create(config_json: ?[*:0]const u8) ?*node_runtime.NodeRuntime {
    const allocator = std.heap.c_allocator;
    const Config = struct { chain_id: u64 = node_runtime.DEFAULT_CHAIN_ID };
    const parsed = std.json.parseFromSlice(Config, allocator, if (config_json) |json| std.mem.span(json) else "{}", .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value.chain_id == 0) return null;
    const node = allocator.create(node_runtime.NodeRuntime) catch return null;
    node.* = node_runtime.NodeRuntime.init(allocator, .{ .chain_id = parsed.value.chain_id }) catch {
        allocator.destroy(node);
        return null;
    };
    return node;
}

export fn zevm_node_destroy(node: ?*node_runtime.NodeRuntime) void {
    const runtime = node orelse return;
    runtime.deinit();
    std.heap.c_allocator.destroy(runtime);
}

export fn zevm_node_rpc(
    node: ?*node_runtime.NodeRuntime,
    request: ?[*]const u8,
    request_len: usize,
    response: ?*?[*]u8,
    response_len: ?*usize,
) c_int {
    const runtime = node orelse return ZEVM_ERR_INVALID_ARG;
    const input = request orelse return ZEVM_ERR_INVALID_ARG;
    const output = response orelse return ZEVM_ERR_INVALID_ARG;
    const length = response_len orelse return ZEVM_ERR_INVALID_ARG;
    output.* = null;
    length.* = 0;
    var handlers = rpc_dispatcher.HandlerRegistry{};
    rpc_wiring.install(&handlers, runtime);
    const result = rpc_server.handlePost(std.heap.c_allocator, input[0..request_len], &handlers) catch return ZEVM_ERR_INTERNAL;
    if (result) |bytes| {
        output.* = bytes.ptr;
        length.* = bytes.len;
    }
    return ZEVM_OK;
}

export fn zevm_node_free_response(response: ?[*]u8, response_len: usize) void {
    if (response) |bytes| std.heap.c_allocator.free(bytes[0..response_len]);
}
