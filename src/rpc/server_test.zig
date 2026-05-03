const std = @import("std");
const jsonrpc = @import("jsonrpc");
const primitives = @import("primitives");
const dispatcher = @import("dispatcher.zig");
const dispatch_wiring = @import("dispatch_wiring.zig");
const runtime_mod = @import("../node/runtime.zig");
const server = @import("server.zig");

const RETURN_32_BYTE_42 = [_]u8{ 0x60, 0x2a, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
const SSTORE_THEN_RETURN_42 = [_]u8{ 0x60, 0x01, 0x60, 0x00, 0x55, 0x60, 0x2a, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
const TARGET = "0x1000000000000000000000000000000000000001";
const TARGET_OVERRIDE = "0x2000000000000000000000000000000000000002";
const EXPECTED_32_BYTE_42 = "0x000000000000000000000000000000000000000000000000000000000000002a";

fn getObjectField(value: std.json.Value, key: []const u8) !std.json.Value {
    return switch (value) {
        .object => |object| object.get(key) orelse error.MissingField,
        else => error.InvalidJsonType,
    };
}

fn parseJson(body: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{
        .allocate = .alloc_always,
    });
}

fn parseQuantityHex(text: []const u8) !u64 {
    if (!std.mem.startsWith(u8, text, "0x") or text.len == 2) return error.InvalidQuantity;
    return std.fmt.parseInt(u64, text[2..], 16);
}

fn successHandler(allocator: std.mem.Allocator, method_name: []const u8, params: ?std.json.Value) anyerror!std.json.Value {
    _ = allocator;
    _ = params;

    if (std.mem.eql(u8, method_name, "eth_blockNumber")) {
        return .{ .integer = 7 };
    }

    return error.UnexpectedMethod;
}

test "POST single request returns HTTP 200 + JSON-RPC envelope" {
    const handlers = dispatcher.HandlerRegistry{
        .on_method = &successHandler,
    };

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_blockNumber\"}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    try std.testing.expectEqualStrings("application/json", response.content_type.?);

    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 7), (try getObjectField(parsed.value, "result")).integer);
}

test "batch request returns per-item result/error array" {
    const handlers = dispatcher.HandlerRegistry{
        .on_method = &successHandler,
    };

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_blockNumber\"},{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"unknown_method\"}]",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, response.status);

    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();

    const items = switch (parsed.value) {
        .array => |array| array.items,
        else => return error.ExpectedArray,
    };
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqual(@as(i64, 7), (try getObjectField(items[0], "result")).integer);

    const error_object = try getObjectField(items[1], "error");
    try std.testing.expectEqual(@as(i64, jsonrpc.envelope.ErrorCode.METHOD_NOT_FOUND), (try getObjectField(error_object, "code")).integer);
}

test "malformed JSON returns -32700" {
    const handlers = dispatcher.HandlerRegistry{};

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();

    const error_object = try getObjectField(parsed.value, "error");
    try std.testing.expectEqual(@as(i64, jsonrpc.envelope.ErrorCode.PARSE_ERROR), (try getObjectField(error_object, "code")).integer);
}

test "invalid request object returns -32600" {
    const handlers = dispatcher.HandlerRegistry{};

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"id\":1}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();

    const error_object = try getObjectField(parsed.value, "error");
    try std.testing.expectEqual(@as(i64, jsonrpc.envelope.ErrorCode.INVALID_REQUEST), (try getObjectField(error_object, "code")).integer);
}

test "unknown method returns -32601" {
    const handlers = dispatcher.HandlerRegistry{};

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"unknown_method\"}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();

    const error_object = try getObjectField(parsed.value, "error");
    try std.testing.expectEqual(@as(i64, jsonrpc.envelope.ErrorCode.METHOD_NOT_FOUND), (try getObjectField(error_object, "code")).integer);
}

test "invalid params returns -32602" {
    const handlers = dispatcher.HandlerRegistry{};

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getBalance\",\"params\":[]}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();

    const error_object = try getObjectField(parsed.value, "error");
    try std.testing.expectEqual(@as(i64, jsonrpc.envelope.ErrorCode.INVALID_PARAMS), (try getObjectField(error_object, "code")).integer);
}

