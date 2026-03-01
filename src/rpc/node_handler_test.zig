const std = @import("std");
const primitives = @import("primitives");
const runtime = @import("../node/runtime.zig");
const node_handler = @import("node_handler.zig");

fn parseParams(allocator: std.mem.Allocator, json_text: []const u8) !std.json.Value {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{
        .allocate = .alloc_always,
    });
    return parsed.value;
}

fn callMethod(
    allocator: std.mem.Allocator,
    handler: *node_handler.NodeHandler,
    method_name: []const u8,
    params: ?std.json.Value,
) !std.json.Value {
    return node_handler.NodeHandler.onMethod(handler, allocator, method_name, params);
}

fn signLegacyRawTx(
    allocator: std.mem.Allocator,
    nonce: u64,
    gas_price: u256,
    gas_limit: u64,
    to: ?primitives.Address,
    value: u256,
) ![]u8 {
    const unsigned_tx = primitives.Transaction.LegacyTransaction{
        .nonce = nonce,
        .gas_price = gas_price,
        .gas_limit = gas_limit,
        .to = to,
        .value = value,
        .data = &[_]u8{},
        .v = 0,
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
    };
    const signed_tx = try primitives.Transaction.signLegacyTransaction(
        allocator,
        unsigned_tx,
        runtime.DEFAULT_DEV_PRIVATE_KEYS[0],
        runtime.DEFAULT_CHAIN_ID,
    );
    return primitives.Transaction.encodeLegacyForSigning(allocator, signed_tx, runtime.DEFAULT_CHAIN_ID);
}

test "NodeHandler eth_chainId returns expected dev chain id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var handler = try node_handler.NodeHandler.init(allocator, null);
    defer handler.deinit(allocator);

    const result = try callMethod(allocator, &handler, "eth_chainId", null);

    switch (result) {
        .string => |s| try std.testing.expectEqualStrings("0x7a69", s),
        else => return error.ExpectedStringResult,
    }
}

test "NodeHandler sendRawTransaction then getTransactionByHash returns transaction object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var handler = try node_handler.NodeHandler.init(allocator, null);
    defer handler.deinit(allocator);

    const raw_tx = try signLegacyRawTx(
        allocator,
        0,
        runtime.DEFAULT_GAS_PRICE,
        21_000,
        runtime.DEFAULT_DEV_ACCOUNTS[1],
        1000,
    );
    defer allocator.free(raw_tx);
    const raw_tx_hex = try primitives.Hex.bytesToHex(allocator, raw_tx);
    defer allocator.free(raw_tx_hex);

    var send_params = std.json.Array.init(allocator);
    defer send_params.deinit();
    try send_params.append(.{ .string = raw_tx_hex });

    const send_result = try callMethod(allocator, &handler, "eth_sendRawTransaction", .{ .array = send_params });

    const tx_hash = switch (send_result) {
        .string => |s| s,
        else => return error.ExpectedHashString,
    };

    var get_params = std.json.Array.init(allocator);
    defer get_params.deinit();
    try get_params.append(.{ .string = tx_hash });

    const get_result = try callMethod(allocator, &handler, "eth_getTransactionByHash", .{ .array = get_params });

    const tx_object = switch (get_result) {
        .object => |obj| obj,
        else => return error.ExpectedObject,
    };
    try std.testing.expect(tx_object.get("hash") != null);
    try std.testing.expect(tx_object.get("from") != null);
}

