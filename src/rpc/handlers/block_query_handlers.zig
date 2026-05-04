const std = @import("std");
const jsonrpc = @import("jsonrpc");
const primitives = @import("primitives");
const blockchain_mod = @import("blockchain");
const block_queries = @import("../block_queries.zig");
const log_index_mod = @import("../../log_index.zig");
const receipt_index_mod = @import("../../receipt_index.zig");
const runtime = @import("../../node/runtime.zig");
const rpc_parse = @import("../parse.zig");

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
    const tag = blockSpecToTag(allocator, params.block) catch |err| switch (err) {
        error.InvalidBlockSpec => return error.InvalidParams,
        else => return err,
    };
    defer allocator.free(tag);

    const internal = try block_queries.getBlockByNumberWithReceipts(
        allocator,
        ctx.blockchain,
        ctx.receipt_index,
        tag,
        params.hydrated_transactions,
    );
    if (internal) |resp| {
        return .{ .block = try internalBlockToRpc(allocator, resp) };
    }
    return .{ .block = null };
}

pub fn handleGetBlockByNumberValue(
    allocator: std.mem.Allocator,
    ctx: *const BlockQueryContext,
    params: jsonrpc.eth.GetBlockByNumber.Params,
) !std.json.Value {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const scratch_allocator = scratch.allocator();

    const tag = blockSpecToTag(scratch_allocator, params.block) catch |err| switch (err) {
        error.InvalidBlockSpec => return error.InvalidParams,
        else => return err,
    };

    const internal = try block_queries.getBlockByNumberWithReceipts(
        scratch_allocator,
        ctx.blockchain,
        ctx.receipt_index,
        tag,
        params.hydrated_transactions,
    );
    if (internal) |resp| return try blockResponseValue(allocator, ctx, resp);
    return .null;
}

// ============================================================================
// eth_getBlockByHash
// ============================================================================

pub fn handleGetBlockByHash(
    allocator: std.mem.Allocator,
    ctx: *const BlockQueryContext,
    params: jsonrpc.eth.GetBlockByHash.Params,
) !jsonrpc.eth.GetBlockByHash.Result {
    const internal = try block_queries.getBlockByHashWithReceipts(
        allocator,
        ctx.blockchain,
        ctx.receipt_index,
        params.block_hash.bytes,
        params.hydrated_transactions,
    );
    if (internal) |resp| {
        return .{ .block = try internalBlockToRpc(allocator, resp) };
    }
    return .{ .block = null };
}

pub fn handleGetBlockByHashValue(
    allocator: std.mem.Allocator,
    ctx: *const BlockQueryContext,
    params: jsonrpc.eth.GetBlockByHash.Params,
) !std.json.Value {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();

    const internal = try block_queries.getBlockByHashWithReceipts(
        scratch.allocator(),
        ctx.blockchain,
        ctx.receipt_index,
        params.block_hash.bytes,
        params.hydrated_transactions,
    );
    if (internal) |resp| return try blockResponseValue(allocator, ctx, resp);
    return .null;
}

// ============================================================================
// eth_getBlockTransactionCountByHash
// ============================================================================