test "HTTP path reaches runtime core read handlers" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        \\[
        \\  {"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]},
        \\  {"jsonrpc":"2.0","id":2,"method":"eth_blockNumber","params":[]},
        \\  {"jsonrpc":"2.0","id":3,"method":"eth_accounts","params":[]},
        \\  {"jsonrpc":"2.0","id":4,"method":"eth_coinbase","params":[]},
        \\  {"jsonrpc":"2.0","id":5,"method":"eth_gasPrice","params":[]},
        \\  {"jsonrpc":"2.0","id":6,"method":"eth_maxPriorityFeePerGas","params":[]},
        \\  {"jsonrpc":"2.0","id":7,"method":"eth_blobBaseFee","params":[]},
        \\  {"jsonrpc":"2.0","id":8,"method":"eth_getBalance","params":["0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266","latest"]},
        \\  {"jsonrpc":"2.0","id":9,"method":"eth_getCode","params":["0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266","latest"]},
        \\  {"jsonrpc":"2.0","id":10,"method":"eth_getStorageAt","params":["0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266","0x0","latest"]},
        \\  {"jsonrpc":"2.0","id":11,"method":"eth_getTransactionCount","params":["0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266","latest"]},
        \\  {"jsonrpc":"2.0","id":12,"method":"eth_feeHistory","params":["0x1","latest"]}
        \\]
    ,
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();

    const items = switch (parsed.value) {
        .array => |array| array.items,
        else => return error.ExpectedArray,
    };
    try std.testing.expectEqual(@as(usize, 12), items.len);
    try std.testing.expectEqualStrings("0x7a69", (try getObjectField(items[0], "result")).string);
    try std.testing.expectEqualStrings("0x0", (try getObjectField(items[1], "result")).string);
    try std.testing.expectEqual(@as(usize, 10), (try getObjectField(items[2], "result")).array.items.len);
    try std.testing.expectEqualStrings("0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266", (try getObjectField(items[3], "result")).string);
    try std.testing.expectEqualStrings("0x77359400", (try getObjectField(items[4], "result")).string);
    try std.testing.expectEqualStrings("0x3b9aca00", (try getObjectField(items[5], "result")).string);
    try std.testing.expectEqualStrings("0x1", (try getObjectField(items[6], "result")).string);
    try std.testing.expectEqualStrings("0x21e19e0c9bab2400000", (try getObjectField(items[7], "result")).string);
    try std.testing.expectEqualStrings("0x", (try getObjectField(items[8], "result")).string);
    try std.testing.expectEqualStrings(
        "0x0000000000000000000000000000000000000000000000000000000000000000",
        (try getObjectField(items[9], "result")).string,
    );
    try std.testing.expectEqualStrings("0x0", (try getObjectField(items[10], "result")).string);
    const fee_history = try getObjectField(items[11], "result");
    try std.testing.expectEqualStrings("0x0", (try getObjectField(fee_history, "oldestBlock")).string);
    try std.testing.expectEqual(@as(usize, 2), (try getObjectField(fee_history, "baseFeePerGas")).array.items.len);
}

