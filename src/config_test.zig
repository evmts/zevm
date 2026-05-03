const std = @import("std");
const config = @import("config.zig");
const hardfork_schedule = @import("hardfork_schedule.zig");
const mining = @import("mining.zig");
const node_runtime = @import("node/runtime.zig");

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

fn expectTrusted(app_config: config.AppConfig) !config.TrustedConfig {
    return switch (app_config.mode) {
        .trusted => |trusted| trusted,
        .light => error.ExpectedTrustedConfig,
    };
}

fn expectLight(app_config: config.AppConfig) !config.LightConfig {
    return switch (app_config.mode) {
        .trusted => error.ExpectedLightConfig,
        .light => |light| light,
    };
}

test "load defaults to trusted mode with shared defaults" {
    var app_config = try config.load(std.testing.allocator, &[_][]const u8{});
    defer app_config.deinit(std.testing.allocator);

    const trusted = try expectTrusted(app_config);
    try std.testing.expectEqualStrings("127.0.0.1", app_config.rpc.host);
    try std.testing.expectEqual(@as(u16, 8545), app_config.rpc.port);
    try std.testing.expect(app_config.engine_rpc == null);
    try std.testing.expectEqual(@as(u64, 31337), trusted.chain_id);
    try std.testing.expectEqual(@as(u8, 0), trusted.coinbase_index);
    try std.testing.expectEqual(node_runtime.DEFAULT_DEV_HARDFORK_CONFIG.cancun_timestamp, trusted.hardfork_config.cancun_timestamp);
    try std.testing.expectEqual(node_runtime.DEFAULT_DEV_HARDFORK_CONFIG.prague_timestamp, trusted.hardfork_config.prague_timestamp);
    try std.testing.expectEqual(mining.MiningConfigType.auto, std.meta.activeTag(trusted.mining_config));
    try std.testing.expect(trusted.fork == null);
}

test "load merges trusted config file with CLI precedence" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const config_path = try writeTmpFile(std.testing.allocator, &tmp_dir, "trusted.json",
        \\{
        \\  "rpc": { "host": "127.0.0.1", "port": 8000 },
        \\  "engineRpc": { "host": "127.0.0.1", "port": 8551 },
        \\  "mode": {
        \\    "trusted": {
        \\      "chainId": 1,
        \\      "coinbaseIndex": 2,
        \\      "initialBalance": "100",
        \\      "gasPrice": "200",
        \\      "baseFee": "300",
        \\      "blobBaseFee": "4",
        \\      "maxPriorityFeePerGas": "5",
        \\      "blockGasLimit": 9000000,
        \\      "mining": { "type": "interval", "blockTime": 10 },
        \\      "fork": { "url": "https://config-rpc.example", "blockNumber": 7 },
        \\      "genesis": "file-genesis.json",
        \\      "chainRlp": "file-chain.rlp"
        \\    }
        \\  }
        \\}
    );
    defer std.testing.allocator.free(config_path);

    var app_config = try config.load(std.testing.allocator, &[_][]const u8{
        "--config",
        config_path,
        "--host",
        "0.0.0.0",
        "--engine-port",
        "8552",
        "--chain-id",
        "2",
        "--mining",
        "manual",
        "--genesis",
        "cli-genesis.json",
        "--chain-rlp",
        "cli-chain.rlp",
    });
    defer app_config.deinit(std.testing.allocator);

    const trusted = try expectTrusted(app_config);
    try std.testing.expectEqualStrings("0.0.0.0", app_config.rpc.host);
    try std.testing.expectEqual(@as(u16, 8000), app_config.rpc.port);
    try std.testing.expectEqualStrings("127.0.0.1", app_config.engine_rpc.?.host);
    try std.testing.expectEqual(@as(u16, 8552), app_config.engine_rpc.?.port);
    try std.testing.expectEqual(@as(u64, 2), trusted.chain_id);
    try std.testing.expectEqual(@as(u8, 2), trusted.coinbase_index);
    try std.testing.expectEqual(@as(u256, 100), trusted.initial_balance);
    try std.testing.expectEqual(@as(u64, 9_000_000), trusted.block_gas_limit);
    try std.testing.expectEqual(mining.MiningConfigType.manual, std.meta.activeTag(trusted.mining_config));
    try std.testing.expectEqualStrings("https://config-rpc.example", trusted.fork.?.url);
    try std.testing.expectEqual(@as(u64, 7), trusted.fork.?.block_number.?);
    try std.testing.expectEqualStrings("cli-genesis.json", trusted.genesis_alloc_path.?);
    try std.testing.expectEqualStrings("cli-chain.rlp", trusted.chain_rlp_path.?);
    try std.testing.expectEqual(node_runtime.DEFAULT_DEV_HARDFORK_CONFIG.cancun_timestamp, trusted.hardfork_config.cancun_timestamp);

    const node_config = trusted.toNodeConfig();
    try std.testing.expectEqual(@as(u64, 9_000_000), node_config.block_gas_limit);
    try std.testing.expectEqualStrings("cli-genesis.json", node_config.genesis_alloc_path.?);
    try std.testing.expectEqualStrings("cli-chain.rlp", node_config.chain_rlp_path.?);
    var node_config_without_genesis = node_config;
    node_config_without_genesis.genesis_alloc_path = null;
    node_config_without_genesis.chain_rlp_path = null;
    var rt = try node_runtime.NodeRuntime.init(std.testing.allocator, node_config_without_genesis);
    defer rt.deinit();
    try std.testing.expectEqual(@as(u64, 9_000_000), rt.dev_runtime.config.block_gas_limit);
}

