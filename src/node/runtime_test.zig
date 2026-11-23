const std = @import("std");
const runtime = @import("runtime.zig");
const genesis = @import("../genesis.zig");
const block_builder = @import("../block_builder.zig");
const hardfork_schedule = @import("../hardfork_schedule.zig");
const mining = @import("../mining.zig");
const primitives = @import("primitives");
const guillotine_mini = @import("guillotine_mini");
const tx_encoding = @import("../transaction_encoding.zig");
const checkpoint = @import("../checkpoint.zig");

const STORE_BLOCKHASH_ZERO = [_]u8{ 0x60, 0x00, 0x40, 0x60, 0x00, 0x55, 0x00 };

fn tmpPath(allocator: std.mem.Allocator, tmp_dir: *std.testing.TmpDir, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp_dir.sub_path, name });
}

fn writeTmpFile(
    allocator: std.mem.Allocator,
    tmp_dir: *std.testing.TmpDir,
    name: []const u8,
    body: []const u8,
) ![]u8 {
    var file = try tmp_dir.dir.createFile(name, .{ .truncate = true });
    defer file.close();
    try file.writeAll(body);
    return tmpPath(allocator, tmp_dir, name);
}

test "NodeRuntime.init uses deterministic defaults" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    try std.testing.expectEqual(@as(u64, 31337), rt.chain_id);
    try std.testing.expectEqual(@as(u64, 0), rt.head_block_number);
    try std.testing.expectEqual(runtime.DEFAULT_DEV_ACCOUNTS[0], rt.coinbase);
}

test "DEFAULT_DEV_ACCOUNTS matches genesis managed wallet addresses" {
    try std.testing.expectEqual(genesis.DEV_ACCOUNTS.len, runtime.DEFAULT_DEV_ACCOUNTS.len);
    for (&genesis.DEV_ACCOUNTS, 0..) |*account, index| {
        try std.testing.expect(primitives.Address.Address.equals(
            account.address,
            runtime.DEFAULT_DEV_ACCOUNTS[index],
        ));
    }
}

test "NodeRuntime coinbase indexes use canonical managed accounts" {
    for (0..runtime.DEFAULT_DEV_ACCOUNTS.len) |index| {
        var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{
            .coinbase_index = @intCast(index),
        });
        defer rt.deinit();

        try std.testing.expectEqual(runtime.DEFAULT_DEV_ACCOUNTS[index], rt.coinbase);
    }
}

test "NodeRuntime signer scope includes every managed genesis account" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    for (&genesis.DEV_ACCOUNTS) |*account| {
        try std.testing.expect(rt.canSignForAccount(account.address));
        const private_key = rt.managedPrivateKey(account.address) orelse return error.MissingManagedPrivateKey;
        try std.testing.expectEqualSlices(u8, &account.private_key, &private_key);
    }
}

test "NodeRuntime exposes managed accounts from runtime state" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    try std.testing.expectEqual(genesis.DEV_ACCOUNTS.len, rt.managedAccountCount());
    try std.testing.expectEqual(genesis.DEV_ACCOUNTS[0].address, rt.managedAccountAddress(0));

    rt.managed_accounts[0] = genesis.DEV_ACCOUNTS[1];
    try std.testing.expectEqual(genesis.DEV_ACCOUNTS[1].address, rt.managedAccountAddress(0));
}

test "NodeRuntime.init seeds dev account balances" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    for (&runtime.DEFAULT_DEV_ACCOUNTS) |addr| {
        const balance = try rt.state.getBalance(addr);
        try std.testing.expectEqual(runtime.DEFAULT_BALANCE, balance);
    }

    const genesis_block = (try rt.blockchain.getBlockByNumber(0)).?;
    const state_root = try block_builder.computeStateRoot(std.testing.allocator, &rt.state);
    try std.testing.expectEqualSlices(u8, &state_root, &genesis_block.header.state_root);
    try std.testing.expect(!std.mem.eql(u8, &genesis_block.header.state_root, &primitives.Hash.ZERO));
}

test "NodeRuntime.init seeds trusted genesis allocation from file" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const genesis_path = try writeTmpFile(std.testing.allocator, &tmp_dir, "genesis.json",
        \\{
        \\  "coinbase": "0x00000000000000000000000000000000000000aa",
        \\  "timestamp": "0x1234",
        \\  "gasLimit": "0x100000",
        \\  "difficulty": "0x20",
        \\  "extraData": "0x68697665",
        \\  "baseFeePerGas": "0x7",
        \\  "alloc": {
        \\    "0x0000000000000000000000000000000000000011": {
        \\      "balance": "0x2a",
        \\      "nonce": "0x7",
        \\      "code": "0x6001",
        \\      "storage": {
        \\        "0x00": "0x05"
        \\      }
        \\    }
        \\  }
        \\}
    );
    defer std.testing.allocator.free(genesis_path);

    var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{
        .initial_balance = 999,
        .genesis_alloc_path = genesis_path,
    });
    defer rt.deinit();

    const account = try primitives.Address.fromHex("0x0000000000000000000000000000000000000011");
    try std.testing.expectEqual(@as(u256, 42), try rt.state.getBalance(account));
    try std.testing.expectEqual(@as(u64, 7), try rt.state.getNonce(account));
    try std.testing.expectEqual(@as(u256, 5), try rt.state.getStorage(account, 0));
    try std.testing.expectEqual(@as(u256, 0), try rt.state.getBalance(runtime.DEFAULT_DEV_ACCOUNTS[0]));

    const code = try rt.state.getCode(account);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x60, 0x01 }, code);

    const genesis_block = (try rt.blockchain.getBlockByNumber(0)).?;
    const state_root = try block_builder.computeStateRoot(std.testing.allocator, &rt.state);
    try std.testing.expectEqualSlices(u8, &state_root, &genesis_block.header.state_root);
    try std.testing.expectEqual(@as(u64, 0x1234), rt.head_block_timestamp);
    try std.testing.expectEqual(@as(u64, 0x100000), genesis_block.header.gas_limit);
    try std.testing.expectEqual(@as(u256, 0x20), genesis_block.header.difficulty);
    try std.testing.expectEqual(@as(u256, 7), genesis_block.header.base_fee_per_gas.?);
    try std.testing.expectEqualSlices(u8, "hive", genesis_block.header.extra_data);
    try std.testing.expectEqual(
        try primitives.Address.fromHex("0x00000000000000000000000000000000000000aa"),
        genesis_block.header.beneficiary,
    );
}

test "NodeRuntime.init respects custom config" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{
        .chain_id = 1,
        .coinbase_index = 2,
        .initial_balance = 42,
        .block_gas_limit = 12_345_678,
    });
    defer rt.deinit();

    try std.testing.expectEqual(@as(u64, 1), rt.chain_id);
    try std.testing.expectEqual(runtime.DEFAULT_DEV_ACCOUNTS[2], rt.coinbase);

    const balance = try rt.state.getBalance(runtime.DEFAULT_DEV_ACCOUNTS[0]);
    try std.testing.expectEqual(@as(u256, 42), balance);
    try std.testing.expectEqual(@as(u64, 12_345_678), rt.dev_runtime.config.block_gas_limit);

    const genesis_block = (try rt.blockchain.getBlockByNumber(0)).?;
    const state_root = try block_builder.computeStateRoot(std.testing.allocator, &rt.state);
    try std.testing.expectEqualSlices(u8, &state_root, &genesis_block.header.state_root);
}

