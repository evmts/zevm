const std = @import("std");
const builtin = @import("builtin");
const primitives = @import("primitives");
const log = @import("log.zig");

const MAX_EXTRA_DATA_BYTES: usize = 32;

/// Upper bound on a single beacon API response body. The largest light-client
/// response, a 128-period `/updates` page, is roughly 3.5 MiB of JSON.
pub const MAX_BEACON_RESPONSE_BYTES: usize = 16 * 1024 * 1024;

/// Consensus-spec `MAX_REQUEST_LIGHT_CLIENT_UPDATES`. A `/updates` response
/// carrying more entries is rejected before any per-update allocation.
pub const MAX_LIGHT_CLIENT_UPDATES: usize = 128;

/// Interrupts the actual socket even when HTTP framing, TLS, or decompression
/// performs several reads internally before returning to the caller.
pub const UpstreamDeadline = struct {
    done: std.Thread.ResetEvent,
    watchdog: std.Thread,
    timer: std.time.Timer,
    budget_ns: u64,

    pub fn start(self: *UpstreamDeadline, connection: *std.http.Client.Connection) !void {
        try self.startWithTimeouts(connection, 15 * std.time.ms_per_s, 30 * std.time.ns_per_s);
    }

    fn startWithTimeouts(
        self: *UpstreamDeadline,
        connection: *std.http.Client.Connection,
        idle_ms: u32,
        budget_ns: u64,
    ) !void {
        const socket = connection.stream_reader.getStream().handle;
        const timeout = if (builtin.os.tag == .windows) idle_ms else std.posix.timeval{
            .sec = @intCast(idle_ms / std.time.ms_per_s),
            .usec = @intCast((idle_ms % std.time.ms_per_s) * std.time.us_per_ms),
        };
        try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));
        try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout));
        self.* = .{ .done = .{}, .watchdog = undefined, .timer = try std.time.Timer.start(), .budget_ns = budget_ns };
        self.watchdog = try std.Thread.spawn(.{}, interruptAtDeadline, .{ &self.done, socket, self.timer, budget_ns });
    }

    fn interruptAtDeadline(
        done: *std.Thread.ResetEvent,
        socket: std.net.Stream.Handle,
        started: std.time.Timer,
        budget_ns: u64,
    ) void {
        var timer = started;
        done.timedWait(budget_ns -| timer.read()) catch {
            std.posix.shutdown(socket, .both) catch |err| switch (err) {
                error.SocketNotConnected => {},
                else => log.debug(.consensus_sync, "deadline_socket_shutdown_failed error={s}", .{@errorName(err)}),
            };
        };
    }

    pub fn stop(self: *UpstreamDeadline) void {
        self.done.set();
        self.watchdog.join();
    }

    pub fn check(self: *UpstreamDeadline, connection: *const std.http.Client.Connection) error{UpstreamTimeout}!void {
        if (self.timer.read() >= self.budget_ns or
            isTimeout(connection.stream_reader.getError()) or isTimeout(connection.stream_writer.err))
        {
            return error.UpstreamTimeout;
        }
    }

    fn isTimeout(err: ?anyerror) bool {
        const e = err orelse return false;
        return e == error.WouldBlock or e == error.ConnectionTimedOut or e == error.Timeout;
    }
};
pub const GenesisInfo = struct {
    genesis_time: u64,
    genesis_validators_root: [32]u8,
};

pub const BeaconHeaderInfo = struct {
    root: [32]u8,
    slot: u64,
};

