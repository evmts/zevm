const std = @import("std");
const jsonrpc = @import("jsonrpc");
const primitives = @import("primitives");
const dispatcher = @import("dispatcher.zig");
const dispatch_wiring = @import("dispatch_wiring.zig");
const runtime_mod = @import("../node/runtime.zig");
const server = @import("server.zig");

const SSTORE_THEN_RETURN_42 = [_]u8{ 0x60, 0x01, 0x60, 0x00, 0x55, 0x60, 0x2a, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
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

fn base64UrlEncode(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(source.len));
    errdefer allocator.free(out);
    _ = std.base64.url_safe_no_pad.Encoder.encode(out, source);
    return out;
}

fn makeJwt(allocator: std.mem.Allocator, secret: []const u8, iat: i64) ![]u8 {
    const header_segment = try base64UrlEncode(allocator, "{\"alg\":\"HS256\",\"typ\":\"JWT\"}");
    defer allocator.free(header_segment);

    const payload_json = try std.fmt.allocPrint(allocator, "{{\"iat\":{}}}", .{iat});
    defer allocator.free(payload_json);
    const payload_segment = try base64UrlEncode(allocator, payload_json);
    defer allocator.free(payload_segment);

    const signing_input = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ header_segment, payload_segment });
    defer allocator.free(signing_input);

    var signature: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&signature, signing_input, secret);
    const signature_segment = try base64UrlEncode(allocator, signature[0..]);
    defer allocator.free(signature_segment);

    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ signing_input, signature_segment });
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

test "engine JWT auth validates bearer signature and time drift" {
    const now: i64 = 1_700_000_000;
    const token = try makeJwt(std.testing.allocator, server.DEFAULT_ENGINE_JWT_SECRET, now);
    defer std.testing.allocator.free(token);
    const authorization = try std.fmt.allocPrint(std.testing.allocator, "Bearer {s}", .{token});
    defer std.testing.allocator.free(authorization);

    try std.testing.expect(try server.validateJwtAuthorizationForTest(
        std.testing.allocator,
        authorization,
        server.DEFAULT_ENGINE_JWT_SECRET,
        now + server.DEFAULT_ENGINE_JWT_MAX_TIME_DRIFT_SECONDS,
        server.DEFAULT_ENGINE_JWT_MAX_TIME_DRIFT_SECONDS,
    ));
    try std.testing.expect(!try server.validateJwtAuthorizationForTest(
        std.testing.allocator,
        authorization,
        server.DEFAULT_ENGINE_JWT_SECRET,
        now + server.DEFAULT_ENGINE_JWT_MAX_TIME_DRIFT_SECONDS + 1,
        server.DEFAULT_ENGINE_JWT_MAX_TIME_DRIFT_SECONDS,
    ));
}

test "engine JWT client authorization is accepted by the engine listener validator" {
    const now: i64 = 1_700_000_000;
    const authorization = try server.engineJwtAuthorization(std.testing.allocator, server.DEFAULT_ENGINE_JWT_SECRET, now);
    defer std.testing.allocator.free(authorization);

    const token = try makeJwt(std.testing.allocator, server.DEFAULT_ENGINE_JWT_SECRET, now);
    defer std.testing.allocator.free(token);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "Bearer {s}", .{token});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, authorization);

    try std.testing.expect(try server.validateJwtAuthorizationForTest(
        std.testing.allocator,
        authorization,
        server.DEFAULT_ENGINE_JWT_SECRET,
        now,
        server.DEFAULT_ENGINE_JWT_MAX_TIME_DRIFT_SECONDS,
    ));
    try std.testing.expect(!try server.validateJwtAuthorizationForTest(
        std.testing.allocator,
        authorization,
        "wrongsecretwrongsecretwrongsecre",
        now,
        server.DEFAULT_ENGINE_JWT_MAX_TIME_DRIFT_SECONDS,
    ));
}

