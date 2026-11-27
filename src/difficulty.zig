const std = @import("std");

pub const DifficultyFork = enum {
    frontier,
    homestead,
    byzantium,
    constantinople,
    muir_glacier,
    london,
    arrow_glacier,
    gray_glacier,
    merge,
};

pub const MINIMUM_DIFFICULTY: u256 = 131_072;

const fork_names = std.StaticStringMap(DifficultyFork).initComptime(.{
    .{ "Frontier", .frontier },
    .{ "Homestead", .homestead },
    .{ "DAO", .homestead },
    .{ "DAOFork", .homestead },
    .{ "EIP150", .homestead },
    .{ "TangerineWhistle", .homestead },
    .{ "EIP158", .homestead },
    .{ "SpuriousDragon", .homestead },
    .{ "Byzantium", .byzantium },
    .{ "Constantinople", .constantinople },
    .{ "ConstantinopleFix", .constantinople },
    .{ "Petersburg", .constantinople },
    .{ "Istanbul", .constantinople },
    .{ "MuirGlacier", .muir_glacier },
    .{ "EIP2384", .muir_glacier },
    .{ "Berlin", .muir_glacier },
    .{ "London", .london },
    .{ "ArrowGlacier", .arrow_glacier },
    .{ "GrayGlacier", .gray_glacier },
    .{ "Paris", .merge },
    .{ "Merge", .merge },
    .{ "Shanghai", .merge },
    .{ "Cancun", .merge },
    .{ "Prague", .merge },
    .{ "Osaka", .merge },
    .{ "Fusaka", .merge },
});

pub fn forkFromName(name: []const u8) ?DifficultyFork {
    return fork_names.get(name);
}

pub fn calcDifficulty(
    fork: DifficultyFork,
    parent_timestamp: u64,
    current_timestamp: u64,
    parent_difficulty: u256,
    current_block_number: u64,
    parent_has_uncles: bool,
) u256 {
    if (fork == .merge) return 0;

    const elapsed = @as(i128, current_timestamp) - @as(i128, parent_timestamp);
    const uncle_factor: i128 = if (parent_has_uncles) 2 else 1;
    const adjustment: i128 = switch (fork) {
        .frontier => if (elapsed < 13) 1 else -1,
        .homestead => @max(1 - @divFloor(elapsed, 10), -99),
        else => @max(uncle_factor - @divFloor(elapsed, 9), -99),
    };
    const change = (parent_difficulty / 2048) *| @as(u256, @abs(adjustment));
    const adjusted = if (adjustment < 0) parent_difficulty -| change else parent_difficulty +| change;
    const base = @max(MINIMUM_DIFFICULTY, adjusted);

    const bomb_delay: u64 = switch (fork) {
        .frontier, .homestead => 0,
        .byzantium => 3_000_000,
        .constantinople => 5_000_000,
        .muir_glacier => 9_000_000,
        .london => 9_700_000,
        .arrow_glacier => 10_700_000,
        .gray_glacier => 11_400_000,
        .merge => return 0,
    };
    const period = (current_block_number -| bomb_delay) / 100_000;
    if (period < 2) return base;

    // Saturate when the mathematical difficulty exceeds the u256 return type.
    const exponent = period - 2;
    if (exponent >= 256) return std.math.maxInt(u256);
    return base +| (@as(u256, 1) << @intCast(exponent));
}

test "difficulty fixture fork names and aliases" {
    for (fork_names.keys(), fork_names.values()) |name, fork| {
        try std.testing.expectEqual(@as(?DifficultyFork, fork), forkFromName(name));
    }
    try std.testing.expectEqual(@as(?DifficultyFork, null), forkFromName("Unknown"));
}

test "Frontier switches at 13 seconds and ignores uncles" {
    const parent = 2_048_001;
    try std.testing.expectEqual(@as(u256, 2_049_001), calcDifficulty(.frontier, 100, 112, parent, 0, false));
    try std.testing.expectEqual(@as(u256, 2_047_001), calcDifficulty(.frontier, 100, 113, parent, 0, true));
}

