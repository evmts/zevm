const std = @import("std");
const testing = std.testing;
const primitives = @import("primitives");
const blockchain_mod = @import("blockchain");
const block_queries = @import("block_queries.zig");
const receipt_index_mod = @import("../receipt_index.zig");
const log_index_mod = @import("../log_index.zig");
const genesis_mod = @import("../genesis.zig");
const tx_encoding = @import("../transaction_encoding.zig");

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

fn makeSignedLegacyTx(
    allocator: std.mem.Allocator,
    nonce: u64,
    gas_price: u256,
    gas_limit: u64,
    to: ?primitives.Address,
    value: u256,
    data: []const u8,
    chain_id: u64,
) !primitives.Transaction.LegacyTransaction {
    const unsigned = primitives.Transaction.LegacyTransaction{
        .nonce = nonce,
        .gas_price = gas_price,
        .gas_limit = gas_limit,
        .to = to,
        .value = value,
        .data = data,
        .v = 0,
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
    };
    return tx_encoding.signLegacyTransaction(allocator, unsigned, genesis_mod.DEV_ACCOUNTS[0].private_key, chain_id);
}

fn addBlockWithRawTransactions(
    allocator: std.mem.Allocator,
    bc: *blockchain_mod.Blockchain,
    parent_hash: [32]u8,
    number: u64,
    txs: []const primitives.BlockBody.TransactionData,
) !primitives.Block.Block {
    var header = primitives.BlockHeader.BlockHeader{
        .parent_hash = parent_hash,
        .number = number,
        .timestamp = number * 12,
        .gas_limit = 30_000_000,
        .base_fee_per_gas = 1_000_000_000,
    };
    _ = &header;
    const body = primitives.BlockBody.BlockBody{
        .transactions = txs,
        .ommers = &.{},
        .withdrawals = null,
    };
    const block = try primitives.Block.from(&header, &body, allocator);
    try bc.putBlock(block);
    try bc.setCanonicalHead(block.hash);
    return block;
}

fn expectHydratedLegacyTx(
    tx: block_queries.TxResponse,
    raw: []const u8,
    signed: primitives.Transaction.LegacyTransaction,
    sender: primitives.Address,
    block_hash: [32]u8,
    block_number: u64,
    index: u32,
) !void {
    const expected_hash = tx_encoding.transactionHash(raw);
    const actual_block_hash = tx.blockHash.?;
    try testing.expectEqualSlices(u8, &expected_hash, &tx.hash);
    try testing.expectEqualSlices(u8, &block_hash, &actual_block_hash);
    try testing.expectEqual(block_number, tx.blockNumber.?);
    try testing.expectEqual(index, tx.transactionIndex.?);
    try testing.expectEqual(sender, tx.from);
    try testing.expectEqual(signed.to.?, tx.to.?);
    try testing.expectEqual(signed.nonce, tx.nonce);
    try testing.expectEqual(signed.gas_limit, tx.gas);
    try testing.expectEqual(signed.value, tx.value);
    try testing.expectEqualSlices(u8, signed.data, tx.input);
    try testing.expectEqual(@as(u8, 0), tx.type_field);
    try testing.expectEqual(tx_encoding.legacyChainId(signed).?, tx.chain_id.?);
    try testing.expectEqual(signed.gas_price, tx.gas_price.?);
    try testing.expectEqual(@as(?u256, null), tx.max_fee_per_gas);
    try testing.expectEqual(@as(u256, signed.v), tx.v.?);
    try testing.expectEqual(tx_encoding.bytes32ToU256(signed.r), tx.r.?);
    try testing.expectEqual(tx_encoding.bytes32ToU256(signed.s), tx.s.?);
    try testing.expectEqual(tx_encoding.legacyRecoveryId(signed.v), tx.y_parity.?);
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

test "transaction queries hydrate signed legacy raw transaction fields" {
    const allocator = testing.allocator;
    var bc = try setupBlockchain(allocator);
    defer bc.deinit();
    var ri = receipt_index_mod.ReceiptIndex.init(allocator);
    defer ri.deinit(allocator);

    const genesis = (try bc.getBlockByNumber(0)).?;
    const sender = genesis_mod.DEV_ACCOUNTS[0].address;
    const recipient = genesis_mod.DEV_ACCOUNTS[1].address;
    const input = [_]u8{ 0xde, 0xad, 0xbe, 0xef };
    const signed = try makeSignedLegacyTx(
        allocator,
        7,
        2_000_000_000,
        50_000,
        recipient,
        1234,
        &input,
        31337,
    );
    const raw = try tx_encoding.encodeLegacyTransactionEnvelope(allocator, signed);
    defer allocator.free(raw);
    const tx_hash = tx_encoding.transactionHash(raw);

    const txs = try allocator.alloc(primitives.BlockBody.TransactionData, 1);
    defer allocator.free(txs);
    txs[0] = .{ .raw = raw };

    const block = try addBlockWithRawTransactions(allocator, &bc, genesis.hash, 1, txs);

    const by_index = (try block_queries.getTransactionByBlockHashAndIndex(allocator, &bc, block.hash, 0)).?;
    try expectHydratedLegacyTx(by_index, raw, signed, sender, block.hash, 1, 0);

    const by_number = (try block_queries.getTransactionByBlockNumberAndIndex(allocator, &bc, "0x1", 0)).?;
    try expectHydratedLegacyTx(by_number, raw, signed, sender, block.hash, 1, 0);

    var receipt = try makeTestReceipt(allocator, tx_hash, block.hash, 1, true);
    defer receipt.deinit(allocator);
    receipt.sender = sender;
    receipt.to = recipient;
    receipt.effective_gas_price = signed.gas_price;
    try ri.putBlockReceipts(allocator, block.hash, &[_]primitives.Receipt.Receipt{receipt});

    const by_hash = (try block_queries.getTransactionByHash(allocator, &bc, &ri, tx_hash)).?;
    try expectHydratedLegacyTx(by_hash, raw, signed, sender, block.hash, 1, 0);
}

test "transaction query for typed raw envelope degrades without legacy field hydration" {
    const allocator = testing.allocator;
    var bc = try setupBlockchain(allocator);
    defer bc.deinit();

    const genesis = (try bc.getBlockByNumber(0)).?;
    const typed_raw = [_]u8{ 0x02, 0xc0 };
    const txs = try allocator.alloc(primitives.BlockBody.TransactionData, 1);
    defer allocator.free(txs);
    txs[0] = .{ .raw = &typed_raw };

    const block = try addBlockWithRawTransactions(allocator, &bc, genesis.hash, 1, txs);

    const tx = (try block_queries.getTransactionByBlockHashAndIndex(allocator, &bc, block.hash, 0)).?;
    const typed_hash = tx_encoding.transactionHash(&typed_raw);
    try testing.expectEqual(@as(u8, 2), tx.type_field);
    try testing.expectEqualSlices(u8, &typed_hash, &tx.hash);
    try testing.expectEqual(primitives.Address.ZERO_ADDRESS, tx.from);
    try testing.expectEqual(@as(?primitives.Address, null), tx.to);
    try testing.expectEqual(@as(u64, 0), tx.nonce);
    try testing.expectEqual(@as(u64, 0), tx.gas);
    try testing.expectEqual(@as(u256, 0), tx.value);
    try testing.expectEqual(@as(usize, 0), tx.input.len);
    try testing.expectEqual(@as(?u256, null), tx.gas_price);
    try testing.expectEqual(@as(?u256, null), tx.v);
    try testing.expectEqual(@as(?u256, null), tx.r);
    try testing.expectEqual(@as(?u256, null), tx.s);
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
