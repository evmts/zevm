const std = @import("std");
const envelope = @import("envelope.zig");

fn getObjectField(value: std.json.Value, key: []const u8) !std.json.Value {
    return switch (value) {
        .object => |object| object.get(key) orelse error.MissingField,
        else => error.InvalidJsonType,
    };
}

test "parseBody parses a valid single request object" {
    var parsed = try envelope.parseBody(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_chainId\",\"params\":[]}",
    );
    defer parsed.deinit(std.testing.allocator);

    switch (parsed) {
        .single => |request| {
            try std.testing.expectEqualStrings("eth_chainId", request.method);
            try std.testing.expect(request.id != null);
            switch (request.id.?) {
                .number => |number| try std.testing.expectEqual(@as(i64, 1), number),
                else => return error.ExpectedNumberId,
            }
            try std.testing.expect(request.params != null);
            switch (request.params.?) {
                .array => |array| try std.testing.expectEqual(@as(usize, 0), array.items.len),
                else => return error.ExpectedArrayParams,
            }
        },
        .batch => return error.ExpectedSingleRequest,
    }
}

test "parseBody maps malformed JSON to parse error" {
    try std.testing.expectError(
        error.ParseError,
        envelope.parseBody(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"method\""),
    );
}

test "parseBody maps invalid request object shape to invalid request" {
    try std.testing.expectError(
        error.InvalidRequest,
        envelope.parseBody(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1}"),
    );
}

test "parseId accepts number string and null" {
    const number_id = try envelope.parseId(std.json.Value{ .integer = 99 });
    switch (number_id) {
        .number => |value| try std.testing.expectEqual(@as(i64, 99), value),
        else => return error.ExpectedNumberId,
    }

    const string_id = try envelope.parseId(std.json.Value{ .string = "abc" });
    switch (string_id) {
        .string => |value| try std.testing.expectEqualStrings("abc", value),
        else => return error.ExpectedStringId,
    }

    const null_id = try envelope.parseId(std.json.Value.null);
    switch (null_id) {
        .null_value => {},
        else => return error.ExpectedNullId,
    }
}

test "writeSuccess serializes result envelope" {
    const response = try envelope.writeSuccess(
        std.testing.allocator,
        envelope.Id{ .number = 7 },
        std.json.Value{ .string = "ok" },
    );
    defer std.testing.allocator.free(response);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, response, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("2.0", (try getObjectField(parsed.value, "jsonrpc")).string);
    try std.testing.expectEqual(@as(i64, 7), (try getObjectField(parsed.value, "id")).integer);
    try std.testing.expectEqualStrings("ok", (try getObjectField(parsed.value, "result")).string);
}

test "writeError serializes error envelope" {
    const response = try envelope.writeError(
        std.testing.allocator,
        envelope.Id{ .string = "id-1" },
        -32601,
        "Method not found",
    );
    defer std.testing.allocator.free(response);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, response, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("id-1", (try getObjectField(parsed.value, "id")).string);

    const error_object = try getObjectField(parsed.value, "error");
    try std.testing.expectEqual(@as(i64, -32601), (try getObjectField(error_object, "code")).integer);
    try std.testing.expectEqualStrings("Method not found", (try getObjectField(error_object, "message")).string);
}

test "parseBody parses non-empty batch" {
    var parsed = try envelope.parseBody(
        std.testing.allocator,
        "[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_chainId\"},{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"eth_blockNumber\"}]",
    );
    defer parsed.deinit(std.testing.allocator);

    switch (parsed) {
        .single => return error.ExpectedBatch,
        .batch => |requests| {
            try std.testing.expectEqual(@as(usize, 2), requests.len);
            try std.testing.expectEqualStrings("eth_chainId", requests[0].method);
            try std.testing.expectEqualStrings("eth_blockNumber", requests[1].method);
        },
    }
}

test "parseBody rejects empty batch" {
    try std.testing.expectError(
        error.InvalidRequest,
        envelope.parseBody(std.testing.allocator, "[]"),
    );
}
