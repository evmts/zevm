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
    totalDifficulty: u256,
    transactions: TransactionList,
};

pub const TxResponse = struct {
    blockHash: ?[32]u8,
    blockNumber: ?u64,
    from: primitives.Address.Address,
    gas: u64,
    hash: [32]u8,
    input: []const u8,
    nonce: u64,
    to: ?primitives.Address.Address,
    transactionIndex: ?u32,
    value: u256,
    type_field: u8,
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

pub fn blockToResponseFromBlock(
    allocator: std.mem.Allocator,
    block: primitives.Block.Block,
    full_txs: bool,
) !BlockResponse {
    return blockToResponse(allocator, block, full_txs);
}

pub fn getBlockTxCountByNumber(
    bc: *blockchain_mod.Blockchain,
    tag: []const u8,
) !?u64 {
    const number = resolveBlockTag(bc, tag) orelse return null;
    const block = (try bc.getBlockByNumber(number)) orelse return null;
    return block.body.transactions.len;
}

pub fn getBlockTxCountByHash(
    bc: *blockchain_mod.Blockchain,
    hash: [32]u8,
) !?u64 {
    const block = (try bc.getBlockByHash(hash)) orelse return null;
    return block.body.transactions.len;
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
    const receipts = ri.getByBlockHash(block.hash) orelse return null;

    const responses = try allocator.alloc(ReceiptResponse, receipts.len);
    errdefer allocator.free(responses);

    for (receipts, 0..) |receipt, i| {
        responses[i] = try receiptToResponse(allocator, receipt);
    }

    return responses;
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
            full[i] = try transactionToResponse(
                allocator,
                block.hash,
                block.header.number,
                tx_data.raw,
                @intCast(i),
            );
        }
        break :blk .{ .full = full };
    } else blk: {
        const hashes = try allocator.alloc([32]u8, block.body.transactions.len);
        for (block.body.transactions, 0..) |tx_data, i| {
            hashes[i] = txHash(tx_data.raw);
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
        .totalDifficulty = block.total_difficulty orelse 0,
        .transactions = txs,
    };
}

fn transactionToResponse(
    allocator: std.mem.Allocator,
    block_hash: [32]u8,
    block_number: u64,
    raw_tx: []const u8,
    transaction_index: u32,
) !TxResponse {
    const decoded = try primitives.Transaction.decodeRawTransaction(allocator, raw_tx);
    defer primitives.Transaction.deinitDecodedTransaction(allocator, decoded);

    const sender = primitives.Transaction.recoverSender(allocator, decoded) catch primitives.Address.ZERO_ADDRESS;
    const hash = txHash(raw_tx);

    return switch (decoded) {
        .legacy => |tx| .{
            .blockHash = block_hash,
            .blockNumber = block_number,
            .from = sender,
            .gas = tx.gas_limit,
            .hash = hash,
            .input = try allocator.dupe(u8, tx.data),
            .nonce = tx.nonce,
            .to = tx.to,
            .transactionIndex = transaction_index,
            .value = tx.value,
            .type_field = 0,
        },
        .eip2930 => |tx| .{
            .blockHash = block_hash,
            .blockNumber = block_number,
            .from = sender,
            .gas = tx.gas_limit,
            .hash = hash,
            .input = try allocator.dupe(u8, tx.data),
            .nonce = tx.nonce,
            .to = tx.to,
            .transactionIndex = transaction_index,
            .value = tx.value,
            .type_field = 1,
        },
        .eip1559 => |tx| .{
            .blockHash = block_hash,
            .blockNumber = block_number,
            .from = sender,
            .gas = tx.gas_limit,
            .hash = hash,
            .input = try allocator.dupe(u8, tx.data),
            .nonce = tx.nonce,
            .to = tx.to,
            .transactionIndex = transaction_index,
            .value = tx.value,
            .type_field = 2,
        },
        .eip4844 => |tx| .{
            .blockHash = block_hash,
            .blockNumber = block_number,
            .from = sender,
            .gas = tx.gas_limit,
            .hash = hash,
            .input = try allocator.dupe(u8, tx.data),
            .nonce = tx.nonce,
            .to = tx.to,
            .transactionIndex = transaction_index,
            .value = tx.value,
            .type_field = 3,
        },
        .eip7702 => |tx| .{
            .blockHash = block_hash,
            .blockNumber = block_number,
            .from = sender,
            .gas = tx.gas_limit,
            .hash = hash,
            .input = try allocator.dupe(u8, tx.data),
            .nonce = tx.nonce,
            .to = tx.to,
            .transactionIndex = transaction_index,
            .value = tx.value,
            .type_field = 4,
        },
    };
}

fn txHash(raw_tx: []const u8) [32]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(raw_tx, &hash, .{});
    return hash;
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

pub fn receiptToResponse(
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