pub fn handleGetBlockTransactionCountByHash(
    allocator: std.mem.Allocator,
    ctx: *const BlockQueryContext,
    params: jsonrpc.eth.GetBlockTransactionCountByHash.Params,
) !jsonrpc.eth.GetBlockTransactionCountByHash.Result {
    const count = try block_queries.getBlockTxCountByHash(ctx.blockchain, params.block_hash.bytes);
    if (count) |n| {
        return .{ .value = try quantityFromU64(allocator, n) };
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
    const tag = blockSpecToTag(allocator, params.block) catch |err| switch (err) {
        error.InvalidBlockSpec => return error.InvalidParams,
        else => return err,
    };
    defer allocator.free(tag);

    const count = try block_queries.getBlockTxCountByNumber(ctx.blockchain, tag);
    if (count) |n| {
        return .{ .value = try quantityFromU64(allocator, n) };
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
    const count = try block_queries.getUncleCountByHash(ctx.blockchain, params.block_hash.bytes);
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
    const tag = blockSpecToTag(allocator, params.block) catch |err| switch (err) {
        error.InvalidBlockSpec => return error.InvalidParams,
        else => return err,
    };
    defer allocator.free(tag);

    const count = try block_queries.getUncleCountByNumber(ctx.blockchain, tag);
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
    const internal = try block_queries.getTransactionReceiptWithBlock(allocator, ctx.blockchain, ctx.receipt_index, params.transaction_hash.bytes);
    if (internal) |resp| {
        return .{ .value = try internalReceiptToRpc(allocator, resp) };
    }
    return .{ .value = null };
}

pub fn handleGetTransactionReceiptValue(
    allocator: std.mem.Allocator,
    ctx: *const BlockQueryContext,
    params: jsonrpc.eth.GetTransactionReceipt.Params,
) !std.json.Value {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();

    const internal = try block_queries.getTransactionReceiptWithBlock(scratch.allocator(), ctx.blockchain, ctx.receipt_index, params.transaction_hash.bytes);
    if (internal) |resp| return try receiptResponseValue(allocator, resp);
    return .null;
}

// ============================================================================
// eth_getBlockReceipts
// ============================================================================

pub fn handleGetBlockReceipts(
    allocator: std.mem.Allocator,
    ctx: *const BlockQueryContext,
    params: jsonrpc.eth.GetBlockReceipts.Params,
) !jsonrpc.eth.GetBlockReceipts.Result {
    const maybe_receipts = blockReceiptsFromSpec(allocator, ctx, params.block) catch |err| switch (err) {
        error.InvalidBlockSpec => return error.InvalidParams,
        else => return err,
    };
    if (maybe_receipts) |resps| {
        defer allocator.free(resps);
        const rpc_receipts = try allocator.alloc(jsonrpc.types.ReceiptResponse, resps.len);
        for (resps, 0..) |resp, i| {
            rpc_receipts[i] = try internalReceiptToRpc(allocator, resp);
        }
        return .{ .value = rpc_receipts };
    }
    return .{ .value = null };
}

pub fn handleGetBlockReceiptsValue(
    allocator: std.mem.Allocator,
    ctx: *const BlockQueryContext,
    params: jsonrpc.eth.GetBlockReceipts.Params,
) !std.json.Value {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();

    const maybe_receipts = blockReceiptsFromSpec(scratch.allocator(), ctx, params.block) catch |err| switch (err) {
        error.InvalidBlockSpec => return error.InvalidParams,
        else => return err,
    };
    if (maybe_receipts) |resps| {
        var array = std.json.Array.init(allocator);
        for (resps) |resp| {
            try array.append(try receiptResponseValue(allocator, resp));
        }
        return .{ .array = array };
    }
    return .null;
}

/// Resolve a BlockSpec to receipts. Accepts block numbers/tags as strings and
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
            if (!isTrustedBlockSelector(s)) return error.InvalidBlockSpec;
            return try block_queries.getBlockReceipts(allocator, ctx.blockchain, ctx.receipt_index, s);
        },
        .object => |obj| {
            if (obj.get("blockHash")) |bh_value| {
                const bh_str = switch (bh_value) {
                    .string => |s| s,
                    else => return error.InvalidBlockSpec,
                };
                const hash_bytes = parseBlockHashString(bh_str) orelse return error.InvalidBlockSpec;
                return try block_queries.getBlockReceiptsByHash(allocator, ctx.blockchain, ctx.receipt_index, hash_bytes);
            }
            if (obj.get("blockNumber")) |bn_value| {
                switch (bn_value) {
                    .string => |s| {
                        if (!isTrustedBlockSelector(s)) return error.InvalidBlockSpec;
                        return try block_queries.getBlockReceipts(allocator, ctx.blockchain, ctx.receipt_index, s);
                    },
                    else => return error.InvalidBlockSpec,
                }
            }
            return null;
        },
        else => return null,
    }
}

fn parseBlockHashString(s: []const u8) ?[32]u8 {
    return rpc_parse.parseHash32String(s) catch null;
}

// ============================================================================
// eth_getLogs
// ============================================================================