pub const BeaconApi = struct {
    endpoint_url: []const u8,

    pub fn getGenesis(
        self: BeaconApi,
        allocator: std.mem.Allocator,
    ) !GenesisInfo {
        const url = try self.buildGenesisUrl(allocator);
        defer allocator.free(url);

        const response = try self.httpGet(allocator, url);
        defer allocator.free(response.body);

        return try parseGenesisResponse(allocator, response.body);
    }

    pub fn getHeader(
        self: BeaconApi,
        allocator: std.mem.Allocator,
        block_root: [32]u8,
    ) !BeaconHeaderInfo {
        const url = try self.buildHeaderUrl(allocator, block_root);
        defer allocator.free(url);

        const response = try self.httpGet(allocator, url);
        defer allocator.free(response.body);

        return try parseHeaderResponse(allocator, response.body);
    }

    pub fn getBootstrap(
        self: BeaconApi,
        allocator: std.mem.Allocator,
        checkpoint: [32]u8,
    ) !primitives.LightClientUpdate.LightClientBootstrap {
        const url = try self.buildBootstrapUrl(allocator, checkpoint);
        defer allocator.free(url);

        const response = try self.httpGet(allocator, url);
        defer allocator.free(response.body);

        return try parseBootstrapResponseWithFork(allocator, response.body, response.fork);
    }

    pub fn getUpdates(
        self: BeaconApi,
        allocator: std.mem.Allocator,
        start_period: u64,
        count: u8,
    ) ![]primitives.LightClientUpdate.LightClientUpdate {
        const url = try self.buildUpdatesUrl(allocator, start_period, count);
        defer allocator.free(url);

        const response = try self.httpGet(allocator, url);
        defer allocator.free(response.body);

        return try parseUpdatesResponseWithFork(allocator, response.body, response.fork);
    }

    pub fn getFinalityUpdate(
        self: BeaconApi,
        allocator: std.mem.Allocator,
    ) !primitives.LightClientUpdate.LightClientFinalityUpdate {
        const url = try self.buildFinalityUpdateUrl(allocator);
        defer allocator.free(url);

        const response = try self.httpGet(allocator, url);
        defer allocator.free(response.body);

        return try parseFinalityUpdateResponseWithFork(allocator, response.body, response.fork);
    }

    pub fn getOptimisticUpdate(
        self: BeaconApi,
        allocator: std.mem.Allocator,
    ) !primitives.LightClientUpdate.LightClientOptimisticUpdate {
        const url = try self.buildOptimisticUpdateUrl(allocator);
        defer allocator.free(url);

        const response = try self.httpGet(allocator, url);
        defer allocator.free(response.body);

        return try parseOptimisticUpdateResponseWithFork(allocator, response.body, response.fork);
    }

    pub fn buildBootstrapUrl(
        self: BeaconApi,
        allocator: std.mem.Allocator,
        checkpoint: [32]u8,
    ) ![]u8 {
        const endpoint = endpointWithoutTrailingSlash(self.endpoint_url);
        if (endpoint.len == 0) {
            return error.InvalidEndpointUrl;
        }

        const checkpoint_hex = bytesToHex(32, checkpoint);
        return try std.fmt.allocPrint(
            allocator,
            "{s}/eth/v1/beacon/light_client/bootstrap/{s}",
            .{ endpoint, checkpoint_hex[0..] },
        );
    }

    pub fn buildGenesisUrl(
        self: BeaconApi,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        const endpoint = endpointWithoutTrailingSlash(self.endpoint_url);
        if (endpoint.len == 0) {
            return error.InvalidEndpointUrl;
        }

        return try std.fmt.allocPrint(
            allocator,
            "{s}/eth/v1/beacon/genesis",
            .{endpoint},
        );
    }

    pub fn buildHeaderUrl(
        self: BeaconApi,
        allocator: std.mem.Allocator,
        block_root: [32]u8,
    ) ![]u8 {
        const endpoint = endpointWithoutTrailingSlash(self.endpoint_url);
        if (endpoint.len == 0) {
            return error.InvalidEndpointUrl;
        }

        const root_hex = bytesToHex(32, block_root);
        return try std.fmt.allocPrint(
            allocator,
            "{s}/eth/v1/beacon/headers/{s}",
            .{ endpoint, root_hex[0..] },
        );
    }

    pub fn buildUpdatesUrl(
        self: BeaconApi,
        allocator: std.mem.Allocator,
        start_period: u64,
        count: u8,
    ) ![]u8 {
        const endpoint = endpointWithoutTrailingSlash(self.endpoint_url);
        if (endpoint.len == 0) {
            return error.InvalidEndpointUrl;
        }

        return try std.fmt.allocPrint(
            allocator,
            "{s}/eth/v1/beacon/light_client/updates?start_period={d}&count={d}",
            .{ endpoint, start_period, count },
        );
    }

    pub fn buildFinalityUpdateUrl(
        self: BeaconApi,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        const endpoint = endpointWithoutTrailingSlash(self.endpoint_url);
        if (endpoint.len == 0) {
            return error.InvalidEndpointUrl;
        }

        return try std.fmt.allocPrint(
            allocator,
            "{s}/eth/v1/beacon/light_client/finality_update",
            .{endpoint},
        );
    }

    pub fn buildOptimisticUpdateUrl(
        self: BeaconApi,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        const endpoint = endpointWithoutTrailingSlash(self.endpoint_url);
        if (endpoint.len == 0) {
            return error.InvalidEndpointUrl;
        }

        return try std.fmt.allocPrint(
            allocator,
            "{s}/eth/v1/beacon/light_client/optimistic_update",
            .{endpoint},
        );
    }

    const HttpResponse = struct {
        body: []u8,
        fork: ?primitives.LightClientHeader.Fork,
    };

    fn httpGet(
        self: BeaconApi,
        allocator: std.mem.Allocator,
        url: []const u8,
    ) !HttpResponse {
        _ = self;

        var client: std.http.Client = .{ .allocator = allocator };
        defer client.deinit();

        const uri = try std.Uri.parse(url);
        var request = client.request(.GET, uri, .{ .redirect_behavior = .unhandled, .keep_alive = false }) catch |err| {
            if (err == error.ConnectionTimedOut) return error.UpstreamTimeout;
            return err;
        };
        defer {
            // This client serves one request. Close without draining an
            // incomplete response after the watchdog has been joined.
            request.connection.?.closing = true;
            request.deinit();
        }

        var deadline: UpstreamDeadline = undefined;
        const connection = request.connection.?;
        try deadline.start(connection);
        defer deadline.stop();
        const response = receiveBeaconResponse(allocator, &request) catch |err| {
            try deadline.check(connection);
            return err;
        };
        errdefer allocator.free(response.body);
        try deadline.check(connection);
        return response;
    }

    fn receiveBeaconResponse(allocator: std.mem.Allocator, request: *std.http.Client.Request) !HttpResponse {
        try request.sendBodiless();

        var redirect_buffer: [8 * 1024]u8 = undefined;
        var response = try request.receiveHead(redirect_buffer[0..]);
        if (response.head.status != .ok) {
            return error.UnexpectedHttpStatus;
        }

        const fork = try consensusForkFromHeaders(response.head);

        if (response.head.content_length) |content_length| {
            if (content_length > MAX_BEACON_RESPONSE_BYTES) return error.BeaconResponseTooLarge;
        }

        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .zstd => try allocator.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try allocator.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };
        defer if (response.head.content_encoding != .identity) allocator.free(decompress_buffer);

        var transfer_buffer: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

        const body = readLimitedBody(allocator, reader, MAX_BEACON_RESPONSE_BYTES) catch |err| switch (err) {
            error.ReadFailed => return resolveBodyReadError(response.bodyErr()),
            else => return err,
        };

        return .{
            .body = body,
            .fork = fork,
        };
    }
};

