const std = @import("std");
const blockchain_mod = @import("blockchain");
const primitives = @import("primitives");

const RlpKind = enum {
    string,
    list,
};

const RlpSpan = struct {
    start: usize,
    end: usize,
    payload_start: usize,
    payload_end: usize,
    kind: RlpKind,
};

pub const ImportStats = struct {
    block_count: usize = 0,
    transaction_count: usize = 0,
    head_block_number: u64 = 0,
    head_hash: [32]u8 = primitives.Hash.ZERO,
};

pub const OwnedBlockBody = struct {
    block_hash: [32]u8 = primitives.Hash.ZERO,
    header_extra_data: ?[]u8 = null,
    transactions: []const primitives.BlockBody.TransactionData = &.{},
    ommers: []const primitives.BlockBody.UncleHeader = &.{},
    withdrawals: ?[]const primitives.BlockBody.Withdrawal = null,
    requests_hash: ?[32]u8 = null,

    pub fn deinit(self: *OwnedBlockBody, allocator: std.mem.Allocator) void {
        if (self.header_extra_data) |bytes| {
            allocator.free(bytes);
            self.header_extra_data = null;
        }

        for (self.transactions) |tx| {
            allocator.free(tx.raw);
        }
        if (self.transactions.len > 0) allocator.free(self.transactions);
        self.transactions = &.{};

        for (self.ommers) |ommer| {
            if (ommer.extra_data.len > 0) allocator.free(ommer.extra_data);
        }
        if (self.ommers.len > 0) allocator.free(self.ommers);
        self.ommers = &.{};

        if (self.withdrawals) |withdrawals| {
            if (withdrawals.len > 0) allocator.free(withdrawals);
            self.withdrawals = null;
        }
    }
};

pub const DecodedBlock = struct {
    block: primitives.Block.Block,
    owned_body: OwnedBlockBody,

    pub fn deinit(self: *DecodedBlock, allocator: std.mem.Allocator) void {
        self.owned_body.deinit(allocator);
    }
};

pub fn importChainFile(
    allocator: std.mem.Allocator,
    blockchain: *blockchain_mod.Blockchain,
    owned_block_bodies: *std.ArrayList(OwnedBlockBody),
    path: []const u8,
) !ImportStats {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 512 * 1024 * 1024);
    defer allocator.free(bytes);
    return try importChainBytes(allocator, blockchain, owned_block_bodies, bytes);
}

pub fn importChainBytes(
    allocator: std.mem.Allocator,
    blockchain: *blockchain_mod.Blockchain,
    owned_block_bodies: *std.ArrayList(OwnedBlockBody),
    bytes: []const u8,
) !ImportStats {
    var stats = ImportStats{};
    var offset: usize = 0;
    while (offset < bytes.len) {
        var decoded = try decodeNextBlock(allocator, bytes[offset..]);
        var owned = false;
        errdefer if (!owned) decoded.deinit(allocator);

        stats.transaction_count += decoded.block.body.transactions.len;
        stats.head_block_number = decoded.block.header.number;
        stats.head_hash = decoded.block.hash;

        try blockchain.putBlock(decoded.block);
        try owned_block_bodies.append(allocator, decoded.owned_body);
        owned = true;
        try blockchain.setCanonicalHead(decoded.block.hash);

        offset += decodedBlockLength(bytes[offset..]);
        stats.block_count += 1;
    }
    return stats;
}

