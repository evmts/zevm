const std = @import("std");
const runtime = @import("runtime.zig");
const genesis = @import("../genesis.zig");
const block_builder = @import("../block_builder.zig");
const hardfork_schedule = @import("../hardfork_schedule.zig");
const mining = @import("../mining.zig");
const primitives = @import("primitives");
const guillotine_mini = @import("guillotine_mini");
const tx_encoding = @import("../transaction_encoding.zig");

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
            .petersburg_block = 0,
            .istanbul_block = 0,
            .muir_glacier_block = 0,
            .berlin_block = 0,
            .london_block = 10,
            .arrow_glacier_block = 30,
            .gray_glacier_block = 30,
            .merge_block = 20,
            .shanghai_timestamp = 100,
            .cancun_timestamp = 200,
            .prague_timestamp = std.math.maxInt(u64),
            .osaka_timestamp = std.math.maxInt(u64),
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
