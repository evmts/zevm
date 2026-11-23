const std = @import("std");
const primitives = @import("primitives");
const crypto = @import("crypto");
const genesis = @import("../../genesis.zig");
const mining = @import("../../mining.zig");
const runtime = @import("../../node/runtime.zig");
const block_queries = @import("../block_queries.zig");
const tx_submission = @import("tx_submission.zig");
const txpool_handlers = @import("txpool.zig");
const tx_encoding = @import("../../transaction_encoding.zig");
const tx_processor = @import("../../tx_processor.zig");
const txpool = @import("../../txpool.zig");
const jsonrpc = @import("jsonrpc");
const dispatcher = @import("../dispatcher.zig");
const dispatch_wiring = @import("../dispatch_wiring.zig");
const server = @import("../server.zig");

fn makeRuntime() !runtime.NodeRuntime {
    return runtime.NodeRuntime.init(std.testing.allocator, null);
}

fn parseAddr(comptime hex: *const [42]u8) primitives.Address {
    var out: [20]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex[2..]) catch unreachable;
    return .{ .bytes = out };
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

    const signed_tx = try tx_encoding.signLegacyTransaction(allocator, unsigned_tx, private_key, chain_id);
    const encoded = try tx_encoding.encodeLegacyTransactionEnvelope(allocator, signed_tx);
    return encoded;
}

fn bytesToHexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    return primitives.Hex.bytesToHex(allocator, bytes);
}

fn expectObject(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.ExpectedObject,
    };
}

fn field(obj: std.json.ObjectMap, key: []const u8) !std.json.Value {
    return obj.get(key) orelse error.MissingField;
}

// --- Phase 3 Tests ---

test "eth_sendRawTransaction rejects nonce mismatch" {
    var rt = try makeRuntime();
    defer rt.deinit();

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
        genesis.DEV_ACCOUNTS[0].private_key,
    );
    defer std.testing.allocator.free(encoded);

    const hex = try bytesToHexAlloc(std.testing.allocator, encoded);
    defer std.testing.allocator.free(hex);

    const result = tx_submission.handleSendRawTransaction(std.testing.allocator, &rt, makeRawTxParams(hex));
    try std.testing.expectError(tx_submission.TxSubmissionError.NonceMismatch, result);
}

test "eth_sendRawTransaction rejects insufficient balance" {
    var rt = try makeRuntime();
    defer rt.deinit();

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
        genesis.DEV_ACCOUNTS[0].private_key,
    );
    defer std.testing.allocator.free(encoded);

    const hex = try bytesToHexAlloc(std.testing.allocator, encoded);
    defer std.testing.allocator.free(hex);

    const result = tx_submission.handleSendRawTransaction(std.testing.allocator, &rt, makeRawTxParams(hex));
    try std.testing.expectError(tx_submission.TxSubmissionError.InsufficientBalance, result);
}

test "eth_sendRawTransaction accepts gas price below advertised gasPrice" {
    var rt = try makeRuntime();
    defer rt.deinit();
    try rt.setMiningConfig(.manual);
    rt.gas_price = runtime.DEFAULT_GAS_PRICE + 1;

    const encoded = try signTestLegacyTx(
        std.testing.allocator,
        0,
        runtime.DEFAULT_GAS_PRICE,
        21_000,
        runtime.DEFAULT_DEV_ACCOUNTS[1],
        1000,
        runtime.DEFAULT_CHAIN_ID,
        genesis.DEV_ACCOUNTS[0].private_key,
    );
    defer std.testing.allocator.free(encoded);

    const hex = try bytesToHexAlloc(std.testing.allocator, encoded);
    defer std.testing.allocator.free(hex);

    _ = try tx_submission.handleSendRawTransaction(std.testing.allocator, &rt, makeRawTxParams(hex));
    try std.testing.expectEqual(@as(usize, 1), rt.pool.items().len);
}

test "eth_sendRawTransaction rejects intrinsic gas > gasLimit" {
    var rt = try makeRuntime();
    defer rt.deinit();

    // Gas limit below intrinsic gas (21000)
    const encoded = try signTestLegacyTx(
        std.testing.allocator,
        0,
        runtime.DEFAULT_GAS_PRICE,
        100, // way below 21000
        runtime.DEFAULT_DEV_ACCOUNTS[1],
        1000,
        runtime.DEFAULT_CHAIN_ID,
        genesis.DEV_ACCOUNTS[0].private_key,
    );
    defer std.testing.allocator.free(encoded);

    const hex = try bytesToHexAlloc(std.testing.allocator, encoded);
    defer std.testing.allocator.free(hex);

    const result = tx_submission.handleSendRawTransaction(std.testing.allocator, &rt, makeRawTxParams(hex));
    try std.testing.expectError(tx_submission.TxSubmissionError.IntrinsicGasExceedsLimit, result);
}

