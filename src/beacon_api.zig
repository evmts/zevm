const std = @import("std");
const primitives = @import("primitives");

const MAX_EXTRA_DATA_BYTES: usize = 32;

pub const BeaconApi = struct {
    endpoint_url: []const u8,

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

        var response_writer = std.Io.Writer.Allocating.init(allocator);
        defer response_writer.deinit();

        const uri = try std.Uri.parse(url);
        var request = try client.request(.GET, uri, .{});
        defer request.deinit();

        try request.sendBodiless();

        var redirect_buffer: [8 * 1024]u8 = undefined;
        var response = try request.receiveHead(redirect_buffer[0..]);
        const fork = consensusForkFromHeaders(response.head);

        if (response.head.status != .ok) {
            return error.UnexpectedHttpStatus;
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

        _ = reader.streamRemaining(&response_writer.writer) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr().?,
            else => |e| return e,
        };

        return .{
            .body = try allocator.dupe(u8, response_writer.written()),
            .fork = fork,
        };
    }
};

fn consensusForkFromHeaders(head: std.http.Client.Response.Head) ?primitives.LightClientHeader.Fork {
    var headers = head.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "eth-consensus-version") or
            std.ascii.eqlIgnoreCase(header.name, "consensus_version"))
        {
            return parseFork(header.value) catch null;
        }
    }
    return null;
}

fn parseFork(name: []const u8) !primitives.LightClientHeader.Fork {
    if (std.ascii.eqlIgnoreCase(name, "bellatrix")) return .bellatrix;
    if (std.ascii.eqlIgnoreCase(name, "capella")) return .capella;
    if (std.ascii.eqlIgnoreCase(name, "deneb")) return .deneb;
    if (std.ascii.eqlIgnoreCase(name, "electra")) return .electra;
    return error.UnknownFork;
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
                fork = parseFork(v.string) catch fork;
            }
        }
        if (value.object.get("data")) |data| {
            return .{ .data = data, .fork = fork };
        }
    }
    return .{ .data = value, .fork = fork };
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
    _ = response.fork;
    return try parseBootstrap(response.data);
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
    const updates = try allocator.alloc(primitives.LightClientUpdate.LightClientUpdate, items.len);
    errdefer allocator.free(updates);

    for (items, 0..) |item, index| {
        const item_response = try getVersionedData(item, response.fork);
        _ = item_response.fork;
        updates[index] = try parseUpdate(item_response.data);
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
    _ = response.fork;
    return try parseFinalityUpdate(response.data);
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
    _ = response.fork;
    return try parseOptimisticUpdate(response.data);
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

fn parseBootstrap(value: std.json.Value) !primitives.LightClientUpdate.LightClientBootstrap {
    const current_sync_committee = try getObjectField(value, "current_sync_committee");

    return primitives.LightClientUpdate.LightClientBootstrap.from(
        try parseLightClientHeader(try getObjectField(value, "header")),
        try parseSyncCommitteePubkeys(try getObjectField(current_sync_committee, "pubkeys")),
        try hexToBytes(48, try getStringField(current_sync_committee, "aggregate_pubkey")),
        try parseBranch(5, try getObjectField(value, "current_sync_committee_branch")),
    );
}

fn parseUpdate(value: std.json.Value) !primitives.LightClientUpdate.LightClientUpdate {
    const sync_aggregate = try parseSyncAggregate(try getObjectField(value, "sync_aggregate"));
    const next_sync_committee = try getObjectField(value, "next_sync_committee");

    return primitives.LightClientUpdate.LightClientUpdate.from(
        try parseLightClientHeader(try getObjectField(value, "attested_header")),
        try parseSyncCommitteePubkeys(try getObjectField(next_sync_committee, "pubkeys")),
        try hexToBytes(48, try getStringField(next_sync_committee, "aggregate_pubkey")),
        try parseBranch(5, try getObjectField(value, "next_sync_committee_branch")),
        try parseLightClientHeader(try getObjectField(value, "finalized_header")),
        try parseBranch(6, try getObjectField(value, "finality_branch")),
        sync_aggregate.sync_committee_bits,
        sync_aggregate.sync_committee_signature,
        try parseU64(try getStringField(value, "signature_slot")),
    );
}

fn parseFinalityUpdate(value: std.json.Value) !primitives.LightClientUpdate.LightClientFinalityUpdate {
    const sync_aggregate = try parseSyncAggregate(try getObjectField(value, "sync_aggregate"));

    return primitives.LightClientUpdate.LightClientFinalityUpdate.from(
        try parseLightClientHeader(try getObjectField(value, "attested_header")),
        try parseLightClientHeader(try getObjectField(value, "finalized_header")),
        try parseBranch(6, try getObjectField(value, "finality_branch")),
        sync_aggregate.sync_committee_bits,
        sync_aggregate.sync_committee_signature,
        try parseU64(try getStringField(value, "signature_slot")),
    );
}

fn parseOptimisticUpdate(value: std.json.Value) !primitives.LightClientUpdate.LightClientOptimisticUpdate {
    const sync_aggregate = try parseSyncAggregate(try getObjectField(value, "sync_aggregate"));

    return primitives.LightClientUpdate.LightClientOptimisticUpdate.from(
        try parseLightClientHeader(try getObjectField(value, "attested_header")),
        sync_aggregate.sync_committee_bits,
        sync_aggregate.sync_committee_signature,
        try parseU64(try getStringField(value, "signature_slot")),
    );
}

fn parseLightClientHeader(value: std.json.Value) !primitives.LightClientHeader.LightClientHeader {
    return primitives.LightClientHeader.LightClientHeader.from(
        try parseBeaconHeader(try getObjectField(value, "beacon")),
        try parseExecutionHeader(try getObjectField(value, "execution")),
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
) !primitives.LightClientHeader.LightClientHeader.ExecutionPayloadHeaderFields {
    return primitives.LightClientHeader.LightClientHeader.ExecutionPayloadHeaderFields.from(
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
        try parseU256(try getStringField(value, "base_fee_per_gas")),
        try hexToBytes(32, try getStringField(value, "block_hash")),
        try hexToBytes(32, try getStringField(value, "transactions_root")),
        try hexToBytes(32, try getStringField(value, "withdrawals_root")),
        try parseU64(try getStringField(value, "blob_gas_used")),
        try parseU64(try getStringField(value, "excess_blob_gas")),
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

fn parseSyncAggregate(value: std.json.Value) !primitives.SyncAggregate.SyncAggregate {
    return primitives.SyncAggregate.SyncAggregate{
        .sync_committee_bits = try hexToBytes(64, try getStringField(value, "sync_committee_bits")),
        .sync_committee_signature = try hexToBytes(96, try getStringField(value, "sync_committee_signature")),
    };
}
