const std = @import("std");
const cli = @import("cli.zig");

test "parse returns only user supplied values" {
    const options = try cli.parse(&[_][]const u8{});

    try std.testing.expect(options.mode == null);
    try std.testing.expect(options.host == null);
    try std.testing.expect(options.port == null);
    try std.testing.expect(!options.strict_checkpoint_age);
    try std.testing.expect(!options.strict_checkpoint_age_present);
}

test "parse reads shared and trusted flags" {
    const options = try cli.parse(&[_][]const u8{
        "--config",
        "zevm.json",
        "--mode",
        "trusted",
        "--host",
        "0.0.0.0",
        "--port",
        "9555",
        "--chain-id",
        "1",
        "--coinbase-index",
        "9",
        "--initial-balance",
        "100",
        "--gas-price",
        "2",
        "--base-fee",
        "3",
        "--blob-base-fee",
        "4",
        "--max-priority-fee-per-gas",
        "5",
        "--block-gas-limit",
        "30000000",
        "--mining",
        "interval",
        "--block-time",
        "12",
        "--fork-url",
        "https://rpc.example",
        "--fork-block-number",
        "123",
    });

    try std.testing.expectEqualStrings("zevm.json", options.config_path.?);
    try std.testing.expectEqual(cli.Mode.trusted, options.mode.?);
    try std.testing.expectEqualStrings("0.0.0.0", options.host.?);
    try std.testing.expectEqual(@as(u16, 9555), options.port.?);
    try std.testing.expectEqual(@as(u64, 1), options.chain_id.?);
    try std.testing.expectEqual(@as(u8, 9), options.coinbase_index.?);
    try std.testing.expectEqual(@as(u256, 100), options.initial_balance.?);
    try std.testing.expectEqual(cli.MiningType.interval, options.mining.?);
    try std.testing.expectEqual(@as(u64, 12), options.block_time.?);
    try std.testing.expectEqualStrings("https://rpc.example", options.fork_url.?);
    try std.testing.expectEqual(@as(u64, 123), options.fork_block_number.?);
    try std.testing.expect(options.hasTrustedOnly());
}

test "parse reads light flags" {
    const checkpoint = "0x1111111111111111111111111111111111111111111111111111111111111111";
    const options = try cli.parse(&[_][]const u8{
        "--mode",
        "light",
        "--network",
        "sepolia",
        "--consensus-rpc-url",
        "https://beacon.example",
        "--checkpoint",
        checkpoint,
        "--checkpoint-dir",
        ".state/<network>",
        "--max-checkpoint-age-seconds",
        "42",
        "--strict-checkpoint-age",
    });

    try std.testing.expectEqual(cli.Mode.light, options.mode.?);
    try std.testing.expectEqual(cli.Network.sepolia, options.network.?);
    try std.testing.expectEqualStrings("https://beacon.example", options.consensus_rpc_url.?);
    try std.testing.expectEqual(@as(u8, 0x11), options.checkpoint.?[0]);
    try std.testing.expectEqualStrings(".state/<network>", options.checkpoint_dir.?);
    try std.testing.expectEqual(@as(u64, 42), options.max_checkpoint_age_seconds.?);
    try std.testing.expect(options.strict_checkpoint_age);
    try std.testing.expect(options.strict_checkpoint_age_present);
    try std.testing.expect(options.hasLightOnly());
}

test "parse rejects unknown and malformed flags" {
    try std.testing.expectError(error.UnknownArgument, cli.parse(&[_][]const u8{"--bogus"}));
    try std.testing.expectError(error.MissingFlagValue, cli.parse(&[_][]const u8{"--host"}));
    try std.testing.expectError(error.InvalidFlagValue, cli.parse(&[_][]const u8{ "--mode", "archive" }));
    try std.testing.expectError(error.InvalidFlagValue, cli.parse(&[_][]const u8{"--strict-checkpoint-age=false"}));
}
