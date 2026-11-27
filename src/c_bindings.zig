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

// Embedded hosts own request logging and event delivery.
pub const std_options: std.Options = .{ .log_level = .err };
const primitives = @import("primitives");
const consensus_sync = @import("consensus_sync.zig");
const consensus_verifier = @import("consensus_verifier.zig");
const light_proof = @import("light_proof.zig");

// Must equal `.version` in build.zig.zon and npm/zevm/package.json; verify-release.cjs and npm-smoke enforce it.
const ZEVM_VERSION: [:0]const u8 = "0.1.0";
const ZEVM_ABI_VERSION: u32 = 1;

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
const ZEVM_NETWORK_HOODI: c_int = 3;

const CHECKPOINT_LEN: usize = 32;

const MAX_ERROR_LEN: usize = 512;

const Handle = struct {
    allocator: std.mem.Allocator,
    engine: consensus_sync.ConsensusSyncEngine,
    beacon_url: []u8,
    execution_url: []u8,
    /// Trusted beacon block root used for the initial bootstrap.
    startup_checkpoint: [CHECKPOINT_LEN]u8,
    startup_checkpoint_source: []const u8,
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
        ZEVM_NETWORK_HOODI => consensus_sync.NetworkConfig.hoodi(beacon_url),
        else => null,
    };
}

fn cstrSliceOrNull(ptr: ?[*:0]const u8) ?[:0]const u8 {
    const p = ptr orelse return null;
    return std.mem.span(p);
}

export fn zevm_abi_version() callconv(.c) u32 {
    return ZEVM_ABI_VERSION;
}

export fn zevm_version() callconv(.c) [*:0]const u8 {
    return ZEVM_VERSION.ptr;
}

export fn zevm_error_message(code: c_int) callconv(.c) [*:0]const u8 {
    const message: [:0]const u8 = switch (code) {
        ZEVM_OK => "ok",
        ZEVM_ERR_INVALID_ARG => "invalid argument",
        ZEVM_ERR_NOT_SYNCED => "light client is not synced",
        ZEVM_ERR_BUFFER_TOO_SMALL => "output buffer is too small",
        ZEVM_ERR_NETWORK => "network request failed",
        ZEVM_ERR_PROOF => "proof verification failed",
        ZEVM_ERR_BLOCK_UNAVAILABLE => "requested block is unavailable",
        ZEVM_ERR_INTERNAL => "internal error",
        else => "unknown zevm error",
    };
    return message.ptr;
}

export fn zevm_light_network_name(network: c_int) callconv(.c) ?[*:0]const u8 {
    const name: [:0]const u8 = switch (network) {
        ZEVM_NETWORK_MAINNET => "mainnet",
        ZEVM_NETWORK_SEPOLIA => "sepolia",
        ZEVM_NETWORK_HOLESKY => "holesky",
        ZEVM_NETWORK_HOODI => "hoodi",
        else => return null,
    };
    return name.ptr;
}

export fn zevm_light_init(
    network: c_int,
    beacon_rpc_url: ?[*:0]const u8,
    execution_rpc_url: ?[*:0]const u8,
) callconv(.c) ?*anyopaque {
    return zevm_light_init_ex(network, beacon_rpc_url, execution_rpc_url, null, 0);
}

