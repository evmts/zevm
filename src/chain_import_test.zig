const std = @import("std");
const chain_import = @import("chain_import.zig");
const blockchain_mod = @import("blockchain");
const primitives = @import("primitives");
const hardfork_schedule = @import("hardfork_schedule.zig");

test "decodeNextBlock decodes block header and empty body" {
    var header = primitives.BlockHeader.BlockHeader{
        .parent_hash = primitives.Hash.ZERO,
        .ommers_hash = primitives.BlockHeader.EMPTY_OMMERS_HASH,
        .beneficiary = try primitives.Address.fromHex("0x00000000000000000000000000000000000000aa"),
        .state_root = primitives.State.EMPTY_TRIE_ROOT,
        .transactions_root = primitives.BlockHeader.EMPTY_TRANSACTIONS_ROOT,
        .receipts_root = primitives.BlockHeader.EMPTY_RECEIPTS_ROOT,
        .logs_bloom = [_]u8{0} ** primitives.BlockHeader.BLOOM_SIZE,
        .difficulty = 0,
        .number = 1,
        .gas_limit = 1_000_000,
        .gas_used = 0,
        .timestamp = 42,
        .extra_data = "chain",
        .mix_hash = primitives.Hash.ZERO,
        .nonce = [_]u8{0} ** primitives.BlockHeader.NONCE_SIZE,
        .base_fee_per_gas = 7,
    };
    _ = &header;

    const header_rlp = try primitives.BlockHeader.rlpEncode(&header, std.testing.allocator);
    defer std.testing.allocator.free(header_rlp);

    const block_rlp = try encodeListFromEncoded(std.testing.allocator, &.{
        header_rlp,
        &[_]u8{0xc0},
        &[_]u8{0xc0},
    });
    defer std.testing.allocator.free(block_rlp);

    var decoded = try chain_import.decodeNextBlock(std.testing.allocator, block_rlp);
    defer decoded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 1), decoded.block.header.number);
    try std.testing.expectEqual(@as(u64, 42), decoded.block.header.timestamp);
    try std.testing.expectEqual(@as(u256, 7), decoded.block.header.base_fee_per_gas.?);
    try std.testing.expectEqualSlices(u8, "chain", decoded.block.header.extra_data);
    try std.testing.expectEqual(@as(usize, 0), decoded.block.body.transactions.len);
    try std.testing.expectEqual(block_rlp.len, decoded.block.size);
}

test "decodeNextBlock owns ommer extra data" {
    var header = primitives.BlockHeader.BlockHeader{
        .parent_hash = primitives.Hash.ZERO,
        .ommers_hash = primitives.BlockHeader.EMPTY_OMMERS_HASH,
        .beneficiary = try primitives.Address.fromHex("0x00000000000000000000000000000000000000aa"),
        .state_root = primitives.State.EMPTY_TRIE_ROOT,
        .transactions_root = primitives.BlockHeader.EMPTY_TRANSACTIONS_ROOT,
        .receipts_root = primitives.BlockHeader.EMPTY_RECEIPTS_ROOT,
        .logs_bloom = [_]u8{0} ** primitives.BlockHeader.BLOOM_SIZE,
        .difficulty = 0,
        .number = 1,
        .gas_limit = 1_000_000,
        .gas_used = 0,
        .timestamp = 42,
        .extra_data = "chain",
        .mix_hash = primitives.Hash.ZERO,
        .nonce = [_]u8{0} ** primitives.BlockHeader.NONCE_SIZE,
        .base_fee_per_gas = 7,
    };
    _ = &header;

    const header_rlp = try primitives.BlockHeader.rlpEncode(&header, std.testing.allocator);
    defer std.testing.allocator.free(header_rlp);

    const ommers_rlp = try encodeListFromEncoded(std.testing.allocator, &.{header_rlp});
    defer std.testing.allocator.free(ommers_rlp);

    const block_rlp = try encodeListFromEncoded(std.testing.allocator, &.{
        header_rlp,
        &[_]u8{0xc0},
        ommers_rlp,
    });
    defer std.testing.allocator.free(block_rlp);

    var decoded = try chain_import.decodeNextBlock(std.testing.allocator, block_rlp);
    defer decoded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 1), decoded.block.header.number);
    try std.testing.expectEqual(@as(u64, 42), decoded.block.header.timestamp);
    try std.testing.expectEqual(@as(u256, 7), decoded.block.header.base_fee_per_gas.?);
    try std.testing.expectEqualSlices(u8, "chain", decoded.block.header.extra_data);
    try std.testing.expectEqual(@as(usize, 0), decoded.block.body.transactions.len);
    try std.testing.expectEqual(block_rlp.len, decoded.block.size);
    try std.testing.expectEqual(@as(usize, 1), decoded.block.body.ommers.len);
    try std.testing.expectEqualSlices(u8, "chain", decoded.block.body.ommers[0].extra_data);
}

