const std = @import("std");
const blockchain = @import("blockchain");
const primitives = @import("primitives");
const eth_handler = @import("eth_handler.zig");

// Test 1: eth_chainId returns configured chain ID (mainnet)
test "chainId returns configured chain ID" {
    var bc = try blockchain.Blockchain.init(std.testing.allocator, null);
    defer bc.deinit();

    const provider = eth_handler.Provider{
        .chain_id = 1,
        .blockchain = &bc,
    };

    const result = eth_handler.chainId(&provider);
    try std.testing.expectEqual(@as(u64, 1), result);
}

// Test 2: eth_chainId returns custom dev chain ID
test "chainId returns custom dev chain ID" {
    var bc = try blockchain.Blockchain.init(std.testing.allocator, null);
    defer bc.deinit();

    const provider = eth_handler.Provider{
        .chain_id = 1337,
        .blockchain = &bc,
    };

    const result = eth_handler.chainId(&provider);
    try std.testing.expectEqual(@as(u64, 1337), result);
}

// Test 3: eth_blockNumber returns 0 for empty blockchain
test "blockNumber returns 0 for empty blockchain" {
    var bc = try blockchain.Blockchain.init(std.testing.allocator, null);
    defer bc.deinit();

    const provider = eth_handler.Provider{
        .chain_id = 1,
        .blockchain = &bc,
    };

    const result = eth_handler.blockNumber(&provider);
    try std.testing.expectEqual(@as(u64, 0), result);
}

// Test 4: eth_blockNumber returns head after adding blocks
test "blockNumber returns head block number" {
    var bc = try blockchain.Blockchain.init(std.testing.allocator, null);
    defer bc.deinit();

    // Create and add genesis block
    const genesis = try primitives.Block.genesis(1, std.testing.allocator);
    try bc.putBlock(genesis);
    try bc.setCanonicalHead(genesis.hash);

    // Create and add block 1
    const block1 = try primitives.Block.genesis(1, std.testing.allocator);
    var block1_header = block1.header;
    block1_header.number = 1;
    block1_header.parent_hash = genesis.hash;
    const block1_with_header = try primitives.Block.from(&block1_header, &block1.body, std.testing.allocator);
    try bc.putBlock(block1_with_header);
    try bc.setCanonicalHead(block1_with_header.hash);

    const provider = eth_handler.Provider{
        .chain_id = 1,
        .blockchain = &bc,
    };

    const result = eth_handler.blockNumber(&provider);
    try std.testing.expectEqual(@as(u64, 1), result);
}

// Test 5: eth_blockNumber returns 0 when blockchain has no canonical head
test "blockNumber returns 0 when no canonical head" {
    var bc = try blockchain.Blockchain.init(std.testing.allocator, null);
    defer bc.deinit();

    // Add a block but don't set it as canonical head
    const block = try primitives.Block.genesis(1, std.testing.allocator);
    try bc.putBlock(block);
    // Note: we do NOT call setCanonicalHead

    const provider = eth_handler.Provider{
        .chain_id = 1,
        .blockchain = &bc,
    };

    const result = eth_handler.blockNumber(&provider);
    // Returns 0 as fallback when no canonical head is set (matches Anvil behavior)
    try std.testing.expectEqual(@as(u64, 0), result);
}
