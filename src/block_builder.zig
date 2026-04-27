const std = @import("std");
const primitives = @import("primitives");
const state_manager = @import("state-manager");
const guillotine_mini = @import("guillotine_mini");
const tx_processor = @import("tx_processor.zig");

const INITIAL_BASE_FEE_PER_GAS: u256 = 1_000_000_000;
const BASE_FEE_CHANGE_DENOMINATOR: u256 = 8;
const GAS_LIMIT_ELASTICITY_MULTIPLIER: u64 = 2;
const WEI_PER_GWEI: u256 = 1_000_000_000;
const WEI_PER_ETHER: u256 = 1_000_000_000_000_000_000;
const HISTORY_BUFFER_LENGTH: u64 = 8191;
const CANCUN_MAX_BLOB_GAS_PER_BLOCK: u64 = 786_432;
const PRAGUE_MAX_BLOB_GAS_PER_BLOCK: u64 = 1_179_648;
const CANCUN_TARGET_BLOB_GAS_PER_BLOCK: u64 = 393_216;
const PRAGUE_TARGET_BLOB_GAS_PER_BLOCK: u64 = 786_432;

pub const BEACON_ROOTS_ADDRESS = primitives.Address{ .bytes = .{
    0x00, 0x0f, 0x3d, 0xf6, 0xd7, 0x32, 0x80, 0x7e, 0xf1, 0x31,
    0x9f, 0xb7, 0xb8, 0xbb, 0x85, 0x22, 0xd0, 0xbe, 0xac, 0x02,
} };

pub const SYSTEM_ADDRESS = primitives.Address{ .bytes = .{
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe,
} };

pub const Hardfork = enum(u8) {
    frontier,
    homestead,
    byzantium,
    constantinople,
    istanbul,
    berlin,
    london,
    paris,
    shanghai,
    cancun,
    prague,
};

pub const RequestsByType = struct {
    deposits: []const u8 = &.{},
    withdrawals: []const u8 = &.{},
    consolidations: []const u8 = &.{},
};

pub const BuildBlockOptions = struct {
    fork: Hardfork = .paris,
    withdrawals: ?[]const primitives.BlockBody.Withdrawal = null,
    parent_beacon_block_root: ?[32]u8 = null,
    requests: RequestsByType = .{},
    state_root: ?[32]u8 = null,
};

pub const BlockCommitments = struct {
    transactions_root: [32]u8,
    receipts_root: [32]u8,
    withdrawals_root: ?[32]u8,
    state_root: ?[32]u8,
    logs_bloom: [256]u8,
    blob_gas_used: u64,
    excess_blob_gas: ?u64,
    requests_hash: ?[32]u8,
};

pub const BlockResult = struct {
    receipts: []primitives.Receipt.Receipt,
    total_gas_used: u64,
    block_number: u64,
    transactions_root: [32]u8,
    receipts_root: [32]u8,
    withdrawals_root: ?[32]u8,
    state_root: ?[32]u8,
    logs_bloom: [256]u8,
    blob_gas_used: u64,
    requests_hash: ?[32]u8,

    pub fn deinit(self: *BlockResult, allocator: std.mem.Allocator) void {
        for (self.receipts) |receipt| {
            receipt.deinit(allocator);
        }
        allocator.free(self.receipts);
    }
};

pub const BlockValidationInput = struct {
    header: *const primitives.BlockHeader.BlockHeader,
    parent_header: *const primitives.BlockHeader.BlockHeader,
    fork: Hardfork = .paris,
    execution_transactions: []const tx_processor.ExecutionTx = &.{},
    transaction_envelopes: ?[]const primitives.BlockBody.TransactionData = null,
    receipts: []const primitives.Receipt.Receipt = &.{},
    withdrawals: ?[]const primitives.BlockBody.Withdrawal = null,
    state_root: ?[32]u8 = null,
    requests_hash: ?[32]u8 = null,
};

