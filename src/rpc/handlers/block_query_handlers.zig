const std = @import("std");
const jsonrpc = @import("jsonrpc");
const primitives = @import("primitives");
const blockchain_mod = @import("blockchain");
const block_queries = @import("../block_queries.zig");
const log_index_mod = @import("../../log_index.zig");
const receipt_index_mod = @import("../../receipt_index.zig");
const block_spec = @import("block_spec.zig");
const runtime = @import("../../node/runtime.zig");

/// Context needed by block query handlers beyond NodeRuntime.
pub const BlockQueryContext = struct {
    rt: *runtime.NodeRuntime,
    blockchain: *blockchain_mod.Blockchain,
    receipt_index: *const receipt_index_mod.ReceiptIndex,
    log_index: *const log_index_mod.LogIndex,
};

// ============================================================================
// eth_getBlockByNumber
// ============================================================================

pub fn handleGetBlockByNumber(
    allocator: std.mem.Allocator,
    ctx: *const BlockQueryContext,
    params: jsonrpc.eth.GetBlockByNumber.Params,
) !jsonrpc.eth.GetBlockByNumber.Result {
    const tag = blockSpecToTag(allocator, params.block) catch return .{ .block = null };
    defer allocator.free(tag);

    const internal = block_queries.getBlockByNumber(allocator, ctx.blockchain, tag, params.hydrated_transactions) catch return .{ .block = null };
    if (internal) |resp| {
        return .{ .block = internalBlockToRpc(allocator, resp) catch return .{ .block = null } };
    }
    return .{ .block = null };
}

// ============================================================================
// eth_getBlockByHash
// ============================================================================

pub fn handleGetBlockByHash(
    allocator: std.mem.Allocator,
    ctx: *const BlockQueryContext,
    params: jsonrpc.eth.GetBlockByHash.Params,
) !jsonrpc.eth.GetBlockByHash.Result {
    const internal = block_queries.getBlockByHash(allocator, ctx.blockchain, params.block_hash.bytes, params.hydrated_transactions) catch return .{ .block = null };
    if (internal) |resp| {
        return .{ .block = internalBlockToRpc(allocator, resp) catch return .{ .block = null } };
    }
    return .{ .block = null };
}

// ============================================================================
// eth_getTransactionReceipt
// ============================================================================

pub fn handleGetTransactionReceipt(
    allocator: std.mem.Allocator,
    ctx: *const BlockQueryContext,
    params: jsonrpc.eth.GetTransactionReceipt.Params,
) !jsonrpc.eth.GetTransactionReceipt.Result {
    const internal = block_queries.getTransactionReceipt(allocator, ctx.receipt_index, params.transaction_hash.bytes) catch return .{ .value = null };
    if (internal) |resp| {
        return .{ .value = internalReceiptToRpc(allocator, resp) catch return .{ .value = null } };
    }
    return .{ .value = null };
}

// ============================================================================
// eth_getBlockReceipts
// ============================================================================

pub fn handleGetBlockReceipts(
    allocator: std.mem.Allocator,
    ctx: *const BlockQueryContext,
    params: jsonrpc.eth.GetBlockReceipts.Params,
) !jsonrpc.eth.GetBlockReceipts.Result {
    const tag = blockSpecToTag(allocator, params.block) catch return .{ .value = null };
    defer allocator.free(tag);

    const internal = block_queries.getBlockReceipts(allocator, ctx.blockchain, ctx.receipt_index, tag) catch return .{ .value = null };
    if (internal) |resps| {
        defer allocator.free(resps);
        const rpc_receipts = allocator.alloc(jsonrpc.types.ReceiptResponse, resps.len) catch return .{ .value = null };
        for (resps, 0..) |resp, i| {
            rpc_receipts[i] = internalReceiptToRpc(allocator, resp) catch return .{ .value = null };
        }
        return .{ .value = rpc_receipts };
    }
    return .{ .value = null };
}

// ============================================================================
// eth_getLogs
// ============================================================================