test "HTTP path reaches simulation handlers without persisting state overrides" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const target = primitives.Address{ .bytes = [_]u8{0x10} ++ [_]u8{0} ** 18 ++ [_]u8{0x01} };
    const override_target = primitives.Address{ .bytes = [_]u8{0x20} ++ [_]u8{0} ** 18 ++ [_]u8{0x02} };
    try rt.setCode(target, &SSTORE_THEN_RETURN_42);

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        \\[
        \\  {"jsonrpc":"2.0","id":1,"method":"eth_call","params":[{"to":"0x1000000000000000000000000000000000000001","data":"0x"},"latest"]},
        \\  {"jsonrpc":"2.0","id":2,"method":"eth_estimateGas","params":[{"from":"0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266","to":"0x1000000000000000000000000000000000000001","gas":"0x186a0"}]},
        \\  {"jsonrpc":"2.0","id":3,"method":"eth_call","params":[{"to":"0x2000000000000000000000000000000000000002"},"latest",{"0x2000000000000000000000000000000000000002":{"code":"0x602a60005260206000f3"}}]}
        \\]
    ,
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();

    const items = switch (parsed.value) {
        .array => |array| array.items,
        else => return error.ExpectedArray,
    };
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings(EXPECTED_32_BYTE_42, (try getObjectField(items[0], "result")).string);
    try std.testing.expect((try parseQuantityHex((try getObjectField(items[1], "result")).string)) > 21_000);
    try std.testing.expectEqualStrings(EXPECTED_32_BYTE_42, (try getObjectField(items[2], "result")).string);
    try std.testing.expectEqual(@as(u256, 0), try rt.getStorage(target, 0));
    try std.testing.expectEqual(@as(usize, 0), (try rt.getCode(override_target)).len);
}

