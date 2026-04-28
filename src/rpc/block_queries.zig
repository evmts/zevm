const std = @import("std");
const primitives = @import("primitives");
const blockchain_mod = @import("blockchain");
const receipt_index_mod = @import("../receipt_index.zig");
const log_index_mod = @import("../log_index.zig");

// ============================================================================
// Response Types
// ============================================================================

pub const TransactionList = union(enum) {
    hashes: [][32]u8,
    full: []TxResponse,
};

pub const BlockResponse = struct {
    hash: [32]u8,
    number: u64,
    parentHash: [32]u8,
    miner: primitives.Address.Address,
    stateRoot: [32]u8,
    transactionsRoot: [32]u8,
    receiptsRoot: [32]u8,
    logsBloom: [256]u8,
    difficulty: u256,
    gasLimit: u64,
    gasUsed: u64,
    timestamp: u64,
    extraData: []const u8,
    mixHash: [32]u8,
    nonce: [8]u8,
    baseFeePerGas: ?u256,
    withdrawalsRoot: ?[32]u8,
    blobGasUsed: ?u64,
    excessBlobGas: ?u64,
    parentBeaconBlockRoot: ?[32]u8,
    size: u64,
    totalDifficulty: ?u256,
    transactions: TransactionList,
};

pub const TxResponse = struct {
    hash: [32]u8,
    blockHash: ?[32]u8,
    blockNumber: ?u64,
    transactionIndex: ?u32,
    from: primitives.Address.Address,
    to: ?primitives.Address.Address,
    nonce: u64,
    gas: u64,
    value: u256,
    input: []const u8,
    type_field: u8,
    chain_id: ?u64,
    gas_price: ?u256,
    max_fee_per_gas: ?u256,
    max_priority_fee_per_gas: ?u256,
    max_fee_per_blob_gas: ?u256,
    blob_versioned_hashes: ?[]const [32]u8,
    access_list: ?[]const TxAccessListEntry,
    authorization_list: ?[]const TxAuthorizationEntry,
    v: ?u256,
    r: ?u256,
    s: ?u256,
    y_parity: ?u8,
};

pub const TxAccessListEntry = struct {
    address: primitives.Address.Address,
    storage_keys: []const [32]u8,
};

pub const TxAuthorizationEntry = struct {
    chain_id: u256,
    address: primitives.Address.Address,
    nonce: u64,
    y_parity: u8,
    r: u256,
    s: u256,
};

pub const LogResponse = struct {
    address: primitives.Address.Address,
    topics: []const [32]u8,
    data: []const u8,
    blockNumber: ?u64,
    blockHash: [32]u8,
    transactionHash: ?[32]u8,
    transactionIndex: ?u32,
    logIndex: ?u32,
    removed: bool,
};

pub const ReceiptResponse = struct {
    transactionHash: [32]u8,
    transactionIndex: u32,
    blockHash: [32]u8,
    blockNumber: u64,
    from: primitives.Address.Address,
    to: ?primitives.Address.Address,
    cumulativeGasUsed: u256,
    gasUsed: u256,
    contractAddress: ?primitives.Address.Address,
    logs: []const LogResponse,
    logsBloom: [256]u8,
    status: ?u8,
    root: ?[32]u8,
    effectiveGasPrice: u256,
    type_field: u8,
    blobGasUsed: ?u256,
    blobGasPrice: ?u256,
};

// ============================================================================
// Block Tag Resolution
// ============================================================================

pub fn resolveBlockTag(
    bc: *blockchain_mod.Blockchain,
    tag: []const u8,
) ?u64 {
    if (std.mem.eql(u8, tag, "latest") or
        std.mem.eql(u8, tag, "safe") or
        std.mem.eql(u8, tag, "finalized") or
        std.mem.eql(u8, tag, "pending"))
    {
        return bc.getHeadBlockNumber();
    }
    if (std.mem.eql(u8, tag, "earliest")) {
        return 0;
    }
    // Hex number: "0x..."
    if (tag.len >= 2 and tag[0] == '0' and tag[1] == 'x') {
        return std.fmt.parseInt(u64, tag[2..], 16) catch null;
    }
    return null;
}

// ============================================================================
// Block Queries
// ============================================================================

pub fn getBlockByNumber(
    allocator: std.mem.Allocator,
    bc: *blockchain_mod.Blockchain,
    tag: []const u8,
    full_txs: bool,
) !?BlockResponse {
    const number = resolveBlockTag(bc, tag) orelse return null;
    const block = (try bc.getBlockByNumber(number)) orelse return null;
    return @as(?BlockResponse, try blockToResponse(allocator, block, full_txs));
}

