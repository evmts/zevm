const std = @import("std");
const primitives = @import("primitives");
const state_manager = @import("state-manager");
const guillotine_mini = @import("guillotine_mini");
const zevm = @import("zevm");
const harness = @import("harness");

fn makeAddress(seed: u64) primitives.Address {
    var addr = primitives.Address.ZERO;
    std.mem.writeInt(u64, addr.bytes[12..20], seed, .big);
    return addr;
}

fn defaultBlockCtx(number: u64) guillotine_mini.BlockContext {
    return .{
        .chain_id = 1,
        .block_number = number,
        .block_timestamp = 1_760_000_000 + number * 12,
        .block_difficulty = 0,
        .block_prevrandao = 0x33,
        .block_coinbase = makeAddress(999),
        .block_gas_limit = 30_000_000,
        .block_base_fee = 1_000_000_000,
        .blob_base_fee = 1,
        .block_hashes = &.{},
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cfg = try harness.parseArgs(allocator, "block-builder");
    var runner = harness.Runner.init(allocator, cfg);
    defer runner.deinit();

    // 1. Empty block build
    {
        var sm = try state_manager.StateManager.init(allocator, null);
        defer sm.deinit();
        var adapter = zevm.host_adapter.HostAdapter{ .state = &sm };

        const Ctx = struct {
            allocator: std.mem.Allocator,
            sm: *state_manager.StateManager,
            adapter: *zevm.host_adapter.HostAdapter,
            block_num: u64 = 1,
        };
        var ctx = Ctx{ .allocator = allocator, .sm = &sm, .adapter = &adapter };

        try runner.run("block_builder/build_empty_block", &ctx, struct {
            fn f(c: *Ctx) !void {
                var res = try zevm.block_builder.buildBlock(
                    c.allocator,
                    c.sm,
                    c.adapter.hostInterface(),
                    &.{},
                    defaultBlockCtx(c.block_num),
                );
                defer res.deinit(c.allocator);
                c.block_num += 1;
                std.mem.doNotOptimizeAway(&res);
            }
        }.f, .{});
    }

    // 2. Build 10-tx and 50-tx ETH transfer blocks
    inline for (.{ .{ "block_builder/build_10_tx_block", 10 }, .{ "block_builder/build_50_tx_block", 50 } }) |case| {
        const name = case[0];
        const count = case[1];
        var sm = try state_manager.StateManager.init(allocator, null);
        defer sm.deinit();
        for (0..count) |i| {
            try sm.setBalance(makeAddress(i + 1), 1_000_000_000_000_000_000_000);
        }
        var adapter = zevm.host_adapter.HostAdapter{ .state = &sm };

        var txs: [count]zevm.tx_processor.ExecutionTx = undefined;
        for (0..count) |i| {
            txs[i] = .{
                .caller = makeAddress(i + 1),
                .tx = .{
                    .nonce = 0,
                    .gas_price = 2_000_000_000,
                    .gas_limit = 21_000,
                    .to = makeAddress(1000 + i),
                    .value = 1000,
                    .data = &.{},
                    .v = 27,
                    .r = [_]u8{1} ** 32,
                    .s = [_]u8{1} ** 32,
                },
            };
        }

        const Ctx = struct {
            allocator: std.mem.Allocator,
            sm: *state_manager.StateManager,
            adapter: *zevm.host_adapter.HostAdapter,
            txs: []zevm.tx_processor.ExecutionTx,
            block_num: u64 = 1,
        };
        var ctx = Ctx{
            .allocator = allocator,
            .sm = &sm,
            .adapter = &adapter,
            .txs = &txs,
        };

        try runner.run(name, &ctx, struct {
            fn f(c: *Ctx) !void {
                var res = try zevm.block_builder.buildBlock(
                    c.allocator,
                    c.sm,
                    c.adapter.hostInterface(),
                    c.txs,
                    defaultBlockCtx(c.block_num),
                );
                defer res.deinit(c.allocator);
                for (c.txs) |*item| item.tx.nonce += 1;
                c.block_num += 1;
                std.mem.doNotOptimizeAway(&res);
            }
        }.f, .{ .gas_per_op = count * 21_000, .warmup_iters = 2 });
    }

    // 3. computeTransactionsRoot, computeReceiptsRoot, aggregateLogsBloom (50 items)
    {
        var txs: [50]zevm.tx_processor.ExecutionTx = undefined;
        var receipts: [50]primitives.Receipt.Receipt = undefined;
        const topics = [_][32]u8{[_]u8{0xdd} ** 32};
        const log_data = [_]u8{0xee} ** 32;
        var logs_arr: [2]primitives.EventLog.EventLog = undefined;
        for (0..2) |j| {
            logs_arr[j] = .{
                .address = makeAddress(200 + j),
                .topics = &topics,
                .data = &log_data,
                .block_number = 1,
                .transaction_hash = [_]u8{@intCast(j)} ** 32,
                .transaction_index = 0,
                .log_index = @intCast(j),
                .removed = false,
            };
        }
        const sample_bloom = zevm.tx_processor.computeLogsBloom(&logs_arr);

        for (0..50) |i| {
            txs[i] = .{
                .caller = makeAddress(i + 1),
                .tx = .{
                    .nonce = i,
                    .gas_price = 2_000_000_000,
                    .gas_limit = 21_000,
                    .to = makeAddress(1000 + i),
                    .value = 1000,
                    .data = &.{},
                    .v = 27,
                    .r = [_]u8{1} ** 32,
                    .s = [_]u8{1} ** 32,
                },
            };
            receipts[i] = .{
                .transaction_hash = [_]u8{@intCast(i)} ** 32,
                .transaction_index = @intCast(i),
                .block_hash = [_]u8{0xaa} ** 32,
                .block_number = 1,
                .sender = makeAddress(i + 1),
                .to = makeAddress(1000 + i),
                .cumulative_gas_used = (i + 1) * 21_000,
                .gas_used = 21_000,
                .contract_address = null,
                .logs = &logs_arr,
                .logs_bloom = sample_bloom,
                .status = .{ .success = true, .gas_used = 21_000 },
                .root = null,
                .effective_gas_price = 2_000_000_000,
                .type = .eip1559,
                .blob_gas_used = null,
                .blob_gas_price = null,
            };
        }

        const Ctx = struct {
            allocator: std.mem.Allocator,
            txs: []const zevm.tx_processor.ExecutionTx,
            receipts: []const primitives.Receipt.Receipt,
        };
        var ctx = Ctx{ .allocator = allocator, .txs = &txs, .receipts = &receipts };

        try runner.run("block_builder/compute_txs_root_50", &ctx, struct {
            fn f(c: *Ctx) !void {
                const root = try zevm.block_builder.computeTransactionsRoot(c.allocator, c.txs);
                std.mem.doNotOptimizeAway(&root);
            }
        }.f, .{});

        try runner.run("block_builder/compute_receipts_root_50", &ctx, struct {
            fn f(c: *Ctx) !void {
                const root = try zevm.block_builder.computeReceiptsRoot(c.allocator, c.receipts);
                std.mem.doNotOptimizeAway(&root);
            }
        }.f, .{});

        try runner.run("block_builder/aggregate_logs_bloom_50", &ctx, struct {
            fn f(c: *Ctx) !void {
                const bloom = zevm.block_builder.aggregateLogsBloom(c.receipts);
                std.mem.doNotOptimizeAway(&bloom);
            }
        }.f, .{});
    }

    // 4. computeStateRoot on 64 populated accounts (with storage)
    {
        var sm = try state_manager.StateManager.init(allocator, null);
        defer sm.deinit();
        for (0..64) |i| {
            const addr = makeAddress(500 + i);
            try sm.setBalance(addr, (i + 1) * 1_000_000);
            try sm.setNonce(addr, i);
            if (i % 4 == 0) {
                for (0..8) |slot| {
                    try sm.setStorage(addr, slot + 1, (i + 1) * (slot + 1));
                }
            }
        }

        const Ctx = struct {
            allocator: std.mem.Allocator,
            sm: *state_manager.StateManager,
        };
        var ctx = Ctx{ .allocator = allocator, .sm = &sm };

        try runner.run("block_builder/compute_state_root_64", &ctx, struct {
            fn f(c: *Ctx) !void {
                const root = try zevm.block_builder.computeStateRoot(c.allocator, c.sm);
                std.mem.doNotOptimizeAway(&root);
            }
        }.f, .{});
    }

    try runner.finish();
}