test "engine JWT auth rejects incorrect secrets and malformed bearer values" {
    const now: i64 = 1_700_000_000;
    const token = try makeJwt(std.testing.allocator, "wrongsecret", now);
    defer std.testing.allocator.free(token);
    const authorization = try std.fmt.allocPrint(std.testing.allocator, "Bearer {s}", .{token});
    defer std.testing.allocator.free(authorization);

    try std.testing.expect(!try server.validateJwtAuthorizationForTest(
        std.testing.allocator,
        authorization,
        server.DEFAULT_ENGINE_JWT_SECRET,
        now,
        server.DEFAULT_ENGINE_JWT_MAX_TIME_DRIFT_SECONDS,
    ));
    try std.testing.expect(!try server.validateJwtAuthorizationForTest(
        std.testing.allocator,
        token,
        server.DEFAULT_ENGINE_JWT_SECRET,
        now,
        server.DEFAULT_ENGINE_JWT_MAX_TIME_DRIFT_SECONDS,
    ));
}

test "blob-sized HTTP body reaches JSON-RPC parser" {
    const handlers = dispatcher.HandlerRegistry{};
    const old_one_mib_limit = 1024 * 1024;
    const body = try std.testing.allocator.alloc(u8, old_one_mib_limit + 1);
    defer std.testing.allocator.free(body);
    @memset(body, ' ');

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        body,
        &handlers,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();

    const error_object = try getObjectField(parsed.value, "error");
    try std.testing.expectEqual(@as(i64, jsonrpc.envelope.ErrorCode.PARSE_ERROR), (try getObjectField(error_object, "code")).integer);
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

test "request telemetry rejects invalid and oversized method names" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "eth_bad\nstatus=success", "eth_bad-method", "a" ** 65 }) |method| {
        const message = try server.formatRequestTelemetryForTest(allocator, .{
            .method = method,
            .id_present = false,
            .batch_size = 1,
            .status = "error",
            .error_code = null,
            .duration_ns = 0,
            .mode = "trusted",
        });
        defer allocator.free(message);
        try std.testing.expect(std.mem.startsWith(u8, message, "rpc_request method=<invalid> id_present="));
    }
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

// ---------------------------------------------------------------------------
// Round 1 transport hardening regressions.
// ---------------------------------------------------------------------------

var engine_handler_calls = std.atomic.Value(usize).init(0);

fn engineAwareHandler(allocator: std.mem.Allocator, method_name: []const u8, params: ?std.json.Value) anyerror!std.json.Value {
    _ = allocator;
    _ = params;
    if (std.mem.startsWith(u8, method_name, "engine_")) {
        _ = engine_handler_calls.fetchAdd(1, .seq_cst);
        return .{ .integer = 99 };
    }
    if (std.mem.eql(u8, method_name, "eth_blockNumber")) return .{ .integer = 7 };
    return error.UnexpectedMethod;
}

fn expectErrorCode(body: []const u8, expected: i32) !void {
    const parsed = try parseJson(body);
    defer parsed.deinit();
    const error_object = try getObjectField(parsed.value, "error");
    try std.testing.expectEqual(@as(i64, expected), (try getObjectField(error_object, "code")).integer);
}

fn nestedParamsRequest(allocator: std.mem.Allocator, depth: usize) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_blockNumber\",\"params\":");
    for (0..depth) |_| try out.writer.writeByte('[');
    for (0..depth) |_| try out.writer.writeByte(']');
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn batchRequest(allocator: std.mem.Allocator, count: usize) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    try out.writer.writeByte('[');
    for (0..count) |index| {
        if (index != 0) try out.writer.writeByte(',');
        try out.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"eth_blockNumber\"}}", .{index});
    }
    try out.writer.writeByte(']');
    return out.toOwnedSlice();
}

/// Writes `bytes`, then reads until the server closes the connection.
fn rawExchange(allocator: std.mem.Allocator, address: std.net.Address, bytes: []const u8) ![]u8 {
    const stream = try std.net.tcpConnectToAddress(address);
    defer stream.close();
    try stream.writeAll(bytes);

    var response = std.ArrayList(u8).empty;
    errdefer response.deinit(allocator);
    var buffer: [4096]u8 = undefined;
    while (true) {
        const read_count = stream.read(&buffer) catch |err| switch (err) {
            error.ConnectionResetByPeer => break,
            else => return err,
        };
        if (read_count == 0) break;
        try response.appendSlice(allocator, buffer[0..read_count]);
    }
    return response.toOwnedSlice(allocator);
}