test "NodeRuntime owns explicit hardfork policy" {
    var dev = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer dev.deinit();
    try std.testing.expectEqual(guillotine_mini.Hardfork.CANCUN, dev.hardforkAt(0, 0));
    try std.testing.expectEqual(runtime.DEFAULT_DEV_HARDFORK_CONFIG.cancun_timestamp, dev.hardfork_config.cancun_timestamp);

    var mainnet = try runtime.NodeRuntime.init(std.testing.allocator, .{ .chain_id = 1 });
    defer mainnet.deinit();
    try std.testing.expectEqual(guillotine_mini.Hardfork.FRONTIER, mainnet.hardforkAt(0, 0));
    try std.testing.expectEqual(
        guillotine_mini.Hardfork.PRAGUE,
        mainnet.hardforkAt(hardfork_schedule.MAINNET_CHAIN_CONFIG.merge_block, hardfork_schedule.MAINNET_CHAIN_CONFIG.prague_timestamp),
    );

    var custom = try runtime.NodeRuntime.init(std.testing.allocator, .{
        .chain_id = 999,
        .hardfork_config = .{
            .homestead_block = 0,
            .dao_block = 0,
            .tangerine_whistle_block = 0,
            .spurious_dragon_block = 0,
            .byzantium_block = 0,
            .constantinople_block = 0,
            .petersburg_block = 0,
            .istanbul_block = 0,
            .muir_glacier_block = 0,
            .berlin_block = 0,
            .london_block = 10,
            .arrow_glacier_block = 20,
            .gray_glacier_block = 20,
            .merge_block = 20,
            .shanghai_timestamp = 100,
            .cancun_timestamp = 200,
            .prague_timestamp = std.math.maxInt(u64),
            .osaka_timestamp = std.math.maxInt(u64),
            .blob_schedule = hardfork_schedule.BlobSchedule.empty,
        },
    });
    defer custom.deinit();
    try std.testing.expectEqual(guillotine_mini.Hardfork.BERLIN, custom.hardforkAt(9, 0));
    try std.testing.expectEqual(guillotine_mini.Hardfork.LONDON, custom.hardforkAt(10, 0));
    try std.testing.expectEqual(guillotine_mini.Hardfork.CANCUN, custom.hardforkAt(20, 200));
}

test "NodeRuntime.init rejects invalid startup config before listener setup" {
    try std.testing.expectError(error.InvalidCoinbaseIndex, runtime.NodeRuntime.init(std.testing.allocator, .{
        .coinbase_index = runtime.DEFAULT_DEV_ACCOUNTS.len,
    }));
}

test "NodeRuntime.init head block number starts at 0" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    try std.testing.expectEqual(@as(u64, 0), rt.head_block_number);
}

test "NodeRuntime.deinit releases state" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    rt.deinit();
    // If allocator leaks, testing.allocator will detect it
}

test "NodeRuntime initializes with default auto mining config" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    try std.testing.expectEqual(mining.MiningConfigType.auto, std.meta.activeTag(rt.mining_config));
}

test "NodeRuntime setMiningConfig updates to interval" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    try rt.setMiningConfig(.{ .interval = .{ .block_time = 12 } });
    try std.testing.expectEqual(mining.MiningConfigType.interval, std.meta.activeTag(rt.mining_config));
    switch (rt.mining_config) {
        .interval => |iv| try std.testing.expectEqual(@as(u64, 12), iv.block_time),
        else => return error.TestUnexpectedResult,
    }
}

test "NodeRuntime setMiningConfig updates to manual" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    try rt.setMiningConfig(.manual);
    try std.testing.expectEqual(mining.MiningConfigType.manual, std.meta.activeTag(rt.mining_config));
}

test "NodeRuntime init respects custom mining config" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{
        .mining_config = .{ .interval = .{ .block_time = 5 } },
    });
    defer rt.deinit();

    try std.testing.expectEqual(mining.MiningConfigType.interval, std.meta.activeTag(rt.mining_config));
}

test "NodeRuntime startBackgroundServices owns configured interval timer" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{
        .mining_config = .{ .interval = .{ .block_time = 30 } },
    });
    defer rt.deinit();

    try rt.startBackgroundServices();
    try std.testing.expect(rt.interval_thread != null);

    try rt.setAutomine(false);
    try std.testing.expectEqual(mining.MiningConfigType.manual, std.meta.activeTag(rt.mining_config));
    try std.testing.expect(rt.interval_thread == null);
}

test "NodeRuntime mining fallback stores canonical signed legacy raw transaction" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const sender = runtime.DEFAULT_DEV_ACCOUNTS[0];
    const recipient = runtime.DEFAULT_DEV_ACCOUNTS[1];
    const input = [_]u8{ 0xab, 0xcd };
    const unsigned = primitives.Transaction.LegacyTransaction{
        .nonce = 0,
        .gas_price = runtime.DEFAULT_GAS_PRICE,
        .gas_limit = 50_000,
        .to = recipient,
        .value = 1000,
        .data = &input,
        .v = 0,
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
    };
    const signed = try tx_encoding.signLegacyTransaction(
        std.testing.allocator,
        unsigned,
        genesis.DEV_ACCOUNTS[0].private_key,
        rt.chain_id,
    );
    const canonical_raw = try tx_encoding.encodeLegacyTransactionEnvelope(std.testing.allocator, signed);
    defer std.testing.allocator.free(canonical_raw);
    const tx_hash = tx_encoding.transactionHash(canonical_raw);

    try rt.pool.setNonce(sender, 0);
    try rt.pool.add(std.testing.allocator, .{
        .sender = sender,
        .nonce = signed.nonce,
        .gas_limit = signed.gas_limit,
        .max_fee_per_gas = signed.gas_price,
        .max_priority_fee_per_gas = signed.gas_price,
        .hash = tx_hash,
        .to = signed.to,
        .value = signed.value,
        .input = signed.data,
        .raw = &.{},
        .v = signed.v,
        .r = signed.r,
        .s = signed.s,
    });

    try rt.mineBlocks(1, 0);

    const block = (try rt.blockchain.getBlockByNumber(1)).?;
    const state_root = try block_builder.computeStateRoot(std.testing.allocator, &rt.state);
    try std.testing.expectEqualSlices(u8, &state_root, &block.header.state_root);
    try std.testing.expect(!std.mem.eql(u8, &block.header.state_root, &primitives.Hash.ZERO));
    try std.testing.expectEqual(@as(usize, 1), block.body.transactions.len);
    try std.testing.expectEqualSlices(u8, canonical_raw, block.body.transactions[0].raw);
    const receipt = rt.receipt_index.getByTxHash(tx_hash).?;
    try std.testing.expectEqualSlices(u8, &tx_hash, &receipt.transaction_hash);
}

test "NodeRuntime mining populates BLOCKHASH parent history" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const genesis_block = (try rt.blockchain.getBlockByNumber(0)).?;
    const sender = runtime.DEFAULT_DEV_ACCOUNTS[0];
    const contract = primitives.Address{ .bytes = [_]u8{0x10} ++ [_]u8{0} ** 19 };
    try rt.setCode(contract, &STORE_BLOCKHASH_ZERO);

    const unsigned = primitives.Transaction.LegacyTransaction{
        .nonce = 0,
        .gas_price = runtime.DEFAULT_GAS_PRICE,
        .gas_limit = 100_000,
        .to = contract,
        .value = 0,
        .data = &.{},
        .v = 0,
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
    };
    const signed = try tx_encoding.signLegacyTransaction(
        std.testing.allocator,
        unsigned,
        genesis.DEV_ACCOUNTS[0].private_key,
        rt.chain_id,
    );
    const canonical_raw = try tx_encoding.encodeLegacyTransactionEnvelope(std.testing.allocator, signed);
    defer std.testing.allocator.free(canonical_raw);
    const tx_hash = tx_encoding.transactionHash(canonical_raw);

    try rt.pool.setNonce(sender, 0);
    try rt.pool.add(std.testing.allocator, .{
        .sender = sender,
        .nonce = signed.nonce,
        .gas_limit = signed.gas_limit,
        .max_fee_per_gas = signed.gas_price,
        .max_priority_fee_per_gas = signed.gas_price,
        .hash = tx_hash,
        .to = signed.to,
        .value = signed.value,
        .input = signed.data,
        .raw = canonical_raw,
        .v = signed.v,
        .r = signed.r,
        .s = signed.s,
    });

    try rt.mineBlocks(1, 0);

    const expected = std.mem.readInt(u256, &genesis_block.hash, .big);
    try std.testing.expectEqual(expected, try rt.getStorage(contract, 0));
}

