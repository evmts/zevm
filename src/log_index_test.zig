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

test "log_index: failed append leaves the index unchanged (#53)" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const allocator = failing.allocator();
    var idx = log_index.LogIndex.init();
    defer idx.deinit(allocator);

    const addr = primitives.Address.ZERO_ADDRESS;
    const topic = [_]u8{0x77} ** 32;
    const block_one = [_]u8{0x01} ** 32;
    const block_two = [_]u8{0x02} ** 32;

    var first = try makeReceiptWithLogs(testing.allocator, addr, topic, 1);
    defer first.deinit(testing.allocator);
    try idx.appendBlockLogs(allocator, 1, block_one, &[_]primitives.Receipt.Receipt{first});

    var r0 = try makeReceiptWithLogs(testing.allocator, addr, topic, 2);
    defer r0.deinit(testing.allocator);
    var r1 = try makeReceiptWithLogs(testing.allocator, addr, null, 3);
    defer r1.deinit(testing.allocator);
    const receipts = [_]primitives.Receipt.Receipt{ r0, r1 };

    var failures: usize = 0;
    var budget: usize = 0;
    while (budget < 64) : (budget += 1) {
        failing.fail_index = failing.alloc_index + budget;
        if (idx.appendBlockLogs(allocator, 2, block_two, &receipts)) |_| {
            break;
        } else |err| {
            failures += 1;
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(@as(usize, 1), idx.logs.items.len);
            try testing.expect(idx.block_range.get(2) == null);
            try testing.expectEqual(@as(usize, 1), idx.block_range.count());
        }
    } else return error.AppendNeverSucceeded;
    failing.fail_index = std.math.maxInt(usize);

    try testing.expect(failures > 0);
    try testing.expectEqual(@as(usize, 6), idx.logs.items.len);
    const by_hash = try idx.query(testing.allocator, .{ .block_hash = block_two }, 2);
    defer testing.allocator.free(by_hash);
    try testing.expectEqual(@as(usize, 5), by_hash.len);
    const by_range = try idx.query(testing.allocator, .{ .from_block = 2, .to_block = 2 }, 2);
    defer testing.allocator.free(by_range);
    try testing.expectEqual(@as(usize, 5), by_range.len);
}

test "log_index: empty address list is a wildcard" {
    const allocator = testing.allocator;
    var idx = log_index.LogIndex.init();
    defer idx.deinit(allocator);

    var bh: [32]u8 = undefined;
    @memset(&bh, 0x01);
    const addr = primitives.Address{ .bytes = [_]u8{0x11} ** 20 };

    var receipt = try makeReceiptWithLogs(allocator, addr, null, 2);
    defer receipt.deinit(allocator);
    try idx.appendBlockLogs(allocator, 1, bh, &[_]primitives.Receipt.Receipt{receipt});

    const no_addresses: []const primitives.Address.Address = &.{};
    const by_range = try idx.query(allocator, .{ .from_block = 1, .to_block = 1, .addresses = no_addresses }, 1);
    defer allocator.free(by_range);
    try testing.expectEqual(@as(usize, 2), by_range.len);

    const by_hash = try idx.query(allocator, .{ .block_hash = bh, .addresses = no_addresses }, 1);
    defer allocator.free(by_hash);
    try testing.expectEqual(@as(usize, 2), by_hash.len);
}

test "log_index: removeBlocksAbove drops stale blocks by number and by hash" {
    const allocator = testing.allocator;
    var idx = log_index.LogIndex.init();
    defer idx.deinit(allocator);

    const addr = primitives.Address{ .bytes = [_]u8{0x22} ** 20 };
    var hashes: [4][32]u8 = undefined;
    for (&hashes, 0..) |*hash, i| @memset(hash, @intCast(i + 1));

    var receipt = try makeReceiptWithLogs(allocator, addr, null, 2);
    defer receipt.deinit(allocator);
    var empty_receipt = try makeReceiptWithLogs(allocator, addr, null, 0);
    defer empty_receipt.deinit(allocator);

    try idx.appendBlockLogs(allocator, 1, hashes[0], &[_]primitives.Receipt.Receipt{receipt});
    try idx.appendBlockLogs(allocator, 2, hashes[1], &[_]primitives.Receipt.Receipt{receipt});
    try idx.appendBlockLogs(allocator, 3, hashes[2], &[_]primitives.Receipt.Receipt{empty_receipt});

    idx.removeBlocksAbove(1);

    const kept = try idx.query(allocator, .{ .from_block = 0, .to_block = 3 }, 3);
    defer allocator.free(kept);
    try testing.expectEqual(@as(usize, 2), kept.len);
    try testing.expect(std.mem.eql(u8, &kept[0].block_hash, &hashes[0]));

    const stale = try idx.query(allocator, .{ .block_hash = hashes[1] }, 3);
    defer allocator.free(stale);
    try testing.expectEqual(@as(usize, 0), stale.len);
    try testing.expectEqual(@as(usize, 1), idx.block_hash_range.count());

    try idx.appendBlockLogs(allocator, 2, hashes[3], &[_]primitives.Receipt.Receipt{receipt});
    const replaced = try idx.query(allocator, .{ .from_block = 2, .to_block = 2 }, 2);
    defer allocator.free(replaced);
    try testing.expectEqual(@as(usize, 2), replaced.len);
    try testing.expect(std.mem.eql(u8, &replaced[0].block_hash, &hashes[3]));
    try testing.expectEqual(@as(usize, 4), idx.logs.items.len);

    idx.removeBlocksAbove(std.math.maxInt(u64));
    try testing.expectEqual(@as(usize, 2), idx.block_numbers.items.len);
}

test "log_index: failed append leaves the index unchanged" {
    const base = testing.allocator;
    var idx = log_index.LogIndex.init();
    defer idx.deinit(base);

    const addr = primitives.Address{ .bytes = [_]u8{0x33} ** 20 };
    var bh: [32]u8 = undefined;
    @memset(&bh, 0x07);
    var receipt = try makeReceiptWithLogs(base, addr, null, 3);
    defer receipt.deinit(base);

    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(base, .{ .fail_index = fail_index });
        if (idx.appendBlockLogs(failing.allocator(), 5, bh, &[_]primitives.Receipt.Receipt{receipt})) |_| {
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(@as(usize, 0), idx.logs.items.len);
            try testing.expectEqual(@as(usize, 0), idx.block_range.count());
            try testing.expectEqual(@as(usize, 0), idx.block_hash_range.count());
            try testing.expectEqual(@as(usize, 0), idx.block_numbers.items.len);
        }
    } else return error.TestUnexpectedResult;

    const result = try idx.query(base, .{ .from_block = 5, .to_block = 5 }, 5);
    defer base.free(result);
    try testing.expectEqual(@as(usize, 3), result.len);
}