test "HTTP path snapshots restore dev controls mined blocks and query indexes" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    const controlled = "0x0000000000000000000000000000000000000042";
    const controlled_address = try primitives.Address.fromHex(controlled);
    const unmanaged = "0x0000000000000000000000000000000000000099";
    const unmanaged_address = try primitives.Address.fromHex(unmanaged);

    var snapshot_response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"zevm_snapshot\",\"params\":[]}",
        &handlers,
    );
    defer snapshot_response.deinit(std.testing.allocator);

    const snapshot_parsed = try parseJson(snapshot_response.body.?);
    defer snapshot_parsed.deinit();
    const snapshot_id = try std.testing.allocator.dupe(u8, (try getObjectField(snapshot_parsed.value, "result")).string);
    defer std.testing.allocator.free(snapshot_id);

    var mutate_response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        \\[
        \\  {"jsonrpc":"2.0","id":1,"method":"zevm_setBalance","params":["0x0000000000000000000000000000000000000042","0x2a"]},
        \\  {"jsonrpc":"2.0","id":2,"method":"zevm_setCode","params":["0x0000000000000000000000000000000000000042","0x602a60005260206000f3"]},
        \\  {"jsonrpc":"2.0","id":3,"method":"zevm_setStorageAt","params":["0x0000000000000000000000000000000000000042","0x0000000000000000000000000000000000000000000000000000000000000001","0x2a"]},
        \\  {"jsonrpc":"2.0","id":4,"method":"zevm_increaseTime","params":["0x2a"]},
        \\  {"jsonrpc":"2.0","id":5,"method":"zevm_setNextBlockTimestamp","params":["0x4d2"]},
        \\  {"jsonrpc":"2.0","id":6,"method":"zevm_impersonateAccount","params":["0x0000000000000000000000000000000000000099"]},
        \\  {"jsonrpc":"2.0","id":7,"method":"eth_getBalance","params":["0x0000000000000000000000000000000000000042","latest"]},
        \\  {"jsonrpc":"2.0","id":8,"method":"eth_getCode","params":["0x0000000000000000000000000000000000000042","latest"]},
        \\  {"jsonrpc":"2.0","id":9,"method":"eth_getStorageAt","params":["0x0000000000000000000000000000000000000042","0x1","latest"]}
        \\]
    ,
        &handlers,
    );
    defer mutate_response.deinit(std.testing.allocator);

    const mutate_parsed = try parseJson(mutate_response.body.?);
    defer mutate_parsed.deinit();
    const mutate_items = switch (mutate_parsed.value) {
        .array => |array| array.items,
        else => return error.ExpectedArray,
    };
    try std.testing.expectEqual(@as(usize, 9), mutate_items.len);
    try std.testing.expect((try getObjectField(mutate_items[0], "result")).bool);
    try std.testing.expect((try getObjectField(mutate_items[1], "result")).bool);
    try std.testing.expect((try getObjectField(mutate_items[2], "result")).bool);
    try std.testing.expectEqualStrings("0x2a", (try getObjectField(mutate_items[3], "result")).string);
    try std.testing.expect((try getObjectField(mutate_items[4], "result")).bool);
    try std.testing.expect((try getObjectField(mutate_items[5], "result")).bool);
    try std.testing.expectEqualStrings("0x2a", (try getObjectField(mutate_items[6], "result")).string);
    try std.testing.expectEqualStrings("0x602a60005260206000f3", (try getObjectField(mutate_items[7], "result")).string);
    try std.testing.expectEqualStrings(
        "0x000000000000000000000000000000000000000000000000000000000000002a",
        (try getObjectField(mutate_items[8], "result")).string,
    );
    try std.testing.expect(rt.canSignForAccount(unmanaged_address));

    var mine_response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"zevm_mine\",\"params\":[\"0x1\"]}",
        &handlers,
    );
    defer mine_response.deinit(std.testing.allocator);
    const mine_parsed = try parseJson(mine_response.body.?);
    defer mine_parsed.deinit();
    try std.testing.expect((try getObjectField(mine_parsed.value, "result")).bool);

    var send_response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_sendTransaction\",\"params\":[{\"from\":\"0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266\",\"to\":\"0x0000000000000000000000000000000000000042\",\"value\":\"0x1\",\"gas\":\"0x100000\"}]}",
        &handlers,
    );
    defer send_response.deinit(std.testing.allocator);
    const send_parsed = try parseJson(send_response.body.?);
    defer send_parsed.deinit();
    const tx_hash = try std.testing.allocator.dupe(u8, (try getObjectField(send_parsed.value, "result")).string);
    defer std.testing.allocator.free(tx_hash);

    const receipt_body = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getTransactionReceipt\",\"params\":[\"{s}\"]}}",
        .{tx_hash},
    );
    defer std.testing.allocator.free(receipt_body);

    var receipt_response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        receipt_body,
        &handlers,
    );
    defer receipt_response.deinit(std.testing.allocator);
    const receipt_parsed = try parseJson(receipt_response.body.?);
    defer receipt_parsed.deinit();
    const receipt = try getObjectField(receipt_parsed.value, "result");
    try std.testing.expectEqualStrings("0x2", (try getObjectField(receipt, "blockNumber")).string);
    try std.testing.expectEqualStrings(tx_hash, (try getObjectField(receipt, "transactionHash")).string);

    var mined_read_response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        \\[
        \\  {"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]},
        \\  {"jsonrpc":"2.0","id":2,"method":"eth_getBlockByNumber","params":["0x1",false]}
        \\]
    ,
        &handlers,
    );
    defer mined_read_response.deinit(std.testing.allocator);
    const mined_read_parsed = try parseJson(mined_read_response.body.?);
    defer mined_read_parsed.deinit();
    const mined_items = switch (mined_read_parsed.value) {
        .array => |array| array.items,
        else => return error.ExpectedArray,
    };
    try std.testing.expectEqualStrings("0x2", (try getObjectField(mined_items[0], "result")).string);
    const mined_block = try getObjectField(mined_items[1], "result");
    try std.testing.expectEqualStrings("0x4d2", (try getObjectField(mined_block, "timestamp")).string);

    const revert_body = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"zevm_revert\",\"params\":[\"{s}\"]}}",
        .{snapshot_id},
    );
    defer std.testing.allocator.free(revert_body);

    var revert_response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        revert_body,
        &handlers,
    );
    defer revert_response.deinit(std.testing.allocator);
    const revert_parsed = try parseJson(revert_response.body.?);
    defer revert_parsed.deinit();
    try std.testing.expect((try getObjectField(revert_parsed.value, "result")).bool);

    var restored_receipt_response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        receipt_body,
        &handlers,
    );
    defer restored_receipt_response.deinit(std.testing.allocator);
    const restored_receipt_parsed = try parseJson(restored_receipt_response.body.?);
    defer restored_receipt_parsed.deinit();
    switch (try getObjectField(restored_receipt_parsed.value, "result")) {
        .null => {},
        else => return error.ExpectedNull,
    }

    var restored_response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        revert_body,
        &handlers,
    );
    defer restored_response.deinit(std.testing.allocator);
    const second_revert_parsed = try parseJson(restored_response.body.?);
    defer second_revert_parsed.deinit();
    try std.testing.expect(!(try getObjectField(second_revert_parsed.value, "result")).bool);

    var restored_read_response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        \\[
        \\  {"jsonrpc":"2.0","id":1,"method":"eth_getBalance","params":["0x0000000000000000000000000000000000000042","latest"]},
        \\  {"jsonrpc":"2.0","id":2,"method":"eth_getCode","params":["0x0000000000000000000000000000000000000042","latest"]},
        \\  {"jsonrpc":"2.0","id":3,"method":"eth_getStorageAt","params":["0x0000000000000000000000000000000000000042","0x1","latest"]},
        \\  {"jsonrpc":"2.0","id":4,"method":"eth_blockNumber","params":[]},
        \\  {"jsonrpc":"2.0","id":5,"method":"eth_getBlockByNumber","params":["0x1",false]}
        \\]
    ,
        &handlers,
    );
    defer restored_read_response.deinit(std.testing.allocator);
    const restored_read_parsed = try parseJson(restored_read_response.body.?);
    defer restored_read_parsed.deinit();
    const restored_items = switch (restored_read_parsed.value) {
        .array => |array| array.items,
        else => return error.ExpectedArray,
    };
    try std.testing.expectEqualStrings("0x0", (try getObjectField(restored_items[0], "result")).string);
    try std.testing.expectEqualStrings("0x", (try getObjectField(restored_items[1], "result")).string);
    try std.testing.expectEqualStrings(
        "0x0000000000000000000000000000000000000000000000000000000000000000",
        (try getObjectField(restored_items[2], "result")).string,
    );
    try std.testing.expectEqualStrings("0x0", (try getObjectField(restored_items[3], "result")).string);
    switch (try getObjectField(restored_items[4], "result")) {
        .null => {},
        else => return error.ExpectedNull,
    }
    try std.testing.expectEqual(@as(u256, 0), try rt.getBalance(controlled_address));
    try std.testing.expectEqual(@as(i128, 0), rt.time_offset);
    try std.testing.expectEqual(@as(?u64, null), rt.next_block_timestamp);
    try std.testing.expect(!rt.canSignForAccount(unmanaged_address));
}

