const std = @import("std");
const jsonrpc = @import("jsonrpc");
const primitives = @import("primitives");
const blockchain_mod = @import("blockchain");
const block_query_handlers = @import("block_query_handlers.zig");
const receipt_index_mod = @import("../../receipt_index.zig");
const log_index_mod = @import("../../log_index.zig");
const runtime = @import("../../node/runtime.zig");

fn makeBlockSpec(tag: []const u8) jsonrpc.types.BlockSpec {
    return .{ .value = .{ .string = tag } };
}

fn setupCtx(allocator: std.mem.Allocator) !struct {
    rt: runtime.NodeRuntime,
    bc: blockchain_mod.Blockchain,
    ri: receipt_index_mod.ReceiptIndex,
    li: log_index_mod.LogIndex,

    fn getCtx(self: *@This()) block_query_handlers.BlockQueryContext {
        return .{
            .rt = &self.rt,
            .blockchain = &self.bc,
            .receipt_index = &self.ri,
            .log_index = &self.li,
        };
    }

    fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        self.li.deinit(alloc);
        self.ri.deinit(alloc);
        self.bc.deinit();
        self.rt.deinit(alloc);
    }
} {
    var rt = try runtime.NodeRuntime.init(allocator, null);
    errdefer rt.deinit(allocator);

    var bc = try blockchain_mod.Blockchain.init(allocator, null);
    errdefer bc.deinit();

    const genesis = try primitives.Block.genesis(1, allocator);
    try bc.putBlock(genesis);
    try bc.setCanonicalHead(genesis.hash);

    return .{
        .rt = rt,
        .bc = bc,
        .ri = receipt_index_mod.ReceiptIndex.init(allocator),
        .li = log_index_mod.LogIndex.init(),
    };
}

fn makeReceiptWithSingleLog(
    allocator: std.mem.Allocator,
    tx_hash: [32]u8,
    block_hash: [32]u8,
    block_number: u64,
    topic: [32]u8,
    data: []const u8,
) !primitives.Receipt.Receipt {
    const topics = try allocator.alloc([32]u8, 1);
    topics[0] = topic;

    const logs = try allocator.alloc(primitives.EventLog.EventLog, 1);
    logs[0] = .{
        .address = runtime.DEFAULT_DEV_ACCOUNTS[0],
        .topics = topics,
        .data = try allocator.dupe(u8, data),
        .block_number = block_number,
        .transaction_hash = tx_hash,
        .transaction_index = 0,
        .log_index = 0,
        .removed = false,
    };

    var bloom: [256]u8 = undefined;
    @memset(&bloom, 0);

    return .{
        .transaction_hash = tx_hash,
        .transaction_index = 0,
        .block_hash = block_hash,
        .block_number = block_number,
        .sender = runtime.DEFAULT_DEV_ACCOUNTS[0],
        .to = runtime.DEFAULT_DEV_ACCOUNTS[1],
        .cumulative_gas_used = 21_000,
        .gas_used = 21_000,
        .contract_address = null,
        .logs = logs,
        .logs_bloom = bloom,
        .status = .{ .success = true, .gas_used = 21_000 },
        .root = null,
        .effective_gas_price = runtime.DEFAULT_GAS_PRICE,
        .type = .legacy,
        .blob_gas_used = null,
        .blob_gas_price = null,
    };
}

// ============================================================================
// eth_getBlockByNumber tests
// ============================================================================

test "handleGetBlockByNumber: returns null for missing block" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var state = try setupCtx(allocator);
    defer state.deinit(allocator);

    var ctx = state.getCtx();
    const result = try block_query_handlers.handleGetBlockByNumber(
        arena.allocator(),
        &ctx,
        .{ .block = makeBlockSpec("0x999"), .hydrated_transactions = false },
    );
    try std.testing.expect(result.block == null);
}

test "handleGetBlockByNumber: returns genesis at earliest" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var state = try setupCtx(allocator);
    defer state.deinit(allocator);

    var ctx = state.getCtx();
    const result = try block_query_handlers.handleGetBlockByNumber(
        arena.allocator(),
        &ctx,
        .{ .block = makeBlockSpec("earliest"), .hydrated_transactions = false },
    );
    try std.testing.expect(result.block != null);
}

test "handleGetBlockByNumber: returns block at latest" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var state = try setupCtx(allocator);
    defer state.deinit(allocator);

    var ctx = state.getCtx();
    const result = try block_query_handlers.handleGetBlockByNumber(
        arena.allocator(),
        &ctx,
        .{ .block = makeBlockSpec("latest"), .hydrated_transactions = false },
    );
    try std.testing.expect(result.block != null);
}