test "JSON nesting deeper than max_json_depth returns -32600 before parsing" {
    const handlers = dispatcher.HandlerRegistry{ .on_method = &successHandler };

    // The envelope object is depth 1, so params nesting of 63 reaches depth 64.
    const at_limit = try nestedParamsRequest(std.testing.allocator, server.DEFAULT_MAX_JSON_DEPTH - 1);
    defer std.testing.allocator.free(at_limit);
    const accepted = (try server.handlePost(std.testing.allocator, at_limit, &handlers)).?;
    defer std.testing.allocator.free(accepted);
    const accepted_parsed = try parseJson(accepted);
    defer accepted_parsed.deinit();
    try std.testing.expect(accepted_parsed.value.object.get("error") == null or
        (try getObjectField(try getObjectField(accepted_parsed.value, "error"), "code")).integer != jsonrpc.envelope.ErrorCode.INVALID_REQUEST);

    const too_deep = try nestedParamsRequest(std.testing.allocator, server.DEFAULT_MAX_JSON_DEPTH);
    defer std.testing.allocator.free(too_deep);
    const rejected = (try server.handlePost(std.testing.allocator, too_deep, &handlers)).?;
    defer std.testing.allocator.free(rejected);
    try expectErrorCode(rejected, jsonrpc.envelope.ErrorCode.INVALID_REQUEST);

    // A nesting bomb far beyond std.json.Stringify's 256-level limit must not panic.
    const bomb = try nestedParamsRequest(std.testing.allocator, 100_000);
    defer std.testing.allocator.free(bomb);
    const bomb_response = (try server.handlePost(std.testing.allocator, bomb, &handlers)).?;
    defer std.testing.allocator.free(bomb_response);
    try expectErrorCode(bomb_response, jsonrpc.envelope.ErrorCode.INVALID_REQUEST);
}

test "JSON value cap rejects a shallow request above the limit" {
    const handlers = dispatcher.HandlerRegistry{ .on_method = &successHandler };
    const body =
        \\{"jsonrpc":"2.0","method":"eth_blockNumber","id":1,"params":[[100,-2,3e4,0,0,0,0,0,0]]}
    ;
    const allocator = std.testing.allocator;
    var response = try server.handleHttpRequestForTestWithOptions(allocator, .{
        .method = .POST,
        .body = body,
        .options = .{ .max_json_values = 15 },
    }, &handlers);
    defer response.deinit(allocator);

    const parsed = try parseJson(response.body.?);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("result") != null);

    var rejected = try server.handleHttpRequestForTestWithOptions(allocator, .{
        .method = .POST,
        .body = body,
        .options = .{ .max_json_values = 14 },
    }, &handlers);
    defer rejected.deinit(allocator);
    try expectErrorCode(rejected.body.?, jsonrpc.envelope.ErrorCode.INVALID_REQUEST);
    const rejected_parsed = try parseJson(rejected.body.?);
    defer rejected_parsed.deinit();
    try std.testing.expect((try getObjectField(rejected_parsed.value, "id")) == .null);
}

test "dev method policy rejects each dev namespace before dispatch" {
    const allocator = std.testing.allocator;
    const handlers = dispatcher.HandlerRegistry{ .on_method = &struct {
        fn handle(_: std.mem.Allocator, _: []const u8, _: ?std.json.Value) anyerror!std.json.Value {
            return .{ .bool = true };
        }
    }.handle };
    for ([_][]const u8{ "anvil_mine", "evm_mine", "hardhat_reset", "zevm_mine", "testing_buildBlockV1" }) |method| {
        const body = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"id\":1,\"params\":[]}}", .{method});
        defer allocator.free(body);

        const accepted = (try server.handlePost(allocator, body, &handlers)).?;
        defer allocator.free(accepted);
        const parsed = try parseJson(accepted);
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("result") != null);

        const response = (try server.handlePostWithPolicy(allocator, body, &handlers, .{
            .allow_dev_methods = false,
        })).?;
        defer allocator.free(response);
        try expectErrorCode(response, jsonrpc.envelope.ErrorCode.METHOD_NOT_FOUND);
    }

    // Read-only light-mode health status stays reachable even when dev mutators are off.
    const light_status = (try server.handlePostWithPolicy(
        allocator,
        "{\"jsonrpc\":\"2.0\",\"method\":\"zevm_lightSyncStatus\",\"id\":1,\"params\":[]}",
        &handlers,
        .{ .allow_dev_methods = false },
    )).?;
    defer allocator.free(light_status);
    const parsed_status = try parseJson(light_status);
    defer parsed_status.deinit();
    try std.testing.expect(parsed_status.value.object.get("result") != null);
}

