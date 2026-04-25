const std = @import("std");
const primitives = @import("primitives");
const state_manager = @import("state-manager");
const database = @import("database.zig");

test "init produces null state root (empty trie)" {
    var db = try database.Database.init(std.testing.allocator, null);
    defer db.deinit(std.testing.allocator);

    try std.testing.expect(db.accounts.stateRoot() == null);
}

test "put and get account" {
    var db = try database.Database.init(std.testing.allocator, null);
    defer db.deinit(std.testing.allocator);

    const addr = try primitives.Address.fromHex("0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266");
    const account = primitives.AccountState.AccountState.from(.{
        .nonce = 1,
        .balance = 1000000000000000000, // 1 ETH
    });

    try db.accounts.put(std.testing.allocator, addr, &account);

    const retrieved = try db.accounts.get(std.testing.allocator, addr);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(@as(u64, 1), retrieved.?.nonce);
    try std.testing.expectEqual(@as(u256, 1000000000000000000), retrieved.?.balance);
}

test "get nonexistent account returns null" {
    var db = try database.Database.init(std.testing.allocator, null);
    defer db.deinit(std.testing.allocator);

    const addr = try primitives.Address.fromHex("0x0000000000000000000000000000000000000001");
    const result = try db.accounts.get(std.testing.allocator, addr);
    try std.testing.expect(result == null);
}

test "put account produces non-null state root" {
    var db = try database.Database.init(std.testing.allocator, null);
    defer db.deinit(std.testing.allocator);

    const addr = try primitives.Address.fromHex("0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266");
    const account = primitives.AccountState.AccountState.createEmpty();

    try db.accounts.put(std.testing.allocator, addr, &account);

    try std.testing.expect(db.accounts.stateRoot() != null);
}

test "update existing account" {
    var db = try database.Database.init(std.testing.allocator, null);
    defer db.deinit(std.testing.allocator);

    const addr = try primitives.Address.fromHex("0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266");

    const a1 = primitives.AccountState.AccountState.from(.{ .nonce = 0, .balance = 100 });
    try db.accounts.put(std.testing.allocator, addr, &a1);

    const a2 = primitives.AccountState.AccountState.from(.{ .nonce = 1, .balance = 200 });
    try db.accounts.put(std.testing.allocator, addr, &a2);

    const retrieved = (try db.accounts.get(std.testing.allocator, addr)).?;
    try std.testing.expectEqual(@as(u64, 1), retrieved.nonce);
    try std.testing.expectEqual(@as(u256, 200), retrieved.balance);
}

test "remove account" {
    var db = try database.Database.init(std.testing.allocator, null);
    defer db.deinit(std.testing.allocator);

    const addr = try primitives.Address.fromHex("0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266");
    const account = primitives.AccountState.AccountState.from(.{ .nonce = 5, .balance = 500 });

    try db.accounts.put(std.testing.allocator, addr, &account);
    try std.testing.expect((try db.accounts.get(std.testing.allocator, addr)) != null);

    try db.accounts.remove(addr);
    try std.testing.expect((try db.accounts.get(std.testing.allocator, addr)) == null);
}

test "multiple accounts have independent state" {
    var db = try database.Database.init(std.testing.allocator, null);
    defer db.deinit(std.testing.allocator);

    const addr1 = try primitives.Address.fromHex("0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266");
    const addr2 = try primitives.Address.fromHex("0x70997970c51812dc3a010c7d01b50e0d17dc79c8");

    const a1 = primitives.AccountState.AccountState.from(.{ .nonce = 1, .balance = 100 });
    const a2 = primitives.AccountState.AccountState.from(.{ .nonce = 2, .balance = 200 });

    try db.accounts.put(std.testing.allocator, addr1, &a1);
    try db.accounts.put(std.testing.allocator, addr2, &a2);

    const r1 = (try db.accounts.get(std.testing.allocator, addr1)).?;
    const r2 = (try db.accounts.get(std.testing.allocator, addr2)).?;

    try std.testing.expectEqual(@as(u64, 1), r1.nonce);
    try std.testing.expectEqual(@as(u256, 100), r1.balance);
    try std.testing.expectEqual(@as(u64, 2), r2.nonce);
    try std.testing.expectEqual(@as(u256, 200), r2.balance);
}

