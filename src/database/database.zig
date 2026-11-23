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
        const account = try self.buildAccountState(allocator, address);
        try self.accounts.put(allocator, address, &account);
    }

    pub fn syncCachedAccountsToTrie(self: *Database, allocator: std.mem.Allocator) !void {
        var rebuilt = @import("accounts.zig").Accounts.init(self.accounts.allocator);
        errdefer rebuilt.deinit();

        // `setCode` and `setStorage` write their own caches without creating
        // an account-cache entry, so collect the union of all three caches.
        var addresses = std.AutoHashMapUnmanaged(primitives.Address, void){};
        defer addresses.deinit(allocator);

        var account_it = self.state.accountIterator();
        while (account_it.next()) |entry| {
            try addresses.put(allocator, entry.key_ptr.*, {});
        }
        var code_it = self.state.journaled_state.contract_cache.cache.keyIterator();
        while (code_it.next()) |address| {
            try addresses.put(allocator, address.*, {});
        }
        var storage_it = self.state.journaled_state.storage_cache.cache.keyIterator();
        while (storage_it.next()) |address| {
            try addresses.put(allocator, address.*, {});
        }

        var address_it = addresses.keyIterator();
        while (address_it.next()) |address_ptr| {
            const address = address_ptr.*;
            // EIP-161: an account with zero nonce, zero balance and no code
            // is empty and has no leaf in the state trie, however it came to
            // be cached (a touch, a read, or a reverted write).
            if (try self.accountIsEmpty(address)) continue;
            const account = try self.buildAccountState(allocator, address);
            try rebuilt.put(allocator, address, &account);
        }

        self.accounts.deinit();
        self.accounts = rebuilt;
    }

    fn accountIsEmpty(self: *Database, address: primitives.Address) !bool {
        if (try self.state.getNonce(address) != 0) return false;
        if (try self.state.getBalance(address) != 0) return false;
        if ((try self.state.getCode(address)).len != 0) return false;
        return !self.hasNonZeroStorage(address);
    }

    fn hasNonZeroStorage(self: *const Database, address: primitives.Address) bool {
        const slots = self.state.journaled_state.storage_cache.cache.getPtr(address) orelse return false;
        var it = slots.valueIterator();
        while (it.next()) |val| {
            if (val.* != 0) return true;
        }
        return false;
    }

    fn buildAccountState(self: *Database, allocator: std.mem.Allocator, address: primitives.Address) !primitives.AccountState.AccountState {
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

        return primitives.AccountState.AccountState.from(.{
            .nonce = nonce,
            .balance = balance,
            .storage_root = storage_root,
            .code_hash = code_hash,
        });
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

    if (slots.count() == 0) return primitives.State.EMPTY_TRIE_ROOT;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const capacity = slots.count();
    var keys = try std.ArrayList([]const u8).initCapacity(arena_alloc, capacity);
    var values = try std.ArrayList([]const u8).initCapacity(arena_alloc, capacity);
    const slot_storage = try arena_alloc.alloc([32]u8, capacity);
    var idx: usize = 0;

    var it = slots.iterator();
    while (it.next()) |entry| {
        const value = entry.value_ptr.*;
        if (value == 0) continue;

        std.mem.writeInt(u256, &slot_storage[idx], entry.key_ptr.*, .big);
        const encoded_value = try primitives.Rlp.encode(arena_alloc, value);
        keys.appendAssumeCapacity(&slot_storage[idx]);
        values.appendAssumeCapacity(encoded_value);
        idx += 1;
    }

    if (keys.items.len == 0) return primitives.State.EMPTY_TRIE_ROOT;
    return try primitives.TrieHash.secure_trie_root(arena_alloc, keys.items, values.items);
}

test "syncCachedAccountsToTrie keeps EIP-161 empty accounts out of the trie" {
    const allocator = std.testing.allocator;
    const funded = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 };
    const touched = primitives.Address{ .bytes = [_]u8{0x02} ++ [_]u8{0} ** 19 };

    var reference = try Database.init(allocator, null);
    defer reference.deinit(allocator);
    try reference.state.setBalance(funded, 100);
    try reference.syncCachedAccountsToTrie(allocator);

    var db = try Database.init(allocator, null);
    defer db.deinit(allocator);
    try db.state.setBalance(funded, 100);
    // A zero-value touch caches the account without making it non-empty.
    try db.state.setBalance(touched, 0);
    try db.state.setNonce(touched, 0);
    try db.syncCachedAccountsToTrie(allocator);

    try std.testing.expectEqualSlices(u8, &reference.accounts.stateRoot().?, &db.accounts.stateRoot().?);
    try std.testing.expect((try db.accounts.get(allocator, touched)) == null);
}
