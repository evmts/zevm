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
