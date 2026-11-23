//! Prague/Osaka system contracts and the Osaka P256VERIFY precompile, tested
//! through the block builder and through JSON-RPC on a mined chain.

const std = @import("std");
const jsonrpc = @import("jsonrpc");
const primitives = @import("primitives");
const state_manager = @import("state-manager");
const guillotine_mini = @import("guillotine_mini");
const block_builder = @import("block_builder.zig");
const genesis = @import("genesis.zig");
const hardfork_schedule = @import("hardfork_schedule.zig");
const host_adapter = @import("host_adapter.zig");
const system_contracts = @import("system_contracts.zig");
const tx_processor = @import("tx_processor.zig");
const runtime = @import("node/runtime.zig");
const dispatcher = @import("rpc/dispatcher.zig");
const dispatch_wiring = @import("rpc/dispatch_wiring.zig");

const MAINNET_PRAGUE_TIMESTAMP: u64 = 1_746_612_311;
const MAINNET_OSAKA_TIMESTAMP: u64 = 1_764_798_551;
const HISTORY_BUFFER_LENGTH: u64 = 8191;
const P256VERIFY_GAS: u64 = 6900;

const P256VERIFY_ADDRESS = primitives.Address.fromU256(0x0100);

/// Valid EIP-7951 input (first go-ethereum p256Verify.json vector):
/// h || r || s || qx || qy.
const P256VERIFY_VALID_HEX =
    "4cee90eb86eaa050036147a12d49004b6b9c72bd725d39d4785011fe190f0b4d" ++
    "a73bd4903f0ce3b639bbbf6e8e80d16931ff4bcf5993d58468e8fb19086e8cac" ++
    "36dbcd03009df8c59286b162af3bd7fcc0450c9aa81be5d10d312af6c66b1d60" ++
    "4aebd3099c618202fcfe16ae7770b0c49ab5eadf74b754204a3bb6060e44eff3" ++
    "7618b065f9832de4ca6ca971a7a1adc826d0f7c00181a5fb2ddf79ae00b4e10e";

const P256VERIFY_VALID_INPUT = blk: {
    var input: [160]u8 = undefined;
    _ = std.fmt.hexToBytes(&input, P256VERIFY_VALID_HEX) catch unreachable;
    break :blk input;
};

const WORD_ONE_HEX = "0x0000000000000000000000000000000000000000000000000000000000000001";

/// Every fork through Osaka active from genesis.
const OSAKA_DEV_CONFIG = hardfork_schedule.ChainConfig{
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
    .london_block = 0,
    .arrow_glacier_block = 0,
    .gray_glacier_block = 0,
    .merge_block = 0,
    .shanghai_timestamp = 0,
    .cancun_timestamp = 0,
    .prague_timestamp = 0,
    .osaka_timestamp = 0,
    .blob_schedule = hardfork_schedule.BlobSchedule.empty,
};

fn pragueDevConfig() hardfork_schedule.ChainConfig {
    var config = OSAKA_DEV_CONFIG;
    config.osaka_timestamp = std.math.maxInt(u64);
    return config;
}

fn blockContext(number: u64, timestamp: u64) guillotine_mini.BlockContext {
    return .{
        .chain_id = 1,
        .block_number = number,
        .block_timestamp = timestamp,
        .block_difficulty = 0,
        .block_prevrandao = 0,
        .block_coinbase = primitives.Address{ .bytes = [_]u8{0xCB} ++ [_]u8{0} ** 19 },
        .block_gas_limit = 30_000_000,
        .block_base_fee = 0,
        .blob_base_fee = 0,
    };
}

fn blockOptions(config: hardfork_schedule.ChainConfig) block_builder.BuildBlockOptions {
    return .{
        .hardfork_config = config,
        .withdrawals = &.{},
        .parent_beacon_block_root = [_]u8{0xbe} ** 32,
        .parent_hash = [_]u8{0x11} ** 32,
    };
}

fn callTx(caller: primitives.Address, to: primitives.Address, value: u256, data: []const u8) tx_processor.ExecutionTx {
    return .{
        .caller = caller,
        .tx = .{
            .nonce = 0,
            .gas_price = 1,
            .gas_limit = 500_000,
            .to = to,
            .value = value,
            .data = data,
            .v = 0,
            .r = [_]u8{0} ** 32,
            .s = [_]u8{0} ** 32,
        },
    };
}

fn keccak(bytes: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(bytes, &out, .{});
    return out;
}

fn hash32(comptime text: *const [64]u8) [32]u8 {
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, text) catch unreachable;
    return out;
}

// ============================================================================
// Canonical bytecode and genesis installation
// ============================================================================

