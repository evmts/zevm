const std = @import("std");
const c_bindings = @import("c_bindings");

extern fn zevm_abi_version() callconv(.c) u32;
extern fn zevm_version() callconv(.c) [*:0]const u8;
extern fn zevm_error_message(code: c_int) callconv(.c) [*:0]const u8;
extern fn zevm_light_network_name(network: c_int) callconv(.c) ?[*:0]const u8;
extern fn zevm_light_init(
    network: c_int,
    beacon_rpc_url: ?[*:0]const u8,
    execution_rpc_url: ?[*:0]const u8,
) callconv(.c) ?*anyopaque;
extern fn zevm_light_shutdown(opaque_ptr: ?*anyopaque) callconv(.c) void;
extern fn zevm_light_status(opaque_ptr: ?*anyopaque) callconv(.c) c_int;
extern fn zevm_light_last_error(opaque_ptr: ?*anyopaque) callconv(.c) ?[*:0]const u8;
extern fn zevm_light_get_balance(
    opaque_ptr: ?*anyopaque,
    address_hex: ?[*:0]const u8,
    block_number: u64,
    out_hex: ?[*]u8,
    out_len: ?*usize,
) callconv(.c) c_int;
extern fn zevm_light_get_transaction_count(
    opaque_ptr: ?*anyopaque,
    address_hex: ?[*:0]const u8,
    block_number: u64,
    out_count: ?*u64,
) callconv(.c) c_int;
extern fn zevm_light_get_code(
    opaque_ptr: ?*anyopaque,
    address_hex: ?[*:0]const u8,
    block_number: u64,
    out_buf: ?[*]u8,
    out_len: ?*usize,
) callconv(.c) c_int;
extern fn zevm_light_get_storage(
    opaque_ptr: ?*anyopaque,
    address_hex: ?[*:0]const u8,
    slot_hex: ?[*:0]const u8,
    block_number: u64,
    out_hex: ?[*]u8,
    out_len: ?*usize,
) callconv(.c) c_int;
extern fn zevm_node_create(config_json: ?[*:0]const u8) callconv(.c) ?*anyopaque;
extern fn zevm_node_destroy(node: ?*anyopaque) callconv(.c) void;
extern fn zevm_node_rpc(
    node: ?*anyopaque,
    request: ?[*]const u8,
    request_len: usize,
    response: ?*?[*]u8,
    response_len: ?*usize,
) callconv(.c) c_int;
extern fn zevm_node_free_response(response: ?[*]u8, response_len: usize) callconv(.c) void;

comptime {
    _ = c_bindings;
}

fn toCString(allocator: std.mem.Allocator, raw: []const u8) ![:0]u8 {
    // Strip interior NUL bytes so we construct a clean NUL-terminated C string from arbitrary bytes.
    var clean = try allocator.allocSentinel(u8, raw.len, 0);
    for (raw, 0..) |b, i| {
        clean[i] = if (b == 0) 'x' else b;
    }
    return clean;
}

fn fuzzCAbiLightAndMetadata(_: void, input: []const u8) anyerror!void {
    const allocator = std.testing.allocator;
    if (input.len > 4096) return;

    try std.testing.expectEqual(@as(u32, 1), zevm_abi_version());
    try std.testing.expect(std.mem.span(zevm_version()).len > 0);

    const code: c_int = if (input.len > 0) @as(c_int, @as(i8, @bitCast(input[0]))) else 0;
    try std.testing.expect(std.mem.span(zevm_error_message(code)).len > 0);
    const net_name = zevm_light_network_name(code);
    if (code >= 0 and code <= 2) {
        try std.testing.expect(net_name != null);
    } else {
        try std.testing.expect(net_name == null);
    }

    // Null handle guards must never crash.
    zevm_light_shutdown(null);
    try std.testing.expectEqual(@as(c_int, 0), zevm_light_status(null));
    try std.testing.expect(zevm_light_last_error(null) == null);

    const mid = input.len / 2;
    const s1 = try toCString(allocator, input[0..mid]);
    defer allocator.free(s1);
    const s2 = try toCString(allocator, input[mid..]);
    defer allocator.free(s2);

    const net_id: c_int = if (input.len > 1) @mod(@as(c_int, input[1]), 4) else 0;
    const handle = zevm_light_init(net_id, s1.ptr, s2.ptr);
    if (net_id >= 0 and net_id <= 2) {
        try std.testing.expect(handle != null);
        defer zevm_light_shutdown(handle);

        try std.testing.expectEqual(@as(c_int, 1), zevm_light_status(handle));
        try std.testing.expect(zevm_light_last_error(handle) != null);

        var out_buf: [80]u8 = undefined;
        var out_len: usize = out_buf.len;
        var out_count: u64 = 0;

        // Every read call on an unsynced handle with arbitrary address/slot strings must return
        // either ZEVM_ERR_INVALID_ARG (1) or ZEVM_ERR_NOT_SYNCED (2) without crashing.
        const r_bal = zevm_light_get_balance(handle, s1.ptr, 0, &out_buf, &out_len);
        try std.testing.expect(r_bal == 1 or r_bal == 2);

        const r_cnt = zevm_light_get_transaction_count(handle, s1.ptr, 0, &out_count);
        try std.testing.expect(r_cnt == 1 or r_cnt == 2);

        out_len = out_buf.len;
        const r_code = zevm_light_get_code(handle, s1.ptr, 0, &out_buf, &out_len);
        try std.testing.expect(r_code == 1 or r_code == 2);

        out_len = out_buf.len;
        const r_stor = zevm_light_get_storage(handle, s1.ptr, s2.ptr, 0, &out_buf, &out_len);
        try std.testing.expect(r_stor == 1 or r_stor == 2);

        // Null output pointer checks
        try std.testing.expectEqual(@as(c_int, 1), zevm_light_get_transaction_count(handle, s1.ptr, 0, null));
        try std.testing.expectEqual(@as(c_int, 1), zevm_light_get_code(handle, s1.ptr, 0, null, null));
    } else {
        try std.testing.expect(handle == null);
    }
}

