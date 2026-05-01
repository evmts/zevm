const std = @import("std");

pub const Id = union(enum) {
    number: i64,
    string: []const u8,
    null_value: void,
};

pub const Request = struct {
    id: ?Id,
    method: []const u8,
    params: ?std.json.Value,
    invalid_request: bool = false,
    owns_memory: bool = false,

    pub fn deinit(self: *Request, allocator: std.mem.Allocator) void {
        if (!self.owns_memory) {
            return;
        }

        if (self.id) |id| {
            switch (id) {
                .string => |text| allocator.free(text),
                else => {},
            }
        }

        allocator.free(self.method);

        if (self.params) |*params| {
            deinitValue(allocator, params);
        }
    }
};

pub const ParsedBody = union(enum) {
    single: Request,
    batch: []Request,

    pub fn deinit(self: *ParsedBody, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .single => |*request| {
                request.deinit(allocator);
            },
            .batch => |requests| {
                for (requests) |*request| {
                    request.deinit(allocator);
                }
                allocator.free(requests);
            },
        }
    }
};

pub fn parseId(value: std.json.Value) !Id {
    return switch (value) {
        .integer => |number| .{ .number = number },
        .string => |text| .{ .string = text },
        .number_string => |text| .{ .number = std.fmt.parseInt(i64, text, 10) catch return error.InvalidRequest },
        .null => .{ .null_value = {} },
        else => error.InvalidRequest,
    };
}

pub fn validateRequestObject(value: std.json.Value) !void {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidRequest,
    };

    const version = object.get("jsonrpc") orelse return error.InvalidRequest;
    switch (version) {
        .string => |text| {
            if (!std.mem.eql(u8, text, "2.0")) {
                return error.InvalidRequest;
            }
        },
        else => return error.InvalidRequest,
    }

    const method_value = object.get("method") orelse return error.InvalidRequest;
    switch (method_value) {
        .string => |method_name| {
            if (method_name.len == 0) {
                return error.InvalidRequest;
            }
        },
        else => return error.InvalidRequest,
    }

    if (object.get("id")) |id_value| {
        _ = parseId(id_value) catch return error.InvalidRequest;
    }
}

pub fn parseRequestObject(value: std.json.Value) !Request {
    try validateRequestObject(value);

    const object = value.object;

    var request_id: ?Id = null;
    if (object.get("id")) |id_value| {
        request_id = try parseId(id_value);
    }

    return .{
        .id = request_id,
        .method = object.get("method").?.string,
        .params = object.get("params"),
    };
}

pub fn parseBody(allocator: std.mem.Allocator, bytes: []const u8) !ParsedBody {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
    }) catch {
        return error.ParseError;
    };
    defer parsed.deinit();

    switch (parsed.value) {
        .object => {
            return .{ .single = try cloneRequestObject(allocator, parsed.value) };
        },
        .array => |array| {
            if (array.items.len == 0) {
                return error.InvalidRequest;
            }

            const requests = try allocator.alloc(Request, array.items.len);
            var written: usize = 0;
            errdefer {
                var index: usize = 0;
                while (index < written) : (index += 1) {
                    requests[index].deinit(allocator);
                }
                allocator.free(requests);
            }

            for (array.items) |item| {
                requests[written] = cloneRequestObject(allocator, item) catch |err| switch (err) {
                    error.InvalidRequest => try cloneInvalidBatchItem(allocator, item),
                    else => return err,
                };
                written += 1;
            }

            return .{ .batch = requests };
        },
        else => return error.InvalidRequest,
    }
}

pub fn writeId(writer: anytype, id: ?Id) !void {
    if (id) |actual_id| {
        switch (actual_id) {
            .number => |number| {
                try std.json.Stringify.value(std.json.Value{ .integer = number }, .{}, writer);
            },
            .string => |text| {
                try std.json.Stringify.value(std.json.Value{ .string = text }, .{}, writer);
            },
            .null_value => {
                try writer.writeAll("null");
            },
        }
        return;
    }

    try writer.writeAll("null");
}