test "handleGetBlockByNumber: preserves block extraData" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var state = try setupCtx(allocator);
    defer state.deinit(allocator);

    const genesis = (try state.rt.blockchain.getBlockByNumber(0)).?;
    var header = primitives.BlockHeader.BlockHeader{
        .parent_hash = genesis.hash,
        .number = 1,
        .timestamp = 12,
        .gas_limit = 30_000_000,
        .base_fee_per_gas = runtime.DEFAULT_BASE_FEE,
        .extra_data = &[_]u8{ 0xde, 0xad },
    };
    const body = primitives.BlockBody.init();
    const block = try primitives.Block.from(&header, &body, allocator);
    try state.rt.blockchain.putBlock(block);
    try state.rt.blockchain.setCanonicalHead(block.hash);

    state.rt.head_block_number = 1;

    var ctx = state.getCtx();
    const result = try block_query_handlers.handleGetBlockByNumber(
        arena.allocator(),
        &ctx,
        .{ .block = makeBlockSpec("0x1"), .hydrated_transactions = false },
    );
    const rpc_block = result.block orelse return error.ExpectedBlock;
    switch (rpc_block.extraData.value) {
        .string => |value| try std.testing.expectEqualStrings("0xdead", value),
        else => return error.ExpectedExtraDataString,
    }
}

// ============================================================================
// eth_getBlockByHash tests
// ============================================================================

test "handleGetBlockByHash: returns null for zero hash" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var state = try setupCtx(allocator);
    defer state.deinit(allocator);

    var ctx = state.getCtx();
    const result = try block_query_handlers.handleGetBlockByHash(
        arena.allocator(),
        &ctx,
        .{
            .block_hash = .{ .bytes = [_]u8{0} ** 32 },
            .hydrated_transactions = false,
        },
    );
    try std.testing.expect(result.block == null);
}

test "handleGetBlockByHash: returns genesis by hash" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var state = try setupCtx(allocator);
    defer state.deinit(allocator);

    const genesis = (try state.bc.getBlockByNumber(0)).?;
    var ctx = state.getCtx();
    const result = try block_query_handlers.handleGetBlockByHash(
        arena.allocator(),
        &ctx,
        .{
            .block_hash = .{ .bytes = genesis.hash },
            .hydrated_transactions = false,
        },
    );
    try std.testing.expect(result.block != null);
}

// ============================================================================
// eth_getTransactionReceipt tests
// ============================================================================

test "handleGetTransactionReceipt: returns null for missing tx" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var state = try setupCtx(allocator);
    defer state.deinit(allocator);

    var ctx = state.getCtx();
    const result = try block_query_handlers.handleGetTransactionReceipt(
        arena.allocator(),
        &ctx,
        .{ .transaction_hash = .{ .bytes = [_]u8{0xff} ** 32 } },
    );
    try std.testing.expect(result.value == null);
}

test "handleGetTransactionReceipt: preserves log data and topics" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var state = try setupCtx(allocator);
    defer state.deinit(allocator);

    const genesis = (try state.bc.getBlockByNumber(0)).?;
    var tx_hash: [32]u8 = undefined;
    @memset(&tx_hash, 0x11);
    var topic: [32]u8 = undefined;
    @memset(&topic, 0xaa);

    var receipt = try makeReceiptWithSingleLog(
        allocator,
        tx_hash,
        genesis.hash,
        0,
        topic,
        &[_]u8{ 0xde, 0xad, 0xbe, 0xef },
    );
    defer receipt.deinit(allocator);
    try state.ri.putBlockReceipts(allocator, genesis.hash, &[_]primitives.Receipt.Receipt{receipt});

    var ctx = state.getCtx();
    const result = try block_query_handlers.handleGetTransactionReceipt(
        arena.allocator(),
        &ctx,
        .{ .transaction_hash = .{ .bytes = tx_hash } },
    );
    const rpc_receipt = result.value orelse return error.ExpectedReceipt;
    try std.testing.expectEqual(@as(usize, 1), rpc_receipt.logs.len);

    const rpc_log = rpc_receipt.logs[0];
    try std.testing.expectEqual(@as(usize, 1), rpc_log.topics.len);
    try std.testing.expectEqual(topic, rpc_log.topics[0].bytes);

    switch (rpc_log.data.value) {
        .string => |data_hex| try std.testing.expectEqualStrings("0xdeadbeef", data_hex),
        else => return error.ExpectedHexDataString,
    }
}

