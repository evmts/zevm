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
    const block_number = block_spec.resolveBlockNumber(ctx.rt, params.block) catch |err| switch (err) {
        error.InvalidBlockSpec => return error.InvalidParams,
        error.BlockOutOfRange => return .{ .block = null },
    };
    const block = try ctx.rt.getBlockByNumberWithFork(allocator, block_number);
    if (block) |resolved_block| {
        const internal = try block_queries.blockToResponseFromBlock(
            allocator,
            resolved_block,
            params.hydrated_transactions,
        );
        return .{ .block = try internalBlockToRpc(allocator, internal) };
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
    const block = try ctx.rt.getBlockByHashWithFork(allocator, params.block_hash.bytes);
    if (block) |resolved_block| {
        const internal = try block_queries.blockToResponseFromBlock(
            allocator,
            resolved_block,
            params.hydrated_transactions,
        );
        return .{ .block = try internalBlockToRpc(allocator, internal) };
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
    const internal = try block_queries.getTransactionReceipt(allocator, ctx.receipt_index, params.transaction_hash.bytes);
    if (internal) |resp| {
        return .{ .value = try internalReceiptToRpc(allocator, resp) };
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
    const block_number = block_spec.resolveBlockNumber(ctx.rt, params.block) catch |err| switch (err) {
        error.InvalidBlockSpec => return error.InvalidParams,
        error.BlockOutOfRange => return .{ .value = null },
    };
    const block = try ctx.rt.getBlockByNumberWithFork(allocator, block_number);
    if (block == null) return .{ .value = null };

    const receipts = ctx.receipt_index.getByBlockHash(block.?.hash) orelse return .{ .value = null };
    const internal = try allocator.alloc(block_queries.ReceiptResponse, receipts.len);
    defer allocator.free(internal);
    for (receipts, 0..) |receipt, i| {
        internal[i] = try block_queries.receiptToResponse(allocator, receipt);
    }

    const rpc_receipts = try allocator.alloc(jsonrpc.types.ReceiptResponse, internal.len);
    for (internal, 0..) |resp, i| {
        rpc_receipts[i] = try internalReceiptToRpc(allocator, resp);
    }
    return .{ .value = rpc_receipts };
}

// ============================================================================
// eth_getLogs
// ============================================================================

pub fn handleGetLogs(
    allocator: std.mem.Allocator,
    ctx: *const BlockQueryContext,
    params: jsonrpc.eth.GetLogs.Params,
) !jsonrpc.eth.GetLogs.Result {
    const filter = rpcFilterToInternal(allocator, params.filter) catch return error.InvalidParams;

    const internal = block_queries.getLogs(allocator, ctx.blockchain, ctx.log_index, filter) catch |err| switch (err) {
        error.InvalidFilter => return error.InvalidParams,
        else => return err,
    };
    defer allocator.free(internal);

    const rpc_logs = try allocator.alloc(jsonrpc.types.LogEntry, internal.len);
    for (internal, 0..) |resp, i| {
        rpc_logs[i] = try internalLogToRpc(allocator, resp);
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
    const record = ctx.rt.getTransactionRecord(params.transaction_hash.bytes) orelse return .{ .value = null };
    const decoded = try primitives.Transaction.decodeRawTransaction(allocator, record.raw);
    defer primitives.Transaction.deinitDecodedTransaction(allocator, decoded);

    const metadata = jsonrpc.types.TransactionResponse.Metadata{
        .block_hash = if (record.block_hash) |h| .{ .bytes = h } else null,
        .block_number = record.block_number,
        .block_timestamp = record.block_timestamp,
        .transaction_index = record.transaction_index,
        .from = .{ .bytes = record.sender.bytes },
        .hash = .{ .bytes = params.transaction_hash.bytes },
    };

    return .{
        .value = switch (decoded) {
            .legacy => |tx| .{
                .legacy = .{
                    .metadata = metadata,
                    .nonce = tx.nonce,
                    .gas_price = tx.gas_price,
                    .gas = tx.gas_limit,
                    .to = if (tx.to) |to| .{ .bytes = to.bytes } else null,
                    .value = tx.value,
                    .input = try allocator.dupe(u8, tx.data),
                    .v = tx.v,
                    .r = tx.r,
                    .s = tx.s,
                    .chain_id = ctx.rt.chain_id,
                },
            },
            .eip2930 => |tx| .{
                .eip2930 = .{
                    .metadata = metadata,
                    .chain_id = tx.chain_id,
                    .nonce = tx.nonce,
                    .gas_price = tx.gas_price,
                    .gas = tx.gas_limit,
                    .to = if (tx.to) |to| .{ .bytes = to.bytes } else null,
                    .value = tx.value,
                    .input = try allocator.dupe(u8, tx.data),
                    .access_list = try toResponseAccessList(allocator, tx.access_list),
                    .y_parity = tx.y_parity,
                    .r = tx.r,
                    .s = tx.s,
                },
            },
            .eip1559 => |tx| .{
                .eip1559 = .{
                    .metadata = metadata,
                    .chain_id = tx.chain_id,
                    .nonce = tx.nonce,
                    .max_priority_fee_per_gas = tx.max_priority_fee_per_gas,
                    .max_fee_per_gas = tx.max_fee_per_gas,
                    .gas = tx.gas_limit,
                    .to = if (tx.to) |to| .{ .bytes = to.bytes } else null,
                    .value = tx.value,
                    .input = try allocator.dupe(u8, tx.data),
                    .access_list = try toResponseAccessList(allocator, tx.access_list),
                    .y_parity = tx.y_parity,
                    .r = tx.r,
                    .s = tx.s,
                },
            },
            .eip4844 => |tx| .{
                .eip4844 = .{
                    .metadata = metadata,
                    .chain_id = tx.chain_id,
                    .nonce = tx.nonce,
                    .max_priority_fee_per_gas = tx.max_priority_fee_per_gas,
                    .max_fee_per_gas = tx.max_fee_per_gas,
                    .gas = tx.gas_limit,
                    .to = .{ .bytes = tx.to.bytes },
                    .value = tx.value,
                    .input = try allocator.dupe(u8, tx.data),
                    .access_list = try toResponseAccessList(allocator, tx.access_list),
                    .max_fee_per_blob_gas = tx.max_fee_per_blob_gas,
                    .blob_versioned_hashes = try toBlobVersionedHashes(allocator, tx.blob_versioned_hashes),
                    .y_parity = tx.y_parity,
                    .r = tx.r,
                    .s = tx.s,
                },
            },
            .eip7702 => |tx| .{
                .eip7702 = .{
                    .metadata = metadata,
                    .chain_id = tx.chain_id,
                    .nonce = tx.nonce,
                    .max_priority_fee_per_gas = tx.max_priority_fee_per_gas,
                    .max_fee_per_gas = tx.max_fee_per_gas,
                    .gas = tx.gas_limit,
                    .to = if (tx.to) |to| .{ .bytes = to.bytes } else null,
                    .value = tx.value,
                    .input = try allocator.dupe(u8, tx.data),
                    .access_list = try toResponseAccessList(allocator, tx.access_list),
                    .authorization_list = try toResponseAuthorizationList(allocator, tx.authorization_list),
                    .y_parity = tx.y_parity,
                    .r = tx.r,
                    .s = tx.s,
                },
            },
        },
    };
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

fn dataFromBytes(allocator: std.mem.Allocator, data: []const u8) !jsonrpc.types.Quantity {
    return .{ .value = .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{data}) } };
}

fn txTypeFromU8(type_field: u8) jsonrpc.types.TransactionInfo.TransactionType {
    return switch (type_field) {
        1 => .eip2930,
        2 => .eip1559,
        3 => .eip4844,
        4 => .eip7702,
        else => .legacy,
    };
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
                        .type = txTypeFromU8(tx.type_field),
                        .hash = hashToRpc(tx.hash),
                        .nonce = try quantityFromU64(allocator, tx.nonce),
                        .blockHash = hashToRpc(tx.blockHash orelse [_]u8{0} ** 32),
                        .blockNumber = try quantityFromU64(allocator, tx.blockNumber orelse 0),
                        .transactionIndex = try quantityFromU64(allocator, tx.transactionIndex orelse 0),
                        .from = addrToRpc(tx.from),
                        .to = optAddrToRpc(tx.to),
                        .value = try quantityFromU256(allocator, tx.value),
                        .gas = try quantityFromU64(allocator, tx.gas),
                        .input = try dataFromBytes(allocator, tx.input),
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
        .extraData = try dataFromBytes(allocator, resp.extraData),
        .mixHash = hashToRpc(resp.mixHash),
        .nonce = .{ .bytes = resp.nonce },
        .size = try quantityFromU64(allocator, resp.size),
        .transactions = txs,
        .uncles = &.{},
        .difficulty = try quantityFromU256(allocator, resp.difficulty),
        .totalDifficulty = try quantityFromU256(allocator, resp.totalDifficulty orelse 0),
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
        const rpc_topics = try allocator.alloc(jsonrpc.types.Hash, log.topics.len);
        for (log.topics, 0..) |topic, topic_index| {
            rpc_topics[topic_index] = hashToRpc(topic);
        }

        rpc_logs[i] = .{
            .removed = log.removed,
            .logIndex = if (log.logIndex) |li| try quantityFromU64(allocator, li) else null,
            .transactionIndex = if (log.transactionIndex) |ti| try quantityFromU64(allocator, ti) else null,
            .transactionHash = if (log.transactionHash) |th| hashToRpc(th) else hashToRpc([_]u8{0} ** 32),
            .blockHash = hashToRpc(log.blockHash),
            .blockNumber = if (log.blockNumber) |bn| try quantityFromU64(allocator, bn) else null,
            .address = addrToRpc(log.address),
            .data = try dataFromBytes(allocator, log.data),
            .topics = rpc_topics,
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
        .data = try dataFromBytes(allocator, resp.data),
        .topics = rpc_topics,
    };
}

fn rpcFilterToInternal(allocator: std.mem.Allocator, filter: anytype) !log_index_mod.LogFilter {
    var result: log_index_mod.LogFilter = .{};

    if (@hasField(@TypeOf(filter), "fromBlock")) {
        if (filter.fromBlock) |fb| {
            result.from_block = try parseQuantityToU64(fb);
        }
    }
    if (@hasField(@TypeOf(filter), "toBlock")) {
        if (filter.toBlock) |tb| {
            result.to_block = try parseQuantityToU64(tb);
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

fn toResponseAccessList(
    allocator: std.mem.Allocator,
    access_list: []const primitives.Transaction.AccessListItem,
) ![]const jsonrpc.types.TransactionResponse.AccessListEntry {
    const response = try allocator.alloc(jsonrpc.types.TransactionResponse.AccessListEntry, access_list.len);
    for (access_list, 0..) |entry, i| {
        response[i] = .{
            .address = .{ .bytes = entry.address.bytes },
            .storage_keys = try allocator.dupe([32]u8, entry.storage_keys),
        };
    }
    return response;
}

fn toResponseAuthorizationList(
    allocator: std.mem.Allocator,
    authorization_list: []const primitives.Authorization.Authorization,
) ![]const jsonrpc.types.TransactionResponse.AuthorizationEntry {
    const response = try allocator.alloc(jsonrpc.types.TransactionResponse.AuthorizationEntry, authorization_list.len);
    for (authorization_list, 0..) |entry, i| {
        response[i] = .{
            .chain_id = entry.chain_id,
            .address = .{ .bytes = entry.address.bytes },
            .nonce = entry.nonce,
            .y_parity = @intCast(entry.v & 1),
            .r = entry.r,
            .s = entry.s,
        };
    }
    return response;
}

fn toBlobVersionedHashes(
    allocator: std.mem.Allocator,
    hashes: []const primitives.Blob.VersionedHash,
) ![]const [32]u8 {
    const out = try allocator.alloc([32]u8, hashes.len);
    for (hashes, 0..) |hash, i| {
        out[i] = hash.bytes;
    }
    return out;
}

test {
    _ = @import("block_query_handlers_test.zig");
}