pub fn buildBlock(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    host_iface: guillotine_mini.HostInterface,
    transactions: []const tx_processor.ExecutionTx,
    block_ctx: guillotine_mini.BlockContext,
) !BlockResult {
    return buildBlockWithOptions(allocator, sm, host_iface, transactions, block_ctx, .{});
}

pub fn buildBlockWithOptions(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    host_iface: guillotine_mini.HostInterface,
    transactions: []const tx_processor.ExecutionTx,
    block_ctx: guillotine_mini.BlockContext,
    options: BuildBlockOptions,
) !BlockResult {
    try sm.checkpoint();
    var block_committed = false;
    errdefer if (!block_committed) sm.revert();

    if (options.parent_beacon_block_root) |root| {
        if (!atLeast(options.fork, .cancun)) return error.BeaconRootBeforeCancun;
        try applyBeaconRootsSystemCall(sm, block_ctx.block_timestamp, root);
    }

    var receipts = std.array_list.Managed(primitives.Receipt.Receipt).init(allocator);
    errdefer {
        for (receipts.items) |r| r.deinit(allocator);
        receipts.deinit();
    }

    var total_gas_used: u64 = 0;
    var total_blob_gas_used: u64 = 0;

    for (transactions) |item| {
        if (total_gas_used >= block_ctx.block_gas_limit) {
            break;
        }

        const remaining = block_ctx.block_gas_limit - total_gas_used;
        if (item.tx.gas_limit > remaining) {
            continue;
        }

        var receipt = tx_processor.processTransaction(
            allocator,
            sm,
            host_iface,
            item.caller,
            item.tx,
            block_ctx,
        ) catch |err| switch (err) {
            tx_processor.TxError.NonceMismatch,
            tx_processor.TxError.IntrinsicGasExceedsLimit,
            tx_processor.TxError.InsufficientBalance,
            tx_processor.TxError.GasPriceBelowBaseFee,
            => return error.InvalidIncludedTransaction,
            else => return err,
        };

        var receipt_appended = false;
        errdefer if (!receipt_appended) receipt.deinit(allocator);

        const gas_used_u64 = std.math.cast(u64, receipt.gas_used) orelse return error.GasOverflow;
        total_gas_used = std.math.add(u64, total_gas_used, gas_used_u64) catch return error.GasOverflow;
        total_blob_gas_used = std.math.add(u64, total_blob_gas_used, try receiptBlobGasUsed(receipt)) catch return error.BlobGasOverflow;
        receipt.cumulative_gas_used = @as(u256, total_gas_used);
        receipt.transaction_index = @as(u32, @intCast(receipts.items.len));
        try receipts.append(receipt);
        receipt_appended = true;
    }

    var withdrawals_root: ?[32]u8 = null;
    if (atLeast(options.fork, .shanghai)) {
        const withdrawals = options.withdrawals orelse return error.MissingWithdrawals;
        try applyWithdrawals(sm, withdrawals);
        withdrawals_root = try computeWithdrawalsRoot(allocator, withdrawals);
    } else if (options.withdrawals != null) {
        return error.WithdrawalsBeforeShanghai;
    }

    if (!atLeast(options.fork, .paris)) {
        try applyMinerReward(sm, block_ctx.block_coinbase, options.fork);
    }

    const transactions_root = try computeTransactionsRoot(allocator, transactions);
    const receipts_root = try computeReceiptsRoot(allocator, receipts.items);
    const logs_bloom = aggregateLogsBloom(receipts.items);
    const requests_hash = if (hasAnyRequests(options.requests)) computeRequestsHash(options.requests) else null;

    sm.commit();
    block_committed = true;

    return BlockResult{
        .receipts = try receipts.toOwnedSlice(),
        .total_gas_used = total_gas_used,
        .block_number = block_ctx.block_number,
        .transactions_root = transactions_root,
        .receipts_root = receipts_root,
        .withdrawals_root = withdrawals_root,
        .state_root = options.state_root,
        .logs_bloom = logs_bloom,
        .blob_gas_used = total_blob_gas_used,
        .requests_hash = requests_hash,
    };
}