test "system contracts carry the canonical mainnet runtime bytecode" {
    const expected = [_]struct { address: []const u8, len: usize, code_hash: [32]u8 }{
        // EIP-4788: 0x000F3df6D732807Ef1319fB7B8bB8522d0Beac02
        .{
            .address = "000f3df6d732807ef1319fb7b8bb8522d0beac02",
            .len = 97,
            .code_hash = hash32("f57acd40259872606d76197ef052f3d35588dadf919ee1f0e3cb9b62d3f4b02c"),
        },
        // EIP-2935: 0x0000F90827F1C53a10cb7A02335B175320002935
        .{
            .address = "0000f90827f1c53a10cb7a02335b175320002935",
            .len = 83,
            .code_hash = hash32("6e49e66782037c0555897870e29fa5e552daf4719552131a0abce779daec0a5d"),
        },
        // EIP-7002: 0x00000961Ef480Eb55e80D19ad83579A64c007002
        .{
            .address = "00000961ef480eb55e80d19ad83579a64c007002",
            .len = 504,
            .code_hash = hash32("0345a365d2f4c5975b9f1599abe0a2ee76b7a3a731bc68781bd04c84e4858f50"),
        },
        // EIP-7251: 0x0000BBdDc7CE488642fb579F8B00f3a590007251
        .{
            .address = "0000bbddc7ce488642fb579f8b00f3a590007251",
            .len = 414,
            .code_hash = hash32("78c6cb5202685228bbcbfb992b1c4e116c7ec5ef11e25b8e92716cfc628ddd60"),
        },
    };

    try std.testing.expectEqual(expected.len, system_contracts.ALL.len);
    for (expected, system_contracts.ALL) |want, contract| {
        const address_hex = std.fmt.bytesToHex(contract.address.bytes, .lower);
        try std.testing.expectEqualStrings(want.address, &address_hex);
        try std.testing.expectEqual(want.len, contract.code.len);
        try std.testing.expectEqualSlices(u8, &want.code_hash, &keccak(contract.code));
        // Every system contract starts by comparing CALLER with SYSTEM_ADDRESS:
        // CALLER, PUSH20 0xff..fe, EQ.
        try std.testing.expectEqual(@as(u8, 0x33), contract.code[0]);
        try std.testing.expectEqual(@as(u8, 0x73), contract.code[1]);
        try std.testing.expectEqualSlices(u8, &system_contracts.SYSTEM_ADDRESS.bytes, contract.code[2..22]);
        try std.testing.expectEqual(@as(u8, 0x14), contract.code[22]);
        try std.testing.expect(system_contracts.find(contract.address) != null);
    }
    try std.testing.expect(system_contracts.find(P256VERIFY_ADDRESS) == null);

    // The block builder calls the same addresses the genesis installs.
    try std.testing.expect(block_builder.BEACON_ROOTS_ADDRESS.equals(system_contracts.ALL[0].address));
    try std.testing.expect(block_builder.HISTORY_STORAGE_ADDRESS.equals(system_contracts.ALL[1].address));
    try std.testing.expect(block_builder.WITHDRAWAL_REQUESTS_ADDRESS.equals(system_contracts.ALL[2].address));
    try std.testing.expect(block_builder.CONSOLIDATION_REQUESTS_ADDRESS.equals(system_contracts.ALL[3].address));
}

test "installGenesis installs code with nonce 1, no balance and empty storage" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();
    try system_contracts.installGenesis(&sm);

    for (system_contracts.ALL) |contract| {
        try std.testing.expectEqualSlices(u8, contract.code, try sm.getCode(contract.address));
        try std.testing.expectEqual(@as(u64, 1), try sm.getNonce(contract.address));
        try std.testing.expectEqual(@as(u256, 0), try sm.getBalance(contract.address));
        for (0..4) |slot| {
            try std.testing.expectEqual(@as(u256, 0), try sm.getStorage(contract.address, slot));
        }
    }
}

test "devnet genesis allocation contains the system contracts and matches the state manager root" {
    var allocation: [genesis.DEVNET_PREMINE_LEN]genesis.PremineAccount = undefined;
    genesis.fillDevnetPremine(&allocation);
    try std.testing.expectEqual(genesis.DEV_ACCOUNTS.len + 4, allocation.len);
    for (system_contracts.ALL, allocation[genesis.DEV_ACCOUNTS.len..]) |contract, account| {
        try std.testing.expect(contract.address.equals(account.address));
        try std.testing.expectEqualSlices(u8, contract.code, account.code);
        try std.testing.expectEqual(@as(u64, 1), account.nonce);
        try std.testing.expectEqual(@as(u256, 0), account.balance);
    }

    // The genesis header commits to the same state the node runtime seeds.
    const genesis_block = try genesis.createGenesisBlock(std.testing.allocator, genesis.DEVNET_CHAIN_ID);

    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();
    try genesis.seedDevGenesisState(&sm, &genesis.DEV_ACCOUNTS, genesis.DEV_BALANCE, false);
    const state_root = try block_builder.computeStateRoot(std.testing.allocator, &sm);
    try std.testing.expectEqualSlices(u8, &genesis_block.header.state_root, &state_root);

    // Without the contracts the root differs: they are really in the trie.
    var bare = try state_manager.StateManager.init(std.testing.allocator, null);
    defer bare.deinit();
    try genesis.seedDevGenesisState(&bare, &genesis.DEV_ACCOUNTS, genesis.DEV_BALANCE, true);
    const bare_root = try block_builder.computeStateRoot(std.testing.allocator, &bare);
    try std.testing.expect(!std.mem.eql(u8, &bare_root, &state_root));
    for (system_contracts.ALL) |contract| {
        try std.testing.expectEqual(@as(usize, 0), (try bare.getCode(contract.address)).len);
    }
}