/// Maps a `ReadFailed` body read error using `response.bodyErr()` queried
/// *after* the read failed. Decompression failures leave `body_err == null`.
fn resolveBodyReadError(
    body_err: ?std.http.Reader.BodyError,
) (std.http.Reader.BodyError || error{InvalidCompressedResponse}) {
    return body_err orelse error.InvalidCompressedResponse;
}

/// Reads the whole (possibly decompressed) response body, accepting at most
/// `max_bytes`. Callers query `response.bodyErr()` only after `ReadFailed`.
fn readLimitedBody(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    max_bytes: usize,
) ![]u8 {
    // `allocRemaining` fails when the limit is reached, so allow one extra
    // byte to accept a body of exactly `max_bytes`.
    const body = reader.allocRemaining(allocator, .limited(max_bytes + 1)) catch |err| switch (err) {
        error.ReadFailed => return error.ReadFailed,
        error.StreamTooLong => return error.BeaconResponseTooLarge,
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (body.len > max_bytes) {
        allocator.free(body);
        return error.BeaconResponseTooLarge;
    }
    return body;
}

fn consensusForkFromHeaders(head: std.http.Client.Response.Head) !?primitives.LightClientHeader.Fork {
    var headers = head.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "eth-consensus-version") or
            std.ascii.eqlIgnoreCase(header.name, "consensus_version"))
        {
            return try parseFork(header.value);
        }
    }
    return null;
}

/// Maps an explicit consensus fork name to its light-client wire layout.
/// Unknown names fail with `error.UnsupportedConsensusFork`: guessing a layout
/// would parse proofs with the wrong branch depth.
pub fn parseFork(name: []const u8) error{UnsupportedConsensusFork}!primitives.LightClientHeader.Fork {
    if (std.ascii.eqlIgnoreCase(name, "bellatrix")) return .bellatrix;
    if (std.ascii.eqlIgnoreCase(name, "capella")) return .capella;
    if (std.ascii.eqlIgnoreCase(name, "deneb")) return .deneb;
    // Fulu preserves Electra's 6-element post-Electra light-client branch depth.
    if (std.ascii.eqlIgnoreCase(name, "electra") or std.ascii.eqlIgnoreCase(name, "fulu")) return .electra;
    return error.UnsupportedConsensusFork;
}

