const primitives = @import("primitives");
const state_manager = @import("state-manager");
const guillotine_mini = @import("guillotine_mini");

pub const HostAdapter = struct {
    state: *state_manager.StateManager,
    host_error: ?HostError = null,

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
        self.state.setBalance(address, balance) catch |err| return hostErrorToError(mapStateWriteError(err));
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

    pub fn deleteAccount(self: *HostAdapter, address: primitives.Address) Error!void {
        _ = self.state.journaled_state.account_cache.delete(address);
        _ = self.state.journaled_state.contract_cache.delete(address);
        if (self.state.journaled_state.storage_cache.cache.fetchRemove(address)) |entry| {
            var slots = entry.value;
            slots.deinit();
        }
    }

    pub fn accountExists(self: *HostAdapter, address: primitives.Address) Error!bool {
        if (self.state.journaled_state.account_cache.has(address)) return true;
        if (self.state.journaled_state.contract_cache.has(address)) return true;
        if (self.state.journaled_state.storage_cache.cache.contains(address)) return true;

        if (self.state.journaled_state.fork_backend != null) {
            _ = self.state.journaled_state.getAccount(address) catch |err| return hostErrorToError(mapStateReadError(err));
            return self.state.journaled_state.account_cache.has(address);
        }

        return false;
    }

    pub fn accountIsEmpty(self: *HostAdapter, address: primitives.Address) Error!bool {
        const account = self.state.journaled_state.getAccount(address) catch |err| return hostErrorToError(mapStateReadError(err));
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
        self.state.setBalance(address, balance) catch |err| {
            self.recordError(mapStateWriteError(err));
        };
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
