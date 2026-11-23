const std = @import("std");
const primitives = @import("primitives");
const zevm = @import("zevm");
const harness = @import("harness");

fn makeAddress(seed: u64) primitives.Address {
    var addr = primitives.Address.ZERO;
    std.mem.writeInt(u64, addr.bytes[12..20], seed, .big);
    return addr;
}

fn makeHash(a: u64, b: u64) [32]u8 {
    var h = [_]u8{0} ** 32;
    std.mem.writeInt(u64, h[0..8], a, .big);
    std.mem.writeInt(u64, h[8..16], b, .big);
    return h;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cfg = try harness.parseArgs(allocator, "indexes");
    var runner = harness.Runner.init(allocator, cfg);
    defer runner.deinit();

    // Prepare 200 blocks x 10 receipts x 1 log = 2,000 logs & 2,000 receipts
    var receipt_index = zevm.receipt_index.ReceiptIndex.init(allocator);
    defer receipt_index.deinit(allocator);

    var log_index = zevm.log_index.LogIndex.init();
    defer log_index.deinit(allocator);

    const payload_data = [_]u8{0xab} ** 32;
    for (1..201) |blk| {
        const block_hash = makeHash(0xBEEF, blk);
        var receipts: [10]primitives.Receipt.Receipt = undefined;
        var logs_per_tx: [10][1]primitives.EventLog.EventLog = undefined;
        var topics_per_tx: [10][2][32]u8 = undefined;
        for (0..10) |ti| {
            topics_per_tx[ti] = .{
                makeHash(0xAAAA, (blk + ti) % 16),
                makeHash(0xBBBB, (blk * 7 + ti) % 64),
            };
            logs_per_tx[ti][0] = .{
                .address = makeAddress(((blk + ti) % 32) + 1),
                .topics = &topics_per_tx[ti],
                .data = &payload_data,
                .block_number = blk,
                .transaction_hash = makeHash(blk, ti),
                .transaction_index = @intCast(ti),
                .log_index = @intCast(ti),
                .removed = false,
            };
            receipts[ti] = .{
                .transaction_hash = makeHash(blk, ti),
                .transaction_index = @intCast(ti),
                .block_hash = block_hash,
                .block_number = blk,
                .sender = makeAddress(ti + 1),
                .to = makeAddress(100 + ti),
                .cumulative_gas_used = (ti + 1) * 21_000,
                .gas_used = 21_000,
                .contract_address = null,
                .logs = &logs_per_tx[ti],
                .logs_bloom = [_]u8{0} ** 256,
                .status = .{ .success = true, .gas_used = 21_000 },
                .root = null,
                .effective_gas_price = 1_000_000_000,
                .type = .eip1559,
                .blob_gas_used = null,
                .blob_gas_price = null,
            };
        }
        try receipt_index.putBlockReceipts(allocator, block_hash, &receipts);
        try log_index.appendBlockLogs(allocator, blk, block_hash, &receipts);
    }

    // Also add a sparse high block to test wide sparse block-range queries!
    const high_block_num: u64 = 100_000;
    {
        const block_hash = makeHash(0xBEEF, high_block_num);
        var topics = [_][32]u8{ makeHash(0xAAAA, 1), makeHash(0xBBBB, 1) };
        var logs = [_]primitives.EventLog.EventLog{.{
            .address = makeAddress(1),
            .topics = &topics,
            .data = &payload_data,
            .block_number = high_block_num,
            .transaction_hash = makeHash(high_block_num, 0),
            .transaction_index = 0,
            .log_index = 0,
            .removed = false,
        }};
        const receipts = [_]primitives.Receipt.Receipt{.{
            .transaction_hash = makeHash(high_block_num, 0),
            .transaction_index = 0,
            .block_hash = block_hash,
            .block_number = high_block_num,
            .sender = makeAddress(1),
            .to = makeAddress(2),
            .cumulative_gas_used = 21_000,
            .gas_used = 21_000,
            .contract_address = null,
            .logs = &logs,
            .logs_bloom = [_]u8{0} ** 256,
            .status = .{ .success = true, .gas_used = 21_000 },
            .root = null,
            .effective_gas_price = 1_000_000_000,
            .type = .eip1559,
            .blob_gas_used = null,
            .blob_gas_price = null,
        }};
        try log_index.appendBlockLogs(allocator, high_block_num, block_hash, &receipts);
    }

    const Ctx = struct {
        allocator: std.mem.Allocator,
        receipt_index: *const zevm.receipt_index.ReceiptIndex,
        log_index: *const zevm.log_index.LogIndex,
        tick: u64 = 0,
    };
    var ctx = Ctx{
        .allocator = allocator,
        .receipt_index = &receipt_index,
        .log_index = &log_index,
    };

    try runner.run("receipt_index/get_by_tx_hash_2k", &ctx, struct {
        fn f(c: *Ctx) !void {
            c.tick +%= 1;
            const blk = (c.tick % 200) + 1;
            const ti = c.tick % 10;
            const got = c.receipt_index.getByTxHash(makeHash(blk, ti));
            std.mem.doNotOptimizeAway(&got);
        }
    }.f, .{});

    try runner.run("receipt_index/get_by_block_hash_200", &ctx, struct {
        fn f(c: *Ctx) !void {
            c.tick +%= 1;
            const blk = (c.tick % 200) + 1;
            const got = c.receipt_index.getByBlockHash(makeHash(0xBEEF, blk));
            std.mem.doNotOptimizeAway(&got);
        }
    }.f, .{});

    try runner.run("log_index/query_by_block_hash_2k_logs", &ctx, struct {
        fn f(c: *Ctx) !void {
            c.tick +%= 1;
            const blk = (c.tick % 200) + 1;
            const res = try c.log_index.query(c.allocator, .{
                .block_hash = makeHash(0xBEEF, blk),
            }, high_block_num);
            defer c.allocator.free(res);
            std.mem.doNotOptimizeAway(&res);
        }
    }.f, .{});

    try runner.run("log_index/query_addr_topic_200_blocks", &ctx, struct {
        fn f(c: *Ctx) !void {
            const addrs = [_]primitives.Address.Address{makeAddress(5)};
            const t0 = [_][32]u8{makeHash(0xAAAA, 4)};
            const topics = [_]?[]const [32]u8{&t0};
            const res = try c.log_index.query(c.allocator, .{
                .from_block = 1,
                .to_block = 200,
                .addresses = &addrs,
                .topics = &topics,
            }, high_block_num);
            defer c.allocator.free(res);
            std.mem.doNotOptimizeAway(&res);
        }
    }.f, .{});

    try runner.run("log_index/query_sparse_range_100k_blocks", &ctx, struct {
        fn f(c: *Ctx) !void {
            const addrs = [_]primitives.Address.Address{makeAddress(1)};
            const res = try c.log_index.query(c.allocator, .{
                .from_block = 1,
                .to_block = high_block_num,
                .addresses = &addrs,
            }, high_block_num);
            defer c.allocator.free(res);
            std.mem.doNotOptimizeAway(&res);
        }
    }.f, .{});

    try runner.run("log_index/query_no_match_addr_200_blocks", &ctx, struct {
        fn f(c: *Ctx) !void {
            const addrs = [_]primitives.Address.Address{makeAddress(99999)};
            const res = try c.log_index.query(c.allocator, .{
                .from_block = 1,
                .to_block = 200,
                .addresses = &addrs,
            }, high_block_num);
            defer c.allocator.free(res);
            std.mem.doNotOptimizeAway(&res);
        }
    }.f, .{});

    try runner.finish();
}