pub fn validateBlock(allocator: std.mem.Allocator, input: BlockValidationInput) !BlockCommitments {
    try validateHeader(input.header, input.parent_header, input.fork);

    const tx_count = if (input.transaction_envelopes) |envelopes| envelopes.len else input.execution_transactions.len;
    if (tx_count != input.receipts.len) return error.TransactionReceiptCountMismatch;

    const transactions_root = if (input.transaction_envelopes) |envelopes|
        try computeRawTransactionsRoot(allocator, envelopes)
    else
        try computeTransactionsRoot(allocator, input.execution_transactions);

    if (!std.mem.eql(u8, &transactions_root, &input.header.transactions_root)) {
        return error.InvalidTransactionsRoot;
    }

    const receipts_root = try computeReceiptsRoot(allocator, input.receipts);
    if (!std.mem.eql(u8, &receipts_root, &input.header.receipts_root)) {
        return error.InvalidReceiptsRoot;
    }

    const logs_bloom = aggregateLogsBloom(input.receipts);
    if (!std.mem.eql(u8, &logs_bloom, &input.header.logs_bloom)) {
        return error.InvalidLogsBloom;
    }

    const gas_used = try receiptGasUsed(input.receipts);
    if (gas_used != input.header.gas_used) return error.InvalidGasUsed;

    const withdrawals_root = try validateWithdrawalsRoot(allocator, input.header, input.withdrawals, input.fork);

    if (input.state_root) |state_root| {
        if (!std.mem.eql(u8, &state_root, &input.header.state_root)) return error.InvalidStateRoot;
    }

    const blob_gas_used = try validateBlobGas(input.header, input.parent_header, input.receipts, input.fork);
    const requests_hash = input.requests_hash;

    return .{
        .transactions_root = transactions_root,
        .receipts_root = receipts_root,
        .withdrawals_root = withdrawals_root,
        .state_root = input.state_root,
        .logs_bloom = logs_bloom,
        .blob_gas_used = blob_gas_used,
        .excess_blob_gas = input.header.excess_blob_gas,
        .requests_hash = requests_hash,
    };
}

pub fn validateHeader(
    header: *const primitives.BlockHeader.BlockHeader,
    parent: *const primitives.BlockHeader.BlockHeader,
    fork: Hardfork,
) !void {
    if (header.gas_used > header.gas_limit) return error.HeaderGasUsedExceedsLimit;
    primitives.BlockHeader.validateGasLimitDelta(header, parent) catch return error.InvalidGasLimitDelta;
    primitives.BlockHeader.validateTimestampStrictlyGreater(header, parent) catch return error.InvalidTimestamp;
    if (parent.number == std.math.maxInt(u64)) return error.InvalidBlockNumber;
    if (header.number != parent.number + 1) return error.InvalidBlockNumber;
    if (header.extra_data.len > primitives.BlockHeader.MAX_EXTRA_DATA_SIZE) return error.ExtraDataTooLarge;

    if (atLeast(fork, .paris)) {
        if (header.difficulty != 0) return error.InvalidPostParisDifficulty;
        if (!std.mem.eql(u8, &header.nonce, &([_]u8{0} ** 8))) return error.InvalidPostParisNonce;
        if (!std.mem.eql(u8, &header.ommers_hash, &primitives.BlockHeader.EMPTY_OMMERS_HASH)) {
            return error.InvalidPostParisOmmersHash;
        }
    }

    if (atLeast(fork, .london)) {
        const actual_base_fee = header.base_fee_per_gas orelse return error.MissingBaseFeePerGas;
        const expected_base_fee = try expectedBaseFeePerGas(parent);
        if (actual_base_fee != expected_base_fee) return error.InvalidBaseFeePerGas;
    } else if (header.base_fee_per_gas != null) {
        return error.BaseFeeBeforeLondon;
    }

    if (!atLeast(fork, .shanghai) and header.withdrawals_root != null) return error.WithdrawalsRootBeforeShanghai;
    if (!atLeast(fork, .cancun) and (header.blob_gas_used != null or header.excess_blob_gas != null or header.parent_beacon_block_root != null)) {
        return error.BlobFieldsBeforeCancun;
    }
}

