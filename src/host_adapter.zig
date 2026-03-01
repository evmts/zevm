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
    fork_resolver: ?ForkResolver = null,

    pub const ForkResolver = struct {
        context: *anyopaque,
        resolve: *const fn (context: *anyopaque) bool,
    };

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

    fn resolvePendingFork(self: *HostAdapter) bool {
        const resolver = self.fork_resolver orelse return false;
        return resolver.resolve(resolver.context);
    }

    fn getBalance(ptr: *anyopaque, address: primitives.Address) u256 {
        const self: *HostAdapter = @ptrCast(@alignCast(ptr));

        var attempts: usize = 0;
        while (attempts < 256) : (attempts += 1) {
            return self.state.getBalance(address) catch |err| switch (err) {
                error.RpcPending => {
                    if (!self.resolvePendingFork()) return 0;
                    continue;
                },
                else => return 0,
            };
        }

        return 0;
    }

    fn setBalance(ptr: *anyopaque, address: primitives.Address, balance: u256) void {
        const self: *HostAdapter = @ptrCast(@alignCast(ptr));

        var attempts: usize = 0;
        while (attempts < 256) : (attempts += 1) {
            self.state.setBalance(address, balance) catch |err| switch (err) {
                error.RpcPending => {
                    if (!self.resolvePendingFork()) return;
                    continue;
                },
                else => return,
            };
            return;
        }
    }

    fn getCode(ptr: *anyopaque, address: primitives.Address) []const u8 {
        const self: *HostAdapter = @ptrCast(@alignCast(ptr));

        var attempts: usize = 0;
        while (attempts < 256) : (attempts += 1) {
            return self.state.getCode(address) catch |err| switch (err) {
                error.RpcPending => {
                    if (!self.resolvePendingFork()) return &[_]u8{};
                    continue;
                },
                else => return &[_]u8{},
            };
        }

        return &[_]u8{};
    }

    fn setCode(ptr: *anyopaque, address: primitives.Address, code: []const u8) void {
        const self: *HostAdapter = @ptrCast(@alignCast(ptr));
        self.state.setCode(address, code) catch return;
    }

    fn getStorage(ptr: *anyopaque, address: primitives.Address, slot: u256) u256 {
        const self: *HostAdapter = @ptrCast(@alignCast(ptr));

        var attempts: usize = 0;
        while (attempts < 256) : (attempts += 1) {
            return self.state.getStorage(address, slot) catch |err| switch (err) {
                error.RpcPending => {
                    if (!self.resolvePendingFork()) return 0;
                    continue;
                },
                else => return 0,
            };
        }

        return 0;
    }

    fn setStorage(ptr: *anyopaque, address: primitives.Address, slot: u256, value: u256) void {
        const self: *HostAdapter = @ptrCast(@alignCast(ptr));
        self.state.setStorage(address, slot, value) catch return;
    }

    fn getNonce(ptr: *anyopaque, address: primitives.Address) u64 {
        const self: *HostAdapter = @ptrCast(@alignCast(ptr));

        var attempts: usize = 0;
        while (attempts < 256) : (attempts += 1) {
            return self.state.getNonce(address) catch |err| switch (err) {
                error.RpcPending => {
                    if (!self.resolvePendingFork()) return 0;
                    continue;
                },
                else => return 0,
            };
        }

        return 0;
    }

    fn setNonce(ptr: *anyopaque, address: primitives.Address, nonce: u64) void {
        const self: *HostAdapter = @ptrCast(@alignCast(ptr));

        var attempts: usize = 0;
        while (attempts < 256) : (attempts += 1) {
            self.state.setNonce(address, nonce) catch |err| switch (err) {
                error.RpcPending => {
                    if (!self.resolvePendingFork()) return;
                    continue;
                },
                else => return,
            };
            return;
        }
    }
};
