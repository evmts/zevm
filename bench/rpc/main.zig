const std = @import("std");
const jsonrpc = @import("jsonrpc");
const zevm = @import("zevm");
const harness = @import("harness");

fn dispatchJson(
    allocator: std.mem.Allocator,
    handlers: *const zevm.rpc.dispatcher.HandlerRegistry,
    body: []const u8,
) !void {
    var resp = try zevm.rpc.server.handleHttpRequestForTest(allocator, .POST, body, handlers);
    defer if (resp.body) |b| allocator.free(b);
    std.mem.doNotOptimizeAway(&resp.status);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cfg = try harness.parseArgs(allocator, "rpc");
    zevm.log.init(.err);
    var runner = harness.Runner.init(allocator, cfg);
    defer runner.deinit();

    // 1. rpc.parse microbenchmarks
    {
        const qty = "0x123456789abcdef";
        const addr = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
        const hash = "0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

        const Ctx = struct {
            qty: []const u8,
            addr: []const u8,
            hash: []const u8,
            acc: u64 = 0,
        };
        var ctx = Ctx{ .qty = qty, .addr = addr, .hash = hash };

        try runner.run("rpc/parse_quantity_u64", &ctx, struct {
            fn f(c: *Ctx) !void {
                c.acc +%= try zevm.rpc.parse.parseQuantityString(u64, c.qty);
                std.mem.doNotOptimizeAway(&c.acc);
            }
        }.f, .{});

        try runner.run("rpc/parse_address", &ctx, struct {
            fn f(c: *Ctx) !void {
                const a = try zevm.rpc.parse.parseAddressString(c.addr);
                std.mem.doNotOptimizeAway(&a);
            }
        }.f, .{});

        try runner.run("rpc/parse_hash32", &ctx, struct {
            fn f(c: *Ctx) !void {
                const h = try zevm.rpc.parse.parseHash32String(c.hash);
                std.mem.doNotOptimizeAway(&h);
            }
        }.f, .{});
    }

    // 2. Full NodeRuntime + RPC dispatcher + HTTP server framing benchmarks
    {
        var rt = try zevm.node_runtime.NodeRuntime.init(allocator, null);
        defer rt.deinit();
        var handlers = zevm.rpc.dispatcher.HandlerRegistry{};
        zevm.rpc.dispatch_wiring.install(&handlers, &rt);

        // Deploy a simple contract (returns 42) so eth_call / eth_estimateGas run real EVM
        const contract_addr = zevm.node_runtime.DEFAULT_DEV_ACCOUNTS[9];
        const return42_code = [_]u8{ 0x60, 0x2a, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
        try rt.setCode(contract_addr, &return42_code);
        try rt.mineBlocks(5, 12);

        const req_chain_id = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_chainId\",\"params\":[]}";
        const req_block_num = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"eth_blockNumber\",\"params\":[]}";
        const req_balance = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"eth_getBalance\",\"params\":[\"0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266\",\"latest\"]}";
        const req_block = "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"eth_getBlockByNumber\",\"params\":[\"latest\",true]}";
        const req_call = "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"eth_call\",\"params\":[{\"to\":\"0xa0Ee7A142d267C1f36714E4a8F75612F20a79720\",\"data\":\"0x\"},\"latest\"]}";
        const req_estimate = "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"eth_estimateGas\",\"params\":[{\"from\":\"0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266\",\"to\":\"0xa0Ee7A142d267C1f36714E4a8F75612F20a79720\",\"data\":\"0x\"}]}";
        const req_logs = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"eth_getLogs\",\"params\":[{\"fromBlock\":\"0x0\",\"toBlock\":\"latest\"}]}";

        // Build 20-request JSON-RPC batch
        var batch_buf = std.ArrayList(u8){};
        defer batch_buf.deinit(allocator);
        try batch_buf.append(allocator, '[');
        for (0..20) |i| {
            if (i != 0) try batch_buf.append(allocator, ',');
            try batch_buf.appendSlice(allocator, req_balance);
        }
        try batch_buf.append(allocator, ']');

        const Ctx = struct {
            allocator: std.mem.Allocator,
            handlers: *const zevm.rpc.dispatcher.HandlerRegistry,
            body: []const u8,
        };

        var c_chain = Ctx{ .allocator = allocator, .handlers = &handlers, .body = req_chain_id };
        try runner.run("rpc/http_eth_chainId", &c_chain, struct {
            fn f(c: *Ctx) !void {
                try dispatchJson(c.allocator, c.handlers, c.body);
            }
        }.f, .{});

        var c_bn = Ctx{ .allocator = allocator, .handlers = &handlers, .body = req_block_num };
        try runner.run("rpc/http_eth_blockNumber", &c_bn, struct {
            fn f(c: *Ctx) !void {
                try dispatchJson(c.allocator, c.handlers, c.body);
            }
        }.f, .{});

        var c_bal = Ctx{ .allocator = allocator, .handlers = &handlers, .body = req_balance };
        try runner.run("rpc/http_eth_getBalance", &c_bal, struct {
            fn f(c: *Ctx) !void {
                try dispatchJson(c.allocator, c.handlers, c.body);
            }
        }.f, .{});

        var c_blk = Ctx{ .allocator = allocator, .handlers = &handlers, .body = req_block };
        try runner.run("rpc/http_eth_getBlockByNumber", &c_blk, struct {
            fn f(c: *Ctx) !void {
                try dispatchJson(c.allocator, c.handlers, c.body);
            }
        }.f, .{});

        var c_call = Ctx{ .allocator = allocator, .handlers = &handlers, .body = req_call };
        try runner.run("rpc/http_eth_call", &c_call, struct {
            fn f(c: *Ctx) !void {
                try dispatchJson(c.allocator, c.handlers, c.body);
            }
        }.f, .{});

        var c_est = Ctx{ .allocator = allocator, .handlers = &handlers, .body = req_estimate };
        try runner.run("rpc/http_eth_estimateGas", &c_est, struct {
            fn f(c: *Ctx) !void {
                try dispatchJson(c.allocator, c.handlers, c.body);
            }
        }.f, .{});

        var c_logs = Ctx{ .allocator = allocator, .handlers = &handlers, .body = req_logs };
        try runner.run("rpc/http_eth_getLogs", &c_logs, struct {
            fn f(c: *Ctx) !void {
                try dispatchJson(c.allocator, c.handlers, c.body);
            }
        }.f, .{});

        var c_batch = Ctx{ .allocator = allocator, .handlers = &handlers, .body = batch_buf.items };
        try runner.run("rpc/http_batch_20_eth_getBalance", &c_batch, struct {
            fn f(c: *Ctx) !void {
                try dispatchJson(c.allocator, c.handlers, c.body);
            }
        }.f, .{ .bytes_per_op = batch_buf.items.len });

        // Direct dispatcher (without HTTP JSON parse/serialize)
        var req = jsonrpc.envelope.RequestEnvelope{
            .jsonrpc = try allocator.dupe(u8, "2.0"),
            .id = .{ .integer = 1 },
            .method = try allocator.dupe(u8, "eth_chainId"),
            .params = null,
        };
        defer req.deinit(allocator);

        const DirectCtx = struct {
            allocator: std.mem.Allocator,
            handlers: *const zevm.rpc.dispatcher.HandlerRegistry,
            req: jsonrpc.envelope.RequestEnvelope,
        };
        var dctx = DirectCtx{ .allocator = allocator, .handlers = &handlers, .req = req };
        try runner.run("rpc/dispatch_direct_eth_chainId", &dctx, struct {
            fn f(c: *DirectCtx) !void {
                var resp = try zevm.rpc.dispatcher.dispatch(c.allocator, c.req, c.handlers);
                defer resp.deinit(c.allocator);
                std.mem.doNotOptimizeAway(&resp);
            }
        }.f, .{});
    }

    try runner.finish();
}
