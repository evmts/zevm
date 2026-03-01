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