test "JSON depth scan ignores brackets inside strings and escaped quotes" {
    const shape = server.scanJsonShape("{\"a\":\"[[[[\\\"{{{{\",\"b\":[1,2]}", 64);
    try std.testing.expectEqual(@as(usize, 2), shape.max_depth);
    try std.testing.expect(shape.top_level_array_len == null);

    const batch_shape = server.scanJsonShape("[ {\"x\":\",\"}, {} ,{}]", 64);
    try std.testing.expectEqual(@as(?usize, 3), batch_shape.top_level_array_len);
    try std.testing.expectEqual(@as(?usize, 0), server.scanJsonShape("[ ]", 64).top_level_array_len);
}

test "batch larger than max_batch_size returns a single -32600 error" {
    const handlers = dispatcher.HandlerRegistry{ .on_method = &successHandler };

    const at_limit = try batchRequest(std.testing.allocator, server.DEFAULT_MAX_BATCH_SIZE);
    defer std.testing.allocator.free(at_limit);
    const accepted = (try server.handlePost(std.testing.allocator, at_limit, &handlers)).?;
    defer std.testing.allocator.free(accepted);
    const accepted_parsed = try parseJson(accepted);
    defer accepted_parsed.deinit();
    try std.testing.expectEqual(server.DEFAULT_MAX_BATCH_SIZE, accepted_parsed.value.array.items.len);

    const too_many = try batchRequest(std.testing.allocator, server.DEFAULT_MAX_BATCH_SIZE + 1);
    defer std.testing.allocator.free(too_many);
    const rejected = (try server.handlePost(std.testing.allocator, too_many, &handlers)).?;
    defer std.testing.allocator.free(rejected);
    try expectErrorCode(rejected, jsonrpc.envelope.ErrorCode.INVALID_REQUEST);
}

test "public listener options reject engine_* with -32601 without calling the handler" {
    const handlers = dispatcher.HandlerRegistry{ .on_method = &engineAwareHandler };
    const calls_before = engine_handler_calls.load(.seq_cst);

    var response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"engine_exchangeCapabilities\",\"params\":[[]]}",
        &handlers,
    );
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.ok, response.status);
    try expectErrorCode(response.body.?, jsonrpc.envelope.ErrorCode.METHOD_NOT_FOUND);

    var batch_response = try server.handleHttpRequestForTest(
        std.testing.allocator,
        .POST,
        "[{\"jsonrpc\":\"2.0\",\"method\":\"engine_forkchoiceUpdatedV3\",\"params\":[]},{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"engine_getPayloadV4\",\"params\":[\"0x01\"]}]",
        &handlers,
    );
    defer batch_response.deinit(std.testing.allocator);
    const parsed = try parseJson(batch_response.body.?);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
    const error_object = try getObjectField(parsed.value.array.items[0], "error");
    try std.testing.expectEqual(@as(i64, jsonrpc.envelope.ErrorCode.METHOD_NOT_FOUND), (try getObjectField(error_object, "code")).integer);

    try std.testing.expectEqual(calls_before, engine_handler_calls.load(.seq_cst));

    // Engine listener options reach the handler.
    var engine_response = try server.handleHttpRequestForTestWithOptions(std.testing.allocator, .{
        .method = .POST,
        .body = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"engine_exchangeCapabilities\",\"params\":[[]]}",
        .options = .{ .allow_engine_methods = true },
    }, &handlers);
    defer engine_response.deinit(std.testing.allocator);
    const engine_parsed = try parseJson(engine_response.body.?);
    defer engine_parsed.deinit();
    try std.testing.expectEqual(@as(i64, 99), (try getObjectField(engine_parsed.value, "result")).integer);
    try std.testing.expectEqual(calls_before + 1, engine_handler_calls.load(.seq_cst));
}