pub fn handleGetLogs(
    allocator: std.mem.Allocator,
    ctx: *const BlockQueryContext,
    params: jsonrpc.eth.GetLogs.Params,
) !jsonrpc.eth.GetLogs.Result {
    const filter = rpcFilterToInternal(allocator, ctx, params.filter) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidParams,
    };

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

pub fn handleGetLogsValue(
    allocator: std.mem.Allocator,
    ctx: *const BlockQueryContext,
    params: jsonrpc.eth.GetLogs.Params,
) !std.json.Value {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const scratch_allocator = scratch.allocator();

    const filter = rpcFilterToInternal(scratch_allocator, ctx, params.filter) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidParams,
    };
    const internal = block_queries.getLogs(scratch_allocator, ctx.blockchain, ctx.log_index, filter) catch |err| switch (err) {
        error.InvalidFilter => return error.InvalidParams,
        else => return err,
    };

    var array = std.json.Array.init(allocator);
    for (internal) |resp| {
        try array.append(try logResponseValue(allocator, resp));
    }
    return .{ .array = array };
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
    ) catch |err| return err;
    if (internal) |tx| {
        return .{ .value = try internalTxToRpc(allocator, tx) };
    }
    return .{ .value = null };
}

pub fn handleGetTransactionByHashValue(
    allocator: std.mem.Allocator,
    ctx: *const BlockQueryContext,
    params: jsonrpc.eth.GetTransactionByHash.Params,
) !std.json.Value {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();

    const internal = try block_queries.getTransactionByHash(
        scratch.allocator(),
        ctx.blockchain,
        ctx.receipt_index,
        params.transaction_hash.bytes,
    );
    if (internal) |tx| return try transactionResponseValue(allocator, tx);
    return .null;
}

// ============================================================================
// eth_getTransactionByBlockHashAndIndex
// ============================================================================

pub fn handleGetTransactionByBlockHashAndIndex(
    allocator: std.mem.Allocator,
    ctx: *const BlockQueryContext,
    params: jsonrpc.eth.GetTransactionByBlockHashAndIndex.Params,
) !jsonrpc.eth.GetTransactionByBlockHashAndIndex.Result {
    const index = parseQuantityToU64(params.transaction_index) catch return error.InvalidParams;
    const internal = block_queries.getTransactionByBlockHashAndIndexWithReceipts(
        allocator,
        ctx.blockchain,
        ctx.receipt_index,
        params.block_hash.bytes,
        index,
    ) catch |err| return err;
    if (internal) |tx| {
        return .{ .value = try internalTxToRpc(allocator, tx) };
    }
    return .{ .value = null };
}

pub fn handleGetTransactionByBlockHashAndIndexValue(
    allocator: std.mem.Allocator,
    ctx: *const BlockQueryContext,
    params: jsonrpc.eth.GetTransactionByBlockHashAndIndex.Params,
) !std.json.Value {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();

    const index = parseQuantityToU64(params.transaction_index) catch return error.InvalidParams;
    const internal = try block_queries.getTransactionByBlockHashAndIndexWithReceipts(
        scratch.allocator(),
        ctx.blockchain,
        ctx.receipt_index,
        params.block_hash.bytes,
        index,
    );
    if (internal) |tx| return try transactionResponseValue(allocator, tx);
    return .null;
}

// ============================================================================
// eth_getTransactionByBlockNumberAndIndex
// ============================================================================

pub fn handleGetTransactionByBlockNumberAndIndex(
    allocator: std.mem.Allocator,
    ctx: *const BlockQueryContext,
    params: jsonrpc.eth.GetTransactionByBlockNumberAndIndex.Params,
) !jsonrpc.eth.GetTransactionByBlockNumberAndIndex.Result {
    const tag = blockSpecToTag(allocator, params.block) catch |err| switch (err) {
        error.InvalidBlockSpec => return error.InvalidParams,
        else => return err,
    };
    defer allocator.free(tag);

    const index = parseQuantityToU64(params.transaction_index) catch return error.InvalidParams;
    const internal = block_queries.getTransactionByBlockNumberAndIndexWithReceipts(
        allocator,
        ctx.blockchain,
        ctx.receipt_index,
        tag,
        index,
    ) catch |err| return err;
    if (internal) |tx| {
        return .{ .value = try internalTxToRpc(allocator, tx) };
    }
    return .{ .value = null };
}

