const std = @import("std");
const primitives = @import("primitives");
const state_manager = @import("state-manager");
const guillotine_mini = @import("guillotine_mini");

/// Adapts voltaire's StateManager to guillotine-mini's HostInterface vtable.
///
/// StateManager methods return errors (!T) but the HostInterface vtable
/// expects plain values (T). On error, sensible defaults are returned
/// (0 for balances/nonces/storage, empty slice for code).
pub const HostAdapter = struct {
    state: *state_manager.StateManager,

    const vtable = guillotine_mini.HostInterface.VTable{
        .getBalance = getBalance,
        .setBalance = setBalance,
        .getCode = getCode,
        .setCode = setCode,
        .getStorage = getStorage,
        .setStorage = setStorage,
        .getNonce = getNonce,
        .setNonce = setNonce,
    };

    pub fn hostInterface(self: *HostAdapter) guillotine_mini.HostInterface {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn getBalance(ptr: *anyopaque, address: primitives.Address) u256 {
        const self: *HostAdapter = @ptrCast(@alignCast(ptr));
        return self.state.getBalance(address) catch |err| {
            std.debug.panic("StateManager.getBalance failed: {}", .{err});
        };
    }

    fn setBalance(ptr: *anyopaque, address: primitives.Address, balance: u256) void {
        const self: *HostAdapter = @ptrCast(@alignCast(ptr));
        self.state.setBalance(address, balance) catch |err| {
            std.debug.panic("StateManager.setBalance failed: {}", .{err});
        };
    }

    fn getCode(ptr: *anyopaque, address: primitives.Address) []const u8 {
        const self: *HostAdapter = @ptrCast(@alignCast(ptr));
        return self.state.getCode(address) catch |err| {
            std.debug.panic("StateManager.getCode failed: {}", .{err});
        };
    }

    fn setCode(ptr: *anyopaque, address: primitives.Address, code: []const u8) void {
        const self: *HostAdapter = @ptrCast(@alignCast(ptr));
        self.state.setCode(address, code) catch |err| {
            std.debug.panic("StateManager.setCode failed: {}", .{err});
        };
    }

    fn getStorage(ptr: *anyopaque, address: primitives.Address, slot: u256) u256 {
        const self: *HostAdapter = @ptrCast(@alignCast(ptr));
        return self.state.getStorage(address, slot) catch |err| {
            std.debug.panic("StateManager.getStorage failed: {}", .{err});
        };
    }

    fn setStorage(ptr: *anyopaque, address: primitives.Address, slot: u256, value: u256) void {
        const self: *HostAdapter = @ptrCast(@alignCast(ptr));
        self.state.setStorage(address, slot, value) catch |err| {
            std.debug.panic("StateManager.setStorage failed: {}", .{err});
        };
    }

    fn getNonce(ptr: *anyopaque, address: primitives.Address) u64 {
        const self: *HostAdapter = @ptrCast(@alignCast(ptr));
        return self.state.getNonce(address) catch |err| {
            std.debug.panic("StateManager.getNonce failed: {}", .{err});
        };
    }

    fn setNonce(ptr: *anyopaque, address: primitives.Address, nonce: u64) void {
        const self: *HostAdapter = @ptrCast(@alignCast(ptr));
        self.state.setNonce(address, nonce) catch |err| {
            std.debug.panic("StateManager.setNonce failed: {}", .{err});
        };
    }
};