// ============================================================================
// Block builder: Prague and Osaka blocks
// ============================================================================

test "Prague and Osaka blocks are invalid without system contract code" {
    // The validation stays strict: no code means no block (EIP-7002/7251).
    for ([_]hardfork_schedule.ChainConfig{ pragueDevConfig(), OSAKA_DEV_CONFIG }) |config| {
        var sm = try state_manager.StateManager.init(std.testing.allocator, null);
        defer sm.deinit();
        var adapter = host_adapter.HostAdapter{ .state = &sm };
        try std.testing.expectError(error.MissingSystemContractCode, block_builder.buildBlockWithOptions(
            std.testing.allocator,
            &sm,
            adapter.hostInterface(),
            &.{},
            blockContext(1, 1000),
            blockOptions(config),
        ));

        // Only one of the two request contracts is still not enough.
        try sm.setCode(system_contracts.WITHDRAWAL_REQUESTS_ADDRESS, &system_contracts.WITHDRAWAL_REQUESTS_CODE);
        try std.testing.expectError(error.MissingSystemContractCode, block_builder.buildBlockWithOptions(
            std.testing.allocator,
            &sm,
            adapter.hostInterface(),
            &.{},
            blockContext(1, 1000),
            blockOptions(config),
        ));
    }
}

test "empty blocks build at the mainnet Prague and Osaka timestamps from a system contract genesis" {
    const cases = [_]struct { config: hardfork_schedule.ChainConfig, timestamp: u64 }{
        .{ .config = hardfork_schedule.MAINNET_CHAIN_CONFIG, .timestamp = MAINNET_PRAGUE_TIMESTAMP },
        .{ .config = hardfork_schedule.MAINNET_CHAIN_CONFIG, .timestamp = MAINNET_OSAKA_TIMESTAMP - 1 },
        .{ .config = hardfork_schedule.MAINNET_CHAIN_CONFIG, .timestamp = MAINNET_OSAKA_TIMESTAMP },
        .{ .config = hardfork_schedule.MAINNET_CHAIN_CONFIG, .timestamp = MAINNET_OSAKA_TIMESTAMP + 12 },
        .{ .config = pragueDevConfig(), .timestamp = 1000 },
        .{ .config = OSAKA_DEV_CONFIG, .timestamp = 1000 },
    };
    const empty_requests_hash = block_builder.computeRequestsHash(.{});

    for (cases) |case| {
        var sm = try state_manager.StateManager.init(std.testing.allocator, null);
        defer sm.deinit();
        try genesis.seedDevGenesisState(&sm, &genesis.DEV_ACCOUNTS, genesis.DEV_BALANCE, false);
        var adapter = host_adapter.HostAdapter{ .state = &sm };

        const block_number: u64 = 7;
        var result = try block_builder.buildBlockWithOptions(
            std.testing.allocator,
            &sm,
            adapter.hostInterface(),
            &.{},
            blockContext(block_number, case.timestamp),
            blockOptions(case.config),
        );
        defer result.deinit(std.testing.allocator);

        try std.testing.expectEqual(@as(u64, 0), result.total_gas_used);
        // Both request queues ran and were empty.
        try std.testing.expectEqualSlices(u8, &empty_requests_hash, &result.requests_hash.?);

        // EIP-4788 and EIP-2935 state landed in the installed contracts.
        const slot = case.timestamp % HISTORY_BUFFER_LENGTH;
        try std.testing.expectEqual(@as(u256, case.timestamp), try sm.getStorage(system_contracts.BEACON_ROOTS_ADDRESS, slot));
        try std.testing.expectEqual(
            std.mem.readInt(u256, &([_]u8{0xbe} ** 32), .big),
            try sm.getStorage(system_contracts.BEACON_ROOTS_ADDRESS, slot + HISTORY_BUFFER_LENGTH),
        );
        try std.testing.expectEqual(
            std.mem.readInt(u256, &([_]u8{0x11} ** 32), .big),
            try sm.getStorage(system_contracts.HISTORY_STORAGE_ADDRESS, (block_number - 1) % HISTORY_BUFFER_LENGTH),
        );
        // The system calls leave the contracts' code, nonce and balance alone.
        for (system_contracts.ALL) |contract| {
            try std.testing.expectEqualSlices(u8, contract.code, try sm.getCode(contract.address));
            try std.testing.expectEqual(@as(u64, 1), try sm.getNonce(contract.address));
            try std.testing.expectEqual(@as(u256, 0), try sm.getBalance(contract.address));
        }
    }
}