pub fn getBlockByHash(
    allocator: std.mem.Allocator,
    bc: *blockchain_mod.Blockchain,
    hash: [32]u8,
    full_txs: bool,
) !?BlockResponse {
    const block = (try bc.getBlockByHash(hash)) orelse return null;
    return @as(?BlockResponse, try blockToResponse(allocator, block, full_txs));
}

pub fn getBlockTxCountByNumber(
    bc: *blockchain_mod.Blockchain,
    tag: []const u8,
) !?u64 {
    const number = resolveBlockTag(bc, tag) orelse return null;
    const block = (try bc.getBlockByNumber(number)) orelse return null;
    return @intCast(block.body.transactions.len);
}

pub fn getBlockTxCountByHash(
    bc: *blockchain_mod.Blockchain,
    hash: [32]u8,
) !?u64 {
    const block = (try bc.getBlockByHash(hash)) orelse return null;
    return @intCast(block.body.transactions.len);
}

/// Post-Merge: always 0 uncles. Returns null only when the block is missing.
pub fn getUncleCountByNumber(
    bc: *blockchain_mod.Blockchain,
    tag: []const u8,
) !?u64 {
    const number = resolveBlockTag(bc, tag) orelse return null;
    const block = (try bc.getBlockByNumber(number)) orelse return null;
    return @intCast(block.body.ommers.len);
}

pub fn getUncleCountByHash(
    bc: *blockchain_mod.Blockchain,
    hash: [32]u8,
) !?u64 {
    const block = (try bc.getBlockByHash(hash)) orelse return null;
    return @intCast(block.body.ommers.len);
}

// ============================================================================
// Receipt Queries
// ============================================================================

pub fn getTransactionReceipt(
    allocator: std.mem.Allocator,
    ri: *const receipt_index_mod.ReceiptIndex,
    tx_hash: [32]u8,
) !?ReceiptResponse {
    const receipt = ri.getByTxHash(tx_hash) orelse return null;
    return try receiptToResponse(allocator, receipt);
}

pub fn getBlockReceipts(
    allocator: std.mem.Allocator,
    bc: *blockchain_mod.Blockchain,
    ri: *const receipt_index_mod.ReceiptIndex,
    tag: []const u8,
) !?[]ReceiptResponse {
    const number = resolveBlockTag(bc, tag) orelse return null;
    const block = (try bc.getBlockByNumber(number)) orelse return null;
    return try receiptsForBlockHash(allocator, ri, block.hash);
}

pub fn getBlockReceiptsByHash(
    allocator: std.mem.Allocator,
    bc: *blockchain_mod.Blockchain,
    ri: *const receipt_index_mod.ReceiptIndex,
    hash: [32]u8,
) !?[]ReceiptResponse {
    const block = (try bc.getBlockByHash(hash)) orelse return null;
    return try receiptsForBlockHash(allocator, ri, block.hash);
}

fn receiptsForBlockHash(
    allocator: std.mem.Allocator,
    ri: *const receipt_index_mod.ReceiptIndex,
    block_hash: [32]u8,
) !?[]ReceiptResponse {
    const receipts = ri.getByBlockHash(block_hash) orelse return null;

    const responses = try allocator.alloc(ReceiptResponse, receipts.len);
    errdefer allocator.free(responses);

    for (receipts, 0..) |receipt, i| {
        responses[i] = try receiptToResponse(allocator, receipt);
    }

    return responses;
}

// ============================================================================
// Transaction Queries
// ============================================================================

/// Look up a transaction by hash. We don't carry a structured tx index; instead,
/// the receipt index tracks each mined tx. We use the receipt to locate the
/// containing block + index, then synthesize a TxResponse using receipt-derived
/// fields. Fields that require RLP-decoding the raw tx bytes (nonce, value,
/// input, gasPrice, signature components, chain id, access list, etc.) cannot
/// be recovered without a transaction decoder; those are returned as 0/empty.
pub fn getTransactionByHash(
    allocator: std.mem.Allocator,
    bc: *blockchain_mod.Blockchain,
    ri: *const receipt_index_mod.ReceiptIndex,
    tx_hash: [32]u8,
) !?TxResponse {
    const receipt = ri.getByTxHash(tx_hash) orelse return null;
    const block = (try bc.getBlockByHash(receipt.block_hash)) orelse {
        // Receipt without block — degrade gracefully.
        return txResponseFromReceipt(allocator, receipt, null);
    };
    return txResponseFromReceipt(allocator, receipt, block);
}

