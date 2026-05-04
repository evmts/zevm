const std = @import("std");
const primitives = @import("primitives");
const blockchain_mod = @import("blockchain");
const receipt_index_mod = @import("../receipt_index.zig");
const log_index_mod = @import("../log_index.zig");
const tx_encoding = @import("../transaction_encoding.zig");

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
    ommersHash: [32]u8,
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
    uncleHashes: [][32]u8,
    withdrawals: ?[]const WithdrawalResponse,
};

pub const TxResponse = struct {
    hash: [32]u8,
    blockHash: ?[32]u8,
    blockNumber: ?u64,
    blockTimestamp: ?u64,
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

pub const WithdrawalResponse = struct {
    index: u64,
    validatorIndex: u64,
    address: primitives.Address.Address,
    amount: u64,
};

pub const LogResponse = struct {
    address: primitives.Address.Address,
    topics: []const [32]u8,
    data: []const u8,
    blockNumber: ?u64,
    blockHash: [32]u8,
    blockTimestamp: ?u64,
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

pub fn getBlockByNumberWithReceipts(
    allocator: std.mem.Allocator,
    bc: *blockchain_mod.Blockchain,
    ri: *const receipt_index_mod.ReceiptIndex,
    tag: []const u8,
    full_txs: bool,
) !?BlockResponse {
    const number = resolveBlockTag(bc, tag) orelse return null;
    const block = (try bc.getBlockByNumber(number)) orelse return null;
    return @as(?BlockResponse, try blockToResponseWithReceipts(allocator, block, full_txs, ri));
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

pub fn getBlockByHashWithReceipts(
    allocator: std.mem.Allocator,
    bc: *blockchain_mod.Blockchain,
    ri: *const receipt_index_mod.ReceiptIndex,
    hash: [32]u8,
    full_txs: bool,
) !?BlockResponse {
    const block = (try bc.getBlockByHash(hash)) orelse return null;
    return @as(?BlockResponse, try blockToResponseWithReceipts(allocator, block, full_txs, ri));
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
    return try receiptToResponse(allocator, receipt, null);
}

pub fn getTransactionReceiptWithBlock(
    allocator: std.mem.Allocator,
    bc: *blockchain_mod.Blockchain,
    ri: *const receipt_index_mod.ReceiptIndex,
    tx_hash: [32]u8,
) !?ReceiptResponse {
    const receipt = ri.getByTxHash(tx_hash) orelse return null;
    return try receiptToResponse(allocator, receipt, try timestampForReceipt(bc, receipt));
}

pub fn getBlockReceipts(
    allocator: std.mem.Allocator,
    bc: *blockchain_mod.Blockchain,
    ri: *const receipt_index_mod.ReceiptIndex,
    tag: []const u8,
) !?[]ReceiptResponse {
    const number = resolveBlockTag(bc, tag) orelse return null;
    const block = (try bc.getBlockByNumber(number)) orelse return null;
    return try receiptsForBlockHash(allocator, ri, block.hash, block.header.timestamp);
}

pub fn getBlockReceiptsByHash(
    allocator: std.mem.Allocator,
    bc: *blockchain_mod.Blockchain,
    ri: *const receipt_index_mod.ReceiptIndex,
    hash: [32]u8,
) !?[]ReceiptResponse {
    const block = (try bc.getBlockByHash(hash)) orelse return null;
    return try receiptsForBlockHash(allocator, ri, block.hash, block.header.timestamp);
}

fn receiptsForBlockHash(
    allocator: std.mem.Allocator,
    ri: *const receipt_index_mod.ReceiptIndex,
    block_hash: [32]u8,
    block_timestamp: ?u64,
) !?[]ReceiptResponse {
    const receipts = ri.getByBlockHash(block_hash) orelse {
        return try allocator.alloc(ReceiptResponse, 0);
    };

    const responses = try allocator.alloc(ReceiptResponse, receipts.len);
    errdefer allocator.free(responses);

    for (receipts, 0..) |receipt, i| {
        responses[i] = try receiptToResponse(allocator, receipt, block_timestamp);
    }

    return responses;
}

// ============================================================================
// Transaction Queries
// ============================================================================

/// Look up a transaction by hash. We don't carry a structured tx index; instead,
/// the receipt index tracks each mined tx. We use the receipt to locate the
/// containing block + index, then hydrate a TxResponse from the raw transaction
/// bytes where the envelope is a supported legacy transaction.
pub fn getTransactionByHash(
    allocator: std.mem.Allocator,
    bc: *blockchain_mod.Blockchain,
    ri: *const receipt_index_mod.ReceiptIndex,
    tx_hash: [32]u8,
) !?TxResponse {
    const receipt = ri.getByTxHash(tx_hash) orelse return try findTransactionByHashInBlocks(allocator, bc, tx_hash);
    const block = (try bc.getBlockByHash(receipt.block_hash)) orelse {
        // Receipt without block — degrade gracefully.
        return @as(?TxResponse, try txResponseFromReceipt(allocator, receipt, null));
    };
    return @as(?TxResponse, try txResponseFromReceipt(allocator, receipt, block));
}

fn findTransactionByHashInBlocks(
    allocator: std.mem.Allocator,
    bc: *blockchain_mod.Blockchain,
    tx_hash: [32]u8,
) !?TxResponse {
    const head = bc.getHeadBlockNumber() orelse return null;
    var block_number: u64 = 0;
    while (block_number <= head) : (block_number += 1) {
        const block = (try bc.getBlockByNumber(block_number)) orelse continue;
        for (block.body.transactions, 0..) |tx_data, index| {
            if (!std.mem.eql(u8, &computeTxHash(tx_data.raw), &tx_hash)) continue;
            if (index > std.math.maxInt(u32)) return null;
            return try txResponseFromRaw(
                allocator,
                tx_data.raw,
                block.hash,
                block.header.number,
                block.header.timestamp,
                @intCast(index),
                null,
                null,
            );
        }
    }
    return null;
}

pub fn getTransactionByBlockHashAndIndex(
    allocator: std.mem.Allocator,
    bc: *blockchain_mod.Blockchain,
    block_hash: [32]u8,
    index: u64,
) !?TxResponse {
    const block = (try bc.getBlockByHash(block_hash)) orelse return null;
    if (index >= block.body.transactions.len) return null;
    if (index > std.math.maxInt(u32)) return null;
    const tx_index: usize = @intCast(index);
    return try txResponseFromRaw(
        allocator,
        block.body.transactions[tx_index].raw,
        block.hash,
        block.header.number,
        block.header.timestamp,
        @intCast(index),
        null,
        null,
    );
}

pub fn getTransactionByBlockHashAndIndexWithReceipts(
    allocator: std.mem.Allocator,
    bc: *blockchain_mod.Blockchain,
    ri: *const receipt_index_mod.ReceiptIndex,
    block_hash: [32]u8,
    index: u64,
) !?TxResponse {
    const block = (try bc.getBlockByHash(block_hash)) orelse return null;
    if (index >= block.body.transactions.len) return null;
    if (index > std.math.maxInt(u32)) return null;
    const tx_index: usize = @intCast(index);
    const receipt = receiptForIndex(ri, block.hash, @intCast(index));
    return try txResponseFromRaw(
        allocator,
        block.body.transactions[tx_index].raw,
        block.hash,
        block.header.number,
        block.header.timestamp,
        @intCast(index),
        if (receipt) |r| r.sender else null,
        receipt,
    );
}

pub fn getTransactionByBlockNumberAndIndex(
    allocator: std.mem.Allocator,
    bc: *blockchain_mod.Blockchain,
    tag: []const u8,
    index: u64,
) !?TxResponse {
    const number = resolveBlockTag(bc, tag) orelse return null;
    const block = (try bc.getBlockByNumber(number)) orelse return null;
    if (index >= block.body.transactions.len) return null;
    if (index > std.math.maxInt(u32)) return null;
    const tx_index: usize = @intCast(index);
    return try txResponseFromRaw(
        allocator,
        block.body.transactions[tx_index].raw,
        block.hash,
        block.header.number,
        block.header.timestamp,
        @intCast(index),
        null,
        null,
    );
}

pub fn getTransactionByBlockNumberAndIndexWithReceipts(
    allocator: std.mem.Allocator,
    bc: *blockchain_mod.Blockchain,
    ri: *const receipt_index_mod.ReceiptIndex,
    tag: []const u8,
    index: u64,
) !?TxResponse {
    const number = resolveBlockTag(bc, tag) orelse return null;
    const block = (try bc.getBlockByNumber(number)) orelse return null;
    if (index >= block.body.transactions.len) return null;
    if (index > std.math.maxInt(u32)) return null;
    const tx_index: usize = @intCast(index);
    const receipt = receiptForIndex(ri, block.hash, @intCast(index));
    return try txResponseFromRaw(
        allocator,
        block.body.transactions[tx_index].raw,
        block.hash,
        block.header.number,
        block.header.timestamp,
        @intCast(index),
        if (receipt) |r| r.sender else null,
        receipt,
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
        const block_timestamp = if (entry.log.block_number) |number| blk: {
            const block = (try bc.getBlockByNumber(number)) orelse break :blk null;
            break :blk block.header.timestamp;
        } else null;
        responses[i] = .{
            .address = entry.log.address,
            .topics = entry.log.topics,
            .data = entry.log.data,
            .blockNumber = entry.log.block_number,
            .blockHash = entry.block_hash,
            .blockTimestamp = block_timestamp,
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
    return blockToResponseWithReceipts(allocator, block, full_txs, null);
}

fn blockToResponseWithReceipts(
    allocator: std.mem.Allocator,
    block: primitives.Block.Block,
    full_txs: bool,
    ri: ?*const receipt_index_mod.ReceiptIndex,
) !BlockResponse {
    const txs: TransactionList = if (full_txs) blk: {
        const full = try allocator.alloc(TxResponse, block.body.transactions.len);
        for (block.body.transactions, 0..) |tx_data, i| {
            const fallback_sender = if (ri) |receipt_index|
                receiptSenderForIndex(receipt_index, block.hash, @intCast(i))
            else
                null;
            const receipt = if (ri) |receipt_index|
                receiptForIndex(receipt_index, block.hash, @intCast(i))
            else
                null;
            full[i] = try txResponseFromRaw(
                allocator,
                tx_data.raw,
                block.hash,
                block.header.number,
                block.header.timestamp,
                @intCast(i),
                fallback_sender,
                receipt,
            );
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
        .ommersHash = block.header.ommers_hash,
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
        .uncleHashes = try uncleHashes(allocator, block.body.ommers),
        .withdrawals = if (block.body.withdrawals) |withdrawals| try copyWithdrawals(allocator, withdrawals) else null,
    };
}

fn uncleHashes(
    allocator: std.mem.Allocator,
    ommers: []const primitives.BlockBody.UncleHeader,
) ![][32]u8 {
    const hashes = try allocator.alloc([32]u8, ommers.len);
    for (ommers, 0..) |ommer, i| {
        var uncle = primitives.Uncle.Uncle{
            .parent_hash = ommer.parent_hash,
            .ommers_hash = ommer.ommers_hash,
            .beneficiary = ommer.beneficiary,
            .state_root = ommer.state_root,
            .transactions_root = ommer.transactions_root,
            .receipts_root = ommer.receipts_root,
            .logs_bloom = ommer.logs_bloom,
            .difficulty = ommer.difficulty,
            .number = ommer.number,
            .gas_limit = ommer.gas_limit,
            .gas_used = ommer.gas_used,
            .timestamp = ommer.timestamp,
            .extra_data = ommer.extra_data,
            .mix_hash = ommer.mix_hash,
            .nonce = ommer.nonce,
        };
        const encoded = try primitives.Uncle.rlpEncode(&uncle, allocator);
        defer allocator.free(encoded);
        std.crypto.hash.sha3.Keccak256.hash(encoded, &hashes[i], .{});
    }
    return hashes;
}

fn txResponseFromRaw(
    allocator: std.mem.Allocator,
    raw: []const u8,
    block_hash: [32]u8,
    block_number: u64,
    block_timestamp: u64,
    index: u32,
    fallback_sender: ?primitives.Address.Address,
    receipt: ?primitives.Receipt.Receipt,
) !TxResponse {
    var decoded = tx_encoding.decodeEnvelope(allocator, raw) catch blk: {
        if (detectTxTypeField(raw) == 0 and raw.len > 0 and raw[0] >= 0xc0 and fallback_sender != null) {
            if (tx_encoding.decodeLegacyEnvelopeAllowInvalidSignature(raw)) |tx| {
                break :blk tx_encoding.DecodedEnvelope{ .legacy = tx };
            } else |_| {}
        }
        return fallbackTxResponse(raw, block_hash, block_number, block_timestamp, index);
    };
    defer decoded.deinit(allocator);

    if (txResponseFromDecoded(
        allocator,
        raw,
        decoded,
        block_hash,
        block_number,
        block_timestamp,
        index,
        fallback_sender,
        receipt,
    )) |tx| {
        return tx;
    } else |_| {
        return fallbackTxResponse(raw, block_hash, block_number, block_timestamp, index);
    }
}

fn fallbackTxResponse(
    raw: []const u8,
    block_hash: [32]u8,
    block_number: u64,
    block_timestamp: u64,
    index: u32,
) TxResponse {
    return .{
        .hash = computeTxHash(raw),
        .blockHash = block_hash,
        .blockNumber = block_number,
        .blockTimestamp = block_timestamp,
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

fn txResponseFromDecoded(
    allocator: std.mem.Allocator,
    raw: []const u8,
    decoded: tx_encoding.DecodedEnvelope,
    block_hash: [32]u8,
    block_number: u64,
    block_timestamp: u64,
    index: u32,
    fallback_sender: ?primitives.Address.Address,
    receipt: ?primitives.Receipt.Receipt,
) !TxResponse {
    return switch (decoded) {
        .legacy => |tx| txResponseFromLegacy(allocator, raw, tx, block_hash, block_number, block_timestamp, index, fallback_sender),
        .eip2930 => |tx| .{
            .hash = computeTxHash(raw),
            .blockHash = block_hash,
            .blockNumber = block_number,
            .blockTimestamp = block_timestamp,
            .transactionIndex = index,
            .from = tx_encoding.recoverEnvelopeSender(allocator, decoded) catch (fallback_sender orelse primitives.Address.ZERO_ADDRESS),
            .to = tx.to,
            .nonce = tx.nonce,
            .gas = tx.gas_limit,
            .value = tx.value,
            .input = tx.data,
            .type_field = 1,
            .chain_id = tx.chain_id,
            .gas_price = tx.gas_price,
            .max_fee_per_gas = null,
            .max_priority_fee_per_gas = null,
            .max_fee_per_blob_gas = null,
            .blob_versioned_hashes = null,
            .access_list = try copyAccessList(allocator, tx.access_list),
            .authorization_list = null,
            .v = @as(u256, tx.y_parity),
            .r = tx_encoding.bytes32ToU256(tx.r),
            .s = tx_encoding.bytes32ToU256(tx.s),
            .y_parity = tx.y_parity,
        },
        .eip1559 => |tx| .{
            .hash = computeTxHash(raw),
            .blockHash = block_hash,
            .blockNumber = block_number,
            .blockTimestamp = block_timestamp,
            .transactionIndex = index,
            .from = tx_encoding.recoverEnvelopeSender(allocator, decoded) catch (fallback_sender orelse primitives.Address.ZERO_ADDRESS),
            .to = tx.to,
            .nonce = tx.nonce,
            .gas = tx.gas_limit,
            .value = tx.value,
            .input = tx.data,
            .type_field = 2,
            .chain_id = tx.chain_id,
            .gas_price = if (receipt) |r| r.effective_gas_price else tx.max_fee_per_gas,
            .max_fee_per_gas = tx.max_fee_per_gas,
            .max_priority_fee_per_gas = tx.max_priority_fee_per_gas,
            .max_fee_per_blob_gas = null,
            .blob_versioned_hashes = null,
            .access_list = try copyAccessList(allocator, tx.access_list),
            .authorization_list = null,
            .v = @as(u256, tx.y_parity),
            .r = tx_encoding.bytes32ToU256(tx.r),
            .s = tx_encoding.bytes32ToU256(tx.s),
            .y_parity = tx.y_parity,
        },
        .eip4844 => |tx| .{
            .hash = computeTxHash(raw),
            .blockHash = block_hash,
            .blockNumber = block_number,
            .blockTimestamp = block_timestamp,
            .transactionIndex = index,
            .from = tx_encoding.recoverEnvelopeSender(allocator, decoded) catch (fallback_sender orelse primitives.Address.ZERO_ADDRESS),
            .to = tx.to,
            .nonce = tx.nonce,
            .gas = tx.gas_limit,
            .value = tx.value,
            .input = tx.data,
            .type_field = 3,
            .chain_id = tx.chain_id,
            .gas_price = if (receipt) |r| r.effective_gas_price else tx.max_fee_per_gas,
            .max_fee_per_gas = tx.max_fee_per_gas,
            .max_priority_fee_per_gas = tx.max_priority_fee_per_gas,
            .max_fee_per_blob_gas = tx.max_fee_per_blob_gas,
            .blob_versioned_hashes = try copyBlobVersionedHashes(allocator, tx.blob_versioned_hashes),
            .access_list = try copyAccessList(allocator, tx.access_list),
            .authorization_list = null,
            .v = @as(u256, tx.y_parity),
            .r = tx_encoding.bytes32ToU256(tx.r),
            .s = tx_encoding.bytes32ToU256(tx.s),
            .y_parity = tx.y_parity,
        },
        .eip7702 => |tx| .{
            .hash = computeTxHash(raw),
            .blockHash = block_hash,
            .blockNumber = block_number,
            .blockTimestamp = block_timestamp,
            .transactionIndex = index,
            .from = tx_encoding.recoverEnvelopeSender(allocator, decoded) catch (fallback_sender orelse primitives.Address.ZERO_ADDRESS),
            .to = tx.to,
            .nonce = tx.nonce,
            .gas = tx.gas_limit,
            .value = tx.value,
            .input = tx.data,
            .type_field = 4,
            .chain_id = tx.chain_id,
            .gas_price = if (receipt) |r| r.effective_gas_price else tx.max_fee_per_gas,
            .max_fee_per_gas = tx.max_fee_per_gas,
            .max_priority_fee_per_gas = tx.max_priority_fee_per_gas,
            .max_fee_per_blob_gas = null,
            .blob_versioned_hashes = null,
            .access_list = try copyAccessList(allocator, tx.access_list),
            .authorization_list = try copyAuthorizationList(allocator, tx.authorization_list),
            .v = @as(u256, tx.y_parity),
            .r = tx_encoding.bytes32ToU256(tx.r),
            .s = tx_encoding.bytes32ToU256(tx.s),
            .y_parity = tx.y_parity,
        },
    };
}

fn receiptSenderForIndex(
    ri: *const receipt_index_mod.ReceiptIndex,
    block_hash: [32]u8,
    index: u32,
) ?primitives.Address.Address {
    return if (receiptForIndex(ri, block_hash, index)) |receipt| receipt.sender else null;
}

fn receiptForIndex(
    ri: *const receipt_index_mod.ReceiptIndex,
    block_hash: [32]u8,
    index: u32,
) ?primitives.Receipt.Receipt {
    const receipts = ri.getByBlockHash(block_hash) orelse return null;
    if (index >= receipts.len) return null;
    return receipts[index];
}

fn copyAccessList(
    allocator: std.mem.Allocator,
    access_list: []const primitives.Transaction.AccessListItem,
) ![]const TxAccessListEntry {
    const out = try allocator.alloc(TxAccessListEntry, access_list.len);
    for (access_list, 0..) |entry, i| {
        out[i] = .{
            .address = entry.address,
            .storage_keys = try allocator.dupe([32]u8, entry.storage_keys),
        };
    }
    return out;
}

fn copyAuthorizationList(
    allocator: std.mem.Allocator,
    authorization_list: []const primitives.Authorization.Authorization,
) ![]const TxAuthorizationEntry {
    const out = try allocator.alloc(TxAuthorizationEntry, authorization_list.len);
    for (authorization_list, 0..) |entry, i| {
        out[i] = .{
            .chain_id = entry.chain_id,
            .address = entry.address,
            .nonce = entry.nonce,
            .y_parity = @intCast(entry.v),
            .r = tx_encoding.bytes32ToU256(entry.r),
            .s = tx_encoding.bytes32ToU256(entry.s),
        };
    }
    return out;
}

fn copyBlobVersionedHashes(
    allocator: std.mem.Allocator,
    hashes: []const primitives.Blob.VersionedHash,
) ![]const [32]u8 {
    const out = try allocator.alloc([32]u8, hashes.len);
    for (hashes, 0..) |hash, i| {
        out[i] = hash.bytes;
    }
    return out;
}

fn copyWithdrawals(
    allocator: std.mem.Allocator,
    withdrawals: []const primitives.BlockBody.Withdrawal,
) ![]const WithdrawalResponse {
    const out = try allocator.alloc(WithdrawalResponse, withdrawals.len);
    for (withdrawals, 0..) |withdrawal, i| {
        out[i] = .{
            .index = withdrawal.index,
            .validatorIndex = withdrawal.validator_index,
            .address = withdrawal.address,
            .amount = withdrawal.amount,
        };
    }
    return out;
}

fn txResponseFromReceipt(
    allocator: std.mem.Allocator,
    receipt: primitives.Receipt.Receipt,
    block: ?primitives.Block.Block,
) !TxResponse {
    var raw_type_field: ?u8 = null;
    if (block) |b| {
        const idx: usize = @intCast(receipt.transaction_index);
        if (idx < b.body.transactions.len) {
            const raw = b.body.transactions[idx].raw;
            raw_type_field = detectTxTypeField(raw);
            return txResponseFromRaw(
                allocator,
                raw,
                receipt.block_hash,
                receipt.block_number,
                b.header.timestamp,
                receipt.transaction_index,
                receipt.sender,
                receipt,
            );
        }
    }

    const type_field = raw_type_field orelse txTypeToU8(receipt.type);
    const tx_response = TxResponse{
        .hash = receipt.transaction_hash,
        .blockHash = receipt.block_hash,
        .blockNumber = receipt.block_number,
        .blockTimestamp = if (block) |b| b.header.timestamp else null,
        .transactionIndex = receipt.transaction_index,
        .from = receipt.sender,
        .to = receipt.to,
        .nonce = 0,
        .gas = @intCast(@min(receipt.gas_used, @as(u256, std.math.maxInt(u64)))),
        .value = 0,
        .input = &.{},
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

fn txResponseFromLegacy(
    allocator: std.mem.Allocator,
    raw: []const u8,
    tx: primitives.Transaction.LegacyTransaction,
    block_hash: [32]u8,
    block_number: u64,
    block_timestamp: u64,
    index: u32,
    fallback_sender: ?primitives.Address.Address,
) !TxResponse {
    const sender = if (isUnsignedLegacyEnvelope(tx))
        (fallback_sender orelse primitives.Address.ZERO_ADDRESS)
    else
        tx_encoding.recoverLegacySender(allocator, tx) catch
            (fallback_sender orelse primitives.Address.ZERO_ADDRESS);

    return .{
        .hash = computeTxHash(raw),
        .blockHash = block_hash,
        .blockNumber = block_number,
        .blockTimestamp = block_timestamp,
        .transactionIndex = index,
        .from = sender,
        .to = tx.to,
        .nonce = tx.nonce,
        .gas = tx.gas_limit,
        .value = tx.value,
        .input = tx.data,
        .type_field = 0,
        .chain_id = tx_encoding.legacyChainId(tx),
        .gas_price = tx.gas_price,
        .max_fee_per_gas = null,
        .max_priority_fee_per_gas = null,
        .max_fee_per_blob_gas = null,
        .blob_versioned_hashes = null,
        .access_list = null,
        .authorization_list = null,
        .v = tx.v,
        .r = tx_encoding.bytes32ToU256(tx.r),
        .s = tx_encoding.bytes32ToU256(tx.s),
        .y_parity = tx_encoding.legacyRecoveryId(tx.v),
    };
}

fn isUnsignedLegacyEnvelope(tx: primitives.Transaction.LegacyTransaction) bool {
    return tx.v == 0 and
        std.mem.allEqual(u8, &tx.r, 0) and
        std.mem.allEqual(u8, &tx.s, 0);
}

fn detectTxTypeField(raw: []const u8) u8 {
    if (raw.len == 0) return 0;
    const first = raw[0];
    return switch (first) {
        0x01 => 1,
        0x02 => 2,
        0x03 => 3,
        0x04 => 4,
        else => if (first <= 0x7f) first else 0, // legacy is an RLP list prefix >= 0xc0
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
    block_timestamp: ?u64,
) !ReceiptResponse {
    const log_responses = try allocator.alloc(LogResponse, receipt.logs.len);
    for (receipt.logs, 0..) |log, i| {
        log_responses[i] = .{
            .address = log.address,
            .topics = log.topics,
            .data = log.data,
            .blockNumber = log.block_number,
            .blockHash = receipt.block_hash,
            .blockTimestamp = block_timestamp,
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

fn timestampForReceipt(
    bc: *blockchain_mod.Blockchain,
    receipt: primitives.Receipt.Receipt,
) !?u64 {
    const block = (try bc.getBlockByHash(receipt.block_hash)) orelse return null;
    return block.header.timestamp;
}