pub fn handleGetTransactionByBlockNumberAndIndexValue(
    allocator: std.mem.Allocator,
    ctx: *const BlockQueryContext,
    params: jsonrpc.eth.GetTransactionByBlockNumberAndIndex.Params,
) !std.json.Value {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const scratch_allocator = scratch.allocator();

    const tag = blockSpecToTag(scratch_allocator, params.block) catch |err| switch (err) {
        error.InvalidBlockSpec => return error.InvalidParams,
        else => return err,
    };

    const index = parseQuantityToU64(params.transaction_index) catch return error.InvalidParams;
    const internal = try block_queries.getTransactionByBlockNumberAndIndexWithReceipts(
        scratch_allocator,
        ctx.blockchain,
        ctx.receipt_index,
        tag,
        index,
    );
    if (internal) |tx| return try transactionResponseValue(allocator, tx);
    return .null;
}

// ============================================================================
// Conversion Helpers
// ============================================================================

fn putJson(
    obj: *std.json.ObjectMap,
    allocator: std.mem.Allocator,
    key: []const u8,
    value: std.json.Value,
) !void {
    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    try obj.put(owned_key, value);
}

fn quantityValue(allocator: std.mem.Allocator, n: anytype) !std.json.Value {
    return .{ .string = try std.fmt.allocPrint(allocator, "0x{x}", .{n}) };
}

fn bytesValue(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Value {
    if (bytes.len == 0) return .{ .string = try allocator.dupe(u8, "0x") };

    const out = try allocator.alloc(u8, 2 + bytes.len * 2);
    out[0] = '0';
    out[1] = 'x';
    writeHexLower(out[2..], bytes);
    return .{ .string = out };
}

fn hashValue(allocator: std.mem.Allocator, h: [32]u8) !std.json.Value {
    const out = try allocator.alloc(u8, 66);
    out[0] = '0';
    out[1] = 'x';
    writeHexLower(out[2..], h[0..]);
    return .{ .string = out };
}

fn addressValue(allocator: std.mem.Allocator, a: primitives.Address.Address) !std.json.Value {
    const out = try allocator.alloc(u8, 42);
    out[0] = '0';
    out[1] = 'x';
    writeHexLower(out[2..], a.bytes[0..]);
    return .{ .string = out };
}

fn writeHexLower(out: []u8, src: []const u8) void {
    const alphabet = "0123456789abcdef";
    for (src, 0..) |byte, i| {
        out[i * 2] = alphabet[(byte >> 4) & 0x0f];
        out[i * 2 + 1] = alphabet[byte & 0x0f];
    }
}

fn hashArrayValue(allocator: std.mem.Allocator, hashes: []const [32]u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (hashes) |hash| {
        try array.append(try hashValue(allocator, hash));
    }
    return .{ .array = array };
}

fn blockTransactionsValue(
    allocator: std.mem.Allocator,
    transactions: block_queries.TransactionList,
) !std.json.Value {
    var array = std.json.Array.init(allocator);
    switch (transactions) {
        .hashes => |hashes| {
            for (hashes) |hash| {
                try array.append(try hashValue(allocator, hash));
            }
        },
        .full => |txs| {
            for (txs) |tx| {
                try array.append(try transactionResponseValue(allocator, tx));
            }
        },
    }
    return .{ .array = array };
}

fn blockResponseValue(
    allocator: std.mem.Allocator,
    ctx: *const BlockQueryContext,
    resp: block_queries.BlockResponse,
) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);

    try putJson(&obj, allocator, "hash", try hashValue(allocator, resp.hash));
    try putJson(&obj, allocator, "parentHash", try hashValue(allocator, resp.parentHash));
    try putJson(&obj, allocator, "sha3Uncles", try hashValue(allocator, resp.ommersHash));
    try putJson(&obj, allocator, "miner", try addressValue(allocator, resp.miner));
    try putJson(&obj, allocator, "stateRoot", try hashValue(allocator, resp.stateRoot));
    try putJson(&obj, allocator, "transactionsRoot", try hashValue(allocator, resp.transactionsRoot));
    try putJson(&obj, allocator, "receiptsRoot", try hashValue(allocator, resp.receiptsRoot));
    try putJson(&obj, allocator, "logsBloom", try bytesValue(allocator, resp.logsBloom[0..]));
    try putJson(&obj, allocator, "number", try quantityValue(allocator, resp.number));
    try putJson(&obj, allocator, "gasLimit", try quantityValue(allocator, resp.gasLimit));
    try putJson(&obj, allocator, "gasUsed", try quantityValue(allocator, resp.gasUsed));
    try putJson(&obj, allocator, "timestamp", try quantityValue(allocator, resp.timestamp));
    try putJson(&obj, allocator, "extraData", try bytesValue(allocator, resp.extraData));
    try putJson(&obj, allocator, "mixHash", try hashValue(allocator, resp.mixHash));
    try putJson(&obj, allocator, "nonce", try bytesValue(allocator, resp.nonce[0..]));
    try putJson(&obj, allocator, "size", try quantityValue(allocator, resp.size));
    try putJson(&obj, allocator, "transactions", try blockTransactionsValue(allocator, resp.transactions));
    try putJson(&obj, allocator, "uncles", try hashArrayValue(allocator, resp.uncleHashes));
    try putJson(&obj, allocator, "difficulty", try quantityValue(allocator, resp.difficulty));
    if (resp.totalDifficulty) |td| try putJson(&obj, allocator, "totalDifficulty", try quantityValue(allocator, td));
    if (resp.baseFeePerGas) |bfpg| try putJson(&obj, allocator, "baseFeePerGas", try quantityValue(allocator, bfpg));
    if (resp.withdrawalsRoot) |wr| {
        try putJson(&obj, allocator, "withdrawalsRoot", try hashValue(allocator, wr));
        try putJson(&obj, allocator, "withdrawals", try withdrawalsValue(allocator, resp.withdrawals orelse &.{}));
    }
    if (resp.blobGasUsed) |bgu| try putJson(&obj, allocator, "blobGasUsed", try quantityValue(allocator, bgu));
    if (resp.excessBlobGas) |ebg| try putJson(&obj, allocator, "excessBlobGas", try quantityValue(allocator, ebg));
    if (resp.parentBeaconBlockRoot) |pbbr| try putJson(&obj, allocator, "parentBeaconBlockRoot", try hashValue(allocator, pbbr));
    if (requestsHashForBlock(ctx, resp)) |requests_hash| try putJson(&obj, allocator, "requestsHash", try hashValue(allocator, requests_hash));

    return .{ .object = obj };
}

