const std = @import("std");
const primitives = @import("primitives");
const crypto = @import("crypto");
const runtime = @import("../../node/runtime.zig");
const tx_submission = @import("tx_submission.zig");
const jsonrpc = @import("jsonrpc");

fn makeRuntime() !runtime.NodeRuntime {
    return runtime.NodeRuntime.init(std.testing.allocator, null);
}

fn makeRawTxParams(hex_str: []const u8) jsonrpc.eth.SendRawTransaction.Params {
    return .{
        .transaction = .{ .value = .{ .string = hex_str } },
    };
}

fn signTestLegacyTx(
    allocator: std.mem.Allocator,
    nonce: u64,
    gas_price: u256,
    gas_limit: u64,
    to: ?primitives.Address,
    value: u256,
    chain_id: u64,
    private_key: crypto.Crypto.PrivateKey,
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

    const signed_tx = try primitives.Transaction.signLegacyTransaction(allocator, unsigned_tx, private_key, chain_id);
    const encoded = try primitives.Transaction.encodeLegacyForSigning(allocator, signed_tx, chain_id);
    return encoded;
}

fn bytesToHexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    return primitives.Hex.bytesToHex(allocator, bytes);
}

// --- Phase 3 Tests ---

test "eth_sendRawTransaction rejects nonce mismatch" {
    var rt = try makeRuntime();
    defer rt.deinit(std.testing.allocator);

    // Bump nonce in state so tx nonce=0 is stale
    try rt.state.setNonce(runtime.DEFAULT_DEV_ACCOUNTS[0], 5);

    // Create a signed tx with nonce=0
    const encoded = try signTestLegacyTx(
        std.testing.allocator,
        0,
        runtime.DEFAULT_GAS_PRICE,
        21_000,
        runtime.DEFAULT_DEV_ACCOUNTS[1],
        1000,
        runtime.DEFAULT_CHAIN_ID,
        runtime.DEFAULT_DEV_PRIVATE_KEYS[0],
    );
    defer std.testing.allocator.free(encoded);

    const hex = try bytesToHexAlloc(std.testing.allocator, encoded);
    defer std.testing.allocator.free(hex);

    const result = tx_submission.handleSendRawTransaction(std.testing.allocator, &rt, makeRawTxParams(hex));
    try std.testing.expectError(tx_submission.TxSubmissionError.NonceMismatch, result);
}

test "eth_sendRawTransaction rejects insufficient balance" {
    var rt = try makeRuntime();
    defer rt.deinit(std.testing.allocator);

    // Set balance to near zero
    try rt.state.setBalance(runtime.DEFAULT_DEV_ACCOUNTS[0], 1);

    const encoded = try signTestLegacyTx(
        std.testing.allocator,
        0,
        runtime.DEFAULT_GAS_PRICE,
        21_000,
        runtime.DEFAULT_DEV_ACCOUNTS[1],
        1_000_000_000_000_000_000, // 1 ETH — more than balance
        runtime.DEFAULT_CHAIN_ID,
        runtime.DEFAULT_DEV_PRIVATE_KEYS[0],
    );
    defer std.testing.allocator.free(encoded);

    const hex = try bytesToHexAlloc(std.testing.allocator, encoded);
    defer std.testing.allocator.free(hex);

    const result = tx_submission.handleSendRawTransaction(std.testing.allocator, &rt, makeRawTxParams(hex));
    try std.testing.expectError(tx_submission.TxSubmissionError.InsufficientBalance, result);
}

test "eth_sendRawTransaction rejects intrinsic gas > gasLimit" {
    var rt = try makeRuntime();
    defer rt.deinit(std.testing.allocator);

    // Gas limit below intrinsic gas (21000)
    const encoded = try signTestLegacyTx(
        std.testing.allocator,
        0,
        runtime.DEFAULT_GAS_PRICE,
        100, // way below 21000
        runtime.DEFAULT_DEV_ACCOUNTS[1],
        1000,
        runtime.DEFAULT_CHAIN_ID,
        runtime.DEFAULT_DEV_PRIVATE_KEYS[0],
    );
    defer std.testing.allocator.free(encoded);

    const hex = try bytesToHexAlloc(std.testing.allocator, encoded);
    defer std.testing.allocator.free(hex);

    const result = tx_submission.handleSendRawTransaction(std.testing.allocator, &rt, makeRawTxParams(hex));
    try std.testing.expectError(tx_submission.TxSubmissionError.IntrinsicGasExceedsLimit, result);
}