pub fn handleGetLogs(
    allocator: std.mem.Allocator,
    ctx: *const BlockQueryContext,
    params: jsonrpc.eth.GetLogs.Params,
) !jsonrpc.eth.GetLogs.Result {
    const filter = rpcFilterToInternal(allocator, params.filter) catch return .{ .logs = &.{} };

    const internal = block_queries.getLogs(allocator, ctx.blockchain, ctx.log_index, filter) catch return .{ .logs = &.{} };
    defer allocator.free(internal);

    const rpc_logs = allocator.alloc(jsonrpc.types.LogEntry, internal.len) catch return .{ .logs = &.{} };
    for (internal, 0..) |resp, i| {
        rpc_logs[i] = internalLogToRpc(allocator, resp) catch return .{ .logs = &.{} };
    }
    return .{ .logs = rpc_logs };
}

// ============================================================================
// eth_getTransactionByHash (stub — no tx index exists yet)
// ============================================================================

pub fn handleGetTransactionByHash(
    _: std.mem.Allocator,
    _: *const BlockQueryContext,
    _: jsonrpc.eth.GetTransactionByHash.Params,
) !jsonrpc.eth.GetTransactionByHash.Result {
    return .{ .value = null };
}

// ============================================================================
// Conversion Helpers
// ============================================================================

fn blockSpecToTag(allocator: std.mem.Allocator, spec: jsonrpc.types.BlockSpec) ![]u8 {
    switch (spec.value) {
        .string => |s| return try allocator.dupe(u8, s),
        .integer => |n| {
            if (n < 0) return error.InvalidBlockSpec;
            return try std.fmt.allocPrint(allocator, "0x{x}", .{@as(u64, @intCast(n))});
        },
        else => return error.InvalidBlockSpec,
    }
}

fn quantityFromU64(allocator: std.mem.Allocator, n: u64) !jsonrpc.types.Quantity {
    return .{ .value = .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{n}) } };
}

fn quantityFromU256(allocator: std.mem.Allocator, n: u256) !jsonrpc.types.Quantity {
    return .{ .value = .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{n}) } };
}

fn hashToRpc(h: [32]u8) jsonrpc.types.Hash {
    return .{ .bytes = h };
}

fn addrToRpc(a: primitives.Address) jsonrpc.types.Address {
    return .{ .bytes = a.bytes };
}

fn optAddrToRpc(a: ?primitives.Address) ?jsonrpc.types.Address {
    if (a) |addr| return .{ .bytes = addr.bytes };
    return null;
}