pub fn expectedBaseFeePerGas(parent: *const primitives.BlockHeader.BlockHeader) !u256 {
    const parent_base_fee = parent.base_fee_per_gas orelse return INITIAL_BASE_FEE_PER_GAS;
    const parent_gas_target = parent.gas_limit / GAS_LIMIT_ELASTICITY_MULTIPLIER;
    if (parent_gas_target == 0) return error.InvalidGasLimit;

    if (parent.gas_used == parent_gas_target) return parent_base_fee;

    if (parent.gas_used > parent_gas_target) {
        const gas_delta = parent.gas_used - parent_gas_target;
        const raw_delta = (@as(u512, parent_base_fee) * @as(u512, gas_delta)) /
            @as(u512, parent_gas_target) /
            @as(u512, BASE_FEE_CHANGE_DENOMINATOR);
        const base_fee_delta = @max(@as(u256, 1), @as(u256, @intCast(raw_delta)));
        return std.math.add(u256, parent_base_fee, base_fee_delta) catch return error.BaseFeeOverflow;
    }

    const gas_delta = parent_gas_target - parent.gas_used;
    const raw_delta = (@as(u512, parent_base_fee) * @as(u512, gas_delta)) /
        @as(u512, parent_gas_target) /
        @as(u512, BASE_FEE_CHANGE_DENOMINATOR);
    const base_fee_delta = @as(u256, @intCast(raw_delta));
    if (parent_base_fee > base_fee_delta) return parent_base_fee - base_fee_delta;
    return 0;
}

pub fn computeTransactionsRoot(
    allocator: std.mem.Allocator,
    transactions: []const tx_processor.ExecutionTx,
) ![32]u8 {
    const keys = try allocator.alloc([]const u8, transactions.len);
    defer allocator.free(keys);
    const values = try allocator.alloc([]const u8, transactions.len);
    defer allocator.free(values);

    var initialized: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < initialized) : (i += 1) {
            allocator.free(keys[i]);
            allocator.free(values[i]);
        }
    }
    defer {
        var i: usize = 0;
        while (i < initialized) : (i += 1) {
            allocator.free(keys[i]);
            allocator.free(values[i]);
        }
    }

    for (transactions, 0..) |item, i| {
        keys[i] = try primitives.Rlp.encode(allocator, @as(u64, @intCast(i)));
        values[i] = try encodeLegacyTransactionEnvelope(allocator, item.tx);
        initialized += 1;
    }

    return primitives.TrieHash.trie_root(allocator, keys, values);
}

pub fn computeRawTransactionsRoot(
    allocator: std.mem.Allocator,
    transactions: []const primitives.BlockBody.TransactionData,
) ![32]u8 {
    const keys = try allocator.alloc([]const u8, transactions.len);
    defer allocator.free(keys);
    const values = try allocator.alloc([]const u8, transactions.len);
    defer allocator.free(values);

    var initialized: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < initialized) : (i += 1) allocator.free(keys[i]);
    }
    defer {
        var i: usize = 0;
        while (i < initialized) : (i += 1) allocator.free(keys[i]);
    }

    for (transactions, 0..) |item, i| {
        keys[i] = try primitives.Rlp.encode(allocator, @as(u64, @intCast(i)));
        values[i] = item.raw;
        initialized += 1;
    }

    return primitives.TrieHash.trie_root(allocator, keys, values);
}