export fn zevm_light_init_ex(
    network: c_int,
    beacon_rpc_url: ?[*:0]const u8,
    execution_rpc_url: ?[*:0]const u8,
    checkpoint: ?[*]const u8,
    strict_checkpoint_age: c_int,
) callconv(.c) ?*anyopaque {
    const beacon_span = cstrSliceOrNull(beacon_rpc_url) orelse return null;
    const execution_span = cstrSliceOrNull(execution_rpc_url) orelse return null;
    if (beacon_span.len == 0 or execution_span.len == 0) return null;
    // An all-zero root is never a real beacon block; treat it as a caller bug
    // instead of silently bootstrapping from (and failing against) it.
    if (checkpoint) |checkpoint_ptr| {
        if (std.mem.allEqual(u8, checkpoint_ptr[0..CHECKPOINT_LEN], 0)) return null;
    }

    const allocator = std.heap.c_allocator;

    const handle = allocator.create(Handle) catch return null;

    const beacon_copy = allocator.dupe(u8, beacon_span) catch {
        allocator.destroy(handle);
        return null;
    };

    const execution_copy = allocator.dupe(u8, execution_span) catch {
        allocator.free(beacon_copy);
        allocator.destroy(handle);
        return null;
    };

    var config = networkConfig(network, beacon_copy) orelse {
        allocator.free(beacon_copy);
        allocator.free(execution_copy);
        allocator.destroy(handle);
        return null;
    };
    config.strict_checkpoint_age = strict_checkpoint_age != 0;

    var startup_checkpoint = config.default_checkpoint;
    var startup_checkpoint_source: []const u8 = "c_bindings.default";
    if (checkpoint) |checkpoint_ptr| {
        @memcpy(startup_checkpoint[0..], checkpoint_ptr[0..CHECKPOINT_LEN]);
        startup_checkpoint_source = "c_bindings.custom";
    }

    handle.* = .{
        .allocator = allocator,
        .engine = consensus_sync.ConsensusSyncEngine.init(config),
        .beacon_url = beacon_copy,
        .execution_url = execution_copy,
        .startup_checkpoint = startup_checkpoint,
        .startup_checkpoint_source = startup_checkpoint_source,
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
        const ctx = consensus_sync.CheckpointStartupContext{ .source = handle.startup_checkpoint_source };
        handle.engine.sync(handle.allocator, handle.startup_checkpoint, ctx) catch |err| {
            setError(handle, "initial sync failed: {s}", .{@errorName(err)});
            return classifySyncError(err);
        };
        handle.initial_done = true;
        return ZEVM_OK;
    }

    handle.engine.advance(handle.allocator) catch |err| {
        setError(handle, "advance failed: {s} (consecutive failures {d}, last verified optimistic slot {d})", .{
            @errorName(err), handle.engine.consecutive_advance_failures, handle.engine.optimisticSlot(),
        });
        return classifySyncError(err);
    };
    return ZEVM_OK;
}

/// Maps a consensus sync failure to a ZEVM_* code. Proof and signature
/// failures mean the beacon node served data that does not verify; a stale or
/// unknown checkpoint is a caller argument problem; everything else that is
/// not an allocation failure is a transport or upstream failure.
fn classifySyncError(err: anyerror) c_int {
    if (isConsensusVerifierError(err)) return ZEVM_ERR_PROOF;
    return switch (err) {
        error.CheckpointRootMismatch,
        error.CheckpointSlotMismatch,
        error.ConsensusNetworkMismatch,
        error.ExtraDataTooLong,
        error.InvalidArrayLength,
        => ZEVM_ERR_PROOF,
        error.CheckpointTooOld,
        error.CheckpointTimeOverflow,
        => ZEVM_ERR_INVALID_ARG,
        error.OutOfMemory => ZEVM_ERR_INTERNAL,
        else => ZEVM_ERR_NETWORK,
    };
}

fn isConsensusVerifierError(err: anyerror) bool {
    const verifier_errors = @typeInfo(consensus_verifier.ConsensusVerifierError).error_set.?;
    inline for (verifier_errors) |verifier_error| {
        if (std.mem.eql(u8, @errorName(err), verifier_error.name)) return true;
    }
    return false;
}