const VersionedJson = struct {
    data: std.json.Value,
    fork: ?primitives.LightClientHeader.Fork,
};

fn getVersionedData(value: std.json.Value, hint_fork: ?primitives.LightClientHeader.Fork) !VersionedJson {
    var fork = hint_fork;
    if (value == .object) {
        if (value.object.get("version")) |v| {
            if (v == .string) {
                fork = try parseFork(v.string);
            }
        }
        if (value.object.get("data")) |data| {
            return .{ .data = data, .fork = fork };
        }
    }
    return .{ .data = value, .fork = fork };
}

fn defaultFork(fork: ?primitives.LightClientHeader.Fork) primitives.LightClientHeader.Fork {
    return fork orelse .deneb;
}

fn getVersionedArray(value: std.json.Value, hint_fork: ?primitives.LightClientHeader.Fork) !VersionedJson {
    return getVersionedData(value, hint_fork);
}

pub fn parseBootstrapResponse(
    allocator: std.mem.Allocator,
    json_response: []const u8,
) !primitives.LightClientUpdate.LightClientBootstrap {
    return parseBootstrapResponseWithFork(allocator, json_response, null);
}

pub fn parseGenesisResponse(
    allocator: std.mem.Allocator,
    json_response: []const u8,
) !GenesisInfo {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_response, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const data = try getDataField(parsed.value);
    return .{
        .genesis_time = try parseU64(try getStringField(data, "genesis_time")),
        .genesis_validators_root = try hexToBytes(32, try getStringField(data, "genesis_validators_root")),
    };
}

pub fn parseHeaderResponse(
    allocator: std.mem.Allocator,
    json_response: []const u8,
) !BeaconHeaderInfo {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_response, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const data = try getDataField(parsed.value);
    const header = try getObjectField(data, "header");
    const message = try getObjectField(header, "message");
    return .{
        .root = try hexToBytes(32, try getStringField(data, "root")),
        .slot = try parseU64(try getStringField(message, "slot")),
    };
}

pub fn parseBootstrapResponseWithFork(
    allocator: std.mem.Allocator,
    json_response: []const u8,
    consensus_fork: ?primitives.LightClientHeader.Fork,
) !primitives.LightClientUpdate.LightClientBootstrap {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_response, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const response = try getVersionedData(parsed.value, consensus_fork);
    return try parseBootstrap(response.data, defaultFork(response.fork));
}

pub fn parseUpdatesResponse(
    allocator: std.mem.Allocator,
    json_response: []const u8,
) ![]primitives.LightClientUpdate.LightClientUpdate {
    return parseUpdatesResponseWithFork(allocator, json_response, null);
}

pub fn parseUpdatesResponseWithFork(
    allocator: std.mem.Allocator,
    json_response: []const u8,
    consensus_fork: ?primitives.LightClientHeader.Fork,
) ![]primitives.LightClientUpdate.LightClientUpdate {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_response, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const response = try getVersionedArray(parsed.value, consensus_fork);
    const items = try expectArray(response.data);
    if (items.len > MAX_LIGHT_CLIENT_UPDATES) return error.TooManyLightClientUpdates;
    const updates = try allocator.alloc(primitives.LightClientUpdate.LightClientUpdate, items.len);
    errdefer allocator.free(updates);

    for (items, 0..) |item, index| {
        const item_response = try getVersionedData(item, response.fork);
        updates[index] = try parseUpdate(item_response.data, defaultFork(item_response.fork));
    }

    return updates;
}

pub fn parseFinalityUpdateResponse(
    allocator: std.mem.Allocator,
    json_response: []const u8,
) !primitives.LightClientUpdate.LightClientFinalityUpdate {
    return parseFinalityUpdateResponseWithFork(allocator, json_response, null);
}

pub fn parseFinalityUpdateResponseWithFork(
    allocator: std.mem.Allocator,
    json_response: []const u8,
    consensus_fork: ?primitives.LightClientHeader.Fork,
) !primitives.LightClientUpdate.LightClientFinalityUpdate {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_response, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const response = try getVersionedData(parsed.value, consensus_fork);
    return try parseFinalityUpdate(response.data, defaultFork(response.fork));
}

pub fn parseOptimisticUpdateResponse(
    allocator: std.mem.Allocator,
    json_response: []const u8,
) !primitives.LightClientUpdate.LightClientOptimisticUpdate {
    return parseOptimisticUpdateResponseWithFork(allocator, json_response, null);
}