test "load rejects engine RPC in light mode" {
    try std.testing.expectError(error.InvalidConfig, config.load(std.testing.allocator, &[_][]const u8{
        "--mode",
        "light",
        "--engine-port",
        "8551",
        "--network",
        "sepolia",
        "--consensus-rpc-url",
        "https://beacon.example",
    }));
}

test "load parses trusted hardfork overrides from config" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const config_path = try writeTmpFile(std.testing.allocator, &tmp_dir, "hardfork.json",
        \\{
        \\  "mode": {
        \\    "trusted": {
        \\      "chainId": 1,
        \\      "hardfork": {
        \\        "londonBlock": 10,
        \\        "mergeBlock": 20,
        \\        "shanghaiTimestamp": 30,
        \\        "cancunTimestamp": 40,
        \\        "pragueTimestamp": 50,
        \\        "osakaTimestamp": 60,
        \\        "secondsPerSlot": 2
        \\      }
        \\    }
        \\  }
        \\}
    );
    defer std.testing.allocator.free(config_path);

    var app_config = try config.load(std.testing.allocator, &[_][]const u8{ "--config", config_path });
    defer app_config.deinit(std.testing.allocator);

    const trusted = try expectTrusted(app_config);
    try std.testing.expectEqual(hardfork_schedule.MAINNET_CHAIN_CONFIG.berlin_block, trusted.hardfork_config.berlin_block);
    try std.testing.expectEqual(@as(u64, 10), trusted.hardfork_config.london_block);
    try std.testing.expectEqual(@as(u64, 20), trusted.hardfork_config.merge_block);
    try std.testing.expectEqual(@as(u64, 30), trusted.hardfork_config.shanghai_timestamp);
    try std.testing.expectEqual(@as(u64, 40), trusted.hardfork_config.cancun_timestamp);
    try std.testing.expectEqual(@as(u64, 50), trusted.hardfork_config.prague_timestamp);
    try std.testing.expectEqual(@as(u64, 60), trusted.hardfork_config.osaka_timestamp);
    try std.testing.expectEqual(@as(u64, 2), trusted.hardfork_config.seconds_per_slot);

    const node_config = trusted.toNodeConfig();
    try std.testing.expectEqual(@as(u64, 40), node_config.hardfork_config.?.cancun_timestamp);
}