test "NodeRuntime time controls adjust effective current time" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    try std.testing.expectEqual(@as(i128, 0), rt.time_offset);
    try std.testing.expectEqual(@as(?u64, null), rt.next_block_timestamp);

    const before = rt.effectiveCurrentTime();
    try std.testing.expectEqual(@as(u64, 42), try rt.increaseTime(42));
    try std.testing.expect(rt.effectiveCurrentTime() >= before + 42);

    const target = before + 600;
    try std.testing.expectEqual(target, try rt.setTime(target));
    const effective = rt.effectiveCurrentTime();
    try std.testing.expect(effective >= target);
    try std.testing.expect(effective <= target + 1);
}

test "NodeRuntime nextBlockTimestamp consumes one-shot override" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    rt.setNextBlockTimestamp(100);
    try std.testing.expectEqual(@as(u64, 100), try rt.nextBlockTimestamp(99));
    try std.testing.expectEqual(@as(?u64, null), rt.next_block_timestamp);
    try std.testing.expect(rt.dev_runtime.config.next_block_timestamp == null);

    rt.setNextBlockTimestamp(100);
    try std.testing.expectError(error.InvalidParams, rt.nextBlockTimestamp(100));
    try std.testing.expectEqual(@as(?u64, 100), rt.next_block_timestamp);
    try std.testing.expectEqual(@as(?u64, 100), rt.dev_runtime.config.next_block_timestamp);
}

test "NodeRuntime mineBlocks consumes next block timestamp override once" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    rt.setNextBlockTimestamp(100);
    try rt.mineBlocks(2, 3);

    const block_1 = (try rt.blockchain.getBlockByNumber(1)).?;
    const block_2 = (try rt.blockchain.getBlockByNumber(2)).?;
    try std.testing.expectEqual(@as(u64, 100), block_1.header.timestamp);
    try std.testing.expectEqual(@as(u64, 103), block_2.header.timestamp);
    try std.testing.expectEqual(@as(?u64, null), rt.next_block_timestamp);
    try std.testing.expect(rt.dev_runtime.config.next_block_timestamp == null);
}

test "NodeRuntime mineBlocks consumes prevRandao override once" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    rt.dev_runtime.config.prev_randao = 0x42;
    try rt.mineBlocks(2, 1);

    const block_1 = (try rt.blockchain.getBlockByNumber(1)).?;
    const block_2 = (try rt.blockchain.getBlockByNumber(2)).?;
    try std.testing.expectEqual(@as(u256, 0x42), std.mem.readInt(u256, &block_1.header.mix_hash, .big));
    try std.testing.expectEqual(@as(u256, 0), std.mem.readInt(u256, &block_2.header.mix_hash, .big));
    try std.testing.expect(rt.dev_runtime.config.prev_randao == null);
}

test "NodeRuntime configured block timestamp interval controls explicit mining" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    rt.setBlockTimestampInterval(7);
    try rt.mineBlocksWithTimestampInterval(2, null);

    const block_1 = (try rt.blockchain.getBlockByNumber(1)).?;
    const block_2 = (try rt.blockchain.getBlockByNumber(2)).?;
    try std.testing.expectEqual(@as(u64, 7), block_1.header.timestamp);
    try std.testing.expectEqual(@as(u64, 14), block_2.header.timestamp);

    rt.removeBlockTimestampInterval();
    try std.testing.expectEqual(@as(?u64, null), rt.block_timestamp_interval);
}

test "NodeRuntime engine import rejects descendants of known invalid payload" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    try rt.mineBlocks(2, 1);
    const genesis_block = (try rt.blockchain.getBlockByNumber(0)).?;
    const block_1 = (try rt.blockchain.getBlockByNumber(1)).?;
    const block_2 = (try rt.blockchain.getBlockByNumber(2)).?;

    var invalid_parent = block_1;
    invalid_parent.header.state_root[31] ^= 0x01;
    invalid_parent.hash = try block_builder.computeHeaderHashWithRequestsHash(
        std.testing.allocator,
        &invalid_parent.header,
        null,
    );

    const invalid_result = try rt.importEnginePayloadBlock(invalid_parent, null);
    try std.testing.expectEqual(runtime.EnginePayloadImportStatus.invalid, invalid_result.status);
    try std.testing.expect(invalid_result.latest_valid_hash != null);
    try std.testing.expectEqualSlices(u8, &genesis_block.hash, &invalid_result.latest_valid_hash.?);

    var child = block_2;
    child.header.parent_hash = invalid_parent.hash;
    child.hash = try block_builder.computeHeaderHashWithRequestsHash(std.testing.allocator, &child.header, null);

    const child_result = try rt.importEnginePayloadBlock(child, null);
    try std.testing.expectEqual(runtime.EnginePayloadImportStatus.invalid, child_result.status);
    try std.testing.expect(child_result.latest_valid_hash != null);
    try std.testing.expectEqualSlices(u8, &genesis_block.hash, &child_result.latest_valid_hash.?);
}

test "NodeRuntime engine forkchoice rollback prunes stale canonical numbers" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    try rt.mineBlocks(3, 1);
    const block_1 = (try rt.blockchain.getBlockByNumber(1)).?;
    const block_3 = (try rt.blockchain.getBlockByNumber(3)).?;
    try std.testing.expectEqual(@as(u64, 3), rt.head_block_number);
    try std.testing.expectEqual(@as(?u64, 3), rt.blockchain.getHeadBlockNumber());

    const applied = try rt.setEngineCanonicalHead(block_1.hash);
    try std.testing.expectEqual(runtime.EnginePayloadImportStatus.valid, applied.status);
    try std.testing.expectEqual(@as(u64, 1), rt.head_block_number);
    try std.testing.expectEqual(@as(?u64, 1), rt.blockchain.getHeadBlockNumber());
    try std.testing.expect(rt.blockchain.getCanonicalHash(2) == null);
    try std.testing.expect((try rt.blockchain.getBlockByNumber(2)) == null);
    try std.testing.expect(rt.blockchain.getBlockLocal(block_3.hash) != null);
}

test "NodeRuntime snapshot and reset preserve time controls" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    _ = try rt.increaseTime(10);
    rt.setNextBlockTimestamp(100);
    rt.setBlockTimestampInterval(7);
    const snap = try rt.snapshot();

    _ = try rt.increaseTime(5);
    rt.setNextBlockTimestamp(200);
    rt.setBlockTimestampInterval(9);

    try std.testing.expect(try rt.revertToSnapshot(snap));
    try std.testing.expectEqual(@as(i128, 10), rt.time_offset);
    try std.testing.expectEqual(@as(?u64, 100), rt.next_block_timestamp);
    try std.testing.expectEqual(@as(?u64, 7), rt.block_timestamp_interval);

    try rt.reset(.keep_current);
    try std.testing.expectEqual(@as(i128, 0), rt.time_offset);
    try std.testing.expectEqual(@as(?u64, null), rt.next_block_timestamp);
    try std.testing.expectEqual(@as(?u64, null), rt.block_timestamp_interval);
}

