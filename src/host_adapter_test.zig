const std = @import("std");
const primitives = @import("primitives");
const state_manager = @import("state-manager");
const host_adapter = @import("host_adapter.zig");

const ForkResolverContext = struct {
    allocator: std.mem.Allocator,
    fork_backend: *state_manager.ForkBackend,
    nonce: u64 = 5,
    balance: u256 = 0x7b,
    storage_value: u256 = 0x99,
    code_hex: []const u8 = "0x6000",
};

fn resolveForkRequest(context: *anyopaque) bool {
    const typed_context: *ForkResolverContext = @ptrCast(@alignCast(context));
    const request = typed_context.fork_backend.nextRequest() orelse return false;

    const parsed = std.json.parseFromSlice(std.json.Value, typed_context.allocator, request.params_json, .{}) catch return false;
    defer parsed.deinit();

    const items = switch (parsed.value) {
        .array => |array| array.items,
        else => return false,
    };

    if (items.len == 2) {
        const code_response = std.fmt.allocPrint(typed_context.allocator, "\"{s}\"", .{typed_context.code_hex}) catch return false;
        defer typed_context.allocator.free(code_response);
        typed_context.fork_backend.continueRequest(request.id, code_response) catch return false;
        return true;
    }

    const zero_hash = "0x0000000000000000000000000000000000000000000000000000000000000000";
    const slot_values = if (items.len >= 2 and items[1] == .array) items[1].array.items else &[_]std.json.Value{};

    if (slot_values.len > 0) {
        const slot_hex = switch (slot_values[0]) {
            .string => |slot| slot,
            else => "0x0",
        };
        const proof_response = std.fmt.allocPrint(
            typed_context.allocator,
            "{{\"nonce\":\"0x{x}\",\"balance\":\"0x{x}\",\"codeHash\":\"{s}\",\"storageHash\":\"{s}\",\"storageProof\":[{{\"key\":\"{s}\",\"value\":\"0x{x}\",\"proof\":[]}}]}}",
            .{ typed_context.nonce, typed_context.balance, zero_hash, zero_hash, slot_hex, typed_context.storage_value },
        ) catch return false;
        defer typed_context.allocator.free(proof_response);
        typed_context.fork_backend.continueRequest(request.id, proof_response) catch return false;
        return true;
    }

    const account_response = std.fmt.allocPrint(
        typed_context.allocator,
        "{{\"nonce\":\"0x{x}\",\"balance\":\"0x{x}\",\"codeHash\":\"{s}\",\"storageHash\":\"{s}\"}}",
        .{ typed_context.nonce, typed_context.balance, zero_hash, zero_hash },
    ) catch return false;
    defer typed_context.allocator.free(account_response);
    typed_context.fork_backend.continueRequest(request.id, account_response) catch return false;
    return true;
}

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

test "host adapter returns defaults when fork pending cannot be resolved" {
    var fork_backend = try state_manager.ForkBackend.init(std.testing.allocator, "latest", .{});
    defer fork_backend.deinit();

    var sm = try state_manager.StateManager.init(std.testing.allocator, &fork_backend);
    defer sm.deinit();

    var adapter = host_adapter.HostAdapter{ .state = &sm };
    const host = adapter.hostInterface();
    const addr = primitives.Address{ .bytes = [_]u8{0xaa} ++ [_]u8{0} ** 19 };

    try std.testing.expectEqual(@as(u256, 0), host.getBalance(addr));
    try std.testing.expectEqual(@as(u64, 0), host.getNonce(addr));
    try std.testing.expectEqual(@as(u256, 0), host.getStorage(addr, 1));
    try std.testing.expectEqual(@as(usize, 0), host.getCode(addr).len);
}

test "host adapter resolves fork pending requests via resolver callback" {
    var fork_backend = try state_manager.ForkBackend.init(std.testing.allocator, "latest", .{});
    defer fork_backend.deinit();

    var sm = try state_manager.StateManager.init(std.testing.allocator, &fork_backend);
    defer sm.deinit();

    var resolver_context = ForkResolverContext{
        .allocator = std.testing.allocator,
        .fork_backend = &fork_backend,
    };
    var adapter = host_adapter.HostAdapter{
        .state = &sm,
        .fork_resolver = .{
            .context = @ptrCast(&resolver_context),
            .resolve = resolveForkRequest,
        },
    };
    const host = adapter.hostInterface();
    const addr = primitives.Address{ .bytes = [_]u8{0xbb} ++ [_]u8{0} ** 19 };

    try std.testing.expectEqual(resolver_context.balance, host.getBalance(addr));
    try std.testing.expectEqual(resolver_context.nonce, host.getNonce(addr));
    try std.testing.expectEqual(resolver_context.storage_value, host.getStorage(addr, 1));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x60, 0x00 }, host.getCode(addr));
}