test "load requires config to contain exactly one mode branch" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const both_path = try writeTmpFile(std.testing.allocator, &tmp_dir, "both.json",
        \\{
        \\  "mode": {
        \\    "trusted": {},
        \\    "light": { "consensusRpcUrl": "https://beacon.example" }
        \\  }
        \\}
    );
    defer std.testing.allocator.free(both_path);

    try std.testing.expectError(
        error.InvalidConfig,
        config.load(std.testing.allocator, &[_][]const u8{ "--config", both_path }),
    );

    const neither_path = try writeTmpFile(std.testing.allocator, &tmp_dir, "neither.json",
        \\{ "mode": {} }
    );
    defer std.testing.allocator.free(neither_path);

    try std.testing.expectError(
        error.InvalidConfig,
        config.load(std.testing.allocator, &[_][]const u8{ "--config", neither_path }),
    );
}

test "loadWithDiagnostics classifies config file failures" {
    var missing = config.LoadDiagnostics{};
    try std.testing.expectError(
        error.InvalidConfig,
        config.loadWithDiagnostics(std.testing.allocator, &[_][]const u8{ "--config", ".zig-cache/tmp/does-not-exist.json" }, &missing),
    );
    try std.testing.expectEqual(config.LoadFailureClass.missing_file, missing.failure_class);
    try std.testing.expectEqualStrings(".zig-cache/tmp/does-not-exist.json", missing.config_path.?);

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const malformed_path = try writeTmpFile(std.testing.allocator, &tmp_dir, "malformed.json", "{");
    defer std.testing.allocator.free(malformed_path);

    var malformed = config.LoadDiagnostics{};
    try std.testing.expectError(
        error.InvalidConfig,
        config.loadWithDiagnostics(std.testing.allocator, &[_][]const u8{ "--config", malformed_path }, &malformed),
    );
    try std.testing.expectEqual(config.LoadFailureClass.malformed_json, malformed.failure_class);
    try std.testing.expectEqualStrings(malformed_path, malformed.config_path.?);

    const schema_path = try writeTmpFile(std.testing.allocator, &tmp_dir, "schema.json",
        \\{ "unknown": true }
    );
    defer std.testing.allocator.free(schema_path);

    var schema = config.LoadDiagnostics{};
    try std.testing.expectError(
        error.InvalidConfig,
        config.loadWithDiagnostics(std.testing.allocator, &[_][]const u8{ "--config", schema_path }, &schema),
    );
    try std.testing.expectEqual(config.LoadFailureClass.schema, schema.failure_class);
    try std.testing.expectEqualStrings(schema_path, schema.config_path.?);
}

test "load rejects explicit CLI mode mismatch with config branch" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const config_path = try writeTmpFile(std.testing.allocator, &tmp_dir, "trusted.json",
        \\{ "mode": { "trusted": {} } }
    );
    defer std.testing.allocator.free(config_path);

    try std.testing.expectError(
        error.InvalidConfig,
        config.load(std.testing.allocator, &[_][]const u8{ "--config", config_path, "--mode", "light" }),
    );
}

test "load rejects mode-specific flag mixing" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const light_path = try writeTmpFile(std.testing.allocator, &tmp_dir, "light.json",
        \\{ "mode": { "light": { "consensusRpcUrl": "https://beacon.example" } } }
    );
    defer std.testing.allocator.free(light_path);

    try std.testing.expectError(
        error.InvalidConfig,
        config.load(std.testing.allocator, &[_][]const u8{ "--config", light_path, "--chain-id", "1" }),
    );

    try std.testing.expectError(
        error.InvalidConfig,
        config.load(std.testing.allocator, &[_][]const u8{ "--consensus-rpc-url", "https://beacon.example" }),
    );
    try std.testing.expectError(
        error.InvalidConfig,
        config.load(std.testing.allocator, &[_][]const u8{ "--execution-rpc-url", "https://execution.example" }),
    );
}