pub fn computeReceiptsRoot(
    allocator: std.mem.Allocator,
    receipts: []const primitives.Receipt.Receipt,
) ![32]u8 {
    const keys = try allocator.alloc([]const u8, receipts.len);
    defer allocator.free(keys);
    const values = try allocator.alloc([]const u8, receipts.len);
    defer allocator.free(values);

    var initialized: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < initialized) : (i += 1) {
            allocator.free(keys[i]);
            allocator.free(values[i]);
        }
    }
    defer {
        var i: usize = 0;
        while (i < initialized) : (i += 1) {
            allocator.free(keys[i]);
            allocator.free(values[i]);
        }
    }

    for (receipts, 0..) |receipt, i| {
        keys[i] = try primitives.Rlp.encode(allocator, @as(u64, @intCast(i)));
        values[i] = try encodeReceiptEnvelope(allocator, receipt);
        initialized += 1;
    }

    return primitives.TrieHash.trie_root(allocator, keys, values);
}

pub fn computeWithdrawalsRoot(
    allocator: std.mem.Allocator,
    withdrawals: []const primitives.BlockBody.Withdrawal,
) ![32]u8 {
    const keys = try allocator.alloc([]const u8, withdrawals.len);
    defer allocator.free(keys);
    const values = try allocator.alloc([]const u8, withdrawals.len);
    defer allocator.free(values);

    var initialized: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < initialized) : (i += 1) {
            allocator.free(keys[i]);
            allocator.free(values[i]);
        }
    }
    defer {
        var i: usize = 0;
        while (i < initialized) : (i += 1) {
            allocator.free(keys[i]);
            allocator.free(values[i]);
        }
    }

    for (withdrawals, 0..) |withdrawal, i| {
        keys[i] = try primitives.Rlp.encode(allocator, @as(u64, @intCast(i)));
        values[i] = try encodeWithdrawal(allocator, withdrawal);
        initialized += 1;
    }

    return primitives.TrieHash.trie_root(allocator, keys, values);
}

pub fn aggregateLogsBloom(receipts: []const primitives.Receipt.Receipt) [256]u8 {
    var logs_bloom: [256]u8 = [_]u8{0} ** 256;
    for (receipts) |receipt| {
        for (receipt.logs_bloom, 0..) |byte, i| {
            logs_bloom[i] |= byte;
        }
    }
    return logs_bloom;
}

pub fn applyWithdrawals(
    sm: *state_manager.StateManager,
    withdrawals: []const primitives.BlockBody.Withdrawal,
) !void {
    for (withdrawals) |withdrawal| {
        const credit = std.math.mul(u256, @as(u256, withdrawal.amount), WEI_PER_GWEI) catch return error.WithdrawalAmountOverflow;
        const balance = try sm.getBalance(withdrawal.address);
        const new_balance = std.math.add(u256, balance, credit) catch return error.BalanceOverflow;
        try sm.setBalance(withdrawal.address, new_balance);
    }
}

pub fn applyBeaconRootsSystemCall(
    sm: *state_manager.StateManager,
    timestamp: u64,
    parent_beacon_block_root: [32]u8,
) !void {
    const slot = timestamp % HISTORY_BUFFER_LENGTH;
    const root_value = std.mem.readInt(u256, &parent_beacon_block_root, .big);
    try sm.setStorage(BEACON_ROOTS_ADDRESS, @as(u256, slot), @as(u256, timestamp));
    try sm.setStorage(BEACON_ROOTS_ADDRESS, @as(u256, slot + HISTORY_BUFFER_LENGTH), root_value);
}

pub fn computeRequestsHash(requests: RequestsByType) [32]u8 {
    var hashes: [96]u8 = undefined;
    var len: usize = 0;

    if (requests.deposits.len > 0) {
        std.crypto.hash.sha2.Sha256.hash(requests.deposits, hashes[len..][0..32], .{});
        len += 32;
    }
    if (requests.withdrawals.len > 0) {
        std.crypto.hash.sha2.Sha256.hash(requests.withdrawals, hashes[len..][0..32], .{});
        len += 32;
    }
    if (requests.consolidations.len > 0) {
        std.crypto.hash.sha2.Sha256.hash(requests.consolidations, hashes[len..][0..32], .{});
        len += 32;
    }

    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(hashes[0..len], &out, .{});
    return out;
}

