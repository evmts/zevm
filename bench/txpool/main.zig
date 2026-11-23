const std = @import("std");
const primitives = @import("primitives");
const zevm = @import("zevm");
const harness = @import("harness");

fn makeAddress(seed: u64) primitives.Address {
    var addr = primitives.Address.ZERO;
    std.mem.writeInt(u64, addr.bytes[12..20], seed, .big);
    return addr;
}

fn makeTx(sender_id: u64, nonce: u64, gas_price: u256) zevm.txpool.PooledTransaction {
    var hash: [32]u8 = [_]u8{0} ** 32;
    std.mem.writeInt(u64, hash[0..8], sender_id, .big);
    std.mem.writeInt(u64, hash[8..16], nonce, .big);
    std.mem.writeInt(u64, hash[16..24], @truncate(gas_price), .big);
    return .{
        .sender = makeAddress(sender_id),
        .nonce = nonce,
        .gas_limit = 21_000,
        .max_fee_per_gas = gas_price,
        .max_priority_fee_per_gas = gas_price / 10,
        .hash = hash,
        .to = makeAddress(9999),
        .value = 1000,
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cfg = try harness.parseArgs(allocator, "txpool");
    var runner = harness.Runner.init(allocator, cfg);
    defer runner.deinit();

    // 1. Insert 250 transactions across 25 senders (10 nonces each)
    {
        const Ctx = struct { allocator: std.mem.Allocator };
        var ctx = Ctx{ .allocator = allocator };
        try runner.run("txpool/insert_250_multi_sender", &ctx, struct {
            fn f(c: *Ctx) !void {
                var pool = zevm.txpool.TransactionPool.init(c.allocator);
                defer pool.deinit();
                for (0..25) |s| {
                    for (0..10) |n| {
                        try pool.add(c.allocator, makeTx(s + 1, n, 20_000_000_000 + n));
                    }
                }
                std.mem.doNotOptimizeAway(&pool);
            }
        }.f, .{});
    }

    // 2. getReady & pendingCount on 200 txs (10 senders x 20 nonces)
    {
        var pool = zevm.txpool.TransactionPool.init(allocator);
        defer pool.deinit();
        for (0..10) |s| {
            for (0..20) |n| {
                try pool.add(allocator, makeTx(s + 1, n, 25_000_000_000));
            }
        }

        const Ctx = struct {
            pool: *zevm.txpool.TransactionPool,
            allocator: std.mem.Allocator,
        };
        var ctx = Ctx{ .pool = &pool, .allocator = allocator };

        try runner.run("txpool/pending_count_200", &ctx, struct {
            fn f(c: *Ctx) !void {
                const count = c.pool.pendingCount();
                std.mem.doNotOptimizeAway(&count);
            }
        }.f, .{});

        try runner.run("txpool/get_ready_200", &ctx, struct {
            fn f(c: *Ctx) !void {
                const ready = try c.pool.getReady(c.allocator);
                defer c.allocator.free(ready);
                std.mem.doNotOptimizeAway(&ready);
            }
        }.f, .{});

        try runner.run("txpool/pending_nonce_200", &ctx, struct {
            fn f(c: *Ctx) !void {
                const next = c.pool.pendingNonce(makeAddress(5), 0);
                std.mem.doNotOptimizeAway(&next);
            }
        }.f, .{});
    }

    // 3. getReady on 250 consecutive txs from a SINGLE sender (stress test for O(N^3)!)
    {
        var pool = zevm.txpool.TransactionPool.init(allocator);
        defer pool.deinit();
        for (0..250) |n| {
            try pool.add(allocator, makeTx(1, n, 25_000_000_000));
        }

        const Ctx = struct {
            pool: *zevm.txpool.TransactionPool,
            allocator: std.mem.Allocator,
        };
        var ctx = Ctx{ .pool = &pool, .allocator = allocator };

        try runner.run("txpool/get_ready_250_single_sender", &ctx, struct {
            fn f(c: *Ctx) !void {
                const ready = try c.pool.getReady(c.allocator);
                defer c.allocator.free(ready);
                std.mem.doNotOptimizeAway(&ready);
            }
        }.f, .{ .warmup_iters = 1 });
    }

    // 4. removeMined 50 of 250 transactions
    {
        var base_pool = zevm.txpool.TransactionPool.init(allocator);
        defer base_pool.deinit();
        var mined_hashes: [50][32]u8 = undefined;
        for (0..250) |i| {
            const tx = makeTx((i % 25) + 1, i / 25, 25_000_000_000);
            try base_pool.add(allocator, tx);
            if (i < 50) mined_hashes[i] = tx.hash;
        }

        const Ctx = struct {
            base: *const zevm.txpool.TransactionPool,
            hashes: []const [32]u8,
            allocator: std.mem.Allocator,
        };
        var ctx = Ctx{ .base = &base_pool, .hashes = &mined_hashes, .allocator = allocator };

        try runner.run("txpool/remove_mined_50_of_250", &ctx, struct {
            fn f(c: *Ctx) !void {
                var cloned = try c.base.clone(c.allocator);
                defer cloned.deinit();
                cloned.removeMined(c.hashes);
                std.mem.doNotOptimizeAway(&cloned);
            }
        }.f, .{});
    }

    // 5. Gas-price replacement in 250-tx pool
    {
        var pool = zevm.txpool.TransactionPool.init(allocator);
        defer pool.deinit();
        var target_hash: [32]u8 = undefined;
        for (0..250) |i| {
            const tx = makeTx((i % 25) + 1, i / 25, 20_000_000_000);
            if (i == 0) target_hash = tx.hash;
            try pool.add(allocator, tx);
        }

        const Ctx = struct {
            pool: *zevm.txpool.TransactionPool,
            allocator: std.mem.Allocator,
            price: u256 = 25_000_000_000,
            last_hash: [32]u8,
        };
        var ctx = Ctx{ .pool = &pool, .allocator = allocator, .last_hash = target_hash };

        try runner.run("txpool/replace_under_250_pool", &ctx, struct {
            fn f(c: *Ctx) !void {
                c.price += 100;
                if (c.price > 1_000_000_000_000_000) {
                    _ = c.pool.removeByHash(c.last_hash);
                    c.price = 25_000_000_000;
                }
                const tx = makeTx(1, 0, c.price);
                try c.pool.add(c.allocator, tx);
                c.last_hash = tx.hash;
            }
        }.f, .{});
    }

    try runner.finish();
}
