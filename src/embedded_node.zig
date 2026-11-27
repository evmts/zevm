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
    const raw_json = if (config_json) |json| std.mem.span(json) else "{}";
    const parsed = std.json.parseFromSlice(Config, allocator, raw_json, .{}) catch return null;
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
    const result = rpc_server.handlePost(
        std.heap.c_allocator,
        input[0..request_len],
        &handlers,
    ) catch return ZEVM_ERR_INTERNAL;
    if (result) |bytes| {
        output.* = bytes.ptr;
        length.* = bytes.len;
    }
    return ZEVM_OK;
}

export fn zevm_node_free_response(response: ?[*]u8, response_len: usize) void {
    if (response) |bytes| std.heap.c_allocator.free(bytes[0..response_len]);
}

test "embedded_node create, eth_chainId RPC, invalid args, and destroy" {
    try std.testing.expectEqual(@as(?*node_runtime.NodeRuntime, null), zevm_node_create("{\"chain_id\":0}"));

    // Use a non-default chain ID (Sepolia 11155111 = 0xaa36a7) so the test
    // proves zevm_node_create actually honors config_json.
    const node = zevm_node_create("{\"chain_id\":11155111}") orelse return error.TestUnexpectedResult;
    defer zevm_node_destroy(node);

    var response_ptr: ?[*]u8 = null;
    var response_len: usize = 0;
    const req = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"eth_chainId\",\"params\":[]}";
    try std.testing.expectEqual(
        @as(c_int, ZEVM_ERR_INVALID_ARG),
        zevm_node_rpc(null, req.ptr, req.len, &response_ptr, &response_len),
    );
    try std.testing.expectEqual(
        @as(c_int, ZEVM_OK),
        zevm_node_rpc(node, req.ptr, req.len, &response_ptr, &response_len),
    );
    defer zevm_node_free_response(response_ptr, response_len);

    const body = (response_ptr orelse return error.TestUnexpectedResult)[0..response_len];
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 7), parsed.value.object.get("id").?.integer);
    try std.testing.expectEqualStrings("0xaa36a7", parsed.value.object.get("result").?.string);
}