fn internalBlockToRpc(
    allocator: std.mem.Allocator,
    resp: block_queries.BlockResponse,
) !jsonrpc.types.BlockResponse.BlockResponse {
    const txs = try allocator.alloc(jsonrpc.types.TransactionInfo.TransactionInfo, switch (resp.transactions) {
        .hashes => |h| h.len,
        .full => |f| f.len,
    });

    switch (resp.transactions) {
        .hashes => |hashes| {
            for (hashes, 0..) |h, i| {
                txs[i] = .{ .hash = hashToRpc(h) };
            }
        },
        .full => |full| {
            for (full, 0..) |tx, i| {
                txs[i] = .{
                    .full = .{
                        .type = .legacy,
                        .hash = hashToRpc(tx.hash),
                        .nonce = try quantityFromU64(allocator, tx.nonce),
                        .blockHash = hashToRpc(tx.blockHash orelse [_]u8{0} ** 32),
                        .blockNumber = try quantityFromU64(allocator, tx.blockNumber orelse 0),
                        .transactionIndex = try quantityFromU64(allocator, tx.transactionIndex orelse 0),
                        .from = addrToRpc(tx.from),
                        .to = optAddrToRpc(tx.to),
                        .value = try quantityFromU256(allocator, tx.value),
                        .gas = try quantityFromU64(allocator, tx.gas),
                        .input = .{ .value = .{ .string = "0x" } },
                    },
                };
            }
        },
    }

    return .{
        .hash = hashToRpc(resp.hash),
        .parentHash = hashToRpc(resp.parentHash),
        .sha3Uncles = hashToRpc([_]u8{0} ** 32),
        .miner = addrToRpc(resp.miner),
        .stateRoot = hashToRpc(resp.stateRoot),
        .transactionsRoot = hashToRpc(resp.transactionsRoot),
        .receiptsRoot = hashToRpc(resp.receiptsRoot),
        .logsBloom = .{ .bytes = resp.logsBloom },
        .number = try quantityFromU64(allocator, resp.number),
        .gasLimit = try quantityFromU64(allocator, resp.gasLimit),
        .gasUsed = try quantityFromU64(allocator, resp.gasUsed),
        .timestamp = try quantityFromU64(allocator, resp.timestamp),
        .extraData = .{ .value = .{ .string = "0x" } },
        .mixHash = hashToRpc(resp.mixHash),
        .nonce = .{ .bytes = resp.nonce },
        .size = try quantityFromU64(allocator, resp.size),
        .transactions = txs,
        .uncles = &.{},
        .difficulty = if (resp.difficulty > 0) try quantityFromU256(allocator, resp.difficulty) else null,
        .totalDifficulty = if (resp.totalDifficulty) |td| try quantityFromU256(allocator, td) else null,
        .baseFeePerGas = if (resp.baseFeePerGas) |bfpg| try quantityFromU256(allocator, bfpg) else null,
        .withdrawalsRoot = if (resp.withdrawalsRoot) |wr| hashToRpc(wr) else null,
        .blobGasUsed = if (resp.blobGasUsed) |bgu| try quantityFromU64(allocator, bgu) else null,
        .excessBlobGas = if (resp.excessBlobGas) |ebg| try quantityFromU64(allocator, ebg) else null,
        .parentBeaconBlockRoot = if (resp.parentBeaconBlockRoot) |pbbr| hashToRpc(pbbr) else null,
    };
}

fn internalReceiptToRpc(
    allocator: std.mem.Allocator,
    resp: block_queries.ReceiptResponse,
) !jsonrpc.types.ReceiptResponse {
    const rpc_logs = try allocator.alloc(jsonrpc.types.LogEntry, resp.logs.len);
    for (resp.logs, 0..) |log, i| {
        rpc_logs[i] = .{
            .removed = log.removed,
            .logIndex = if (log.logIndex) |li| try quantityFromU64(allocator, li) else null,
            .transactionIndex = if (log.transactionIndex) |ti| try quantityFromU64(allocator, ti) else null,
            .transactionHash = if (log.transactionHash) |th| hashToRpc(th) else hashToRpc([_]u8{0} ** 32),
            .blockHash = hashToRpc(log.blockHash),
            .blockNumber = if (log.blockNumber) |bn| try quantityFromU64(allocator, bn) else null,
            .address = addrToRpc(log.address),
            .data = .{ .value = .{ .string = "0x" } },
            .topics = &.{},
        };
    }

    return .{
        .transactionHash = hashToRpc(resp.transactionHash),
        .transactionIndex = resp.transactionIndex,
        .blockHash = hashToRpc(resp.blockHash),
        .blockNumber = resp.blockNumber,
        .from = addrToRpc(resp.from),
        .to = optAddrToRpc(resp.to),
        .cumulativeGasUsed = @intCast(@min(resp.cumulativeGasUsed, std.math.maxInt(u64))),
        .gasUsed = @intCast(@min(resp.gasUsed, std.math.maxInt(u64))),
        .contractAddress = optAddrToRpc(resp.contractAddress),
        .logs = rpc_logs,
        .logsBloom = resp.logsBloom,
        .status = resp.status,
        .root = if (resp.root) |r| hashToRpc(r) else null,
        .effectiveGasPrice = @intCast(@min(resp.effectiveGasPrice, std.math.maxInt(u64))),
        .tx_type = resp.type_field,
        .blobGasUsed = if (resp.blobGasUsed) |bgu| @intCast(@min(bgu, std.math.maxInt(u64))) else null,
        .blobGasPrice = if (resp.blobGasPrice) |bgp| @intCast(@min(bgp, std.math.maxInt(u64))) else null,
    };
}

