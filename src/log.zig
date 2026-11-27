const std = @import("std");

pub const Level = std.log.Level;

const default_level: Level = .info;
var active_level = std.atomic.Value(u8).init(@intFromEnum(default_level));

pub const LEVEL_ENV_VAR = "ZEVM_LOG_LEVEL";
const STACK_MESSAGE_BYTES = 4096;

pub fn init(level: Level) void {
    active_level.store(@intFromEnum(level), .release);
}

pub fn currentLevel() Level {
    return @enumFromInt(active_level.load(.monotonic));
}

/// Parses `err|error|warn|warning|info|debug` (case-insensitive).
pub fn parseLevel(text: []const u8) ?Level {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "err") or std.ascii.eqlIgnoreCase(trimmed, "error")) return .err;
    if (std.ascii.eqlIgnoreCase(trimmed, "warn") or std.ascii.eqlIgnoreCase(trimmed, "warning")) return .warn;
    if (std.ascii.eqlIgnoreCase(trimmed, "info")) return .info;
    if (std.ascii.eqlIgnoreCase(trimmed, "debug")) return .debug;
    return null;
}

/// Applies `ZEVM_LOG_LEVEL` when set and valid, otherwise `fallback`.
/// Returns false when the variable is set to an unknown value.
pub fn initFromEnv(fallback: Level) bool {
    init(fallback);
    if (std.posix.getenv(LEVEL_ENV_VAR)) |value| {
        const level = parseLevel(value) orelse return false;
        init(level);
    }
    return true;
}

/// Writes `scheme://host[:port]` for `url` into `out`, dropping userinfo,
/// path, query and fragment. RPC providers embed API keys in all of those.
/// Returns "<redacted>" when `url` has no scheme.
pub fn redactUrl(out: []u8, url: []const u8) []const u8 {
    const redacted = "<redacted>";
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return redacted;
    const scheme = url[0..scheme_end];
    if (scheme.len == 0) return redacted;
    for (scheme) |char| {
        if (!(std.ascii.isAlphanumeric(char) or char == '+' or char == '-' or char == '.')) return redacted;
    }

    const rest = url[scheme_end + 3 ..];
    const authority_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..authority_end];
    const host_port = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority[at + 1 ..] else authority;
    if (host_port.len == 0) return redacted;

    return std.fmt.bufPrint(out, "{s}://{s}", .{ scheme, host_port }) catch redacted;
}

/// Returns a single safe telemetry field for an untrusted RPC method name.
pub fn sanitizeRpcMethod(method: []const u8) []const u8 {
    if (method.len == 0 or method.len > 64) return "<invalid>";
    for (method) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return "<invalid>";
    }
    return method;
}