test "eth_sendRawTransaction valid tx returns hash and inserts into pool" {
    var rt = try makeRuntime();
    defer rt.deinit(std.testing.allocator);

    // Set mining mode to manual to prevent automine from consuming pool entries
    rt.mining_mode = .manual;

    const encoded = try signTestLegacyTx(
        std.testing.allocator,
        0,
        runtime.DEFAULT_GAS_PRICE,
        21_000,
        runtime.DEFAULT_DEV_ACCOUNTS[1],
        1000,
        runtime.DEFAULT_CHAIN_ID,
        runtime.DEFAULT_DEV_PRIVATE_KEYS[0],
    );
    defer std.testing.allocator.free(encoded);

    const hex = try bytesToHexAlloc(std.testing.allocator, encoded);
    defer std.testing.allocator.free(hex);

    const result = try tx_submission.handleSendRawTransaction(std.testing.allocator, &rt, makeRawTxParams(hex));

    // Should return a non-zero hash
    const zero_hash = [_]u8{0} ** 32;
    try std.testing.expect(!std.mem.eql(u8, &result.value.bytes, &zero_hash));

    // Pool should contain 1 tx
    try std.testing.expectEqual(@as(usize, 1), rt.pool.pendingCount());
}

test "automine: auto mode mines block on valid tx" {
    var rt = try makeRuntime();
    defer rt.deinit(std.testing.allocator);

    // auto mode is default
    try std.testing.expectEqual(runtime.MiningMode.auto, rt.mining_mode);

    const encoded = try signTestLegacyTx(
        std.testing.allocator,
        0,
        runtime.DEFAULT_GAS_PRICE,
        21_000,
        runtime.DEFAULT_DEV_ACCOUNTS[1],
        1000,
        runtime.DEFAULT_CHAIN_ID,
        runtime.DEFAULT_DEV_PRIVATE_KEYS[0],
    );
    defer std.testing.allocator.free(encoded);

    const hex = try bytesToHexAlloc(std.testing.allocator, encoded);
    defer std.testing.allocator.free(hex);

    _ = try tx_submission.handleSendRawTransaction(std.testing.allocator, &rt, makeRawTxParams(hex));

    // Block number should have been incremented by automine
    try std.testing.expectEqual(@as(u64, 1), rt.head_block_number);

    // Pool should be empty after automine
    try std.testing.expectEqual(@as(usize, 0), rt.pool.pendingCount());
}

test "automine: manual mode does not mine" {
    var rt = try makeRuntime();
    defer rt.deinit(std.testing.allocator);

    rt.mining_mode = .manual;

    const encoded = try signTestLegacyTx(
        std.testing.allocator,
        0,
        runtime.DEFAULT_GAS_PRICE,
        21_000,
        runtime.DEFAULT_DEV_ACCOUNTS[1],
        1000,
        runtime.DEFAULT_CHAIN_ID,
        runtime.DEFAULT_DEV_PRIVATE_KEYS[0],
    );
    defer std.testing.allocator.free(encoded);

    const hex = try bytesToHexAlloc(std.testing.allocator, encoded);
    defer std.testing.allocator.free(hex);

    _ = try tx_submission.handleSendRawTransaction(std.testing.allocator, &rt, makeRawTxParams(hex));

    // Block number should NOT have been incremented
    try std.testing.expectEqual(@as(u64, 0), rt.head_block_number);

    // Pool should still have 1 tx
    try std.testing.expectEqual(@as(usize, 1), rt.pool.pendingCount());
}

// --- Phase 5 Tests ---

test "eth_sendTransaction managed account signs and returns hash" {
    var rt = try makeRuntime();
    defer rt.deinit(std.testing.allocator);
    rt.mining_mode = .manual;

    var obj = std.json.ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("from", .{ .string = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" });
    try obj.put("to", .{ .string = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" });
    try obj.put("value", .{ .string = "0x3e8" }); // 1000 wei
    try obj.put("gas", .{ .string = "0x5208" }); // 21000

    const params = jsonrpc.eth.SendTransaction.Params{
        .transaction = .{ .value = .{ .object = obj } },
    };

    const result = try tx_submission.handleSendTransaction(std.testing.allocator, &rt, params);
    const zero_hash = [_]u8{0} ** 32;
    try std.testing.expect(!std.mem.eql(u8, &result.value.bytes, &zero_hash));
    try std.testing.expectEqual(@as(usize, 1), rt.pool.pendingCount());
}

test "eth_sendTransaction unmanaged account returns error" {
    var rt = try makeRuntime();
    defer rt.deinit(std.testing.allocator);

    var obj = std.json.ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("from", .{ .string = "0x0000000000000000000000000000000000000001" });
    try obj.put("to", .{ .string = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" });
    try obj.put("value", .{ .string = "0x3e8" });

    const params = jsonrpc.eth.SendTransaction.Params{
        .transaction = .{ .value = .{ .object = obj } },
    };

    const result = tx_submission.handleSendTransaction(std.testing.allocator, &rt, params);
    try std.testing.expectError(tx_submission.TxSubmissionError.UnmanagedAccount, result);
}