test "eth_sendRawTransaction valid tx returns hash and inserts into pool" {
    var rt = try makeRuntime();
    defer rt.deinit();

    // Set mining mode to manual to prevent automine from consuming pool entries
    try rt.setMiningConfig(.manual);

    const encoded = try signTestLegacyTx(
        std.testing.allocator,
        0,
        runtime.DEFAULT_GAS_PRICE,
        21_000,
        runtime.DEFAULT_DEV_ACCOUNTS[1],
        1000,
        runtime.DEFAULT_CHAIN_ID,
        genesis.DEV_ACCOUNTS[0].private_key,
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

test "eth_sendRawTransaction queues future nonce without automining" {
    var rt = try makeRuntime();
    defer rt.deinit();

    const encoded = try signTestLegacyTx(
        std.testing.allocator,
        2,
        runtime.DEFAULT_GAS_PRICE,
        21_000,
        runtime.DEFAULT_DEV_ACCOUNTS[1],
        1000,
        runtime.DEFAULT_CHAIN_ID,
        genesis.DEV_ACCOUNTS[0].private_key,
    );
    defer std.testing.allocator.free(encoded);

    const hex = try bytesToHexAlloc(std.testing.allocator, encoded);
    defer std.testing.allocator.free(hex);

    _ = try tx_submission.handleSendRawTransaction(std.testing.allocator, &rt, makeRawTxParams(hex));

    try std.testing.expectEqual(@as(u64, 0), rt.head_block_number);
    try std.testing.expectEqual(@as(usize, 0), rt.pool.pendingCount());
    try std.testing.expectEqual(@as(usize, 1), rt.pool.queuedCount());
    try std.testing.expectEqual(@as(u64, 2), rt.pool.items()[0].nonce);
}

test "eth_sendRawTransaction enforces replacement pricing" {
    var rt = try makeRuntime();
    defer rt.deinit();
    try rt.setMiningConfig(.manual);

    const first = try signTestLegacyTx(
        std.testing.allocator,
        0,
        runtime.DEFAULT_GAS_PRICE,
        21_000,
        runtime.DEFAULT_DEV_ACCOUNTS[1],
        1000,
        runtime.DEFAULT_CHAIN_ID,
        genesis.DEV_ACCOUNTS[0].private_key,
    );
    defer std.testing.allocator.free(first);

    const first_hex = try bytesToHexAlloc(std.testing.allocator, first);
    defer std.testing.allocator.free(first_hex);

    const first_hash = (try tx_submission.handleSendRawTransaction(std.testing.allocator, &rt, makeRawTxParams(first_hex))).value.bytes;

    const duplicate = try signTestLegacyTx(
        std.testing.allocator,
        0,
        runtime.DEFAULT_GAS_PRICE,
        21_000,
        runtime.DEFAULT_DEV_ACCOUNTS[1],
        1000,
        runtime.DEFAULT_CHAIN_ID,
        genesis.DEV_ACCOUNTS[0].private_key,
    );
    defer std.testing.allocator.free(duplicate);

    const duplicate_hex = try bytesToHexAlloc(std.testing.allocator, duplicate);
    defer std.testing.allocator.free(duplicate_hex);

    const duplicate_hash = (try tx_submission.handleSendRawTransaction(std.testing.allocator, &rt, makeRawTxParams(duplicate_hex))).value.bytes;
    try std.testing.expectEqualSlices(u8, &first_hash, &duplicate_hash);

    const same_price = try signTestLegacyTx(
        std.testing.allocator,
        0,
        runtime.DEFAULT_GAS_PRICE,
        21_000,
        runtime.DEFAULT_DEV_ACCOUNTS[1],
        1001,
        runtime.DEFAULT_CHAIN_ID,
        genesis.DEV_ACCOUNTS[0].private_key,
    );
    defer std.testing.allocator.free(same_price);

    const same_price_hex = try bytesToHexAlloc(std.testing.allocator, same_price);
    defer std.testing.allocator.free(same_price_hex);

    try std.testing.expectError(
        tx_submission.TxSubmissionError.PoolInsertFailed,
        tx_submission.handleSendRawTransaction(std.testing.allocator, &rt, makeRawTxParams(same_price_hex)),
    );

    // A 1 wei nudge is below the 10% replacement bump.
    const nudge = try signTestLegacyTx(
        std.testing.allocator,
        0,
        runtime.DEFAULT_GAS_PRICE + 1,
        21_000,
        runtime.DEFAULT_DEV_ACCOUNTS[1],
        1000,
        runtime.DEFAULT_CHAIN_ID,
        genesis.DEV_ACCOUNTS[0].private_key,
    );
    defer std.testing.allocator.free(nudge);
    const nudge_hex = try bytesToHexAlloc(std.testing.allocator, nudge);
    defer std.testing.allocator.free(nudge_hex);
    try std.testing.expectError(
        tx_submission.TxSubmissionError.PoolInsertFailed,
        tx_submission.handleSendRawTransaction(std.testing.allocator, &rt, makeRawTxParams(nudge_hex)),
    );

    const replacement_price = runtime.DEFAULT_GAS_PRICE + runtime.DEFAULT_GAS_PRICE / 10;
    const replacement = try signTestLegacyTx(
        std.testing.allocator,
        0,
        replacement_price,
        21_000,
        runtime.DEFAULT_DEV_ACCOUNTS[1],
        1000,
        runtime.DEFAULT_CHAIN_ID,
        genesis.DEV_ACCOUNTS[0].private_key,
    );
    defer std.testing.allocator.free(replacement);

    const replacement_hex = try bytesToHexAlloc(std.testing.allocator, replacement);
    defer std.testing.allocator.free(replacement_hex);

    const replacement_hash = (try tx_submission.handleSendRawTransaction(std.testing.allocator, &rt, makeRawTxParams(replacement_hex))).value.bytes;

    try std.testing.expectEqual(@as(usize, 1), rt.pool.pendingCount());
    try std.testing.expect(!std.mem.eql(u8, &first_hash, &replacement_hash));
    try std.testing.expectEqual(replacement_price, rt.pool.items()[0].max_fee_per_gas);
    try std.testing.expectEqualSlices(u8, &replacement_hash, &rt.pool.items()[0].hash);
}

test "automine: auto mode mines block on valid tx" {
    var rt = try makeRuntime();
    defer rt.deinit();

    // auto mode is default
    try std.testing.expectEqual(mining.MiningConfigType.auto, std.meta.activeTag(rt.mining_config));

    const encoded = try signTestLegacyTx(
        std.testing.allocator,
        0,
        runtime.DEFAULT_GAS_PRICE,
        21_000,
        runtime.DEFAULT_DEV_ACCOUNTS[1],
        1000,
        runtime.DEFAULT_CHAIN_ID,
        genesis.DEV_ACCOUNTS[0].private_key,
    );
    defer std.testing.allocator.free(encoded);

    const hex = try bytesToHexAlloc(std.testing.allocator, encoded);
    defer std.testing.allocator.free(hex);

    const result = try tx_submission.handleSendRawTransaction(std.testing.allocator, &rt, makeRawTxParams(hex));

    // Block number should have been incremented by automine
    try std.testing.expectEqual(@as(u64, 1), rt.head_block_number);

    // Pool should be empty after automine
    try std.testing.expectEqual(@as(usize, 0), rt.pool.pendingCount());

    const block = (try rt.blockchain.getBlockByNumber(1)).?;
    try std.testing.expectEqual(@as(usize, 1), block.body.transactions.len);
    try std.testing.expectEqualSlices(u8, encoded, block.body.transactions[0].raw);

    const receipt = rt.receipt_index.getByTxHash(result.value.bytes).?;
    try std.testing.expectEqual(@as(u64, 1), receipt.block_number);
    try std.testing.expectEqualSlices(u8, &block.hash, &receipt.block_hash);
    try std.testing.expectEqualSlices(u8, &result.value.bytes, &receipt.transaction_hash);
}

test "automine: manual mode does not mine" {
    var rt = try makeRuntime();
    defer rt.deinit();

    try rt.setMiningConfig(.manual);

    const encoded = try signTestLegacyTx(
        std.testing.allocator,
        0,
        runtime.DEFAULT_GAS_PRICE,
        21_000,
        runtime.DEFAULT_DEV_ACCOUNTS[1],
        1000,
        runtime.DEFAULT_CHAIN_ID,
        genesis.DEV_ACCOUNTS[0].private_key,
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
    defer rt.deinit();
    try rt.setMiningConfig(.manual);

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

    const pooled = rt.pool.items()[0];
    try std.testing.expectEqualSlices(u8, &result.value.bytes, &pooled.hash);

    const decoded = try tx_encoding.decodeLegacyEnvelope(pooled.raw);
    try std.testing.expectEqual(@as(u64, 0), decoded.nonce);
    try std.testing.expectEqual(runtime.DEFAULT_GAS_PRICE, decoded.gas_price);
    try std.testing.expectEqual(@as(u64, 21_000), decoded.gas_limit);
    try std.testing.expectEqual(runtime.DEFAULT_DEV_ACCOUNTS[1], decoded.to.?);
    try std.testing.expectEqual(@as(u256, 1000), decoded.value);
    try std.testing.expectEqual(runtime.DEFAULT_CHAIN_ID, tx_encoding.legacyChainId(decoded).?);
    try std.testing.expect(decoded.v == runtime.DEFAULT_CHAIN_ID * 2 + 35 or decoded.v == runtime.DEFAULT_CHAIN_ID * 2 + 36);

    const sender = try tx_encoding.recoverLegacySender(std.testing.allocator, decoded);
    try std.testing.expectEqual(runtime.DEFAULT_DEV_ACCOUNTS[0], sender);

    const canonical = try tx_encoding.encodeLegacyTransactionEnvelope(std.testing.allocator, decoded);
    defer std.testing.allocator.free(canonical);
    try std.testing.expectEqualSlices(u8, canonical, pooled.raw);
    const canonical_hash = tx_encoding.transactionHash(canonical);
    try std.testing.expectEqualSlices(u8, &canonical_hash, &result.value.bytes);

    const signing_preimage = try tx_encoding.encodeLegacySigningPreimage(
        std.testing.allocator,
        decoded,
        tx_encoding.legacyChainId(decoded),
    );
    defer std.testing.allocator.free(signing_preimage);
    try std.testing.expect(!std.mem.eql(u8, signing_preimage, pooled.raw));
}

test "eth_sendTransaction uses runtime hardfork policy for intrinsic gas" {
    var pre_shanghai_cfg = runtime.DEFAULT_DEV_HARDFORK_CONFIG;
    pre_shanghai_cfg.shanghai_timestamp = std.math.maxInt(u64);
    pre_shanghai_cfg.cancun_timestamp = std.math.maxInt(u64);
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{
        .hardfork_config = pre_shanghai_cfg,
    });
    defer rt.deinit();
    try rt.setMiningConfig(.manual);

    // STOP followed by padding is valid initcode, so estimation reaches the
    // intrinsic floor and still distinguishes pre-Shanghai initcode pricing.
    const initcode_bytes = [_]u8{0x00} ** 33;
    const initcode_hex = "0x000000000000000000000000000000000000000000000000000000000000000000";
    try std.testing.expectEqual(@as(usize, initcode_bytes.len), (initcode_hex.len - 2) / 2);

    var obj = std.json.ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("from", .{ .string = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" });
    try obj.put("data", .{ .string = initcode_hex });

    const params = jsonrpc.eth.SendTransaction.Params{
        .transaction = .{ .value = .{ .object = obj } },
    };

    _ = try tx_submission.handleSendTransaction(std.testing.allocator, &rt, params);

    const expected = tx_processor.intrinsicGasForFork(&initcode_bytes, true, .MERGE);
    try std.testing.expectEqual(expected, rt.pool.items()[0].gas_limit);
}

test "eth_sendTransaction queues explicit future nonce" {
    var rt = try makeRuntime();
    defer rt.deinit();

    var obj = std.json.ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("from", .{ .string = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" });
    try obj.put("to", .{ .string = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" });
    try obj.put("nonce", .{ .string = "0x2" });
    try obj.put("value", .{ .string = "0x3e8" });
    try obj.put("gas", .{ .string = "0x5208" });

    const params = jsonrpc.eth.SendTransaction.Params{
        .transaction = .{ .value = .{ .object = obj } },
    };

    _ = try tx_submission.handleSendTransaction(std.testing.allocator, &rt, params);

    try std.testing.expectEqual(@as(u64, 0), rt.head_block_number);
    try std.testing.expectEqual(@as(usize, 0), rt.pool.pendingCount());
    try std.testing.expectEqual(@as(usize, 1), rt.pool.queuedCount());
    try std.testing.expectEqual(@as(u64, 2), rt.pool.items()[0].nonce);
}

test "eth_sendTransaction rejects explicit gas price below runtime minimum" {
    var rt = try makeRuntime();
    defer rt.deinit();
    try rt.setMiningConfig(.manual);
    rt.gas_price = runtime.DEFAULT_GAS_PRICE + 1;

    var obj = std.json.ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("from", .{ .string = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" });
    try obj.put("to", .{ .string = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" });
    try obj.put("gasPrice", .{ .string = "0x3b9aca00" });
    try obj.put("gas", .{ .string = "0x5208" });

    const params = jsonrpc.eth.SendTransaction.Params{
        .transaction = .{ .value = .{ .object = obj } },
    };

    const result = tx_submission.handleSendTransaction(std.testing.allocator, &rt, params);
    try std.testing.expectError(tx_submission.TxSubmissionError.GasPriceBelowMinimum, result);
}

test "eth_sendTransaction accepts matching data aliases without leaking parser buffers" {
    var rt = try makeRuntime();
    defer rt.deinit();
    try rt.setMiningConfig(.manual);

    var obj = std.json.ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("from", .{ .string = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" });
    try obj.put("to", .{ .string = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" });
    try obj.put("gas", .{ .string = "0x5218" });
    try obj.put("data", .{ .string = "0xab" });
    try obj.put("input", .{ .string = "0xab" });

    const params = jsonrpc.eth.SendTransaction.Params{
        .transaction = .{ .value = .{ .object = obj } },
    };

    _ = try tx_submission.handleSendTransaction(std.testing.allocator, &rt, params);
    try std.testing.expectEqual(@as(usize, 1), rt.pool.pendingCount());
    try std.testing.expectEqualSlices(u8, &[_]u8{0xab}, rt.pool.items()[0].input);
}

test "eth_sendTransaction frees parser buffers on data alias mismatch" {
    var rt = try makeRuntime();
    defer rt.deinit();

    var obj = std.json.ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("from", .{ .string = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" });
    try obj.put("data", .{ .string = "0xab" });
    try obj.put("input", .{ .string = "0xcd" });

    const params = jsonrpc.eth.SendTransaction.Params{
        .transaction = .{ .value = .{ .object = obj } },
    };

    const result = tx_submission.handleSendTransaction(std.testing.allocator, &rt, params);
    try std.testing.expectError(tx_submission.TxSubmissionError.InvalidHexData, result);
}

test "eth_sendTransaction automine executes and persists canonical block" {
    var rt = try makeRuntime();
    defer rt.deinit();

    const recipient = runtime.DEFAULT_DEV_ACCOUNTS[1];
    const recipient_balance_before = try rt.state.getBalance(recipient);

    var obj = std.json.ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("from", .{ .string = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" });
    try obj.put("to", .{ .string = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" });
    try obj.put("value", .{ .string = "0x3e8" });
    try obj.put("gas", .{ .string = "0x5208" });

    const params = jsonrpc.eth.SendTransaction.Params{
        .transaction = .{ .value = .{ .object = obj } },
    };

    const result = try tx_submission.handleSendTransaction(std.testing.allocator, &rt, params);

    try std.testing.expectEqual(@as(u64, 1), rt.head_block_number);
    try std.testing.expectEqual(@as(usize, 0), rt.pool.pendingCount());
    try std.testing.expectEqual(@as(u64, 1), try rt.state.getNonce(runtime.DEFAULT_DEV_ACCOUNTS[0]));
    try std.testing.expectEqual(recipient_balance_before + 1000, try rt.state.getBalance(recipient));

    const block = (try rt.blockchain.getBlockByNumber(1)).?;
    try std.testing.expectEqual(@as(usize, 1), block.body.transactions.len);

    const receipt = rt.receipt_index.getByTxHash(result.value.bytes).?;
    try std.testing.expectEqual(@as(u64, 1), receipt.block_number);
    try std.testing.expectEqualSlices(u8, &block.hash, &receipt.block_hash);
    try std.testing.expectEqualSlices(u8, &result.value.bytes, &receipt.transaction_hash);
}

test "eth_sendTransaction unmanaged account returns error" {
    var rt = try makeRuntime();
    defer rt.deinit();

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

test "eth_sendTransaction impersonated mined tx hydrates sender from receipt metadata" {
    var rt = try makeRuntime();
    defer rt.deinit();

    const sender = parseAddr("0x0000000000000000000000000000000000000042");
    const recipient = runtime.DEFAULT_DEV_ACCOUNTS[1];
    try rt.impersonateAccount(sender);
    try rt.setBalance(sender, 1_000_000_000_000_000_000);

    var obj = std.json.ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("from", .{ .string = "0x0000000000000000000000000000000000000042" });
    try obj.put("to", .{ .string = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" });
    try obj.put("value", .{ .string = "0x3e8" });
    try obj.put("gas", .{ .string = "0x5208" });

    const params = jsonrpc.eth.SendTransaction.Params{
        .transaction = .{ .value = .{ .object = obj } },
    };

    const result = try tx_submission.handleSendTransaction(std.testing.allocator, &rt, params);
    try std.testing.expectEqual(@as(u64, 1), rt.head_block_number);

    const tx_by_hash = (try block_queries.getTransactionByHash(
        std.testing.allocator,
        &rt.blockchain,
        &rt.receipt_index,
        result.value.bytes,
    )).?;
    try std.testing.expectEqual(sender, tx_by_hash.from);
    try std.testing.expectEqual(recipient, tx_by_hash.to.?);
    try std.testing.expectEqual(@as(u64, 0), tx_by_hash.nonce);
    try std.testing.expectEqual(@as(u64, 21_000), tx_by_hash.gas);
    try std.testing.expectEqual(@as(u256, 1000), tx_by_hash.value);
    try std.testing.expectEqual(@as(?u256, 0), tx_by_hash.v);
    try std.testing.expectEqual(@as(?u256, 0), tx_by_hash.r);
    try std.testing.expectEqual(@as(?u256, 0), tx_by_hash.s);
    try std.testing.expectEqualSlices(u8, &result.value.bytes, &tx_by_hash.hash);

    const receipt = (try block_queries.getTransactionReceipt(
        std.testing.allocator,
        &rt.receipt_index,
        result.value.bytes,
    )).?;
    defer std.testing.allocator.free(receipt.logs);
    try std.testing.expectEqual(sender, receipt.from);
    try std.testing.expectEqual(recipient, receipt.to.?);
    try std.testing.expectEqualSlices(u8, &result.value.bytes, &receipt.transactionHash);

    const tx_by_number = (try block_queries.getTransactionByBlockNumberAndIndexWithReceipts(
        std.testing.allocator,
        &rt.blockchain,
        &rt.receipt_index,
        "0x1",
        0,
    )).?;
    try std.testing.expectEqual(sender, tx_by_number.from);
    try std.testing.expectEqual(recipient, tx_by_number.to.?);
    try std.testing.expectEqualSlices(u8, &result.value.bytes, &tx_by_number.hash);

    const block_by_hash = (try rt.blockchain.getBlockByNumber(1)).?;
    const tx_by_block_hash = (try block_queries.getTransactionByBlockHashAndIndexWithReceipts(
        std.testing.allocator,
        &rt.blockchain,
        &rt.receipt_index,
        block_by_hash.hash,
        0,
    )).?;
    try std.testing.expectEqual(sender, tx_by_block_hash.from);
    try std.testing.expectEqual(recipient, tx_by_block_hash.to.?);
    try std.testing.expectEqualSlices(u8, &result.value.bytes, &tx_by_block_hash.hash);

    const block_receipts = (try block_queries.getBlockReceiptsByHash(
        std.testing.allocator,
        &rt.blockchain,
        &rt.receipt_index,
        block_by_hash.hash,
    )).?;
    defer {
        for (block_receipts) |block_receipt| std.testing.allocator.free(block_receipt.logs);
        std.testing.allocator.free(block_receipts);
    }
    try std.testing.expectEqual(@as(usize, 1), block_receipts.len);
    try std.testing.expectEqual(sender, block_receipts[0].from);
    try std.testing.expectEqual(recipient, block_receipts[0].to.?);

    const block = (try block_queries.getBlockByNumberWithReceipts(
        std.testing.allocator,
        &rt.blockchain,
        &rt.receipt_index,
        "0x1",
        true,
    )).?;
    defer std.testing.allocator.free(block.transactions.full);
    const hydrated = block.transactions.full[0];
    try std.testing.expectEqual(sender, hydrated.from);
    try std.testing.expectEqual(recipient, hydrated.to.?);

    const block_by_hash_hydrated = (try block_queries.getBlockByHashWithReceipts(
        std.testing.allocator,
        &rt.blockchain,
        &rt.receipt_index,
        block_by_hash.hash,
        true,
    )).?;
    defer std.testing.allocator.free(block_by_hash_hydrated.transactions.full);
    try std.testing.expectEqual(sender, block_by_hash_hydrated.transactions.full[0].from);
    try std.testing.expectEqual(recipient, block_by_hash_hydrated.transactions.full[0].to.?);
}

test "eth_sendTransaction auto-impersonated txpool and mined queries preserve sender" {
    var rt = try makeRuntime();
    defer rt.deinit();

    try rt.setMiningConfig(.manual);
    rt.setAutoImpersonateAccount(true);

    const sender = parseAddr("0x0000000000000000000000000000000000000043");
    const recipient = runtime.DEFAULT_DEV_ACCOUNTS[1];
    try rt.setBalance(sender, 1_000_000_000_000_000_000);

    var obj = std.json.ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("from", .{ .string = "0x0000000000000000000000000000000000000043" });
    try obj.put("to", .{ .string = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" });
    try obj.put("value", .{ .string = "0x2a" });
    try obj.put("gas", .{ .string = "0x5208" });

    const params = jsonrpc.eth.SendTransaction.Params{
        .transaction = .{ .value = .{ .object = obj } },
    };

    const result = try tx_submission.handleSendTransaction(std.testing.allocator, &rt, params);
    try std.testing.expectEqual(@as(u64, 0), rt.head_block_number);
    try std.testing.expectEqual(@as(usize, 1), rt.pool.pendingCount());

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const content = try txpool_handlers.handleContent(arena.allocator(), &rt, null);
    const content_root = try expectObject(content);
    const pending = try expectObject(try field(content_root, "pending"));
    const pending_account = try expectObject(try field(pending, "0x0000000000000000000000000000000000000043"));
    const pending_tx = try expectObject(try field(pending_account, "0"));
    try std.testing.expectEqualStrings("0x0000000000000000000000000000000000000043", (try field(pending_tx, "from")).string);
    try std.testing.expectEqualStrings("0x2a", (try field(pending_tx, "value")).string);
    try std.testing.expectEqualStrings("0x5208", (try field(pending_tx, "gas")).string);
    try std.testing.expectEqualStrings("0x0", (try field(pending_tx, "nonce")).string);

    const inspect = try txpool_handlers.handleInspect(arena.allocator(), &rt, null);
    const inspect_root = try expectObject(inspect);
    const inspect_pending = try expectObject(try field(inspect_root, "pending"));
    const inspect_account = try expectObject(try field(inspect_pending, "0x0000000000000000000000000000000000000043"));
    try std.testing.expectEqualStrings(
        "0x70997970C51812dc3A010C7d01b50e0d17dc79C8: 42 wei + 21000 gas x 2000000000 wei",
        (try field(inspect_account, "0")).string,
    );

    try rt.mineBlocks(1, 0);
    try std.testing.expectEqual(@as(u64, 1), rt.head_block_number);
    try std.testing.expectEqual(@as(usize, 0), rt.pool.pendingCount());

    const tx_by_hash = (try block_queries.getTransactionByHash(
        std.testing.allocator,
        &rt.blockchain,
        &rt.receipt_index,
        result.value.bytes,
    )).?;
    try std.testing.expectEqual(sender, tx_by_hash.from);
    try std.testing.expectEqual(recipient, tx_by_hash.to.?);
    try std.testing.expectEqual(@as(u256, 42), tx_by_hash.value);

    const receipt = (try block_queries.getTransactionReceipt(
        std.testing.allocator,
        &rt.receipt_index,
        result.value.bytes,
    )).?;
    defer std.testing.allocator.free(receipt.logs);
    try std.testing.expectEqual(sender, receipt.from);
    try std.testing.expectEqual(recipient, receipt.to.?);
}

// --- Malformed typed envelope rejection --------------------------------

fn submitRawWithLeadingByte(rt: *runtime.NodeRuntime, leading: u8) tx_submission.TxSubmissionError!jsonrpc.eth.SendRawTransaction.Result {
    const payload = [_]u8{ leading, 0xc0 };
    const hex = try primitives.Hex.bytesToHex(std.testing.allocator, &payload);
    defer std.testing.allocator.free(hex);
    return tx_submission.handleSendRawTransaction(std.testing.allocator, rt, makeRawTxParams(hex));
}

test "eth_sendRawTransaction rejects EIP-2930 typed envelope (0x01)" {
    var rt = try makeRuntime();
    defer rt.deinit();
    const result = submitRawWithLeadingByte(&rt, 0x01);
    try std.testing.expectError(tx_submission.TxSubmissionError.DecodeFailed, result);
}

test "eth_sendRawTransaction rejects EIP-1559 typed envelope (0x02)" {
    var rt = try makeRuntime();
    defer rt.deinit();
    const result = submitRawWithLeadingByte(&rt, 0x02);
    try std.testing.expectError(tx_submission.TxSubmissionError.DecodeFailed, result);
}

test "eth_sendRawTransaction rejects EIP-4844 typed envelope (0x03)" {
    var rt = try makeRuntime();
    defer rt.deinit();
    const result = submitRawWithLeadingByte(&rt, 0x03);
    try std.testing.expectError(tx_submission.TxSubmissionError.DecodeFailed, result);
}

test "eth_sendRawTransaction rejects EIP-7702 typed envelope (0x04)" {
    var rt = try makeRuntime();
    defer rt.deinit();
    const result = submitRawWithLeadingByte(&rt, 0x04);
    try std.testing.expectError(tx_submission.TxSubmissionError.DecodeFailed, result);
}

test "eth_sendRawTransaction rejects unknown type byte (0x7f)" {
    var rt = try makeRuntime();
    defer rt.deinit();
    const result = submitRawWithLeadingByte(&rt, 0x7f);
    try std.testing.expectError(tx_submission.TxSubmissionError.UnsupportedTxType, result);
}

test "eth_sendRawTransaction rejects RLP-string leading byte (0x80)" {
    // 0x80..=0xbf is RLP string territory and is not a valid top-level tx
    // encoding. It must not be silently accepted as a typed-envelope nor as
    // a legacy list; surface it as a decode failure.
    var rt = try makeRuntime();
    defer rt.deinit();
    const result = submitRawWithLeadingByte(&rt, 0x80);
    try std.testing.expectError(tx_submission.TxSubmissionError.DecodeFailed, result);
}

test "eth_sendTransaction rejects 'type' field" {
    var rt = try makeRuntime();
    defer rt.deinit();
    try rt.setMiningConfig(.manual);

    var obj = std.json.ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("from", .{ .string = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" });
    try obj.put("to", .{ .string = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" });
    try obj.put("value", .{ .string = "0x3e8" });
    try obj.put("type", .{ .string = "0x2" });

    const params = jsonrpc.eth.SendTransaction.Params{
        .transaction = .{ .value = .{ .object = obj } },
    };
    const result = tx_submission.handleSendTransaction(std.testing.allocator, &rt, params);
    try std.testing.expectError(tx_submission.TxSubmissionError.UnsupportedTxType, result);
}

test "eth_sendTransaction rejects EIP-1559 dynamic-fee fields" {
    var rt = try makeRuntime();
    defer rt.deinit();
    try rt.setMiningConfig(.manual);

    var obj = std.json.ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("from", .{ .string = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" });
    try obj.put("to", .{ .string = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" });
    try obj.put("value", .{ .string = "0x3e8" });
    try obj.put("maxFeePerGas", .{ .string = "0x3b9aca00" });
    try obj.put("maxPriorityFeePerGas", .{ .string = "0x77359400" });

    const params = jsonrpc.eth.SendTransaction.Params{
        .transaction = .{ .value = .{ .object = obj } },
    };
    const result = tx_submission.handleSendTransaction(std.testing.allocator, &rt, params);
    try std.testing.expectError(tx_submission.TxSubmissionError.UnsupportedTxType, result);
}

test "eth_sendTransaction rejects EIP-2930 access-list field" {
    var rt = try makeRuntime();
    defer rt.deinit();
    try rt.setMiningConfig(.manual);

    var access_list = std.json.Array.init(std.testing.allocator);
    defer access_list.deinit();

    var obj = std.json.ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("from", .{ .string = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" });
    try obj.put("to", .{ .string = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" });
    try obj.put("value", .{ .string = "0x3e8" });
    try obj.put("accessList", .{ .array = access_list });

    const params = jsonrpc.eth.SendTransaction.Params{
        .transaction = .{ .value = .{ .object = obj } },
    };
    const result = tx_submission.handleSendTransaction(std.testing.allocator, &rt, params);
    try std.testing.expectError(tx_submission.TxSubmissionError.UnsupportedTxType, result);
}

test "eth_sendTransaction rejects EIP-4844 blob fields" {
    var rt = try makeRuntime();
    defer rt.deinit();
    try rt.setMiningConfig(.manual);

    var blob_hashes = std.json.Array.init(std.testing.allocator);
    defer blob_hashes.deinit();

    var obj = std.json.ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("from", .{ .string = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" });
    try obj.put("to", .{ .string = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" });
    try obj.put("maxFeePerBlobGas", .{ .string = "0x1" });
    try obj.put("blobVersionedHashes", .{ .array = blob_hashes });

    const params = jsonrpc.eth.SendTransaction.Params{
        .transaction = .{ .value = .{ .object = obj } },
    };
    const result = tx_submission.handleSendTransaction(std.testing.allocator, &rt, params);
    try std.testing.expectError(tx_submission.TxSubmissionError.UnsupportedTxType, result);
}

test "eth_sendTransaction rejects EIP-7702 authorization-list field" {
    var rt = try makeRuntime();
    defer rt.deinit();
    try rt.setMiningConfig(.manual);

    var auth_list = std.json.Array.init(std.testing.allocator);
    defer auth_list.deinit();

    var obj = std.json.ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("from", .{ .string = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" });
    try obj.put("to", .{ .string = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" });
    try obj.put("value", .{ .string = "0x3e8" });
    try obj.put("authorizationList", .{ .array = auth_list });

    const params = jsonrpc.eth.SendTransaction.Params{
        .transaction = .{ .value = .{ .object = obj } },
    };
    const result = tx_submission.handleSendTransaction(std.testing.allocator, &rt, params);
    try std.testing.expectError(tx_submission.TxSubmissionError.UnsupportedTxType, result);
}

test "eth_sendTransaction rejects chainId field" {
    var rt = try makeRuntime();
    defer rt.deinit();
    try rt.setMiningConfig(.manual);

    var obj = std.json.ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("from", .{ .string = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" });
    try obj.put("to", .{ .string = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" });
    try obj.put("value", .{ .string = "0x3e8" });
    try obj.put("chainId", .{ .string = "0x7a69" });

    const params = jsonrpc.eth.SendTransaction.Params{
        .transaction = .{ .value = .{ .object = obj } },
    };
    const result = tx_submission.handleSendTransaction(std.testing.allocator, &rt, params);
    try std.testing.expectError(tx_submission.TxSubmissionError.UnsupportedTxType, result);
}

test "EIP-7825 submission and signing return exact JSON error without changing state" {
    var osaka_cfg = runtime.DEFAULT_DEV_HARDFORK_CONFIG;
    osaka_cfg.prague_timestamp = 0;
    osaka_cfg.osaka_timestamp = 0;
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{ .hardfork_config = osaka_cfg });
    defer rt.deinit();
    try rt.setMiningConfig(.manual);
    var handlers = dispatcher.HandlerRegistry{};
    dispatch_wiring.install(&handlers, &rt);
    const sender = runtime.DEFAULT_DEV_ACCOUNTS[0];
    const before_balance = try rt.state.getBalance(sender);
    const before_nonce = try rt.state.getNonce(sender);
    const encoded = try signTestLegacyTx(std.testing.allocator, before_nonce, runtime.DEFAULT_GAS_PRICE, 16_777_217, runtime.DEFAULT_DEV_ACCOUNTS[1], 1, runtime.DEFAULT_CHAIN_ID, genesis.DEV_ACCOUNTS[0].private_key);
    defer std.testing.allocator.free(encoded);
    const raw_hex = try bytesToHexAlloc(std.testing.allocator, encoded);
    defer std.testing.allocator.free(raw_hex);
    const from_hex = primitives.Address.toHex(sender);
    const to_hex = primitives.Address.toHex(runtime.DEFAULT_DEV_ACCOUNTS[1]);
    const object_params = try std.fmt.allocPrint(std.testing.allocator, "[{{\"from\":\"{s}\",\"to\":\"{s}\",\"gas\":\"0x1000001\"}}]", .{ from_hex, to_hex });
    defer std.testing.allocator.free(object_params);
    const raw_params = try std.fmt.allocPrint(std.testing.allocator, "[\"{s}\"]", .{raw_hex});
    defer std.testing.allocator.free(raw_params);
    for ([_][]const u8{ "eth_sendTransaction", "eth_signTransaction", "eth_sendRawTransaction" }) |method| {
        const params = if (std.mem.eql(u8, method, "eth_sendRawTransaction")) raw_params else object_params;
        const request = try std.fmt.allocPrint(std.testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":7825,\"method\":\"{s}\",\"params\":{s}}}", .{ method, params });
        defer std.testing.allocator.free(request);
        var response = try server.handleHttpRequestForTest(std.testing.allocator, .POST, request, &handlers);
        defer response.deinit(std.testing.allocator);
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, response.body.?, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("2.0", parsed.value.object.get("jsonrpc").?.string);
        try std.testing.expectEqual(@as(i64, 7825), parsed.value.object.get("id").?.integer);
        const rpc_error = parsed.value.object.get("error").?.object;
        try std.testing.expectEqual(@as(i64, -32000), rpc_error.get("code").?.integer);
        try std.testing.expectEqualStrings("transaction gas limit exceeds Osaka cap (16777216)", rpc_error.get("message").?.string);
        try std.testing.expectEqual(@as(usize, 2), rpc_error.count());
        try std.testing.expectEqual(@as(usize, 0), rt.pool.items().len);
        try std.testing.expectEqual(before_nonce, try rt.state.getNonce(sender));
        try std.testing.expectEqual(before_balance, try rt.state.getBalance(sender));
    }
}

test "EIP-7825 raw admission follows pending timestamp and permits exact cap" {
    for ([_]struct { timestamp: u64, gas_limit: u64 }{
        .{ .timestamp = 99, .gas_limit = 16_777_217 },
        .{ .timestamp = 100, .gas_limit = 16_777_216 },
    }) |case| {
        var osaka_100_cfg = runtime.DEFAULT_DEV_HARDFORK_CONFIG;
        osaka_100_cfg.prague_timestamp = 0;
        osaka_100_cfg.osaka_timestamp = 100;
        var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{ .hardfork_config = osaka_100_cfg });
        defer rt.deinit();
        try rt.setMiningConfig(.manual);
        rt.setNextBlockTimestamp(case.timestamp);
        const sender = runtime.DEFAULT_DEV_ACCOUNTS[0];
        const before_balance = try rt.state.getBalance(sender);
        const encoded = try signTestLegacyTx(std.testing.allocator, 0, runtime.DEFAULT_GAS_PRICE, case.gas_limit, runtime.DEFAULT_DEV_ACCOUNTS[1], 1, runtime.DEFAULT_CHAIN_ID, genesis.DEV_ACCOUNTS[0].private_key);
        defer std.testing.allocator.free(encoded);
        const hex = try bytesToHexAlloc(std.testing.allocator, encoded);
        defer std.testing.allocator.free(hex);
        _ = try tx_submission.handleSendRawTransaction(std.testing.allocator, &rt, makeRawTxParams(hex));
        try std.testing.expectEqual(@as(usize, 1), rt.pool.items().len);
        try std.testing.expectEqual(@as(u64, 0), try rt.state.getNonce(sender));
        try std.testing.expectEqual(before_balance, try rt.state.getBalance(sender));
    }
}

test "EIP-7594 admission gates v0/v1 wrappers, verifies KZG proofs, upgrades sidecars, and enforces 6-blob cap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const temp = arena.allocator();

    const infinity = [_]u8{0xc0} ++ [_]u8{0} ** 47;
    const versioned_hash = primitives.Blob.commitmentToVersionedHash(infinity);
    const sidecar = try temp.create(tx_encoding.BlobSidecar);
    @memset(&sidecar.blob, 0);
    sidecar.commitment = infinity;
    sidecar.proofs = .{ .cells = [_][48]u8{infinity} ** tx_encoding.CELLS_PER_EXT_BLOB };

    var tx = primitives.Transaction.Eip4844Transaction{
        .chain_id = runtime.DEFAULT_CHAIN_ID,
        .nonce = 0,
        .max_priority_fee_per_gas = 1,
        .max_fee_per_gas = runtime.DEFAULT_GAS_PRICE,
        .gas_limit = 21_000,
        .to = runtime.DEFAULT_DEV_ACCOUNTS[1],
        .value = 0,
        .data = &.{},
        .access_list = &.{},
        .max_fee_per_blob_gas = 1,
        .blob_versioned_hashes = &.{versioned_hash},
        .y_parity = 0,
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
    };
    const unsigned = try primitives.Transaction.encodeEip4844ForSigning(temp, tx);
    const sig = try crypto.Crypto.unaudited_signHash(tx_encoding.transactionHash(unsigned), genesis.DEV_ACCOUNTS[0].private_key);
    tx.y_parity = sig.v - 27;
    std.mem.writeInt(u256, &tx.r, sig.r, .big);
    std.mem.writeInt(u256, &tx.s, sig.s, .big);
    const signed = try primitives.Transaction.encodeEip4844ForSigning(temp, tx);

    const v1_raw = try tx_encoding.encodeBlobNetworkEnvelope(temp, signed, sidecar[0..1]);
    const v1_params = makeRawTxParams(try bytesToHexAlloc(temp, v1_raw));
    sidecar.proofs = .{ .blob = infinity };
    const v0_raw = try tx_encoding.encodeBlobNetworkEnvelope(temp, signed, sidecar[0..1]);
    const v0_params = makeRawTxParams(try bytesToHexAlloc(temp, v0_raw));

    var rt = try makeRuntime();
    defer rt.deinit();
    try rt.setMiningConfig(.manual);

    // Pre-Osaka: v1 rejected, v0 verified via c-kzg and pooled.
    try std.testing.expectError(error.BlobWrapperVersionMismatch, tx_submission.handleSendRawTransaction(temp, &rt, v1_params));
    _ = try tx_submission.handleSendRawTransaction(temp, &rt, v0_params);
    try std.testing.expect(rt.pool.items()[0].blob_sidecars[0].proofs == .blob);

    // Activate Osaka: v0 rejected, tampered v1 rejected by c-kzg cell batch verify, valid v1 upgrades sidecar.
    rt.hardfork_config.prague_timestamp = 0;
    rt.hardfork_config.osaka_timestamp = 0;
    try std.testing.expectError(error.BlobWrapperVersionMismatch, tx_submission.handleSendRawTransaction(temp, &rt, v0_params));

    sidecar.proofs = .{ .cells = [_][48]u8{infinity} ** tx_encoding.CELLS_PER_EXT_BLOB };
    sidecar.blob[31] = 1;
    const tampered_v1 = try tx_encoding.encodeBlobNetworkEnvelope(temp, signed, sidecar[0..1]);
    try std.testing.expectError(error.DecodeFailed, tx_submission.handleSendRawTransaction(temp, &rt, makeRawTxParams(try bytesToHexAlloc(temp, tampered_v1))));
    try std.testing.expect(rt.pool.items()[0].blob_sidecars[0].proofs == .blob);

    _ = try tx_submission.handleSendRawTransaction(temp, &rt, v1_params);
    const pooled = rt.pool.items()[0];
    try std.testing.expectEqualSlices(u8, signed, pooled.raw);
    try std.testing.expectEqual(tx_encoding.transactionHash(signed), pooled.hash);
    try std.testing.expectEqual(infinity, pooled.blob_sidecars[0].proofs.cells[127]);

    // Fusaka 6-blobs-per-tx cap: 7-blob tx rejected with TooManyBlobs on Osaka even if block max > 6.
    const seven_hashes = [_]primitives.Blob.VersionedHash{versioned_hash} ** 7;
    var tx7 = tx;
    tx7.nonce = 1;
    tx7.blob_versioned_hashes = &seven_hashes;
    tx7.y_parity = 0;
    tx7.r = [_]u8{0} ** 32;
    tx7.s = [_]u8{0} ** 32;
    const unsigned7 = try primitives.Transaction.encodeEip4844ForSigning(temp, tx7);
    const sig7 = try crypto.Crypto.unaudited_signHash(tx_encoding.transactionHash(unsigned7), genesis.DEV_ACCOUNTS[0].private_key);
    tx7.y_parity = sig7.v - 27;
    std.mem.writeInt(u256, &tx7.r, sig7.r, .big);
    std.mem.writeInt(u256, &tx7.s, sig7.s, .big);
    const signed7 = try primitives.Transaction.encodeEip4844ForSigning(temp, tx7);
    try std.testing.expectError(error.TooManyBlobs, tx_submission.handleSendRawTransaction(temp, &rt, makeRawTxParams(try bytesToHexAlloc(temp, signed7))));
}

// --- Regression: unchecked fee/value arithmetic (#55) ---

test "eth_sendTransaction returns an error when gasPrice * gas overflows u256 (#55)" {
    var rt = try makeRuntime();
    defer rt.deinit();
    try rt.setMiningConfig(.manual);

    var obj = std.json.ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("from", .{ .string = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" });
    try obj.put("to", .{ .string = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" });
    try obj.put("gasPrice", .{ .string = "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" });
    try obj.put("gas", .{ .string = "0x5208" });

    const result = tx_submission.handleSendTransaction(std.testing.allocator, &rt, .{
        .transaction = .{ .value = .{ .object = obj } },
    });
    try std.testing.expectError(tx_submission.TxSubmissionError.InsufficientBalance, result);
    try std.testing.expectEqual(@as(usize, 0), rt.pool.pendingCount());
}

test "eth_sendTransaction rejects value + gas cost overflow even with a u256-max balance (#55)" {
    var rt = try makeRuntime();
    defer rt.deinit();
    try rt.setMiningConfig(.manual);
    try rt.setBalance(runtime.DEFAULT_DEV_ACCOUNTS[0], std.math.maxInt(u256));

    var obj = std.json.ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("from", .{ .string = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" });
    try obj.put("to", .{ .string = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" });
    try obj.put("value", .{ .string = "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" });
    try obj.put("gas", .{ .string = "0x5208" });

    // A saturating sum equals the balance and would be accepted.
    const result = tx_submission.handleSendTransaction(std.testing.allocator, &rt, .{
        .transaction = .{ .value = .{ .object = obj } },
    });
    try std.testing.expectError(tx_submission.TxSubmissionError.InsufficientBalance, result);
    try std.testing.expectEqual(@as(usize, 0), rt.pool.pendingCount());
}

test "eth_sendRawTransaction rejects value + gas cost overflow even with a u256-max balance (#55)" {
    var rt = try makeRuntime();
    defer rt.deinit();
    try rt.setMiningConfig(.manual);
    try rt.setBalance(runtime.DEFAULT_DEV_ACCOUNTS[0], std.math.maxInt(u256));

    const encoded = try signTestLegacyTx(
        std.testing.allocator,
        0,
        runtime.DEFAULT_GAS_PRICE,
        21_000,
        runtime.DEFAULT_DEV_ACCOUNTS[1],
        std.math.maxInt(u256),
        runtime.DEFAULT_CHAIN_ID,
        genesis.DEV_ACCOUNTS[0].private_key,
    );
    defer std.testing.allocator.free(encoded);
    const hex = try bytesToHexAlloc(std.testing.allocator, encoded);
    defer std.testing.allocator.free(hex);

    const result = tx_submission.handleSendRawTransaction(std.testing.allocator, &rt, makeRawTxParams(hex));
    try std.testing.expectError(tx_submission.TxSubmissionError.InsufficientBalance, result);
    try std.testing.expectEqual(@as(usize, 0), rt.pool.pendingCount());
}

// --- Regression: automine failure must fail the submission (#56) ---

test "automine failure fails eth_sendRawTransaction and evicts the transaction (#56)" {
    var rt = try makeRuntime();
    defer rt.deinit();

    const encoded = try signTestLegacyTx(
        std.testing.allocator,
        0,
        runtime.DEFAULT_GAS_PRICE,
        21_000,
        runtime.DEFAULT_DEV_ACCOUNTS[1],
        1000,
        runtime.DEFAULT_CHAIN_ID,
        genesis.DEV_ACCOUNTS[0].private_key,
    );
    defer std.testing.allocator.free(encoded);
    const hex = try bytesToHexAlloc(std.testing.allocator, encoded);
    defer std.testing.allocator.free(hex);

    // A next-block timestamp at or before the head makes the mining pass fail.
    rt.next_block_timestamp = rt.head_block_timestamp;
    const failed = tx_submission.handleSendRawTransaction(std.testing.allocator, &rt, makeRawTxParams(hex));
    try std.testing.expectError(tx_submission.TxSubmissionError.MiningFailed, failed);
    try std.testing.expectEqual(@as(u64, 0), rt.head_block_number);
    try std.testing.expectEqual(@as(usize, 0), rt.pool.pendingCount());
    try std.testing.expectEqual(@as(usize, 0), rt.pool.queuedCount());

    // The failed submission left nothing behind, so the same tx can be resent.
    rt.next_block_timestamp = null;
    const result = try tx_submission.handleSendRawTransaction(std.testing.allocator, &rt, makeRawTxParams(hex));
    try std.testing.expectEqual(@as(u64, 1), rt.head_block_number);
    try std.testing.expectEqual(@as(u64, 1), rt.receipt_index.getByTxHash(result.value.bytes).?.block_number);
}

test "automine failure fails eth_sendTransaction and evicts the transaction (#56)" {
    var rt = try makeRuntime();
    defer rt.deinit();

    var obj = std.json.ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("from", .{ .string = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" });
    try obj.put("to", .{ .string = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" });
    try obj.put("value", .{ .string = "0x3e8" });
    try obj.put("gas", .{ .string = "0x5208" });
    const params = jsonrpc.eth.SendTransaction.Params{ .transaction = .{ .value = .{ .object = obj } } };

    rt.next_block_timestamp = rt.head_block_timestamp;
    const failed = tx_submission.handleSendTransaction(std.testing.allocator, &rt, params);
    try std.testing.expectError(tx_submission.TxSubmissionError.MiningFailed, failed);
    try std.testing.expectEqual(@as(u64, 0), rt.head_block_number);
    try std.testing.expectEqual(@as(usize, 0), rt.pool.pendingCount());
    try std.testing.expectEqual(@as(u64, 0), try rt.getNonce(runtime.DEFAULT_DEV_ACCOUNTS[0]));

    rt.next_block_timestamp = null;
    _ = try tx_submission.handleSendTransaction(std.testing.allocator, &rt, params);
    try std.testing.expectEqual(@as(u64, 1), rt.head_block_number);
    try std.testing.expectEqual(@as(u64, 1), try rt.getNonce(runtime.DEFAULT_DEV_ACCOUNTS[0]));
}

test "eth_sendTransaction with gasPrice=maxInt(u256) returns InsufficientBalance instead of overflowing" {
    var rt = try makeRuntime();
    defer rt.deinit();
    try rt.setMiningConfig(.manual);

    var obj = std.json.ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("from", .{ .string = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" });
    try obj.put("to", .{ .string = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" });
    try obj.put("gasPrice", .{ .string = "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" });
    try obj.put("gas", .{ .string = "0x5208" });

    const params = jsonrpc.eth.SendTransaction.Params{
        .transaction = .{ .value = .{ .object = obj } },
    };

    try std.testing.expectError(
        tx_submission.TxSubmissionError.InsufficientBalance,
        tx_submission.handleSendTransaction(std.testing.allocator, &rt, params),
    );
    try std.testing.expectEqual(@as(usize, 0), rt.pool.items().len);
}

test "eth_sendTransaction value plus gas cost overflow returns InsufficientBalance" {
    var rt = try makeRuntime();
    defer rt.deinit();
    try rt.setMiningConfig(.manual);

    var obj = std.json.ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("from", .{ .string = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" });
    try obj.put("to", .{ .string = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" });
    try obj.put("value", .{ .string = "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" });
    try obj.put("gas", .{ .string = "0x5208" });

    const params = jsonrpc.eth.SendTransaction.Params{
        .transaction = .{ .value = .{ .object = obj } },
    };

    try std.testing.expectError(
        tx_submission.TxSubmissionError.InsufficientBalance,
        tx_submission.handleSendTransaction(std.testing.allocator, &rt, params),
    );
}

fn sendLegacyRequest(rt: *runtime.NodeRuntime, gas_price_hex: []const u8, value_hex: []const u8) tx_submission.TxSubmissionError!jsonrpc.eth.SendTransaction.Result {
    var obj = std.json.ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("from", .{ .string = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" });
    try obj.put("to", .{ .string = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" });
    try obj.put("nonce", .{ .string = "0x0" });
    try obj.put("gasPrice", .{ .string = gas_price_hex });
    try obj.put("value", .{ .string = value_hex });
    try obj.put("gas", .{ .string = "0x5208" });
    return tx_submission.handleSendTransaction(std.testing.allocator, rt, .{
        .transaction = .{ .value = .{ .object = obj } },
    });
}

test "eth_sendTransaction legacy replacement succeeds with a 10% gas price bump" {
    var rt = try makeRuntime();
    defer rt.deinit();
    try rt.setMiningConfig(.manual);

    // 0x77359400 = 2 gwei (the runtime minimum), 0x83215600 = 2.2 gwei.
    const first = try sendLegacyRequest(&rt, "0x77359400", "0x1");
    try std.testing.expectEqual(runtime.DEFAULT_GAS_PRICE, rt.pool.items()[0].max_priority_fee_per_gas);

    // Same price with a different payload is not a replacement.
    try std.testing.expectError(
        tx_submission.TxSubmissionError.PoolInsertFailed,
        sendLegacyRequest(&rt, "0x77359400", "0x2"),
    );

    const replacement = try sendLegacyRequest(&rt, "0x83215600", "0x2");
    try std.testing.expect(!std.mem.eql(u8, &first.value.bytes, &replacement.value.bytes));
    try std.testing.expectEqual(@as(usize, 1), rt.pool.items().len);
    try std.testing.expectEqualSlices(u8, &replacement.value.bytes, &rt.pool.items()[0].hash);
    try std.testing.expectEqual(@as(u256, 2_200_000_000), rt.pool.items()[0].max_fee_per_gas);
}

test "eth_sendRawTransaction rejects a priority fee above the fee cap" {
    var rt = try makeRuntime();
    defer rt.deinit();
    try rt.setMiningConfig(.manual);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const temp = arena.allocator();

    var tx = primitives.Transaction.Eip1559Transaction{
        .chain_id = runtime.DEFAULT_CHAIN_ID,
        .nonce = 0,
        .max_priority_fee_per_gas = runtime.DEFAULT_GAS_PRICE + 1,
        .max_fee_per_gas = runtime.DEFAULT_GAS_PRICE,
        .gas_limit = 21_000,
        .to = runtime.DEFAULT_DEV_ACCOUNTS[1],
        .value = 0,
        .data = &.{},
        .access_list = &.{},
        .y_parity = 0,
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
    };
    const unsigned = try primitives.Transaction.encodeEip1559ForSigning(temp, tx);
    const sig = try crypto.Crypto.unaudited_signHash(tx_encoding.transactionHash(unsigned), genesis.DEV_ACCOUNTS[0].private_key);
    tx.y_parity = sig.v - 27;
    std.mem.writeInt(u256, &tx.r, sig.r, .big);
    std.mem.writeInt(u256, &tx.s, sig.s, .big);
    const signed = try primitives.Transaction.encodeEip1559ForSigning(temp, tx);

    try std.testing.expectError(
        tx_submission.TxSubmissionError.DecodeFailed,
        tx_submission.handleSendRawTransaction(std.testing.allocator, &rt, makeRawTxParams(try bytesToHexAlloc(temp, signed))),
    );
    try std.testing.expectEqual(@as(usize, 0), rt.pool.items().len);
}

// --- Round 2 admission regressions ---

fn submitSignedLegacy(
    rt: *runtime.NodeRuntime,
    nonce: u64,
    gas_price: u256,
) tx_submission.TxSubmissionError!jsonrpc.eth.SendRawTransaction.Result {
    const allocator = std.testing.allocator;
    const encoded = signTestLegacyTx(
        allocator,
        nonce,
        gas_price,
        21_000,
        runtime.DEFAULT_DEV_ACCOUNTS[1],
        1,
        runtime.DEFAULT_CHAIN_ID,
        genesis.DEV_ACCOUNTS[0].private_key,
    ) catch return tx_submission.TxSubmissionError.SigningFailed;
    defer allocator.free(encoded);
    const hex = bytesToHexAlloc(allocator, encoded) catch return tx_submission.TxSubmissionError.OutOfMemory;
    defer allocator.free(hex);
    return tx_submission.handleSendRawTransaction(allocator, rt, makeRawTxParams(hex));
}

test "eth_sendRawTransaction rejects a fee cap below the pending base fee" {
    var rt = try makeRuntime();
    defer rt.deinit();
    try rt.setMiningConfig(.manual);
    try std.testing.expect(rt.pendingHardfork().isAtLeast(.LONDON));

    rt.base_fee = runtime.DEFAULT_GAS_PRICE + 1;
    try std.testing.expectError(
        tx_submission.TxSubmissionError.GasPriceBelowBaseFee,
        submitSignedLegacy(&rt, 0, runtime.DEFAULT_GAS_PRICE),
    );
    try std.testing.expectEqual(@as(usize, 0), rt.pool.items().len);
    try std.testing.expectEqual(@as(u32, 0), rt.pool.base_nonces.count());

    // A fee cap equal to the base fee is includable, and a zero base fee
    // disables the floor.
    rt.base_fee = runtime.DEFAULT_GAS_PRICE;
    _ = try submitSignedLegacy(&rt, 0, runtime.DEFAULT_GAS_PRICE);
    rt.base_fee = 0;
    _ = try submitSignedLegacy(&rt, 1, 1);
    try std.testing.expectEqual(@as(usize, 2), rt.pool.items().len);
}

test "eth_sendRawTransaction keeps no sender state for a pool-rejected transaction and prunes it on removal" {
    var rt = try makeRuntime();
    defer rt.deinit();
    try rt.setMiningConfig(.manual);

    // The pool rejects a nonce beyond the gap limit. Before the fix the base
    // nonce was recorded first and the entry was never released.
    try std.testing.expectError(
        tx_submission.TxSubmissionError.PoolInsertFailed,
        submitSignedLegacy(&rt, txpool.MAX_NONCE_GAP + 1, runtime.DEFAULT_GAS_PRICE),
    );
    try std.testing.expectEqual(@as(usize, 0), rt.pool.items().len);
    try std.testing.expectEqual(@as(u32, 0), rt.pool.base_nonces.count());

    const accepted = try submitSignedLegacy(&rt, 0, runtime.DEFAULT_GAS_PRICE);
    try std.testing.expectEqual(@as(usize, 1), rt.pool.pendingCount());
    try std.testing.expectEqual(@as(u32, 1), rt.pool.base_nonces.count());

    try std.testing.expect(rt.pool.removeByHash(accepted.value.bytes));
    try std.testing.expectEqual(@as(u32, 0), rt.pool.base_nonces.count());
}

test "eth_sendRawTransaction enforces EIP-3607 on the recovered sender" {
    var rt = try makeRuntime();
    defer rt.deinit();
    try rt.setMiningConfig(.manual);
    const sender = runtime.DEFAULT_DEV_ACCOUNTS[0];

    try rt.setCode(sender, &[_]u8{ 0x60, 0x00 });
    try std.testing.expectError(
        tx_submission.TxSubmissionError.SenderNotEOA,
        submitSignedLegacy(&rt, 0, runtime.DEFAULT_GAS_PRICE),
    );
    try std.testing.expectEqual(@as(usize, 0), rt.pool.items().len);

    // A 23-byte 0xef0100 delegation designator is an EOA from Prague on.
    const delegation = [_]u8{ 0xef, 0x01, 0x00 } ++ [_]u8{0x11} ** 20;
    try rt.setCode(sender, &delegation);
    const delegated = submitSignedLegacy(&rt, 0, runtime.DEFAULT_GAS_PRICE);
    if (rt.pendingHardfork().isAtLeast(.PRAGUE)) {
        _ = try delegated;
        try std.testing.expectEqual(@as(usize, 1), rt.pool.items().len);
    } else {
        try std.testing.expectError(tx_submission.TxSubmissionError.SenderNotEOA, delegated);
    }

    // The prefix alone does not make arbitrary code a delegation.
    var rt_long = try makeRuntime();
    defer rt_long.deinit();
    try rt_long.setMiningConfig(.manual);
    const not_delegation = [_]u8{ 0xef, 0x01, 0x00 } ++ [_]u8{0x11} ** 21;
    try rt_long.setCode(sender, &not_delegation);
    try std.testing.expectError(
        tx_submission.TxSubmissionError.SenderNotEOA,
        submitSignedLegacy(&rt_long, 0, runtime.DEFAULT_GAS_PRICE),
    );
}

test "eth_sendRawTransaction rejects the EIP-2681 maximum nonce" {
    var rt = try makeRuntime();
    defer rt.deinit();
    try rt.setMiningConfig(.manual);

    try std.testing.expectError(
        tx_submission.TxSubmissionError.NonceTooHigh,
        submitSignedLegacy(&rt, std.math.maxInt(u64), runtime.DEFAULT_GAS_PRICE),
    );
    try std.testing.expectEqual(@as(usize, 0), rt.pool.items().len);
    try std.testing.expectEqual(@as(u32, 0), rt.pool.base_nonces.count());
}