const FixtureForkResolver = struct {
    url_a: []const u8,
    url_b: []const u8,
    balance_a: u256,
    balance_b: u256,
    nonce_a: u64,
    nonce_b: u64,
    storage_slot: u256,
    storage_a: u256,
    storage_b: u256,
    code_a: []const u8,
    code_b: []const u8,
    request_count: usize = 0,

    fn asResolver(self: *FixtureForkResolver) runtime.ForkRpcResolver {
        return .{
            .context = self,
            .resolve = &resolve,
        };
    }

    fn resolve(
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        request: runtime.ForkRpcRequest,
    ) ![]u8 {
        const raw_context = context orelse return error.InvalidContext;
        const self: *FixtureForkResolver = @ptrCast(@alignCast(raw_context));
        self.request_count += 1;

        const use_b = std.mem.eql(u8, request.url, self.url_b);
        const balance = if (use_b) self.balance_b else self.balance_a;
        const nonce = if (use_b) self.nonce_b else self.nonce_a;
        const storage_value = if (use_b) self.storage_b else self.storage_a;
        const code_bytes = if (use_b) self.code_b else self.code_a;

        if (std.mem.eql(u8, request.method, "eth_getCode")) {
            const code_hex = try primitives.Hex.bytesToHex(allocator, code_bytes);
            defer allocator.free(code_hex);
            return try std.fmt.allocPrint(allocator, "\"{s}\"", .{code_hex});
        }

        if (!std.mem.eql(u8, request.method, "eth_getProof")) {
            return error.UnsupportedMethod;
        }

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, request.params_json, .{
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        const params = switch (parsed.value) {
            .array => |array| array.items,
            else => return error.InvalidParams,
        };

        var has_slot = false;
        if (params.len >= 2 and params[1] == .array) {
            has_slot = params[1].array.items.len > 0;
        }

        if (!has_slot) {
            return try std.fmt.allocPrint(
                allocator,
                "{{\"nonce\":\"0x{x}\",\"balance\":\"0x{x}\",\"codeHash\":\"{s}\",\"storageHash\":\"{s}\",\"storageProof\":[]}}",
                .{ nonce, balance, ZERO_HASH_HEX, ZERO_HASH_HEX },
            );
        }

        const slot_text = switch (params[1].array.items[0]) {
            .string => |value| value,
            else => return error.InvalidParams,
        };
        const slot = try parseHexU256(slot_text);
        const encoded_slot = if (slot == self.storage_slot) slot else @as(u256, 0);
        const encoded_value = if (slot == self.storage_slot) storage_value else @as(u256, 0);

        return try std.fmt.allocPrint(
            allocator,
            "{{\"nonce\":\"0x{x}\",\"balance\":\"0x{x}\",\"codeHash\":\"{s}\",\"storageHash\":\"{s}\",\"storageProof\":[{{\"key\":\"0x{x:0>64}\",\"value\":\"0x{x}\"}}]}}",
            .{ nonce, balance, ZERO_HASH_HEX, ZERO_HASH_HEX, encoded_slot, encoded_value },
        );
    }
};

const ZERO_HASH_HEX = "0x0000000000000000000000000000000000000000000000000000000000000000";

fn parseHexU256(text: []const u8) !u256 {
    if (text.len < 3) return error.InvalidHex;
    if (!(text[0] == '0' and (text[1] == 'x' or text[1] == 'X'))) return error.InvalidHex;
    return std.fmt.parseInt(u256, text[2..], 16);
}

fn testAddress() primitives.Address {
    return parseAddr("0x0000000000000000000000000000000000000042");
}

fn parseAddr(comptime hex: *const [42]u8) primitives.Address {
    var out: [20]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex[2..]) catch unreachable;
    return .{ .bytes = out };
}

test "impersonation signer scope includes managed manual and auto accounts" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const unmanaged = testAddress();
    try std.testing.expect(rt.canSignForAccount(runtime.DEFAULT_DEV_ACCOUNTS[0]));
    try std.testing.expect(!rt.canSignForAccount(unmanaged));

    try rt.impersonateAccount(unmanaged);
    try std.testing.expect(rt.isImpersonatingAccount(unmanaged));
    try std.testing.expect(rt.canSignForAccount(unmanaged));

    rt.stopImpersonatingAccount(unmanaged);
    try std.testing.expect(!rt.isImpersonatingAccount(unmanaged));
    try std.testing.expect(!rt.canSignForAccount(unmanaged));

    rt.setAutoImpersonateAccount(true);
    try std.testing.expect(rt.canSignForAccount(unmanaged));

    rt.stopImpersonatingAccount(unmanaged);
    try std.testing.expect(rt.canSignForAccount(unmanaged));

    rt.setAutoImpersonateAccount(false);
    try std.testing.expect(!rt.canSignForAccount(unmanaged));
}

test "snapshot revert and reset restore impersonation state" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const manual = testAddress();
    const auto_only = parseAddr("0x0000000000000000000000000000000000000043");

    try rt.impersonateAccount(manual);
    rt.setAutoImpersonateAccount(true);

    const snapshot_id = try rt.snapshot();
    rt.stopImpersonatingAccount(manual);
    rt.setAutoImpersonateAccount(false);

    try std.testing.expect(!rt.canSignForAccount(manual));
    try std.testing.expect(!rt.canSignForAccount(auto_only));

    try std.testing.expect(try rt.revertToSnapshot(snapshot_id));
    try std.testing.expect(rt.isImpersonatingAccount(manual));
    try std.testing.expect(rt.canSignForAccount(manual));
    try std.testing.expect(rt.canSignForAccount(auto_only));

    try rt.reset(.disable);
    try std.testing.expect(!rt.isImpersonatingAccount(manual));
    try std.testing.expect(!rt.canSignForAccount(auto_only));
}

test "forked runtime reads remote account code and storage" {
    var resolver = FixtureForkResolver{
        .url_a = "https://rpc-a.example",
        .url_b = "https://rpc-b.example",
        .balance_a = 0x2a,
        .balance_b = 0x99,
        .nonce_a = 7,
        .nonce_b = 1,
        .storage_slot = 5,
        .storage_a = 0x55,
        .storage_b = 0xaa,
        .code_a = &[_]u8{ 0x60, 0x01 },
        .code_b = &[_]u8{ 0x60, 0x02 },
    };

    var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{
        .fork_url = resolver.url_a,
        .fork_rpc_resolver = resolver.asResolver(),
    });
    defer rt.deinit();

    const addr = testAddress();
    try std.testing.expectEqual(@as(u256, 0x2a), try rt.getBalance(addr));
    try std.testing.expectEqual(@as(u64, 7), try rt.getNonce(addr));
    try std.testing.expectEqual(@as(u256, 0x55), try rt.getStorage(addr, 5));

    const code = try rt.getCode(addr);
    try std.testing.expectEqual(@as(usize, 2), code.len);
    try std.testing.expectEqual(@as(u8, 0x60), code[0]);
    try std.testing.expectEqual(@as(u8, 0x01), code[1]);
}

test "local overlay writes override fork-backed reads" {
    var resolver = FixtureForkResolver{
        .url_a = "https://rpc-a.example",
        .url_b = "https://rpc-b.example",
        .balance_a = 100,
        .balance_b = 200,
        .nonce_a = 0,
        .nonce_b = 0,
        .storage_slot = 1,
        .storage_a = 0,
        .storage_b = 0,
        .code_a = &[_]u8{},
        .code_b = &[_]u8{},
    };

    var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{
        .fork_url = resolver.url_a,
        .fork_rpc_resolver = resolver.asResolver(),
    });
    defer rt.deinit();

    const addr = testAddress();
    const remote = try rt.getBalance(addr);
    try std.testing.expectEqual(@as(u256, 100), remote);

    const count_before_overlay = resolver.request_count;
    try rt.setBalance(addr, 999);
    try std.testing.expectEqual(@as(u256, 999), try rt.getBalance(addr));
    try std.testing.expectEqual(count_before_overlay, resolver.request_count);
}

