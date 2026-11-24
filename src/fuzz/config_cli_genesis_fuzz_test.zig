const std = @import("std");
const primitives = @import("primitives");
const state_manager = @import("state-manager");
const cli = @import("../cli.zig");
const config = @import("../config.zig");
const genesis = @import("../genesis.zig");
const genesis_alloc = @import("../genesis_alloc.zig");
const checkpoint = @import("../checkpoint.zig");
const hardfork_schedule = @import("../hardfork_schedule.zig");
const database = @import("../database/root.zig");
const runtime_mod = @import("../node/runtime.zig");
const block_spec = @import("../rpc/handlers/block_spec.zig");

const known_flags = [_][]const u8{
    "--config",
    "--mode",
    "--host",
    "--port",
    "--engine-host",
    "--engine-port",
    "--chain-id",
    "--coinbase-index",
    "--initial-balance",
    "--gas-price",
    "--base-fee",
    "--blob-base-fee",
    "--max-priority-fee-per-gas",
    "--block-gas-limit",
    "--mining",
    "--block-time",
    "--fork-url",
    "--fork-block-number",
    "--genesis",
    "--chain-rlp",
    "--network",
    "--consensus-rpc-url",
    "--execution-rpc-url",
    "--checkpoint",
    "--checkpoint-dir",
    "--max-checkpoint-age-seconds",
    "--strict-checkpoint-age",
    "--strict-checkpoint-age=true",
    "--unknown-flag",
};

fn fuzzCliParse(_: void, input: []const u8) anyerror!void {
    const allocator = std.testing.allocator;
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(allocator);

    var owned = std.ArrayList([]u8).empty;
    defer {
        for (owned.items) |slice| allocator.free(slice);
        owned.deinit(allocator);
    }

    var cursor: usize = 0;
    while (cursor < input.len and args.items.len < 24) {
        const tag = input[cursor];
        cursor += 1;
        if (tag & 0x80 != 0) {
            const flag = known_flags[tag % known_flags.len];
            // Avoid --config pointing at arbitrary filesystem paths during raw CLI fuzzing.
            if (std.mem.eql(u8, flag, "--config")) continue;
            try args.append(allocator, flag);
        } else {
            const len: usize = @min(@as(usize, tag & 0x3f), input.len - cursor);
            const token = input[cursor .. cursor + len];
            cursor += len;
            try args.append(allocator, token);
        }
    }

    if (cli.parse(args.items)) |opts| {
        // Verify option classification consistency.
        if (opts.mode) |mode| {
            _ = cli.modeFromString(@tagName(mode)) orelse return error.ModeRoundTripFailed;
        }
        if (opts.network) |network| {
            try std.testing.expectEqual(network, cli.networkFromString(cli.networkName(network)).?);
        }
        if (opts.mining) |m| {
            try std.testing.expectEqual(m, cli.miningTypeFromString(@tagName(m)).?);
        }
        if (opts.checkpoint) |hash| {
            var hex: [66]u8 = undefined;
            _ = try std.fmt.bufPrint(&hex, "0x{x}", .{&hash});
            try std.testing.expectEqual(hash, try cli.parsePrefixedHash32(&hex));
            try std.testing.expectEqual(hash, try cli.parseUnprefixedHash32(hex[2..]));
        }
    } else |_| {}

    var diagnostics = config.LoadDiagnostics{};
    if (config.loadWithDiagnostics(allocator, args.items, &diagnostics)) |loaded_val| {
        var loaded = loaded_val;
        defer loaded.deinit(allocator);
        try std.testing.expect(loaded.rpc.host.len > 0);
        switch (loaded.mode) {
            .trusted => |trusted| {
                const node_cfg = trusted.toNodeConfig();
                try std.testing.expectEqual(trusted.chain_id, node_cfg.chain_id);
                try std.testing.expectEqual(trusted.block_gas_limit, node_cfg.block_gas_limit);
            },
            .light => |light| {
                const node_cfg = light.toNodeConfig();
                try std.testing.expectEqual(runtime_mod.Mode.light, node_cfg.mode);
                try std.testing.expectEqualStrings(light.consensus_rpc_url, node_cfg.light.consensus_rpc_url);
            },
        }
    } else |_| {}
}

