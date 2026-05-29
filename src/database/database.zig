const std = @import("std");
const primitives = @import("primitives");
const state_manager = @import("state-manager");

/// In-memory Ethereum state database.
///
/// StateManager is the source of truth for all account state (balance,
/// nonce, code, storage) with journaling support. The Accounts trie is
/// a derived artifact used solely for computing the Merkle state root
/// when producing block headers. Call syncAccountToTrie to flush dirty
/// accounts from StateManager into the trie before reading stateRoot.
pub const Database = struct {
    state: state_manager.StateManager,
    accounts: @import("accounts.zig").Accounts,
    contracts: @import("contracts.zig").Contracts,

    pub fn init(allocator: std.mem.Allocator, fork_backend: ?*state_manager.ForkBackend) !Database {
        return .{
            .state = try state_manager.StateManager.init(allocator, fork_backend),
            .accounts = @import("accounts.zig").Accounts.init(allocator),
            .contracts = @import("contracts.zig").Contracts.init(),
        };
    }

    pub fn deinit(self: *Database, allocator: std.mem.Allocator) void {
        self.state.deinit();
        self.accounts.deinit();
        self.contracts.deinit(allocator);
    }

    /// Flush a single account from StateManager into the Accounts trie.
    /// Call this for each address modified during block execution before
    /// reading stateRoot().
    pub fn syncAccountToTrie(self: *Database, allocator: std.mem.Allocator, address: primitives.Address) !void {
        const balance = try self.state.getBalance(address);
        const nonce = try self.state.getNonce(address);
        const code = try self.state.getCode(address);

        var code_hash = primitives.State.EMPTY_CODE_HASH;
        if (code.len > 0) {
            std.crypto.hash.sha3.Keccak256.hash(code, &code_hash, .{});
        }

        // The Ethereum account RLP is [nonce, balance, storageRoot, codeHash].
        // Compute the real storage root from the account's storage so contracts
        // with non-empty storage are encoded correctly; omitting it would leave
        // storageRoot = EMPTY_TRIE_ROOT and produce a consensus-invalid state root.
        const storage_root = try computeAccountStorageRoot(self, allocator, address);

        const account = primitives.AccountState.AccountState.from(.{
            .nonce = nonce,
            .balance = balance,
            .storage_root = storage_root,
            .code_hash = code_hash,
        });
        try self.accounts.put(allocator, address, &account);
    }

    pub fn syncCachedAccountsToTrie(self: *Database, allocator: std.mem.Allocator) !void {
        var it = self.state.accountIterator();
        while (it.next()) |entry| {
            try self.syncAccountToTrie(allocator, entry.key_ptr.*);
        }
    }
};

/// Compute the storage trie root for an account from its journaled storage.
///
/// Returns EMPTY_TRIE_ROOT when the account has no non-zero storage slots,
/// mirroring the canonical Ethereum storage trie (zero-valued slots are not
/// stored). The caller owns no returned memory; all intermediate allocations
/// are freed before returning.
fn computeAccountStorageRoot(
    self: *Database,
    allocator: std.mem.Allocator,
    address: primitives.Address,
) ![32]u8 {
    const slots = self.state.journaled_state.storage_cache.cache.getPtr(address) orelse
        return primitives.State.EMPTY_TRIE_ROOT;

    var keys = std.ArrayList([]const u8){};
    defer {
        for (keys.items) |key| allocator.free(key);
        keys.deinit(allocator);
    }
    var values = std.ArrayList([]const u8){};
    defer {
        for (values.items) |value| allocator.free(value);
        values.deinit(allocator);
    }

    var it = slots.iterator();
    while (it.next()) |entry| {
        const value = entry.value_ptr.*;
        if (value == 0) continue;

        var slot_bytes: [32]u8 = undefined;
        std.mem.writeInt(u256, &slot_bytes, entry.key_ptr.*, .big);
        const key = try allocator.dupe(u8, slot_bytes[0..]);
        var key_owned = true;
        errdefer if (key_owned) allocator.free(key);
        const encoded_value = try primitives.Rlp.encode(allocator, value);
        var value_owned = true;
        errdefer if (value_owned) allocator.free(encoded_value);

        try keys.append(allocator, key);
        key_owned = false;
        try values.append(allocator, encoded_value);
        value_owned = false;
    }

    if (keys.items.len == 0) return primitives.State.EMPTY_TRIE_ROOT;
    return try primitives.TrieHash.secure_trie_root(allocator, keys.items, values.items);
}