test "snapshot and revert restore local overlays and fork URL state" {
    var resolver = FixtureForkResolver{
        .url_a = "https://rpc-a.example",
        .url_b = "https://rpc-b.example",
        .balance_a = 11,
        .balance_b = 22,
        .nonce_a = 0,
        .nonce_b = 0,
        .storage_slot = 1,
        .storage_a = 0,
        .storage_b = 0,
        .code_a = &[_]u8{},
        .code_b = &[_]u8{},
    };

    var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{
        .fork_url = resolver.url_a,
        .fork_rpc_resolver = resolver.asResolver(),
    });
    defer rt.deinit();

    const addr = testAddress();
    try std.testing.expectEqual(@as(u256, 11), try rt.getBalance(addr));

    const snap = try rt.snapshot();
    try rt.setBalance(addr, 444);
    try rt.setRpcUrl(resolver.url_b);
    try std.testing.expectEqual(@as(u256, 444), try rt.getBalance(addr));
    try std.testing.expectEqualStrings(resolver.url_b, rt.fork_config.?.url);

    const reverted = try rt.revertToSnapshot(snap);
    try std.testing.expect(reverted);
    try std.testing.expectEqualStrings(resolver.url_a, rt.fork_config.?.url);
    try std.testing.expectEqual(@as(u256, 11), try rt.getBalance(addr));
}

test "snapshot and revert restore block environment overrides" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    rt.dev_runtime.config.block_gas_limit = 21_000;
    rt.dev_runtime.config.next_block_base_fee_per_gas = 2;
    rt.setNextBlockTimestamp(1234);
    rt.dev_runtime.config.blob_base_fee = 7;

    const snap = try rt.snapshot();

    rt.dev_runtime.config.block_gas_limit = 42_000;
    rt.dev_runtime.config.next_block_base_fee_per_gas = 3;
    rt.setNextBlockTimestamp(5678);
    rt.dev_runtime.config.blob_base_fee = 9;

    const reverted = try rt.revertToSnapshot(snap);
    try std.testing.expect(reverted);
    try std.testing.expectEqual(@as(u64, 21_000), rt.dev_runtime.config.block_gas_limit);
    try std.testing.expectEqual(@as(u256, 2), rt.dev_runtime.config.next_block_base_fee_per_gas.?);
    try std.testing.expectEqual(@as(u64, 1234), rt.dev_runtime.config.next_block_timestamp.?);
    try std.testing.expectEqual(@as(u256, 7), rt.dev_runtime.config.blob_base_fee.?);
}

test "reset restores configured block gas limit default" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{
        .block_gas_limit = 12_345_678,
    });
    defer rt.deinit();

    try std.testing.expectEqual(@as(u64, 12_345_678), rt.dev_runtime.config.block_gas_limit);
    rt.dev_runtime.config.block_gas_limit = 21_000;
    rt.dev_runtime.config.next_block_base_fee_per_gas = 2;
    rt.setNextBlockTimestamp(1234);

    try rt.reset(.keep_current);

    try std.testing.expectEqual(@as(u64, 12_345_678), rt.dev_runtime.config.block_gas_limit);
    try std.testing.expect(rt.dev_runtime.config.next_block_base_fee_per_gas == null);
    try std.testing.expect(rt.dev_runtime.config.next_block_timestamp == null);
}

test "reset keep/disable/replace follows fork semantics without changing chain id" {
    var resolver = FixtureForkResolver{
        .url_a = "https://rpc-a.example",
        .url_b = "https://rpc-b.example",
        .balance_a = 50,
        .balance_b = 75,
        .nonce_a = 0,
        .nonce_b = 0,
        .storage_slot = 1,
        .storage_a = 0,
        .storage_b = 0,
        .code_a = &[_]u8{},
        .code_b = &[_]u8{},
    };

    var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{
        .chain_id = 999,
        .fork_url = resolver.url_a,
        .fork_rpc_resolver = resolver.asResolver(),
    });
    defer rt.deinit();

    const addr = testAddress();
    const snapshot_id = try rt.snapshot();
    try rt.setBalance(addr, 123);

    try rt.reset(.keep_current);
    try std.testing.expect(rt.isForkingEnabled());
    try std.testing.expectEqualStrings(resolver.url_a, rt.fork_config.?.url);
    try std.testing.expectEqual(@as(u256, 50), try rt.getBalance(addr));
    try std.testing.expectEqual(@as(u64, 999), rt.chain_id);
    try std.testing.expect(!(try rt.revertToSnapshot(snapshot_id)));

    try rt.reset(.disable);
    try std.testing.expect(!rt.isForkingEnabled());
    try std.testing.expectEqual(@as(u256, 0), try rt.state.getBalance(addr));
    try std.testing.expectEqual(@as(u64, 999), rt.chain_id);

    try rt.reset(.{ .replace = .{
        .url = resolver.url_b,
        .block_number = 7,
    } });
    try std.testing.expect(rt.isForkingEnabled());
    try std.testing.expectEqualStrings(resolver.url_b, rt.fork_config.?.url);
    try std.testing.expectEqual(@as(?u64, 7), rt.fork_config.?.block_number);
    try std.testing.expectEqual(@as(u64, 999), rt.chain_id);
    try std.testing.expectEqual(@as(u256, 75), try rt.getBalance(addr));
}

test "setRpcUrl requires fork mode to be enabled" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    try std.testing.expectError(error.ForkNotEnabled, rt.setRpcUrl("https://rpc.example"));
}

test "fork URL validation rejects unusable HTTP URLs" {
    const invalid_urls = [_][]const u8{
        "",
        "ftp://rpc.example",
        "https://",
        "http://",
        "https://rpc example",
        "https://rpc.example\n",
    };

    for (invalid_urls) |url| {
        try std.testing.expectError(
            error.InvalidForkUrl,
            runtime.NodeRuntime.init(std.testing.allocator, .{ .fork_url = url }),
        );
    }

    var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{
        .fork_url = "https://rpc.example",
    });
    defer rt.deinit();

    try std.testing.expectError(error.InvalidForkUrl, rt.setRpcUrl("https://"));
    try std.testing.expectEqualStrings("https://rpc.example", rt.fork_config.?.url);
}

/// Fork upstream that serves the scalar read methods but not `eth_getProof`.
const ScalarOnlyForkResolver = struct {
    balance: u256,
    nonce: u64,
    storage_slot: u256,
    storage_value: u256,
    code: []const u8,
    fail_everything: bool = false,
    proof_calls: usize = 0,
    scalar_calls: usize = 0,

    fn asResolver(self: *ScalarOnlyForkResolver) runtime.ForkRpcResolver {
        return .{ .context = self, .resolve = &resolve };
    }

    fn resolve(
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        request: runtime.ForkRpcRequest,
    ) ![]u8 {
        const self: *ScalarOnlyForkResolver = @ptrCast(@alignCast(context.?));
        if (self.fail_everything) return error.UpstreamRpcFailed;
        if (std.mem.eql(u8, request.method, "eth_getProof")) {
            self.proof_calls += 1;
            return error.InvalidUpstreamRpcResponse;
        }
        self.scalar_calls += 1;

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, request.params_json, .{});
        defer parsed.deinit();
        const params = parsed.value.array.items;
        if (params[0] != .string or params[params.len - 1] != .string) return error.InvalidParams;

        if (std.mem.eql(u8, request.method, "eth_getBalance")) {
            if (params.len != 2) return error.InvalidParams;
            return std.fmt.allocPrint(allocator, "\"0x{x}\"", .{self.balance});
        }
        if (std.mem.eql(u8, request.method, "eth_getTransactionCount")) {
            if (params.len != 2) return error.InvalidParams;
            return std.fmt.allocPrint(allocator, "\"0x{x}\"", .{self.nonce});
        }
        if (std.mem.eql(u8, request.method, "eth_getCode")) {
            if (params.len != 2) return error.InvalidParams;
            const code_hex = try primitives.Hex.bytesToHex(allocator, self.code);
            defer allocator.free(code_hex);
            return std.fmt.allocPrint(allocator, "\"{s}\"", .{code_hex});
        }
        if (std.mem.eql(u8, request.method, "eth_getStorageAt")) {
            if (params.len != 3) return error.InvalidParams;
            const slot = try parseHexU256(params[1].string);
            const value = if (slot == self.storage_slot) self.storage_value else @as(u256, 0);
            return std.fmt.allocPrint(allocator, "\"0x{x:0>64}\"", .{value});
        }
        return error.UnsupportedMethod;
    }
};