pub fn getTransactionByBlockHashAndIndex(
    bc: *blockchain_mod.Blockchain,
    block_hash: [32]u8,
    index: u64,
) !?TxResponse {
    const block = (try bc.getBlockByHash(block_hash)) orelse return null;
    if (index >= block.body.transactions.len) return null;
    if (index > std.math.maxInt(u32)) return null;
    const tx_index: usize = @intCast(index);
    return txResponseFromRaw(
        block.body.transactions[tx_index].raw,
        block.hash,
        block.header.number,
        @intCast(index),
    );
}

pub fn getTransactionByBlockNumberAndIndex(
    bc: *blockchain_mod.Blockchain,
    tag: []const u8,
    index: u64,
) !?TxResponse {
    const number = resolveBlockTag(bc, tag) orelse return null;
    const block = (try bc.getBlockByNumber(number)) orelse return null;
    if (index >= block.body.transactions.len) return null;
    if (index > std.math.maxInt(u32)) return null;
    const tx_index: usize = @intCast(index);
    return txResponseFromRaw(
        block.body.transactions[tx_index].raw,
        block.hash,
        block.header.number,
        @intCast(index),
    );
}

// ============================================================================
// Log Queries
// ============================================================================

pub fn getLogs(
    allocator: std.mem.Allocator,
    bc: *blockchain_mod.Blockchain,
    li: *const log_index_mod.LogIndex,
    filter: log_index_mod.LogFilter,
) ![]LogResponse {
    const head = bc.getHeadBlockNumber() orelse 0;
    const indexed_logs = try li.query(allocator, filter, head);
    defer allocator.free(indexed_logs);

    const responses = try allocator.alloc(LogResponse, indexed_logs.len);
    for (indexed_logs, 0..) |entry, i| {
        responses[i] = .{
            .address = entry.log.address,
            .topics = entry.log.topics,
            .data = entry.log.data,
            .blockNumber = entry.log.block_number,
            .blockHash = entry.block_hash,
            .transactionHash = if (entry.log.transaction_hash) |h| h else null,
            .transactionIndex = entry.log.transaction_index,
            .logIndex = entry.log.log_index,
            .removed = entry.log.removed,
        };
    }

    return responses;
}

// ============================================================================
// Internal Helpers
// ============================================================================

fn blockToResponse(
    allocator: std.mem.Allocator,
    block: primitives.Block.Block,
    full_txs: bool,
) !BlockResponse {
    const txs: TransactionList = if (full_txs) blk: {
        const full = try allocator.alloc(TxResponse, block.body.transactions.len);
        for (block.body.transactions, 0..) |tx_data, i| {
            full[i] = txResponseFromRaw(tx_data.raw, block.hash, block.header.number, @intCast(i));
        }
        break :blk .{ .full = full };
    } else blk: {
        const hashes = try allocator.alloc([32]u8, block.body.transactions.len);
        for (block.body.transactions, 0..) |tx_data, i| {
            hashes[i] = computeTxHash(tx_data.raw);
        }
        break :blk .{ .hashes = hashes };
    };

    return .{
        .hash = block.hash,
        .number = block.header.number,
        .parentHash = block.header.parent_hash,
        .miner = block.header.beneficiary,
        .stateRoot = block.header.state_root,
        .transactionsRoot = block.header.transactions_root,
        .receiptsRoot = block.header.receipts_root,
        .logsBloom = block.header.logs_bloom,
        .difficulty = block.header.difficulty,
        .gasLimit = block.header.gas_limit,
        .gasUsed = block.header.gas_used,
        .timestamp = block.header.timestamp,
        .extraData = block.header.extra_data,
        .mixHash = block.header.mix_hash,
        .nonce = block.header.nonce,
        .baseFeePerGas = block.header.base_fee_per_gas,
        .withdrawalsRoot = block.header.withdrawals_root,
        .blobGasUsed = block.header.blob_gas_used,
        .excessBlobGas = block.header.excess_blob_gas,
        .parentBeaconBlockRoot = block.header.parent_beacon_block_root,
        .size = block.size,
        .totalDifficulty = block.total_difficulty,
        .transactions = txs,
    };
}

