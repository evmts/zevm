const std = @import("std");
const testing = std.testing;
const primitives = @import("primitives");
const log_index = @import("log_index.zig");

fn makeReceiptWithLogs(
    allocator: std.mem.Allocator,
    address: primitives.Address.Address,
    topic0: ?[32]u8,
    log_count: usize,
) !primitives.Receipt.Receipt {
    const logs = try allocator.alloc(primitives.EventLog.EventLog, log_count);
    for (logs, 0..) |*l, i| {
        if (topic0) |t| {
            const topics = try allocator.alloc([32]u8, 1);
            topics[0] = t;
            l.* = primitives.EventLog.EventLog{
                .address = address,
                .topics = topics,
                .data = try allocator.dupe(u8, &[_]u8{@intCast(i)}),
                .block_number = null,
                .transaction_hash = null,
                .transaction_index = null,
                .log_index = @intCast(i),
                .removed = false,
            };
        } else {
            l.* = primitives.EventLog.EventLog{
                .address = address,
                .topics = try allocator.alloc([32]u8, 0),
                .data = try allocator.dupe(u8, &[_]u8{@intCast(i)}),
                .block_number = null,
                .transaction_hash = null,
                .transaction_index = null,
                .log_index = @intCast(i),
                .removed = false,
            };
        }
    }

    var bloom: [256]u8 = undefined;
    @memset(&bloom, 0);
    var tx_hash: [32]u8 = undefined;
    @memset(&tx_hash, 0xaa);
    var block_hash: [32]u8 = undefined;
    @memset(&block_hash, 0xbb);

    return primitives.Receipt.Receipt{
        .transaction_hash = tx_hash,
        .transaction_index = 0,
        .block_hash = block_hash,
        .block_number = 0,
        .sender = primitives.Address.ZERO_ADDRESS,
        .to = null,
        .cumulative_gas_used = 21000,
        .gas_used = 21000,
        .contract_address = null,
        .logs = logs,
        .logs_bloom = bloom,
        .status = primitives.Receipt.TransactionStatus{ .success = true, .gas_used = 21000 },
        .root = null,
        .effective_gas_price = 1_000_000_000,
        .type = .legacy,
        .blob_gas_used = null,
        .blob_gas_price = null,
    };
}

test "log_index: append and retrieve all logs for a block" {
    const allocator = testing.allocator;
    var idx = log_index.LogIndex.init();
    defer idx.deinit(allocator);

    var block_hash: [32]u8 = undefined;
    @memset(&block_hash, 0x01);

    var receipt = try makeReceiptWithLogs(allocator, primitives.Address.ZERO_ADDRESS, null, 2);
    defer receipt.deinit(allocator);

    const receipts = [_]primitives.Receipt.Receipt{receipt};
    try idx.appendBlockLogs(allocator, 1, block_hash, &receipts);

    const result = try idx.query(allocator, .{ .from_block = 1, .to_block = 1 }, 1);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 2), result.len);
}

test "log_index: scan range returns logs in canonical order" {
    const allocator = testing.allocator;
    var idx = log_index.LogIndex.init();
    defer idx.deinit(allocator);

    var bh1: [32]u8 = undefined;
    @memset(&bh1, 0x01);
    var bh2: [32]u8 = undefined;
    @memset(&bh2, 0x02);

    var r1 = try makeReceiptWithLogs(allocator, primitives.Address.ZERO_ADDRESS, null, 1);
    defer r1.deinit(allocator);
    var r2 = try makeReceiptWithLogs(allocator, primitives.Address.ZERO_ADDRESS, null, 1);
    defer r2.deinit(allocator);

    try idx.appendBlockLogs(allocator, 1, bh1, &[_]primitives.Receipt.Receipt{r1});
    try idx.appendBlockLogs(allocator, 2, bh2, &[_]primitives.Receipt.Receipt{r2});

    const result = try idx.query(allocator, .{ .from_block = 1, .to_block = 2 }, 2);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expect(std.mem.eql(u8, &result[0].block_hash, &bh1));
    try testing.expect(std.mem.eql(u8, &result[1].block_hash, &bh2));
}

test "log_index: clone preserves logs independently" {
    const allocator = testing.allocator;
    var idx = log_index.LogIndex.init();

    var block_hash: [32]u8 = undefined;
    @memset(&block_hash, 0x42);
    var topic: [32]u8 = undefined;
    @memset(&topic, 0x99);

    var receipt = try makeReceiptWithLogs(allocator, primitives.Address.ZERO_ADDRESS, topic, 1);
    defer receipt.deinit(allocator);

    try idx.appendBlockLogs(allocator, 3, block_hash, &[_]primitives.Receipt.Receipt{receipt});

    var cloned = try idx.clone(allocator);
    defer cloned.deinit(allocator);
    idx.deinit(allocator);

    const topic_filter = [_][32]u8{topic};
    const topics = [_]?[]const [32]u8{&topic_filter};
    const result = try cloned.query(allocator, .{
        .from_block = 3,
        .to_block = 3,
        .topics = &topics,
    }, 3);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expect(std.mem.eql(u8, &result[0].block_hash, &block_hash));
    try testing.expectEqual(@as(u8, 0), result[0].log.data[0]);
}

