const std = @import("std");
const jsonrpc = @import("jsonrpc");

pub fn handleJsonRpc(allocator: std.mem.Allocator, request_bytes: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const arena_allocator = arena.allocator();
    const parsed = std.json.parseFromSlice(std.json.Value, arena_allocator, request_bytes, .{
        .allocate = .alloc_always,
    }) catch {
        const response_value = try makeErrorResponseValue(arena_allocator, .null, -32700, "Parse error");
        const response_bytes = try serializeResponse(arena_allocator, response_value);
        return allocator.dupe(u8, response_bytes);
    };
    defer parsed.deinit();

    const response_value = switch (parsed.value) {
        .object => try handleSingleValue(arena_allocator, parsed.value),
        .array => |array| try handleBatch(arena_allocator, array.items),
        else => try makeErrorResponseValue(arena_allocator, .null, -32600, "Invalid request"),
    };

    const response_bytes = try serializeResponse(arena_allocator, response_value);
    return allocator.dupe(u8, response_bytes);
}

fn handleSingleValue(allocator: std.mem.Allocator, request_value: std.json.Value) !std.json.Value {
    const request_object = switch (request_value) {
        .object => |object| object,
        else => return makeErrorResponseValue(allocator, .null, -32600, "Invalid request"),
    };

    const request_id = extractResponseId(request_value);

    const jsonrpc_field = request_object.get("jsonrpc") orelse {
        return makeErrorResponseValue(allocator, request_id, -32600, "Invalid request");
    };

    switch (jsonrpc_field) {
        .string => |jsonrpc_version| {
            if (!std.mem.eql(u8, jsonrpc_version, "2.0")) {
                return makeErrorResponseValue(allocator, request_id, -32600, "Invalid request");
            }
        },
        else => return makeErrorResponseValue(allocator, request_id, -32600, "Invalid request"),
    }

    const method_field = request_object.get("method") orelse {
        return makeErrorResponseValue(allocator, request_id, -32600, "Invalid request");
    };

    const method_name = switch (method_field) {
        .string => |method_name| method_name,
        else => return makeErrorResponseValue(allocator, request_id, -32600, "Invalid request"),
    };

    return dispatchMethod(allocator, request_id, method_name);
}

fn handleBatch(allocator: std.mem.Allocator, batch_values: []const std.json.Value) !std.json.Value {
    if (batch_values.len == 0) {
        return makeErrorResponseValue(allocator, .null, -32600, "Invalid request");
    }

    var responses = std.json.Array.init(allocator);
    for (batch_values) |batch_value| {
        try responses.append(try handleSingleValue(allocator, batch_value));
    }

    return .{ .array = responses };
}

fn dispatchMethod(
    allocator: std.mem.Allocator,
    request_id: std.json.Value,
    method_name: []const u8,
) !std.json.Value {
    if (!isKnownMethod(method_name)) {
        return makeErrorResponseValue(allocator, request_id, -32601, "Method not found");
    }

    return makeErrorResponseValue(allocator, request_id, -32601, "Method not found");
}

fn isKnownMethod(method_name: []const u8) bool {
    _ = jsonrpc.eth.EthMethod.fromMethodName(method_name) catch {
        _ = jsonrpc.debug.DebugMethod.fromMethodName(method_name) catch {
            _ = jsonrpc.engine.EngineMethod.fromMethodName(method_name) catch {
                return false;
            };
            return true;
        };
        return true;
    };
    return true;
}

fn extractResponseId(request_value: std.json.Value) std.json.Value {
    const request_object = switch (request_value) {
        .object => |object| object,
        else => return .null,
    };

    const request_id = request_object.get("id") orelse return .null;

    return switch (request_id) {
        .null => .null,
        .integer => request_id,
        .float => request_id,
        .number_string => request_id,
        .string => request_id,
        else => .null,
    };
}

fn makeErrorResponseValue(
    allocator: std.mem.Allocator,
    request_id: std.json.Value,
    code: i32,
    message: []const u8,
) !std.json.Value {
    var error_object = std.json.ObjectMap.init(allocator);
    try error_object.put("code", .{ .integer = code });
    try error_object.put("message", .{ .string = message });

    var response_object = std.json.ObjectMap.init(allocator);
    try response_object.put("jsonrpc", .{ .string = "2.0" });
    try response_object.put("id", request_id);
    try response_object.put("error", .{ .object = error_object });

    return .{ .object = response_object };
}

fn serializeResponse(allocator: std.mem.Allocator, response_value: std.json.Value) ![]u8 {
    var response_writer = std.Io.Writer.Allocating.init(allocator);
    defer response_writer.deinit();

    try std.json.Stringify.value(response_value, .{}, &response_writer.writer);

    return response_writer.toOwnedSlice();
}

test "isKnownMethod: recognizes eth/debug/engine method names" {
    try std.testing.expect(isKnownMethod("eth_chainId"));
    try std.testing.expect(isKnownMethod("debug_getRawBlock"));
    try std.testing.expect(isKnownMethod("engine_getPayloadV1"));
    try std.testing.expect(!isKnownMethod("zevm_notAMethod"));
}

test "extractResponseId: numeric/string/null ids are preserved" {
    var object = std.json.ObjectMap.init(std.testing.allocator);
    defer object.deinit();

    try object.put("id", .{ .integer = 7 });
    try std.testing.expectEqual(@as(i64, 7), switch (extractResponseId(.{ .object = object })) {
        .integer => |value| value,
        else => return error.InvalidJsonType,
    });
}

test "extractResponseId: invalid id shapes become null" {
    var object = std.json.ObjectMap.init(std.testing.allocator);
    defer object.deinit();

    var nested = std.json.ObjectMap.init(std.testing.allocator);
    defer nested.deinit();
    try nested.put("k", .{ .string = "v" });

    try object.put("id", .{ .object = nested });
    try std.testing.expect(extractResponseId(.{ .object = object }) == .null);
}

test "makeErrorResponseValue: emits jsonrpc/id/error envelope" {
    const response_value = try makeErrorResponseValue(std.testing.allocator, .{ .string = "abc" }, -32601, "Method not found");
    defer response_value.object.deinit();

    const response_object = response_value.object;
    try std.testing.expectEqualStrings("2.0", switch (response_object.get("jsonrpc") orelse return error.MissingJsonField) {
        .string => |value| value,
        else => return error.InvalidJsonType,
    });
    try std.testing.expectEqualStrings("abc", switch (response_object.get("id") orelse return error.MissingJsonField) {
        .string => |value| value,
        else => return error.InvalidJsonType,
    });
    const error_object = switch (response_object.get("error") orelse return error.MissingJsonField) {
        .object => |object| object,
        else => return error.InvalidJsonType,
    };
    try std.testing.expectEqual(@as(i64, -32601), switch (error_object.get("code") orelse return error.MissingJsonField) {
        .integer => |value| value,
        else => return error.InvalidJsonType,
    });
}
