const std = @import("std");
const primitives = @import("primitives");

/// Block hash storage mapping block numbers to their hashes.
///
/// Provides the backing store for the EVM BLOCKHASH opcode, which
/// requires access to the hashes of the 256 most recent blocks.
pub const BlockHashes = struct {
    hashes: std.AutoHashMapUnmanaged(u64, primitives.Hash.Hash) = .empty,

    pub fn init() BlockHashes {
        return .{};
    }

    pub fn deinit(self: *BlockHashes, allocator: std.mem.Allocator) void {
        self.hashes.deinit(allocator);
    }

    /// Retrieve a block hash by block number.
    pub fn get(self: *const BlockHashes, block_number: u64) ?primitives.Hash.Hash {
        return self.hashes.get(block_number);
    }

    /// Store a block hash for a given block number.
    pub fn put(self: *BlockHashes, allocator: std.mem.Allocator, block_number: u64, hash: primitives.Hash.Hash) !void {
        try self.hashes.put(allocator, block_number, hash);
    }

    /// Remove a block hash by block number.
    pub fn remove(self: *BlockHashes, block_number: u64) void {
        _ = self.hashes.remove(block_number);
    }
};