pub fn parseOptimisticUpdateResponseWithFork(
    allocator: std.mem.Allocator,
    json_response: []const u8,
    consensus_fork: ?primitives.LightClientHeader.Fork,
) !primitives.LightClientUpdate.LightClientOptimisticUpdate {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_response, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const response = try getVersionedData(parsed.value, consensus_fork);
    return try parseOptimisticUpdate(response.data, defaultFork(response.fork));
}

pub fn hexToBytes(comptime N: usize, input: []const u8) ![N]u8 {
    if (!std.mem.startsWith(u8, input, "0x")) {
        return error.InvalidHexPrefix;
    }

    const raw = input[2..];
    if (raw.len != N * 2) {
        return error.InvalidHexLength;
    }

    var out: [N]u8 = undefined;
    _ = std.fmt.hexToBytes(out[0..], raw) catch {
        return error.InvalidHexValue;
    };
    return out;
}

fn hexBytesMax(comptime N: usize, input: []const u8) ![N]u8 {
    if (!std.mem.startsWith(u8, input, "0x")) {
        return error.InvalidHexPrefix;
    }

    const raw = input[2..];
    if (raw.len > N * 2 or raw.len % 2 != 0) {
        return error.InvalidHexLength;
    }

    var out = [_]u8{0} ** N;
    _ = std.fmt.hexToBytes(out[0 .. raw.len / 2], raw) catch {
        return error.InvalidHexValue;
    };
    return out;
}

pub fn parseU64(input: []const u8) !u64 {
    return std.fmt.parseInt(u64, input, 10) catch {
        return error.InvalidDecimalValue;
    };
}

pub fn parseU256(input: []const u8) !u256 {
    return std.fmt.parseInt(u256, input, 10) catch {
        return error.InvalidDecimalValue;
    };
}

pub fn bytesToHex(comptime N: usize, bytes: [N]u8) [2 + (N * 2)]u8 {
    var out: [2 + (N * 2)]u8 = undefined;
    out[0] = '0';
    out[1] = 'x';

    const encoded = std.fmt.bytesToHex(bytes, .lower);
    @memcpy(out[2..], encoded[0..]);
    return out;
}

fn endpointWithoutTrailingSlash(endpoint: []const u8) []const u8 {
    var end = endpoint.len;
    while (end > 0 and endpoint[end - 1] == '/') : (end -= 1) {}
    return endpoint[0..end];
}

fn getDataField(value: std.json.Value) !std.json.Value {
    return try getObjectField(value, "data");
}

fn getObjectField(value: std.json.Value, key: []const u8) !std.json.Value {
    return switch (value) {
        .object => |object| object.get(key) orelse error.MissingJsonField,
        else => error.InvalidJsonType,
    };
}

fn getStringField(value: std.json.Value, key: []const u8) ![]const u8 {
    return try expectString(try getObjectField(value, key));
}

fn getOptionalStringField(value: std.json.Value, key: []const u8) !?[]const u8 {
    return switch (value) {
        .object => |object| if (object.get(key)) |field| try expectString(field) else null,
        else => error.InvalidJsonType,
    };
}

fn expectString(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |string| string,
        else => error.InvalidJsonType,
    };
}

fn expectArray(value: std.json.Value) ![]const std.json.Value {
    return switch (value) {
        .array => |array| array.items,
        else => error.InvalidJsonType,
    };
}

fn parseBootstrap(
    value: std.json.Value,
    fork: primitives.LightClientHeader.Fork,
) !primitives.LightClientUpdate.LightClientBootstrap {
    const current_sync_committee = try getObjectField(value, "current_sync_committee");

    var branch_buffer: [6][32]u8 = undefined;
    const current_sync_committee_branch = try parseBranchSlice(
        branch_buffer[0..],
        syncCommitteeBranchLen(fork),
        try getObjectField(value, "current_sync_committee_branch"),
    );

    return primitives.LightClientUpdate.LightClientBootstrap.fromBranch(
        try parseLightClientHeader(try getObjectField(value, "header"), fork),
        try parseSyncCommitteePubkeys(try getObjectField(current_sync_committee, "pubkeys")),
        try hexToBytes(48, try getStringField(current_sync_committee, "aggregate_pubkey")),
        current_sync_committee_branch,
    );
}

