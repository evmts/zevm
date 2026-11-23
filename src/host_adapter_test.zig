const std = @import("std");
const primitives = @import("primitives");
const state_manager = @import("state-manager");
const host_adapter = @import("host_adapter.zig");

test "host adapter get/set balance" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var adapter = host_adapter.HostAdapter{ .state = &sm };
    const host = adapter.hostInterface();

    const addr = primitives.Address{ .bytes = [_]u8{0x11} ++ [_]u8{0} ** 19 };

    // Default balance should be 0
    try std.testing.expectEqual(@as(u256, 0), host.getBalance(addr));

    // Set and get balance
    host.setBalance(addr, 1000);
    try std.testing.expectEqual(@as(u256, 1000), host.getBalance(addr));
}

test "host adapter get/set nonce" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var adapter = host_adapter.HostAdapter{ .state = &sm };
    const host = adapter.hostInterface();

    const addr = primitives.Address{ .bytes = [_]u8{0x22} ++ [_]u8{0} ** 19 };

    try std.testing.expectEqual(@as(u64, 0), host.getNonce(addr));

    host.setNonce(addr, 42);
    try std.testing.expectEqual(@as(u64, 42), host.getNonce(addr));
}

test "host adapter get/set storage" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var adapter = host_adapter.HostAdapter{ .state = &sm };
    const host = adapter.hostInterface();

    const addr = primitives.Address{ .bytes = [_]u8{0x33} ++ [_]u8{0} ** 19 };
    const slot: u256 = 7;

    try std.testing.expectEqual(@as(u256, 0), host.getStorage(addr, slot));

    host.setStorage(addr, slot, 999);
    try std.testing.expectEqual(@as(u256, 999), host.getStorage(addr, slot));
}

test "host adapter get/set code" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var adapter = host_adapter.HostAdapter{ .state = &sm };
    const host = adapter.hostInterface();

    const addr = primitives.Address{ .bytes = [_]u8{0x44} ++ [_]u8{0} ** 19 };
    const bytecode = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0xfd };

    try std.testing.expectEqual(@as(usize, 0), host.getCode(addr).len);

    host.setCode(addr, &bytecode);
    try std.testing.expectEqualSlices(u8, &bytecode, host.getCode(addr));
}

test "host adapter checkpoint and revert" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var adapter = host_adapter.HostAdapter{ .state = &sm };
    const host = adapter.hostInterface();

    const addr = primitives.Address{ .bytes = [_]u8{0x55} ++ [_]u8{0} ** 19 };

    host.setBalance(addr, 100);
    try sm.checkpoint();

    host.setBalance(addr, 200);
    try std.testing.expectEqual(@as(u256, 200), host.getBalance(addr));

    sm.revert();
    try std.testing.expectEqual(@as(u256, 100), host.getBalance(addr));
}

test "host adapter multiple addresses independent" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var adapter = host_adapter.HostAdapter{ .state = &sm };
    const host = adapter.hostInterface();

    const addr1 = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 };
    const addr2 = primitives.Address{ .bytes = [_]u8{0x02} ++ [_]u8{0} ** 19 };

    host.setBalance(addr1, 100);
    host.setBalance(addr2, 200);

    try std.testing.expectEqual(@as(u256, 100), host.getBalance(addr1));
    try std.testing.expectEqual(@as(u256, 200), host.getBalance(addr2));
}

