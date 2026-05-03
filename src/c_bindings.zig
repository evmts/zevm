//! C ABI for the zevm light client.
//!
//! See include/zevm.h for the public contract.
//!
//! Implementation notes:
//! - The handle owns a c_allocator-backed ConsensusSyncEngine plus a small
//!   per-handle error buffer that backs zevm_light_last_error.
//! - Reads (balance/code/storage) call into light_proof.zig directly,
//!   using the verified state_root from the engine's optimistic_header.
//!   This is the same primitive the JSON-RPC layer would compose with;
//!   we just bypass the JSON wrapper.
//! - `block_number == 0` is the supported "latest verified head" path.
//!   A non-zero block_number is only valid if it matches the currently
//!   verified optimistic or finalized header; otherwise the call fails
//!   with ZEVM_ERR_BLOCK_UNAVAILABLE. zevm carries no historical state
//!   today, so this is the honest contract.

const std = @import("std");
const builtin = @import("builtin");
const primitives = @import("primitives");
const consensus_sync = @import("consensus_sync.zig");
const light_proof = @import("light_proof.zig");

const ZEVM_OK: c_int = 0;
const ZEVM_ERR_INVALID_ARG: c_int = 1;
const ZEVM_ERR_NOT_SYNCED: c_int = 2;
const ZEVM_ERR_BUFFER_TOO_SMALL: c_int = 3;
const ZEVM_ERR_NETWORK: c_int = 4;
const ZEVM_ERR_PROOF: c_int = 5;
const ZEVM_ERR_BLOCK_UNAVAILABLE: c_int = 6;
const ZEVM_ERR_INTERNAL: c_int = 7;

const ZEVM_STATUS_NOT_SYNCED: c_int = 0;
const ZEVM_STATUS_SYNCING: c_int = 1;
const ZEVM_STATUS_SYNCED: c_int = 2;

const ZEVM_NETWORK_MAINNET: c_int = 0;
const ZEVM_NETWORK_SEPOLIA: c_int = 1;
const ZEVM_NETWORK_HOLESKY: c_int = 2;

const MAX_ERROR_LEN: usize = 512;

const Handle = struct {
    allocator: std.mem.Allocator,
    engine: consensus_sync.ConsensusSyncEngine,
    beacon_url: []u8,
    execution_url: []u8,
    initial_done: bool,
    error_buf: [MAX_ERROR_LEN]u8,
    error_len: usize,
};

fn handleFromOpaque(opaque_ptr: ?*anyopaque) ?*Handle {
    const ptr = opaque_ptr orelse return null;
    return @as(*Handle, @ptrCast(@alignCast(ptr)));
}

fn opaqueFromHandle(handle: *Handle) *anyopaque {
    return @ptrCast(handle);
}

fn clearError(handle: *Handle) void {
    handle.error_len = 0;
    handle.error_buf[0] = 0;
}

fn setError(handle: *Handle, comptime fmt: []const u8, args: anytype) void {
    const written = std.fmt.bufPrint(handle.error_buf[0 .. MAX_ERROR_LEN - 1], fmt, args) catch blk: {
        const truncated = "error message truncated";
        const len = @min(truncated.len, MAX_ERROR_LEN - 1);
        @memcpy(handle.error_buf[0..len], truncated[0..len]);
        break :blk handle.error_buf[0..len];
    };
    handle.error_buf[written.len] = 0;
    handle.error_len = written.len;
}

fn networkConfig(network: c_int, beacon_url: []const u8) ?consensus_sync.NetworkConfig {
    return switch (network) {
        ZEVM_NETWORK_MAINNET => consensus_sync.NetworkConfig.mainnet(beacon_url),
        ZEVM_NETWORK_SEPOLIA => consensus_sync.NetworkConfig.sepolia(beacon_url),
        ZEVM_NETWORK_HOLESKY => consensus_sync.NetworkConfig.holesky(beacon_url),
        else => null,
    };
}

fn cstrSliceOrNull(ptr: ?[*:0]const u8) ?[:0]const u8 {
    const p = ptr orelse return null;
    return std.mem.span(p);
}

