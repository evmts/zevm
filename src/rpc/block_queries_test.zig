const std = @import("std");
const testing = std.testing;
const primitives = @import("primitives");
const blockchain_mod = @import("blockchain");
const block_queries = @import("block_queries.zig");
const receipt_index_mod = @import("../receipt_index.zig");
const log_index_mod = @import("../log_index.zig");

fn setupBlockchain(allocator: std.mem.Allocator) !blockchain_mod.Blockchain {
    var bc = try blockchain_mod.Blockchain.init(allocator, null);
    const genesis = try primitives.Block.genesis(1, allocator);
    try bc.putBlock(genesis);
    try bc.setCanonicalHead(genesis.hash);
    return bc;
}

fn addBlock(allocator: std.mem.Allocator, bc: *blockchain_mod.Blockchain, parent_hash: [32]u8, number: u64) !primitives.Block.Block {
    var header = primitives.BlockHeader.BlockHeader{
        .parent_hash = parent_hash,
        .number = number,
        .timestamp = number * 12,
        .gas_limit = 30_000_000,
        .base_fee_per_gas = 1_000_000_000,
    };
    _ = &header;
    const body = primitives.BlockBody.init();
    const block = try primitives.Block.from(&header, &body, allocator);
    try bc.putBlock(block);
    try bc.setCanonicalHead(block.hash);
    return block;
}

// ============================================================================
// Block Query Tests
// ============================================================================

test "getBlockByNumber: returns null for missing block" {
    const allocator = testing.allocator;
    var bc = try setupBlockchain(allocator);
    defer bc.deinit();

    const result = try block_queries.getBlockByNumber(allocator, &bc, "0x999", false);
    try testing.expect(result == null);
}

test "getBlockByNumber: returns genesis at tag 'earliest'" {
    const allocator = testing.allocator;
    var bc = try setupBlockchain(allocator);
    defer bc.deinit();

    const result = try block_queries.getBlockByNumber(allocator, &bc, "earliest", false);
    try testing.expect(result != null);
    try testing.expectEqual(@as(u64, 0), result.?.number);
}

test "getBlockByNumber: returns head block at tag 'latest'" {
    const allocator = testing.allocator;
    var bc = try setupBlockchain(allocator);
    defer bc.deinit();

    const genesis = (try bc.getBlockByNumber(0)).?;
    const b1 = try addBlock(allocator, &bc, genesis.hash, 1);
    _ = b1;

    const result = try block_queries.getBlockByNumber(allocator, &bc, "latest", false);
    try testing.expect(result != null);
    try testing.expectEqual(@as(u64, 1), result.?.number);
}

test "getBlockByNumber: returns block at hex number" {
    const allocator = testing.allocator;
    var bc = try setupBlockchain(allocator);
    defer bc.deinit();

    const result = try block_queries.getBlockByNumber(allocator, &bc, "0x0", false);
    try testing.expect(result != null);
    try testing.expectEqual(@as(u64, 0), result.?.number);
}

test "getBlockByNumber: fullTxs=false returns tx hashes" {
    const allocator = testing.allocator;
    var bc = try setupBlockchain(allocator);
    defer bc.deinit();

    const result = (try block_queries.getBlockByNumber(allocator, &bc, "earliest", false)).?;
    switch (result.transactions) {
        .hashes => {},
        .full => return error.ExpectedHashes,
    }
}

test "getBlockByNumber: fullTxs=true returns tx objects" {
    const allocator = testing.allocator;
    var bc = try setupBlockchain(allocator);
    defer bc.deinit();

    const result = (try block_queries.getBlockByNumber(allocator, &bc, "earliest", true)).?;
    switch (result.transactions) {
        .full => {},
        .hashes => return error.ExpectedFull,
    }
}

test "getBlockByHash: returns block by 32-byte hash" {
    const allocator = testing.allocator;
    var bc = try setupBlockchain(allocator);
    defer bc.deinit();

    const genesis = (try bc.getBlockByNumber(0)).?;
    const result = try block_queries.getBlockByHash(allocator, &bc, genesis.hash, false);
    try testing.expect(result != null);
    try testing.expectEqual(@as(u64, 0), result.?.number);
}