test "canonical EIP-4788 and EIP-2935 bytecode writes the same storage as the builder's direct writes" {
    const timestamp: u64 = MAINNET_OSAKA_TIMESTAMP;
    const block_number: u64 = 23_935_694;
    const root = [_]u8{0x42} ** 32;
    const parent_hash = [_]u8{0x34} ** 32;

    // State A: the builder's direct storage writes.
    var direct = try state_manager.StateManager.init(std.testing.allocator, null);
    defer direct.deinit();
    try system_contracts.installGenesis(&direct);
    try block_builder.applyBeaconRootsSystemCall(&direct, timestamp, root);
    try block_builder.applyHistoricalBlockHashSystemCall(&direct, block_number, parent_hash);

    // State B: the installed bytecode, executed as SYSTEM_ADDRESS.
    var executed = try state_manager.StateManager.init(std.testing.allocator, null);
    defer executed.deinit();
    try system_contracts.installGenesis(&executed);
    var adapter = host_adapter.HostAdapter{ .state = &executed };
    for ([_]struct { to: primitives.Address, input: [32]u8 }{
        .{ .to = system_contracts.BEACON_ROOTS_ADDRESS, .input = root },
        .{ .to = system_contracts.HISTORY_STORAGE_ADDRESS, .input = parent_hash },
    }) |call| {
        const output = try block_builder.runSystemContractCall(
            std.testing.allocator,
            &executed,
            adapter.hostInterface(),
            blockContext(block_number, timestamp),
            .OSAKA,
            call.to,
            &call.input,
        );
        defer std.testing.allocator.free(output);
        try std.testing.expectEqual(@as(usize, 0), output.len);
    }

    const beacon_slot = timestamp % HISTORY_BUFFER_LENGTH;
    const history_slot = (block_number - 1) % HISTORY_BUFFER_LENGTH;
    const slots = [_]struct { address: primitives.Address, slot: u256, value: u256 }{
        .{ .address = system_contracts.BEACON_ROOTS_ADDRESS, .slot = beacon_slot, .value = timestamp },
        .{
            .address = system_contracts.BEACON_ROOTS_ADDRESS,
            .slot = beacon_slot + HISTORY_BUFFER_LENGTH,
            .value = std.mem.readInt(u256, &root, .big),
        },
        .{
            .address = system_contracts.HISTORY_STORAGE_ADDRESS,
            .slot = history_slot,
            .value = std.mem.readInt(u256, &parent_hash, .big),
        },
    };
    for (slots) |entry| {
        try std.testing.expectEqual(entry.value, try executed.getStorage(entry.address, entry.slot));
        try std.testing.expectEqual(entry.value, try direct.getStorage(entry.address, entry.slot));
    }
    // Identical state overall, not just in the probed slots.
    const direct_root = try block_builder.computeStateRoot(std.testing.allocator, &direct);
    const executed_root = try block_builder.computeStateRoot(std.testing.allocator, &executed);
    try std.testing.expectEqualSlices(u8, &direct_root, &executed_root);
}

