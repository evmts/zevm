const std = @import("std");
const testing = std.testing;
const primitives = @import("primitives");
const receipt_index = @import("receipt_index.zig");

fn makeReceipt(allocator: std.mem.Allocator, tx_hash: [32]u8, block_hash: [32]u8, block_number: u64, tx_index: u32) !primitives.Receipt.Receipt {
    const logs = try allocator.alloc(primitives.EventLog.EventLog, 0);
    var bloom: [256]u8 = undefined;
    @memset(&bloom, 0);

    return primitives.Receipt.Receipt{
        .transaction_hash = tx_hash,
        .transaction_index = tx_index,
        .block_hash = block_hash,
        .block_number = block_number,
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

test "receipt_index: store and retrieve by tx hash" {
    const allocator = testing.allocator;
    var idx = receipt_index.ReceiptIndex.init(allocator);
    defer idx.deinit(allocator);

    var tx_hash: [32]u8 = undefined;
    @memset(&tx_hash, 0xaa);
    var block_hash: [32]u8 = undefined;
    @memset(&block_hash, 0xbb);

    var receipt = try makeReceipt(allocator, tx_hash, block_hash, 1, 0);
    defer receipt.deinit(allocator);

    const receipts = [_]primitives.Receipt.Receipt{receipt};
    try idx.putBlockReceipts(allocator, block_hash, &receipts);

    const found = idx.getByTxHash(tx_hash);
    try testing.expect(found != null);
    try testing.expectEqual(@as(u64, 1), found.?.block_number);
}

test "receipt_index: missing tx hash returns null" {
    const allocator = testing.allocator;
    var idx = receipt_index.ReceiptIndex.init(allocator);
    defer idx.deinit(allocator);

    var missing: [32]u8 = undefined;
    @memset(&missing, 0xff);

    try testing.expect(idx.getByTxHash(missing) == null);
}

test "receipt_index: store and retrieve block receipts by block hash" {
    const allocator = testing.allocator;
    var idx = receipt_index.ReceiptIndex.init(allocator);
    defer idx.deinit(allocator);

    var block_hash: [32]u8 = undefined;
    @memset(&block_hash, 0xcc);

    var tx_hash1: [32]u8 = undefined;
    @memset(&tx_hash1, 0x01);
    var tx_hash2: [32]u8 = undefined;
    @memset(&tx_hash2, 0x02);

    var r1 = try makeReceipt(allocator, tx_hash1, block_hash, 5, 0);
    defer r1.deinit(allocator);
    var r2 = try makeReceipt(allocator, tx_hash2, block_hash, 5, 1);
    defer r2.deinit(allocator);

    const receipts = [_]primitives.Receipt.Receipt{ r1, r2 };
    try idx.putBlockReceipts(allocator, block_hash, &receipts);

    const found = idx.getByBlockHash(block_hash);
    try testing.expect(found != null);
    try testing.expectEqual(@as(usize, 2), found.?.len);
}

test "receipt_index: missing block hash returns null" {
    const allocator = testing.allocator;
    var idx = receipt_index.ReceiptIndex.init(allocator);
    defer idx.deinit(allocator);

    var missing: [32]u8 = undefined;
    @memset(&missing, 0xff);

    try testing.expect(idx.getByBlockHash(missing) == null);
}

test "receipt_index: block hash with no receipts returns empty slice" {
    const allocator = testing.allocator;
    var idx = receipt_index.ReceiptIndex.init(allocator);
    defer idx.deinit(allocator);

    var block_hash: [32]u8 = undefined;
    @memset(&block_hash, 0xdd);

    const empty: []const primitives.Receipt.Receipt = &.{};
    try idx.putBlockReceipts(allocator, block_hash, empty);

    const found = idx.getByBlockHash(block_hash);
    try testing.expect(found != null);
    try testing.expectEqual(@as(usize, 0), found.?.len);
}

test "receipt_index: clone preserves block and transaction lookups independently" {
    const allocator = testing.allocator;
    var idx = receipt_index.ReceiptIndex.init(allocator);

    var block_hash: [32]u8 = undefined;
    @memset(&block_hash, 0xce);
    var tx_hash: [32]u8 = undefined;
    @memset(&tx_hash, 0x42);

    var receipt = try makeReceipt(allocator, tx_hash, block_hash, 9, 0);
    defer receipt.deinit(allocator);

    try idx.putBlockReceipts(allocator, block_hash, &[_]primitives.Receipt.Receipt{receipt});

    var cloned = try idx.clone(allocator);
    defer cloned.deinit(allocator);
    idx.deinit(allocator);

    const by_tx = cloned.getByTxHash(tx_hash);
    try testing.expect(by_tx != null);
    try testing.expectEqual(@as(u64, 9), by_tx.?.block_number);

    const by_block = cloned.getByBlockHash(block_hash);
    try testing.expect(by_block != null);
    try testing.expectEqual(@as(usize, 1), by_block.?.len);
    try testing.expect(std.mem.eql(u8, &by_block.?[0].transaction_hash, &tx_hash));
}

test "receipt_index: multiple receipts stored per block in tx-index order" {
    const allocator = testing.allocator;
    var idx = receipt_index.ReceiptIndex.init(allocator);
    defer idx.deinit(allocator);

    var block_hash: [32]u8 = undefined;
    @memset(&block_hash, 0xee);

    var tx_hash0: [32]u8 = undefined;
    @memset(&tx_hash0, 0x10);
    var tx_hash1: [32]u8 = undefined;
    @memset(&tx_hash1, 0x11);
    var tx_hash2: [32]u8 = undefined;
    @memset(&tx_hash2, 0x12);

    var r0 = try makeReceipt(allocator, tx_hash0, block_hash, 10, 0);
    defer r0.deinit(allocator);
    var r1 = try makeReceipt(allocator, tx_hash1, block_hash, 10, 1);
    defer r1.deinit(allocator);
    var r2 = try makeReceipt(allocator, tx_hash2, block_hash, 10, 2);
    defer r2.deinit(allocator);

    const receipts = [_]primitives.Receipt.Receipt{ r0, r1, r2 };
    try idx.putBlockReceipts(allocator, block_hash, &receipts);

    const found = idx.getByBlockHash(block_hash).?;
    try testing.expectEqual(@as(usize, 3), found.len);
    try testing.expectEqual(@as(u32, 0), found[0].transaction_index);
    try testing.expectEqual(@as(u32, 1), found[1].transaction_index);
    try testing.expectEqual(@as(u32, 2), found[2].transaction_index);
}

fn makeReceiptWithLog(allocator: std.mem.Allocator, tx_hash: [32]u8, block_hash: [32]u8, block_number: u64) !primitives.Receipt.Receipt {
    const logs = try allocator.alloc(primitives.EventLog.EventLog, 1);
    const topics = try allocator.alloc([32]u8, 1);
    @memset(&topics[0], 0x77);
    const data = try allocator.dupe(u8, &[_]u8{ 1, 2, 3, 4 });
    logs[0] = primitives.EventLog.EventLog{
        .address = primitives.Address.ZERO_ADDRESS,
        .topics = topics,
        .data = data,
        .block_number = block_number,
        .transaction_hash = tx_hash,
        .transaction_index = 0,
        .log_index = 0,
        .removed = false,
    };
    var bloom: [256]u8 = undefined;
    @memset(&bloom, 0);

    return primitives.Receipt.Receipt{
        .transaction_hash = tx_hash,
        .transaction_index = 0,
        .block_hash = block_hash,
        .block_number = block_number,
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

test "receipt_index: duplicate tx hash across blocks frees prior logs (no leak)" {
    // Regression for finding #30: by_tx.put silently overwrote on duplicate tx
    // hash, leaking the prior receipt's logs. testing.allocator detects the leak.
    const allocator = testing.allocator;
    var idx = receipt_index.ReceiptIndex.init(allocator);
    defer idx.deinit(allocator);

    var tx_hash: [32]u8 = undefined;
    @memset(&tx_hash, 0x42);
    var block_a: [32]u8 = undefined;
    @memset(&block_a, 0xaa);
    var block_b: [32]u8 = undefined;
    @memset(&block_b, 0xbb);

    var ra = try makeReceiptWithLog(allocator, tx_hash, block_a, 1);
    defer ra.deinit(allocator);
    try idx.putBlockReceipts(allocator, block_a, &[_]primitives.Receipt.Receipt{ra});

    // Re-seal a different block containing the same tx hash. The first receipt's
    // logs (from block_a) must be freed before the by_tx entry is overwritten.
    var rb = try makeReceiptWithLog(allocator, tx_hash, block_b, 2);
    defer rb.deinit(allocator);
    try idx.putBlockReceipts(allocator, block_b, &[_]primitives.Receipt.Receipt{rb});

    const found = idx.getByTxHash(tx_hash).?;
    try testing.expectEqual(@as(u64, 2), found.block_number);
}

test "receipt_index: failed by_tx insertion rolls back so index stays consistent" {
    // Regression for finding #32: when a later by_tx.put fails, earlier by_tx
    // entries for the same call must be rolled back so getByTxHash does not report
    // receipts for a block absent from by_block.
    const base = testing.allocator;
    var idx = receipt_index.ReceiptIndex.init(base);
    defer idx.deinit(base);

    var tx0: [32]u8 = undefined;
    @memset(&tx0, 0x01);
    var tx1: [32]u8 = undefined;
    @memset(&tx1, 0x02);
    var tx2: [32]u8 = undefined;
    @memset(&tx2, 0x03);
    var block_hash: [32]u8 = undefined;
    @memset(&block_hash, 0xcd);

    var r0 = try makeReceiptWithLog(base, tx0, block_hash, 5);
    defer r0.deinit(base);
    var r1 = try makeReceiptWithLog(base, tx1, block_hash, 5);
    defer r1.deinit(base);
    var r2 = try makeReceiptWithLog(base, tx2, block_hash, 5);
    defer r2.deinit(base);
    const receipts = [_]primitives.Receipt.Receipt{ r0, r1, r2 };

    // Find the failure point: run with increasing allocation budgets until the call
    // fails. For each failing budget, verify the index is left fully consistent
    // (no orphan by_tx entries) and no memory leaks (FailingAllocator + the rollback
    // errdefer must free everything).
    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(base, .{ .fail_index = fail_index });
        const alloc = failing.allocator();

        const result = idx.putBlockReceipts(alloc, block_hash, &receipts);
        if (result) |_| {
            // Succeeded: block present, all txs present, then we are done scanning.
            try testing.expect(idx.getByBlockHash(block_hash) != null);
            try testing.expect(idx.getByTxHash(tx0) != null);
            try testing.expect(idx.getByTxHash(tx1) != null);
            try testing.expect(idx.getByTxHash(tx2) != null);
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            // After a failed call the index must be unchanged: no block stored and
            // no orphan tx entries for this call.
            try testing.expect(idx.getByBlockHash(block_hash) == null);
            try testing.expect(idx.getByTxHash(tx0) == null);
            try testing.expect(idx.getByTxHash(tx1) == null);
            try testing.expect(idx.getByTxHash(tx2) == null);
        }
    }
}

test "receipt_index: deinit frees all memory" {
    const allocator = testing.allocator;
    var idx = receipt_index.ReceiptIndex.init(allocator);

    var block_hash: [32]u8 = undefined;
    @memset(&block_hash, 0xaa);
    var tx_hash: [32]u8 = undefined;
    @memset(&tx_hash, 0xbb);

    var receipt = try makeReceipt(allocator, tx_hash, block_hash, 1, 0);
    defer receipt.deinit(allocator);

    const receipts = [_]primitives.Receipt.Receipt{receipt};
    try idx.putBlockReceipts(allocator, block_hash, &receipts);

    // deinit should free all cloned data without leaks
    idx.deinit(allocator);
}
