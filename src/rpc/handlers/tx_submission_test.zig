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
const jsonrpc = @import("jsonrpc");

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

test "eth_sendRawTransaction rejects gas price below runtime minimum" {
    var rt = try makeRuntime();
    defer rt.deinit();
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

    const result = tx_submission.handleSendRawTransaction(std.testing.allocator, &rt, makeRawTxParams(hex));
    try std.testing.expectError(tx_submission.TxSubmissionError.GasPriceBelowMinimum, result);
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

    const same_price = try signTestLegacyTx(
        std.testing.allocator,
        0,
        runtime.DEFAULT_GAS_PRICE,
        21_000,
        runtime.DEFAULT_DEV_ACCOUNTS[1],
        1000,
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

    const replacement = try signTestLegacyTx(
        std.testing.allocator,
        0,
        runtime.DEFAULT_GAS_PRICE + 1,
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
    try std.testing.expectEqual(runtime.DEFAULT_GAS_PRICE + 1, rt.pool.items()[0].max_fee_per_gas);
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
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{
        .hardfork_config = .{
            .homestead_block = 0,
            .dao_block = 0,
            .tangerine_whistle_block = 0,
            .spurious_dragon_block = 0,
            .byzantium_block = 0,
            .petersburg_block = 0,
            .istanbul_block = 0,
            .muir_glacier_block = 0,
            .berlin_block = 0,
            .london_block = 0,
            .arrow_glacier_block = 0,
            .gray_glacier_block = 0,
            .merge_block = 0,
            .shanghai_timestamp = std.math.maxInt(u64),
            .cancun_timestamp = std.math.maxInt(u64),
            .prague_timestamp = std.math.maxInt(u64),
            .osaka_timestamp = std.math.maxInt(u64),
        },
    });
    defer rt.deinit();
    try rt.setMiningConfig(.manual);

    const initcode_bytes = [_]u8{0x11} ** 33;
    const initcode_hex = "0x111111111111111111111111111111111111111111111111111111111111111111";
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
        "0x70997970c51812dc3a010c7d01b50e0d17dc79c8: 42 wei + 21000 gas x 2000000000 wei",
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

// --- Phase 1 boundary: typed envelope rejection -------------------------
//
// Phase 1 accepts only legacy RLP envelopes on the public RPC surface.
// Every EIP-2718 typed envelope (type bytes 0x01..=0x7f) must reject cleanly
// with `UnsupportedTxType`, which the dispatcher maps to JSON-RPC -32602.

fn submitRawWithLeadingByte(rt: *runtime.NodeRuntime, leading: u8) tx_submission.TxSubmissionError!jsonrpc.eth.SendRawTransaction.Result {
    // Body shape is irrelevant: rejection happens on the type-byte check
    // before any RLP decoding, so a single leading byte plus a minimal
    // suffix is enough to exercise the boundary.
    const payload = [_]u8{ leading, 0xc0 };
    const hex = try primitives.Hex.bytesToHex(std.testing.allocator, &payload);
    defer std.testing.allocator.free(hex);
    return tx_submission.handleSendRawTransaction(std.testing.allocator, rt, makeRawTxParams(hex));
}

test "eth_sendRawTransaction rejects EIP-2930 typed envelope (0x01)" {
    var rt = try makeRuntime();
    defer rt.deinit();
    const result = submitRawWithLeadingByte(&rt, 0x01);
    try std.testing.expectError(tx_submission.TxSubmissionError.UnsupportedTxType, result);
}

test "eth_sendRawTransaction rejects EIP-1559 typed envelope (0x02)" {
    var rt = try makeRuntime();
    defer rt.deinit();
    const result = submitRawWithLeadingByte(&rt, 0x02);
    try std.testing.expectError(tx_submission.TxSubmissionError.UnsupportedTxType, result);
}

test "eth_sendRawTransaction rejects EIP-4844 typed envelope (0x03)" {
    var rt = try makeRuntime();
    defer rt.deinit();
    const result = submitRawWithLeadingByte(&rt, 0x03);
    try std.testing.expectError(tx_submission.TxSubmissionError.UnsupportedTxType, result);
}

test "eth_sendRawTransaction rejects EIP-7702 typed envelope (0x04)" {
    var rt = try makeRuntime();
    defer rt.deinit();
    const result = submitRawWithLeadingByte(&rt, 0x04);
    try std.testing.expectError(tx_submission.TxSubmissionError.UnsupportedTxType, result);
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