test "getBlockByHash: returns null for zero hash" {
    const allocator = testing.allocator;
    var bc = try setupBlockchain(allocator);
    defer bc.deinit();

    const result = try block_queries.getBlockByHash(allocator, &bc, [_]u8{0} ** 32, false);
    try testing.expect(result == null);
}

test "getBlockTransactionCountByNumber: returns 0 for empty block" {
    const allocator = testing.allocator;
    var bc = try setupBlockchain(allocator);
    defer bc.deinit();

    const result = try block_queries.getBlockTxCountByNumber(&bc, "0x0");
    try testing.expect(result != null);
    try testing.expectEqual(@as(u64, 0), result.?);
}

test "getBlockTransactionCountByHash: returns null for missing block" {
    const allocator = testing.allocator;
    var bc = try setupBlockchain(allocator);
    defer bc.deinit();

    const result = try block_queries.getBlockTxCountByHash(&bc, [_]u8{0xff} ** 32);
    try testing.expect(result == null);
}

test "getBlockTransactionCountByHash: returns correct count" {
    const allocator = testing.allocator;
    var bc = try setupBlockchain(allocator);
    defer bc.deinit();

    const genesis = (try bc.getBlockByNumber(0)).?;
    const result = try block_queries.getBlockTxCountByHash(&bc, genesis.hash);
    try testing.expect(result != null);
    try testing.expectEqual(@as(u64, 0), result.?);
}

// ============================================================================
// Receipt Query Tests
// ============================================================================

fn makeTestReceipt(allocator: std.mem.Allocator, tx_hash: [32]u8, block_hash: [32]u8, block_number: u64, success: bool) !primitives.Receipt.Receipt {
    const logs = try allocator.alloc(primitives.EventLog.EventLog, 0);
    var bloom: [256]u8 = undefined;
    @memset(&bloom, 0);

    return primitives.Receipt.Receipt{
        .transaction_hash = tx_hash,
        .transaction_index = 0,
        .block_hash = block_hash,
        .block_number = block_number,
        .sender = primitives.Address.ZERO_ADDRESS,
        .to = primitives.Address{ .bytes = [_]u8{0x42} ** 20 },
        .cumulative_gas_used = 21000,
        .gas_used = 21000,
        .contract_address = null,
        .logs = logs,
        .logs_bloom = bloom,
        .status = primitives.Receipt.TransactionStatus{ .success = success, .gas_used = 21000 },
        .root = null,
        .effective_gas_price = 1_000_000_000,
        .type = .legacy,
        .blob_gas_used = null,
        .blob_gas_price = null,
    };
}

test "getTransactionReceipt: returns null for missing tx hash" {
    const allocator = testing.allocator;
    var ri = receipt_index_mod.ReceiptIndex.init(allocator);
    defer ri.deinit(allocator);

    var missing: [32]u8 = undefined;
    @memset(&missing, 0xff);

    const result = try block_queries.getTransactionReceipt(allocator, &ri, missing);
    try testing.expect(result == null);
}

test "getTransactionReceipt: returns receipt with status=1 for success" {
    const allocator = testing.allocator;
    var ri = receipt_index_mod.ReceiptIndex.init(allocator);
    defer ri.deinit(allocator);

    var tx_hash: [32]u8 = undefined;
    @memset(&tx_hash, 0xaa);
    var block_hash: [32]u8 = undefined;
    @memset(&block_hash, 0xbb);

    var receipt = try makeTestReceipt(allocator, tx_hash, block_hash, 1, true);
    defer receipt.deinit(allocator);

    try ri.putBlockReceipts(allocator, block_hash, &[_]primitives.Receipt.Receipt{receipt});

    const result = (try block_queries.getTransactionReceipt(allocator, &ri, tx_hash)).?;
    defer allocator.free(result.logs);

    try testing.expectEqual(@as(?u8, 1), result.status);
}