fn requestsHashForBlock(ctx: *const BlockQueryContext, resp: block_queries.BlockResponse) ?[32]u8 {
    for (ctx.rt.owned_block_bodies.items) |owned| {
        if (std.mem.eql(u8, &owned.block_hash, &resp.hash)) return owned.requests_hash;
    }

    if (ctx.rt.hardforkAt(resp.number, resp.timestamp).isAtLeast(.PRAGUE)) {
        var empty: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&.{}, &empty, .{});
        return empty;
    }
    return null;
}

fn transactionResponseValue(
    allocator: std.mem.Allocator,
    tx: block_queries.TxResponse,
) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);

    try putJson(&obj, allocator, "type", try quantityValue(allocator, tx.type_field));
    try putJson(&obj, allocator, "hash", try hashValue(allocator, tx.hash));
    try putJson(&obj, allocator, "nonce", try quantityValue(allocator, tx.nonce));
    try putJson(&obj, allocator, "blockHash", if (tx.blockHash) |hash| try hashValue(allocator, hash) else .null);
    try putJson(&obj, allocator, "blockNumber", if (tx.blockNumber) |n| try quantityValue(allocator, n) else .null);
    if (tx.blockTimestamp) |timestamp| try putJson(&obj, allocator, "blockTimestamp", try quantityValue(allocator, timestamp));
    try putJson(&obj, allocator, "transactionIndex", if (tx.transactionIndex) |i| try quantityValue(allocator, i) else .null);
    try putJson(&obj, allocator, "from", try addressValue(allocator, tx.from));
    try putJson(&obj, allocator, "to", if (tx.to) |to| try addressValue(allocator, to) else .null);
    try putJson(&obj, allocator, "value", try quantityValue(allocator, tx.value));
    try putJson(&obj, allocator, "gas", try quantityValue(allocator, tx.gas));
    try putJson(&obj, allocator, "input", try bytesValue(allocator, tx.input));
    if (tx.gas_price) |gas_price| try putJson(&obj, allocator, "gasPrice", try quantityValue(allocator, gas_price));
    if (tx.max_priority_fee_per_gas) |value| try putJson(&obj, allocator, "maxPriorityFeePerGas", try quantityValue(allocator, value));
    if (tx.max_fee_per_gas) |value| try putJson(&obj, allocator, "maxFeePerGas", try quantityValue(allocator, value));
    if (tx.max_fee_per_blob_gas) |value| try putJson(&obj, allocator, "maxFeePerBlobGas", try quantityValue(allocator, value));
    if (tx.access_list) |access_list| try putJson(&obj, allocator, "accessList", try accessListValue(allocator, access_list));
    if (tx.blob_versioned_hashes) |hashes| try putJson(&obj, allocator, "blobVersionedHashes", try hashArrayValue(allocator, hashes));
    if (tx.chain_id) |chain_id| try putJson(&obj, allocator, "chainId", try quantityValue(allocator, chain_id));
    if (tx.authorization_list) |auth_list| try putJson(&obj, allocator, "authorizationList", try authorizationListValue(allocator, auth_list));
    if (tx.y_parity != null and tx.type_field != 0) try putJson(&obj, allocator, "yParity", try quantityValue(allocator, tx.y_parity.?));
    if (tx.v) |v| try putJson(&obj, allocator, "v", try quantityValue(allocator, v));
    if (tx.r) |r| try putJson(&obj, allocator, "r", try quantityValue(allocator, r));
    if (tx.s) |s| try putJson(&obj, allocator, "s", try quantityValue(allocator, s));

    return .{ .object = obj };
}

