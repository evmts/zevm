const std = @import("std");
const primitives = @import("primitives");
const consensus_sync = @import("consensus_sync.zig");

fn parseHex32(comptime value: []const u8) [32]u8 {
    var bytes: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, value) catch unreachable;
    return bytes;
}

fn testConfig(genesis_time: u64, max_checkpoint_age: u64) consensus_sync.NetworkConfig {
    return .{
        .chain_id = 1,
        .genesis_time = genesis_time,
        .genesis_validators_root = [_]u8{0} ** 32,
        .fork_config = primitives.ForkConfig.ForkConfig.mainnet(),
        .default_checkpoint = [_]u8{0} ** 32,
        .consensus_rpc = "http://localhost:5052",
        .max_checkpoint_age = max_checkpoint_age,
        .strict_checkpoint_age = false,
    };
}

test "NetworkConfig.mainnet has expected genesis values" {
    const config = consensus_sync.NetworkConfig.mainnet("https://example.com");

    try std.testing.expectEqual(@as(u64, 1), config.chain_id);
    try std.testing.expectEqual(@as(u64, 1606824023), config.genesis_time);
    try std.testing.expectEqualSlices(
        u8,
        parseHex32("4b363db94e286120d76eb905340fdd4e54bfe9f06bf33ff6cf5ad27f511bfe95")[0..],
        config.genesis_validators_root[0..],
    );
    try std.testing.expectEqual(@as(u64, 1_209_600), config.max_checkpoint_age);
    try std.testing.expect(!config.strict_checkpoint_age);
}

test "expectedCurrentSlot matches primitives consensus calculation" {
    var engine = consensus_sync.ConsensusSyncEngine.init(testConfig(0, 1_209_600));

    const expected = primitives.consensus.expectedCurrentSlot(engine.config.genesis_time);
    try std.testing.expectEqual(expected, engine.expectedCurrentSlot());
}

test "isValidCheckpoint returns true for a recent slot" {
    var engine = consensus_sync.ConsensusSyncEngine.init(testConfig(0, 1_000));
    const current_slot = engine.expectedCurrentSlot();
    const recent_slot = if (current_slot > 0) current_slot - 1 else 0;

    try std.testing.expect(engine.isValidCheckpoint(recent_slot));
}

test "isValidCheckpoint returns false for an old slot" {
    var engine = consensus_sync.ConsensusSyncEngine.init(testConfig(0, 100));
    const current_slot = engine.expectedCurrentSlot();
    const old_slot = if (current_slot > 20) current_slot - 20 else 0;

    try std.testing.expect(!engine.isValidCheckpoint(old_slot));
}

test "isValidCheckpoint treats age equal to max age as valid" {
    var engine = consensus_sync.ConsensusSyncEngine.init(testConfig(0, 120));
    const current_slot = engine.expectedCurrentSlot();
    const boundary_slot = current_slot - 10;

    const info = engine.checkpointAgeInfo(boundary_slot);
    try std.testing.expectEqual(@as(u64, 120), info.age_seconds);
    try std.testing.expectEqual(@as(u64, 120), info.max_checkpoint_age_seconds);
    try std.testing.expect(!info.stale);
    try std.testing.expect(engine.isValidCheckpoint(boundary_slot));
}

test "checkpointAgeInfo records stale startup warning fields" {
    var engine = consensus_sync.ConsensusSyncEngine.init(testConfig(1_000, 119));
    const current_slot = engine.expectedCurrentSlot();
    const checkpoint_slot = current_slot - 10;

    const info = engine.checkpointAgeInfo(checkpoint_slot);
    try std.testing.expectEqual(engine.slotTimestamp(checkpoint_slot), info.checkpoint_time_seconds);
    try std.testing.expectEqual(engine.slotTimestamp(current_slot), info.startup_time_seconds);
    try std.testing.expectEqual(@as(u64, 120), info.age_seconds);
    try std.testing.expectEqual(@as(u64, 119), info.max_checkpoint_age_seconds);
    try std.testing.expect(info.stale);
}

