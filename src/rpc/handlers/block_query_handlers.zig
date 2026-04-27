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
// eth_getBlockTransactionCountByHash
// ============================================================================

pub fn handleGetBlockTransactionCountByHash(
    allocator: std.mem.Allocator,
    ctx: *const BlockQueryContext,
    params: jsonrpc.eth.GetBlockTransactionCountByHash.Params,
) !jsonrpc.eth.GetBlockTransactionCountByHash.Result {
    const count = block_queries.getBlockTxCountByHash(ctx.blockchain, params.block_hash.bytes) catch return .{ .value = null };
    if (count) |n| {
        return .{ .value = quantityFromU64(allocator, n) catch return .{ .value = null } };
    }
    return .{ .value = null };
}

// ============================================================================
// eth_getBlockTransactionCountByNumber
// ============================================================================

pub fn handleGetBlockTransactionCountByNumber(
    allocator: std.mem.Allocator,
    ctx: *const BlockQueryContext,
    params: jsonrpc.eth.GetBlockTransactionCountByNumber.Params,
) !jsonrpc.eth.GetBlockTransactionCountByNumber.Result {
    const tag = blockSpecToTag(allocator, params.block) catch return .{ .value = null };
    defer allocator.free(tag);

    const count = block_queries.getBlockTxCountByNumber(ctx.blockchain, tag) catch return .{ .value = null };
    if (count) |n| {
        return .{ .value = quantityFromU64(allocator, n) catch return .{ .value = null } };
    }
    return .{ .value = null };
}

// ============================================================================
// eth_getUncleCountByBlockHash
// ============================================================================

pub fn handleGetUncleCountByBlockHash(
    allocator: std.mem.Allocator,
    ctx: *const BlockQueryContext,
    params: jsonrpc.eth.GetUncleCountByBlockHash.Params,
) !jsonrpc.eth.GetUncleCountByBlockHash.Result {
    const count = block_queries.getUncleCountByHash(ctx.blockchain, params.block_hash.bytes) catch return .{ .value = try zeroQuantity(allocator) };
    if (count) |n| {
        return .{ .value = try quantityFromU64(allocator, n) };
    }
    // Block not found: spec returns 0x0 (Result is non-nullable). Mirrors
    // post-Merge behavior where uncle counts are always zero.
    return .{ .value = try zeroQuantity(allocator) };
}

// ============================================================================
// eth_getUncleCountByBlockNumber
// ============================================================================

pub fn handleGetUncleCountByBlockNumber(
    allocator: std.mem.Allocator,
    ctx: *const BlockQueryContext,
    params: jsonrpc.eth.GetUncleCountByBlockNumber.Params,
) !jsonrpc.eth.GetUncleCountByBlockNumber.Result {
    const tag = blockSpecToTag(allocator, params.block) catch return .{ .value = try zeroQuantity(allocator) };
    defer allocator.free(tag);

    const count = block_queries.getUncleCountByNumber(ctx.blockchain, tag) catch return .{ .value = try zeroQuantity(allocator) };
    if (count) |n| {
        return .{ .value = try quantityFromU64(allocator, n) };
    }
    return .{ .value = try zeroQuantity(allocator) };
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
    const maybe_receipts = blockReceiptsFromSpec(allocator, ctx, params.block) catch return .{ .value = null };
    if (maybe_receipts) |resps| {
        defer allocator.free(resps);
        const rpc_receipts = allocator.alloc(jsonrpc.types.ReceiptResponse, resps.len) catch return .{ .value = null };
        for (resps, 0..) |resp, i| {
            rpc_receipts[i] = internalReceiptToRpc(allocator, resp) catch return .{ .value = null };
        }
        return .{ .value = rpc_receipts };
    }
    return .{ .value = null };
}

/// Resolve a BlockSpec to receipts. Accepts numbers/tags as a hex string and
/// 32-byte hashes (per execution-apis BlockSpec union).
fn blockReceiptsFromSpec(
    allocator: std.mem.Allocator,
    ctx: *const BlockQueryContext,
    spec: jsonrpc.types.BlockSpec,
) !?[]block_queries.ReceiptResponse {
    switch (spec.value) {
        .string => |s| {
            if (parseBlockHashString(s)) |hash_bytes| {
                return try block_queries.getBlockReceiptsByHash(allocator, ctx.blockchain, ctx.receipt_index, hash_bytes);
            }
            return try block_queries.getBlockReceipts(allocator, ctx.blockchain, ctx.receipt_index, s);
        },
        .integer => |n| {
            if (n < 0) return null;
            const tag = try std.fmt.allocPrint(allocator, "0x{x}", .{@as(u64, @intCast(n))});
            defer allocator.free(tag);
            return try block_queries.getBlockReceipts(allocator, ctx.blockchain, ctx.receipt_index, tag);
        },
        .object => |obj| {
            if (obj.get("blockHash")) |bh_value| {
                const bh_str = switch (bh_value) {
                    .string => |s| s,
                    else => return null,
                };
                const hash_bytes = parseBlockHashString(bh_str) orelse return null;
                return try block_queries.getBlockReceiptsByHash(allocator, ctx.blockchain, ctx.receipt_index, hash_bytes);
            }
            if (obj.get("blockNumber")) |bn_value| {
                switch (bn_value) {
                    .string => |s| return try block_queries.getBlockReceipts(allocator, ctx.blockchain, ctx.receipt_index, s),
                    else => return null,
                }
            }
            return null;
        },
        else => return null,
    }
}