test "fuzz: CLI flag parser and config resolver on arbitrary token streams" {
    try fuzzCliParse({}, "");
    try std.testing.fuzz({}, fuzzCliParse, .{ .corpus = &.{
        "\x81\x07trusted\x83\x048545\x86\x0531337",
        "\x81\x05light\x94\x07mainnet\x95\x12http://127.0.0.1:1",
        "\x8d\x08interval\x8e\x0212",
        "\x8d\x04auto\x8f\x15http://localhost:8545\x90\x0242",
        "\x9a\x9b",
        "\x81\x05light\x86\x011",
        "\x97\x420x0000000000000000000000000000000000000000000000000000000000000001",
    } });
}

fn fuzzConfigJson(_: void, input: []const u8) anyerror!void {
    const allocator = std.testing.allocator;
    if (input.len > 64 * 1024) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "config.json", .data = input });
    const full_path = try tmp.dir.realpathAlloc(allocator, "config.json");
    defer allocator.free(full_path);

    var diagnostics = config.LoadDiagnostics{};
    const args = [_][]const u8{ "--config", full_path };
    if (config.loadWithDiagnostics(allocator, &args, &diagnostics)) |loaded_val| {
        var loaded = loaded_val;
        defer loaded.deinit(allocator);
        try std.testing.expect(loaded.rpc.host.len > 0);
        try std.testing.expect(diagnostics.config_path != null);
    } else |err| {
        if (err == error.OutOfMemory) return err;
        try std.testing.expect(diagnostics.config_path != null);
        try std.testing.expect(diagnostics.failure_class.name().len > 0);
    }
}

test "fuzz: config.loadWithDiagnostics JSON schema and validation on arbitrary bytes" {
    try fuzzConfigJson({}, "");
    try std.testing.fuzz({}, fuzzConfigJson, .{ .corpus = &.{
        "{",
        "{}",
        "{\"mode\":\"trusted\"}",
        "{\"mode\":\"trusted\",\"rpc\":{\"host\":\"127.0.0.1\",\"port\":8545},\"trusted\":{\"chain_id\":31337,\"block_gas_limit\":30000000}}",
        "{\"mode\":\"trusted\",\"trusted\":{\"chain_id\":1,\"hardfork_config\":{\"osaka_timestamp\":1000,\"blob_schedule\":[{\"timestamp\":2000,\"target\":10,\"max\":15,\"base_fee_update_fraction\":8346193}]}}}",
        "{\"mode\":\"light\",\"light\":{\"network\":\"hoodi\",\"consensus_rpc_url\":\"https://beacon.example\",\"strict_checkpoint_age\":true}}",
        "{\"mode\":\"light\",\"light\":{\"network\":\"mainnet\",\"consensus_rpc_url\":\"https://beacon.example\",\"checkpoint\":\"0x0000000000000000000000000000000000000000000000000000000000000001\"}}",
        "{\"mode\":\"trusted\",\"engine_rpc\":{\"host\":\"127.0.0.1\",\"port\":8551},\"trusted\":{\"fork\":{\"url\":\"https://rpc.example\",\"block_number\":42}}}",
        "{\"unknown\":true}",
    } });
}

fn fuzzGenesisAllocJson(_: void, input: []const u8) anyerror!void {
    const allocator = std.testing.allocator;
    if (input.len > 64 * 1024) return;

    var sm = try state_manager.StateManager.init(allocator, null);
    defer sm.deinit();

    if (genesis_alloc.loadGenesisJson(allocator, &sm, input)) |loaded_val| {
        var loaded = loaded_val;
        defer loaded.deinit(allocator);
        // Header accessors must remain safe and valid.
        _ = loaded.header.extraData();
    } else |err| {
        if (err == error.OutOfMemory) return err;
    }
}