fn parseUpdate(
    value: std.json.Value,
    fork: primitives.LightClientHeader.Fork,
) !primitives.LightClientUpdate.LightClientUpdate {
    const sync_aggregate = try parseSyncAggregate(try getObjectField(value, "sync_aggregate"));
    const next_sync_committee = try getObjectField(value, "next_sync_committee");

    var next_branch_buffer: [6][32]u8 = undefined;
    const next_sync_committee_branch = try parseBranchSlice(
        next_branch_buffer[0..],
        syncCommitteeBranchLen(fork),
        try getObjectField(value, "next_sync_committee_branch"),
    );

    var finality_branch_buffer: [7][32]u8 = undefined;
    const finality_branch = try parseBranchSlice(
        finality_branch_buffer[0..],
        finalityBranchLen(fork),
        try getObjectField(value, "finality_branch"),
    );

    return primitives.LightClientUpdate.LightClientUpdate.fromBranches(
        try parseLightClientHeader(try getObjectField(value, "attested_header"), fork),
        try parseSyncCommitteePubkeys(try getObjectField(next_sync_committee, "pubkeys")),
        try hexToBytes(48, try getStringField(next_sync_committee, "aggregate_pubkey")),
        next_sync_committee_branch,
        try parseLightClientHeader(try getObjectField(value, "finalized_header"), fork),
        finality_branch,
        sync_aggregate.sync_committee_bits,
        sync_aggregate.sync_committee_signature,
        try parseU64(try getStringField(value, "signature_slot")),
    );
}

fn parseFinalityUpdate(
    value: std.json.Value,
    fork: primitives.LightClientHeader.Fork,
) !primitives.LightClientUpdate.LightClientFinalityUpdate {
    const sync_aggregate = try parseSyncAggregate(try getObjectField(value, "sync_aggregate"));

    var finality_branch_buffer: [7][32]u8 = undefined;
    const finality_branch = try parseBranchSlice(
        finality_branch_buffer[0..],
        finalityBranchLen(fork),
        try getObjectField(value, "finality_branch"),
    );

    return primitives.LightClientUpdate.LightClientFinalityUpdate.fromBranch(
        try parseLightClientHeader(try getObjectField(value, "attested_header"), fork),
        try parseLightClientHeader(try getObjectField(value, "finalized_header"), fork),
        finality_branch,
        sync_aggregate.sync_committee_bits,
        sync_aggregate.sync_committee_signature,
        try parseU64(try getStringField(value, "signature_slot")),
    );
}

fn parseOptimisticUpdate(
    value: std.json.Value,
    fork: primitives.LightClientHeader.Fork,
) !primitives.LightClientUpdate.LightClientOptimisticUpdate {
    const sync_aggregate = try parseSyncAggregate(try getObjectField(value, "sync_aggregate"));

    return primitives.LightClientUpdate.LightClientOptimisticUpdate.from(
        try parseLightClientHeader(try getObjectField(value, "attested_header"), fork),
        sync_aggregate.sync_committee_bits,
        sync_aggregate.sync_committee_signature,
        try parseU64(try getStringField(value, "signature_slot")),
    );
}

fn parseLightClientHeader(
    value: std.json.Value,
    fork: primitives.LightClientHeader.Fork,
) !primitives.LightClientHeader.LightClientHeader {
    return primitives.LightClientHeader.LightClientHeader.fromWithFork(
        fork,
        try parseBeaconHeader(try getObjectField(value, "beacon")),
        try parseExecutionHeader(try getObjectField(value, "execution"), fork),
        try parseBranch(4, try getObjectField(value, "execution_branch")),
    );
}

fn parseBeaconHeader(value: std.json.Value) !primitives.LightClientHeader.LightClientHeader.BeaconBlockHeader {
    return primitives.LightClientHeader.LightClientHeader.BeaconBlockHeader.from(
        try parseU64(try getStringField(value, "slot")),
        try parseU64(try getStringField(value, "proposer_index")),
        try hexToBytes(32, try getStringField(value, "parent_root")),
        try hexToBytes(32, try getStringField(value, "state_root")),
        try hexToBytes(32, try getStringField(value, "body_root")),
    );
}