test "HTTP path maps malformed core read selector to invalid params" {
    var rt = try runtime_mod.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getBalance\",\"params\":[\"0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266\",\"0x999\"]}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();

    const error_object = try getObjectField(parsed.value, "error");
    try std.testing.expectEqual(@as(i64, jsonrpc.envelope.ErrorCode.INVALID_PARAMS), (try getObjectField(error_object, "code")).integer);
}

test "content-type is application/json for JSON-RPC responses" {
    const handlers = dispatcher.HandlerRegistry{};

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"unknown_method\"}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    try std.testing.expectEqualStrings("application/json", response.content_type.?);
}

test "non-root request target returns 404 without JSON-RPC body" {
    const handlers = dispatcher.HandlerRegistry{};

    var response = try server.handleHttpRequestForTestWithOptions(
        std.testing.allocator,
        .{
            .method = .POST,
            .target = "/rpc",
            .body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_blockNumber\"}",
        },
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.not_found, response.status);
    try std.testing.expect(response.body == null);
    try std.testing.expect(response.content_type == null);
}

test "non-POST request returns 405" {
    const handlers = dispatcher.HandlerRegistry{};

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .GET,
        "",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.method_not_allowed, response.status);
    try std.testing.expect(response.body == null);
    try std.testing.expect(response.content_type == null);
}

