const std = @import("std");
const primitives = @import("primitives");

/// Account state storage backed by a Merkle Patricia Trie.
///
/// Stores Ethereum accounts keyed by keccak256(address) in a secure trie,
/// providing O(log n) lookups and a deterministic state root hash.
pub const Accounts = struct {
    allocator: std.mem.Allocator,
    account_trie: primitives.Trie,

    pub fn init(allocator: std.mem.Allocator) Accounts {
        return .{
            .allocator = allocator,
            .account_trie = primitives.Trie.init(allocator),
        };
    }

    pub fn deinit(self: *Accounts) void {
        self.account_trie.deinit();
    }

    /// Retrieve an account by address. Returns null if the account does not exist.
    pub fn get(
        self: *Accounts,
        allocator: std.mem.Allocator,
        address: primitives.Address,
    ) !?primitives.AccountState.AccountState {
        var hashed_key: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(&address.bytes, &hashed_key, .{});
        const value = try self.account_trie.get(&hashed_key) orelse return null;
        return try primitives.AccountState.AccountState.rlpDecode(allocator, value);
    }

    /// Insert or update an account at the given address.
    pub fn put(
        self: *Accounts,
        allocator: std.mem.Allocator,
        address: primitives.Address,
        account: *const primitives.AccountState.AccountState,
    ) !void {
        var hashed_key: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(&address.bytes, &hashed_key, .{});
        const encoded = try account.rlpEncode(allocator);
        defer allocator.free(encoded);
        try self.account_trie.put(&hashed_key, encoded);
    }

    /// Remove an account at the given address.
    pub fn remove(self: *Accounts, address: primitives.Address) !void {
        var hashed_key: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(&address.bytes, &hashed_key, .{});
        try self.account_trie.delete(&hashed_key);
    }

    /// Returns the Merkle root hash of the account trie, or null if empty.
    pub fn stateRoot(self: *const Accounts) ?[32]u8 {
        return self.account_trie.root_hash();
    }
};

test "Accounts put, get, update, remove, and deterministic stateRoot" {
    const allocator = std.testing.allocator;
    var accounts = Accounts.init(allocator);
    defer accounts.deinit();

    const addr = primitives.Address.fromU256(0x1234);
    try std.testing.expectEqual(@as(?[32]u8, null), accounts.stateRoot());
    try std.testing.expectEqual(
        @as(?primitives.AccountState.AccountState, null),
        try accounts.get(allocator, addr),
    );

    const initial = primitives.AccountState.AccountState.from(.{
        .nonce = 7,
        .balance = 42_000,
    });
    try accounts.put(allocator, addr, &initial);
    const loaded = (try accounts.get(allocator, addr)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 7), loaded.nonce);
    try std.testing.expectEqual(@as(u256, 42_000), loaded.balance);
    const root_after_insert = accounts.stateRoot() orelse return error.TestUnexpectedResult;

    const updated = primitives.AccountState.AccountState.from(.{
        .nonce = 8,
        .balance = 99_000,
    });
    try accounts.put(allocator, addr, &updated);
    const root_after_update = accounts.stateRoot() orelse return error.TestUnexpectedResult;
    try std.testing.expect(!std.mem.eql(u8, &root_after_insert, &root_after_update));

    try accounts.remove(addr);
    try std.testing.expectEqual(
        @as(?primitives.AccountState.AccountState, null),
        try accounts.get(allocator, addr),
    );
}
