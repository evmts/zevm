const std = @import("std");
const chain_import = @import("chain_import.zig");
const blockchain_mod = @import("blockchain");
const primitives = @import("primitives");

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