test "public TCP listener rejects engine_* with -32601" {
    const handlers = dispatcher.HandlerRegistry{ .on_method = &engineAwareHandler };
    const calls_before = engine_handler_calls.load(.seq_cst);

    var listener = try server.TestListener.init(std.testing.allocator, "127.0.0.1", &handlers);
    defer listener.deinit();
    try listener.start();

    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"engine_newPayloadV4\",\"params\":[]}";
    const request = try std.fmt.allocPrint(
        std.testing.allocator,
        "POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ body.len, body },
    );
    defer std.testing.allocator.free(request);

    const raw = try rawExchange(std.testing.allocator, listener.address(), request);
    defer std.testing.allocator.free(raw);
    const header_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.MissingResponseHead;
    try std.testing.expect(std.mem.startsWith(u8, raw, "HTTP/1.1 200"));
    try expectErrorCode(raw[header_end + 4 ..], jsonrpc.envelope.ErrorCode.METHOD_NOT_FOUND);
    try std.testing.expectEqual(calls_before, engine_handler_calls.load(.seq_cst));
}

test "engine listener requires a 32-byte JWT secret" {
    try std.testing.expectError(
        error.EngineJwtSecretRequired,
        server.validateEngineAuthForTest(.{ .allow_engine_methods = true }),
    );
    try std.testing.expectError(
        error.InsecureEngineJwtSecret,
        server.validateEngineAuthForTest(.{ .allow_engine_methods = true, .jwt_secret = "short" }),
    );

    var secret: [server.ENGINE_JWT_SECRET_BYTES]u8 = undefined;
    std.crypto.random.bytes(&secret);
    try server.validateEngineAuthForTest(.{ .allow_engine_methods = true, .jwt_secret = &secret });
    try server.validateEngineAuthForTest(.{});

    const handlers = dispatcher.HandlerRegistry{};
    try std.testing.expectError(
        error.EngineJwtSecretRequired,
        server.TestListener.initWithLimits(std.testing.allocator, "127.0.0.1", &handlers, .{ .allow_engine_methods = true }),
    );
}

test "JWT iat at i64 extremes does not overflow drift arithmetic" {
    const secret = server.DEFAULT_ENGINE_JWT_SECRET;
    for ([_]i64{ std.math.minInt(i64), std.math.maxInt(i64) }) |iat| {
        const token = try makeJwt(std.testing.allocator, secret, iat);
        defer std.testing.allocator.free(token);
        const authorization = try std.fmt.allocPrint(std.testing.allocator, "Bearer {s}", .{token});
        defer std.testing.allocator.free(authorization);

        for ([_]i64{ std.math.maxInt(i64), std.math.minInt(i64), 1_700_000_000 }) |now| {
            try std.testing.expectEqual(iat == now, try server.validateJwtAuthorizationForTest(
                std.testing.allocator,
                authorization,
                secret,
                now,
                server.DEFAULT_ENGINE_JWT_MAX_TIME_DRIFT_SECONDS,
            ));
        }
    }
}

test "JWT float iat rejects fractional and out-of-range values" {
    try std.testing.expectEqual(@as(?i64, 1_700_000_000), server.floatIatToSecondsForTest(1_700_000_000.0));
    try std.testing.expectEqual(@as(?i64, std.math.minInt(i64)), server.floatIatToSecondsForTest(-9223372036854775808.0));
    try std.testing.expect(server.floatIatToSecondsForTest(9223372036854775808.0) == null);
    try std.testing.expect(server.floatIatToSecondsForTest(1.5) == null);
    try std.testing.expect(server.floatIatToSecondsForTest(std.math.inf(f64)) == null);
    try std.testing.expect(server.floatIatToSecondsForTest(std.math.nan(f64)) == null);
}

test "early HTTP error closes keep-alive connection instead of parsing the unread body" {
    const handlers = dispatcher.HandlerRegistry{ .on_method = &successHandler };
    var listener = try server.TestListener.initWithLimits(std.testing.allocator, "127.0.0.1", &handlers, .{
        .read_timeout_ms = 2_000,
    });
    defer listener.deinit();
    try listener.start();

    // The body is a smuggled second request. A keep-alive server that skipped
    // draining would answer it as a second response.
    const smuggled = "POST / HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 51\r\n\r\n{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_blockNumber\"}";
    const request = try std.fmt.allocPrint(
        std.testing.allocator,
        "POST /not-root HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ smuggled.len, smuggled },
    );
    defer std.testing.allocator.free(request);

    const raw = try rawExchange(std.testing.allocator, listener.address(), request);
    defer std.testing.allocator.free(raw);

    try std.testing.expect(std.mem.startsWith(u8, raw, "HTTP/1.1 404"));
    try std.testing.expect(std.ascii.indexOfIgnoreCase(raw, "connection: close") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, raw, "HTTP/1.1 "));
}