test "NodeHandler hardhat impersonation allows eth_sendTransaction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var handler = try node_handler.NodeHandler.init(allocator, null);
    defer handler.deinit(allocator);

    var impersonate_params = std.json.Array.init(allocator);
    defer impersonate_params.deinit();
    try impersonate_params.append(.{ .string = "0x00000000000000000000000000000000000000aa" });
    _ = try callMethod(allocator, &handler, "hardhat_impersonateAccount", .{ .array = impersonate_params });

    var balance_params = std.json.Array.init(allocator);
    defer balance_params.deinit();
    try balance_params.append(.{ .string = "0x00000000000000000000000000000000000000aa" });
    try balance_params.append(.{ .string = "0x56BC75E2D63100000" }); // 100 ETH
    _ = try callMethod(allocator, &handler, "hardhat_setBalance", .{ .array = balance_params });

    var tx_object = std.json.ObjectMap.init(allocator);
    defer tx_object.deinit();
    try tx_object.put("from", .{ .string = "0x00000000000000000000000000000000000000aa" });
    try tx_object.put("to", .{ .string = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" });
    try tx_object.put("value", .{ .string = "0x1" });
    try tx_object.put("gas", .{ .string = "0x5208" });

    var send_params = std.json.Array.init(allocator);
    defer send_params.deinit();
    try send_params.append(.{ .object = tx_object });

    const send_result = try callMethod(allocator, &handler, "eth_sendTransaction", .{ .array = send_params });

    switch (send_result) {
        .string => |hash| try std.testing.expect(std.mem.startsWith(u8, hash, "0x")),
        else => return error.ExpectedHashString,
    }
}

test "NodeHandler eth_sendTransaction rejects malformed to address" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var handler = try node_handler.NodeHandler.init(allocator, null);
    defer handler.deinit(allocator);

    var tx_object = std.json.ObjectMap.init(allocator);
    defer tx_object.deinit();
    try tx_object.put("from", .{ .string = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" });
    try tx_object.put("to", .{ .string = "0x1234" });
    try tx_object.put("value", .{ .string = "0x1" });

    var send_params = std.json.Array.init(allocator);
    defer send_params.deinit();
    try send_params.append(.{ .object = tx_object });

    try std.testing.expectError(error.InvalidParams, callMethod(allocator, &handler, "eth_sendTransaction", .{ .array = send_params }));
}

test "NodeHandler eth_sendTransaction supports EIP-4844 typed transactions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var handler = try node_handler.NodeHandler.init(allocator, null);
    defer handler.deinit(allocator);

    // Keep tx in pool/index for direct decode assertions.
    var disable_automine_params = std.json.Array.init(allocator);
    defer disable_automine_params.deinit();
    try disable_automine_params.append(.{ .bool = false });
    _ = try callMethod(allocator, &handler, "hardhat_setAutomine", .{ .array = disable_automine_params });

    var blob_hashes = std.json.Array.init(allocator);
    defer blob_hashes.deinit();
    try blob_hashes.append(.{ .string = "0x0100000000000000000000000000000000000000000000000000000000000000" });

    var tx_object = std.json.ObjectMap.init(allocator);
    defer tx_object.deinit();
    try tx_object.put("from", .{ .string = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" });
    try tx_object.put("to", .{ .string = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" });
    try tx_object.put("value", .{ .string = "0x1" });
    try tx_object.put("gas", .{ .string = "0x5208" });
    try tx_object.put("maxPriorityFeePerGas", .{ .string = "0x3b9aca00" });
    try tx_object.put("maxFeePerGas", .{ .string = "0x77359400" });
    try tx_object.put("maxFeePerBlobGas", .{ .string = "0x1" });
    try tx_object.put("blobVersionedHashes", .{ .array = blob_hashes });
    try tx_object.put("type", .{ .string = "0x3" });

    var send_params = std.json.Array.init(allocator);
    defer send_params.deinit();
    try send_params.append(.{ .object = tx_object });

    const send_result = try callMethod(allocator, &handler, "eth_sendTransaction", .{ .array = send_params });
    const tx_hash = switch (send_result) {
        .string => |value| value,
        else => return error.ExpectedStringResult,
    };

    const tx_hash_bytes = primitives.Hex.hexToBytesFixed(32, tx_hash) catch return error.InvalidHexData;
    const record = handler.node_runtime.getTransactionRecord(tx_hash_bytes) orelse return error.ExpectedTransactionRecord;
    const decoded = try primitives.Transaction.decodeRawTransaction(allocator, record.raw);
    defer primitives.Transaction.deinitDecodedTransaction(allocator, decoded);
    try std.testing.expect(decoded == .eip4844);
}

test "NodeHandler eth_sendTransaction supports EIP-7702 typed transactions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var handler = try node_handler.NodeHandler.init(allocator, null);
    defer handler.deinit(allocator);

    var disable_automine_params = std.json.Array.init(allocator);
    defer disable_automine_params.deinit();
    try disable_automine_params.append(.{ .bool = false });
    _ = try callMethod(allocator, &handler, "hardhat_setAutomine", .{ .array = disable_automine_params });

    var authorization_list = std.json.Array.init(allocator);
    defer authorization_list.deinit();

    var tx_object = std.json.ObjectMap.init(allocator);
    defer tx_object.deinit();
    try tx_object.put("from", .{ .string = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" });
    try tx_object.put("to", .{ .string = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" });
    try tx_object.put("value", .{ .string = "0x1" });
    try tx_object.put("gas", .{ .string = "0x5208" });
    try tx_object.put("maxPriorityFeePerGas", .{ .string = "0x3b9aca00" });
    try tx_object.put("maxFeePerGas", .{ .string = "0x77359400" });
    try tx_object.put("authorizationList", .{ .array = authorization_list });
    try tx_object.put("type", .{ .string = "0x4" });

    var send_params = std.json.Array.init(allocator);
    defer send_params.deinit();
    try send_params.append(.{ .object = tx_object });

    const send_result = try callMethod(allocator, &handler, "eth_sendTransaction", .{ .array = send_params });
    const tx_hash = switch (send_result) {
        .string => |value| value,
        else => return error.ExpectedStringResult,
    };

    const tx_hash_bytes = primitives.Hex.hexToBytesFixed(32, tx_hash) catch return error.InvalidHexData;
    const record = handler.node_runtime.getTransactionRecord(tx_hash_bytes) orelse return error.ExpectedTransactionRecord;
    const decoded = try primitives.Transaction.decodeRawTransaction(allocator, record.raw);
    defer primitives.Transaction.deinitDecodedTransaction(allocator, decoded);
    try std.testing.expect(decoded == .eip7702);
}

test "NodeHandler eth_call executes and returns hex data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var handler = try node_handler.NodeHandler.init(allocator, null);
    defer handler.deinit(allocator);

    var tx_object = std.json.ObjectMap.init(allocator);
    defer tx_object.deinit();
    try tx_object.put("from", .{ .string = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" });
    try tx_object.put("to", .{ .string = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" });
    try tx_object.put("data", .{ .string = "0x" });

    var params = std.json.Array.init(allocator);
    defer params.deinit();
    try params.append(.{ .object = tx_object });
    try params.append(.{ .string = "latest" });

    const result = try callMethod(allocator, &handler, "eth_call", .{ .array = params });
    switch (result) {
        .string => |value| try std.testing.expect(std.mem.startsWith(u8, value, "0x")),
        else => return error.ExpectedStringResult,
    }
}

test "NodeHandler eth_estimateGas uses execution search" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var handler = try node_handler.NodeHandler.init(allocator, null);
    defer handler.deinit(allocator);

    var tx_object = std.json.ObjectMap.init(allocator);
    defer tx_object.deinit();
    try tx_object.put("from", .{ .string = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" });
    try tx_object.put("to", .{ .string = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" });
    try tx_object.put("value", .{ .string = "0x1" });

    var params = std.json.Array.init(allocator);
    defer params.deinit();
    try params.append(.{ .object = tx_object });

    const result = try callMethod(allocator, &handler, "eth_estimateGas", .{ .array = params });
    switch (result) {
        .string => |value| try std.testing.expectEqualStrings("0x5208", value),
        else => return error.ExpectedStringResult,
    }
}

test "NodeHandler log filter lifecycle returns array results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var handler = try node_handler.NodeHandler.init(allocator, null);
    defer handler.deinit(allocator);

    var filter_object = std.json.ObjectMap.init(allocator);
    defer filter_object.deinit();

    var new_filter_params = std.json.Array.init(allocator);
    defer new_filter_params.deinit();
    try new_filter_params.append(.{ .object = filter_object });

    const new_filter_result = try callMethod(allocator, &handler, "eth_newFilter", .{ .array = new_filter_params });
    const filter_id = switch (new_filter_result) {
        .string => |value| value,
        else => return error.ExpectedStringResult,
    };

    var get_logs_params = std.json.Array.init(allocator);
    defer get_logs_params.deinit();
    try get_logs_params.append(.{ .string = filter_id });

    const logs_result = try callMethod(allocator, &handler, "eth_getFilterLogs", .{ .array = get_logs_params });
    switch (logs_result) {
        .array => |_| {},
        else => return error.ExpectedArrayResult,
    }
}

test "NodeHandler debug_traceCall returns structured trace result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var handler = try node_handler.NodeHandler.init(allocator, null);
    defer handler.deinit(allocator);

    var tx_object = std.json.ObjectMap.init(allocator);
    defer tx_object.deinit();
    try tx_object.put("from", .{ .string = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" });
    try tx_object.put("to", .{ .string = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" });
    try tx_object.put("data", .{ .string = "0x" });

    var params = std.json.Array.init(allocator);
    defer params.deinit();
    try params.append(.{ .object = tx_object });
    try params.append(.{ .string = "latest" });

    const result = try callMethod(allocator, &handler, "debug_traceCall", .{ .array = params });
    const object = switch (result) {
        .object => |obj| obj,
        else => return error.ExpectedObject,
    };
    try std.testing.expect(object.get("gas") != null);
    try std.testing.expect(object.get("failed") != null);
    try std.testing.expect(object.get("returnValue") != null);
    try std.testing.expect(object.get("structLogs") != null);
}

test "NodeHandler debug_traceTransaction returns structured trace result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var handler = try node_handler.NodeHandler.init(allocator, null);
    defer handler.deinit(allocator);

    const raw_tx = try signLegacyRawTx(
        allocator,
        0,
        runtime.DEFAULT_GAS_PRICE,
        21_000,
        runtime.DEFAULT_DEV_ACCOUNTS[1],
        1000,
    );
    defer allocator.free(raw_tx);
    const raw_tx_hex = try primitives.Hex.bytesToHex(allocator, raw_tx);
    defer allocator.free(raw_tx_hex);

    var send_params = std.json.Array.init(allocator);
    defer send_params.deinit();
    try send_params.append(.{ .string = raw_tx_hex });
    const send_result = try callMethod(allocator, &handler, "eth_sendRawTransaction", .{ .array = send_params });
    const tx_hash = switch (send_result) {
        .string => |value| value,
        else => return error.ExpectedStringResult,
    };

    var trace_params = std.json.Array.init(allocator);
    defer trace_params.deinit();
    try trace_params.append(.{ .string = tx_hash });

    const trace_result = try callMethod(allocator, &handler, "debug_traceTransaction", .{ .array = trace_params });
    const object = switch (trace_result) {
        .object => |obj| obj,
        else => return error.ExpectedObject,
    };
    try std.testing.expect(object.get("gas") != null);
    try std.testing.expect(object.get("failed") != null);
    try std.testing.expect(object.get("returnValue") != null);
    try std.testing.expect(object.get("structLogs") != null);
}

test "NodeHandler debug_traceCall applies trace config flags to struct logs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var handler = try node_handler.NodeHandler.init(allocator, null);
    defer handler.deinit(allocator);

    var set_code_params = std.json.Array.init(allocator);
    defer set_code_params.deinit();
    try set_code_params.append(.{ .string = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" });
    try set_code_params.append(.{ .string = "0x00" });
    _ = try callMethod(allocator, &handler, "hardhat_setCode", .{ .array = set_code_params });

    var tx_object = std.json.ObjectMap.init(allocator);
    defer tx_object.deinit();
    try tx_object.put("from", .{ .string = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" });
    try tx_object.put("to", .{ .string = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" });
    try tx_object.put("data", .{ .string = "0x" });
    try tx_object.put("gas", .{ .string = "0x100000" });

    var config_object = std.json.ObjectMap.init(allocator);
    defer config_object.deinit();
    try config_object.put("disableStack", .{ .bool = true });
    try config_object.put("disableMemory", .{ .bool = true });
    try config_object.put("disableStorage", .{ .bool = true });

    var params = std.json.Array.init(allocator);
    defer params.deinit();
    try params.append(.{ .object = tx_object });
    try params.append(.{ .string = "latest" });
    try params.append(.{ .object = config_object });

    const result = try callMethod(allocator, &handler, "debug_traceCall", .{ .array = params });
    const object = switch (result) {
        .object => |obj| obj,
        else => return error.ExpectedObject,
    };

    const struct_logs_value = object.get("structLogs") orelse return error.MissingField;
    const struct_logs = switch (struct_logs_value) {
        .array => |array| array.items,
        else => return error.ExpectedArrayResult,
    };
    if (struct_logs.len > 0) {
        const first_log_object = switch (struct_logs[0]) {
            .object => |entry| entry,
            else => return error.ExpectedObject,
        };
        try std.testing.expect(first_log_object.get("stack") == null);
        try std.testing.expect(first_log_object.get("memory") == null);
        try std.testing.expect(first_log_object.get("storage") == null);
    }
}

test "NodeHandler eth_subscribe newPendingTransactions emits websocket messages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var handler = try node_handler.NodeHandler.init(allocator, null);
    defer handler.deinit(allocator);

    var subscribe_params = std.json.Array.init(allocator);
    defer subscribe_params.deinit();
    try subscribe_params.append(.{ .string = "newPendingTransactions" });
    const subscribe_result = try callMethod(allocator, &handler, "eth_subscribe", .{ .array = subscribe_params });
    const subscription_id = switch (subscribe_result) {
        .string => |value| value,
        else => return error.ExpectedStringResult,
    };

    var tx_object = std.json.ObjectMap.init(allocator);
    defer tx_object.deinit();
    try tx_object.put("from", .{ .string = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" });
    try tx_object.put("to", .{ .string = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" });
    try tx_object.put("value", .{ .string = "0x1" });
    try tx_object.put("gas", .{ .string = "0x5208" });

    var send_params = std.json.Array.init(allocator);
    defer send_params.deinit();
    try send_params.append(.{ .object = tx_object });
    _ = try callMethod(allocator, &handler, "eth_sendTransaction", .{ .array = send_params });

    const messages = try handler.collectSubscriptionMessages(allocator);
    defer {
        for (messages) |message| allocator.free(message);
        allocator.free(messages);
    }

    var found = false;
    for (messages) |message| {
        if (std.mem.indexOf(u8, message, "\"method\":\"eth_subscription\"") != null and
            std.mem.indexOf(u8, message, subscription_id) != null)
        {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "NodeHandler eth_subscribe newHeads emits websocket messages after mining" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var handler = try node_handler.NodeHandler.init(allocator, null);
    defer handler.deinit(allocator);

    var subscribe_params = std.json.Array.init(allocator);
    defer subscribe_params.deinit();
    try subscribe_params.append(.{ .string = "newHeads" });
    const subscribe_result = try callMethod(allocator, &handler, "eth_subscribe", .{ .array = subscribe_params });
    const subscription_id = switch (subscribe_result) {
        .string => |value| value,
        else => return error.ExpectedStringResult,
    };

    _ = try callMethod(allocator, &handler, "evm_mine", null);

    const messages = try handler.collectSubscriptionMessages(allocator);
    defer {
        for (messages) |message| allocator.free(message);
        allocator.free(messages);
    }

    var found = false;
    for (messages) |message| {
        if (std.mem.indexOf(u8, message, "\"method\":\"eth_subscription\"") != null and
            std.mem.indexOf(u8, message, subscription_id) != null and
            std.mem.indexOf(u8, message, "\"number\"") != null)
        {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "NodeHandler eth_unsubscribe returns true then false for subscription id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var handler = try node_handler.NodeHandler.init(allocator, null);
    defer handler.deinit(allocator);

    var subscribe_params = std.json.Array.init(allocator);
    defer subscribe_params.deinit();
    try subscribe_params.append(.{ .string = "newPendingTransactions" });
    const subscribe_result = try callMethod(allocator, &handler, "eth_subscribe", .{ .array = subscribe_params });
    const subscription_id = switch (subscribe_result) {
        .string => |value| value,
        else => return error.ExpectedStringResult,
    };

    var unsubscribe_params = std.json.Array.init(allocator);
    defer unsubscribe_params.deinit();
    try unsubscribe_params.append(.{ .string = subscription_id });
    const first_result = try callMethod(allocator, &handler, "eth_unsubscribe", .{ .array = unsubscribe_params });
    try std.testing.expect(first_result.bool);

    var unsubscribe_again_params = std.json.Array.init(allocator);
    defer unsubscribe_again_params.deinit();
    try unsubscribe_again_params.append(.{ .string = subscription_id });
    const second_result = try callMethod(allocator, &handler, "eth_unsubscribe", .{ .array = unsubscribe_again_params });
    try std.testing.expect(!second_result.bool);
}

test "NodeHandler setAutomine toggles mining mode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var handler = try node_handler.NodeHandler.init(allocator, null);
    defer handler.deinit(allocator);

    var disable_params = std.json.Array.init(allocator);
    defer disable_params.deinit();
    try disable_params.append(.{ .bool = false });
    _ = try callMethod(allocator, &handler, "hardhat_setAutomine", .{ .array = disable_params });
    try std.testing.expectEqual(runtime.MiningMode.manual, handler.node_runtime.mining_mode);

    var enable_params = std.json.Array.init(allocator);
    defer enable_params.deinit();
    try enable_params.append(.{ .bool = true });
    _ = try callMethod(allocator, &handler, "hardhat_setAutomine", .{ .array = enable_params });
    try std.testing.expectEqual(runtime.MiningMode.auto, handler.node_runtime.mining_mode);
}

test "NodeHandler interval mining tick mines pending transactions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var handler = try node_handler.NodeHandler.init(allocator, null);
    defer handler.deinit(allocator);

    var interval_params = std.json.Array.init(allocator);
    defer interval_params.deinit();
    try interval_params.append(.{ .string = "0x3e8" }); // 1000 ms
    _ = try callMethod(allocator, &handler, "hardhat_setIntervalMining", .{ .array = interval_params });
    try std.testing.expectEqual(runtime.MiningMode.interval, handler.node_runtime.mining_mode);

    const initial_block_number = handler.node_runtime.head_block_number;

    var tx_object = std.json.ObjectMap.init(allocator);
    defer tx_object.deinit();
    try tx_object.put("from", .{ .string = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" });
    try tx_object.put("to", .{ .string = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" });
    try tx_object.put("value", .{ .string = "0x1" });
    try tx_object.put("gas", .{ .string = "0x5208" });

    var send_params = std.json.Array.init(allocator);
    defer send_params.deinit();
    try send_params.append(.{ .object = tx_object });
    _ = try callMethod(allocator, &handler, "eth_sendTransaction", .{ .array = send_params });
    try std.testing.expectEqual(@as(usize, 1), handler.node_runtime.pool.pendingCount());

    handler.last_interval_mine_ns = std.time.nanoTimestamp() - std.time.ns_per_s;
    try handler.maybeMineInterval(allocator);

    try std.testing.expectEqual(@as(usize, 0), handler.node_runtime.pool.pendingCount());
    try std.testing.expectEqual(initial_block_number + 1, handler.node_runtime.head_block_number);
}

test "NodeHandler evm_setBlockGasLimit constrains automine inclusion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var handler = try node_handler.NodeHandler.init(allocator, null);
    defer handler.deinit(allocator);

    var set_limit_params = std.json.Array.init(allocator);
    defer set_limit_params.deinit();
    try set_limit_params.append(.{ .string = "0x4e20" }); // 20_000
    _ = try callMethod(allocator, &handler, "evm_setBlockGasLimit", .{ .array = set_limit_params });

    var tx_object = std.json.ObjectMap.init(allocator);
    defer tx_object.deinit();
    try tx_object.put("from", .{ .string = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" });
    try tx_object.put("to", .{ .string = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" });
    try tx_object.put("value", .{ .string = "0x1" });
    try tx_object.put("gas", .{ .string = "0x5208" }); // 21_000

    var send_params = std.json.Array.init(allocator);
    defer send_params.deinit();
    try send_params.append(.{ .object = tx_object });
    _ = try callMethod(allocator, &handler, "eth_sendTransaction", .{ .array = send_params });

    try std.testing.expectEqual(@as(u64, 0), handler.node_runtime.head_block_number);
    try std.testing.expectEqual(@as(usize, 1), handler.node_runtime.pool.pendingCount());
}

test "NodeHandler evm_revert restores runtime snapshot metadata and mempool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var handler = try node_handler.NodeHandler.init(allocator, null);
    defer handler.deinit(allocator);

    var disable_automine_params = std.json.Array.init(allocator);
    defer disable_automine_params.deinit();
    try disable_automine_params.append(.{ .bool = false });
    _ = try callMethod(allocator, &handler, "hardhat_setAutomine", .{ .array = disable_automine_params });

    const initial_timestamp = handler.node_runtime.current_timestamp;
    const initial_pending_events = handler.node_runtime.pending_tx_events.items.len;
    const initial_block_events = handler.node_runtime.mined_block_events.items.len;

    const snapshot_result = try callMethod(allocator, &handler, "evm_snapshot", .{ .array = std.json.Array.init(allocator) });
    const snapshot_id = switch (snapshot_result) {
        .string => |value| value,
        else => return error.ExpectedStringResult,
    };

    var tx_object = std.json.ObjectMap.init(allocator);
    defer tx_object.deinit();
    try tx_object.put("from", .{ .string = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" });
    try tx_object.put("to", .{ .string = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" });
    try tx_object.put("value", .{ .string = "0x1" });
    try tx_object.put("gas", .{ .string = "0x5208" });

    var send_params = std.json.Array.init(allocator);
    defer send_params.deinit();
    try send_params.append(.{ .object = tx_object });
    const send_result = try callMethod(allocator, &handler, "eth_sendTransaction", .{ .array = send_params });
    const tx_hash = switch (send_result) {
        .string => |value| value,
        else => return error.ExpectedStringResult,
    };

    var increase_time_params = std.json.Array.init(allocator);
    defer increase_time_params.deinit();
    try increase_time_params.append(.{ .integer = 60 });
    _ = try callMethod(allocator, &handler, "evm_increaseTime", .{ .array = increase_time_params });
    try std.testing.expect(handler.node_runtime.current_timestamp > initial_timestamp);

    try std.testing.expectEqual(@as(usize, 1), handler.node_runtime.pool.pendingCount());

    var revert_params = std.json.Array.init(allocator);
    defer revert_params.deinit();
    try revert_params.append(.{ .string = snapshot_id });
    const revert_result = try callMethod(allocator, &handler, "evm_revert", .{ .array = revert_params });
    try std.testing.expect(revert_result.bool);

    try std.testing.expectEqual(@as(usize, 0), handler.node_runtime.pool.pendingCount());
    try std.testing.expectEqual(initial_timestamp, handler.node_runtime.current_timestamp);
    try std.testing.expectEqual(initial_pending_events, handler.node_runtime.pending_tx_events.items.len);
    try std.testing.expectEqual(initial_block_events, handler.node_runtime.mined_block_events.items.len);

    const tx_hash_bytes = primitives.Hex.hexToBytesFixed(32, tx_hash) catch return error.InvalidHexData;
    try std.testing.expect(handler.node_runtime.getTransactionRecord(tx_hash_bytes) == null);
}

test "NodeHandler evm_setNextBlockTimestamp applies on next mined block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var handler = try node_handler.NodeHandler.init(allocator, null);
    defer handler.deinit(allocator);

    const target_timestamp = handler.node_runtime.current_timestamp + 1234;

    var set_params = std.json.Array.init(allocator);
    defer set_params.deinit();
    try set_params.append(.{ .integer = @intCast(target_timestamp) });
    const set_result = try callMethod(allocator, &handler, "evm_setNextBlockTimestamp", .{ .array = set_params });
    try std.testing.expect(set_result.bool);

    _ = try callMethod(allocator, &handler, "evm_mine", null);
    try std.testing.expectEqual(target_timestamp, handler.node_runtime.current_timestamp);
}

test "NodeHandler hardhat_setPrevRandao updates runtime value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var handler = try node_handler.NodeHandler.init(allocator, null);
    defer handler.deinit(allocator);

    var params = std.json.Array.init(allocator);
    defer params.deinit();
    try params.append(.{ .string = "0x42" });

    const result = try callMethod(allocator, &handler, "hardhat_setPrevRandao", .{ .array = params });
    try std.testing.expect(result.bool);
    try std.testing.expectEqual(@as(u256, 0x42), handler.node_runtime.prev_randao);
}

test "NodeHandler hardhat_mine mines requested number of blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var handler = try node_handler.NodeHandler.init(allocator, null);
    defer handler.deinit(allocator);

    const initial = handler.node_runtime.head_block_number;
    var mine_params = std.json.Array.init(allocator);
    defer mine_params.deinit();
    try mine_params.append(.{ .string = "0x3" });

    _ = try callMethod(allocator, &handler, "hardhat_mine", .{ .array = mine_params });
    try std.testing.expectEqual(initial + 3, handler.node_runtime.head_block_number);
}

test "NodeHandler block filter returns mined block hashes via eth_getFilterChanges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var handler = try node_handler.NodeHandler.init(allocator, null);
    defer handler.deinit(allocator);

    const create_result = try callMethod(allocator, &handler, "eth_newBlockFilter", .{ .array = std.json.Array.init(allocator) });
    const filter_id = switch (create_result) {
        .string => |value| value,
        else => return error.ExpectedStringResult,
    };

    _ = try callMethod(allocator, &handler, "evm_mine", null);

    var changes_params = std.json.Array.init(allocator);
    defer changes_params.deinit();
    try changes_params.append(.{ .string = filter_id });
    const changes_result = try callMethod(allocator, &handler, "eth_getFilterChanges", .{ .array = changes_params });
    const changes = switch (changes_result) {
        .array => |array| array.items,
        else => return error.ExpectedArrayResult,
    };

    try std.testing.expectEqual(@as(usize, 1), changes.len);
    switch (changes[0]) {
        .string => |value| try std.testing.expect(std.mem.startsWith(u8, value, "0x")),
        else => return error.ExpectedStringResult,
    }

    var second_params = std.json.Array.init(allocator);
    defer second_params.deinit();
    try second_params.append(.{ .string = filter_id });
    const second_result = try callMethod(allocator, &handler, "eth_getFilterChanges", .{ .array = second_params });
    const second_changes = switch (second_result) {
        .array => |array| array.items,
        else => return error.ExpectedArrayResult,
    };
    try std.testing.expectEqual(@as(usize, 0), second_changes.len);
}

test "NodeHandler pending filter returns pending tx hashes via eth_getFilterChanges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var handler = try node_handler.NodeHandler.init(allocator, null);
    defer handler.deinit(allocator);

    var disable_automine_params = std.json.Array.init(allocator);
    defer disable_automine_params.deinit();
    try disable_automine_params.append(.{ .bool = false });
    _ = try callMethod(allocator, &handler, "hardhat_setAutomine", .{ .array = disable_automine_params });

    const create_result = try callMethod(allocator, &handler, "eth_newPendingTransactionFilter", .{ .array = std.json.Array.init(allocator) });
    const filter_id = switch (create_result) {
        .string => |value| value,
        else => return error.ExpectedStringResult,
    };

    var tx_object = std.json.ObjectMap.init(allocator);
    defer tx_object.deinit();
    try tx_object.put("from", .{ .string = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" });
    try tx_object.put("to", .{ .string = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" });
    try tx_object.put("value", .{ .string = "0x1" });
    try tx_object.put("gas", .{ .string = "0x5208" });

    var send_params = std.json.Array.init(allocator);
    defer send_params.deinit();
    try send_params.append(.{ .object = tx_object });
    const tx_result = try callMethod(allocator, &handler, "eth_sendTransaction", .{ .array = send_params });
    const tx_hash = switch (tx_result) {
        .string => |value| value,
        else => return error.ExpectedStringResult,
    };

    var changes_params = std.json.Array.init(allocator);
    defer changes_params.deinit();
    try changes_params.append(.{ .string = filter_id });
    const changes_result = try callMethod(allocator, &handler, "eth_getFilterChanges", .{ .array = changes_params });
    const changes = switch (changes_result) {
        .array => |array| array.items,
        else => return error.ExpectedArrayResult,
    };
    try std.testing.expectEqual(@as(usize, 1), changes.len);
    switch (changes[0]) {
        .string => |value| try std.testing.expectEqualStrings(tx_hash, value),
        else => return error.ExpectedStringResult,
    }

    var second_params = std.json.Array.init(allocator);
    defer second_params.deinit();
    try second_params.append(.{ .string = filter_id });
    const second_result = try callMethod(allocator, &handler, "eth_getFilterChanges", .{ .array = second_params });
    const second_changes = switch (second_result) {
        .array => |array| array.items,
        else => return error.ExpectedArrayResult,
    };
    try std.testing.expectEqual(@as(usize, 0), second_changes.len);
}

test "NodeHandler eth_uninstallFilter returns true then false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var handler = try node_handler.NodeHandler.init(allocator, null);
    defer handler.deinit(allocator);

    var filter_object = std.json.ObjectMap.init(allocator);
    defer filter_object.deinit();
    var create_params = std.json.Array.init(allocator);
    defer create_params.deinit();
    try create_params.append(.{ .object = filter_object });
    const create_result = try callMethod(allocator, &handler, "eth_newFilter", .{ .array = create_params });
    const filter_id = switch (create_result) {
        .string => |value| value,
        else => return error.ExpectedStringResult,
    };

    var remove_params = std.json.Array.init(allocator);
    defer remove_params.deinit();
    try remove_params.append(.{ .string = filter_id });
    const first_remove = try callMethod(allocator, &handler, "eth_uninstallFilter", .{ .array = remove_params });
    try std.testing.expect(first_remove.bool);

    var second_remove_params = std.json.Array.init(allocator);
    defer second_remove_params.deinit();
    try second_remove_params.append(.{ .string = filter_id });
    const second_remove = try callMethod(allocator, &handler, "eth_uninstallFilter", .{ .array = second_remove_params });
    try std.testing.expect(!second_remove.bool);
}

test "NodeHandler automine aliases toggle mining mode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var handler = try node_handler.NodeHandler.init(allocator, null);
    defer handler.deinit(allocator);

    var disable_params = std.json.Array.init(allocator);
    defer disable_params.deinit();
    try disable_params.append(.{ .bool = false });
    _ = try callMethod(allocator, &handler, "evm_setAutomine", .{ .array = disable_params });
    try std.testing.expectEqual(runtime.MiningMode.manual, handler.node_runtime.mining_mode);

    var enable_params = std.json.Array.init(allocator);
    defer enable_params.deinit();
    try enable_params.append(.{ .bool = true });
    _ = try callMethod(allocator, &handler, "anvil_setAutomine", .{ .array = enable_params });
    try std.testing.expectEqual(runtime.MiningMode.auto, handler.node_runtime.mining_mode);
}

test "NodeHandler interval mining aliases set and clear interval mode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var handler = try node_handler.NodeHandler.init(allocator, null);
    defer handler.deinit(allocator);

    var set_params = std.json.Array.init(allocator);
    defer set_params.deinit();
    try set_params.append(.{ .string = "0x3e8" });
    _ = try callMethod(allocator, &handler, "anvil_setIntervalMining", .{ .array = set_params });
    try std.testing.expectEqual(runtime.MiningMode.interval, handler.node_runtime.mining_mode);
    try std.testing.expectEqual(@as(u64, 1), handler.node_runtime.interval_seconds);

    var clear_params = std.json.Array.init(allocator);
    defer clear_params.deinit();
    try clear_params.append(.{ .string = "0x0" });
    _ = try callMethod(allocator, &handler, "evm_setIntervalMining", .{ .array = clear_params });
    try std.testing.expectEqual(runtime.MiningMode.manual, handler.node_runtime.mining_mode);
}

test "NodeHandler reverting old snapshot invalidates newer snapshots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var handler = try node_handler.NodeHandler.init(allocator, null);
    defer handler.deinit(allocator);

    const initial_timestamp = handler.node_runtime.current_timestamp;
    const snapshot_1 = try callMethod(allocator, &handler, "evm_snapshot", .{ .array = std.json.Array.init(allocator) });
    const snapshot_1_id = switch (snapshot_1) {
        .string => |value| value,
        else => return error.ExpectedStringResult,
    };

    var increase_1_params = std.json.Array.init(allocator);
    defer increase_1_params.deinit();
    try increase_1_params.append(.{ .integer = 10 });
    _ = try callMethod(allocator, &handler, "evm_increaseTime", .{ .array = increase_1_params });

    const snapshot_2 = try callMethod(allocator, &handler, "evm_snapshot", .{ .array = std.json.Array.init(allocator) });
    const snapshot_2_id = switch (snapshot_2) {
        .string => |value| value,
        else => return error.ExpectedStringResult,
    };

    var increase_2_params = std.json.Array.init(allocator);
    defer increase_2_params.deinit();
    try increase_2_params.append(.{ .integer = 20 });
    _ = try callMethod(allocator, &handler, "evm_increaseTime", .{ .array = increase_2_params });

    var revert_1_params = std.json.Array.init(allocator);
    defer revert_1_params.deinit();
    try revert_1_params.append(.{ .string = snapshot_1_id });
    const revert_1 = try callMethod(allocator, &handler, "evm_revert", .{ .array = revert_1_params });
    try std.testing.expect(revert_1.bool);
    try std.testing.expectEqual(initial_timestamp, handler.node_runtime.current_timestamp);

    var revert_2_params = std.json.Array.init(allocator);
    defer revert_2_params.deinit();
    try revert_2_params.append(.{ .string = snapshot_2_id });
    const revert_2 = try callMethod(allocator, &handler, "evm_revert", .{ .array = revert_2_params });
    try std.testing.expect(!revert_2.bool);
}