pub fn blockRewardWei(fork: Hardfork) ?u256 {
    return switch (fork) {
        .frontier, .homestead => 5 * WEI_PER_ETHER,
        .byzantium => 3 * WEI_PER_ETHER,
        .constantinople, .istanbul, .berlin, .london => 2 * WEI_PER_ETHER,
        .paris, .shanghai, .cancun, .prague => null,
    };
}

pub fn applyMinerReward(sm: *state_manager.StateManager, beneficiary: primitives.Address, fork: Hardfork) !void {
    const reward = blockRewardWei(fork) orelse return;
    const balance = try sm.getBalance(beneficiary);
    const new_balance = std.math.add(u256, balance, reward) catch return error.BalanceOverflow;
    try sm.setBalance(beneficiary, new_balance);
}

pub fn maxBlobGasPerBlock(fork: Hardfork) ?u64 {
    return switch (fork) {
        .cancun => CANCUN_MAX_BLOB_GAS_PER_BLOCK,
        .prague => PRAGUE_MAX_BLOB_GAS_PER_BLOCK,
        else => null,
    };
}

pub fn calculateExcessBlobGasForFork(fork: Hardfork, parent_excess_blob_gas: u64, parent_blob_gas_used: u64) u64 {
    const target = if (atLeast(fork, .prague)) PRAGUE_TARGET_BLOB_GAS_PER_BLOCK else CANCUN_TARGET_BLOB_GAS_PER_BLOCK;
    if (parent_excess_blob_gas + parent_blob_gas_used < target) return 0;
    return parent_excess_blob_gas + parent_blob_gas_used - target;
}

fn validateWithdrawalsRoot(
    allocator: std.mem.Allocator,
    header: *const primitives.BlockHeader.BlockHeader,
    withdrawals: ?[]const primitives.BlockBody.Withdrawal,
    fork: Hardfork,
) !?[32]u8 {
    if (!atLeast(fork, .shanghai)) {
        if (withdrawals != null) return error.WithdrawalsBeforeShanghai;
        if (header.withdrawals_root != null) return error.WithdrawalsRootBeforeShanghai;
        return null;
    }

    const actual_withdrawals = withdrawals orelse return error.MissingWithdrawals;
    const expected_root = try computeWithdrawalsRoot(allocator, actual_withdrawals);
    const header_root = header.withdrawals_root orelse return error.MissingWithdrawalsRoot;
    if (!std.mem.eql(u8, &expected_root, &header_root)) return error.InvalidWithdrawalsRoot;
    return expected_root;
}

fn validateBlobGas(
    header: *const primitives.BlockHeader.BlockHeader,
    parent: *const primitives.BlockHeader.BlockHeader,
    receipts: []const primitives.Receipt.Receipt,
    fork: Hardfork,
) !u64 {
    const actual_blob_gas = try blobGasUsedFromReceipts(receipts);

    if (!atLeast(fork, .cancun)) {
        if (actual_blob_gas != 0) return error.BlobGasBeforeCancun;
        if (header.blob_gas_used != null or header.excess_blob_gas != null) return error.BlobFieldsBeforeCancun;
        return 0;
    }

    const header_blob_gas = header.blob_gas_used orelse return error.MissingBlobGasUsed;
    if (header_blob_gas != actual_blob_gas) return error.InvalidBlobGasUsed;

    const cap = maxBlobGasPerBlock(fork).?;
    if (actual_blob_gas > cap) return error.BlobGasLimitExceeded;

    const header_excess = header.excess_blob_gas orelse return error.MissingExcessBlobGas;
    const expected_excess = calculateExcessBlobGasForFork(fork, parent.excess_blob_gas orelse 0, parent.blob_gas_used orelse 0);
    if (header_excess != expected_excess) return error.InvalidExcessBlobGas;

    return actual_blob_gas;
}

