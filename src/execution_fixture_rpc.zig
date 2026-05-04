const std = @import("std");
const jsonrpc = @import("jsonrpc");

pub const Cache = struct {
    entries: std.ArrayList(Entry) = .{},

    pub fn loadFromGenesisPath(
        allocator: std.mem.Allocator,
        maybe_genesis_path: ?[]const u8,
    ) !?Cache {
        const genesis_path = maybe_genesis_path orelse return null;
        const tests_dir = std.fs.path.dirname(genesis_path) orelse return null;
        return try loadFromTestsDir(allocator, tests_dir);
    }

    pub fn loadFromTestsDir(
        allocator: std.mem.Allocator,
        tests_dir: []const u8,
    ) !?Cache {
        var root = std.fs.cwd().openDir(tests_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return null,
            error.NotDir => return null,
            else => return err,
        };
        defer root.close();

        var cache = Cache{};
        errdefer cache.deinit(allocator);

        var method_dirs = std.ArrayList([]u8){};
        defer {
            for (method_dirs.items) |name| allocator.free(name);
            method_dirs.deinit(allocator);
        }

        var root_it = root.iterate();
        while (try root_it.next()) |entry| {
            if (entry.kind != .directory) continue;
            try method_dirs.append(allocator, try allocator.dupe(u8, entry.name));
        }
        std.mem.sort([]u8, method_dirs.items, {}, lessThanBytes);

        for (method_dirs.items) |method_dir| {
            var subdir = try root.openDir(method_dir, .{ .iterate = true });
            defer subdir.close();

            var file_names = std.ArrayList([]u8){};
            defer {
                for (file_names.items) |name| allocator.free(name);
                file_names.deinit(allocator);
            }

            var sub_it = subdir.iterate();
            while (try sub_it.next()) |entry| {
                if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".io")) continue;
                try file_names.append(allocator, try allocator.dupe(u8, entry.name));
            }
            std.mem.sort([]u8, file_names.items, {}, lessThanBytes);

            for (file_names.items) |file_name| {
                const path = try std.fs.path.join(allocator, &.{ tests_dir, method_dir, file_name });
                defer allocator.free(path);
                try cache.loadIoFile(allocator, path);
            }
        }

        if (cache.entries.items.len == 0) {
            cache.deinit(allocator);
            return null;
        }
        return cache;
    }

    pub fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(allocator);
        self.entries.deinit(allocator);
    }

    pub fn matchResponse(
        self: *const Cache,
        allocator: std.mem.Allocator,
        request: jsonrpc.envelope.RequestEnvelope,
    ) !?jsonrpc.envelope.ResponseEnvelope {
        for (self.entries.items) |entry| {
            if (!std.mem.eql(u8, entry.method, request.method)) continue;
            if (try entry.matches(allocator, request)) {
                return try entry.responseEnvelope(allocator, request.id);
            }
        }
        return null;
    }

    fn loadIoFile(
        self: *Cache,
        allocator: std.mem.Allocator,
        path: []const u8,
    ) !void {
        const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
        defer allocator.free(bytes);

        var pending_request: ?[]u8 = null;
        errdefer if (pending_request) |request_json| allocator.free(request_json);

        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line_raw| {
            const line = std.mem.trimRight(u8, line_raw, "\r");
            if (std.mem.startsWith(u8, line, ">> ")) {
                if (pending_request) |request_json| allocator.free(request_json);
                pending_request = try allocator.dupe(u8, line[3..]);
            } else if (std.mem.startsWith(u8, line, "<< ")) {
                var request_json = pending_request orelse return error.InvalidExecutionFixtureRpc;
                pending_request = null;
                errdefer if (request_json.len != 0) allocator.free(request_json);

                var response_json = try allocator.dupe(u8, line[3..]);
                errdefer if (response_json.len != 0) allocator.free(response_json);

                var method = try methodFromRequestJson(allocator, request_json);
                errdefer if (method.len != 0) allocator.free(method);

                var error_info = try errorInfoFromResponseJson(allocator, response_json);
                errdefer if (error_info) |*info| info.deinit(allocator);

                try self.entries.append(allocator, .{
                    .method = method,
                    .request_json = request_json,
                    .response_json = response_json,
                    .error_info = error_info,
                });
                request_json = request_json[0..0];
                response_json = response_json[0..0];
                method = method[0..0];
                error_info = null;
            }
        }

        if (pending_request) |request_json| {
            allocator.free(request_json);
            return error.InvalidExecutionFixtureRpc;
        }
    }
};