test "load validates mining and fork option combinations" {
    try std.testing.expectError(
        error.InvalidConfig,
        config.load(std.testing.allocator, &[_][]const u8{ "--mining", "interval" }),
    );
    try std.testing.expectError(
        error.InvalidConfig,
        config.load(std.testing.allocator, &[_][]const u8{ "--mining", "auto", "--block-time", "12" }),
    );
    try std.testing.expectError(
        error.InvalidConfig,
        config.load(std.testing.allocator, &[_][]const u8{ "--fork-block-number", "12" }),
    );
}

test "load parses light config and resolves checkpoint dir default" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const config_path = try writeTmpFile(std.testing.allocator, &tmp_dir, "light.json",
        \\{
        \\  "rpc": { "port": 9000 },
        \\  "mode": {
        \\    "light": {
        \\      "network": "holesky",
        \\      "consensusRpcUrl": "https://beacon.example",
        \\      "executionRpcUrl": "https://execution.example",
        \\      "checkpoint": null,
        \\      "maxCheckpointAgeSeconds": 42,
        \\      "strictCheckpointAge": true
        \\    }
        \\  }
        \\}
    );
    defer std.testing.allocator.free(config_path);

    var app_config = try config.load(std.testing.allocator, &[_][]const u8{ "--config", config_path });
    defer app_config.deinit(std.testing.allocator);

    const light = try expectLight(app_config);
    try std.testing.expectEqual(@as(u16, 9000), app_config.rpc.port);
    try std.testing.expectEqual(config.Network.holesky, light.network);
    try std.testing.expectEqualStrings("https://beacon.example", light.consensus_rpc_url);
    try std.testing.expectEqualStrings("https://execution.example", light.execution_rpc_url.?);
    try std.testing.expectEqual(config.CheckpointSource.default, light.checkpoint_source);
    try std.testing.expect(std.mem.endsWith(u8, light.checkpoint_dir, ".zevm/checkpoints/holesky"));
    try std.testing.expectEqual(@as(u64, 42), light.max_checkpoint_age_seconds);
    try std.testing.expect(light.strict_checkpoint_age);
}

test "load selects CLI checkpoint before config checkpoint" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const config_path = try writeTmpFile(std.testing.allocator, &tmp_dir, "light.json",
        \\{
        \\  "mode": {
        \\    "light": {
        \\      "consensusRpcUrl": "https://beacon.example",
        \\      "checkpoint": "0x1111111111111111111111111111111111111111111111111111111111111111"
        \\    }
        \\  }
        \\}
    );
    defer std.testing.allocator.free(config_path);

    var app_config = try config.load(std.testing.allocator, &[_][]const u8{
        "--config",
        config_path,
        "--checkpoint",
        "0x2222222222222222222222222222222222222222222222222222222222222222",
    });
    defer app_config.deinit(std.testing.allocator);

    const light = try expectLight(app_config);
    try std.testing.expectEqual(config.CheckpointSource.explicit, light.checkpoint_source);
    try std.testing.expectEqual(@as(u8, 0x22), light.checkpoint[0]);
}

test "load selects persisted checkpoint when explicit inputs are absent" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var checkpoint_file = try tmp_dir.dir.createFile("checkpoint", .{ .truncate = true });
    defer checkpoint_file.close();
    try checkpoint_file.writeAll("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n");

    const checkpoint_dir = try tmpPath(std.testing.allocator, &tmp_dir, "");
    defer std.testing.allocator.free(checkpoint_dir);

    var app_config = try config.load(std.testing.allocator, &[_][]const u8{
        "--mode",
        "light",
        "--consensus-rpc-url",
        "https://beacon.example",
        "--checkpoint-dir",
        checkpoint_dir,
    });
    defer app_config.deinit(std.testing.allocator);

    const light = try expectLight(app_config);
    try std.testing.expectEqual(config.CheckpointSource.persisted, light.checkpoint_source);
    try std.testing.expectEqual(@as(u8, 0xaa), light.checkpoint[0]);
}
