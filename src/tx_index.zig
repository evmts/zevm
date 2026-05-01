const std = @import("std");

pub const TxLocation = struct {
    block_hash: [32]u8,
    block_number: u64,
    transaction_index: u32,
};

pub const TxIndex = struct {
    by_hash: std.AutoHashMap([32]u8, TxLocation),

    pub fn init(allocator: std.mem.Allocator) TxIndex {
        return .{ .by_hash = std.AutoHashMap([32]u8, TxLocation).init(allocator) };
    }

    pub fn deinit(self: *TxIndex) void {
        self.by_hash.deinit();
    }

    pub fn putBlockTransactions(self: *TxIndex, block_hash: [32]u8, block_number: u64, tx_hashes: []const [32]u8) !void {
        for (tx_hashes, 0..) |tx_hash, i| {
            if (i > std.math.maxInt(u32)) return error.TransactionIndexOverflow;
            try self.by_hash.put(tx_hash, .{
                .block_hash = block_hash,
                .block_number = block_number,
                .transaction_index = @intCast(i),
            });
        }
    }

    pub fn getByHash(self: *const TxIndex, tx_hash: [32]u8) ?TxLocation {
        return self.by_hash.get(tx_hash);
    }
};