export fn zevm_light_init(
    network: c_int,
    beacon_rpc_url: ?[*:0]const u8,
    execution_rpc_url: ?[*:0]const u8,
) callconv(.c) ?*anyopaque {
    const beacon_span = cstrSliceOrNull(beacon_rpc_url) orelse return null;
    const execution_span = cstrSliceOrNull(execution_rpc_url) orelse return null;

    const allocator = std.heap.c_allocator;

    const handle = allocator.create(Handle) catch return null;
    errdefer allocator.destroy(handle);

    const beacon_copy = allocator.dupe(u8, beacon_span) catch return null;
    errdefer allocator.free(beacon_copy);

    const execution_copy = allocator.dupe(u8, execution_span) catch return null;
    errdefer allocator.free(execution_copy);

    const config = networkConfig(network, beacon_copy) orelse {
        allocator.free(beacon_copy);
        allocator.free(execution_copy);
        allocator.destroy(handle);
        return null;
    };

    handle.* = .{
        .allocator = allocator,
        .engine = consensus_sync.ConsensusSyncEngine.init(config),
        .beacon_url = beacon_copy,
        .execution_url = execution_copy,
        .initial_done = false,
        .error_buf = undefined,
        .error_len = 0,
    };
    handle.error_buf[0] = 0;

    return opaqueFromHandle(handle);
}

export fn zevm_light_shutdown(opaque_ptr: ?*anyopaque) callconv(.c) void {
    const handle = handleFromOpaque(opaque_ptr) orelse return;
    handle.allocator.free(handle.beacon_url);
    handle.allocator.free(handle.execution_url);
    handle.allocator.destroy(handle);
}

export fn zevm_light_sync_step(opaque_ptr: ?*anyopaque) callconv(.c) c_int {
    const handle = handleFromOpaque(opaque_ptr) orelse return ZEVM_ERR_INVALID_ARG;
    clearError(handle);

    if (!handle.initial_done) {
        const checkpoint = handle.engine.config.default_checkpoint;
        const ctx = consensus_sync.CheckpointStartupContext{ .source = "c_bindings.default" };
        handle.engine.sync(handle.allocator, checkpoint, ctx) catch |err| {
            setError(handle, "initial sync failed: {s}", .{@errorName(err)});
            return ZEVM_ERR_NETWORK;
        };
        handle.initial_done = true;
        return ZEVM_OK;
    }

    handle.engine.advance(handle.allocator) catch |err| {
        setError(handle, "advance failed: {s}", .{@errorName(err)});
        return ZEVM_ERR_NETWORK;
    };
    return ZEVM_OK;
}

export fn zevm_light_status(opaque_ptr: ?*anyopaque) callconv(.c) c_int {
    const handle = handleFromOpaque(opaque_ptr) orelse return ZEVM_STATUS_NOT_SYNCED;
    return switch (handle.engine.status) {
        .synced => ZEVM_STATUS_SYNCED,
        .syncing => ZEVM_STATUS_SYNCING,
        .err => ZEVM_STATUS_NOT_SYNCED,
    };
}

export fn zevm_light_last_error(opaque_ptr: ?*anyopaque) callconv(.c) ?[*:0]const u8 {
    const handle = handleFromOpaque(opaque_ptr) orelse return null;
    return @ptrCast(&handle.error_buf[0]);
}

const ResolvedHeader = struct {
    state_root: [32]u8,
    block_number: u64,
    block_tag_hex: [20]u8,
    block_tag_len: usize,
};

fn resolveHeader(handle: *Handle, requested: u64) !ResolvedHeader {
    if (handle.engine.status != .synced) return error.NotSynced;

    const optimistic = handle.engine.store.optimistic_header.execution;
    const finalized = handle.engine.store.finalized_header.execution;

    var picked_state_root: [32]u8 = undefined;
    var picked_block_number: u64 = 0;

    if (requested == 0) {
        if (optimistic.block_number == 0) return error.NotSynced;
        picked_state_root = optimistic.state_root;
        picked_block_number = optimistic.block_number;
    } else if (optimistic.block_number != 0 and requested == optimistic.block_number) {
        picked_state_root = optimistic.state_root;
        picked_block_number = optimistic.block_number;
    } else if (finalized.block_number != 0 and requested == finalized.block_number) {
        picked_state_root = finalized.state_root;
        picked_block_number = finalized.block_number;
    } else {
        return error.BlockUnavailable;
    }

    var tag_buf: [20]u8 = undefined;
    const tag = try std.fmt.bufPrint(&tag_buf, "0x{x}", .{picked_block_number});
    var resolved: ResolvedHeader = .{
        .state_root = picked_state_root,
        .block_number = picked_block_number,
        .block_tag_hex = undefined,
        .block_tag_len = tag.len,
    };
    @memcpy(resolved.block_tag_hex[0..tag.len], tag);
    return resolved;
}