test "Osaka block collects EIP-7002 and EIP-7251 requests from the canonical contracts" {
    var sm = try state_manager.StateManager.init(std.testing.allocator, null);
    defer sm.deinit();
    try system_contracts.installGenesis(&sm);
    var adapter = host_adapter.HostAdapter{ .state = &sm };

    const withdrawer = primitives.Address.fromU256(0x7002_0001);
    const consolidator = primitives.Address.fromU256(0x7251_0001);
    try sm.setBalance(withdrawer, 1_000_000_000_000);
    try sm.setBalance(consolidator, 1_000_000_000_000);

    // EIP-7002 calldata: validator_pubkey[48] || amount[8, big-endian].
    const validator_pubkey = [_]u8{0xaa} ** 48;
    const amount: u64 = 0x0102030405060708;
    var withdrawal_calldata: [56]u8 = undefined;
    @memcpy(withdrawal_calldata[0..48], &validator_pubkey);
    std.mem.writeInt(u64, withdrawal_calldata[48..56], amount, .big);

    // EIP-7251 calldata: source_pubkey[48] || target_pubkey[48].
    const source_pubkey = [_]u8{0xbb} ** 48;
    const target_pubkey = [_]u8{0xcc} ** 48;
    const consolidation_calldata = source_pubkey ++ target_pubkey;

    const transactions = [_]tx_processor.ExecutionTx{
        // Each contract charges a fee of 1 wei while its queue is empty.
        callTx(withdrawer, system_contracts.WITHDRAWAL_REQUESTS_ADDRESS, 1, &withdrawal_calldata),
        callTx(consolidator, system_contracts.CONSOLIDATION_REQUESTS_ADDRESS, 1, &consolidation_calldata),
    };

    var result = try block_builder.buildBlockWithOptions(
        std.testing.allocator,
        &sm,
        adapter.hostInterface(),
        &transactions,
        blockContext(1, MAINNET_OSAKA_TIMESTAMP),
        blockOptions(hardfork_schedule.MAINNET_CHAIN_CONFIG),
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), result.receipts.len);
    for (result.receipts) |receipt| {
        try std.testing.expect(receipt.status.?.success);
    }

    // EIP-7002 request: source_address[20] || pubkey[48] || amount[8, little-endian].
    var withdrawal_request: [76]u8 = undefined;
    @memcpy(withdrawal_request[0..20], &withdrawer.bytes);
    @memcpy(withdrawal_request[20..68], &validator_pubkey);
    std.mem.writeInt(u64, withdrawal_request[68..76], amount, .little);
    // EIP-7251 request: source_address[20] || source_pubkey[48] || target_pubkey[48].
    const consolidation_request = consolidator.bytes ++ source_pubkey ++ target_pubkey;

    const expected = block_builder.computeRequestsHash(.{
        .withdrawals = &withdrawal_request,
        .consolidations = &consolidation_request,
    });
    try std.testing.expectEqualSlices(u8, &expected, &result.requests_hash.?);
    try std.testing.expect(!std.mem.eql(u8, &expected, &block_builder.computeRequestsHash(.{})));

    // The fees stay in the contracts; the system call dequeued both requests.
    try std.testing.expectEqual(@as(u256, 1), try sm.getBalance(system_contracts.WITHDRAWAL_REQUESTS_ADDRESS));
    try std.testing.expectEqual(@as(u256, 1), try sm.getBalance(system_contracts.CONSOLIDATION_REQUESTS_ADDRESS));

    var next = try block_builder.buildBlockWithOptions(
        std.testing.allocator,
        &sm,
        adapter.hostInterface(),
        &.{},
        blockContext(2, MAINNET_OSAKA_TIMESTAMP + 12),
        blockOptions(hardfork_schedule.MAINNET_CHAIN_CONFIG),
    );
    defer next.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &block_builder.computeRequestsHash(.{}), &next.requests_hash.?);
}

test "P256VERIFY transaction costs exactly 6900 execution gas at Osaka and nothing before" {
    var zero_bytes: u64 = 0;
    for (P256VERIFY_VALID_INPUT) |byte| zero_bytes += @intFromBool(byte == 0);
    const nonzero_bytes = P256VERIFY_VALID_INPUT.len - zero_bytes;
    const intrinsic: u64 = 21_000 + 4 * zero_bytes + 16 * nonzero_bytes;
    // EIP-7623 floor: 10 gas per token, a zero byte is 1 token, others 4.
    const floor: u64 = 21_000 + 10 * (zero_bytes + 4 * nonzero_bytes);

    const sender = primitives.Address.fromU256(0x7951_0001);
    const cases = [_]struct { timestamp: u64, gas_used: u64 }{
        // Osaka: the precompile runs.
        .{ .timestamp = MAINNET_OSAKA_TIMESTAMP, .gas_used = intrinsic + P256VERIFY_GAS },
        // One second earlier (Prague): 0x0100 is an empty account, nothing runs.
        .{ .timestamp = MAINNET_OSAKA_TIMESTAMP - 1, .gas_used = @max(intrinsic, floor) },
    };
    try std.testing.expect(cases[0].gas_used > floor);

    for (cases) |case| {
        var sm = try state_manager.StateManager.init(std.testing.allocator, null);
        defer sm.deinit();
        try system_contracts.installGenesis(&sm);
        try sm.setBalance(sender, 1_000_000_000_000);
        var adapter = host_adapter.HostAdapter{ .state = &sm };

        const transactions = [_]tx_processor.ExecutionTx{
            callTx(sender, P256VERIFY_ADDRESS, 0, &P256VERIFY_VALID_INPUT),
        };
        var result = try block_builder.buildBlockWithOptions(
            std.testing.allocator,
            &sm,
            adapter.hostInterface(),
            &transactions,
            blockContext(1, case.timestamp),
            blockOptions(hardfork_schedule.MAINNET_CHAIN_CONFIG),
        );
        defer result.deinit(std.testing.allocator);

        try std.testing.expectEqual(@as(usize, 1), result.receipts.len);
        try std.testing.expect(result.receipts[0].status.?.success);
        try std.testing.expectEqual(case.gas_used, result.total_gas_used);
    }
}

// ============================================================================
// JSON-RPC: mining on mainnet- and devnet-configured chains
// ============================================================================