test "getTransactionReceipt: returns receipt with status=0 for revert" {
    const allocator = testing.allocator;
    var ri = receipt_index_mod.ReceiptIndex.init(allocator);
    defer ri.deinit(allocator);

    var tx_hash: [32]u8 = undefined;
    @memset(&tx_hash, 0xcc);
    var block_hash: [32]u8 = undefined;
    @memset(&block_hash, 0xdd);

    var receipt = try makeTestReceipt(allocator, tx_hash, block_hash, 1, false);
    defer receipt.deinit(allocator);

    try ri.putBlockReceipts(allocator, block_hash, &[_]primitives.Receipt.Receipt{receipt});

    const result = (try block_queries.getTransactionReceipt(allocator, &ri, tx_hash)).?;
    defer allocator.free(result.logs);

    try testing.expectEqual(@as(?u8, 0), result.status);
}

test "getTransactionReceipt: contractAddress non-null for create tx" {
    const allocator = testing.allocator;
    var ri = receipt_index_mod.ReceiptIndex.init(allocator);
    defer ri.deinit(allocator);

    var tx_hash: [32]u8 = undefined;
    @memset(&tx_hash, 0xee);
    var block_hash: [32]u8 = undefined;
    @memset(&block_hash, 0xff);

    var receipt = try makeTestReceipt(allocator, tx_hash, block_hash, 1, true);
    defer receipt.deinit(allocator);
    receipt.to = null;
    receipt.contract_address = primitives.Address{ .bytes = [_]u8{0x99} ** 20 };

    try ri.putBlockReceipts(allocator, block_hash, &[_]primitives.Receipt.Receipt{receipt});

    const result = (try block_queries.getTransactionReceipt(allocator, &ri, tx_hash)).?;
    defer allocator.free(result.logs);

    try testing.expect(result.contractAddress != null);
    try testing.expect(result.to == null);
}

test "getBlockReceipts: returns null for missing block" {
    const allocator = testing.allocator;
    var bc = try setupBlockchain(allocator);
    defer bc.deinit();
    var ri = receipt_index_mod.ReceiptIndex.init(allocator);
    defer ri.deinit(allocator);

    const result = try block_queries.getBlockReceipts(allocator, &bc, &ri, "0x999");
    try testing.expect(result == null);
}

test "getBlockReceipts: returns empty array for block with no receipts stored" {
    const allocator = testing.allocator;
    var bc = try setupBlockchain(allocator);
    defer bc.deinit();
    var ri = receipt_index_mod.ReceiptIndex.init(allocator);
    defer ri.deinit(allocator);

    // Store empty receipts for genesis block
    const genesis = (try bc.getBlockByNumber(0)).?;
    const empty: []const primitives.Receipt.Receipt = &.{};
    try ri.putBlockReceipts(allocator, genesis.hash, empty);

    const result = (try block_queries.getBlockReceipts(allocator, &bc, &ri, "earliest")).?;
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 0), result.len);
}

// ============================================================================
// Log Query Tests
// ============================================================================

test "getLogs: returns empty slice for range with no matching logs" {
    const allocator = testing.allocator;
    var bc = try setupBlockchain(allocator);
    defer bc.deinit();
    var li = log_index_mod.LogIndex.init();
    defer li.deinit(allocator);

    const result = try block_queries.getLogs(allocator, &bc, &li, .{
        .from_block = 0,
        .to_block = 0,
    });
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 0), result.len);
}

test "getLogs: error on blockHash + fromBlock conflict" {
    const allocator = testing.allocator;
    var bc = try setupBlockchain(allocator);
    defer bc.deinit();
    var li = log_index_mod.LogIndex.init();
    defer li.deinit(allocator);

    var bh: [32]u8 = undefined;
    @memset(&bh, 0x01);

    const result = block_queries.getLogs(allocator, &bc, &li, .{
        .block_hash = bh,
        .from_block = 0,
    });
    try testing.expectError(error.InvalidFilter, result);
}

test "getLogs: error on reversed block range" {
    const allocator = testing.allocator;
    var bc = try setupBlockchain(allocator);
    defer bc.deinit();
    var li = log_index_mod.LogIndex.init();
    defer li.deinit(allocator);

    const result = block_queries.getLogs(allocator, &bc, &li, .{
        .from_block = 10,
        .to_block = 5,
    });
    try testing.expectError(error.InvalidFilter, result);
}