fn parseExecutionHeader(
    value: std.json.Value,
    fork: primitives.LightClientHeader.Fork,
) !primitives.LightClientHeader.LightClientHeader.ExecutionPayloadHeaderFields {
    const extra_data = if (try getOptionalStringField(value, "extra_data")) |bytes_hex|
        try hexBytesMax(32, bytes_hex)
    else
        [_]u8{0} ** 32;
    const extra_data_len: usize = if (try getOptionalStringField(value, "extra_data")) |bytes_hex|
        (bytes_hex.len - 2) / 2
    else
        0;
    const withdrawals_root = if (fork.hasWithdrawalsRoot())
        try hexToBytes(32, try getStringField(value, "withdrawals_root"))
    else if (try getOptionalStringField(value, "withdrawals_root")) |withdrawals|
        try hexToBytes(32, withdrawals)
    else
        [_]u8{0} ** 32;
    const blob_gas_used = if (fork.hasBlobGasFields())
        try parseU64(try getStringField(value, "blob_gas_used"))
    else if (try getOptionalStringField(value, "blob_gas_used")) |blob_gas_used_text|
        try parseU64(blob_gas_used_text)
    else
        0;
    const excess_blob_gas = if (fork.hasBlobGasFields())
        try parseU64(try getStringField(value, "excess_blob_gas"))
    else if (try getOptionalStringField(value, "excess_blob_gas")) |excess_blob_gas_text|
        try parseU64(excess_blob_gas_text)
    else
        0;

    return primitives.LightClientHeader.LightClientHeader.ExecutionPayloadHeaderFields.fromWithExtraData(
        fork,
        try hexToBytes(32, try getStringField(value, "parent_hash")),
        try hexToBytes(20, try getStringField(value, "fee_recipient")),
        try hexToBytes(32, try getStringField(value, "state_root")),
        try hexToBytes(32, try getStringField(value, "receipts_root")),
        try hexToBytes(256, try getStringField(value, "logs_bloom")),
        try hexToBytes(32, try getStringField(value, "prev_randao")),
        try parseU64(try getStringField(value, "block_number")),
        try parseU64(try getStringField(value, "gas_limit")),
        try parseU64(try getStringField(value, "gas_used")),
        try parseU64(try getStringField(value, "timestamp")),
        extra_data[0..extra_data_len],
        try parseU256(try getStringField(value, "base_fee_per_gas")),
        try hexToBytes(32, try getStringField(value, "block_hash")),
        try hexToBytes(32, try getStringField(value, "transactions_root")),
        withdrawals_root,
        blob_gas_used,
        excess_blob_gas,
    );
}

fn parseSyncCommitteePubkeys(value: std.json.Value) ![512][48]u8 {
    const pubkeys = try expectArray(value);
    if (pubkeys.len != 512) {
        return error.InvalidArrayLength;
    }

    var out: [512][48]u8 = undefined;
    for (pubkeys, 0..) |pubkey, index| {
        out[index] = try hexToBytes(48, try expectString(pubkey));
    }
    return out;
}

fn parseBranch(comptime N: usize, value: std.json.Value) ![N][32]u8 {
    const branch_items = try expectArray(value);
    if (branch_items.len != N) {
        return error.InvalidArrayLength;
    }

    var out: [N][32]u8 = undefined;
    for (branch_items, 0..) |item, index| {
        out[index] = try hexToBytes(32, try expectString(item));
    }
    return out;
}

/// Parse a Merkle branch of `expected_len` elements into the caller-provided
/// `buffer` and return the populated prefix slice. The expected length depends
/// on the consensus fork (pre-Electra branches are one element shorter than
/// their Electra equivalents), so callers select `expected_len` accordingly.
/// `buffer` must be at least `expected_len` elements long; ownership of the
/// buffer stays with the caller.
fn parseBranchSlice(
    buffer: [][32]u8,
    expected_len: usize,
    value: std.json.Value,
) ![]const [32]u8 {
    const branch_items = try expectArray(value);
    if (branch_items.len != expected_len) {
        return error.InvalidArrayLength;
    }
    std.debug.assert(buffer.len >= expected_len);

    for (branch_items, 0..) |item, index| {
        buffer[index] = try hexToBytes(32, try expectString(item));
    }
    return buffer[0..expected_len];
}

/// Expected element count for a sync-committee Merkle branch
/// (current_sync_committee_branch / next_sync_committee_branch). Electra adds
/// one extra level to the generalized index, so the branch grows from 5 to 6.
fn syncCommitteeBranchLen(fork: primitives.LightClientHeader.Fork) usize {
    return if (fork.isElectraOrLater()) 6 else 5;
}

/// Expected element count for a finality Merkle branch (finality_branch).
/// Electra grows the branch from 6 to 7 elements.
fn finalityBranchLen(fork: primitives.LightClientHeader.Fork) usize {
    return if (fork.isElectraOrLater()) 7 else 6;
}