fn parseBlockHashString(s: []const u8) ?[32]u8 {
    if (s.len != 66) return null;
    if (s[0] != '0' or (s[1] != 'x' and s[1] != 'X')) return null;
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s[2..]) catch return null;
    return out;
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
// eth_getTransactionByHash
// ============================================================================

pub fn handleGetTransactionByHash(
    allocator: std.mem.Allocator,
    ctx: *const BlockQueryContext,
    params: jsonrpc.eth.GetTransactionByHash.Params,
) !jsonrpc.eth.GetTransactionByHash.Result {
    const internal = block_queries.getTransactionByHash(
        allocator,
        ctx.blockchain,
        ctx.receipt_index,
        params.transaction_hash.bytes,
    ) catch return .{ .value = null };
    if (internal) |tx| {
        return .{ .value = internalTxToRpc(allocator, tx) catch return .{ .value = null } };
    }
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

fn zeroQuantity(allocator: std.mem.Allocator) !jsonrpc.types.Quantity {
    return .{ .value = .{ .string = try allocator.dupe(u8, "0x0") } };
}

fn dataHexBytes(allocator: std.mem.Allocator, bytes: []const u8) !jsonrpc.types.Quantity {
    if (bytes.len == 0) {
        return .{ .value = .{ .string = try allocator.dupe(u8, "0x") } };
    }
    const out = try allocator.alloc(u8, 2 + bytes.len * 2);
    out[0] = '0';
    out[1] = 'x';
    const alphabet = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        out[2 + i * 2] = alphabet[(byte >> 4) & 0x0f];
        out[2 + i * 2 + 1] = alphabet[byte & 0x0f];
    }
    return .{ .value = .{ .string = out } };
}

fn hashToRpc(h: [32]u8) jsonrpc.types.Hash {
    return .{ .bytes = h };
}

fn addrToRpc(a: primitives.Address.Address) jsonrpc.types.Address {
    return .{ .bytes = a.bytes };
}

fn optAddrToRpc(a: ?primitives.Address.Address) ?jsonrpc.types.Address {
    if (a) |addr| return .{ .bytes = addr.bytes };
    return null;
}

fn txTypeToRpc(t: u8) jsonrpc.types.TransactionType {
    return switch (t) {
        0 => .legacy,
        1 => .eip2930,
        2 => .eip1559,
        3 => .eip4844,
        4 => .eip7702,
        else => .legacy,
    };
}

