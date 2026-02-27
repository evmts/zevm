const std = @import("std");
const jsonrpc = @import("jsonrpc");
const runtime = @import("../../node/runtime.zig");

pub const BlockSpecError = error{
    BlockOutOfRange,
    InvalidBlockSpec,
};

/// Resolve a JSON-RPC BlockSpec to a concrete block number.
/// Supports tags: "latest", "pending", "earliest", "safe", "finalized"
/// and hex-encoded block numbers ("0x0", "0xa", etc.).
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
            // Try to parse as hex quantity (0x-prefixed)
            if (s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
                const num = std.fmt.parseInt(u64, s[2..], 16) catch return error.InvalidBlockSpec;
                if (num > rt.head_block_number) return error.BlockOutOfRange;
                return num;
            }
            return error.InvalidBlockSpec;
        },
        .integer => |n| {
            if (n < 0) return error.InvalidBlockSpec;
            const num: u64 = @intCast(n);
            if (num > rt.head_block_number) return error.BlockOutOfRange;
            return num;
        },
        else => return error.InvalidBlockSpec,
    }
}