const Rpc = struct {
    rt: *runtime.NodeRuntime,

    /// Dispatches `method` with `params_json` and returns the response.
    /// Fails the test when the node answers with a JSON-RPC error.
    fn call(self: Rpc, method: []const u8, params_json: []const u8) !jsonrpc.envelope.ResponseEnvelope {
        const allocator = std.testing.allocator;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, params_json, .{});
        defer parsed.deinit();

        var handlers = dispatcher.HandlerRegistry{};
        dispatch_wiring.install(&handlers, self.rt);

        var request = jsonrpc.envelope.RequestEnvelope{
            .jsonrpc = try allocator.dupe(u8, "2.0"),
            .id = .{ .integer = 1 },
            .method = try allocator.dupe(u8, method),
            .params = parsed.value,
        };
        defer request.deinit(allocator);

        var response = try dispatcher.dispatch(allocator, request, &handlers);
        errdefer response.deinit(allocator);
        if (response.error_value) |err| {
            std.debug.print("{s} {s} failed: {d} {s}\n", .{ method, params_json, err.code, err.message });
            return error.UnexpectedRpcError;
        }
        return response;
    }

    fn expectString(self: Rpc, method: []const u8, params_json: []const u8, expected: []const u8) !void {
        var response = try self.call(method, params_json);
        defer response.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(expected, response.result.?.string);
    }

    fn mineAt(self: Rpc, timestamp: u64) !void {
        self.rt.setNextBlockTimestamp(timestamp);
        var response = try self.call("evm_mine", "[]");
        defer response.deinit(std.testing.allocator);
    }

    /// Returns one string field of the latest block, owned by the caller.
    fn latestBlockField(self: Rpc, name: []const u8) ![]u8 {
        var response = try self.call("eth_getBlockByNumber", "[\"latest\", false]");
        defer response.deinit(std.testing.allocator);
        const value = response.result.?.object.get(name) orelse return error.MissingBlockField;
        return std.testing.allocator.dupe(u8, value.string);
    }

    /// Pins the pending block context that `eth_call` executes in.
    fn expectCallAt(self: Rpc, timestamp: u64, to: []const u8, data: []const u8, expected: []const u8) !void {
        self.rt.setNextBlockTimestamp(timestamp);
        var buffer: [1024]u8 = undefined;
        const params = try std.fmt.bufPrint(&buffer, "[{{\"to\":\"{s}\",\"data\":\"{s}\"}},\"latest\"]", .{ to, data });
        try self.expectString("eth_call", params, expected);
    }
};

const P256VERIFY_RPC_ADDRESS = "0x0000000000000000000000000000000000000100";
const P256VERIFY_CALLDATA = "0x" ++ P256VERIFY_VALID_HEX;

fn expectSystemContractCode(rpc: Rpc) !void {
    for (system_contracts.ALL) |contract| {
        const address_hex = std.fmt.bytesToHex(contract.address.bytes, .lower);
        var params_buffer: [128]u8 = undefined;
        const params = try std.fmt.bufPrint(&params_buffer, "[\"0x{s}\",\"latest\"]", .{&address_hex});
        const code_hex = try std.fmt.allocPrint(std.testing.allocator, "0x{x}", .{contract.code});
        defer std.testing.allocator.free(code_hex);
        try rpc.expectString("eth_getCode", params, code_hex);
    }
}