test "missing or invalid content-type returns 415 without JSON-RPC body" {
    const handlers = dispatcher.HandlerRegistry{};

    {
        var response = try server.handleHttpRequestForTestWithOptions(
            std.testing.allocator,
            .{
                .method = .POST,
                .content_type = null,
                .body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_blockNumber\"}",
            },
            &handlers,
        );
        defer response.deinit(std.testing.allocator);

        try std.testing.expectEqual(std.http.Status.unsupported_media_type, response.status);
        try std.testing.expect(response.body == null);
        try std.testing.expect(response.content_type == null);
    }

    {
        var response = try server.handleHttpRequestForTestWithOptions(
            std.testing.allocator,
            .{
                .method = .POST,
                .content_type = "text/plain",
                .body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_blockNumber\"}",
            },
            &handlers,
        );
        defer response.deinit(std.testing.allocator);

        try std.testing.expectEqual(std.http.Status.unsupported_media_type, response.status);
        try std.testing.expect(response.body == null);
        try std.testing.expect(response.content_type == null);
    }
}

test "application/json content-type allows media-type parameters" {
    const handlers = dispatcher.HandlerRegistry{
        .on_method = &successHandler,
    };

    var response = try server.handleHttpRequestForTestWithOptions(
        std.testing.allocator,
        .{
            .method = .POST,
            .content_type = "application/json; charset=utf-8",
            .body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_blockNumber\"}",
        },
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    try std.testing.expectEqualStrings("application/json", response.content_type.?);

    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 7), (try getObjectField(parsed.value, "result")).integer);
}

test "oversized HTTP body returns 413 without JSON-RPC body" {
    const handlers = dispatcher.HandlerRegistry{};
    const body = try std.testing.allocator.alloc(u8, server.MAX_REQUEST_BODY_BYTES + 1);
    defer std.testing.allocator.free(body);
    @memset(body, ' ');

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        body,
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.payload_too_large, response.status);
    try std.testing.expect(response.body == null);
    try std.testing.expect(response.content_type == null);
}

test "request telemetry formatting records outcome without params" {
    const message = try server.formatRequestTelemetryForTest(std.testing.allocator, .{
        .method = "eth_sendTransaction",
        .id_present = true,
        .batch_size = 3,
        .status = "error",
        .error_code = jsonrpc.envelope.ErrorCode.INVALID_PARAMS,
        .duration_ns = 12_345_678,
        .mode = "trusted",
    });
    defer std.testing.allocator.free(message);

    try std.testing.expectEqualStrings(
        "rpc_request method=eth_sendTransaction id_present=true batch_size=3 status=error error_code=-32602 duration_us=12345 mode=trusted",
        message,
    );
    try std.testing.expect(std.mem.indexOf(u8, message, "params") == null);
}

test "single notification returns 204 empty response" {
    const handlers = dispatcher.HandlerRegistry{
        .on_method = &successHandler,
    };

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\"}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.no_content, response.status);
    try std.testing.expect(response.body == null);
    try std.testing.expect(response.content_type == null);
}

test "notification-only batch returns 204 empty response" {
    const handlers = dispatcher.HandlerRegistry{
        .on_method = &successHandler,
    };

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "[{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\"},{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\"}]",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.no_content, response.status);
    try std.testing.expect(response.body == null);
    try std.testing.expect(response.content_type == null);
}

test "mixed batch omits notifications and preserves response order" {
    const handlers = dispatcher.HandlerRegistry{
        .on_method = &successHandler,
    };

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "[{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\"},{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"eth_blockNumber\"},{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\"},{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"eth_blockNumber\"}]",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    try std.testing.expectEqualStrings("application/json", response.content_type.?);

    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();

    const items = switch (parsed.value) {
        .array => |array| array.items,
        else => return error.ExpectedArray,
    };
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqual(@as(i64, 2), (try getObjectField(items[0], "id")).integer);
    try std.testing.expectEqual(@as(i64, 7), (try getObjectField(items[0], "result")).integer);
    try std.testing.expectEqual(@as(i64, 3), (try getObjectField(items[1], "id")).integer);
    try std.testing.expectEqual(@as(i64, 7), (try getObjectField(items[1], "result")).integer);
}

test "id null is not treated as a notification" {
    const handlers = dispatcher.HandlerRegistry{
        .on_method = &successHandler,
    };

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"eth_blockNumber\"}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, response.status);

    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();

    try std.testing.expect((try getObjectField(parsed.value, "id")) == .null);
}