fn parseAddress(handle: *Handle, address_hex: ?[*:0]const u8) !primitives.Address {
    const span = cstrSliceOrNull(address_hex) orelse {
        setError(handle, "address_hex is null", .{});
        return error.InvalidArg;
    };
    return primitives.Address.fromHex(span) catch |err| {
        setError(handle, "invalid address: {s}", .{@errorName(err)});
        return error.InvalidArg;
    };
}

fn proofSource(handle: *Handle) light_proof.ProofSource {
    return .{ .url = handle.execution_url, .resolver = null };
}

fn writeQuantityHex(value: u256, scratch: []u8) ![]u8 {
    return std.fmt.bufPrint(scratch, "0x{x}", .{value});
}

fn writeStorageHex(value: u256, scratch: []u8) ![]u8 {
    return std.fmt.bufPrint(scratch, "0x{x:0>64}", .{value});
}

fn copyToCStringBuffer(out_hex: ?[*]u8, out_len: ?*usize, source: []const u8, handle: *Handle) c_int {
    const cap_ptr = out_len orelse return ZEVM_ERR_INVALID_ARG;
    const cap = cap_ptr.*;
    const required = source.len + 1;
    cap_ptr.* = required;
    if (cap < required) {
        setError(handle, "output buffer too small (needed {})", .{required});
        return ZEVM_ERR_BUFFER_TOO_SMALL;
    }
    const dst = out_hex orelse return ZEVM_ERR_INVALID_ARG;
    @memcpy(dst[0..source.len], source);
    dst[source.len] = 0;
    return ZEVM_OK;
}

fn classifyReadError(err: anyerror) c_int {
    return switch (err) {
        error.NotSynced => ZEVM_ERR_NOT_SYNCED,
        error.BlockUnavailable => ZEVM_ERR_BLOCK_UNAVAILABLE,
        error.InvalidArg => ZEVM_ERR_INVALID_ARG,
        error.MalformedProof, error.ProofVerifyFailed => ZEVM_ERR_PROOF,
        error.UpstreamRpcFailed, error.InvalidUpstreamRpcResponse => ZEVM_ERR_NETWORK,
        else => ZEVM_ERR_INTERNAL,
    };
}

export fn zevm_light_get_balance(
    opaque_ptr: ?*anyopaque,
    address_hex: ?[*:0]const u8,
    block_number: u64,
    out_hex: ?[*]u8,
    out_len: ?*usize,
) callconv(.c) c_int {
    const handle = handleFromOpaque(opaque_ptr) orelse return ZEVM_ERR_INVALID_ARG;
    clearError(handle);

    const address = parseAddress(handle, address_hex) catch return ZEVM_ERR_INVALID_ARG;

    const header = resolveHeader(handle, block_number) catch |err| {
        setError(handle, "resolveHeader: {s}", .{@errorName(err)});
        return classifyReadError(err);
    };

    const balance = light_proof.readBalance(
        handle.allocator,
        proofSource(handle),
        header.state_root,
        address,
        header.block_tag_hex[0..header.block_tag_len],
    ) catch |err| {
        setError(handle, "readBalance: {s}", .{@errorName(err)});
        return classifyReadError(err);
    };

    var scratch: [80]u8 = undefined;
    const text = writeQuantityHex(balance, &scratch) catch {
        setError(handle, "internal hex format", .{});
        return ZEVM_ERR_INTERNAL;
    };
    return copyToCStringBuffer(out_hex, out_len, text, handle);
}

