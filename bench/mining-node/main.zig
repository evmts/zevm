const std = @import("std");
const primitives = @import("primitives");
const zevm = @import("zevm");
const harness = @import("harness");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cfg = try harness.parseArgs(allocator, "mining-node");
    zevm.log.init(.err);
    var runner = harness.Runner.init(allocator, cfg);
    defer runner.deinit();

    // 1. NodeRuntime cold init + deinit
    {
        const Ctx = struct { allocator: std.mem.Allocator };
        var ctx = Ctx{ .allocator = allocator };
        try runner.run("node_runtime/init_devnet", &ctx, struct {
            fn f(c: *Ctx) !void {
                var rt = try zevm.node_runtime.NodeRuntime.init(c.allocator, null);
                defer rt.deinit();
                std.mem.doNotOptimizeAway(&rt.head_block_number);
            }
        }.f, .{ .warmup_iters = 2 });
    }

    // 2. NodeRuntime state reads, mining empty blocks, and snapshot/revert
    {
        var rt = try zevm.node_runtime.NodeRuntime.init(allocator, null);
        defer rt.deinit();
        const acct0 = rt.managedAccountAddress(0);

        const Ctx = struct {
            rt: *zevm.node_runtime.NodeRuntime,
            acct: primitives.Address,
            acc: u256 = 0,
        };
        var ctx = Ctx{ .rt = &rt, .acct = acct0 };

        try runner.run("node_runtime/get_balance", &ctx, struct {
            fn f(c: *Ctx) !void {
                c.acc +%= try c.rt.getBalance(c.acct);
                std.mem.doNotOptimizeAway(&c.acc);
            }
        }.f, .{});

        try runner.run("node_runtime/snapshot_and_revert", &ctx, struct {
            fn f(c: *Ctx) !void {
                const snap_id = try c.rt.snapshot();
                try c.rt.setBalance(c.acct, 123_456);
                const ok = try c.rt.revertToSnapshot(snap_id);
                std.mem.doNotOptimizeAway(&ok);
            }
        }.f, .{ .warmup_iters = 2 });

        try runner.run("node_runtime/mine_1_empty_block", &ctx, struct {
            fn f(c: *Ctx) !void {
                try c.rt.mineBlocks(1, 12);
                std.mem.doNotOptimizeAway(&c.rt.head_block_number);
            }
        }.f, .{ .warmup_iters = 2 });
    }

    // 3. NodeRuntime mine 10 blocks with queued txs (using snapshot/revert per iter so state stays bounded)
    {
        var rt = try zevm.node_runtime.NodeRuntime.init(allocator, null);
        defer rt.deinit();
        try rt.setAutomine(false);

        const sender = rt.managedAccountAddress(0);
        const priv_key = rt.managedPrivateKey(sender).?;
        const to_addr = rt.managedAccountAddress(1);

        var txs: [10]zevm.txpool.PooledTransaction = undefined;
        var raw_bufs: [10][]u8 = undefined;
        defer for (raw_bufs) |b| allocator.free(b);

        for (0..10) |i| {
            const signed = try zevm.transaction_encoding.signLegacyTransaction(allocator, .{
                .nonce = i,
                .gas_price = 2_000_000_000,
                .gas_limit = 21_000,
                .to = to_addr,
                .value = 1_000,
                .data = &.{},
                .v = 0,
                .r = [_]u8{0} ** 32,
                .s = [_]u8{0} ** 32,
            }, priv_key, rt.chain_id);
            raw_bufs[i] = try zevm.transaction_encoding.encodeLegacyTransactionEnvelope(allocator, signed);
            txs[i] = .{
                .sender = sender,
                .nonce = i,
                .gas_limit = 21_000,
                .max_fee_per_gas = 2_000_000_000,
                .max_priority_fee_per_gas = 1_000_000_000,
                .hash = zevm.transaction_encoding.transactionHash(raw_bufs[i]),
                .to = to_addr,
                .value = 1_000,
                .raw = raw_bufs[i],
                .v = signed.v,
                .r = signed.r,
                .s = signed.s,
            };
        }

        const Ctx = struct {
            allocator: std.mem.Allocator,
            rt: *zevm.node_runtime.NodeRuntime,
            txs: []const zevm.txpool.PooledTransaction,
        };
        var ctx = Ctx{ .allocator = allocator, .rt = &rt, .txs = &txs };

        try runner.run("node_runtime/mine_block_10_txs_with_revert", &ctx, struct {
            fn f(c: *Ctx) !void {
                const snap = try c.rt.snapshot();
                for (c.txs) |tx| {
                    try c.rt.pool.add(c.allocator, tx);
                }
                try c.rt.mineBlocks(1, 12);
                _ = try c.rt.revertToSnapshot(snap);
            }
        }.f, .{ .gas_per_op = 210_000, .warmup_iters = 2 });
    }

    try runner.finish();
}