// ============================================================================
// eth_getBlockReceipts tests
// ============================================================================

test "handleGetBlockReceipts: returns null for missing block" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var state = try setupCtx(allocator);
    defer state.deinit(allocator);

    var ctx = state.getCtx();
    const result = try block_query_handlers.handleGetBlockReceipts(
        arena.allocator(),
        &ctx,
        .{ .block = makeBlockSpec("0x999") },
    );
    try std.testing.expect(result.value == null);
}

// ============================================================================
// eth_getTransactionByHash tests
// ============================================================================

test "handleGetTransactionByHash: returns null for missing transaction hash" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var state = try setupCtx(allocator);
    defer state.deinit(allocator);

    var ctx = state.getCtx();
    const result = try block_query_handlers.handleGetTransactionByHash(
        arena.allocator(),
        &ctx,
        .{ .transaction_hash = .{ .bytes = [_]u8{0xaa} ** 32 } },
    );
    try std.testing.expect(result.value == null);
}

test "handleGetTransactionByHash: returns null for pending transaction hash" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var state = try setupCtx(allocator);
    defer state.deinit(allocator);

    const unsigned_tx = primitives.Transaction.LegacyTransaction{
        .nonce = 0,
        .gas_price = runtime.DEFAULT_GAS_PRICE,
        .gas_limit = 21_000,
        .to = runtime.DEFAULT_DEV_ACCOUNTS[1],
        .value = 1000,
        .data = &[_]u8{},
        .v = 0,
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
    };
    const signed_tx = try primitives.Transaction.signLegacyTransaction(
        allocator,
        unsigned_tx,
        runtime.DEFAULT_DEV_PRIVATE_KEYS[0],
        runtime.DEFAULT_CHAIN_ID,
    );
    const raw_tx = try primitives.Transaction.encodeLegacyForSigning(allocator, signed_tx, runtime.DEFAULT_CHAIN_ID);
    defer allocator.free(raw_tx);

    var tx_hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(raw_tx, &tx_hash, .{});
    try state.rt.putTransactionRecord(allocator, tx_hash, runtime.DEFAULT_DEV_ACCOUNTS[0], raw_tx);

    var ctx = state.getCtx();
    const result = try block_query_handlers.handleGetTransactionByHash(
        arena.allocator(),
        &ctx,
        .{ .transaction_hash = .{ .bytes = tx_hash } },
    );
    try std.testing.expect(result.value == null);
}

test "handleGetTransactionByHash: returns mined legacy transaction" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var state = try setupCtx(allocator);
    defer state.deinit(allocator);

    const unsigned_tx = primitives.Transaction.LegacyTransaction{
        .nonce = 0,
        .gas_price = runtime.DEFAULT_GAS_PRICE,
        .gas_limit = 21_000,
        .to = runtime.DEFAULT_DEV_ACCOUNTS[1],
        .value = 1000,
        .data = &[_]u8{},
        .v = 0,
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
    };
    const signed_tx = try primitives.Transaction.signLegacyTransaction(
        allocator,
        unsigned_tx,
        runtime.DEFAULT_DEV_PRIVATE_KEYS[0],
        runtime.DEFAULT_CHAIN_ID,
    );
    const raw_tx = try primitives.Transaction.encodeLegacyForSigning(allocator, signed_tx, runtime.DEFAULT_CHAIN_ID);
    defer allocator.free(raw_tx);

    var tx_hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(raw_tx, &tx_hash, .{});
    try state.rt.putTransactionRecord(allocator, tx_hash, runtime.DEFAULT_DEV_ACCOUNTS[0], raw_tx);

    var mined_block_hash: [32]u8 = undefined;
    @memset(&mined_block_hash, 0x44);
    state.rt.markTransactionMined(tx_hash, mined_block_hash, 1, 1000, 0);

    var ctx = state.getCtx();
    const result = try block_query_handlers.handleGetTransactionByHash(
        arena.allocator(),
        &ctx,
        .{ .transaction_hash = .{ .bytes = tx_hash } },
    );
    try std.testing.expect(result.value != null);

    switch (result.value.?) {
        .legacy => |tx| {
            try std.testing.expectEqual(@as(u64, 0), tx.nonce);
            try std.testing.expectEqual(@as(u64, 21_000), tx.gas);
            try std.testing.expectEqual(runtime.DEFAULT_DEV_ACCOUNTS[0].bytes, tx.metadata.from.bytes);
            try std.testing.expect(tx.metadata.block_hash != null);
            try std.testing.expectEqual(mined_block_hash, tx.metadata.block_hash.?.bytes);
            try std.testing.expectEqual(@as(u64, 1), tx.metadata.block_number);
            try std.testing.expectEqual(@as(u64, 1000), tx.metadata.block_timestamp);
            try std.testing.expectEqual(@as(u64, 0), tx.metadata.transaction_index);
            try std.testing.expectEqual(tx_hash, tx.metadata.hash.bytes);
        },
        else => return error.ExpectedLegacyTransaction,
    }
}