test "CORS preflight returns 204 with allow headers" {
    const handlers = dispatcher.HandlerRegistry{};
    var listener = try server.TestListener.initWithLimits(std.testing.allocator, "127.0.0.1", &handlers, .{ .cors_allow_origin = "*" });
    defer listener.deinit();
    try listener.start();

    const raw = try rawExchange(
        std.testing.allocator,
        listener.address(),
        "OPTIONS / HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: http://example.test\r\nAccess-Control-Request-Method: POST\r\n\r\n",
    );
    defer std.testing.allocator.free(raw);
    try std.testing.expect(std.mem.startsWith(u8, raw, "HTTP/1.1 204"));
    try std.testing.expect(std.ascii.indexOfIgnoreCase(raw, "access-control-allow-origin: *") != null);
    try std.testing.expect(std.ascii.indexOfIgnoreCase(raw, "access-control-allow-methods: POST, OPTIONS") != null);
}

test "listen address accepts localhost and wildcard binds unblock via loopback" {
    const localhost = try server.parseListenAddress("localhost", 8545);
    try std.testing.expect(localhost.eql(std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8545)));

    const wildcard4 = try std.net.Address.parseIp("0.0.0.0", 9000);
    try std.testing.expect(server.connectableAddress(wildcard4).eql(std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 9000)));

    const wildcard6 = try std.net.Address.parseIp("::", 9001);
    const loopback6 = try std.net.Address.parseIp("::1", 9001);
    try std.testing.expect(server.connectableAddress(wildcard6).eql(loopback6));

    const specific = try std.net.Address.parseIp("127.0.0.2", 9002);
    try std.testing.expect(server.connectableAddress(specific).eql(specific));
}

test "accept backoff grows and caps" {
    var backoff: u64 = 0;
    backoff = server.nextAcceptBackoffForTest(backoff);
    try std.testing.expectEqual(@as(u64, 5 * std.time.ns_per_ms), backoff);
    backoff = server.nextAcceptBackoffForTest(backoff);
    try std.testing.expectEqual(@as(u64, 10 * std.time.ns_per_ms), backoff);
    for (0..20) |_| backoff = server.nextAcceptBackoffForTest(backoff);
    try std.testing.expectEqual(@as(u64, 500 * std.time.ns_per_ms), backoff);
}

// ---------------------------------------------------------------------------
// Round 3 HTTP hardening tests.
// ---------------------------------------------------------------------------

test "Host header validation accepts loopback and rejects foreign hosts" {
    try std.testing.expect(server.isAllowedHostHeaderForTest("localhost", "127.0.0.1"));
    try std.testing.expect(server.isAllowedHostHeaderForTest("localhost:8545", "127.0.0.1"));
    try std.testing.expect(server.isAllowedHostHeaderForTest("127.0.0.1", "127.0.0.1"));
    try std.testing.expect(server.isAllowedHostHeaderForTest("127.0.0.1:8545", "127.0.0.1"));
    try std.testing.expect(server.isAllowedHostHeaderForTest("[::1]", "127.0.0.1"));
    try std.testing.expect(server.isAllowedHostHeaderForTest("[::1]:8545", "127.0.0.1"));
    try std.testing.expect(!server.isAllowedHostHeaderForTest("evil.example.com", "127.0.0.1"));
    try std.testing.expect(!server.isAllowedHostHeaderForTest("evil.example.com:8545", "127.0.0.1"));
    try std.testing.expect(!server.isAllowedHostHeaderForTest(null, "127.0.0.1"));
    try std.testing.expect(!server.isAllowedHostHeaderForTest("", "127.0.0.1"));
    // Disabled when validate_host is null.
    try std.testing.expect(server.isAllowedHostHeaderForTest("evil.example.com", null));
    try std.testing.expect(server.isAllowedHostHeaderForTest(null, null));
}

test "sameIp matches addresses regardless of port" {
    const a = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8545);
    const b = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 9999);
    const c = std.net.Address.initIp4(.{ 192, 168, 1, 1 }, 8545);
    try std.testing.expect(server.sameIpForTest(a, b));
    try std.testing.expect(!server.sameIpForTest(a, c));
}

