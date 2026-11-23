const std = @import("std");
const config = @import("config.zig");

test "config.load uses trusted defaults" {
    var app_config = try config.load(std.testing.allocator, &[_][]const u8{});
    defer app_config.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("127.0.0.1", app_config.rpc.host);
    try std.testing.expectEqual(@as(u16, 8545), app_config.rpc.port);
    try std.testing.expectEqual(config.Mode.trusted, std.meta.activeTag(app_config.mode));
}

test "config.load reads --host and --port" {
    var app_config = try config.load(
        std.testing.allocator,
        &[_][]const u8{ "--host", "0.0.0.0", "--port", "9555" },
    );
    defer app_config.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("0.0.0.0", app_config.rpc.host);
    try std.testing.expectEqual(@as(u16, 9555), app_config.rpc.port);
}

test "config.load reads --fork-url and --fork-block-number" {
    var app_config = try config.load(
        std.testing.allocator,
        &[_][]const u8{
            "--fork-url",
            "https://rpc.example.org",
            "--fork-block-number",
            "2048",
        },
    );
    defer app_config.deinit(std.testing.allocator);

    const trusted = switch (app_config.mode) {
        .trusted => |trusted| trusted,
        .light => return error.ExpectedTrustedConfig,
    };
    try std.testing.expectEqualStrings("https://rpc.example.org", trusted.fork.?.url);
    try std.testing.expectEqual(@as(u64, 2048), trusted.fork.?.block_number.?);
}

const cli = @import("cli.zig");
const log = @import("log.zig");

test "fork URL startup log redacts API keys and credentials" {
    var buffer: [256]u8 = undefined;
    const cases = [_]struct { url: []const u8, expected: []const u8 }{
        .{ .url = "https://eth-mainnet.g.alchemy.com/v2/AbCdEfSecretKey", .expected = "https://eth-mainnet.g.alchemy.com" },
        .{ .url = "https://mainnet.infura.io/v3/0123456789abcdef", .expected = "https://mainnet.infura.io" },
        .{ .url = "https://user:hunter2@rpc.example.org:8545/", .expected = "https://rpc.example.org:8545" },
        .{ .url = "https://rpc.example.org?apikey=SECRET", .expected = "https://rpc.example.org" },
        .{ .url = "http://127.0.0.1:8545#token=SECRET", .expected = "http://127.0.0.1:8545" },
        .{ .url = "SECRET-without-scheme", .expected = "<redacted>" },
    };
    for (cases) |case| {
        const safe = log.redactUrl(&buffer, case.url);
        try std.testing.expectEqualStrings(case.expected, safe);
        try std.testing.expect(std.mem.indexOf(u8, safe, "SECRET") == null);
        try std.testing.expect(std.mem.indexOf(u8, safe, "Secret") == null);
        try std.testing.expect(std.mem.indexOf(u8, safe, "hunter2") == null);
    }
}

test "config rejects zero chain id, zero gas limit and zero interval block time" {
    const invalid = [_][]const []const u8{
        &.{ "--chain-id", "0" },
        &.{ "--block-gas-limit", "0" },
        &.{ "--mining", "interval", "--block-time", "0" },
    };
    for (invalid) |args| {
        try std.testing.expectError(error.InvalidConfig, config.load(std.testing.allocator, args));
    }
}

test "config reads --authrpc.jwtsecret and --execution-fixture-rpc-dir" {
    var app_config = try config.load(std.testing.allocator, &[_][]const u8{
        "--authrpc.jwtsecret",
        "/tmp/zevm-jwt.hex",
        "--execution-fixture-rpc-dir",
        "/tmp/fixtures",
    });
    defer app_config.deinit(std.testing.allocator);

    const engine_rpc = app_config.engine_rpc orelse return error.ExpectedEngineRpc;
    try std.testing.expectEqualStrings("/tmp/zevm-jwt.hex", engine_rpc.jwt_secret_file.?);
    try std.testing.expectEqual(config.DEFAULT_ENGINE_PORT, engine_rpc.port);
    const trusted = switch (app_config.mode) {
        .trusted => |trusted| trusted,
        .light => return error.ExpectedTrustedConfig,
    };
    try std.testing.expectEqualStrings("/tmp/fixtures", trusted.execution_fixture_rpc_dir.?);
}

test "execution fixture RPC dir is opt-in" {
    var app_config = try config.load(std.testing.allocator, &[_][]const u8{ "--genesis", "/tmp/tests/genesis.json" });
    defer app_config.deinit(std.testing.allocator);
    const trusted = switch (app_config.mode) {
        .trusted => |trusted| trusted,
        .light => return error.ExpectedTrustedConfig,
    };
    try std.testing.expect(trusted.execution_fixture_rpc_dir == null);
}

test "JWT secret hex parser accepts geth format and rejects bad lengths" {
    const hive_secret = "0x7365637265747365637265747365637265747365637265747365637265747365\n";
    const secret = try config.parseJwtSecretHex(hive_secret);
    try std.testing.expectEqualStrings("secretsecretsecretsecretsecretse", &secret);
    try std.testing.expectEqual(secret, try config.parseJwtSecretHex(hive_secret[2..]));
    try std.testing.expectError(error.InvalidJwtSecret, config.parseJwtSecretHex("0x1234"));
    try std.testing.expectError(error.InvalidJwtSecret, config.parseJwtSecretHex("zz65637265747365637265747365637265747365637265747365637265747365"));
}

test "JWT secret file loads from disk" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "jwt.hex", .data = "7365637265747365637265747365637265747365637265747365637265747365" });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "jwt.hex");
    defer std.testing.allocator.free(path);

    const secret = try config.loadJwtSecretFile(std.testing.allocator, path);
    try std.testing.expectEqualStrings("secretsecretsecretsecretsecretse", &secret);
}

test "cli recognizes --help and --version anywhere in argv" {
    try std.testing.expectEqual(@as(?cli.EarlyAction, .help), cli.earlyAction(&.{ "--bogus", "-h" }));
    try std.testing.expectEqual(@as(?cli.EarlyAction, .version), cli.earlyAction(&.{"--version"}));
    try std.testing.expectEqual(@as(?cli.EarlyAction, .help), cli.earlyAction(&.{ "--version", "--help" }));
    try std.testing.expect(cli.earlyAction(&.{ "--port", "8545" }) == null);
    const options = try cli.parse(&.{"--help"});
    try std.testing.expect(options.help);
}
