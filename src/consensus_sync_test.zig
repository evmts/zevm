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