fn accessListValue(
    allocator: std.mem.Allocator,
    access_list: []const block_queries.TxAccessListEntry,
) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (access_list) |entry| {
        var obj = std.json.ObjectMap.init(allocator);
        try putJson(&obj, allocator, "address", try addressValue(allocator, entry.address));
        try putJson(&obj, allocator, "storageKeys", try hashArrayValue(allocator, entry.storage_keys));
        try array.append(.{ .object = obj });
    }
    return .{ .array = array };
}

fn authorizationListValue(
    allocator: std.mem.Allocator,
    authorization_list: []const block_queries.TxAuthorizationEntry,
) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (authorization_list) |entry| {
        var obj = std.json.ObjectMap.init(allocator);
        try putJson(&obj, allocator, "chainId", try quantityValue(allocator, entry.chain_id));
        try putJson(&obj, allocator, "address", try addressValue(allocator, entry.address));
        try putJson(&obj, allocator, "nonce", try quantityValue(allocator, entry.nonce));
        try putJson(&obj, allocator, "yParity", try quantityValue(allocator, entry.y_parity));
        try putJson(&obj, allocator, "r", try quantityValue(allocator, entry.r));
        try putJson(&obj, allocator, "s", try quantityValue(allocator, entry.s));
        try array.append(.{ .object = obj });
    }
    return .{ .array = array };
}

fn withdrawalsValue(
    allocator: std.mem.Allocator,
    withdrawals: []const block_queries.WithdrawalResponse,
) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (withdrawals) |withdrawal| {
        var obj = std.json.ObjectMap.init(allocator);
        try putJson(&obj, allocator, "index", try quantityValue(allocator, withdrawal.index));
        try putJson(&obj, allocator, "validatorIndex", try quantityValue(allocator, withdrawal.validatorIndex));
        try putJson(&obj, allocator, "address", try addressValue(allocator, withdrawal.address));
        try putJson(&obj, allocator, "amount", try quantityValue(allocator, withdrawal.amount));
        try array.append(.{ .object = obj });
    }
    return .{ .array = array };
}