fn txResponseFromRaw(
    raw: []const u8,
    block_hash: [32]u8,
    block_number: u64,
    index: u32,
) TxResponse {
    return .{
        .hash = computeTxHash(raw),
        .blockHash = block_hash,
        .blockNumber = block_number,
        .transactionIndex = index,
        .from = primitives.Address.ZERO_ADDRESS,
        .to = null,
        .nonce = 0,
        .gas = 0,
        .value = 0,
        .input = &.{},
        .type_field = detectTxTypeField(raw),
        .chain_id = null,
        .gas_price = null,
        .max_fee_per_gas = null,
        .max_priority_fee_per_gas = null,
        .max_fee_per_blob_gas = null,
        .blob_versioned_hashes = null,
        .access_list = null,
        .authorization_list = null,
        .v = null,
        .r = null,
        .s = null,
        .y_parity = null,
    };
}

fn txResponseFromReceipt(
    allocator: std.mem.Allocator,
    receipt: primitives.Receipt.Receipt,
    block: ?primitives.Block.Block,
) !TxResponse {
    var input_bytes: []const u8 = &.{};
    if (block) |b| {
        const idx: usize = @intCast(receipt.transaction_index);
        if (idx < b.body.transactions.len) {
            // Best-effort: expose the raw envelope as input. A future tx
            // decoder can split this into nonce/value/input/signature.
            const raw = b.body.transactions[idx].raw;
            input_bytes = try allocator.dupe(u8, raw);
        }
    }

    const type_field = txTypeToU8(receipt.type);
    const tx_response = TxResponse{
        .hash = receipt.transaction_hash,
        .blockHash = receipt.block_hash,
        .blockNumber = receipt.block_number,
        .transactionIndex = receipt.transaction_index,
        .from = receipt.sender,
        .to = receipt.to,
        .nonce = 0,
        .gas = @intCast(@min(receipt.gas_used, @as(u256, std.math.maxInt(u64)))),
        .value = 0,
        .input = input_bytes,
        .type_field = type_field,
        .chain_id = null,
        .gas_price = if (type_field == 0 or type_field == 1) receipt.effective_gas_price else null,
        .max_fee_per_gas = if (type_field >= 2) receipt.effective_gas_price else null,
        .max_priority_fee_per_gas = null,
        .max_fee_per_blob_gas = if (type_field == 3) receipt.blob_gas_price else null,
        .blob_versioned_hashes = null,
        .access_list = null,
        .authorization_list = null,
        .v = null,
        .r = null,
        .s = null,
        .y_parity = null,
    };
    return tx_response;
}

fn detectTxTypeField(raw: []const u8) u8 {
    if (raw.len == 0) return 0;
    const first = raw[0];
    return switch (first) {
        0x01 => 1,
        0x02 => 2,
        0x03 => 3,
        0x04 => 4,
        else => 0, // legacy (RLP list prefix >= 0xc0)
    };
}

fn computeTxHash(raw: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(raw, &out, .{});
    return out;
}

fn txTypeToU8(t: primitives.Receipt.TransactionType) u8 {
    return switch (t) {
        .legacy => 0,
        .eip2930 => 1,
        .eip1559 => 2,
        .eip4844 => 3,
        .eip7702 => 4,
    };
}

fn receiptToResponse(
    allocator: std.mem.Allocator,
    receipt: primitives.Receipt.Receipt,
) !ReceiptResponse {
    const log_responses = try allocator.alloc(LogResponse, receipt.logs.len);
    for (receipt.logs, 0..) |log, i| {
        log_responses[i] = .{
            .address = log.address,
            .topics = log.topics,
            .data = log.data,
            .blockNumber = log.block_number,
            .blockHash = receipt.block_hash,
            .transactionHash = if (log.transaction_hash) |h| h else null,
            .transactionIndex = log.transaction_index,
            .logIndex = log.log_index,
            .removed = log.removed,
        };
    }

    return .{
        .transactionHash = receipt.transaction_hash,
        .transactionIndex = receipt.transaction_index,
        .blockHash = receipt.block_hash,
        .blockNumber = receipt.block_number,
        .from = receipt.sender,
        .to = receipt.to,
        .cumulativeGasUsed = receipt.cumulative_gas_used,
        .gasUsed = receipt.gas_used,
        .contractAddress = receipt.contract_address,
        .logs = log_responses,
        .logsBloom = receipt.logs_bloom,
        .status = if (receipt.status) |s| (if (s.success) @as(u8, 1) else @as(u8, 0)) else null,
        .root = receipt.root,
        .effectiveGasPrice = receipt.effective_gas_price,
        .type_field = txTypeToU8(receipt.type),
        .blobGasUsed = receipt.blob_gas_used,
        .blobGasPrice = receipt.blob_gas_price,
    };
}