test "host adapter read failures set host error" {
    var fork_backend = try state_manager.ForkBackend.init(std.testing.allocator, "latest", .{});
    defer fork_backend.deinit();

    var sm = try state_manager.StateManager.init(std.testing.allocator, &fork_backend);
    defer sm.deinit();

    var adapter = host_adapter.HostAdapter{ .state = &sm };
    const host = adapter.hostInterface();

    const addr = primitives.Address{ .bytes = [_]u8{0x66} ++ [_]u8{0} ** 19 };

    try std.testing.expectEqual(@as(u256, 0), host.getBalance(addr));
    try expectHostError(&adapter, .rpc_pending);
    adapter.clearHostError();

    try std.testing.expectEqual(@as(u64, 0), host.getNonce(addr));
    try expectHostError(&adapter, .rpc_pending);
    adapter.clearHostError();

    try std.testing.expectEqual(@as(usize, 0), host.getCode(addr).len);
    try expectHostError(&adapter, .rpc_pending);
    adapter.clearHostError();

    try std.testing.expectEqual(@as(u256, 0), host.getStorage(addr, 7));
    try expectHostError(&adapter, .rpc_pending);
}

test "host adapter write failures set host error" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var sm = try state_manager.StateManager.init(failing_allocator.allocator(), null);
    defer sm.deinit();

    var adapter = host_adapter.HostAdapter{ .state = &sm };
    const host = adapter.hostInterface();

    const addr = primitives.Address{ .bytes = [_]u8{0x77} ++ [_]u8{0} ** 19 };
    const code = [_]u8{ 0x60, 0x00 };

    failing_allocator.fail_index = failing_allocator.alloc_index;

    host.setBalance(addr, 1);
    try expectHostError(&adapter, .out_of_memory);
    adapter.clearHostError();

    host.setNonce(addr, 1);
    try expectHostError(&adapter, .out_of_memory);
    adapter.clearHostError();

    host.setCode(addr, &code);
    try expectHostError(&adapter, .out_of_memory);
    adapter.clearHostError();

    host.setStorage(addr, 1, 1);
    try expectHostError(&adapter, .out_of_memory);
}

test "host adapter direct methods propagate errors" {
    var fork_backend = try state_manager.ForkBackend.init(std.testing.allocator, "latest", .{});
    defer fork_backend.deinit();

    var sm = try state_manager.StateManager.init(std.testing.allocator, &fork_backend);
    defer sm.deinit();

    var adapter = host_adapter.HostAdapter{ .state = &sm };
    const addr = primitives.Address{ .bytes = [_]u8{0x88} ++ [_]u8{0} ** 19 };

    try std.testing.expectError(error.RpcPending, adapter.getBalance(addr));
    try std.testing.expectEqual(@as(?host_adapter.HostAdapter.HostError, null), adapter.getHostError());
}

test "host adapter accountExists follows EIP-161 non-emptiness, not cache presence" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var adapter = host_adapter.HostAdapter{ .state = &sm };
    const host = adapter.hostInterface();
    const absent = primitives.Address{ .bytes = [_]u8{0x99} ++ [_]u8{0} ** 19 };
    const touched_empty = primitives.Address{ .bytes = [_]u8{0xaa} ++ [_]u8{0} ** 19 };
    const with_nonce = primitives.Address{ .bytes = [_]u8{0xbb} ++ [_]u8{0} ** 19 };
    const with_code = primitives.Address{ .bytes = [_]u8{0xcc} ++ [_]u8{0} ** 19 };
    const with_balance = primitives.Address{ .bytes = [_]u8{0xdd} ++ [_]u8{0} ** 19 };
    const storage_only = primitives.Address{ .bytes = [_]u8{0xee} ++ [_]u8{0} ** 19 };
    const code = [_]u8{0x00};

    try std.testing.expect(!try adapter.accountExists(absent));
    try std.testing.expect(try adapter.accountIsEmpty(absent));

    // A zero-value write creates a cache entry but not an account.
    try sm.setBalance(touched_empty, 0);
    try std.testing.expect(sm.journaled_state.account_cache.has(touched_empty));
    try std.testing.expect(!try adapter.accountExists(touched_empty));
    try std.testing.expect(!host.accountExists(touched_empty));
    try std.testing.expect(try adapter.accountIsEmpty(touched_empty));

    try sm.setNonce(with_nonce, 1);
    try std.testing.expect(try adapter.accountExists(with_nonce));
    try std.testing.expect(!try adapter.accountIsEmpty(with_nonce));

    try sm.setBalance(with_balance, 1);
    try std.testing.expect(try adapter.accountExists(with_balance));

    try sm.setCode(with_code, &code);
    try std.testing.expect(try adapter.accountExists(with_code));
    try std.testing.expect(!try adapter.accountIsEmpty(with_code));

    // Storage or cleared code alone does not make an account exist.
    try sm.setStorage(storage_only, 1, 2);
    try sm.setCode(storage_only, &.{});
    try std.testing.expect(!try adapter.accountExists(storage_only));
    try std.testing.expectEqual(@as(?host_adapter.HostAdapter.HostError, null), adapter.getHostError());
}