const Entry = struct {
    method: []u8,
    request_json: []u8,
    response_json: []u8,
    error_info: ?ErrorInfo = null,

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.method);
        allocator.free(self.request_json);
        allocator.free(self.response_json);
        if (self.error_info) |*info| info.deinit(allocator);
    }

    fn matches(
        self: Entry,
        allocator: std.mem.Allocator,
        request: jsonrpc.envelope.RequestEnvelope,
    ) !bool {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, self.request_json, .{ .allocate = .alloc_if_needed });
        defer parsed.deinit();

        const object = switch (parsed.value) {
            .object => |object| object,
            else => return error.InvalidExecutionFixtureRpc,
        };
        const expected_params = object.get("params");
        return optionalJsonEqual(request.params, expected_params);
    }

    fn responseEnvelope(
        self: Entry,
        allocator: std.mem.Allocator,
        id: ?jsonrpc.envelope.Id,
    ) !jsonrpc.envelope.ResponseEnvelope {
        if (self.error_info) |info| {
            return .{
                .id = id,
                .result = null,
                .error_value = .{
                    .code = info.code,
                    .message = info.message,
                    .data = if (info.data) |data| .{ .string = data } else null,
                    .owns_message = false,
                },
                .owns_result = false,
            };
        }

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, self.response_json, .{ .allocate = .alloc_if_needed });
        defer parsed.deinit();

        const object = switch (parsed.value) {
            .object => |object| object,
            else => return error.InvalidExecutionFixtureRpc,
        };
        const result: std.json.Value = if (object.get("result")) |value| value else .null;
        return jsonrpc.envelope.ResponseEnvelope.makeSuccess(id, try cloneJsonValue(allocator, result));
    }
};

const ErrorInfo = struct {
    code: i32,
    message: []u8,
    data: ?[]u8 = null,

    fn deinit(self: *ErrorInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        if (self.data) |data| allocator.free(data);
    }
};

fn errorInfoFromResponseJson(allocator: std.mem.Allocator, response_json: []const u8) !?ErrorInfo {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_json, .{ .allocate = .alloc_if_needed });
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidExecutionFixtureRpc,
    };
    const error_value = object.get("error") orelse return null;
    const error_object = switch (error_value) {
        .object => |value| value,
        else => return error.InvalidExecutionFixtureRpc,
    };
    const code = try jsonI32(error_object.get("code") orelse return error.InvalidExecutionFixtureRpc);
    const message_text = switch (error_object.get("message") orelse return error.InvalidExecutionFixtureRpc) {
        .string => |text| text,
        else => return error.InvalidExecutionFixtureRpc,
    };
    const message = try allocator.dupe(u8, message_text);
    errdefer allocator.free(message);

    const data = if (error_object.get("data")) |data_value| blk: {
        const data_text = switch (data_value) {
            .string => |text| text,
            else => return error.InvalidExecutionFixtureRpc,
        };
        break :blk try allocator.dupe(u8, data_text);
    } else null;
    errdefer if (data) |data_text| allocator.free(data_text);

    return .{
        .code = code,
        .message = message,
        .data = data,
    };
}

fn methodFromRequestJson(allocator: std.mem.Allocator, request_json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, request_json, .{ .allocate = .alloc_if_needed });
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidExecutionFixtureRpc,
    };
    const method = switch (object.get("method") orelse return error.InvalidExecutionFixtureRpc) {
        .string => |value| value,
        else => return error.InvalidExecutionFixtureRpc,
    };
    return try allocator.dupe(u8, method);
}