fn receiptResponseValue(
    allocator: std.mem.Allocator,
    resp: block_queries.ReceiptResponse,
) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);

    try putJson(&obj, allocator, "transactionHash", try hashValue(allocator, resp.transactionHash));
    try putJson(&obj, allocator, "transactionIndex", try quantityValue(allocator, resp.transactionIndex));
    try putJson(&obj, allocator, "blockHash", try hashValue(allocator, resp.blockHash));
    try putJson(&obj, allocator, "blockNumber", try quantityValue(allocator, resp.blockNumber));
    try putJson(&obj, allocator, "from", try addressValue(allocator, resp.from));
    try putJson(&obj, allocator, "to", if (resp.to) |to| try addressValue(allocator, to) else .null);
    try putJson(&obj, allocator, "cumulativeGasUsed", try quantityValue(allocator, resp.cumulativeGasUsed));
    try putJson(&obj, allocator, "gasUsed", try quantityValue(allocator, resp.gasUsed));
    try putJson(&obj, allocator, "contractAddress", if (resp.contractAddress) |address| try addressValue(allocator, address) else .null);
    try putJson(&obj, allocator, "logs", try logsArrayValue(allocator, resp.logs));
    try putJson(&obj, allocator, "logsBloom", try bytesValue(allocator, resp.logsBloom[0..]));
    if (resp.status) |status| {
        try putJson(&obj, allocator, "status", try quantityValue(allocator, status));
    } else if (resp.root) |root| {
        try putJson(&obj, allocator, "root", try hashValue(allocator, root));
    }
    try putJson(&obj, allocator, "effectiveGasPrice", try quantityValue(allocator, resp.effectiveGasPrice));
    try putJson(&obj, allocator, "type", try quantityValue(allocator, resp.type_field));
    if (resp.blobGasUsed) |blob_gas_used| try putJson(&obj, allocator, "blobGasUsed", try quantityValue(allocator, blob_gas_used));
    if (resp.blobGasPrice) |blob_gas_price| try putJson(&obj, allocator, "blobGasPrice", try quantityValue(allocator, blob_gas_price));

    return .{ .object = obj };
}

fn logsArrayValue(
    allocator: std.mem.Allocator,
    logs: []const block_queries.LogResponse,
) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (logs) |log| {
        try array.append(try logResponseValue(allocator, log));
    }
    return .{ .array = array };
}

fn logResponseValue(
    allocator: std.mem.Allocator,
    resp: block_queries.LogResponse,
) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    try putJson(&obj, allocator, "removed", .{ .bool = resp.removed });
    try putJson(&obj, allocator, "logIndex", if (resp.logIndex) |i| try quantityValue(allocator, i) else .null);
    try putJson(&obj, allocator, "transactionIndex", if (resp.transactionIndex) |i| try quantityValue(allocator, i) else .null);
    try putJson(&obj, allocator, "transactionHash", if (resp.transactionHash) |hash| try hashValue(allocator, hash) else .null);
    try putJson(&obj, allocator, "blockHash", try hashValue(allocator, resp.blockHash));
    try putJson(&obj, allocator, "blockNumber", if (resp.blockNumber) |n| try quantityValue(allocator, n) else .null);
    if (resp.blockTimestamp) |timestamp| try putJson(&obj, allocator, "blockTimestamp", try quantityValue(allocator, timestamp));
    try putJson(&obj, allocator, "address", try addressValue(allocator, resp.address));
    try putJson(&obj, allocator, "data", try bytesValue(allocator, resp.data));
    try putJson(&obj, allocator, "topics", try hashArrayValue(allocator, resp.topics));
    return .{ .object = obj };
}