test "fuzz: genesis_alloc.loadGenesisJson on arbitrary JSON payloads" {
    try fuzzGenesisAllocJson({}, "");
    try std.testing.fuzz({}, fuzzGenesisAllocJson, .{ .corpus = &.{
        "{}",
        "{\"alloc\":{}}",
        "{\"gasLimit\":\"0x1c9c380\",\"timestamp\":\"0x0\",\"baseFeePerGas\":\"0x3b9aca00\",\"alloc\":{\"0x0000000000000000000000000000000000000001\":{\"balance\":\"0x100\",\"nonce\":\"0x1\",\"code\":\"0x6000\",\"storage\":{\"0x01\":\"0x02\"}}}}",
        "{\"alloc\":{\"//comment\":\"ignored\",\"0x1111111111111111111111111111111111111111\":{\"wei\":\"1000\"}}}",
        "{\"alloc\":{\"0x1111111111111111111111111111111111111111\":{\"balance\":\"0x1\",\"unknownField\":true}}}",
        "{\"extraData\":\"0x1234\",\"nonce\":\"0x42\",\"mixHash\":\"0x0000000000000000000000000000000000000000000000000000000000000000\",\"alloc\":{}}",
    } });
}

fn fuzzCheckpointBytes(_: void, input: []const u8) anyerror!void {
    const allocator = std.testing.allocator;
    if (input.len > 4096) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "checkpoint", .data = input });
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);

    try std.testing.expect(checkpoint.checkpointExists(dir_path));

    if (checkpoint.loadCheckpoint(allocator, dir_path)) |hash| {
        const trimmed = std.mem.trim(u8, input, " \t\r\n");
        try std.testing.expectEqual(@as(usize, 64), trimmed.len);
        // Save and reload must be an exact fixed point.
        try checkpoint.saveCheckpoint(allocator, dir_path, hash);
        const reloaded = try checkpoint.loadCheckpoint(allocator, dir_path);
        try std.testing.expectEqual(hash, reloaded);
    } else |err| {
        if (err == error.OutOfMemory) return err;
    }
}

test "fuzz: checkpoint.loadCheckpoint and saveCheckpoint round-trip on arbitrary bytes" {
    try fuzzCheckpointBytes({}, "");
    try std.testing.fuzz({}, fuzzCheckpointBytes, .{ .corpus = &.{
        "0000000000000000000000000000000000000000000000000000000000000000",
        "  deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef \n",
        "0x0000000000000000000000000000000000000000000000000000000000000000",
        "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz",
        "a" ** 1025,
    } });
}

test "property: genesis premine state root agrees with Database trie and is order-independent" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x9e4e_5150_7777_0001);
    const random = prng.random();

    for (0..64) |_| {
        const count = random.intRangeAtMost(usize, 1, 8);
        var accounts: [8]genesis.PremineAccount = undefined;

        for (0..count) |i| {
            var addr = primitives.Address.ZERO_ADDRESS;
            random.bytes(&addr.bytes);
            // Guarantee unique addresses across accounts in a trial.
            addr.bytes[0] = @intCast(i + 1);
            accounts[i] = .{
                .address = addr,
                .balance = if (random.boolean()) random.int(u128) else 1 + random.int(u64),
                .nonce = random.int(u16),
            };
        }

        const root_forward = try genesis.computeStateRootFromPremine(allocator, accounts[0..count]);

        // Reversed order must compute the exact same state root.
        var reversed: [8]genesis.PremineAccount = undefined;
        for (0..count) |i| {
            reversed[i] = accounts[count - 1 - i];
        }
        const root_reversed = try genesis.computeStateRootFromPremine(allocator, reversed[0..count]);
        try std.testing.expectEqual(root_forward, root_reversed);

        // Applying premine into a real Database and syncing accounts must match!
        var db = try database.Database.init(allocator, null);
        defer db.deinit(allocator);
        const applied_root = try genesis.applyPremineAllocation(allocator, &db, accounts[0..count]);
        try std.testing.expectEqual(root_forward, applied_root);
        const db_root = db.accounts.stateRoot() orelse primitives.State.EMPTY_TRIE_ROOT;
        try std.testing.expectEqual(root_forward, db_root);
    }
}

