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

test "host adapter distinguishes account existence from emptiness" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();

    var adapter = host_adapter.HostAdapter{ .state = &sm };
    const absent = primitives.Address{ .bytes = [_]u8{0x99} ++ [_]u8{0} ** 19 };
    const empty = primitives.Address{ .bytes = [_]u8{0xaa} ++ [_]u8{0} ** 19 };
    const non_empty = primitives.Address{ .bytes = [_]u8{0xbb} ++ [_]u8{0} ** 19 };
    const code_account = primitives.Address{ .bytes = [_]u8{0xcc} ++ [_]u8{0} ** 19 };
    const code = [_]u8{0x00};

    try std.testing.expect(!try adapter.accountExists(absent));
    try std.testing.expect(try adapter.accountIsEmpty(absent));

    try sm.setBalance(empty, 0);
    try std.testing.expect(try adapter.accountExists(empty));
    try std.testing.expect(try adapter.accountIsEmpty(empty));

    try sm.setNonce(non_empty, 1);
    try std.testing.expect(try adapter.accountExists(non_empty));
    try std.testing.expect(!try adapter.accountIsEmpty(non_empty));

    try sm.setCode(code_account, &code);
    try std.testing.expect(try adapter.accountExists(code_account));
    try std.testing.expect(!try adapter.accountIsEmpty(code_account));
}

fn expectHostError(adapter: *const host_adapter.HostAdapter, expected: host_adapter.HostAdapter.HostError) !void {
    try std.testing.expect(adapter.getHostError() != null);
    try std.testing.expectEqual(expected, adapter.getHostError().?);
}