test "state root changes on mutation" {
    var db = try database.Database.init(std.testing.allocator, null);
    defer db.deinit(std.testing.allocator);

    const addr = try primitives.Address.fromHex("0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266");
    const a1 = primitives.AccountState.AccountState.from(.{ .nonce = 0, .balance = 100 });
    try db.accounts.put(std.testing.allocator, addr, &a1);

    const root1 = db.accounts.stateRoot().?;

    const a2 = primitives.AccountState.AccountState.from(.{ .nonce = 1, .balance = 200 });
    try db.accounts.put(std.testing.allocator, addr, &a2);

    const root2 = db.accounts.stateRoot().?;

    try std.testing.expect(!std.mem.eql(u8, &root1, &root2));
}

test "same state produces same root (deterministic)" {
    var db1 = try database.Database.init(std.testing.allocator, null);
    defer db1.deinit(std.testing.allocator);
    var db2 = try database.Database.init(std.testing.allocator, null);
    defer db2.deinit(std.testing.allocator);

    const addr = try primitives.Address.fromHex("0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266");
    const account = primitives.AccountState.AccountState.from(.{ .nonce = 42, .balance = 1000 });

    try db1.accounts.put(std.testing.allocator, addr, &account);
    try db2.accounts.put(std.testing.allocator, addr, &account);

    const root1 = db1.accounts.stateRoot().?;
    const root2 = db2.accounts.stateRoot().?;

    try std.testing.expectEqualSlices(u8, &root1, &root2);
}

test "contract account with custom code hash" {
    var db = try database.Database.init(std.testing.allocator, null);
    defer db.deinit(std.testing.allocator);

    var code_hash: primitives.Hash.Hash = undefined;
    @memset(&code_hash, 0xAB);

    const addr = try primitives.Address.fromHex("0x5fbdb2315678afecb367f032d93f642f64180aa3");
    const account = primitives.AccountState.AccountState.from(.{
        .nonce = 1,
        .balance = 0,
        .code_hash = code_hash,
    });

    try db.accounts.put(std.testing.allocator, addr, &account);

    const retrieved = (try db.accounts.get(std.testing.allocator, addr)).?;
    try std.testing.expect(retrieved.isContract());
    try std.testing.expectEqualSlices(u8, &code_hash, &retrieved.code_hash);
}

test "remove nonexistent account is safe" {
    var db = try database.Database.init(std.testing.allocator, null);
    defer db.deinit(std.testing.allocator);

    const addr = try primitives.Address.fromHex("0x0000000000000000000000000000000000000001");
    try db.accounts.remove(addr);
}

test "deterministic root with multiple accounts inserted in different order" {
    var db1 = try database.Database.init(std.testing.allocator, null);
    defer db1.deinit(std.testing.allocator);
    var db2 = try database.Database.init(std.testing.allocator, null);
    defer db2.deinit(std.testing.allocator);

    const addr_a = try primitives.Address.fromHex("0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266");
    const addr_b = try primitives.Address.fromHex("0x70997970c51812dc3a010c7d01b50e0d17dc79c8");
    const acct_a = primitives.AccountState.AccountState.from(.{ .nonce = 1, .balance = 100 });
    const acct_b = primitives.AccountState.AccountState.from(.{ .nonce = 2, .balance = 200 });

    try db1.accounts.put(std.testing.allocator, addr_a, &acct_a);
    try db1.accounts.put(std.testing.allocator, addr_b, &acct_b);

    try db2.accounts.put(std.testing.allocator, addr_b, &acct_b);
    try db2.accounts.put(std.testing.allocator, addr_a, &acct_a);

    const root1 = db1.accounts.stateRoot().?;
    const root2 = db2.accounts.stateRoot().?;

    try std.testing.expectEqualSlices(u8, &root1, &root2);
}

test "init accepts fork backend and preserves local writes" {
    var fork_backend = try state_manager.ForkBackend.init(std.testing.allocator, "latest", .{});
    defer fork_backend.deinit();

    var db = try database.Database.init(std.testing.allocator, &fork_backend);
    defer db.deinit(std.testing.allocator);

    const addr = try primitives.Address.fromHex("0x0000000000000000000000000000000000000001");
    try db.state.initAccount(addr, 1234);
    const balance = try db.state.getBalance(addr);
    try std.testing.expectEqual(@as(u256, 1234), balance);
}