export fn zevm_light_get_checkpoint(
    opaque_ptr: ?*anyopaque,
    out_checkpoint: ?[*]u8,
) callconv(.c) c_int {
    const handle = handleFromOpaque(opaque_ptr) orelse return ZEVM_ERR_INVALID_ARG;
    clearError(handle);

    const dst = out_checkpoint orelse {
        setError(handle, "out_checkpoint is null", .{});
        return ZEVM_ERR_INVALID_ARG;
    };
    if (handle.engine.status != .synced) {
        setError(handle, "light client is not synced", .{});
        return ZEVM_ERR_NOT_SYNCED;
    }
    const checkpoint = handle.engine.lastCheckpoint() orelse {
        setError(handle, "no verified checkpoint yet", .{});
        return ZEVM_ERR_NOT_SYNCED;
    };
    @memcpy(dst[0..CHECKPOINT_LEN], checkpoint[0..]);
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
    const cap_ptr = out_len orelse {
        setError(handle, "out_len is null", .{});
        return ZEVM_ERR_INVALID_ARG;
    };
    const cap = cap_ptr.*;
    const required = source.len + 1;
    cap_ptr.* = required;
    if (cap < required) {
        setError(handle, "output buffer too small (needed {})", .{required});
        return ZEVM_ERR_BUFFER_TOO_SMALL;
    }
    const dst = out_hex orelse {
        setError(handle, "out_hex is null", .{});
        return ZEVM_ERR_INVALID_ARG;
    };
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
        error.UpstreamRpcFailed,
        error.UpstreamTimeout,
        error.InvalidUpstreamRpcResponse,
        error.ProofResponseTooLarge,
        => ZEVM_ERR_NETWORK,
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

    if (out_len == null) {
        setError(handle, "out_len is null", .{});
        return ZEVM_ERR_INVALID_ARG;
    }
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

export fn zevm_light_get_transaction_count(
    opaque_ptr: ?*anyopaque,
    address_hex: ?[*:0]const u8,
    block_number: u64,
    out_count: ?*u64,
) callconv(.c) c_int {
    const handle = handleFromOpaque(opaque_ptr) orelse return ZEVM_ERR_INVALID_ARG;
    clearError(handle);

    const count_ptr = out_count orelse {
        setError(handle, "out_count is null", .{});
        return ZEVM_ERR_INVALID_ARG;
    };
    const address = parseAddress(handle, address_hex) catch return ZEVM_ERR_INVALID_ARG;

    const header = resolveHeader(handle, block_number) catch |err| {
        setError(handle, "resolveHeader: {s}", .{@errorName(err)});
        return classifyReadError(err);
    };

    count_ptr.* = light_proof.readTransactionCount(
        handle.allocator,
        proofSource(handle),
        header.state_root,
        address,
        header.block_tag_hex[0..header.block_tag_len],
    ) catch |err| {
        setError(handle, "readTransactionCount: {s}", .{@errorName(err)});
        return classifyReadError(err);
    };

    return ZEVM_OK;
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

    const cap_ptr = out_len orelse {
        setError(handle, "out_len is null", .{});
        return ZEVM_ERR_INVALID_ARG;
    };
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
    const dst = out_buf orelse {
        setError(handle, "out_buf is null", .{});
        return ZEVM_ERR_INVALID_ARG;
    };
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

    if (out_len == null) {
        setError(handle, "out_len is null", .{});
        return ZEVM_ERR_INVALID_ARG;
    }
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

test "classifySyncError separates proof, argument, transport, and internal failures" {
    try std.testing.expectEqual(ZEVM_ERR_PROOF, classifySyncError(error.InvalidSignature));
    try std.testing.expectEqual(ZEVM_ERR_PROOF, classifySyncError(error.InvalidFinalityProof));
    try std.testing.expectEqual(ZEVM_ERR_PROOF, classifySyncError(error.CheckpointSlotMismatch));
    try std.testing.expectEqual(ZEVM_ERR_INVALID_ARG, classifySyncError(error.CheckpointTooOld));
    try std.testing.expectEqual(ZEVM_ERR_NETWORK, classifySyncError(error.ConnectionRefused));
    try std.testing.expectEqual(ZEVM_ERR_NETWORK, classifySyncError(error.UnexpectedHttpStatus));
    try std.testing.expectEqual(ZEVM_ERR_NETWORK, classifySyncError(error.UpstreamTimeout));
    try std.testing.expectEqual(ZEVM_ERR_INTERNAL, classifyReadError(error.OutOfMemory));
    try std.testing.expectEqual(ZEVM_ERR_NETWORK, classifyReadError(error.UpstreamTimeout));
    try std.testing.expectEqual(ZEVM_ERR_INTERNAL, classifySyncError(error.OutOfMemory));
}

test "failed advances report staleness and preserve synced status and checkpoint access" {
    const ptr = zevm_light_init(ZEVM_NETWORK_MAINNET, "invalid://beacon", "invalid://execution") orelse return error.TestUnexpectedResult;
    defer zevm_light_shutdown(ptr);
    const handle = handleFromOpaque(ptr).?;
    handle.initial_done = true;
    handle.engine.has_verified_store = true;
    handle.engine.status = .synced;
    handle.engine.last_checkpoint = [_]u8{0xa5} ** CHECKPOINT_LEN;
    handle.engine.store.optimistic_header.beacon.slot = 123;

    for (0..2) |_| try std.testing.expectEqual(ZEVM_ERR_NETWORK, zevm_light_sync_step(ptr));
    try std.testing.expectEqual(ZEVM_STATUS_SYNCED, zevm_light_status(ptr));
    const detail = std.mem.span(zevm_light_last_error(ptr).?);
    try std.testing.expect(std.mem.indexOf(u8, detail, "consecutive failures 2, last verified optimistic slot 123") != null);
    var checkpoint: [CHECKPOINT_LEN]u8 = undefined;
    try std.testing.expectEqual(ZEVM_OK, zevm_light_get_checkpoint(ptr, &checkpoint));
    try std.testing.expectEqual(handle.engine.last_checkpoint.?, checkpoint);
}

test "zevm_light_init rejects empty URLs and accepts hoodi" {
    try std.testing.expect(zevm_light_init(ZEVM_NETWORK_MAINNET, "", "http://127.0.0.1:1") == null);
    try std.testing.expect(zevm_light_init(ZEVM_NETWORK_MAINNET, "http://127.0.0.1:1", "") == null);
    try std.testing.expect(zevm_light_init(99, "http://127.0.0.1:1", "http://127.0.0.1:1") == null);

    const handle = zevm_light_init(ZEVM_NETWORK_HOODI, "http://127.0.0.1:1", "http://127.0.0.1:1") orelse
        return error.TestUnexpectedResult;
    defer zevm_light_shutdown(handle);
    try std.testing.expectEqualStrings("hoodi", std.mem.span(zevm_light_network_name(ZEVM_NETWORK_HOODI).?));
}

test "zevm_light_init_ex stores the custom checkpoint and strict age flag" {
    const custom = [_]u8{0x7c} ** CHECKPOINT_LEN;
    const opaque_handle = zevm_light_init_ex(ZEVM_NETWORK_SEPOLIA, "http://127.0.0.1:1", "http://127.0.0.1:1", &custom, 1) orelse
        return error.TestUnexpectedResult;
    defer zevm_light_shutdown(opaque_handle);

    const handle = handleFromOpaque(opaque_handle).?;
    try std.testing.expectEqualSlices(u8, custom[0..], handle.startup_checkpoint[0..]);
    try std.testing.expect(handle.engine.config.strict_checkpoint_age);

    var out: [CHECKPOINT_LEN]u8 = undefined;
    try std.testing.expectEqual(ZEVM_ERR_NOT_SYNCED, zevm_light_get_checkpoint(opaque_handle, &out));
    try std.testing.expectEqual(ZEVM_ERR_INVALID_ARG, zevm_light_get_checkpoint(opaque_handle, null));
}

test "reads reject a null out_len before any network I/O" {
    const opaque_handle = zevm_light_init(ZEVM_NETWORK_MAINNET, "http://127.0.0.1:1", "http://127.0.0.1:1") orelse
        return error.TestUnexpectedResult;
    defer zevm_light_shutdown(opaque_handle);
    const address = "0x0000000000000000000000000000000000000001";

    // The handle is not synced, so a missing out_len check would surface as
    // ZEVM_ERR_NOT_SYNCED rather than ZEVM_ERR_INVALID_ARG.
    try std.testing.expectEqual(ZEVM_ERR_INVALID_ARG, zevm_light_get_balance(opaque_handle, address, 0, null, null));
    try std.testing.expectEqual(ZEVM_ERR_INVALID_ARG, zevm_light_get_storage(opaque_handle, address, "0x0", 0, null, null));
    try std.testing.expectEqual(ZEVM_ERR_INVALID_ARG, zevm_light_get_code(opaque_handle, address, 0, null, null));
    try std.testing.expectEqualStrings("out_len is null", std.mem.span(zevm_light_last_error(opaque_handle).?));
}

test "zevm_light_init_ex rejects an all-zero custom checkpoint" {
    const zero = [_]u8{0} ** CHECKPOINT_LEN;
    try std.testing.expect(zevm_light_init_ex(ZEVM_NETWORK_MAINNET, "http://127.0.0.1:1", "http://127.0.0.1:1", &zero, 0) == null);

    var one_set = zero;
    one_set[CHECKPOINT_LEN - 1] = 1;
    const opaque_handle = zevm_light_init_ex(ZEVM_NETWORK_MAINNET, "http://127.0.0.1:1", "http://127.0.0.1:1", &one_set, 0) orelse
        return error.TestUnexpectedResult;
    zevm_light_shutdown(opaque_handle);
}

test "null output buffers set the last error" {
    const opaque_handle = zevm_light_init(ZEVM_NETWORK_MAINNET, "http://127.0.0.1:1", "http://127.0.0.1:1") orelse
        return error.TestUnexpectedResult;
    defer zevm_light_shutdown(opaque_handle);
    const handle = handleFromOpaque(opaque_handle).?;

    var cap: usize = 16;
    try std.testing.expectEqual(ZEVM_ERR_INVALID_ARG, copyToCStringBuffer(null, &cap, "0x1", handle));
    try std.testing.expectEqualStrings("out_hex is null", std.mem.span(zevm_light_last_error(opaque_handle).?));

    clearError(handle);
    try std.testing.expectEqual(ZEVM_ERR_INVALID_ARG, copyToCStringBuffer(null, null, "0x1", handle));
    try std.testing.expectEqualStrings("out_len is null", std.mem.span(zevm_light_last_error(opaque_handle).?));
}

test "parseSlotHex accepts 0x and bare hex" {
    try std.testing.expectEqual(@as(u256, 0x10), try parseSlotHex("0x10"));
    try std.testing.expectEqual(@as(u256, 0xff), try parseSlotHex("ff"));
    try std.testing.expectError(error.InvalidSlot, parseSlotHex(""));
    try std.testing.expectError(error.InvalidSlot, parseSlotHex("0x"));
}

comptime {
    _ = @import("embedded_node.zig");
}