fn blockSpecToTag(allocator: std.mem.Allocator, spec: jsonrpc.types.BlockSpec) ![]u8 {
    switch (spec.value) {
        .string => |s| {
            if (!isTrustedBlockSelector(s)) return error.InvalidBlockSpec;
            return try allocator.dupe(u8, s);
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
        .sha3Uncles = hashToRpc(primitives.BlockHeader.EMPTY_OMMERS_HASH),
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

fn rpcFilterToInternal(
    allocator: std.mem.Allocator,
    ctx: *const BlockQueryContext,
    filter: jsonrpc.types.Quantity,
) !log_index_mod.LogFilter {
    const object = switch (filter.value) {
        .object => |obj| obj,
        else => return error.InvalidParams,
    };

    var result: log_index_mod.LogFilter = .{};
    var saw_from_block = false;
    var saw_to_block = false;

    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "fromBlock")) {
            result.from_block = try resolveFilterBlock(ctx, value);
            saw_from_block = true;
        } else if (std.mem.eql(u8, key, "toBlock")) {
            result.to_block = try resolveFilterBlock(ctx, value);
            saw_to_block = true;
        } else if (std.mem.eql(u8, key, "blockHash")) {
            result.block_hash = try parseHashValue(value);
        } else if (std.mem.eql(u8, key, "address")) {
            result.addresses = try parseAddressFilter(allocator, value);
        } else if (std.mem.eql(u8, key, "topics")) {
            result.topics = try parseTopicsFilter(allocator, value);
        } else {
            return error.InvalidParams;
        }
    }

    if (result.block_hash != null and (saw_from_block or saw_to_block)) {
        return error.InvalidParams;
    }

    if (result.block_hash == null) {
        const latest = ctx.blockchain.getHeadBlockNumber() orelse 0;
        if (!saw_from_block) result.from_block = latest;
        if (!saw_to_block) result.to_block = latest;
    }
    if (result.from_block != null and result.to_block != null and result.from_block.? > result.to_block.?) {
        return error.InvalidParams;
    }

    return result;
}

fn parseQuantityToU64(q: jsonrpc.types.Quantity) !u64 {
    return rpc_parse.parseQuantity(u64, q) catch return error.InvalidQuantity;
}

fn isTrustedBlockSelector(text: []const u8) bool {
    return rpc_parse.isTrustedBlockSelectorString(text);
}

fn isQuantityHex(text: []const u8) bool {
    return rpc_parse.isQuantityHex(text);
}

fn resolveFilterBlock(ctx: *const BlockQueryContext, value: std.json.Value) !u64 {
    switch (value) {
        .string => |s| {
            if (std.mem.eql(u8, s, "latest") or
                std.mem.eql(u8, s, "pending") or
                std.mem.eql(u8, s, "safe") or
                std.mem.eql(u8, s, "finalized"))
            {
                return ctx.blockchain.getHeadBlockNumber() orelse 0;
            }
            if (std.mem.eql(u8, s, "earliest")) return 0;
            return rpc_parse.parseQuantityString(u64, s);
        },
        else => return error.InvalidParams,
    }
}

fn parseHashValue(value: std.json.Value) ![32]u8 {
    return rpc_parse.parseHash32Value(value);
}

fn parseAddressValue(value: std.json.Value) !primitives.Address.Address {
    return rpc_parse.parseAddressValue(value);
}

fn parseAddressFilter(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) ![]const primitives.Address.Address {
    switch (value) {
        .string => {
            const addresses = try allocator.alloc(primitives.Address.Address, 1);
            addresses[0] = try parseAddressValue(value);
            return addresses;
        },
        .array => |array| {
            const addresses = try allocator.alloc(primitives.Address.Address, array.items.len);
            for (array.items, 0..) |item, i| {
                addresses[i] = try parseAddressValue(item);
            }
            return addresses;
        },
        else => return error.InvalidParams,
    }
}

fn parseTopicsFilter(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) ![]const ?[]const [32]u8 {
    const items = switch (value) {
        .array => |array| array.items,
        else => return error.InvalidParams,
    };

    const topics = try allocator.alloc(?[]const [32]u8, items.len);
    for (items, 0..) |item, i| {
        switch (item) {
            .null => topics[i] = null,
            .string => {
                const hashes = try allocator.alloc([32]u8, 1);
                hashes[0] = try parseHashValue(item);
                topics[i] = hashes;
            },
            .array => |array| {
                const hashes = try allocator.alloc([32]u8, array.items.len);
                for (array.items, 0..) |hash_value, j| {
                    hashes[j] = try parseHashValue(hash_value);
                }
                topics[i] = hashes;
            },
            else => return error.InvalidParams,
        }
    }
    return topics;
}

test {
    _ = @import("block_query_handlers_test.zig");
}