fn receiptGasUsed(receipts: []const primitives.Receipt.Receipt) !u64 {
    if (receipts.len == 0) return 0;
    return std.math.cast(u64, receipts[receipts.len - 1].cumulative_gas_used) orelse error.GasOverflow;
}

fn blobGasUsedFromReceipts(receipts: []const primitives.Receipt.Receipt) !u64 {
    var total: u64 = 0;
    for (receipts) |receipt| {
        total = std.math.add(u64, total, try receiptBlobGasUsed(receipt)) catch return error.BlobGasOverflow;
    }
    return total;
}

fn receiptBlobGasUsed(receipt: primitives.Receipt.Receipt) !u64 {
    const blob_gas = receipt.blob_gas_used orelse return 0;
    return std.math.cast(u64, blob_gas) orelse error.BlobGasOverflow;
}

fn encodeLegacyTransactionEnvelope(
    allocator: std.mem.Allocator,
    tx: primitives.Transaction.LegacyTransaction,
) ![]u8 {
    var fields = std.ArrayList([]u8){};
    defer freeEncodedFields(allocator, &fields);

    try fields.append(allocator, try primitives.Rlp.encode(allocator, tx.nonce));
    try fields.append(allocator, try primitives.Rlp.encode(allocator, tx.gas_price));
    try fields.append(allocator, try primitives.Rlp.encode(allocator, tx.gas_limit));
    if (tx.to) |to| {
        try fields.append(allocator, try primitives.Rlp.encodeBytes(allocator, &to.bytes));
    } else {
        try fields.append(allocator, try primitives.Rlp.encodeBytes(allocator, &.{}));
    }
    try fields.append(allocator, try primitives.Rlp.encode(allocator, tx.value));
    try fields.append(allocator, try primitives.Rlp.encodeBytes(allocator, tx.data));
    try fields.append(allocator, try primitives.Rlp.encode(allocator, tx.v));
    try fields.append(allocator, try primitives.Rlp.encode(allocator, std.mem.readInt(u256, &tx.r, .big)));
    try fields.append(allocator, try primitives.Rlp.encode(allocator, std.mem.readInt(u256, &tx.s, .big)));

    return encodeRlpListFromEncodedFields(allocator, fields.items);
}

fn encodeReceiptEnvelope(
    allocator: std.mem.Allocator,
    receipt: primitives.Receipt.Receipt,
) ![]u8 {
    const payload = try encodeReceiptPayload(allocator, receipt);
    errdefer allocator.free(payload);

    const type_byte: ?u8 = switch (receipt.type) {
        .legacy => null,
        .eip2930 => 0x01,
        .eip1559 => 0x02,
        .eip4844 => 0x03,
        .eip7702 => 0x04,
    };

    if (type_byte) |byte| {
        const out = try allocator.alloc(u8, payload.len + 1);
        out[0] = byte;
        @memcpy(out[1..], payload);
        allocator.free(payload);
        return out;
    }

    return payload;
}

fn encodeReceiptPayload(
    allocator: std.mem.Allocator,
    receipt: primitives.Receipt.Receipt,
) ![]u8 {
    var fields = std.ArrayList([]u8){};
    defer freeEncodedFields(allocator, &fields);

    if (receipt.root) |root| {
        try fields.append(allocator, try primitives.Rlp.encodeBytes(allocator, &root));
    } else if (receipt.status) |status| {
        try fields.append(allocator, try primitives.Rlp.encode(allocator, @as(u8, if (status.success) 1 else 0)));
    } else {
        return error.InvalidReceipt;
    }

    try fields.append(allocator, try primitives.Rlp.encode(allocator, receipt.cumulative_gas_used));
    try fields.append(allocator, try primitives.Rlp.encodeBytes(allocator, &receipt.logs_bloom));
    try fields.append(allocator, try encodeLogs(allocator, receipt.logs));

    return encodeRlpListFromEncodedFields(allocator, fields.items);
}