pub fn decodeNextBlock(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !DecodedBlock {
    const span = try itemSpan(bytes, 0);
    if (span.kind != .list) return error.InvalidChainRlp;

    const block_bytes = bytes[span.start..span.end];
    const block_fields = try childSpans(allocator, block_bytes, span.payload_start, span.payload_end);
    defer allocator.free(block_fields);
    if (block_fields.len != 3 and block_fields.len != 4) return error.InvalidChainRlp;

    const header_span = block_fields[0];
    if (header_span.kind != .list) return error.InvalidChainRlp;
    var owned_body = OwnedBlockBody{};
    errdefer owned_body.deinit(allocator);

    const header_bytes = block_bytes[header_span.start..header_span.end];
    var header = try decodeHeaderForImport(allocator, header_bytes);
    owned_body.requests_hash = try decodeHeaderRequestsHash(allocator, header_bytes);
    owned_body.header_extra_data = try decodeHeaderExtraData(allocator, header_bytes);
    header.extra_data = owned_body.header_extra_data orelse &.{};

    owned_body.transactions = try decodeTransactions(allocator, block_bytes, block_fields[1]);
    owned_body.ommers = try decodeOmmers(allocator, block_bytes, block_fields[2]);
    if (block_fields.len == 4) {
        owned_body.withdrawals = try decodeWithdrawals(allocator, block_bytes, block_fields[3]);
    }

    const body = primitives.BlockBody.BlockBody{
        .transactions = owned_body.transactions,
        .ommers = owned_body.ommers,
        .withdrawals = owned_body.withdrawals,
    };

    var block = try primitives.Block.from(&header, &body, allocator);
    std.crypto.hash.sha3.Keccak256.hash(header_bytes, &block.hash, .{});
    block.size = @intCast(block_bytes.len);
    owned_body.block_hash = block.hash;
    return .{
        .block = block,
        .owned_body = owned_body,
    };
}

fn decodeHeaderForImport(
    allocator: std.mem.Allocator,
    header_bytes: []const u8,
) !primitives.BlockHeader.BlockHeader {
    const header_span = try itemSpan(header_bytes, 0);
    if (header_span.kind != .list or header_span.start != 0 or header_span.end != header_bytes.len) return error.InvalidChainRlp;

    const fields = try childSpans(allocator, header_bytes, header_span.payload_start, header_span.payload_end);
    defer allocator.free(fields);
    if (fields.len < 15) return error.InvalidChainRlp;

    var header = primitives.BlockHeader.BlockHeader{};
    header.parent_hash = try parseRlpHash(header_bytes, fields[0]);
    header.ommers_hash = try parseRlpHash(header_bytes, fields[1]);
    header.beneficiary = try parseRlpAddress(header_bytes, fields[2]);
    header.state_root = try parseRlpHash(header_bytes, fields[3]);
    header.transactions_root = try parseRlpHash(header_bytes, fields[4]);
    header.receipts_root = try parseRlpHash(header_bytes, fields[5]);
    header.logs_bloom = try parseRlpBloom(header_bytes, fields[6]);
    header.difficulty = try parseRlpU256Field(header_bytes, fields[7]);
    header.number = try parseRlpU64Field(header_bytes, fields[8]);
    header.gas_limit = try parseRlpU64Field(header_bytes, fields[9]);
    header.gas_used = try parseRlpU64Field(header_bytes, fields[10]);
    header.timestamp = try parseRlpU64Field(header_bytes, fields[11]);
    header.extra_data = header_bytes[fields[12].payload_start..fields[12].payload_end];
    header.mix_hash = try parseRlpHash(header_bytes, fields[13]);
    header.nonce = try parseRlpNonce(header_bytes, fields[14]);

    if (fields.len > 15) header.base_fee_per_gas = try parseRlpU256Field(header_bytes, fields[15]);
    if (fields.len > 16) header.withdrawals_root = try parseRlpHash(header_bytes, fields[16]);
    if (fields.len > 17) header.blob_gas_used = try parseRlpU64Field(header_bytes, fields[17]);
    if (fields.len > 18) header.excess_blob_gas = try parseRlpU64Field(header_bytes, fields[18]);
    if (fields.len > 19) header.parent_beacon_block_root = try parseRlpHash(header_bytes, fields[19]);

    return header;
}

fn decodeHeaderRequestsHash(allocator: std.mem.Allocator, header_bytes: []const u8) !?[32]u8 {
    const header_span = try itemSpan(header_bytes, 0);
    if (header_span.kind != .list or header_span.start != 0 or header_span.end != header_bytes.len) return error.InvalidChainRlp;

    const fields = try childSpans(allocator, header_bytes, header_span.payload_start, header_span.payload_end);
    defer allocator.free(fields);
    if (fields.len <= 20) return null;
    return try parseRlpHash(header_bytes, fields[20]);
}

pub fn cloneBlockBody(
    allocator: std.mem.Allocator,
    block: *primitives.Block.Block,
) !OwnedBlockBody {
    var owned = OwnedBlockBody{};
    errdefer owned.deinit(allocator);
    owned.block_hash = block.hash;

    if (block.header.extra_data.len > 0) {
        owned.header_extra_data = try allocator.dupe(u8, block.header.extra_data);
        block.header.extra_data = owned.header_extra_data.?;
    }

    owned.transactions = try cloneTransactions(allocator, block.body.transactions);
    block.body.transactions = owned.transactions;

    owned.ommers = try cloneOmmers(allocator, block.body.ommers);
    block.body.ommers = owned.ommers;

    if (block.body.withdrawals) |withdrawals| {
        owned.withdrawals = try cloneWithdrawals(allocator, withdrawals);
        block.body.withdrawals = owned.withdrawals;
    }

    return owned;
}

pub fn freeTransactions(
    allocator: std.mem.Allocator,
    transactions: []const primitives.BlockBody.TransactionData,
) void {
    for (transactions) |tx| {
        allocator.free(tx.raw);
    }
    if (transactions.len > 0) allocator.free(transactions);
}

fn decodedBlockLength(bytes: []const u8) usize {
    const span = itemSpan(bytes, 0) catch unreachable;
    return span.end;
}

fn decodeHeaderExtraData(allocator: std.mem.Allocator, header_bytes: []const u8) !?[]u8 {
    const header_span = try itemSpan(header_bytes, 0);
    if (header_span.kind != .list) return error.InvalidChainRlp;
    const fields = try childSpans(allocator, header_bytes, header_span.payload_start, header_span.payload_end);
    defer allocator.free(fields);
    if (fields.len < 15 or fields[12].kind != .string) return error.InvalidChainRlp;

    const extra_data = header_bytes[fields[12].payload_start..fields[12].payload_end];
    if (extra_data.len == 0) return null;
    return try allocator.dupe(u8, extra_data);
}

fn decodeTransactions(
    allocator: std.mem.Allocator,
    block_bytes: []const u8,
    tx_list_span: RlpSpan,
) ![]const primitives.BlockBody.TransactionData {
    if (tx_list_span.kind != .list) return error.InvalidChainRlp;
    const tx_spans = try childSpans(allocator, block_bytes, tx_list_span.payload_start, tx_list_span.payload_end);
    defer allocator.free(tx_spans);
    if (tx_spans.len == 0) return &.{};

    const transactions = try allocator.alloc(primitives.BlockBody.TransactionData, tx_spans.len);
    var initialized: usize = 0;
    errdefer {
        for (transactions[0..initialized]) |tx| allocator.free(tx.raw);
        allocator.free(transactions);
    }

    for (tx_spans, 0..) |tx_span, index| {
        const raw = switch (tx_span.kind) {
            .list => block_bytes[tx_span.start..tx_span.end],
            .string => block_bytes[tx_span.payload_start..tx_span.payload_end],
        };
        transactions[index] = .{ .raw = try allocator.dupe(u8, raw) };
        initialized += 1;
    }

    return transactions;
}

fn decodeOmmers(
    allocator: std.mem.Allocator,
    block_bytes: []const u8,
    ommers_span: RlpSpan,
) ![]const primitives.BlockBody.UncleHeader {
    if (ommers_span.kind != .list) return error.InvalidChainRlp;
    const ommer_spans = try childSpans(allocator, block_bytes, ommers_span.payload_start, ommers_span.payload_end);
    defer allocator.free(ommer_spans);
    if (ommer_spans.len == 0) return &.{};

    const ommers = try allocator.alloc(primitives.BlockBody.UncleHeader, ommer_spans.len);
    var initialized: usize = 0;
    errdefer {
        for (ommers[0..initialized]) |ommer| {
            if (ommer.extra_data.len > 0) allocator.free(ommer.extra_data);
        }
        allocator.free(ommers);
    }

    for (ommer_spans, 0..) |ommer_span, index| {
        if (ommer_span.kind != .list) return error.InvalidChainRlp;
        const header_bytes = block_bytes[ommer_span.start..ommer_span.end];
        const header = try primitives.BlockHeader.rlpDecode(allocator, header_bytes);
        const extra_data = try decodeHeaderExtraData(allocator, header_bytes);
        errdefer if (extra_data) |bytes| allocator.free(bytes);
        ommers[index] = .{
            .parent_hash = header.parent_hash,
            .ommers_hash = header.ommers_hash,
            .beneficiary = header.beneficiary,
            .state_root = header.state_root,
            .transactions_root = header.transactions_root,
            .receipts_root = header.receipts_root,
            .logs_bloom = header.logs_bloom,
            .difficulty = header.difficulty,
            .number = header.number,
            .gas_limit = header.gas_limit,
            .gas_used = header.gas_used,
            .timestamp = header.timestamp,
            .extra_data = extra_data orelse &.{},
            .mix_hash = header.mix_hash,
            .nonce = header.nonce,
        };
        initialized += 1;
    }

    return ommers;
}

fn decodeWithdrawals(
    allocator: std.mem.Allocator,
    block_bytes: []const u8,
    withdrawals_span: RlpSpan,
) ![]const primitives.BlockBody.Withdrawal {
    if (withdrawals_span.kind != .list) return error.InvalidChainRlp;
    const withdrawal_spans = try childSpans(allocator, block_bytes, withdrawals_span.payload_start, withdrawals_span.payload_end);
    defer allocator.free(withdrawal_spans);
    if (withdrawal_spans.len == 0) return &.{};

    const withdrawals = try allocator.alloc(primitives.BlockBody.Withdrawal, withdrawal_spans.len);
    errdefer allocator.free(withdrawals);

    for (withdrawal_spans, 0..) |withdrawal_span, index| {
        if (withdrawal_span.kind != .list) return error.InvalidChainRlp;
        const fields = try childSpans(allocator, block_bytes, withdrawal_span.payload_start, withdrawal_span.payload_end);
        defer allocator.free(fields);
        if (fields.len != 4) return error.InvalidChainRlp;
        for (fields) |field| {
            if (field.kind != .string) return error.InvalidChainRlp;
        }
        const address = block_bytes[fields[2].payload_start..fields[2].payload_end];
        if (address.len != 20) return error.InvalidChainRlp;

        withdrawals[index] = .{
            .index = try parseRlpU64(block_bytes[fields[0].payload_start..fields[0].payload_end]),
            .validator_index = try parseRlpU64(block_bytes[fields[1].payload_start..fields[1].payload_end]),
            .address = .{ .bytes = address[0..20].* },
            .amount = try parseRlpU64(block_bytes[fields[3].payload_start..fields[3].payload_end]),
        };
    }

    return withdrawals;
}

fn cloneTransactions(
    allocator: std.mem.Allocator,
    transactions: []const primitives.BlockBody.TransactionData,
) ![]const primitives.BlockBody.TransactionData {
    if (transactions.len == 0) return &.{};

    const cloned = try allocator.alloc(primitives.BlockBody.TransactionData, transactions.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |tx| {
            allocator.free(tx.raw);
        }
        allocator.free(cloned);
    }

    for (transactions, 0..) |tx, i| {
        cloned[i] = .{ .raw = try allocator.dupe(u8, tx.raw) };
        initialized += 1;
    }

    return cloned;
}

fn cloneOmmers(
    allocator: std.mem.Allocator,
    ommers: []const primitives.BlockBody.UncleHeader,
) ![]const primitives.BlockBody.UncleHeader {
    if (ommers.len == 0) return &.{};

    const cloned = try allocator.alloc(primitives.BlockBody.UncleHeader, ommers.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |ommer| {
            if (ommer.extra_data.len > 0) allocator.free(ommer.extra_data);
        }
        allocator.free(cloned);
    }

    for (ommers, 0..) |ommer, i| {
        cloned[i] = ommer;
        if (ommer.extra_data.len > 0) {
            cloned[i].extra_data = try allocator.dupe(u8, ommer.extra_data);
        }
        initialized += 1;
    }

    return cloned;
}

fn cloneWithdrawals(
    allocator: std.mem.Allocator,
    withdrawals: []const primitives.BlockBody.Withdrawal,
) ![]const primitives.BlockBody.Withdrawal {
    if (withdrawals.len == 0) return &.{};
    return try allocator.dupe(primitives.BlockBody.Withdrawal, withdrawals);
}

fn childSpans(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    start: usize,
    end: usize,
) ![]RlpSpan {
    var spans = std.ArrayList(RlpSpan){};
    errdefer spans.deinit(allocator);

    var offset = start;
    while (offset < end) {
        const span = try itemSpan(bytes, offset);
        if (span.end > end) return error.InvalidChainRlp;
        try spans.append(allocator, span);
        offset = span.end;
    }
    if (offset != end) return error.InvalidChainRlp;

    return try spans.toOwnedSlice(allocator);
}

fn itemSpan(bytes: []const u8, start: usize) !RlpSpan {
    if (start >= bytes.len) return error.InvalidChainRlp;
    const prefix = bytes[start];
    if (prefix <= 0x7f) {
        return .{
            .start = start,
            .end = start + 1,
            .payload_start = start,
            .payload_end = start + 1,
            .kind = .string,
        };
    }
    if (prefix <= 0xb7) {
        const len: usize = prefix - 0x80;
        return sizedSpan(bytes, start, 1, len, .string);
    }
    if (prefix <= 0xbf) {
        const len_of_len: usize = prefix - 0xb7;
        const len = try parseLength(bytes, start, len_of_len);
        return sizedSpan(bytes, start, 1 + len_of_len, len, .string);
    }
    if (prefix <= 0xf7) {
        const len: usize = prefix - 0xc0;
        return sizedSpan(bytes, start, 1, len, .list);
    }

    const len_of_len: usize = prefix - 0xf7;
    const len = try parseLength(bytes, start, len_of_len);
    return sizedSpan(bytes, start, 1 + len_of_len, len, .list);
}

fn sizedSpan(
    bytes: []const u8,
    start: usize,
    prefix_len: usize,
    payload_len: usize,
    kind: RlpKind,
) !RlpSpan {
    const payload_start = std.math.add(usize, start, prefix_len) catch return error.InvalidChainRlp;
    const payload_end = std.math.add(usize, payload_start, payload_len) catch return error.InvalidChainRlp;
    if (payload_end > bytes.len) return error.InvalidChainRlp;
    return .{
        .start = start,
        .end = payload_end,
        .payload_start = payload_start,
        .payload_end = payload_end,
        .kind = kind,
    };
}

fn parseLength(bytes: []const u8, start: usize, len_of_len: usize) !usize {
    if (len_of_len == 0 or len_of_len > @sizeOf(usize)) return error.InvalidChainRlp;
    const len_start = start + 1;
    const len_end = std.math.add(usize, len_start, len_of_len) catch return error.InvalidChainRlp;
    if (len_end > bytes.len) return error.InvalidChainRlp;
    if (bytes[len_start] == 0) return error.InvalidChainRlp;

    var len: usize = 0;
    for (bytes[len_start..len_end]) |byte| {
        len = (len << 8) | byte;
    }
    return len;
}

fn parseRlpHash(bytes: []const u8, span: RlpSpan) !primitives.Hash.Hash {
    if (span.kind != .string) return error.InvalidChainRlp;
    const payload = bytes[span.payload_start..span.payload_end];
    if (payload.len != 32) return error.InvalidChainRlp;
    return payload[0..32].*;
}

fn parseRlpAddress(bytes: []const u8, span: RlpSpan) !primitives.Address {
    if (span.kind != .string) return error.InvalidChainRlp;
    const payload = bytes[span.payload_start..span.payload_end];
    if (payload.len != 20) return error.InvalidChainRlp;
    return .{ .bytes = payload[0..20].* };
}

fn parseRlpBloom(bytes: []const u8, span: RlpSpan) ![primitives.BlockHeader.BLOOM_SIZE]u8 {
    if (span.kind != .string) return error.InvalidChainRlp;
    const payload = bytes[span.payload_start..span.payload_end];
    if (payload.len != primitives.BlockHeader.BLOOM_SIZE) return error.InvalidChainRlp;
    return payload[0..primitives.BlockHeader.BLOOM_SIZE].*;
}

fn parseRlpNonce(bytes: []const u8, span: RlpSpan) ![primitives.BlockHeader.NONCE_SIZE]u8 {
    if (span.kind != .string) return error.InvalidChainRlp;
    const payload = bytes[span.payload_start..span.payload_end];
    if (payload.len != primitives.BlockHeader.NONCE_SIZE) return error.InvalidChainRlp;
    return payload[0..primitives.BlockHeader.NONCE_SIZE].*;
}

fn parseRlpU64Field(bytes: []const u8, span: RlpSpan) !u64 {
    if (span.kind != .string) return error.InvalidChainRlp;
    return parseRlpU64(bytes[span.payload_start..span.payload_end]);
}

fn parseRlpU256Field(bytes: []const u8, span: RlpSpan) !u256 {
    if (span.kind != .string) return error.InvalidChainRlp;
    return parseRlpU256(bytes[span.payload_start..span.payload_end]);
}

fn parseRlpU64(bytes: []const u8) !u64 {
    if (bytes.len > @sizeOf(u64)) return error.InvalidChainRlp;
    if (bytes.len > 1 and bytes[0] == 0) return error.InvalidChainRlp;
    var value: u64 = 0;
    for (bytes) |byte| {
        value = (value << 8) | byte;
    }
    return value;
}

fn parseRlpU256(bytes: []const u8) !u256 {
    if (bytes.len > 32) return error.InvalidChainRlp;
    if (bytes.len > 1 and bytes[0] == 0) return error.InvalidChainRlp;
    var value: u256 = 0;
    for (bytes) |byte| {
        value = (value << 8) | byte;
    }
    return value;
}

test "decodeNextBlock accepts full Hive rpc-compat chain stream" {
    const bytes = try std.fs.cwd().readFileAlloc(std.testing.allocator, "lib/execution-apis/tests/chain.rlp", 1024 * 1024);
    defer std.testing.allocator.free(bytes);

    var offset: usize = 0;
    var count: usize = 0;
    var last_hash = primitives.Hash.ZERO;
    while (offset < bytes.len) {
        var decoded = try decodeNextBlock(std.testing.allocator, bytes[offset..]);
        defer decoded.deinit(std.testing.allocator);
        last_hash = decoded.block.hash;
        offset += decodedBlockLength(bytes[offset..]);
        count += 1;
    }

    const expected_head = try primitives.Hash.fromHex("0xe27a3e81bd7cfe2aec2cc9e832c73a17c93e7efcf659cf4b39883b96c48708c2");
    try std.testing.expectEqual(@as(usize, 45), count);
    try std.testing.expectEqualSlices(u8, &expected_head, &last_hash);
}