test "log_index: filter by single address" {
    const allocator = testing.allocator;
    var idx = log_index.LogIndex.init();
    defer idx.deinit(allocator);

    var bh: [32]u8 = undefined;
    @memset(&bh, 0x01);

    const addr1 = primitives.Address{ .bytes = [_]u8{0x01} ** 20 };
    const addr2 = primitives.Address{ .bytes = [_]u8{0x02} ** 20 };

    var r1 = try makeReceiptWithLogs(allocator, addr1, null, 1);
    defer r1.deinit(allocator);
    var r2 = try makeReceiptWithLogs(allocator, addr2, null, 1);
    defer r2.deinit(allocator);

    try idx.appendBlockLogs(allocator, 1, bh, &[_]primitives.Receipt.Receipt{ r1, r2 });

    const addrs = [_]primitives.Address.Address{addr1};
    const result = try idx.query(allocator, .{
        .from_block = 1,
        .to_block = 1,
        .addresses = &addrs,
    }, 1);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expect(std.mem.eql(u8, &result[0].log.address.bytes, &addr1.bytes));
}

test "log_index: filter by address array (OR semantics)" {
    const allocator = testing.allocator;
    var idx = log_index.LogIndex.init();
    defer idx.deinit(allocator);

    var bh: [32]u8 = undefined;
    @memset(&bh, 0x01);

    const addr1 = primitives.Address{ .bytes = [_]u8{0x01} ** 20 };
    const addr2 = primitives.Address{ .bytes = [_]u8{0x02} ** 20 };
    const addr3 = primitives.Address{ .bytes = [_]u8{0x03} ** 20 };

    var r1 = try makeReceiptWithLogs(allocator, addr1, null, 1);
    defer r1.deinit(allocator);
    var r2 = try makeReceiptWithLogs(allocator, addr2, null, 1);
    defer r2.deinit(allocator);
    var r3 = try makeReceiptWithLogs(allocator, addr3, null, 1);
    defer r3.deinit(allocator);

    try idx.appendBlockLogs(allocator, 1, bh, &[_]primitives.Receipt.Receipt{ r1, r2, r3 });

    const addrs = [_]primitives.Address.Address{ addr1, addr3 };
    const result = try idx.query(allocator, .{
        .from_block = 1,
        .to_block = 1,
        .addresses = &addrs,
    }, 1);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 2), result.len);
}

test "log_index: filter by exact topic at position 0" {
    const allocator = testing.allocator;
    var idx = log_index.LogIndex.init();
    defer idx.deinit(allocator);

    var bh: [32]u8 = undefined;
    @memset(&bh, 0x01);

    var topic_a: [32]u8 = undefined;
    @memset(&topic_a, 0xaa);
    var topic_b: [32]u8 = undefined;
    @memset(&topic_b, 0xbb);

    var r1 = try makeReceiptWithLogs(allocator, primitives.Address.ZERO_ADDRESS, topic_a, 1);
    defer r1.deinit(allocator);
    var r2 = try makeReceiptWithLogs(allocator, primitives.Address.ZERO_ADDRESS, topic_b, 1);
    defer r2.deinit(allocator);

    try idx.appendBlockLogs(allocator, 1, bh, &[_]primitives.Receipt.Receipt{ r1, r2 });

    const topic_filter = [_][32]u8{topic_a};
    const topics = [_]?[]const [32]u8{&topic_filter};
    const result = try idx.query(allocator, .{
        .from_block = 1,
        .to_block = 1,
        .topics = &topics,
    }, 1);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expect(std.mem.eql(u8, &result[0].log.topics[0], &topic_a));
}

test "log_index: null topic is wildcard — matches any" {
    const allocator = testing.allocator;
    var idx = log_index.LogIndex.init();
    defer idx.deinit(allocator);

    var bh: [32]u8 = undefined;
    @memset(&bh, 0x01);

    var topic_a: [32]u8 = undefined;
    @memset(&topic_a, 0xaa);
    var topic_b: [32]u8 = undefined;
    @memset(&topic_b, 0xbb);

    var r1 = try makeReceiptWithLogs(allocator, primitives.Address.ZERO_ADDRESS, topic_a, 1);
    defer r1.deinit(allocator);
    var r2 = try makeReceiptWithLogs(allocator, primitives.Address.ZERO_ADDRESS, topic_b, 1);
    defer r2.deinit(allocator);

    try idx.appendBlockLogs(allocator, 1, bh, &[_]primitives.Receipt.Receipt{ r1, r2 });

    const topics = [_]?[]const [32]u8{null};
    const result = try idx.query(allocator, .{
        .from_block = 1,
        .to_block = 1,
        .topics = &topics,
    }, 1);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 2), result.len);
}

