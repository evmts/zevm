const std = @import("std");
const primitives = @import("primitives");
const state_manager = @import("state-manager");
const guillotine_mini = @import("guillotine_mini");
const console_log = @import("console_log.zig");

pub const HostAdapter = struct {
    state: *state_manager.StateManager,
    host_error: ?HostError = null,
    balance_change_allocator: ?std.mem.Allocator = null,
    balance_changes: ?*std.ArrayList(BalanceChange) = null,
    /// Node console-log buffer. When set, EVM calls to the Hardhat console
    /// address record their calldata here. Not owned by the adapter.
    console_logs: ?*console_log.ConsoleLogBuffer = null,

    pub const BalanceChange = struct {
        address: primitives.Address,
        before: u256,
        after: u256,
    };

    pub const HostError = enum {
        state_read_failed,
        state_write_failed,
        missing_key,
        out_of_memory,
        rpc_pending,
        invalid_response,
        invalid_request,
    };

    pub const Error = error{
        StateReadFailed,
        StateWriteFailed,
        MissingKey,
        OutOfMemory,
        RpcPending,
        InvalidResponse,
        InvalidRequest,
    };

    const vtable = guillotine_mini.HostInterface.VTable{
        .getBalance = getBalanceVTable,
        .setBalance = setBalanceVTable,
        .getCode = getCodeVTable,
        .setCode = setCodeVTable,
        .getStorage = getStorageVTable,
        .setStorage = setStorageVTable,
        .getNonce = getNonceVTable,
        .setNonce = setNonceVTable,
        .accountExists = accountExistsVTable,
        .deleteAccount = deleteAccountVTable,
    };

    pub fn hostInterface(self: *HostAdapter) guillotine_mini.HostInterface {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn fromHostInterface(host_iface: guillotine_mini.HostInterface) ?*HostAdapter {
        if (host_iface.vtable != &vtable) return null;
        return @ptrCast(@alignCast(host_iface.ptr));
    }

    pub fn getHostError(self: *const HostAdapter) ?HostError {
        return self.host_error;
    }

    pub fn clearHostError(self: *HostAdapter) void {
        self.host_error = null;
    }

    pub fn takeHostError(self: *HostAdapter) ?HostError {
        const host_error = self.host_error;
        self.host_error = null;
        return host_error;
    }

    pub fn getBalance(self: *HostAdapter, address: primitives.Address) Error!u256 {
        return self.state.getBalance(address) catch |err| return hostErrorToError(mapStateReadError(err));
    }

    pub fn setBalance(self: *HostAdapter, address: primitives.Address, balance: u256) Error!void {
        const before = if (self.balance_changes != null) self.state.getBalance(address) catch 0 else 0;
        self.state.setBalance(address, balance) catch |err| return hostErrorToError(mapStateWriteError(err));
        self.recordBalanceChange(address, before, balance);
    }

    pub fn getCode(self: *HostAdapter, address: primitives.Address) Error![]const u8 {
        return self.state.getCode(address) catch |err| return hostErrorToError(mapStateReadError(err));
    }

    pub fn setCode(self: *HostAdapter, address: primitives.Address, code: []const u8) Error!void {
        self.state.setCode(address, code) catch |err| return hostErrorToError(mapStateWriteError(err));
    }

    pub fn getStorage(self: *HostAdapter, address: primitives.Address, slot: u256) Error!u256 {
        return self.state.getStorage(address, slot) catch |err| return hostErrorToError(mapStateReadError(err));
    }

    pub fn setStorage(self: *HostAdapter, address: primitives.Address, slot: u256, value: u256) Error!void {
        self.state.setStorage(address, slot, value) catch |err| return hostErrorToError(mapStateWriteError(err));
    }

    pub fn getNonce(self: *HostAdapter, address: primitives.Address) Error!u64 {
        return self.state.getNonce(address) catch |err| return hostErrorToError(mapStateReadError(err));
    }

    pub fn setNonce(self: *HostAdapter, address: primitives.Address, nonce: u64) Error!void {
        self.state.setNonce(address, nonce) catch |err| return hostErrorToError(mapStateWriteError(err));
    }

    /// Removes an account (SELFDESTRUCT and EIP-161 empty-account cleanup).
    ///
    /// Every write goes through the checkpointed caches, so an enclosing
    /// `revert` restores the account in full.
    ///
    /// Local state: the cache entries are dropped, so the account also leaves
    /// the state trie on the next sync. Cache checkpoints are full snapshots,
    /// which makes the removal revertible.
    ///
    /// Forked state: dropping the entries would make the next read fetch the
    /// remote account again and resurrect it. The account is overwritten with
    /// an empty tombstone instead: balance, nonce and code go through the
    /// `StateManager` setters and every locally cached slot is zeroed.
    pub fn deleteAccount(self: *HostAdapter, address: primitives.Address) Error!void {
        const before = if (self.balance_changes != null) self.state.getBalance(address) catch 0 else 0;
        const journal = &self.state.journaled_state;

        if (journal.fork_backend == null) {
            _ = journal.account_cache.delete(address);
            _ = journal.contract_cache.delete(address);
            if (journal.storage_cache.cache.fetchRemove(address)) |entry| {
                var slots = entry.value;
                slots.deinit();
            }
        } else {
            // `putAccount` also resets the remote `code_hash` and `storage_root`.
            journal.putAccount(address, .{
                .nonce = 0,
                .balance = 0,
                .code_hash = primitives.Hash.ZERO,
                .storage_root = primitives.Hash.ZERO,
            }) catch |err| return hostErrorToError(mapStateWriteError(err));
            self.state.setCode(address, &.{}) catch |err| return hostErrorToError(mapStateWriteError(err));
            // Zero in place: `setStorage` during iteration could rehash the map.
            if (journal.storage_cache.cache.getPtr(address)) |slots| {
                var values = slots.valueIterator();
                while (values.next()) |value| value.* = 0;
            }
        }
        self.recordBalanceChange(address, before, 0);
    }

    /// EIP-161 existence: an account exists when it is non-empty, that is
    /// `nonce > 0`, `balance > 0`, or it has code. Bare cache presence is not
    /// existence: reads of a forked account and zero-value writes both create
    /// cache entries for accounts that are not in the state.
    pub fn accountExists(self: *HostAdapter, address: primitives.Address) Error!bool {
        const journal = &self.state.journaled_state;
        const account = journal.getAccount(address) catch |err| return hostErrorToError(mapStateReadError(err));
        if (account.nonce != 0 or account.balance != 0) return true;

        // Locally written code is authoritative; `AccountState.code_hash` is
        // only populated for accounts fetched from a fork.
        if (journal.contract_cache.get(address)) |code| return code.len != 0;
        if (journal.fork_backend == null) return false;
        return !std.mem.eql(u8, &account.code_hash, &primitives.State.EMPTY_CODE_HASH) and
            !std.mem.eql(u8, &account.code_hash, &primitives.Hash.ZERO);
    }

    pub fn accountIsEmpty(self: *HostAdapter, address: primitives.Address) Error!bool {
        const account = self.state.journaled_state.getAccount(address) catch |err|
            return hostErrorToError(mapStateReadError(err));
        const code = self.state.getCode(address) catch |err| return hostErrorToError(mapStateReadError(err));
        return account.balance == 0 and account.nonce == 0 and code.len == 0;
    }

    fn getBalanceVTable(ptr: *anyopaque, address: primitives.Address) u256 {
        const self: *HostAdapter = @ptrCast(@alignCast(ptr));
        return self.state.getBalance(address) catch |err| {
            self.recordError(mapStateReadError(err));
            return 0;
        };
    }

    fn setBalanceVTable(ptr: *anyopaque, address: primitives.Address, balance: u256) void {
        const self: *HostAdapter = @ptrCast(@alignCast(ptr));
        const before = if (self.balance_changes != null) self.state.getBalance(address) catch 0 else 0;
        self.state.setBalance(address, balance) catch |err| {
            self.recordError(mapStateWriteError(err));
            return;
        };
        self.recordBalanceChange(address, before, balance);
    }

    fn getCodeVTable(ptr: *anyopaque, address: primitives.Address) []const u8 {
        const self: *HostAdapter = @ptrCast(@alignCast(ptr));
        return self.state.getCode(address) catch |err| {
            self.recordError(mapStateReadError(err));
            return &[_]u8{};
        };
    }

    fn setCodeVTable(ptr: *anyopaque, address: primitives.Address, code: []const u8) void {
        const self: *HostAdapter = @ptrCast(@alignCast(ptr));
        self.state.setCode(address, code) catch |err| {
            self.recordError(mapStateWriteError(err));
        };
    }

    fn getStorageVTable(ptr: *anyopaque, address: primitives.Address, slot: u256) u256 {
        const self: *HostAdapter = @ptrCast(@alignCast(ptr));
        return self.state.getStorage(address, slot) catch |err| {
            self.recordError(mapStateReadError(err));
            return 0;
        };
    }

    fn setStorageVTable(ptr: *anyopaque, address: primitives.Address, slot: u256, value: u256) void {
        const self: *HostAdapter = @ptrCast(@alignCast(ptr));
        self.state.setStorage(address, slot, value) catch |err| {
            self.recordError(mapStateWriteError(err));
        };
    }

    fn getNonceVTable(ptr: *anyopaque, address: primitives.Address) u64 {
        const self: *HostAdapter = @ptrCast(@alignCast(ptr));
        return self.state.getNonce(address) catch |err| {
            self.recordError(mapStateReadError(err));
            return 0;
        };
    }

    fn setNonceVTable(ptr: *anyopaque, address: primitives.Address, nonce: u64) void {
        const self: *HostAdapter = @ptrCast(@alignCast(ptr));
        self.state.setNonce(address, nonce) catch |err| {
            self.recordError(mapStateWriteError(err));
        };
    }

    fn accountExistsVTable(ptr: *anyopaque, address: primitives.Address) bool {
        const self: *HostAdapter = @ptrCast(@alignCast(ptr));
        return self.accountExists(address) catch |err| {
            self.recordError(mapStateReadError(err));
            return false;
        };
    }

    fn deleteAccountVTable(ptr: *anyopaque, address: primitives.Address) void {
        const self: *HostAdapter = @ptrCast(@alignCast(ptr));
        self.deleteAccount(address) catch |err| {
            self.recordError(mapStateWriteError(err));
        };
    }

    fn recordError(self: *HostAdapter, host_error: HostError) void {
        if (self.host_error == null) {
            self.host_error = host_error;
        }
    }

    fn recordBalanceChange(self: *HostAdapter, address: primitives.Address, before: u256, after: u256) void {
        if (before == after) return;
        const changes = self.balance_changes orelse return;
        const allocator = self.balance_change_allocator orelse {
            self.recordError(.invalid_request);
            return;
        };
        changes.append(allocator, .{
            .address = address,
            .before = before,
            .after = after,
        }) catch self.recordError(.out_of_memory);
    }

    fn mapStateReadError(err: anyerror) HostError {
        return switch (err) {
            error.OutOfMemory => .out_of_memory,
            error.RpcPending => .rpc_pending,
            error.InvalidResponse => .invalid_response,
            error.InvalidRequest => .invalid_request,
            error.FileNotFound, error.KeyNotFound, error.MissingKey, error.NoEntry, error.NotFound => .missing_key,
            else => .state_read_failed,
        };
    }

    fn mapStateWriteError(err: anyerror) HostError {
        return switch (err) {
            error.OutOfMemory => .out_of_memory,
            error.RpcPending => .rpc_pending,
            error.InvalidResponse => .invalid_response,
            error.InvalidRequest => .invalid_request,
            error.FileNotFound, error.KeyNotFound, error.MissingKey, error.NoEntry, error.NotFound => .missing_key,
            else => .state_write_failed,
        };
    }

    fn hostErrorToError(host_error: HostError) Error {
        return switch (host_error) {
            .state_read_failed => error.StateReadFailed,
            .state_write_failed => error.StateWriteFailed,
            .missing_key => error.MissingKey,
            .out_of_memory => error.OutOfMemory,
            .rpc_pending => error.RpcPending,
            .invalid_response => error.InvalidResponse,
            .invalid_request => error.InvalidRequest,
        };
    }
};