fn internalLogToRpc(
    allocator: std.mem.Allocator,
    resp: block_queries.LogResponse,
) !jsonrpc.types.LogEntry {
    const rpc_topics = try allocator.alloc(jsonrpc.types.Hash, resp.topics.len);
    for (resp.topics, 0..) |t, i| {
        rpc_topics[i] = hashToRpc(t);
    }

    return .{
        .removed = resp.removed,
        .logIndex = if (resp.logIndex) |li| try quantityFromU64(allocator, li) else null,
        .transactionIndex = if (resp.transactionIndex) |ti| try quantityFromU64(allocator, ti) else null,
        .transactionHash = if (resp.transactionHash) |th| hashToRpc(th) else hashToRpc([_]u8{0} ** 32),
        .blockHash = hashToRpc(resp.blockHash),
        .blockNumber = if (resp.blockNumber) |bn| try quantityFromU64(allocator, bn) else null,
        .address = addrToRpc(resp.address),
        .data = .{ .value = .{ .string = "0x" } },
        .topics = rpc_topics,
    };
}

fn rpcFilterToInternal(allocator: std.mem.Allocator, filter: anytype) !log_index_mod.LogFilter {
    var result: log_index_mod.LogFilter = .{};

    if (@hasField(@TypeOf(filter), "fromBlock")) {
        if (filter.fromBlock) |fb| {
            result.from_block = parseQuantityToU64(fb) catch null;
        }
    }
    if (@hasField(@TypeOf(filter), "toBlock")) {
        if (filter.toBlock) |tb| {
            result.to_block = parseQuantityToU64(tb) catch null;
        }
    }
    if (@hasField(@TypeOf(filter), "blockHash")) {
        if (filter.blockHash) |bh| {
            result.block_hash = bh.bytes;
        }
    }
    if (@hasField(@TypeOf(filter), "address")) {
        if (filter.address) |addr| {
            switch (addr) {
                .single => |a| {
                    const addrs = try allocator.alloc(primitives.Address.Address, 1);
                    addrs[0] = .{ .bytes = a.bytes };
                    result.addresses = addrs;
                },
                .array => |arr| {
                    const addrs = try allocator.alloc(primitives.Address.Address, arr.len);
                    for (arr, 0..) |a, i| {
                        addrs[i] = .{ .bytes = a.bytes };
                    }
                    result.addresses = addrs;
                },
            }
        }
    }
    if (@hasField(@TypeOf(filter), "topics")) {
        if (filter.topics) |topics| {
            const internal_topics = try allocator.alloc(?[]const [32]u8, topics.len);
            for (topics, 0..) |maybe_topic, i| {
                if (maybe_topic) |topic| {
                    switch (topic) {
                        .single => |h| {
                            const hashes = try allocator.alloc([32]u8, 1);
                            hashes[0] = h.bytes;
                            internal_topics[i] = hashes;
                        },
                        .array => |arr| {
                            const hashes = try allocator.alloc([32]u8, arr.len);
                            for (arr, 0..) |h, j| {
                                hashes[j] = h.bytes;
                            }
                            internal_topics[i] = hashes;
                        },
                    }
                } else {
                    internal_topics[i] = null;
                }
            }
            result.topics = internal_topics;
        }
    }

    return result;
}

fn parseQuantityToU64(q: jsonrpc.types.Quantity) !u64 {
    switch (q.value) {
        .string => |s| {
            if (s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
                return std.fmt.parseInt(u64, s[2..], 16) catch return error.InvalidQuantity;
            }
            return std.fmt.parseInt(u64, s, 10) catch return error.InvalidQuantity;
        },
        .integer => |n| {
            if (n < 0) return error.InvalidQuantity;
            return @intCast(n);
        },
        else => return error.InvalidQuantity,
    }
}

test {
    _ = @import("block_query_handlers_test.zig");
}