fn hardforkRank(fork: primitives.Hardfork) u8 {
    return @intFromEnum(fork);
}

fn fuzzHardforkSchedule(_: void, input: []const u8) anyerror!void {
    var buf = [_]u8{0} ** 40;
    const len = @min(buf.len, input.len);
    @memcpy(buf[0..len], input[0..len]);

    const b1 = std.mem.readInt(u64, buf[0..8], .little);
    const b2 = std.mem.readInt(u64, buf[8..16], .little);
    const t1 = std.mem.readInt(u64, buf[16..24], .little);
    const t2 = std.mem.readInt(u64, buf[24..32], .little);
    const delta_b = std.mem.readInt(u32, buf[32..36], .little);
    const delta_t = std.mem.readInt(u32, buf[36..40], .little);

    const configs = [_]hardfork_schedule.ChainConfig{
        hardfork_schedule.MAINNET_CHAIN_CONFIG,
        runtime_mod.DEFAULT_DEV_HARDFORK_CONFIG,
    };

    for (configs) |cfg| {
        const f_low = hardfork_schedule.resolveHardforkWithConfig(cfg, @min(b1, b2), @min(t1, t2));
        const f_high = hardfork_schedule.resolveHardforkWithConfig(cfg, @max(b1, b2), @max(t1, t2));
        try std.testing.expect(hardforkRank(f_high) >= hardforkRank(f_low));

        const f_step = hardfork_schedule.resolveHardforkWithConfig(cfg, b1 +| delta_b, t1 +| delta_t);
        const f_base = hardfork_schedule.resolveHardforkWithConfig(cfg, b1, t1);
        try std.testing.expect(hardforkRank(f_step) >= hardforkRank(f_base));

        // At timestamp 0 and block 0 on mainnet, Frontier must be active.
        if (cfg.homestead_block > 0 and cfg.shanghai_timestamp > 0) {
            try std.testing.expectEqual(primitives.Hardfork.FRONTIER, hardfork_schedule.resolveHardforkWithConfig(cfg, 0, 0));
        }
    }
}

test "fuzz: hardfork schedule monotonicity across full u64 block and timestamp domain" {
    try std.testing.fuzz({}, fuzzHardforkSchedule, .{ .corpus = &.{
        &([_]u8{0} ** 40),
        &([_]u8{0xff} ** 40),
        "\x00\x00\x00\x00\x00\x00\x00\x00\xff\xff\xff\xff\xff\xff\xff\xff\x00\x00\x00\x00\x00\x00\x00\x00\xff\xff\xff\xff\xff\xff\xff\xff\x01\x00\x00\x00\x0c\x00\x00\x00",
    } });
}

fn fuzzBlockSpec(_: void, input: []const u8) anyerror!void {
    const allocator = std.testing.allocator;
    if (input.len > 4096) return;

    var rt = try runtime_mod.NodeRuntime.init(allocator, null);
    defer rt.deinit();

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, input, .{}) catch return;
    defer parsed.deinit();

    if (block_spec.resolveBlockNumber(&rt, .{ .value = parsed.value })) |num| {
        try std.testing.expect(num <= rt.head_block_number);
    } else |_| {}
}

test "fuzz: block_spec.resolveBlockNumber on arbitrary JSON values" {
    try std.testing.fuzz({}, fuzzBlockSpec, .{ .corpus = &.{
        "\"latest\"",
        "\"pending\"",
        "\"earliest\"",
        "\"safe\"",
        "\"finalized\"",
        "\"0x0\"",
        "\"0x1\"",
        "\"0x00\"",
        "\"0xffffffffffffffff\"",
        "{\"blockNumber\":\"0x0\"}",
        "{\"blockNumber\":\"0x0\",\"blockHash\":\"0x0000000000000000000000000000000000000000000000000000000000000000\"}",
        "{\"blockHash\":\"0x0000000000000000000000000000000000000000000000000000000000000000\",\"requireCanonical\":true}",
        "null",
        "123",
    } });
}
