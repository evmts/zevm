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
        std.heap.page_allocator,
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
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    timestamp: i64,
    level: Level,
    scope: []const u8,
    message: []const u8,
) !void {
    const fields_start = firstFieldTokenStart(message);
    const event_source = if (fields_start) |start|
        std.mem.trim(u8, message[0..start], " \t\r\n")
    else
        eventOnlyMessage(message);

    const event_name = try buildEventName(allocator, event_source);
    defer if (event_name) |name| allocator.free(name);

    try writer.print("{{\"timestamp\":{},\"level\":\"{s}\",\"scope\":", .{
        timestamp,
        levelText(level),
    });
    try std.json.Stringify.value(scope, .{}, writer);
    try writer.writeAll(",\"message\":");
    try std.json.Stringify.value(message, .{}, writer);
    if (event_name) |name| {
        try writer.writeAll(",\"event\":");
        try std.json.Stringify.value(name, .{}, writer);
    }
    if (fields_start) |start| {
        try writeStructuredFields(writer, message[start..]);
    }
    try writer.writeAll("}\n");
}

fn eventOnlyMessage(message: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, message, " \t\r\n");
    for (trimmed) |char| {
        if (std.ascii.isWhitespace(char)) return "";
    }
    return trimmed;
}

fn firstFieldTokenStart(message: []const u8) ?usize {
    var index: usize = 0;
    while (index < message.len) {
        while (index < message.len and std.ascii.isWhitespace(message[index])) : (index += 1) {}
        if (index >= message.len) return null;

        const token_start = index;
        while (index < message.len and !std.ascii.isWhitespace(message[index])) : (index += 1) {}
        const token = message[token_start..index];
        if (fieldTokenParts(token) != null) return token_start;
    }
    return null;
}

fn buildEventName(allocator: std.mem.Allocator, source: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (trimmed.len == 0) return null;

    var buffer = try allocator.alloc(u8, trimmed.len);
    errdefer allocator.free(buffer);

    var len: usize = 0;
    var last_separator = true;
    for (trimmed) |char| {
        if (std.ascii.isAlphanumeric(char)) {
            buffer[len] = std.ascii.toLower(char);
            len += 1;
            last_separator = false;
        } else if (!last_separator) {
            buffer[len] = '_';
            len += 1;
            last_separator = true;
        }
    }

    if (len > 0 and buffer[len - 1] == '_') len -= 1;
    if (len == 0) {
        allocator.free(buffer);
        return null;
    }

    const event_name = try allocator.dupe(u8, buffer[0..len]);
    allocator.free(buffer);
    return event_name;
}

fn writeStructuredFields(writer: *std.Io.Writer, message: []const u8) !void {
    var index: usize = 0;
    while (index < message.len) {
        while (index < message.len and std.ascii.isWhitespace(message[index])) : (index += 1) {}
        if (index >= message.len) return;

        const token_start = index;
        while (index < message.len and !std.ascii.isWhitespace(message[index])) : (index += 1) {}
        const token = message[token_start..index];
        const parts = fieldTokenParts(token) orelse continue;
        if (isReservedField(parts.key)) continue;

        try writer.writeAll(",");
        try std.json.Stringify.value(parts.key, .{}, writer);
        try writer.writeAll(":");
        try writeFieldValue(writer, parts.value);
    }
}

const FieldTokenParts = struct {
    key: []const u8,
    value: []const u8,
};

fn fieldTokenParts(token: []const u8) ?FieldTokenParts {
    const equals_index = std.mem.indexOfScalar(u8, token, '=') orelse return null;
    if (equals_index == 0) return null;

    const key = token[0..equals_index];
    if (!isValidFieldKey(key)) return null;

    return .{
        .key = key,
        .value = token[equals_index + 1 ..],
    };
}

fn isValidFieldKey(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |char| {
        if (!(std.ascii.isAlphanumeric(char) or char == '_' or char == '-' or char == '.')) return false;
    }
    return true;
}

fn isReservedField(key: []const u8) bool {
    return std.mem.eql(u8, key, "timestamp") or
        std.mem.eql(u8, key, "level") or
        std.mem.eql(u8, key, "scope") or
        std.mem.eql(u8, key, "message") or
        std.mem.eql(u8, key, "event");
}

fn writeFieldValue(writer: *std.Io.Writer, value: []const u8) !void {
    if (std.mem.eql(u8, value, "true") or
        std.mem.eql(u8, value, "false") or
        std.mem.eql(u8, value, "null"))
    {
        try writer.writeAll(value);
    } else if (isJsonInteger(value)) {
        try writer.writeAll(value);
    } else {
        try std.json.Stringify.value(value, .{}, writer);
    }
}

fn isJsonInteger(value: []const u8) bool {
    if (value.len == 0) return false;

    const start: usize = if (value[0] == '-') 1 else 0;
    if (start == value.len) return false;

    if (value[start] == '0') return start + 1 == value.len;
    if (value[start] < '1' or value[start] > '9') return false;

    for (value[start + 1 ..]) |char| {
        if (!std.ascii.isDigit(char)) return false;
    }
    return true;
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
    try writeJsonRecord(allocator, &out.writer, timestamp, level, scope, message.written());
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
    try std.testing.expect(obj.get("event") == null);
}

test "operator log records expose structured event and fields" {
    init(.info);

    const line = (try formatForTest(
        std.testing.allocator,
        1_778_848_800,
        .err,
        "startup",
        "config load failed path=/tmp/zevm.toml failureClass=io error=FileNotFound attempts=2 strictCheckpointAge=false checkpoint=0xabc",
        .{},
    )).?;
    defer std.testing.allocator.free(line);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("config_load_failed", obj.get("event").?.string);
    try std.testing.expectEqualStrings("/tmp/zevm.toml", obj.get("path").?.string);
    try std.testing.expectEqualStrings("io", obj.get("failureClass").?.string);
    try std.testing.expectEqualStrings("FileNotFound", obj.get("error").?.string);
    try std.testing.expectEqual(@as(i64, 2), obj.get("attempts").?.integer);
    try std.testing.expect(!obj.get("strictCheckpointAge").?.bool);
    try std.testing.expectEqualStrings("0xabc", obj.get("checkpoint").?.string);
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