fn internalBlockToRpc(
    allocator: std.mem.Allocator,
    resp: block_queries.BlockResponse,
) !jsonrpc.types.BlockResponse {
    const tx_count: usize = switch (resp.transactions) {
        .hashes => |h| h.len,
        .full => |f| f.len,
    };
    const txs = try allocator.alloc(jsonrpc.types.TransactionInfo, tx_count);

    switch (resp.transactions) {
        .hashes => |hashes| {
            for (hashes, 0..) |h, i| {
                txs[i] = .{ .hash = hashToRpc(h) };
            }
        },
        .full => |full| {
            for (full, 0..) |tx, i| {
                txs[i] = .{ .full = try internalTxToRpc(allocator, tx) };
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
        .extraData = try dataHexBytes(allocator, resp.extraData),
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

fn internalTxToRpc(
    allocator: std.mem.Allocator,
    tx: block_queries.TxResponse,
) !jsonrpc.types.TransactionResponse {
    var access_list: ?[]const jsonrpc.types.AccessListEntry = null;
    if (tx.access_list) |entries| {
        const out = try allocator.alloc(jsonrpc.types.AccessListEntry, entries.len);
        for (entries, 0..) |entry, i| {
            const keys = try allocator.alloc(jsonrpc.types.Hash, entry.storage_keys.len);
            for (entry.storage_keys, 0..) |k, j| {
                keys[j] = hashToRpc(k);
            }
            out[i] = .{
                .address = addrToRpc(entry.address),
                .storageKeys = keys,
            };
        }
        access_list = out;
    }

    var blob_hashes: ?[]const jsonrpc.types.Hash = null;
    if (tx.blob_versioned_hashes) |hashes| {
        const out = try allocator.alloc(jsonrpc.types.Hash, hashes.len);
        for (hashes, 0..) |h, i| {
            out[i] = hashToRpc(h);
        }
        blob_hashes = out;
    }

    var auth_list: ?[]const jsonrpc.types.AuthorizationEntry = null;
    if (tx.authorization_list) |entries| {
        const out = try allocator.alloc(jsonrpc.types.AuthorizationEntry, entries.len);
        for (entries, 0..) |entry, i| {
            out[i] = .{
                .chainId = try quantityFromU256(allocator, entry.chain_id),
                .nonce = try quantityFromU64(allocator, entry.nonce),
                .address = addrToRpc(entry.address),
                .yParity = try quantityFromU64(allocator, @as(u64, @intCast(entry.y_parity))),
                .r = try quantityFromU256(allocator, entry.r),
                .s = try quantityFromU256(allocator, entry.s),
            };
        }
        auth_list = out;
    }

    return .{
        .type = txTypeToRpc(tx.type_field),
        .hash = hashToRpc(tx.hash),
        .nonce = try quantityFromU64(allocator, tx.nonce),
        .blockHash = hashToRpc(tx.blockHash orelse [_]u8{0} ** 32),
        .blockNumber = try quantityFromU64(allocator, tx.blockNumber orelse 0),
        .transactionIndex = try quantityFromU64(allocator, @as(u64, @intCast(tx.transactionIndex orelse 0))),
        .from = addrToRpc(tx.from),
        .to = optAddrToRpc(tx.to),
        .value = try quantityFromU256(allocator, tx.value),
        .gas = try quantityFromU64(allocator, tx.gas),
        .input = try dataHexBytes(allocator, tx.input),
        .gasPrice = if (tx.gas_price) |gp| try quantityFromU256(allocator, gp) else null,
        .maxPriorityFeePerGas = if (tx.max_priority_fee_per_gas) |mp| try quantityFromU256(allocator, mp) else null,
        .maxFeePerGas = if (tx.max_fee_per_gas) |mf| try quantityFromU256(allocator, mf) else null,
        .maxFeePerBlobGas = if (tx.max_fee_per_blob_gas) |mb| try quantityFromU256(allocator, mb) else null,
        .accessList = access_list,
        .blobVersionedHashes = blob_hashes,
        .chainId = if (tx.chain_id) |c| try quantityFromU64(allocator, c) else null,
        .authorizationList = auth_list,
        .yParity = if (tx.y_parity) |yp| try quantityFromU64(allocator, @as(u64, @intCast(yp))) else null,
        .v = if (tx.v) |v| try quantityFromU256(allocator, v) else null,
        .r = if (tx.r) |r| try quantityFromU256(allocator, r) else null,
        .s = if (tx.s) |s| try quantityFromU256(allocator, s) else null,
    };
}

fn internalReceiptToRpc(
    allocator: std.mem.Allocator,
    resp: block_queries.ReceiptResponse,
) !jsonrpc.types.ReceiptResponse {
    const rpc_logs = try allocator.alloc(jsonrpc.types.LogEntry, resp.logs.len);
    for (resp.logs, 0..) |log, i| {
        rpc_logs[i] = try internalLogToRpc(allocator, log);
    }

    return .{
        .transactionHash = hashToRpc(resp.transactionHash),
        .transactionIndex = try quantityFromU64(allocator, @as(u64, @intCast(resp.transactionIndex))),
        .blockHash = hashToRpc(resp.blockHash),
        .blockNumber = try quantityFromU64(allocator, resp.blockNumber),
        .from = addrToRpc(resp.from),
        .to = optAddrToRpc(resp.to),
        .cumulativeGasUsed = try quantityFromU256(allocator, resp.cumulativeGasUsed),
        .gasUsed = try quantityFromU256(allocator, resp.gasUsed),
        .contractAddress = optAddrToRpc(resp.contractAddress),
        .logs = rpc_logs,
        .logsBloom = .{ .bytes = resp.logsBloom },
        .status = if (resp.status) |s| try quantityFromU64(allocator, @as(u64, @intCast(s))) else null,
        .root = if (resp.root) |r| hashToRpc(r) else null,
        .effectiveGasPrice = try quantityFromU256(allocator, resp.effectiveGasPrice),
        .type = try quantityFromU64(allocator, @as(u64, @intCast(resp.type_field))),
        .blobGasUsed = if (resp.blobGasUsed) |bgu| try quantityFromU256(allocator, bgu) else null,
        .blobGasPrice = if (resp.blobGasPrice) |bgp| try quantityFromU256(allocator, bgp) else null,
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
        .logIndex = if (resp.logIndex) |li| try quantityFromU64(allocator, @as(u64, @intCast(li))) else null,
        .transactionIndex = if (resp.transactionIndex) |ti| try quantityFromU64(allocator, @as(u64, @intCast(ti))) else null,
        .transactionHash = if (resp.transactionHash) |th| hashToRpc(th) else hashToRpc([_]u8{0} ** 32),
        .blockHash = hashToRpc(resp.blockHash),
        .blockNumber = if (resp.blockNumber) |bn| try quantityFromU64(allocator, bn) else null,
        .address = addrToRpc(resp.address),
        .data = try dataHexBytes(allocator, resp.data),
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