fn parseSyncAggregate(value: std.json.Value) !primitives.SyncAggregate.SyncAggregate {
    return primitives.SyncAggregate.SyncAggregate{
        .sync_committee_bits = try hexToBytes(64, try getStringField(value, "sync_committee_bits")),
        .sync_committee_signature = try hexToBytes(96, try getStringField(value, "sync_committee_signature")),
    };
}

test "parseFork rejects unknown explicit fork names" {
    try std.testing.expectEqual(primitives.LightClientHeader.Fork.deneb, try parseFork("Deneb"));
    try std.testing.expectEqual(primitives.LightClientHeader.Fork.electra, try parseFork("fulu"));
    try std.testing.expectError(error.UnsupportedConsensusFork, parseFork("gloas"));
    try std.testing.expectError(error.UnsupportedConsensusFork, parseFork(""));
}

test "socket idle timeout and total deadline interrupt an unfinished upstream read" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var server = try std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0).listen(.{});
    defer server.deinit();

    const cases = [_]struct { idle_ms: u32, budget_ns: u64, expect_idle: bool }{
        .{ .idle_ms = 20, .budget_ns = 5 * std.time.ns_per_s, .expect_idle = true },
        .{ .idle_ms = 5000, .budget_ns = 20 * std.time.ns_per_ms, .expect_idle = false },
    };
    for (cases) |case| {
        var client: std.http.Client = .{ .allocator = std.testing.allocator };
        defer client.deinit();
        const connection = try client.connectTcp("127.0.0.1", server.listen_address.getPort(), .plain);
        defer {
            connection.closing = true;
            client.connection_pool.release(connection);
        }
        const peer = try server.accept();
        defer peer.stream.close();
        try peer.stream.writeAll("x");
        try std.testing.expectEqual(@as(u8, 'x'), try connection.reader().takeByte());

        var deadline: UpstreamDeadline = undefined;
        try deadline.startWithTimeouts(connection, case.idle_ms, case.budget_ns);
        defer deadline.stop();
        try std.testing.expect(std.meta.isError(connection.reader().takeByte()));
        try std.testing.expectError(error.UpstreamTimeout, deadline.check(connection));
        try std.testing.expectEqual(case.expect_idle, UpstreamDeadline.isTimeout(connection.stream_reader.getError()));
    }
}

test "versioned response with unknown fork name fails instead of defaulting to deneb" {
    try std.testing.expectError(
        error.UnsupportedConsensusFork,
        parseFinalityUpdateResponseWithFork(std.testing.allocator, "{\"version\":\"gloas\",\"data\":{}}", null),
    );
}

test "readLimitedBody accepts exactly the cap and rejects one byte over" {
    const allocator = std.testing.allocator;

    var exact: std.Io.Reader = .fixed("abcd");
    const body = try readLimitedBody(allocator, &exact, 4);
    defer allocator.free(body);
    try std.testing.expectEqualStrings("abcd", body);

    var over: std.Io.Reader = .fixed("abcde");
    try std.testing.expectError(error.BeaconResponseTooLarge, readLimitedBody(allocator, &over, 4));

    var empty: std.Io.Reader = .fixed("");
    const empty_body = try readLimitedBody(allocator, &empty, 4);
    defer allocator.free(empty_body);
    try std.testing.expectEqual(@as(usize, 0), empty_body.len);
}

test "readLimitedBody maps ReadFailed without a body error to InvalidCompressedResponse" {
    const allocator = std.testing.allocator;

    var failing_reader: std.Io.Reader = .failing;
    try std.testing.expectError(error.ReadFailed, readLimitedBody(allocator, &failing_reader, 4));
    try std.testing.expectEqual(error.InvalidCompressedResponse, resolveBodyReadError(null));
    try std.testing.expectEqual(error.HttpChunkInvalid, resolveBodyReadError(error.HttpChunkInvalid));
}

test "parseUpdatesResponse rejects more than MAX_LIGHT_CLIENT_UPDATES entries before parsing them" {
    const allocator = std.testing.allocator;

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(allocator);
    try json.append(allocator, '[');
    for (0..MAX_LIGHT_CLIENT_UPDATES + 1) |index| {
        if (index != 0) try json.append(allocator, ',');
        // Entries are deliberately unparsable: the count check must fire first.
        try json.appendSlice(allocator, "{}");
    }
    try json.append(allocator, ']');

    try std.testing.expectError(error.TooManyLightClientUpdates, parseUpdatesResponse(allocator, json.items));
}