test "log_index: topic OR array at same position" {
    const allocator = testing.allocator;
    var idx = log_index.LogIndex.init();
    defer idx.deinit(allocator);

    var bh: [32]u8 = undefined;
    @memset(&bh, 0x01);

    var topic_a: [32]u8 = undefined;
    @memset(&topic_a, 0xaa);
    var topic_b: [32]u8 = undefined;
    @memset(&topic_b, 0xbb);
    var topic_c: [32]u8 = undefined;
    @memset(&topic_c, 0xcc);

    var r1 = try makeReceiptWithLogs(allocator, primitives.Address.ZERO_ADDRESS, topic_a, 1);
    defer r1.deinit(allocator);
    var r2 = try makeReceiptWithLogs(allocator, primitives.Address.ZERO_ADDRESS, topic_b, 1);
    defer r2.deinit(allocator);
    var r3 = try makeReceiptWithLogs(allocator, primitives.Address.ZERO_ADDRESS, topic_c, 1);
    defer r3.deinit(allocator);

    try idx.appendBlockLogs(allocator, 1, bh, &[_]primitives.Receipt.Receipt{ r1, r2, r3 });

    const topic_filter = [_][32]u8{ topic_a, topic_c };
    const topics = [_]?[]const [32]u8{&topic_filter};
    const result = try idx.query(allocator, .{
        .from_block = 1,
        .to_block = 1,
        .topics = &topics,
    }, 1);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 2), result.len);
}

test "log_index: blockHash-specific query returns only that block's logs" {
    const allocator = testing.allocator;
    var idx = log_index.LogIndex.init();
    defer idx.deinit(allocator);

    var bh1: [32]u8 = undefined;
    @memset(&bh1, 0x01);
    var bh2: [32]u8 = undefined;
    @memset(&bh2, 0x02);

    var r1 = try makeReceiptWithLogs(allocator, primitives.Address.ZERO_ADDRESS, null, 2);
    defer r1.deinit(allocator);
    var r2 = try makeReceiptWithLogs(allocator, primitives.Address.ZERO_ADDRESS, null, 3);
    defer r2.deinit(allocator);

    try idx.appendBlockLogs(allocator, 1, bh1, &[_]primitives.Receipt.Receipt{r1});
    try idx.appendBlockLogs(allocator, 2, bh2, &[_]primitives.Receipt.Receipt{r2});

    const result = try idx.query(allocator, .{ .block_hash = bh1 }, 2);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 2), result.len);
    for (result) |entry| {
        try testing.expect(std.mem.eql(u8, &entry.block_hash, &bh1));
    }
}

test "log_index: empty range returns empty slice" {
    const allocator = testing.allocator;
    var idx = log_index.LogIndex.init();
    defer idx.deinit(allocator);

    const result = try idx.query(allocator, .{ .from_block = 0, .to_block = 0 }, 0);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 0), result.len);
}

test "log_index: error on blockHash + fromBlock conflict" {
    const allocator = testing.allocator;
    var idx = log_index.LogIndex.init();
    defer idx.deinit(allocator);

    var bh: [32]u8 = undefined;
    @memset(&bh, 0x01);

    const result = idx.query(allocator, .{ .block_hash = bh, .from_block = 0 }, 0);
    try testing.expectError(error.InvalidFilter, result);
}

test "log_index: error on reversed block range" {
    const allocator = testing.allocator;
    var idx = log_index.LogIndex.init();
    defer idx.deinit(allocator);

    const result = idx.query(allocator, .{ .from_block = 10, .to_block = 5 }, 10);
    try testing.expectError(error.InvalidFilter, result);
}

test "log_index: error on to_block > head_block" {
    const allocator = testing.allocator;
    var idx = log_index.LogIndex.init();
    defer idx.deinit(allocator);

    const result = idx.query(allocator, .{ .from_block = 0, .to_block = 100 }, 10);
    try testing.expectError(error.InvalidFilter, result);
}

test "log_index: deinit frees all memory" {
    const allocator = testing.allocator;
    var idx = log_index.LogIndex.init();

    var bh: [32]u8 = undefined;
    @memset(&bh, 0x01);

    var receipt = try makeReceiptWithLogs(allocator, primitives.Address.ZERO_ADDRESS, null, 2);
    defer receipt.deinit(allocator);

    try idx.appendBlockLogs(allocator, 1, bh, &[_]primitives.Receipt.Receipt{receipt});

    idx.deinit(allocator);
}