pub fn writeSuccess(allocator: std.mem.Allocator, id: ?Id, result: std.json.Value) ![]u8 {
    var response_writer = std.Io.Writer.Allocating.init(allocator);
    defer response_writer.deinit();

    try response_writer.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(&response_writer.writer, id);
    try response_writer.writer.writeAll(",\"result\":");
    try std.json.Stringify.value(result, .{}, &response_writer.writer);
    try response_writer.writer.writeByte('}');

    return response_writer.toOwnedSlice();
}

pub fn writeError(allocator: std.mem.Allocator, id: ?Id, code: i32, message: []const u8) ![]u8 {
    var response_writer = std.Io.Writer.Allocating.init(allocator);
    defer response_writer.deinit();

    try response_writer.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(&response_writer.writer, id);
    try response_writer.writer.writeAll(",\"error\":{\"code\":");
    try response_writer.writer.print("{d}", .{code});
    try response_writer.writer.writeAll(",\"message\":");
    try std.json.Stringify.value(std.json.Value{ .string = message }, .{}, &response_writer.writer);
    try response_writer.writer.writeAll("}}");

    return response_writer.toOwnedSlice();
}

fn cloneRequestObject(allocator: std.mem.Allocator, value: std.json.Value) !Request {
    const request = try parseRequestObject(value);

    var cloned = Request{
        .id = try cloneId(allocator, request.id),
        .method = try allocator.dupe(u8, request.method),
        .params = null,
        .invalid_request = false,
        .owns_memory = true,
    };
    errdefer {
        if (cloned.id) |id| {
            switch (id) {
                .string => |text| allocator.free(text),
                else => {},
            }
        }
        allocator.free(cloned.method);
    }

    if (request.params) |params| {
        cloned.params = try cloneValue(allocator, params);
    }

    return cloned;
}

fn cloneInvalidBatchItem(allocator: std.mem.Allocator, value: std.json.Value) !Request {
    var request_id: ?Id = null;
    if (value == .object) {
        if (value.object.get("id")) |id_value| {
            request_id = parseId(id_value) catch null;
        }
    }

    return .{
        .id = try cloneId(allocator, request_id),
        .method = try allocator.dupe(u8, ""),
        .params = null,
        .invalid_request = true,
        .owns_memory = true,
    };
}

fn cloneId(allocator: std.mem.Allocator, id: ?Id) !?Id {
    if (id) |value| {
        return switch (value) {
            .number => |number| .{ .number = number },
            .string => |text| .{ .string = try allocator.dupe(u8, text) },
            .null_value => .{ .null_value = {} },
        };
    }

    return null;
}

fn cloneValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    return switch (value) {
        .null => .null,
        .bool => |boolean| .{ .bool = boolean },
        .integer => |number| .{ .integer = number },
        .float => |number| .{ .float = number },
        .number_string => |text| .{ .number_string = try allocator.dupe(u8, text) },
        .string => |text| .{ .string = try allocator.dupe(u8, text) },
        .array => |array| blk: {
            var cloned_array = std.json.Array.init(allocator);
            errdefer {
                for (cloned_array.items) |*item| {
                    deinitValue(allocator, item);
                }
                cloned_array.deinit();
            }

            for (array.items) |item| {
                try cloned_array.append(try cloneValue(allocator, item));
            }

            break :blk .{ .array = cloned_array };
        },
        .object => |object| blk: {
            var cloned_object = std.json.ObjectMap.init(allocator);
            errdefer {
                var iterator = cloned_object.iterator();
                while (iterator.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    deinitValue(allocator, entry.value_ptr);
                }
                cloned_object.deinit();
            }

            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(key);

                const cloned_entry_value = try cloneValue(allocator, entry.value_ptr.*);
                errdefer {
                    var cleanup_value = cloned_entry_value;
                    deinitValue(allocator, &cleanup_value);
                }

                try cloned_object.put(key, cloned_entry_value);
            }

            break :blk .{ .object = cloned_object };
        },
    };
}

fn deinitValue(allocator: std.mem.Allocator, value: *std.json.Value) void {
    switch (value.*) {
        .number_string => |text| allocator.free(text),
        .string => |text| allocator.free(text),
        .array => |*array| {
            for (array.items) |*item| {
                deinitValue(allocator, item);
            }
            array.deinit();
        },
        .object => |*object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                deinitValue(allocator, entry.value_ptr);
            }
            object.deinit();
        },
        else => {},
    }
}