test "Homestead uses ten second steps and caps decreases" {
    const parent = 2_048_000;
    try std.testing.expectEqual(@as(u256, 2_049_000), calcDifficulty(.homestead, 100, 109, parent, 0, true));
    try std.testing.expectEqual(@as(u256, parent), calcDifficulty(.homestead, 100, 110, parent, 0, false));
    try std.testing.expectEqual(@as(u256, 2_047_000), calcDifficulty(.homestead, 100, 120, parent, 0, false));
    try std.testing.expectEqual(@as(u256, 1_949_000), calcDifficulty(.homestead, 0, 1010, parent, 0, false));
}

test "Byzantium uses nine second steps and the parent uncle factor" {
    const parent = 2_048_000;
    try std.testing.expectEqual(@as(u256, 2_049_000), calcDifficulty(.byzantium, 0, 8, parent, 0, false));
    try std.testing.expectEqual(@as(u256, parent), calcDifficulty(.byzantium, 0, 9, parent, 0, false));
    try std.testing.expectEqual(@as(u256, 2_049_000), calcDifficulty(.byzantium, 0, 9, parent, 0, true));
    try std.testing.expectEqual(@as(u256, parent), calcDifficulty(.byzantium, 0, 18, parent, 0, true));
    try std.testing.expectEqual(@as(u256, 2_047_000), calcDifficulty(.byzantium, 0, 18, parent, 0, false));
    try std.testing.expectEqual(@as(u256, 1_949_000), calcDifficulty(.byzantium, 0, 918, parent, 0, true));
}

test "equal and decreasing timestamps use signed floor division" {
    const parent = 2_048_000;
    try std.testing.expectEqual(@as(u256, 2_049_000), calcDifficulty(.homestead, 100, 100, parent, 0, false));
    try std.testing.expectEqual(@as(u256, 2_050_000), calcDifficulty(.homestead, 100, 99, parent, 0, false));
    try std.testing.expectEqual(@as(u256, 2_050_000), calcDifficulty(.byzantium, 100, 100, parent, 0, true));
    try std.testing.expectEqual(@as(u256, 2_051_000), calcDifficulty(.byzantium, 100, 99, parent, 0, true));
    try std.testing.expectEqual(@as(u256, 2_052_000), calcDifficulty(.byzantium, 100, 90, parent, 0, true));
}

test "every proof of work fork starts its bomb after two periods and adds it after the minimum" {
    const forks = [_]DifficultyFork{ .frontier, .homestead, .byzantium, .constantinople, .muir_glacier, .london, .arrow_glacier, .gray_glacier };
    const delays = [_]u64{ 0, 0, 3_000_000, 5_000_000, 9_000_000, 9_700_000, 10_700_000, 11_400_000 };
    for (forks, delays) |fork, delay| {
        try std.testing.expectEqual(MINIMUM_DIFFICULTY, calcDifficulty(fork, 0, 30, MINIMUM_DIFFICULTY, delay -| 1, false));
        try std.testing.expectEqual(MINIMUM_DIFFICULTY, calcDifficulty(fork, 0, 30, MINIMUM_DIFFICULTY, delay + 199_999, false));
        try std.testing.expectEqual(MINIMUM_DIFFICULTY + 1, calcDifficulty(fork, 0, 30, MINIMUM_DIFFICULTY, delay + 200_000, false));
        try std.testing.expectEqual(MINIMUM_DIFFICULTY + 2, calcDifficulty(fork, 0, 30, MINIMUM_DIFFICULTY, delay + 300_000, false));
    }
}

test "bomb and adjustment saturate at the u256 limit and Merge returns zero" {
    const limit = std.math.maxInt(u256);
    try std.testing.expectEqual(limit, calcDifficulty(.frontier, 0, 1, limit, 0, false));
    try std.testing.expectEqual(limit, calcDifficulty(.frontier, 0, 13, 0, 25_800_000, false));
    try std.testing.expectEqual(MINIMUM_DIFFICULTY + (@as(u256, 1) << 255), calcDifficulty(.frontier, 0, 13, 0, 25_700_000, false));
    try std.testing.expectEqual(@as(u256, 0), calcDifficulty(.merge, 0, 1, limit, std.math.maxInt(u64), true));
}