test "fuzz: C ABI light client lifecycle, error paths, null pointers and string parsing" {
    try fuzzCAbiLightAndMetadata({}, "");
    try std.testing.fuzz({}, fuzzCAbiLightAndMetadata, .{ .corpus = &.{
        "\x00\x00http://127.0.0.1:5052http://127.0.0.1:8545",
        "\x01\x010x00000000000000000000000000000000000000010x01",
        "\x02\x020xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef0xffffffff",
        "\x05\x03invalid-network",
    } });
}

fn fuzzCAbiNodeRpc(_: void, input: []const u8) anyerror!void {
    const allocator = std.testing.allocator;
    if (input.len == 0 or input.len > 8192) return;

    // Test zevm_node_create with arbitrary JSON config on half the inputs.
    if (input[0] & 1 == 1) {
        const cfg = try toCString(allocator, input[1..]);
        defer allocator.free(cfg);
        if (zevm_node_create(cfg.ptr)) |node| {
            zevm_node_destroy(node);
        }
        return;
    }

    // Null argument guards
    zevm_node_destroy(null);
    zevm_node_free_response(null, 0);
    var resp_ptr: ?[*]u8 = null;
    var resp_len: usize = 0;
    try std.testing.expectEqual(@as(c_int, 1), zevm_node_rpc(null, input.ptr, input.len, &resp_ptr, &resp_len));

    const node = zevm_node_create(null) orelse return error.NodeCreateFailed;
    defer zevm_node_destroy(node);

    try std.testing.expectEqual(@as(c_int, 1), zevm_node_rpc(node, null, 0, &resp_ptr, &resp_len));
    try std.testing.expectEqual(@as(c_int, 1), zevm_node_rpc(node, input.ptr, input.len, null, &resp_len));
    try std.testing.expectEqual(@as(c_int, 1), zevm_node_rpc(node, input.ptr, input.len, &resp_ptr, null));

    const body = input[1..];
    const rc = zevm_node_rpc(node, body.ptr, body.len, &resp_ptr, &resp_len);
    if (rc == 0) {
        if (resp_ptr) |ptr| {
            defer zevm_node_free_response(ptr, resp_len);
            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, ptr[0..resp_len], .{});
            defer parsed.deinit();
            try std.testing.expect(parsed.value == .object or parsed.value == .array);
        }
    }
}

test "fuzz: C ABI zevm_node_create and zevm_node_rpc on arbitrary JSON configs and RPC payloads" {
    try std.testing.fuzz({}, fuzzCAbiNodeRpc, .{ .corpus = &.{
        "\x00{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_chainId\",\"params\":[]}",
        "\x00{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_blockNumber\",\"params\":[]}",
        "\x00{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"evm_mine\",\"params\":[]}",
        "\x00{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\"}",
        "\x00{malformed",
        "\x01{}",
        "\x01{\"chain_id\":1}",
        "\x01{\"chain_id\":99999999999999999999999}",
        "\x01not-json",
    } });
}