test "checkpoint age derives from beacon genesis and header data" {
    var config = testConfig(0, 120);
    config.genesis_validators_root = [_]u8{0x44} ** 32;
    var engine = consensus_sync.ConsensusSyncEngine.init(config);

    const checkpoint = [_]u8{0xaa} ** 32;
    const info = try engine.checkpointAgeInfoFromBeaconData(
        .{
            .genesis_time = 1_000,
            .genesis_validators_root = [_]u8{0x44} ** 32,
        },
        .{
            .root = checkpoint,
            .slot = 5,
        },
        checkpoint,
        1_180,
    );

    try std.testing.expectEqual(@as(u64, 1_060), info.checkpoint_time_seconds);
    try std.testing.expectEqual(@as(u64, 1_180), info.startup_time_seconds);
    try std.testing.expectEqual(@as(u64, 120), info.age_seconds);
    try std.testing.expect(!info.stale);
}

test "checkpoint age rejects mismatched beacon network" {
    var config = testConfig(0, 120);
    config.genesis_validators_root = [_]u8{0x44} ** 32;
    var engine = consensus_sync.ConsensusSyncEngine.init(config);

    try std.testing.expectError(
        error.ConsensusNetworkMismatch,
        engine.checkpointAgeInfoFromBeaconData(
            .{
                .genesis_time = 1_000,
                .genesis_validators_root = [_]u8{0x45} ** 32,
            },
            .{
                .root = [_]u8{0xaa} ** 32,
                .slot = 5,
            },
            [_]u8{0xaa} ** 32,
            1_180,
        ),
    );
}

test "checkpoint age rejects header root mismatch" {
    var config = testConfig(0, 120);
    config.genesis_validators_root = [_]u8{0x44} ** 32;
    var engine = consensus_sync.ConsensusSyncEngine.init(config);

    try std.testing.expectError(
        error.CheckpointRootMismatch,
        engine.checkpointAgeInfoFromBeaconData(
            .{
                .genesis_time = 1_000,
                .genesis_validators_root = [_]u8{0x44} ** 32,
            },
            .{
                .root = [_]u8{0xab} ** 32,
                .slot = 5,
            },
            [_]u8{0xaa} ** 32,
            1_180,
        ),
    );
}

test "strict checkpoint age rejects stale startup while non-strict warns and continues" {
    const checkpoint = [_]u8{0xaa} ** 32;
    const stale_info = consensus_sync.CheckpointAgeInfo{
        .checkpoint_time_seconds = 1_000,
        .startup_time_seconds = 1_121,
        .age_seconds = 121,
        .max_checkpoint_age_seconds = 120,
        .stale = true,
    };
    const context = consensus_sync.CheckpointStartupContext{ .source = "test" };

    var non_strict_config = testConfig(0, 120);
    non_strict_config.strict_checkpoint_age = false;
    var non_strict = consensus_sync.ConsensusSyncEngine.init(non_strict_config);
    try non_strict.enforceStartupCheckpointAge(checkpoint, context, stale_info);

    var strict_config = testConfig(0, 120);
    strict_config.strict_checkpoint_age = true;
    var strict = consensus_sync.ConsensusSyncEngine.init(strict_config);
    try std.testing.expectError(
        error.CheckpointTooOld,
        strict.enforceStartupCheckpointAge(checkpoint, context, stale_info),
    );
}

test "ConsensusSyncEngine initialization has expected defaults" {
    var engine = consensus_sync.ConsensusSyncEngine.init(testConfig(0, 1_209_600));

    try std.testing.expectEqual(consensus_sync.SyncStatus.syncing, engine.status);
    try std.testing.expect(engine.lastCheckpoint() == null);
    try std.testing.expectEqual(@as(u64, 0), engine.finalizedSlot());
    try std.testing.expectEqual(@as(u64, 0), engine.optimisticSlot());
}

test "slotTimestamp calculates slot time from genesis" {
    var engine = consensus_sync.ConsensusSyncEngine.init(testConfig(1_000, 1_209_600));

    try std.testing.expectEqual(@as(u64, 1_000), engine.slotTimestamp(0));
    try std.testing.expectEqual(@as(u64, 1_000 + 5 * 12), engine.slotTimestamp(5));
}