fn encodeLogs(
    allocator: std.mem.Allocator,
    logs: []const primitives.EventLog.EventLog,
) ![]u8 {
    var fields = std.ArrayList([]u8){};
    defer freeEncodedFields(allocator, &fields);

    for (logs) |log| {
        try fields.append(allocator, try encodeLog(allocator, log));
    }

    return encodeRlpListFromEncodedFields(allocator, fields.items);
}

fn encodeLog(
    allocator: std.mem.Allocator,
    log: primitives.EventLog.EventLog,
) ![]u8 {
    var fields = std.ArrayList([]u8){};
    defer freeEncodedFields(allocator, &fields);

    try fields.append(allocator, try primitives.Rlp.encodeBytes(allocator, &log.address.bytes));
    try fields.append(allocator, try encodeTopics(allocator, log.topics));
    try fields.append(allocator, try primitives.Rlp.encodeBytes(allocator, log.data));

    return encodeRlpListFromEncodedFields(allocator, fields.items);
}

fn encodeTopics(
    allocator: std.mem.Allocator,
    topics: []const primitives.Hash.Hash,
) ![]u8 {
    var fields = std.ArrayList([]u8){};
    defer freeEncodedFields(allocator, &fields);

    for (topics) |topic| {
        try fields.append(allocator, try primitives.Rlp.encodeBytes(allocator, &topic));
    }

    return encodeRlpListFromEncodedFields(allocator, fields.items);
}

fn encodeWithdrawal(
    allocator: std.mem.Allocator,
    withdrawal: primitives.BlockBody.Withdrawal,
) ![]u8 {
    var fields = std.ArrayList([]u8){};
    defer freeEncodedFields(allocator, &fields);

    try fields.append(allocator, try primitives.Rlp.encode(allocator, withdrawal.index));
    try fields.append(allocator, try primitives.Rlp.encode(allocator, withdrawal.validator_index));
    try fields.append(allocator, try primitives.Rlp.encodeBytes(allocator, &withdrawal.address.bytes));
    try fields.append(allocator, try primitives.Rlp.encode(allocator, withdrawal.amount));

    return encodeRlpListFromEncodedFields(allocator, fields.items);
}

fn encodeRlpListFromEncodedFields(
    allocator: std.mem.Allocator,
    fields: []const []const u8,
) ![]u8 {
    var total_len: usize = 0;
    for (fields) |field| {
        total_len = std.math.add(usize, total_len, field.len) catch return error.RlpPayloadTooLarge;
    }

    var result = std.ArrayList(u8){};
    defer result.deinit(allocator);

    if (total_len < 56) {
        try result.append(allocator, 0xc0 + @as(u8, @intCast(total_len)));
    } else {
        const len_bytes = try primitives.Rlp.encodeLength(allocator, total_len);
        defer allocator.free(len_bytes);
        try result.append(allocator, 0xf7 + @as(u8, @intCast(len_bytes.len)));
        try result.appendSlice(allocator, len_bytes);
    }

    for (fields) |field| {
        try result.appendSlice(allocator, field);
    }

    return try result.toOwnedSlice(allocator);
}

fn freeEncodedFields(allocator: std.mem.Allocator, fields: *std.ArrayList([]u8)) void {
    for (fields.items) |field| {
        allocator.free(field);
    }
    fields.deinit(allocator);
}

fn hasAnyRequests(requests: RequestsByType) bool {
    return requests.deposits.len != 0 or requests.withdrawals.len != 0 or requests.consolidations.len != 0;
}

fn atLeast(fork: Hardfork, minimum: Hardfork) bool {
    return @intFromEnum(fork) >= @intFromEnum(minimum);
}