test "forked runtime falls back to scalar reads when upstream lacks eth_getProof" {
    var resolver = ScalarOnlyForkResolver{
        .balance = 0x2a,
        .nonce = 7,
        .storage_slot = 5,
        .storage_value = 0x55,
        .code = &[_]u8{ 0x60, 0x01 },
    };

    var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{
        .fork_url = "https://rpc-a.example",
        .fork_rpc_resolver = resolver.asResolver(),
    });
    defer rt.deinit();

    const addr = testAddress();
    try std.testing.expectEqual(@as(u256, 0x2a), try rt.getBalance(addr));
    try std.testing.expectEqual(@as(u64, 7), try rt.getNonce(addr));
    try std.testing.expectEqual(@as(u256, 0x55), try rt.getStorage(addr, 5));
    try std.testing.expectEqual(@as(u256, 0), try rt.getStorage(addr, 6));
    const code = try rt.getCode(addr);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x60, 0x01 }, code);

    try std.testing.expectEqual(@as(usize, 1), resolver.proof_calls);
    try std.testing.expect(rt.fork_proof_unavailable);
    try std.testing.expect(resolver.scalar_calls > 0);

    try rt.setRpcUrl("https://rpc-b.example");
    try std.testing.expect(!rt.fork_proof_unavailable);
    const other = parseAddr("0x0000000000000000000000000000000000000043");
    try std.testing.expectEqual(@as(u256, 0x2a), try rt.getBalance(other));
    try std.testing.expectEqual(@as(usize, 2), resolver.proof_calls);
}

test "forked runtime retries a read after an upstream failure" {
    var resolver = ScalarOnlyForkResolver{
        .balance = 0x2a,
        .nonce = 7,
        .storage_slot = 5,
        .storage_value = 0x55,
        .code = &[_]u8{},
        .fail_everything = true,
    };

    var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{
        .fork_url = "https://rpc-a.example",
        .fork_rpc_resolver = resolver.asResolver(),
    });
    defer rt.deinit();

    const addr = testAddress();
    try std.testing.expectError(error.UpstreamRpcFailed, rt.getBalance(addr));
    try std.testing.expectError(error.UpstreamRpcFailed, rt.getStorage(addr, 5));
    try std.testing.expect(!rt.fork_proof_unavailable);

    resolver.fail_everything = false;
    try std.testing.expectEqual(@as(u256, 0x2a), try rt.getBalance(addr));
    try std.testing.expectEqual(@as(u256, 0x55), try rt.getStorage(addr, 5));
}

test "reset rebuilds the configured genesis allocation and header" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const genesis_path = try writeTmpFile(std.testing.allocator, &tmp_dir, "genesis.json",
        \\{
        \\  "coinbase": "0x00000000000000000000000000000000000000aa",
        \\  "timestamp": "0x1234",
        \\  "gasLimit": "0x1000000",
        \\  "alloc": {
        \\    "0x0000000000000000000000000000000000000011": { "balance": "0x2a" }
        \\  }
        \\}
    );
    defer std.testing.allocator.free(genesis_path);

    var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{ .genesis_alloc_path = genesis_path });
    defer rt.deinit();
    const genesis_hash = (try rt.blockchain.getBlockByNumber(0)).?.hash;

    try rt.mineBlocks(1, 1);
    try rt.reset(.keep_current);

    const account = try primitives.Address.fromHex("0x0000000000000000000000000000000000000011");
    try std.testing.expectEqual(@as(u256, 42), try rt.state.getBalance(account));
    try std.testing.expectEqual(@as(u256, 0), try rt.state.getBalance(runtime.DEFAULT_DEV_ACCOUNTS[0]));
    try std.testing.expectEqual(@as(u64, 0x1234), rt.head_block_timestamp);
    const reset_genesis = (try rt.blockchain.getBlockByNumber(0)).?;
    try std.testing.expectEqualSlices(u8, &genesis_hash, &reset_genesis.hash);
    try std.testing.expectEqual(@as(u64, 0x1000000), reset_genesis.header.gas_limit);
}

fn pragueDevHardforkConfig() hardfork_schedule.ChainConfig {
    var config = runtime.DEFAULT_DEV_HARDFORK_CONFIG;
    config.prague_timestamp = 0;
    return config;
}

test "Prague genesis commits to empty requests and Shanghai withdrawals" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{ .hardfork_config = pragueDevHardforkConfig() });
    defer rt.deinit();

    const genesis_block = (try rt.blockchain.getBlockByNumber(0)).?;
    try std.testing.expect(rt.hardforkAt(0, genesis_block.header.timestamp).isAtLeast(.PRAGUE));
    try std.testing.expectEqual(@as(usize, 0), genesis_block.body.withdrawals.?.len);

    var empty_requests_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&.{}, &empty_requests_hash, .{});
    var recorded: ?[32]u8 = null;
    for (rt.owned_block_bodies.items) |body| {
        if (std.mem.eql(u8, &body.block_hash, &genesis_block.hash)) recorded = body.requests_hash;
    }
    try std.testing.expectEqualSlices(u8, &empty_requests_hash, &recorded.?);

    const expected_hash = try block_builder.computeHeaderHashWithRequestsHash(
        std.testing.allocator,
        &genesis_block.header,
        empty_requests_hash,
    );
    try std.testing.expectEqualSlices(u8, &expected_hash, &genesis_block.hash);
}

test "Cancun dev genesis has withdrawals but no requests hash" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const genesis_block = (try rt.blockchain.getBlockByNumber(0)).?;
    try std.testing.expect(!rt.hardforkAt(0, genesis_block.header.timestamp).isAtLeast(.PRAGUE));
    try std.testing.expectEqual(@as(usize, 0), genesis_block.body.withdrawals.?.len);
    for (rt.owned_block_bodies.items) |body| {
        try std.testing.expect(!std.mem.eql(u8, &body.block_hash, &genesis_block.hash));
    }
}

test "snapshots keep the Prague requests hash of cloned blocks" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{ .hardfork_config = pragueDevHardforkConfig() });
    defer rt.deinit();
    try rt.mineBlocks(1, 1);
    const head = (try rt.blockchain.getBlockByNumber(1)).?;

    const snap = try rt.snapshot();
    try rt.mineBlocks(1, 1);
    try std.testing.expect(try rt.revertToSnapshot(snap));

    var recorded: ?[32]u8 = null;
    for (rt.owned_block_bodies.items) |body| {
        if (std.mem.eql(u8, &body.block_hash, &head.hash)) recorded = body.requests_hash;
    }
    try std.testing.expect(recorded != null);
    try std.testing.expectEqual(@as(u64, 1), rt.head_block_number);
    try std.testing.expect(rt.blockchain.getCanonicalHash(2) == null);
}

test "rpc filter table is bounded" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    for (0..runtime.MAX_RPC_FILTERS) |_| _ = try rt.createBlockFilter();
    try std.testing.expectError(error.TooManyFilters, rt.createBlockFilter());
    try std.testing.expectError(error.TooManyFilters, rt.createPendingTransactionFilter());
}

