const std = @import("std");
const jsonrpc = @import("jsonrpc");
const runtime = @import("../../node/runtime.zig");
const rpc_parse = @import("../parse.zig");

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
            if (isQuantityHex(s)) {
                const num = parseQuantityHex(u64, s) catch return error.InvalidBlockSpec;
                return validateInRange(rt, num);
            }
            return error.InvalidBlockSpec;
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
        return error.InvalidBlockSpec;
    }

    return error.InvalidBlockSpec;
}

fn validateInRange(rt: *const runtime.NodeRuntime, num: u64) BlockSpecError!u64 {
    if (num > rt.head_block_number) return error.BlockOutOfRange;
    return num;
}

fn parseQuantityHex(comptime T: type, text: []const u8) !T {
    return rpc_parse.parseQuantityString(T, text) catch return error.InvalidBlockSpec;
}

fn isQuantityHex(text: []const u8) bool {
    return rpc_parse.isQuantityHex(text);
}

fn isHashHex(text: []const u8) bool {
    return rpc_parse.isHash32(text);
}