test "host adapter deleteAccount clears the account and is undone by revert" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var adapter = host_adapter.HostAdapter{ .state = &sm };
    const host = adapter.hostInterface();
    const doomed = primitives.Address{ .bytes = [_]u8{0x5d} ++ [_]u8{0} ** 19 };
    const bystander = primitives.Address{ .bytes = [_]u8{0x5e} ++ [_]u8{0} ** 19 };
    const code = [_]u8{ 0x60, 0x00, 0xff };

    try sm.setBalance(doomed, 1234);
    try sm.setNonce(doomed, 7);
    try sm.setCode(doomed, &code);
    try sm.setStorage(doomed, 1, 0xaaaa);
    try sm.setStorage(doomed, 2, 0xbbbb);
    try sm.setBalance(bystander, 55);
    try sm.setStorage(bystander, 1, 0xcccc);

    try sm.checkpoint();
    host.deleteAccount(doomed);
    try std.testing.expectEqual(@as(?host_adapter.HostAdapter.HostError, null), adapter.getHostError());

    try std.testing.expect(!try adapter.accountExists(doomed));
    try std.testing.expect(try adapter.accountIsEmpty(doomed));
    try std.testing.expectEqual(@as(u256, 0), try sm.getBalance(doomed));
    try std.testing.expectEqual(@as(u64, 0), try sm.getNonce(doomed));
    try std.testing.expectEqual(@as(usize, 0), (try sm.getCode(doomed)).len);
    try std.testing.expectEqual(@as(u256, 0), try sm.getStorage(doomed, 1));
    try std.testing.expectEqual(@as(u256, 0), try sm.getStorage(doomed, 2));
    try std.testing.expectEqual(@as(u256, 55), try sm.getBalance(bystander));
    try std.testing.expectEqual(@as(u256, 0xcccc), try sm.getStorage(bystander, 1));

    // The enclosing frame reverts: the deletion must be undone in full.
    sm.revert();
    try std.testing.expect(try adapter.accountExists(doomed));
    try std.testing.expectEqual(@as(u256, 1234), try sm.getBalance(doomed));
    try std.testing.expectEqual(@as(u64, 7), try sm.getNonce(doomed));
    try std.testing.expectEqualSlices(u8, &code, try sm.getCode(doomed));
    try std.testing.expectEqual(@as(u256, 0xaaaa), try sm.getStorage(doomed, 1));
    try std.testing.expectEqual(@as(u256, 0xbbbb), try sm.getStorage(doomed, 2));

    // A committed deletion sticks.
    try sm.checkpoint();
    try adapter.deleteAccount(doomed);
    sm.commit();
    try std.testing.expect(!try adapter.accountExists(doomed));
    try std.testing.expectEqual(@as(u256, 0), try sm.getStorage(doomed, 1));
    try std.testing.expect(!sm.journaled_state.account_cache.has(doomed));
}

fn expectHostError(adapter: *const host_adapter.HostAdapter, expected: host_adapter.HostAdapter.HostError) !void {
    try std.testing.expect(adapter.getHostError() != null);
    try std.testing.expectEqual(expected, adapter.getHostError().?);
}
