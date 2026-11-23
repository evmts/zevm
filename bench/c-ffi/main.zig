const std = @import("std");
const harness = @import("harness");

// Extern declarations matching include/zevm.h (linked via libzevm.a)
extern fn zevm_abi_version() callconv(.c) u32;
extern fn zevm_node_create(config_json: ?[*:0]const u8) callconv(.c) ?*anyopaque;
extern fn zevm_node_destroy(node: ?*anyopaque) callconv(.c) void;
extern fn zevm_node_rpc(
    node: ?*anyopaque,
    request_ptr: [*]const u8,
    request_len: usize,
    response_ptr_out: *?[*]u8,
    response_len_out: *usize,
) callconv(.c) c_int;
extern fn zevm_node_free_response(response: ?[*]u8, response_len: usize) callconv(.c) void;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cfg = try harness.parseArgs(allocator, "c-ffi");
    var runner = harness.Runner.init(allocator, cfg);
    defer runner.deinit();

    const node = zevm_node_create(null) orelse return error.NodeCreateFailed;
    defer zevm_node_destroy(node);

    const req_chain = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_chainId\",\"params\":[]}";
    const req_bal = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"eth_getBalance\",\"params\":[\"0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266\",\"latest\"]}";

    const Ctx = struct {
        node: *anyopaque,
        req: []const u8,
    };

    var c_ver = Ctx{ .node = node, .req = req_chain };
    try runner.run("c_ffi/abi_version", &c_ver, struct {
        fn f(_: *Ctx) !void {
            const v = zevm_abi_version();
            std.mem.doNotOptimizeAway(&v);
        }
    }.f, .{});

    var c_chain = Ctx{ .node = node, .req = req_chain };
    try runner.run("c_ffi/node_rpc_eth_chainId", &c_chain, struct {
        fn f(c: *Ctx) !void {
            var out_ptr: ?[*]u8 = null;
            var out_len: usize = 0;
            const rc = zevm_node_rpc(c.node, c.req.ptr, c.req.len, &out_ptr, &out_len);
            if (rc != 0) return error.RpcFailed;
            defer zevm_node_free_response(out_ptr, out_len);
            std.mem.doNotOptimizeAway(&out_len);
        }
    }.f, .{});

    var c_bal = Ctx{ .node = node, .req = req_bal };
    try runner.run("c_ffi/node_rpc_eth_getBalance", &c_bal, struct {
        fn f(c: *Ctx) !void {
            var out_ptr: ?[*]u8 = null;
            var out_len: usize = 0;
            const rc = zevm_node_rpc(c.node, c.req.ptr, c.req.len, &out_ptr, &out_len);
            if (rc != 0) return error.RpcFailed;
            defer zevm_node_free_response(out_ptr, out_len);
            std.mem.doNotOptimizeAway(&out_len);
        }
    }.f, .{});

    try runner.finish();
}