// ============================================================================
// eth_getLogs tests
// ============================================================================

test "handleGetLogs: returns empty for empty chain" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var state = try setupCtx(allocator);
    defer state.deinit(allocator);

    var ctx = state.getCtx();
    // Parse filter from JSON like a real request would
    const filter_json =
        \\[{"fromBlock":"0x0","toBlock":"0x0"}]
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), filter_json, .{});
    const params = try std.json.innerParseFromValue(
        jsonrpc.eth.GetLogs.Params,
        arena.allocator(),
        parsed.value,
        .{},
    );
    const result = try block_query_handlers.handleGetLogs(
        arena.allocator(),
        &ctx,
        params,
    );
    try std.testing.expectEqual(@as(usize, 0), result.logs.len);
}

test "handleGetLogs: preserves log data and topics" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var state = try setupCtx(allocator);
    defer state.deinit(allocator);

    const genesis = (try state.bc.getBlockByNumber(0)).?;
    var tx_hash: [32]u8 = undefined;
    @memset(&tx_hash, 0x22);
    var topic: [32]u8 = undefined;
    @memset(&topic, 0xbb);

    var receipt = try makeReceiptWithSingleLog(
        allocator,
        tx_hash,
        genesis.hash,
        0,
        topic,
        &[_]u8{ 0xca, 0xfe },
    );
    defer receipt.deinit(allocator);
    try state.li.appendBlockLogs(allocator, 0, genesis.hash, &[_]primitives.Receipt.Receipt{receipt});

    var ctx = state.getCtx();
    const filter_json =
        \\[{"fromBlock":"0x0","toBlock":"0x0"}]
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), filter_json, .{});
    const params = try std.json.innerParseFromValue(
        jsonrpc.eth.GetLogs.Params,
        arena.allocator(),
        parsed.value,
        .{},
    );
    const result = try block_query_handlers.handleGetLogs(
        arena.allocator(),
        &ctx,
        params,
    );
    try std.testing.expectEqual(@as(usize, 1), result.logs.len);

    const rpc_log = result.logs[0];
    try std.testing.expectEqual(@as(usize, 1), rpc_log.topics.len);
    try std.testing.expectEqual(topic, rpc_log.topics[0].bytes);

    switch (rpc_log.data.value) {
        .string => |data_hex| try std.testing.expectEqualStrings("0xcafe", data_hex),
        else => return error.ExpectedHexDataString,
    }
}

test "handleGetLogs: invalid filter returns InvalidParams" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var state = try setupCtx(allocator);
    defer state.deinit(allocator);

    var ctx = state.getCtx();
    const filter_json =
        \\[{"fromBlock":"0x2","toBlock":"0x1"}]
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), filter_json, .{});
    const params = try std.json.innerParseFromValue(
        jsonrpc.eth.GetLogs.Params,
        arena.allocator(),
        parsed.value,
        .{},
    );
    try std.testing.expectError(
        error.InvalidParams,
        block_query_handlers.handleGetLogs(
            arena.allocator(),
            &ctx,
            params,
        ),
    );
}

test "handleGetLogs: malformed block range quantity returns InvalidParams" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var state = try setupCtx(allocator);
    defer state.deinit(allocator);

    var ctx = state.getCtx();
    const filter_json =
        \\[{"fromBlock":"0xZZ","toBlock":"0x1"}]
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), filter_json, .{});
    const params = try std.json.innerParseFromValue(
        jsonrpc.eth.GetLogs.Params,
        arena.allocator(),
        parsed.value,
        .{},
    );
    try std.testing.expectError(
        error.InvalidParams,
        block_query_handlers.handleGetLogs(
            arena.allocator(),
            &ctx,
            params,
        ),
    );
}

test "handleGetBlockByNumber: invalid block spec returns InvalidParams" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var state = try setupCtx(allocator);
    defer state.deinit(allocator);

    var ctx = state.getCtx();
    try std.testing.expectError(
        error.InvalidParams,
        block_query_handlers.handleGetBlockByNumber(
            arena.allocator(),
            &ctx,
            .{ .block = makeBlockSpec("garbage"), .hydrated_transactions = false },
        ),
    );
}