test "decodeNextBlock accepts fixture chain stream first block" {
    const bytes = try std.fs.cwd().readFileAlloc(std.testing.allocator, "lib/execution-apis/tests/chain.rlp", 1024 * 1024);
    defer std.testing.allocator.free(bytes);

    var decoded = try chain_import.decodeNextBlock(std.testing.allocator, bytes);
    defer decoded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 1), decoded.block.header.number);
    try std.testing.expectEqual(@as(usize, 4), decoded.block.body.transactions.len);
}

fn blockHashOf(block_rlp: []const u8) [32]u8 {
    // The single-block fixtures used here all decode to the same header, whose
    // hash we recompute by decoding the block once with a scratch allocator.
    var decoded = chain_import.decodeNextBlock(std.testing.allocator, block_rlp) catch return primitives.Hash.ZERO;
    defer decoded.deinit(std.testing.allocator);
    return decoded.block.hash;
}

// Regression for finding #33: importChainBytes used to call putBlock (which stores
// the Block, including its body slice fields, by value without copying) BEFORE
// transferring ownership of the body buffers to owned_block_bodies. If the append
// then failed the errdefer freed buffers the blockchain still referenced
// (use-after-free / double-free). The fix appends (transfers ownership) first. This
// test pins the ownership contract: a single import leaves the body owned by
// owned_block_bodies and the stored block readable, with cleanup freeing it exactly
// once (the testing allocator fails on any leak/double-free/UAF).
test "importChainBytes transfers block body ownership to owned_block_bodies without UAF or double-free" {
    var header = primitives.BlockHeader.BlockHeader{
        .parent_hash = primitives.Hash.ZERO,
        .ommers_hash = primitives.BlockHeader.EMPTY_OMMERS_HASH,
        .beneficiary = try primitives.Address.fromHex("0x00000000000000000000000000000000000000aa"),
        .state_root = primitives.State.EMPTY_TRIE_ROOT,
        .transactions_root = primitives.BlockHeader.EMPTY_TRANSACTIONS_ROOT,
        .receipts_root = primitives.BlockHeader.EMPTY_RECEIPTS_ROOT,
        .logs_bloom = [_]u8{0} ** primitives.BlockHeader.BLOOM_SIZE,
        .difficulty = 0,
        // number 0 (genesis) so the block is not treated as an orphan by the
        // BlockStore (a non-genesis block whose parent is absent cannot be made
        // canonical head). This lets the no-failure control run of
        // checkAllAllocationFailures complete the full import path.
        .number = 0,
        .gas_limit = 1_000_000,
        .gas_used = 0,
        .timestamp = 42,
        .extra_data = "chain-import-regression-extra-data",
        .mix_hash = primitives.Hash.ZERO,
        .nonce = [_]u8{0} ** primitives.BlockHeader.NONCE_SIZE,
        .base_fee_per_gas = 7,
    };
    _ = &header;

    const header_rlp = try primitives.BlockHeader.rlpEncode(&header, std.testing.allocator);
    defer std.testing.allocator.free(header_rlp);

    const block_rlp = try encodeListFromEncoded(std.testing.allocator, &.{
        header_rlp,
        &[_]u8{0xc0},
        &[_]u8{0xc0},
    });
    defer std.testing.allocator.free(block_rlp);

    var chain = try blockchain_mod.Blockchain.init(std.testing.allocator, null);
    defer chain.deinit();

    var owned_block_bodies = std.ArrayList(chain_import.OwnedBlockBody){};
    defer {
        for (owned_block_bodies.items) |*body| {
            body.deinit(std.testing.allocator);
        }
        owned_block_bodies.deinit(std.testing.allocator);
    }

    const stats = try chain_import.importChainBytes(
        std.testing.allocator,
        &chain,
        &owned_block_bodies,
        block_rlp,
    );

    // The single genesis block was imported and made canonical.
    try std.testing.expectEqual(@as(usize, 1), stats.block_count);
    try std.testing.expectEqual(@as(usize, 1), owned_block_bodies.items.len);

    // The body buffers are owned by owned_block_bodies because importChainBytes now
    // transfers ownership BEFORE calling putBlock (which stores the Block, including
    // its body slice fields, by value without deep-copying). Reading the stored
    // block back exercises those buffers: a dangling pointer would surface as a
    // use-after-free under the testing allocator, and the defer cleanup freeing the
    // body would be a double-free if the blockchain also owned it. The testing
    // allocator fails the test on either, so this locks in the ordering fix.
    const stored = (try chain.getBlockByHash(blockHashOf(block_rlp))).?;
    std.mem.doNotOptimizeAway(stored.header.extra_data.len);
    std.mem.doNotOptimizeAway(stored.body.transactions.len);
}

