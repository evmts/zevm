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