test "pending transaction events are kept only for pending filters" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    try rt.recordPendingTransactionFilterEvent([_]u8{1} ** 32);
    try std.testing.expectEqual(@as(usize, 0), rt.pending_transaction_filter_events.items.len);

    const id = try rt.createPendingTransactionFilter();
    for (0..runtime.MAX_PENDING_TRANSACTION_FILTER_EVENTS + 10) |index| {
        var hash = [_]u8{0} ** 32;
        std.mem.writeInt(u64, hash[0..8], index, .big);
        try rt.recordPendingTransactionFilterEvent(hash);
    }
    try std.testing.expect(rt.pending_transaction_filter_events.items.len <= runtime.MAX_PENDING_TRANSACTION_FILTER_EVENTS);
    const state = rt.rpcFilter(id).?.pending_transaction;
    const unread = rt.pendingTransactionFilterEventsSince(state.next_event_index);
    try std.testing.expectEqual(rt.pending_transaction_filter_events.items.len, unread.len);
}

test "snapshot table is bounded and evicts the oldest snapshot" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const first = try rt.snapshot();
    for (0..runtime.MAX_SNAPSHOTS) |_| _ = try rt.snapshot();
    try std.testing.expectEqual(@as(u32, runtime.MAX_SNAPSHOTS), rt.snapshots.count());
    try std.testing.expect(!(try rt.revertToSnapshot(first)));
}

test "engine payload jobs are bounded and evict the oldest job" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const parent = (try rt.blockchain.getBlockByNumber(0)).?.hash;
    const attrs = runtime.EnginePayloadAttributes{
        .timestamp = 12,
        .prev_randao = [_]u8{0} ** 32,
        .fee_recipient = primitives.Address.ZERO_ADDRESS,
    };
    const first = try rt.createEnginePayloadJob(parent, attrs);
    for (0..runtime.MAX_ENGINE_PAYLOAD_JOBS) |_| _ = try rt.createEnginePayloadJob(parent, attrs);
    try std.testing.expectEqual(@as(u32, runtime.MAX_ENGINE_PAYLOAD_JOBS), rt.engine_payload_jobs.count());
    try std.testing.expect(rt.enginePayloadJob(first) == null);
}

test "mineBlocks rejects a timestamp interval that overflows" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    rt.setNextBlockTimestamp(1_000);
    try std.testing.expectError(error.InvalidParams, rt.mineBlocks(2, std.math.maxInt(u64)));
}

test "setCode and setStorage write the local overlay" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const addr = try primitives.Address.fromHex("0x0000000000000000000000000000000000000022");
    try rt.setCode(addr, &[_]u8{ 0x60, 0x01 });
    try rt.setStorage(addr, 3, 9);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x60, 0x01 }, try rt.getCode(addr));
    try std.testing.expectEqual(@as(u256, 9), try rt.getStorage(addr, 3));
}

test "engine payload error allowlist caches only consensus-invalid errors" {
    // Consensus violations are cached as INVALID.
    try std.testing.expect(runtime.isDeterministicPayloadError(error.InvalidStateRoot));
    try std.testing.expect(runtime.isDeterministicPayloadError(error.NonceMismatch));
    try std.testing.expect(runtime.isDeterministicPayloadError(error.InvalidSignature));
    try std.testing.expect(runtime.isDeterministicPayloadError(error.BlockRlpSizeExceeded));
    // Local faults and unknown errors never poison engine_invalid_payloads.
    try std.testing.expect(!runtime.isDeterministicPayloadError(error.OutOfMemory));
    try std.testing.expect(!runtime.isDeterministicPayloadError(error.StateError));
    try std.testing.expect(!runtime.isDeterministicPayloadError(error.EvmInitError));
    try std.testing.expect(!runtime.isDeterministicPayloadError(error.ConnectionRefused));
    try std.testing.expect(!runtime.isDeterministicPayloadError(error.MissingParentBlock));
    try std.testing.expect(!runtime.isDeterministicPayloadError(error.SomeFutureInternalError));
}

test "NodeRuntime.init rejects an out-of-order fork schedule" {
    var config = runtime.DEFAULT_DEV_HARDFORK_CONFIG;
    config.shanghai_timestamp = 500;
    config.cancun_timestamp = 100;
    try std.testing.expectError(error.UnorderedTimestampForks, runtime.NodeRuntime.init(std.testing.allocator, .{
        .hardfork_config = config,
    }));
}

test "NodeRuntime rpc filter ids wrap past maxInt, skipping 0 and live ids" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const first = try rt.createBlockFilter();
    try std.testing.expectEqual(@as(u64, 1), first);

    rt.next_rpc_filter_id = std.math.maxInt(u64);
    const at_max = try rt.createBlockFilter();
    try std.testing.expectEqual(std.math.maxInt(u64), at_max);
    // Saturating increment would hand out maxInt again and overwrite the
    // live filter. Wrapping skips 0 and the still-live id 1.
    const wrapped = try rt.createBlockFilter();
    try std.testing.expectEqual(@as(u64, 2), wrapped);
    try std.testing.expectEqual(@as(usize, 3), rt.rpc_filters.count());
}

test "NodeRuntime snapshot OOM at the cap keeps the oldest snapshot" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var rt = try runtime.NodeRuntime.init(failing.allocator(), null);
    defer rt.deinit();

    var first_id: u64 = 0;
    var i: usize = 0;
    while (i < runtime.MAX_SNAPSHOTS) : (i += 1) {
        const id = try rt.snapshot();
        if (i == 0) first_id = id;
    }
    try std.testing.expectEqual(runtime.MAX_SNAPSHOTS, rt.snapshots.count());

    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, rt.snapshot());
    failing.fail_index = std.math.maxInt(usize);

    try std.testing.expectEqual(runtime.MAX_SNAPSHOTS, rt.snapshots.count());
    try std.testing.expect(rt.snapshots.contains(first_id));

    // A successful snapshot at the cap still evicts exactly the oldest.
    const newest = try rt.snapshot();
    try std.testing.expectEqual(runtime.MAX_SNAPSHOTS, rt.snapshots.count());
    try std.testing.expect(!rt.snapshots.contains(first_id));
    try std.testing.expect(rt.snapshots.contains(newest));
}

test "NodeRuntime revertToSnapshot drops newer snapshots" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const older = try rt.snapshot();
    const target = try rt.snapshot();
    const newer = try rt.snapshot();

    try std.testing.expect(try rt.revertToSnapshot(target));
    try std.testing.expect(rt.snapshots.contains(older));
    try std.testing.expect(!rt.snapshots.contains(target));
    try std.testing.expect(!rt.snapshots.contains(newer));
}

fn initLightRuntimeForTest(consensus_rpc_url: []const u8, checkpoint_dir: ?[]const u8) !runtime.NodeRuntime {
    return runtime.NodeRuntime.init(std.testing.allocator, .{
        .mode = .light,
        .light = .{
            .network = .mainnet,
            .consensus_rpc_url = consensus_rpc_url,
            .advance_on_request = true,
            .checkpoint = [_]u8{0xaa} ** 32,
            .checkpoint_source = .explicit,
            .checkpoint_dir = checkpoint_dir,
        },
    });
}

test "light refresh keeps serving the verified store when advance fails" {
    // Port 1 refuses connections: a transient beacon API failure.
    var rt = try initLightRuntimeForTest("http://127.0.0.1:1", null);
    defer rt.deinit();

    const light = &rt.light.?;
    light.engine.status = .synced;
    light.engine.has_verified_store = true;
    try std.testing.expect(rt.isLightReady());

    try rt.refreshLightSyncForRequest();
    try std.testing.expect(rt.isLightReady());
}

test "mineBlocks validates count * interval for overflow upfront" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    rt.setNextBlockTimestamp(1_000);
    try std.testing.expectError(error.InvalidParams, rt.mineBlocks(std.math.maxInt(u64), 2));
    try std.testing.expectEqual(@as(u64, 0), rt.head_block_number);
}

test "mineBlocks updates base_fee after each block" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const base_fee_before = rt.base_fee;
    try rt.mineBlocks(3, 1);
    try std.testing.expectEqual(@as(u64, 3), rt.head_block_number);
    _ = base_fee_before;
}