test "mainnet-configured chain mines Prague and Osaka blocks and runs P256VERIFY from Osaka" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{ .chain_id = 1 });
    defer rt.deinit();
    try rt.setMiningConfig(.manual);
    const rpc = Rpc{ .rt = &rt };

    try std.testing.expectEqual(guillotine_mini.Hardfork.FRONTIER, rt.hardforkAt(0, 0));
    try expectSystemContractCode(rpc);

    // Block 1 at the Prague activation timestamp, block 2 one second before
    // Osaka: both ran the Prague system calls.
    try rpc.mineAt(MAINNET_PRAGUE_TIMESTAMP);
    try rpc.mineAt(MAINNET_OSAKA_TIMESTAMP - 1);
    try std.testing.expectEqual(@as(u64, 2), rt.head_block_number);
    try std.testing.expectEqual(guillotine_mini.Hardfork.PRAGUE, rt.hardforkAt(2, rt.head_block_timestamp));

    // Still Prague: a call to 0x0100 reaches an empty account.
    try rpc.expectCallAt(MAINNET_OSAKA_TIMESTAMP - 1, P256VERIFY_RPC_ADDRESS, P256VERIFY_CALLDATA, "0x");
    // The pending block at the Osaka timestamp executes the precompile.
    try rpc.expectCallAt(MAINNET_OSAKA_TIMESTAMP, P256VERIFY_RPC_ADDRESS, P256VERIFY_CALLDATA, WORD_ONE_HEX);

    const block2_hash = try rpc.latestBlockField("hash");
    defer std.testing.allocator.free(block2_hash);

    // Block 3 at the Osaka activation timestamp, block 4 one slot later.
    try rpc.mineAt(MAINNET_OSAKA_TIMESTAMP);
    try std.testing.expectEqual(guillotine_mini.Hardfork.OSAKA, rt.hardforkAt(3, rt.head_block_timestamp));
    try rpc.mineAt(MAINNET_OSAKA_TIMESTAMP + 12);
    try std.testing.expectEqual(@as(u64, 4), rt.head_block_number);
    try std.testing.expectEqual(MAINNET_OSAKA_TIMESTAMP + 12, rt.head_block_timestamp);

    // An empty Osaka block commits to the empty requests hash.
    const requests_hash = try rpc.latestBlockField("requestsHash");
    defer std.testing.allocator.free(requests_hash);
    const empty_requests_hash = try std.fmt.allocPrint(std.testing.allocator, "0x{x}", .{block_builder.computeRequestsHash(.{})});
    defer std.testing.allocator.free(empty_requests_hash);
    try std.testing.expectEqualStrings(empty_requests_hash, requests_hash);

    // P256VERIFY on the mined Osaka chain: valid, invalid, malformed.
    const next = MAINNET_OSAKA_TIMESTAMP + 24;
    try rpc.expectCallAt(next, P256VERIFY_RPC_ADDRESS, P256VERIFY_CALLDATA, WORD_ONE_HEX);
    const bad_signature = "0x5" ++ P256VERIFY_VALID_HEX[1..];
    try rpc.expectCallAt(next, P256VERIFY_RPC_ADDRESS, bad_signature, "0x");
    try rpc.expectCallAt(next, P256VERIFY_RPC_ADDRESS, "0x", "0x");

    // EIP-2935 get(): the installed contract serves block 2's hash, written by
    // block 3's system call.
    try rpc.expectCallAt(
        next,
        "0x0000f90827f1c53a10cb7a02335b175320002935",
        "0x0000000000000000000000000000000000000000000000000000000000000002",
        block2_hash,
    );

    // EIP-4788 get(): the installed contract knows block 4's timestamp and
    // returns the (zero) beacon root a dev chain mines with.
    var timestamp_calldata: [66]u8 = undefined;
    _ = try std.fmt.bufPrint(&timestamp_calldata, "0x{x:0>64}", .{MAINNET_OSAKA_TIMESTAMP + 12});
    try rpc.expectCallAt(
        next,
        "0x000f3df6d732807ef1319fb7b8bb8522d0beac02",
        &timestamp_calldata,
        "0x0000000000000000000000000000000000000000000000000000000000000000",
    );

    // The contracts are unchanged after four blocks of system calls.
    try expectSystemContractCode(rpc);
}

test "devnet configured through Osaka mines blocks and runs P256VERIFY" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{ .hardfork_config = OSAKA_DEV_CONFIG });
    defer rt.deinit();
    try rt.setMiningConfig(.manual);
    const rpc = Rpc{ .rt = &rt };

    try std.testing.expectEqual(runtime.DEFAULT_CHAIN_ID, rt.chain_id);
    try std.testing.expectEqual(guillotine_mini.Hardfork.OSAKA, rt.hardforkAt(0, 0));
    try expectSystemContractCode(rpc);

    for ([_]u64{ 12, 24, 36 }) |timestamp| {
        try rpc.mineAt(timestamp);
    }
    try std.testing.expectEqual(@as(u64, 3), rt.head_block_number);
    try rpc.expectCallAt(48, P256VERIFY_RPC_ADDRESS, P256VERIFY_CALLDATA, WORD_ONE_HEX);

    // A transaction to the precompile is mined and charged exactly 6900
    // execution gas on top of its intrinsic cost.
    var zero_bytes: u64 = 0;
    for (P256VERIFY_VALID_INPUT) |byte| zero_bytes += @intFromBool(byte == 0);
    const expected_gas: u64 = 21_000 + 4 * zero_bytes + 16 * (P256VERIFY_VALID_INPUT.len - zero_bytes) + P256VERIFY_GAS;

    var send = try rpc.call(
        "eth_sendTransaction",
        "[{\"from\":\"0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266\",\"to\":\"" ++ P256VERIFY_RPC_ADDRESS ++
            "\",\"gas\":\"0x186a0\",\"data\":\"" ++ P256VERIFY_CALLDATA ++ "\"}]",
    );
    defer send.deinit(std.testing.allocator);
    try rpc.mineAt(48);

    var params_buffer: [128]u8 = undefined;
    const params = try std.fmt.bufPrint(&params_buffer, "[\"{s}\"]", .{send.result.?.string});
    var receipt = try rpc.call("eth_getTransactionReceipt", params);
    defer receipt.deinit(std.testing.allocator);
    const fields = receipt.result.?.object;
    try std.testing.expectEqualStrings("0x1", fields.get("status").?.string);
    var gas_buffer: [32]u8 = undefined;
    const expected_gas_hex = try std.fmt.bufPrint(&gas_buffer, "0x{x}", .{expected_gas});
    try std.testing.expectEqualStrings(expected_gas_hex, fields.get("gasUsed").?.string);
}

