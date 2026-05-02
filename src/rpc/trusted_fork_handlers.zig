const std = @import("std");
const runtime = @import("../node/runtime.zig");
const rpc_parse = @import("parse.zig");

pub fn handleZevmReset(
    rt: *runtime.NodeRuntime,
    params: ?std.json.Value,
) !std.json.Value {
    const reset_mode = parseResetMode(params) orelse return error.InvalidParams;
    rt.reset(reset_mode) catch |err| switch (err) {
        error.InvalidForkUrl => return error.InvalidParams,
        else => return err,
    };
    return .{ .bool = true };
}

pub fn handleZevmSetRpcUrl(
    allocator: std.mem.Allocator,
    rt: *runtime.NodeRuntime,
    params: ?std.json.Value,
) !std.json.Value {
    _ = allocator;
    const url = parseSetRpcUrl(params) orelse return error.InvalidParams;
    rt.setRpcUrl(url) catch |err| switch (err) {
        error.InvalidForkUrl => return error.InvalidParams,
        else => return err,
    };
    return .{ .bool = true };
}

fn parseResetMode(params: ?std.json.Value) ?runtime.ResetForkMode {
    if (params == null) return .keep_current;
    const items = getParamsArray(params) orelse return null;

    if (items.len == 0) return .keep_current;
    if (items.len != 1) return null;

    return switch (items[0]) {
        .null => .disable,
        .object => |obj| blk: {
            const url = switch (obj.get("url") orelse return null) {
                .string => |value| value,
                else => return null,
            };

            var block_number: ?u64 = null;
            if (obj.get("blockNumber")) |block_value| {
                block_number = parseQuantityHexU64(block_value) orelse return null;
            }

            // Enforce exact object forms from contract.
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (!std.mem.eql(u8, entry.key_ptr.*, "url") and !std.mem.eql(u8, entry.key_ptr.*, "blockNumber")) {
                    return null;
                }
            }

            break :blk .{ .replace = .{
                .url = url,
                .block_number = block_number,
            } };
        },
        else => null,
    };
}

fn parseSetRpcUrl(params: ?std.json.Value) ?[]const u8 {
    const items = getParamsArray(params) orelse return null;
    if (items.len != 1) return null;
    return switch (items[0]) {
        .string => |value| value,
        else => null,
    };
}

fn getParamsArray(params: ?std.json.Value) ?[]const std.json.Value {
    const value = params orelse return null;
    return switch (value) {
        .array => |array| array.items,
        else => null,
    };
}

fn parseQuantityHexU64(value: std.json.Value) ?u64 {
    return rpc_parse.parseQuantityValue(u64, value) catch null;
}

fn isQuantityHex(text: []const u8) bool {
    return rpc_parse.isQuantityHex(text);
}

test "handleZevmReset with omitted params keeps fork configuration and invalidates snapshots" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{
        .fork_url = "https://rpc-a.example",
        .fork_block_number = 42,
    });
    defer rt.deinit();

    const snapshot_id = try rt.snapshot();

    const result = try handleZevmReset(&rt, null);
    try std.testing.expect(result.bool);
    try std.testing.expect(rt.isForkingEnabled());
    try std.testing.expectEqualStrings("https://rpc-a.example", rt.fork_config.?.url);
    try std.testing.expectEqual(@as(?u64, 42), rt.fork_config.?.block_number);

    const reverted = try rt.revertToSnapshot(snapshot_id);
    try std.testing.expect(!reverted);
}

test "handleZevmReset with [null] disables fork backing" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{
        .fork_url = "https://rpc-a.example",
    });
    defer rt.deinit();

    var args = std.json.Array.init(std.testing.allocator);
    defer args.deinit();
    try args.append(.null);

    const result = try handleZevmReset(&rt, .{ .array = args });
    try std.testing.expect(result.bool);
    try std.testing.expect(!rt.isForkingEnabled());
}

test "handleZevmReset with fork object replaces fork URL and block" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{
        .fork_url = "https://rpc-a.example",
    });
    defer rt.deinit();

    var cfg_obj = std.json.ObjectMap.init(std.testing.allocator);
    defer cfg_obj.deinit();
    try cfg_obj.put("url", .{ .string = "https://rpc-b.example" });
    try cfg_obj.put("blockNumber", .{ .string = "0x2a" });

    var args = std.json.Array.init(std.testing.allocator);
    defer args.deinit();
    try args.append(.{ .object = cfg_obj });

    const result = try handleZevmReset(&rt, .{ .array = args });
    try std.testing.expect(result.bool);
    try std.testing.expectEqualStrings("https://rpc-b.example", rt.fork_config.?.url);
    try std.testing.expectEqual(@as(?u64, 42), rt.fork_config.?.block_number);
}

test "handleZevmReset rejects non-minimal fork block number" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{
        .fork_url = "https://rpc-a.example",
    });
    defer rt.deinit();

    var cfg_obj = std.json.ObjectMap.init(std.testing.allocator);
    defer cfg_obj.deinit();
    try cfg_obj.put("url", .{ .string = "https://rpc-b.example" });
    try cfg_obj.put("blockNumber", .{ .string = "0x02" });

    var args = std.json.Array.init(std.testing.allocator);
    defer args.deinit();
    try args.append(.{ .object = cfg_obj });

    try std.testing.expectError(error.InvalidParams, handleZevmReset(&rt, .{ .array = args }));
}

test "handleZevmSetRpcUrl updates active fork URL" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{
        .fork_url = "https://rpc-a.example",
        .fork_block_number = 99,
    });
    defer rt.deinit();

    var args = std.json.Array.init(std.testing.allocator);
    defer args.deinit();
    try args.append(.{ .string = "https://rpc-b.example" });

    const result = try handleZevmSetRpcUrl(std.testing.allocator, &rt, .{ .array = args });
    try std.testing.expect(result.bool);
    try std.testing.expectEqualStrings("https://rpc-b.example", rt.fork_config.?.url);
    try std.testing.expectEqual(@as(?u64, 99), rt.fork_config.?.block_number);
}

test "handleZevmSetRpcUrl rejects malformed URL as invalid params" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, .{
        .fork_url = "https://rpc-a.example",
    });
    defer rt.deinit();

    var args = std.json.Array.init(std.testing.allocator);
    defer args.deinit();
    try args.append(.{ .string = "ftp://rpc-b.example" });

    try std.testing.expectError(error.InvalidParams, handleZevmSetRpcUrl(std.testing.allocator, &rt, .{ .array = args }));
}

test "handleZevmSetRpcUrl fails when forking is disabled" {
    var rt = try runtime.NodeRuntime.init(std.testing.allocator, null);
    defer rt.deinit();

    var args = std.json.Array.init(std.testing.allocator);
    defer args.deinit();
    try args.append(.{ .string = "https://rpc-b.example" });

    try std.testing.expectError(
        error.ForkNotEnabled,
        handleZevmSetRpcUrl(std.testing.allocator, &rt, .{ .array = args }),
    );
}
