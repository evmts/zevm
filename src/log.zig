const std = @import("std");

pub const Level = std.log.Level;

const default_level: Level = .info;
var active_level = std.atomic.Value(u8).init(@intFromEnum(default_level));

pub fn init(level: Level) void {
    active_level.store(@intFromEnum(level), .seq_cst);
}

pub fn info(
    comptime scope: @Type(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    std.log.scoped(scope).info(fmt, args);
}

pub fn warn(
    comptime scope: @Type(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    std.log.scoped(scope).warn(fmt, args);
}

pub fn err(
    comptime scope: @Type(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    std.log.scoped(scope).err(fmt, args);
}

pub fn logFn(
    comptime message_level: Level,
    comptime scope: @Type(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    if (!shouldLog(message_level)) return;

    var message = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer message.deinit();
    message.writer.print(fmt, args) catch return;

    var buffer: [1024]u8 = undefined;
    const stderr = std.debug.lockStderrWriter(&buffer);
    defer std.debug.unlockStderrWriter();

    nosuspend writeJsonRecord(
        stderr,
        std.time.timestamp(),
        message_level,
        @tagName(scope),
        message.written(),
    ) catch return;
}

fn shouldLog(level: Level) bool {
    return @intFromEnum(level) <= active_level.load(.seq_cst);
}

fn levelText(level: Level) []const u8 {
    return switch (level) {
        .err => "error",
        .warn => "warn",
        .info => "info",
        .debug => "debug",
    };
}

fn writeJsonRecord(
    writer: *std.Io.Writer,
    timestamp: i64,
    level: Level,
    scope: []const u8,
    message: []const u8,
) !void {
    try writer.print("{{\"timestamp\":{},\"level\":\"{s}\",\"scope\":", .{
        timestamp,
        levelText(level),
    });
    try std.json.Stringify.value(scope, .{}, writer);
    try writer.writeAll(",\"message\":");
    try std.json.Stringify.value(message, .{}, writer);
    try writer.writeAll("}\n");
}

fn formatForTest(
    allocator: std.mem.Allocator,
    timestamp: i64,
    level: Level,
    scope: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) !?[]u8 {
    if (!shouldLog(level)) return null;

    var message = std.Io.Writer.Allocating.init(allocator);
    defer message.deinit();
    try message.writer.print(fmt, args);

    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    try writeJsonRecord(&out.writer, timestamp, level, scope, message.written());
    const line = try out.toOwnedSlice();
    return line;
}

test "operator log records are JSON lines with timestamp level scope and message" {
    init(.info);

    const line = (try formatForTest(
        std.testing.allocator,
        1_778_848_800,
        .warn,
        "consensus_sync",
        "checkpoint {s} is {d}s old",
        .{ "0xabc", 42 },
    )).?;
    defer std.testing.allocator.free(line);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .object);
    const obj = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 1_778_848_800), obj.get("timestamp").?.integer);
    try std.testing.expectEqualStrings("warn", obj.get("level").?.string);
    try std.testing.expectEqualStrings("consensus_sync", obj.get("scope").?.string);
    try std.testing.expectEqualStrings("checkpoint 0xabc is 42s old", obj.get("message").?.string);
}

test "operator log level filtering suppresses lower-priority records" {
    init(.warn);
    defer init(.info);

    try std.testing.expect(try formatForTest(
        std.testing.allocator,
        1,
        .info,
        "startup",
        "mode selected",
        .{},
    ) == null);

    const line = (try formatForTest(
        std.testing.allocator,
        1,
        .err,
        "rpc",
        "internal error",
        .{},
    )).?;
    defer std.testing.allocator.free(line);

    try std.testing.expect(std.mem.indexOf(u8, line, "\"level\":\"error\"") != null);
}