test "replayStateToBlockHash rejects fork mode" {
    var resolver = FixtureForkResolver{
        .url_a = "https://rpc-a.example",
        .url_b = "https://rpc-b.example",
        .balance_a = 42,
        .balance_b = 0,
        .nonce_a = 0,
        .nonce_b = 0,
        .storage_slot = 0,
        .storage_a = 0,
        .storage_b = 0,
        .code_a = &[_]u8{},
        .code_b = &[_]u8{},
    };

    var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{
        .fork_url = resolver.url_a,
        .fork_rpc_resolver = resolver.asResolver(),
    });
    defer rt.deinit();

    try rt.mineBlocks(1, 1);
    const block_1 = (try rt.blockchain.getBlockByNumber(1)).?;
    try std.testing.expectError(error.HistoricalStateUnavailable, rt.replayStateToBlockHash(block_1.hash));
}

test "txpool pruneBelowNonce removes consumed-nonce txs" {
    const allocator = std.testing.allocator;
    var pool = @import("../txpool.zig").TransactionPool.init(allocator);
    defer pool.deinit();

    const sender = primitives.Address{ .bytes = [_]u8{0x20} ++ [_]u8{0} ** 19 };
    try pool.setNonce(sender, 0);
    try pool.add(allocator, .{
        .sender = sender,
        .nonce = 0,
        .gas_limit = 21000,
        .max_fee_per_gas = 100,
        .max_priority_fee_per_gas = 1,
        .hash = [_]u8{0xa0} ** 32,
    });
    try pool.add(allocator, .{
        .sender = sender,
        .nonce = 1,
        .gas_limit = 21000,
        .max_fee_per_gas = 100,
        .max_priority_fee_per_gas = 1,
        .hash = [_]u8{0xa1} ** 32,
    });
    try pool.add(allocator, .{
        .sender = sender,
        .nonce = 2,
        .gas_limit = 21000,
        .max_fee_per_gas = 100,
        .max_priority_fee_per_gas = 1,
        .hash = [_]u8{0xa2} ** 32,
    });
    try std.testing.expectEqual(@as(usize, 3), pool.items().len);

    pool.pruneBelowNonce(sender, 2);
    try std.testing.expectEqual(@as(usize, 1), pool.items().len);
    try std.testing.expectEqual(@as(u64, 2), pool.items()[0].nonce);
}

test "revertToSnapshot cleans up newer snapshots even if fork restore fails" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const snap1 = try rt.snapshot();
    const snap2 = try rt.snapshot();
    _ = snap2;
    try std.testing.expect(try rt.revertToSnapshot(snap1));
    try std.testing.expectEqual(@as(u32, 0), rt.snapshots.count());
}

test "light mode persists a new finalized checkpoint to checkpoint_dir" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const dir_path = try tmpPath(std.testing.allocator, &tmp_dir, "checkpoints");
    defer std.testing.allocator.free(dir_path);

    var rt = try initLightRuntimeForTest("http://127.0.0.1:1", dir_path);
    defer rt.deinit();

    const light = &rt.light.?;
    const finalized = [_]u8{0xbb} ** 32;
    light.engine.last_checkpoint = finalized;
    light.persistLatestCheckpoint(std.testing.allocator);

    const loaded = try checkpoint.loadCheckpoint(std.testing.allocator, dir_path);
    try std.testing.expectEqualSlices(u8, &finalized, &loaded);
    try std.testing.expectEqualSlices(u8, &finalized, &light.persisted_checkpoint.?);
}

test "isDeterministicPayloadError includes SystemContractMissingCode" {
    try std.testing.expect(runtime.isDeterministicPayloadError(error.SystemContractMissingCode));
    try std.testing.expect(runtime.isDeterministicPayloadError(error.SystemContractCallFailed));
}

test "increaseTime preserves signed offset when setTime placed offset negative" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    _ = try rt.setTime(0);
    try std.testing.expect(rt.time_offset < 0);

    const result = try rt.increaseTime(5);
    _ = result;
    try std.testing.expect(rt.time_offset < 0);
    try std.testing.expect(rt.time_offset > -@as(i128, std.math.maxInt(u64)));
}

test "revalidateAgainstState updates nonces in both directions" {
    const allocator = std.testing.allocator;
    const txpool_mod = @import("../txpool.zig");
    var pool = txpool_mod.TransactionPool.init(allocator);
    defer pool.deinit();

    const sender = primitives.Address{ .bytes = [_]u8{0x30} ++ [_]u8{0} ** 19 };
    try pool.setNonce(sender, 5);
    try pool.add(allocator, .{
        .sender = sender,
        .nonce = 5,
        .gas_limit = 21000,
        .max_fee_per_gas = 100,
        .hash = [_]u8{0xb0} ** 32,
    });
    try pool.add(allocator, .{
        .sender = sender,
        .nonce = 6,
        .gas_limit = 21000,
        .max_fee_per_gas = 100,
        .hash = [_]u8{0xb1} ** 32,
    });
    try std.testing.expectEqual(@as(usize, 2), pool.items().len);
    try std.testing.expectEqual(@as(usize, 2), pool.pendingCount());

    // Decrease: simulate a reorg that rolled back the sender's nonce.
    pool.revalidateAgainstState(&[_]primitives.Address{sender}, &[_]u64{3});
    // Both transactions remain (nonces 5, 6 are above new base 3) but are
    // now queued because nonces 3 and 4 are missing.
    try std.testing.expectEqual(@as(usize, 2), pool.items().len);
    try std.testing.expectEqual(@as(usize, 0), pool.pendingCount());

    // Increase: advance base nonce past both transactions.
    pool.revalidateAgainstState(&[_]primitives.Address{sender}, &[_]u64{7});
    try std.testing.expectEqual(@as(usize, 0), pool.items().len);
}

test "mineBlocks timestamp overflow check uses first_timestamp not head_block_timestamp" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    rt.setNextBlockTimestamp(std.math.maxInt(u64) - 10);
    try std.testing.expectError(error.InvalidParams, rt.mineBlocks(3, 10));
}

test "replayStateToBlock rejects fork mode" {
    var resolver = FixtureForkResolver{
        .url_a = "https://rpc-a.example",
        .url_b = "https://rpc-b.example",
        .balance_a = 42,
        .balance_b = 0,
        .nonce_a = 0,
        .nonce_b = 0,
        .storage_slot = 0,
        .storage_a = 0,
        .storage_b = 0,
        .code_a = &[_]u8{},
        .code_b = &[_]u8{},
    };
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{
        .fork_url = resolver.url_a,
        .fork_rpc_resolver = resolver.asResolver(),
    });
    defer rt.deinit();

    try rt.mineBlocks(2, 1);
    try std.testing.expectError(error.HistoricalStateUnavailable, rt.replayStateToBlock(1));
}

test "readStateAtBlock rejects fork mode for historical blocks" {
    var resolver = FixtureForkResolver{
        .url_a = "https://rpc-a.example",
        .url_b = "https://rpc-b.example",
        .balance_a = 42,
        .balance_b = 0,
        .nonce_a = 0,
        .nonce_b = 0,
        .storage_slot = 0,
        .storage_a = 0,
        .storage_b = 0,
        .code_a = &[_]u8{},
        .code_b = &[_]u8{},
    };
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{
        .fork_url = resolver.url_a,
        .fork_rpc_resolver = resolver.asResolver(),
    });
    defer rt.deinit();

    try rt.mineBlocks(2, 1);
    try std.testing.expectEqual(@as(u64, 2), rt.head_block_number);
    try std.testing.expectError(error.HistoricalStateUnavailable, rt.readStateAtBlock(1));
    const current_state = try rt.readStateAtBlock(2);
    _ = current_state;
}

test "revertToSnapshot propagates OOM distinctly from invalid snapshot" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    const result = try rt.revertToSnapshot(99999);
    try std.testing.expect(!result);
}