test "default devnet keeps mining Cancun blocks with the system contracts in genesis" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();
    try rt.setMiningConfig(.manual);
    const rpc = Rpc{ .rt = &rt };

    try expectSystemContractCode(rpc);
    try rpc.mineAt(12);
    try rpc.mineAt(24);
    try std.testing.expectEqual(guillotine_mini.Hardfork.CANCUN, rt.hardforkAt(2, 24));
    // Prague and Osaka are not scheduled: 0x0100 is not a precompile.
    try rpc.expectCallAt(36, P256VERIFY_RPC_ADDRESS, P256VERIFY_CALLDATA, "0x");
}

test "installScheduled respects hardfork schedule and preserves pre-existing code" {
    const allocator = std.testing.allocator;

    // Cancun-only schedule installs EIP-4788 only.
    {
        var sm = try state_manager.StateManager.init(allocator, null);
        defer sm.deinit();
        const cancun_only = hardfork_schedule.ChainConfig{
            .cancun_timestamp = 0,
            .prague_timestamp = std.math.maxInt(u64),
            .osaka_timestamp = std.math.maxInt(u64),
        };
        try system_contracts.installScheduled(&sm, cancun_only);
        try std.testing.expectEqualSlices(u8, &system_contracts.BEACON_ROOTS_CODE, try sm.getCode(system_contracts.BEACON_ROOTS_ADDRESS));
        try std.testing.expectEqual(@as(usize, 0), (try sm.getCode(system_contracts.HISTORY_STORAGE_ADDRESS)).len);
        try std.testing.expectEqual(@as(usize, 0), (try sm.getCode(system_contracts.WITHDRAWAL_REQUESTS_ADDRESS)).len);
        try std.testing.expectEqual(@as(usize, 0), (try sm.getCode(system_contracts.CONSOLIDATION_REQUESTS_ADDRESS)).len);
    }

    // Mainnet schedule installs all 4 without clobbering pre-existing code.
    {
        var sm = try state_manager.StateManager.init(allocator, null);
        defer sm.deinit();
        const custom = [_]u8{0xfe};
        try sm.setCode(system_contracts.WITHDRAWAL_REQUESTS_ADDRESS, &custom);
        try system_contracts.installScheduled(&sm, hardfork_schedule.MAINNET_CHAIN_CONFIG);
        try std.testing.expectEqualSlices(u8, &custom, try sm.getCode(system_contracts.WITHDRAWAL_REQUESTS_ADDRESS));
        try std.testing.expectEqualSlices(u8, &system_contracts.CONSOLIDATION_REQUESTS_CODE, try sm.getCode(system_contracts.CONSOLIDATION_REQUESTS_ADDRESS));
        try std.testing.expectEqualSlices(u8, &system_contracts.BEACON_ROOTS_CODE, try sm.getCode(system_contracts.BEACON_ROOTS_ADDRESS));
        try std.testing.expectEqualSlices(u8, &system_contracts.HISTORY_STORAGE_CODE, try sm.getCode(system_contracts.HISTORY_STORAGE_ADDRESS));
    }
}

test "Prague mining rejects an explicit genesis file missing system contract code without advancing head" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile("empty-genesis.json", .{});
    defer file.close();
    try file.writeAll("{\"alloc\":{}}");
    const path = try tmp.dir.realpathAlloc(allocator, "empty-genesis.json");
    defer allocator.free(path);

    var rt = try runtime.NodeRuntime.init(allocator, .{
        .chain_id = 1,
        .genesis_alloc_path = path,
    });
    defer rt.deinit();
    rt.setNextBlockTimestamp(MAINNET_PRAGUE_TIMESTAMP);
    try std.testing.expectError(error.MissingSystemContractCode, rt.mineBlocks(1, 0));
    try std.testing.expectEqual(@as(u64, 0), rt.head_block_number);
}

test "mined Prague and Osaka block headers populate requests_hash directly" {
    const allocator = std.testing.allocator;
    var rt = try runtime.NodeRuntime.init(allocator, .{ .chain_id = 1 });
    defer rt.deinit();
    try rt.setMiningConfig(.manual);

    rt.setNextBlockTimestamp(MAINNET_OSAKA_TIMESTAMP);
    try rt.mineBlocks(1, 0);
    const osaka_block = (try rt.blockchain.getBlockByNumber(1)).?;
    try std.testing.expect(osaka_block.header.requests_hash != null);
    try std.testing.expectEqualSlices(u8, &block_builder.computeRequestsHash(.{}), &osaka_block.header.requests_hash.?);
}
