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

fn addBlock(
    allocator: std.mem.Allocator,
    bc: *blockchain_mod.Blockchain,
    parent_hash: [32]u8,
    number: u64,
) !primitives.Block.Block {
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

fn makeTestReceipt(
    allocator: std.mem.Allocator,
    tx_hash: [32]u8,
    block_hash: [32]u8,
    block_number: u64,
) !primitives.Receipt.Receipt {
    const logs = try allocator.alloc(primitives.EventLog.EventLog, 0);
    var bloom: [256]u8 = undefined;
    @memset(&bloom, 0);

    return .{
        .transaction_hash = tx_hash,
        .transaction_index = 0,
        .block_hash = block_hash,
        .block_number = block_number,
        .sender = primitives.Address.ZERO_ADDRESS,
        .to = null,
        .cumulative_gas_used = 21_000,
        .gas_used = 21_000,
        .contract_address = null,
        .logs = logs,
        .logs_bloom = bloom,
        .status = primitives.Receipt.TransactionStatus{ .success = true, .gas_used = 21_000 },
        .root = null,
        .effective_gas_price = 1_000_000_000,
        .type = .legacy,
        .blob_gas_used = null,
        .blob_gas_price = null,
    };
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
        self.rt.deinit();
    }
} {
    var rt = try runtime.NodeRuntime.init(allocator, null);
    errdefer rt.deinit();

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
    try std.testing.expectEqualSlices(
        u8,
        &primitives.BlockHeader.EMPTY_OMMERS_HASH,
        &result.block.?.sha3Uncles.bytes,
    );
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

test "handleGetBlockByNumber: invalid selector is invalid params" {
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
            .{ .block = makeBlockSpec("not-a-selector"), .hydrated_transactions = false },
        ),
    );
}

test "handleGetBlockByNumber: allocator failure does not become null block" {
    const allocator = std.testing.allocator;

    var state = try setupCtx(allocator);
    defer state.deinit(allocator);

    var failing_allocator = std.testing.FailingAllocator.init(allocator, .{});
    failing_allocator.fail_index = failing_allocator.alloc_index;

    var ctx = state.getCtx();
    try std.testing.expectError(
        error.OutOfMemory,
        block_query_handlers.handleGetBlockByNumber(
            failing_allocator.allocator(),
            &ctx,
            .{ .block = makeBlockSpec("latest"), .hydrated_transactions = false },
        ),
    );
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

test "handleGetBlockReceipts: hash selector resolves exact historical block" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var state = try setupCtx(allocator);
    defer state.deinit(allocator);

    const genesis = (try state.bc.getBlockByNumber(0)).?;
    const block_one = try addBlock(allocator, &state.bc, genesis.hash, 1);
    const block_two = try addBlock(allocator, &state.bc, block_one.hash, 2);

    var receipt = try makeTestReceipt(allocator, [_]u8{0x11} ** 32, block_one.hash, 1);
    defer receipt.deinit(allocator);
    try state.ri.putBlockReceipts(allocator, block_one.hash, &[_]primitives.Receipt.Receipt{receipt});
    try state.ri.putBlockReceipts(allocator, block_two.hash, &.{});

    const hash_hex = std.fmt.bytesToHex(block_one.hash, .lower);
    const selector = try std.fmt.allocPrint(allocator, "0x{s}", .{hash_hex[0..]});
    defer allocator.free(selector);

    var ctx = state.getCtx();
    const result = try block_query_handlers.handleGetBlockReceipts(
        arena.allocator(),
        &ctx,
        .{ .block = makeBlockSpec(selector) },
    );

    try std.testing.expect(result.value != null);
    try std.testing.expectEqual(@as(usize, 1), result.value.?.len);
    try std.testing.expectEqualStrings("0x1", result.value.?[0].blockNumber.value.string);
    try std.testing.expectEqualSlices(u8, &block_one.hash, &result.value.?[0].blockHash.bytes);
}

// ============================================================================
// eth_getTransactionByHash tests
// ============================================================================

test "handleGetTransactionByHash: returns null (no tx index yet)" {
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

test "handleGetLogs: allocator failure does not become empty logs" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var state = try setupCtx(allocator);
    defer state.deinit(allocator);

    const filter_json =
        \\[{"fromBlock":"0x0","toBlock":"0x0","address":"0x0000000000000000000000000000000000000000"}]
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), filter_json, .{});
    const params = try std.json.innerParseFromValue(
        jsonrpc.eth.GetLogs.Params,
        arena.allocator(),
        parsed.value,
        .{},
    );

    var failing_allocator = std.testing.FailingAllocator.init(allocator, .{});
    failing_allocator.fail_index = failing_allocator.alloc_index;

    var ctx = state.getCtx();
    try std.testing.expectError(
        error.OutOfMemory,
        block_query_handlers.handleGetLogs(
            failing_allocator.allocator(),
            &ctx,
            params,
        ),
    );
}