test "POST without Content-Length returns 411" {
    const handlers = dispatcher.HandlerRegistry{ .on_method = &successHandler };
    var listener = try server.TestListener.init(std.testing.allocator, "127.0.0.1", &handlers);
    defer listener.deinit();
    try listener.start();

    const raw = try rawExchange(
        std.testing.allocator,
        listener.address(),
        "POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n\r\n",
    );
    defer std.testing.allocator.free(raw);
    try std.testing.expect(std.mem.startsWith(u8, raw, "HTTP/1.1 411"));
}

test "malformed request head returns 400" {
    const handlers = dispatcher.HandlerRegistry{};
    var listener = try server.TestListener.init(std.testing.allocator, "127.0.0.1", &handlers);
    defer listener.deinit();
    try listener.start();

    const raw = try rawExchange(
        std.testing.allocator,
        listener.address(),
        "INVALID HTTP\r\n\r\n",
    );
    defer std.testing.allocator.free(raw);
    try std.testing.expect(std.mem.startsWith(u8, raw, "HTTP/1.1 400"));
}

test "oversized request head returns 431" {
    const handlers = dispatcher.HandlerRegistry{};
    var listener = try server.TestListener.init(std.testing.allocator, "127.0.0.1", &handlers);
    defer listener.deinit();
    try listener.start();

    const oversized = try std.testing.allocator.alloc(u8, server.MAX_HTTP_HEAD_BYTES + 100);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'A');
    oversized[0] = 'G';
    oversized[1] = 'E';
    oversized[2] = 'T';
    oversized[3] = ' ';

    const raw = try rawExchange(std.testing.allocator, listener.address(), oversized);
    defer std.testing.allocator.free(raw);
    try std.testing.expect(std.mem.startsWith(u8, raw, "HTTP/1.1 431") or std.mem.startsWith(u8, raw, "HTTP/1.1 400"));
}

test "default loopback listener auto-enables host validation and rejects DNS rebinding" {
    const handlers = dispatcher.HandlerRegistry{ .on_method = &successHandler };
    // No explicit validate_host — init auto-populates it for a loopback bind.
    var listener = try server.TestListener.init(std.testing.allocator, "127.0.0.1", &handlers);
    defer listener.deinit();
    try listener.start();

    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_blockNumber\"}";
    const good_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "POST / HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ listener.address().getPort(), body.len, body },
    );
    defer std.testing.allocator.free(good_request);

    const good_raw = try rawExchange(std.testing.allocator, listener.address(), good_request);
    defer std.testing.allocator.free(good_raw);
    try std.testing.expect(std.mem.startsWith(u8, good_raw, "HTTP/1.1 200"));

    const evil_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "POST / HTTP/1.1\r\nHost: evil.com\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ body.len, body },
    );
    defer std.testing.allocator.free(evil_request);

    const evil_raw = try rawExchange(std.testing.allocator, listener.address(), evil_request);
    defer std.testing.allocator.free(evil_raw);
    try std.testing.expect(std.mem.startsWith(u8, evil_raw, "HTTP/1.1 400"));
}

test "Host header validation rejects DNS rebinding on loopback listener" {
    const handlers = dispatcher.HandlerRegistry{ .on_method = &successHandler };
    var listener = try server.TestListener.initWithLimits(std.testing.allocator, "127.0.0.1", &handlers, .{
        .validate_host = "127.0.0.1",
    });
    defer listener.deinit();
    try listener.start();

    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_blockNumber\"}";
    const good_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ body.len, body },
    );
    defer std.testing.allocator.free(good_request);

    const good_raw = try rawExchange(std.testing.allocator, listener.address(), good_request);
    defer std.testing.allocator.free(good_raw);
    try std.testing.expect(std.mem.startsWith(u8, good_raw, "HTTP/1.1 200"));

    const bad_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "POST / HTTP/1.1\r\nHost: evil.example.com\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ body.len, body },
    );
    defer std.testing.allocator.free(bad_request);

    const bad_raw = try rawExchange(std.testing.allocator, listener.address(), bad_request);
    defer std.testing.allocator.free(bad_raw);
    try std.testing.expect(std.mem.startsWith(u8, bad_raw, "HTTP/1.1 400"));
}
