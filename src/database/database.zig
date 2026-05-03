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

        const account = primitives.AccountState.AccountState.from(.{
            .nonce = nonce,
            .balance = balance,
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
