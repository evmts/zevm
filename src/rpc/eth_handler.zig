const blockchain = @import("blockchain");

/// Provider holds configuration and blockchain reference for RPC handlers.
/// This struct is intentionally minimal - no stored allocator, no local type aliases.
pub const Provider = struct {
    chain_id: u64,
    blockchain: *blockchain.Blockchain,
};

/// Handler for eth_chainId RPC method.
/// Returns the configured chain ID as u64.
/// The dispatch layer will convert this to a hex QUANTITY string.
pub fn chainId(provider: *const Provider) u64 {
    return provider.chain_id;
}

/// Handler for eth_blockNumber RPC method.
/// Returns the current canonical head block number, or 0 if no head is set.
/// Matches Anvil/Hardhat behavior for fresh chains.
pub fn blockNumber(provider: *const Provider) u64 {
    return provider.blockchain.getHeadBlockNumber() orelse 0;
}