export fn zevm_light_get_code(
    opaque_ptr: ?*anyopaque,
    address_hex: ?[*:0]const u8,
    block_number: u64,
    out_buf: ?[*]u8,
    out_len: ?*usize,
) callconv(.c) c_int {
    const handle = handleFromOpaque(opaque_ptr) orelse return ZEVM_ERR_INVALID_ARG;
    clearError(handle);

    const cap_ptr = out_len orelse return ZEVM_ERR_INVALID_ARG;
    const address = parseAddress(handle, address_hex) catch return ZEVM_ERR_INVALID_ARG;

    const header = resolveHeader(handle, block_number) catch |err| {
        setError(handle, "resolveHeader: {s}", .{@errorName(err)});
        return classifyReadError(err);
    };

    const code = light_proof.readCode(
        handle.allocator,
        proofSource(handle),
        header.state_root,
        address,
        header.block_tag_hex[0..header.block_tag_len],
    ) catch |err| {
        setError(handle, "readCode: {s}", .{@errorName(err)});
        return classifyReadError(err);
    };
    defer handle.allocator.free(code);

    const cap = cap_ptr.*;
    cap_ptr.* = code.len;
    if (cap < code.len) {
        setError(handle, "code buffer too small (needed {})", .{code.len});
        return ZEVM_ERR_BUFFER_TOO_SMALL;
    }
    if (code.len == 0) return ZEVM_OK;
    const dst = out_buf orelse return ZEVM_ERR_INVALID_ARG;
    @memcpy(dst[0..code.len], code);
    return ZEVM_OK;
}

export fn zevm_light_get_storage(
    opaque_ptr: ?*anyopaque,
    address_hex: ?[*:0]const u8,
    slot_hex: ?[*:0]const u8,
    block_number: u64,
    out_hex: ?[*]u8,
    out_len: ?*usize,
) callconv(.c) c_int {
    const handle = handleFromOpaque(opaque_ptr) orelse return ZEVM_ERR_INVALID_ARG;
    clearError(handle);

    const address = parseAddress(handle, address_hex) catch return ZEVM_ERR_INVALID_ARG;

    const slot_span = cstrSliceOrNull(slot_hex) orelse {
        setError(handle, "slot_hex is null", .{});
        return ZEVM_ERR_INVALID_ARG;
    };
    const slot = parseSlotHex(slot_span) catch |err| {
        setError(handle, "invalid slot hex: {s}", .{@errorName(err)});
        return ZEVM_ERR_INVALID_ARG;
    };

    const header = resolveHeader(handle, block_number) catch |err| {
        setError(handle, "resolveHeader: {s}", .{@errorName(err)});
        return classifyReadError(err);
    };

    const value = light_proof.readStorage(
        handle.allocator,
        proofSource(handle),
        header.state_root,
        address,
        slot,
        header.block_tag_hex[0..header.block_tag_len],
    ) catch |err| {
        setError(handle, "readStorage: {s}", .{@errorName(err)});
        return classifyReadError(err);
    };

    var scratch: [80]u8 = undefined;
    const text = writeStorageHex(value, &scratch) catch {
        setError(handle, "internal hex format", .{});
        return ZEVM_ERR_INTERNAL;
    };
    return copyToCStringBuffer(out_hex, out_len, text, handle);
}

fn parseSlotHex(text: []const u8) !u256 {
    var slice = text;
    if (slice.len >= 2 and (slice[0] == '0') and (slice[1] == 'x' or slice[1] == 'X')) {
        slice = slice[2..];
    }
    if (slice.len == 0 or slice.len > 64) return error.InvalidSlot;
    return std.fmt.parseInt(u256, slice, 16) catch return error.InvalidSlot;
}

test "parseSlotHex accepts 0x and bare hex" {
    try std.testing.expectEqual(@as(u256, 0x10), try parseSlotHex("0x10"));
    try std.testing.expectEqual(@as(u256, 0xff), try parseSlotHex("ff"));
    try std.testing.expectError(error.InvalidSlot, parseSlotHex(""));
    try std.testing.expectError(error.InvalidSlot, parseSlotHex("0x"));
}
