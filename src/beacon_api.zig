const std = @import("std");
const primitives = @import("primitives");

pub const BeaconApi = struct {
    endpoint_url: []const u8,

    pub fn getBootstrap(
        self: BeaconApi,
        allocator: std.mem.Allocator,
        checkpoint: [32]u8,
    ) !primitives.LightClientUpdate.LightClientBootstrap {
        const url = try self.buildBootstrapUrl(allocator, checkpoint);
        defer allocator.free(url);

        const response_body = try self.httpGet(allocator, url);
        defer allocator.free(response_body);

        return try parseBootstrapResponse(allocator, response_body);
    }

    pub fn getUpdates(
        self: BeaconApi,
        allocator: std.mem.Allocator,
        start_period: u64,
        count: u8,
    ) ![]primitives.LightClientUpdate.LightClientUpdate {
        const url = try self.buildUpdatesUrl(allocator, start_period, count);
        defer allocator.free(url);

        const response_body = try self.httpGet(allocator, url);
        defer allocator.free(response_body);

        return try parseUpdatesResponse(allocator, response_body);
    }

    pub fn getFinalityUpdate(
        self: BeaconApi,
        allocator: std.mem.Allocator,
    ) !primitives.LightClientUpdate.LightClientFinalityUpdate {
        const url = try self.buildFinalityUpdateUrl(allocator);
        defer allocator.free(url);

        const response_body = try self.httpGet(allocator, url);
        defer allocator.free(response_body);

        return try parseFinalityUpdateResponse(allocator, response_body);
    }

    pub fn getOptimisticUpdate(
        self: BeaconApi,
        allocator: std.mem.Allocator,
    ) !primitives.LightClientUpdate.LightClientOptimisticUpdate {
        const url = try self.buildOptimisticUpdateUrl(allocator);
        defer allocator.free(url);

        const response_body = try self.httpGet(allocator, url);
        defer allocator.free(response_body);

        return try parseOptimisticUpdateResponse(allocator, response_body);
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

    fn httpGet(
        self: BeaconApi,
        allocator: std.mem.Allocator,
        url: []const u8,
    ) ![]u8 {
        _ = self;

        var client: std.http.Client = .{ .allocator = allocator };
        defer client.deinit();

        var response_writer = std.Io.Writer.Allocating.init(allocator);
        defer response_writer.deinit();

        const response = try client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_writer = &response_writer.writer,
        });

        if (response.status != .ok) {
            return error.UnexpectedHttpStatus;
        }

        return try allocator.dupe(u8, response_writer.written());
    }
};

pub fn parseBootstrapResponse(
    allocator: std.mem.Allocator,
    json_response: []const u8,
) !primitives.LightClientUpdate.LightClientBootstrap {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_response, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const data = try getDataField(parsed.value);
    return try parseBootstrap(data);
}

pub fn parseUpdatesResponse(
    allocator: std.mem.Allocator,
    json_response: []const u8,
) ![]primitives.LightClientUpdate.LightClientUpdate {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_response, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const items = try expectArray(parsed.value);
    const updates = try allocator.alloc(primitives.LightClientUpdate.LightClientUpdate, items.len);
    errdefer allocator.free(updates);

    for (items, 0..) |item, index| {
        updates[index] = try parseUpdate(try getDataField(item));
    }

    return updates;
}

pub fn parseFinalityUpdateResponse(
    allocator: std.mem.Allocator,
    json_response: []const u8,
) !primitives.LightClientUpdate.LightClientFinalityUpdate {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_response, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const data = try getDataField(parsed.value);
    return try parseFinalityUpdate(data);
}

pub fn parseOptimisticUpdateResponse(
    allocator: std.mem.Allocator,
    json_response: []const u8,
) !primitives.LightClientUpdate.LightClientOptimisticUpdate {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_response, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const data = try getDataField(parsed.value);
    return try parseOptimisticUpdate(data);
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
