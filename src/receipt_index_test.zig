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

test "receipt_index: putBlockReceipts is failure-atomic on allocation errors" {
    const backing_allocator = testing.allocator;

    var block_hash: [32]u8 = undefined;
    @memset(&block_hash, 0xab);

    var tx_hash1: [32]u8 = undefined;
    @memset(&tx_hash1, 0x21);
    var tx_hash2: [32]u8 = undefined;
    @memset(&tx_hash2, 0x22);

    var r1 = try makeReceipt(backing_allocator, tx_hash1, block_hash, 8, 0);
    defer r1.deinit(backing_allocator);
    var r2 = try makeReceipt(backing_allocator, tx_hash2, block_hash, 8, 1);
    defer r2.deinit(backing_allocator);
    const receipts = [_]primitives.Receipt.Receipt{ r1, r2 };

    var saw_oom = false;
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        try testing.expect(fail_index < 1024);

        var failing_allocator_state = std.testing.FailingAllocator.init(backing_allocator, .{
            .fail_index = fail_index,
        });
        const allocator = failing_allocator_state.allocator();

        var idx = receipt_index.ReceiptIndex.init(allocator);
        defer idx.deinit(allocator);

        if (idx.putBlockReceipts(allocator, block_hash, &receipts)) |_| {
            const found = idx.getByBlockHash(block_hash).?;
            try testing.expectEqual(@as(usize, 2), found.len);
            try testing.expect(idx.getByTxHash(tx_hash1) != null);
            try testing.expect(idx.getByTxHash(tx_hash2) != null);
            break;
        } else |err| switch (err) {
            error.OutOfMemory => {
                saw_oom = true;
                try testing.expect(idx.getByBlockHash(block_hash) == null);
                try testing.expect(idx.getByTxHash(tx_hash1) == null);
                try testing.expect(idx.getByTxHash(tx_hash2) == null);
            },
            else => return err,
        }
    }

    try testing.expect(saw_oom);
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