pub fn debug(
    comptime scope: @Type(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    if (!shouldLog(.debug)) return;
    std.log.scoped(scope).debug(fmt, args);
}

pub fn info(
    comptime scope: @Type(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    if (!shouldLog(.info)) return;
    std.log.scoped(scope).info(fmt, args);
}

pub fn warn(
    comptime scope: @Type(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    if (!shouldLog(.warn)) return;
    std.log.scoped(scope).warn(fmt, args);
}

pub fn err(
    comptime scope: @Type(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    if (!shouldLog(.err)) return;
    std.log.scoped(scope).err(fmt, args);
}

pub fn logFn(
    comptime message_level: Level,
    comptime scope: @Type(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    if (!shouldLog(message_level)) return;

    // Most records fit on the stack; only oversized ones touch the heap.
    var stack_message: [STACK_MESSAGE_BYTES]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&stack_message);
    var heap_message: ?std.Io.Writer.Allocating = null;
    defer if (heap_message) |*heap| heap.deinit();

    const message: []const u8 = if (fixed.print(fmt, args)) |_|
        fixed.buffered()
    else |_| blk: {
        heap_message = std.Io.Writer.Allocating.init(std.heap.page_allocator);
        heap_message.?.writer.print(fmt, args) catch return;
        break :blk heap_message.?.written();
    };

    var scratch = std.heap.stackFallback(1024, std.heap.page_allocator);

    var buffer: [1024]u8 = undefined;
    const stderr = std.debug.lockStderrWriter(&buffer);
    defer std.debug.unlockStderrWriter();

    nosuspend writeJsonRecord(
        scratch.get(),
        stderr,
        std.time.timestamp(),
        message_level,
        @tagName(scope),
        message,
    ) catch return;
}

/// Cheap level check so callers can skip building expensive log payloads.
pub fn shouldLog(level: Level) bool {
    return @intFromEnum(level) <= active_level.load(.monotonic);
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
        if (std.ascii.isWhitespace(char) or std.ascii.isControl(char)) return "";
    }
    return trimmed;
}

/// Field tokens are separated by spaces and tabs only. A newline or other
/// control byte stays inside its token, so an interpolated value cannot start
/// a forged `key=value` field on a new line; JSON encoding escapes the byte.
fn isFieldSeparator(char: u8) bool {
    return char == ' ' or char == '\t';
}

fn firstFieldTokenStart(message: []const u8) ?usize {
    var index: usize = 0;
    while (index < message.len) {
        while (index < message.len and isFieldSeparator(message[index])) : (index += 1) {}
        if (index >= message.len) return null;

        const token_start = index;
        while (index < message.len and !isFieldSeparator(message[index])) : (index += 1) {}
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
        while (index < message.len and isFieldSeparator(message[index])) : (index += 1) {}
        if (index >= message.len) return;

        const token_start = index;
        while (index < message.len and !isFieldSeparator(message[index])) : (index += 1) {}
        const token = message[token_start..index];
        const parts = fieldTokenParts(token) orelse continue;
        if (isReservedField(parts.key)) continue;
        // First occurrence wins: text interpolated after a field cannot
        // override it, and the JSON object never carries duplicate keys.
        if (keyAppearsBefore(message[0..token_start], parts.key)) continue;

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

fn keyAppearsBefore(prefix: []const u8, key: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, prefix, " \t");
    while (tokens.next()) |token| {
        const parts = fieldTokenParts(token) orelse continue;
        if (std.mem.eql(u8, parts.key, key)) return true;
    }
    return false;
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

test "structured fields keep control bytes inside escaped values" {
    init(.info);

    const line = (try formatForTest(
        std.testing.allocator,
        1,
        .info,
        "rpc",
        "request failed method={s} status=ok",
        .{"eth_call\nlevel=debug\nstatus=forged"},
    )).?;
    defer std.testing.allocator.free(line);

    // One physical line: the record cannot be split by injected newlines.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, line, "\n"));
    try std.testing.expect(std.mem.endsWith(u8, line, "}\n"));

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("info", obj.get("level").?.string);
    try std.testing.expectEqualStrings("eth_call\nlevel=debug\nstatus=forged", obj.get("method").?.string);
    try std.testing.expectEqualStrings("ok", obj.get("status").?.string);
}

test "duplicate structured keys keep the first value" {
    init(.info);

    const line = (try formatForTest(
        std.testing.allocator,
        1,
        .info,
        "rpc",
        "event user={s} user=admin",
        .{"alice"},
    )).?;
    defer std.testing.allocator.free(line);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("alice", parsed.value.object.get("user").?.string);
}

test "parseLevel accepts documented names" {
    try std.testing.expectEqual(@as(?Level, .err), parseLevel("error"));
    try std.testing.expectEqual(@as(?Level, .err), parseLevel("ERR"));
    try std.testing.expectEqual(@as(?Level, .warn), parseLevel("warning"));
    try std.testing.expectEqual(@as(?Level, .info), parseLevel(" info\n"));
    try std.testing.expectEqual(@as(?Level, .debug), parseLevel("Debug"));
    try std.testing.expect(parseLevel("verbose") == null);
}

test "redactUrl strips credentials, path, query and fragment" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("https://mainnet.infura.io", redactUrl(&buf, "https://mainnet.infura.io/v3/SECRETKEY"));
    try std.testing.expectEqualStrings("https://rpc.example.org:8545", redactUrl(&buf, "https://user:pass@rpc.example.org:8545/path?apikey=SECRET#frag"));
    try std.testing.expectEqualStrings("wss://eth.example", redactUrl(&buf, "wss://eth.example?key=SECRET"));
    try std.testing.expectEqualStrings("http://[::1]:8545", redactUrl(&buf, "http://[::1]:8545"));
    try std.testing.expectEqualStrings("<redacted>", redactUrl(&buf, "not a url with SECRET"));
    try std.testing.expectEqualStrings("<redacted>", redactUrl(&buf, "https://user:SECRET@/path"));

    var tiny: [8]u8 = undefined;
    try std.testing.expectEqualStrings("<redacted>", redactUrl(&tiny, "https://very-long-host.example"));
}