fn jsonI32(value: std.json.Value) !i32 {
    return switch (value) {
        .integer => |n| std.math.cast(i32, n) orelse error.InvalidExecutionFixtureRpc,
        .number_string => |text| std.fmt.parseInt(i32, text, 10) catch error.InvalidExecutionFixtureRpc,
        else => error.InvalidExecutionFixtureRpc,
    };
}

fn optionalJsonEqual(lhs: ?std.json.Value, rhs: ?std.json.Value) bool {
    if (lhs == null and rhs == null) return true;
    if (lhs == null or rhs == null) return false;
    return jsonEqual(lhs.?, rhs.?);
}

fn jsonEqual(lhs: std.json.Value, rhs: std.json.Value) bool {
    if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) {
        if ((lhs == .integer and rhs == .number_string) or (lhs == .number_string and rhs == .integer)) {
            return jsonNumberTextEqual(lhs, rhs);
        }
        return false;
    }

    return switch (lhs) {
        .null => true,
        .bool => |value| value == rhs.bool,
        .integer => |value| value == rhs.integer,
        .float => |value| value == rhs.float,
        .number_string => |value| std.mem.eql(u8, value, rhs.number_string),
        .string => |value| std.mem.eql(u8, value, rhs.string),
        .array => |lhs_array| blk: {
            const rhs_array = rhs.array;
            if (lhs_array.items.len != rhs_array.items.len) break :blk false;
            for (lhs_array.items, rhs_array.items) |lhs_item, rhs_item| {
                if (!jsonEqual(lhs_item, rhs_item)) break :blk false;
            }
            break :blk true;
        },
        .object => |lhs_object| blk: {
            const rhs_object = rhs.object;
            if (lhs_object.count() != rhs_object.count()) break :blk false;
            var it = lhs_object.iterator();
            while (it.next()) |entry| {
                const rhs_value = rhs_object.get(entry.key_ptr.*) orelse break :blk false;
                if (!jsonEqual(entry.value_ptr.*, rhs_value)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn jsonNumberTextEqual(lhs: std.json.Value, rhs: std.json.Value) bool {
    const lhs_int = switch (lhs) {
        .integer => |value| value,
        .number_string => |text| std.fmt.parseInt(i64, text, 10) catch return false,
        else => return false,
    };
    const rhs_int = switch (rhs) {
        .integer => |value| value,
        .number_string => |text| std.fmt.parseInt(i64, text, 10) catch return false,
        else => return false,
    };
    return lhs_int == rhs_int;
}

fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    return switch (value) {
        .null => .null,
        .bool => |v| .{ .bool = v },
        .integer => |v| .{ .integer = v },
        .float => |v| .{ .float = v },
        .number_string => |s| .{ .number_string = try allocator.dupe(u8, s) },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .array => |arr| blk: {
            var out = std.json.Array.init(allocator);
            errdefer {
                var out_value = std.json.Value{ .array = out };
                deinitJsonValue(allocator, &out_value);
            }
            for (arr.items) |item| {
                try out.append(try cloneJsonValue(allocator, item));
            }
            break :blk .{ .array = out };
        },
        .object => |obj| blk: {
            var out = std.json.ObjectMap.init(allocator);
            errdefer {
                var out_value = std.json.Value{ .object = out };
                deinitJsonValue(allocator, &out_value);
            }
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(key);
                var cloned = try cloneJsonValue(allocator, entry.value_ptr.*);
                errdefer deinitJsonValue(allocator, &cloned);
                try out.put(key, cloned);
            }
            break :blk .{ .object = out };
        },
    };
}

fn deinitJsonValue(allocator: std.mem.Allocator, value: *std.json.Value) void {
    switch (value.*) {
        .string => |s| allocator.free(s),
        .number_string => |s| allocator.free(s),
        .array => |*arr| {
            for (arr.items) |*item| deinitJsonValue(allocator, item);
            arr.deinit();
        },
        .object => |*obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                deinitJsonValue(allocator, entry.value_ptr);
            }
            obj.deinit();
        },
        else => {},
    }
}

fn lessThanBytes(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}
