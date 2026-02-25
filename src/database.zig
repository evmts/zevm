const std = @import("std");
const primitives = @import("primitives");

/// In-memory Ethereum state database backed by a Merkle Patricia Trie.
///
/// Stores accounts keyed by keccak256(address) in a secure trie,
/// mirroring EDR's PersistentStateTrie architecture using voltaire's
/// native Trie, AccountState, and Address types.
///
/// The underlying trie nodes are stored in a HashMap (voltaire's Trie.nodes),
/// analogous to EDR's PersistentMemoryDB (HashTrieMapSync<Vec<u8>, Vec<u8>>).
pub const Database = struct {
    account_trie: primitives.Trie,

    pub fn init(allocator: std.mem.Allocator) Database {
        return .{
            .account_trie = primitives.Trie.init(allocator),
        };
    }

    pub fn deinit(self: *Database) void {
        self.account_trie.deinit();
    }

    /// Retrieve an account by address. Returns null if the account does not exist.
    pub fn getAccount(self: *Database, allocator: std.mem.Allocator, address: primitives.Address) !?primitives.AccountState.AccountState {
        const value = try primitives.trie.getSecure(&self.account_trie, &address.bytes) orelse return null;
        return try primitives.AccountState.AccountState.rlpDecode(allocator, value);
    }

    /// Insert or update an account at the given address.
    pub fn putAccount(self: *Database, allocator: std.mem.Allocator, address: primitives.Address, account: *const primitives.AccountState.AccountState) !void {
        const encoded = try account.rlpEncode(allocator);
        defer allocator.free(encoded);
        try primitives.trie.putSecure(&self.account_trie, &address.bytes, encoded);
    }

    /// Remove an account at the given address.
    pub fn removeAccount(self: *Database, address: primitives.Address) !void {
        try primitives.trie.deleteSecure(&self.account_trie, &address.bytes);
    }

    /// Returns the Merkle root hash of the account trie, or null if empty.
    pub fn stateRoot(self: *const Database) ?[32]u8 {
        return self.account_trie.root_hash();
    }
};