fn encodeListFromEncoded(allocator: std.mem.Allocator, fields: []const []const u8) ![]u8 {
    var total_len: usize = 0;
    for (fields) |field| {
        total_len += field.len;
    }

    var result = std.ArrayList(u8){};
    errdefer result.deinit(allocator);

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

/// One genesis-numbered block whose RLP encoding is exactly `total_size`
/// bytes, padded by a single typed transaction of opaque bytes.
fn encodeBlockOfSize(allocator: std.mem.Allocator, timestamp: u64, total_size: usize) ![]u8 {
    var header = primitives.BlockHeader.BlockHeader{
        .parent_hash = primitives.Hash.ZERO,
        .ommers_hash = primitives.BlockHeader.EMPTY_OMMERS_HASH,
        .beneficiary = try primitives.Address.fromHex("0x00000000000000000000000000000000000000aa"),
        .state_root = primitives.State.EMPTY_TRIE_ROOT,
        .transactions_root = primitives.BlockHeader.EMPTY_TRANSACTIONS_ROOT,
        .receipts_root = primitives.BlockHeader.EMPTY_RECEIPTS_ROOT,
        .logs_bloom = [_]u8{0} ** primitives.BlockHeader.BLOOM_SIZE,
        .difficulty = 0,
        .number = 0,
        .gas_limit = 60_000_000,
        .gas_used = 0,
        .timestamp = timestamp,
        .extra_data = &.{},
        .mix_hash = primitives.Hash.ZERO,
        .nonce = [_]u8{0} ** primitives.BlockHeader.NONCE_SIZE,
        .base_fee_per_gas = 7,
    };
    _ = &header;
    const header_rlp = try primitives.BlockHeader.rlpEncode(&header, allocator);
    defer allocator.free(header_rlp);

    // Block, transaction list and transaction string each take a four-byte
    // prefix at these sizes; the empty ommers list takes one byte.
    const tx_len = total_size - header_rlp.len - 13;
    const tx_bytes = try allocator.alloc(u8, tx_len);
    defer allocator.free(tx_bytes);
    @memset(tx_bytes, 0x02);
    const tx_item = try primitives.Rlp.encodeBytes(allocator, tx_bytes);
    defer allocator.free(tx_item);
    const tx_list = try encodeListFromEncoded(allocator, &.{tx_item});
    defer allocator.free(tx_list);

    const block_rlp = try encodeListFromEncoded(allocator, &.{ header_rlp, tx_list, &[_]u8{0xc0} });
    errdefer allocator.free(block_rlp);
    try std.testing.expectEqual(total_size, block_rlp.len);
    return block_rlp;
}

fn osakaAtTimestamp(timestamp: u64) hardfork_schedule.ChainConfig {
    return .{
        .homestead_block = 0,
        .dao_block = 0,
        .tangerine_whistle_block = 0,
        .spurious_dragon_block = 0,
        .byzantium_block = 0,
        .constantinople_block = 0,
        .petersburg_block = 0,
        .istanbul_block = 0,
        .muir_glacier_block = 0,
        .berlin_block = 0,
        .london_block = 0,
        .arrow_glacier_block = 0,
        .gray_glacier_block = 0,
        .merge_block = 0,
        .shanghai_timestamp = 0,
        .cancun_timestamp = 0,
        .prague_timestamp = 0,
        .osaka_timestamp = timestamp,
    };
}

const SizedImport = struct {
    block_count: usize,
    stored_bodies: usize,
    block_size: u64,
};

fn importBlockOfSize(
    timestamp: u64,
    total_size: usize,
    options: ?chain_import.ImportOptions,
) !SizedImport {
    const block_rlp = try encodeBlockOfSize(std.testing.allocator, timestamp, total_size);
    defer std.testing.allocator.free(block_rlp);

    var chain = try blockchain_mod.Blockchain.init(std.testing.allocator, null);
    defer chain.deinit();
    var owned_block_bodies = std.ArrayList(chain_import.OwnedBlockBody){};
    defer {
        for (owned_block_bodies.items) |*body| body.deinit(std.testing.allocator);
        owned_block_bodies.deinit(std.testing.allocator);
    }

    const stats = if (options) |import_options|
        chain_import.importChainBytesWithOptions(std.testing.allocator, &chain, &owned_block_bodies, block_rlp, import_options)
    else
        chain_import.importChainBytes(std.testing.allocator, &chain, &owned_block_bodies, block_rlp);

    if (stats) |imported| {
        const stored = (try chain.getBlockByHash(imported.head_hash)).?;
        return .{ .block_count = imported.block_count, .stored_bodies = owned_block_bodies.items.len, .block_size = stored.size };
    } else |err| {
        // A rejected block must not reach the block store or the body list.
        try std.testing.expectEqual(@as(usize, 0), owned_block_bodies.items.len);
        try std.testing.expectEqual(@as(?primitives.Block.Block, null), try chain.getBlockByNumber(0));
        return err;
    }
}

test "EIP-7934 validateBlockRlpSize caps Osaka blocks at 8,388,608 bytes" {
    try std.testing.expectEqual(@as(usize, 8_388_608), chain_import.MAX_RLP_BLOCK_SIZE);
    try std.testing.expectEqual(@as(usize, 10_485_760 - 2_097_152), chain_import.MAX_RLP_BLOCK_SIZE);

    try chain_import.validateBlockRlpSize(0, .OSAKA);
    try chain_import.validateBlockRlpSize(8_388_608, .OSAKA);
    try std.testing.expectError(error.BlockRlpSizeExceeded, chain_import.validateBlockRlpSize(8_388_609, .OSAKA));
    try std.testing.expectError(error.BlockRlpSizeExceeded, chain_import.validateBlockRlpSize(std.math.maxInt(u64), .OSAKA));

    for ([_]primitives.Hardfork{ .FRONTIER, .LONDON, .MERGE, .SHANGHAI, .CANCUN, .PRAGUE }) |fork| {
        try chain_import.validateBlockRlpSize(8_388_609, fork);
        try chain_import.validateBlockRlpSize(std.math.maxInt(u64), fork);
    }
}

test "EIP-7934 import accepts an Osaka block of exactly 8,388,608 bytes" {
    const imported = try importBlockOfSize(42, 8_388_608, .{ .hardfork_config = osakaAtTimestamp(0) });
    try std.testing.expectEqual(@as(usize, 1), imported.block_count);
    try std.testing.expectEqual(@as(usize, 1), imported.stored_bodies);
    try std.testing.expectEqual(@as(u64, 8_388_608), imported.block_size);
}

test "EIP-7934 import rejects an Osaka block one byte over the cap and stores nothing" {
    try std.testing.expectError(
        error.BlockRlpSizeExceeded,
        importBlockOfSize(42, 8_388_609, .{ .hardfork_config = osakaAtTimestamp(0) }),
    );
    try std.testing.expectError(
        error.BlockRlpSizeExceeded,
        importBlockOfSize(42, 10_485_760, .{ .hardfork_config = osakaAtTimestamp(0) }),
    );
}

test "EIP-7934 import allows blocks over 8 MiB before Osaka" {
    // Prague schedule: Osaka never activates.
    const prague = try importBlockOfSize(42, 10_485_760, .{ .hardfork_config = osakaAtTimestamp(std.math.maxInt(u64)) });
    try std.testing.expectEqual(@as(u64, 10_485_760), prague.block_size);

    // No schedule: decode-only import applies no fork rules.
    const decode_only = try importBlockOfSize(42, 8_388_609, null);
    try std.testing.expectEqual(@as(u64, 8_388_609), decode_only.block_size);
    const default_options = try importBlockOfSize(42, 8_388_609, .{});
    try std.testing.expectEqual(@as(usize, 1), default_options.block_count);
}

test "EIP-7934 import applies the cap from the Osaka activation timestamp" {
    const config = osakaAtTimestamp(100);
    const before = try importBlockOfSize(99, 8_388_609, .{ .hardfork_config = config });
    try std.testing.expectEqual(@as(usize, 1), before.block_count);
    try std.testing.expectError(error.BlockRlpSizeExceeded, importBlockOfSize(100, 8_388_609, .{ .hardfork_config = config }));
    try std.testing.expectError(error.BlockRlpSizeExceeded, importBlockOfSize(101, 8_388_609, .{ .hardfork_config = config }));
    const at_cap = try importBlockOfSize(100, 8_388_608, .{ .hardfork_config = config });
    try std.testing.expectEqual(@as(usize, 1), at_cap.block_count);
}

test "EIP-7934 import rejects an oversized block after valid ones" {
    const small = try encodeBlockOfSize(std.testing.allocator, 42, 70_000);
    defer std.testing.allocator.free(small);
    const oversized = try encodeBlockOfSize(std.testing.allocator, 43, 8_388_609);
    defer std.testing.allocator.free(oversized);
    const stream = try std.mem.concat(std.testing.allocator, u8, &.{ small, oversized });
    defer std.testing.allocator.free(stream);

    var chain = try blockchain_mod.Blockchain.init(std.testing.allocator, null);
    defer chain.deinit();
    var owned_block_bodies = std.ArrayList(chain_import.OwnedBlockBody){};
    defer {
        for (owned_block_bodies.items) |*body| body.deinit(std.testing.allocator);
        owned_block_bodies.deinit(std.testing.allocator);
    }

    try std.testing.expectError(error.BlockRlpSizeExceeded, chain_import.importChainBytesWithOptions(
        std.testing.allocator,
        &chain,
        &owned_block_bodies,
        stream,
        .{ .hardfork_config = osakaAtTimestamp(0) },
    ));
    // The valid first block stays imported; the oversized one is not stored.
    try std.testing.expectEqual(@as(usize, 1), owned_block_bodies.items.len);
    try std.testing.expect((try chain.getBlockByHash(blockHashOf(small))) != null);
    try std.testing.expectEqual(@as(?primitives.Block.Block, null), try chain.getBlockByHash(blockHashOf(oversized)));
}
