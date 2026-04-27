const std = @import("std");
const jsonrpc = @import("jsonrpc");
const runtime = @import("../../node/runtime.zig");

pub const BlockSpecError = error{
    BlockOutOfRange,
    InvalidBlockSpec,
};

pub fn resolveBlockNumber(rt: *const runtime.NodeRuntime, block_spec: jsonrpc.types.BlockSpec) BlockSpecError!u64 {
    switch (block_spec.value) {
        .string => |s| {
            if (std.mem.eql(u8, s, "latest") or
                std.mem.eql(u8, s, "pending") or
                std.mem.eql(u8, s, "safe") or
                std.mem.eql(u8, s, "finalized"))
            {
                return rt.head_block_number;
            }
            if (std.mem.eql(u8, s, "earliest")) {
                return 0;
            }
            if (isHashHex(s)) {
                return rt.head_block_number;
            }
            if (isQuantityHex(s)) {
                const num = parseQuantityHex(u64, s) catch return error.InvalidBlockSpec;
                return validateInRange(rt, num);
            }
            return error.InvalidBlockSpec;
        },
        .integer => |n| {
            if (n < 0) return error.InvalidBlockSpec;
            const num: u64 = @intCast(n);
            return validateInRange(rt, num);
        },
        .object => |obj| return resolveBlockObject(rt, obj),
        else => return error.InvalidBlockSpec,
    }
}

fn resolveBlockObject(rt: *const runtime.NodeRuntime, obj: std.json.ObjectMap) BlockSpecError!u64 {
    const block_number = obj.get("blockNumber");
    const block_hash = obj.get("blockHash");

    if (block_number != null and block_hash != null) return error.InvalidBlockSpec;

    if (block_number) |value| {
        const num = switch (value) {
            .string => |s| parseQuantityHex(u64, s) catch return error.InvalidBlockSpec,
            .integer => |n| blk: {
                if (n < 0) return error.InvalidBlockSpec;
                break :blk @as(u64, @intCast(n));
            },
            else => return error.InvalidBlockSpec,
        };
        return validateInRange(rt, num);
    }

    if (block_hash) |value| {
        const hash = switch (value) {
            .string => |s| s,
            else => return error.InvalidBlockSpec,
        };
        if (!isHashHex(hash)) return error.InvalidBlockSpec;
        if (obj.get("requireCanonical")) |canonical| {
            if (canonical != .bool) return error.InvalidBlockSpec;
        }
        return rt.head_block_number;
    }

    return error.InvalidBlockSpec;
}

fn validateInRange(rt: *const runtime.NodeRuntime, num: u64) BlockSpecError!u64 {
    if (num > rt.head_block_number) return error.BlockOutOfRange;
    return num;
}

fn parseQuantityHex(comptime T: type, text: []const u8) !T {
    if (!isQuantityHex(text)) return error.InvalidBlockSpec;
    return std.fmt.parseInt(T, text[2..], 16) catch return error.InvalidBlockSpec;
}

fn isQuantityHex(text: []const u8) bool {
    if (text.len <= 2) return false;
    if (text[0] != '0' or text[1] != 'x') return false;
    if (text.len > 3 and text[2] == '0') return false;
    for (text[2..]) |c| {
        _ = std.fmt.charToDigit(c, 16) catch return false;
    }
    return true;
}

fn isHashHex(text: []const u8) bool {
    if (text.len != 66) return false;
    if (text[0] != '0' or text[1] != 'x') return false;
    for (text[2..]) |c| {
        _ = std.fmt.charToDigit(c, 16) catch return false;
    }
    return true;
}
