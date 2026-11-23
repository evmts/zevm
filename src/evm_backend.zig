//! Pluggable EVM backend seam.
//!
//! `tx_processor` owns transaction validity, fee settlement, and receipts. A
//! backend owns only the execution of one top-level message against a host.
//! The default backend is guillotine-mini with its stock configuration (no
//! opcode overrides). A second EVM (for example `evmts/guillotine`) plugs in by
//! supplying an `ExternalRunner`; `tx_processor` callers do not change.
const std = @import("std");
const primitives = @import("primitives");
const guillotine_mini = @import("guillotine_mini");

pub const BackendKind = enum { guillotine_mini, external };

/// The reference EVM type: guillotine-mini with the stock configuration.
/// guillotine-mini preserves CALLVALUE across DELEGATECALL natively, so no
/// opcode override is installed.
pub const GuillotineMiniEvm = guillotine_mini.Evm(.{});

pub const ExecuteError = error{
    OutOfMemory,
    EvmInitError,
};

/// One top-level message. All slices are borrowed for the duration of
/// `execute`; the backend must not retain them.
pub const ExecutionRequest = struct {
    host: guillotine_mini.HostInterface,
    hardfork: guillotine_mini.Hardfork,
    block_context: guillotine_mini.BlockContext,
    /// Transaction origin and caller of the top-level frame.
    caller: primitives.Address,
    /// Call target, or `null` for contract creation.
    to: ?primitives.Address,
    value: u256,
    /// Calldata for calls, init code for creations.
    input: []const u8,
    /// Execution gas: the gas limit minus intrinsic gas.
    gas: u64,
    /// Effective gas price reported by GASPRICE.
    gas_price: u256,
    /// Deployed code of `to`. Ignored for creations.
    code: []const u8 = &.{},
    access_list: ?primitives.AccessList.AccessList = null,
    /// Addresses warm at the start of execution besides `access_list`, at no
    /// intrinsic gas cost: the EIP-7702 authorities recovered from the
    /// authorization list. A backend must add them to `accessed_addresses`.
    warm_addresses: []const primitives.Address = &.{},
    blob_versioned_hashes: ?[]const [32]u8 = null,
    precompile_overrides: []const guillotine_mini.PrecompileOverride = &.{},
};

/// Backend-neutral execution outcome. `output` and `logs` are owned by the
/// allocator passed to `execute`; release them with `deinit`.
pub const ExecutionResult = struct {
    success: bool,
    gas_left: u64,
    output: []const u8,
    refund_counter: u64 = 0,
    logs: []const guillotine_mini.Log = &.{},
    created_address: ?primitives.Address = null,

    pub const Fields = struct {
        success: bool,
        gas_left: u64,
        output: []const u8 = &.{},
        refund_counter: u64 = 0,
        logs: []const guillotine_mini.Log = &.{},
        created_address: ?primitives.Address = null,
    };

    /// Deep-copies `fields.output` and `fields.logs` into `allocator`.
    pub fn initOwned(allocator: std.mem.Allocator, fields: Fields) error{OutOfMemory}!ExecutionResult {
        const output = try allocator.dupe(u8, fields.output);
        errdefer allocator.free(output);
        const logs = try cloneLogs(allocator, fields.logs);
        return .{
            .success = fields.success,
            .gas_left = fields.gas_left,
            .output = output,
            .refund_counter = fields.refund_counter,
            .logs = logs,
            .created_address = fields.created_address,
        };
    }

    pub fn deinit(self: *ExecutionResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
        for (self.logs) |log| {
            allocator.free(log.topics);
            allocator.free(log.data);
        }
        allocator.free(self.logs);
        self.* = undefined;
    }
};

/// Vtable for an alternative EVM. `execute` must return a result created with
/// `ExecutionResult.initOwned` (or equivalently owned by `allocator`), apply
/// state changes through `request.host`, and report allocation failure as
/// `error.OutOfMemory` rather than as a failed execution.
pub const ExternalRunner = struct {
    context: ?*anyopaque = null,
    execute: *const fn (
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        request: ExecutionRequest,
    ) ExecuteError!ExecutionResult,
};

pub const Backend = union(BackendKind) {
    guillotine_mini,
    external: ExternalRunner,

    pub fn execute(
        self: Backend,
        allocator: std.mem.Allocator,
        request: ExecutionRequest,
    ) ExecuteError!ExecutionResult {
        return switch (self) {
            .guillotine_mini => executeGuillotineMini(allocator, request),
            .external => |runner| runner.execute(runner.context, allocator, request),
        };
    }
};

pub const default_backend: Backend = .guillotine_mini;

fn cloneLogs(
    allocator: std.mem.Allocator,
    logs: []const guillotine_mini.Log,
) error{OutOfMemory}![]const guillotine_mini.Log {
    const out = try allocator.alloc(guillotine_mini.Log, logs.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |log| {
            allocator.free(log.topics);
            allocator.free(log.data);
        }
        allocator.free(out);
    }

    for (logs, 0..) |log, i| {
        const topics = try allocator.dupe(u256, log.topics);
        errdefer allocator.free(topics);
        const data = try allocator.dupe(u8, log.data);
        out[i] = .{ .address = log.address, .topics = topics, .data = data };
        initialized += 1;
    }
    return out;
}

fn initError(err: anyerror) ExecuteError {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.EvmInitError;
}

fn executeGuillotineMini(
    allocator: std.mem.Allocator,
    request: ExecutionRequest,
) ExecuteError!ExecutionResult {
    // guillotine-mini pre-warms from one access list, so `warm_addresses`
    // join it as entries without storage keys. Declared before the EVM so the
    // merged list outlives it.
    var merged_access_list: ?[]primitives.AccessList.AccessListEntry = null;
    defer if (merged_access_list) |entries| allocator.free(entries);
    if (request.warm_addresses.len > 0) {
        const listed: primitives.AccessList.AccessList = request.access_list orelse &.{};
        const entries = try allocator.alloc(
            primitives.AccessList.AccessListEntry,
            listed.len + request.warm_addresses.len,
        );
        @memcpy(entries[0..listed.len], listed);
        for (entries[listed.len..], request.warm_addresses) |*entry, address| {
            entry.* = .{ .address = address, .storage_keys = &.{} };
        }
        merged_access_list = entries;
    }

    var evm: GuillotineMiniEvm = undefined;
    evm.init(
        allocator,
        request.host,
        request.hardfork,
        request.block_context,
        request.caller,
        request.gas_price,
        null,
    ) catch |err| return initError(err);
    defer evm.deinit();
    evm.initTransactionState(null) catch |err| return initError(err);
    evm.precompile_overrides = request.precompile_overrides;
    if (request.blob_versioned_hashes) |hashes| {
        evm.setBlobVersionedHashes(hashes);
    }

    // guillotine-mini reads the top-level frame's code from the pending
    // bytecode: deployed code for calls, init code for creations.
    evm.setBytecode(if (request.to != null) request.code else request.input);
    evm.setAccessList(if (merged_access_list) |entries| entries else request.access_list);

    const call_params: GuillotineMiniEvm.CallParams = if (request.to) |to|
        .{ .call = .{
            .caller = request.caller,
            .to = to,
            .value = request.value,
            .input = request.input,
            .gas = request.gas,
        } }
    else
        .{ .create = .{
            .caller = request.caller,
            .value = request.value,
            .init_code = request.input,
            .gas = request.gas,
        } };

    const result = evm.call(call_params);

    // guillotine-mini reports host-side allocation failure as a failed call
    // tagged with the error name. That is a node fault, not an EVM outcome.
    if (!result.success) {
        if (result.error_info) |info| {
            if (std.mem.eql(u8, info, @errorName(error.OutOfMemory))) return error.OutOfMemory;
        }
    }

    return ExecutionResult.initOwned(allocator, .{
        .success = result.success,
        .gas_left = result.gas_left,
        .output = result.output,
        .refund_counter = result.refund_counter,
        .logs = result.logs,
        .created_address = result.created_address,
    });
}

test "default backend is guillotine-mini" {
    try std.testing.expectEqual(BackendKind.guillotine_mini, std.meta.activeTag(default_backend));
}

test "external runner receives the request and its context" {
    const Probe = struct {
        calls: usize = 0,
        gas_seen: u64 = 0,

        fn execute(
            context: ?*anyopaque,
            allocator: std.mem.Allocator,
            request: ExecutionRequest,
        ) ExecuteError!ExecutionResult {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            self.gas_seen = request.gas;
            const topics = [_]u256{7};
            const logs = [_]guillotine_mini.Log{.{
                .address = request.caller,
                .topics = &topics,
                .data = request.input,
            }};
            return ExecutionResult.initOwned(allocator, .{
                .success = true,
                .gas_left = request.gas / 2,
                .output = request.input,
                .logs = &logs,
            });
        }
    };

    var probe = Probe{};
    const backend = Backend{ .external = .{ .context = &probe, .execute = Probe.execute } };
    try std.testing.expectEqual(BackendKind.external, std.meta.activeTag(backend));

    var result = try backend.execute(std.testing.allocator, .{
        .host = undefined,
        .hardfork = .CANCUN,
        .block_context = undefined,
        .caller = primitives.Address.fromU256(1),
        .to = primitives.Address.fromU256(2),
        .value = 0,
        .input = &[_]u8{ 0xaa, 0xbb },
        .gas = 1000,
        .gas_price = 0,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(u64, 1000), probe.gas_seen);
    try std.testing.expectEqual(@as(u64, 500), result.gas_left);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xaa, 0xbb }, result.output);
    try std.testing.expectEqual(@as(usize, 1), result.logs.len);
    try std.testing.expectEqual(@as(u256, 7), result.logs[0].topics[0]);
}

test "ExecutionResult.initOwned frees partial copies on allocation failure" {
    const topics = [_]u256{ 1, 2 };
    const logs = [_]guillotine_mini.Log{
        .{ .address = primitives.Address.fromU256(1), .topics = &topics, .data = &[_]u8{0x01} },
        .{ .address = primitives.Address.fromU256(2), .topics = &topics, .data = &[_]u8{0x02} },
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator, src_logs: []const guillotine_mini.Log) !void {
            var result = try ExecutionResult.initOwned(allocator, .{
                .success = true,
                .gas_left = 0,
                .output = &[_]u8{0xff},
                .logs = src_logs,
            });
            result.deinit(allocator);
        }
    }.run, .{@as([]const guillotine_mini.Log, &logs)});
}
