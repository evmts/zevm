const std = @import("std");
const primitives = @import("primitives");

pub const ReceiptIndex = struct {
    by_tx: std.AutoHashMap([32]u8, primitives.Receipt.Receipt),
    by_block: std.AutoHashMap([32]u8, []primitives.Receipt.Receipt),

    pub fn init(allocator: std.mem.Allocator) ReceiptIndex {
        return .{
            .by_tx = std.AutoHashMap([32]u8, primitives.Receipt.Receipt).init(allocator),
            .by_block = std.AutoHashMap([32]u8, []primitives.Receipt.Receipt).init(allocator),
        };
    }

    pub fn deinit(self: *ReceiptIndex, allocator: std.mem.Allocator) void {
        var tx_it = self.by_tx.valueIterator();
        while (tx_it.next()) |receipt| {
            receipt.deinit(allocator);
        }
        self.by_tx.deinit();

        var block_it = self.by_block.valueIterator();
        while (block_it.next()) |receipts| {
            allocator.free(receipts.*);
        }
        self.by_block.deinit();
    }

    /// Store receipts for a sealed block. Inserts into both indexes.
    pub fn putBlockReceipts(
        self: *ReceiptIndex,
        allocator: std.mem.Allocator,
        block_hash: [32]u8,
        receipts: []const primitives.Receipt.Receipt,
    ) !void {
        const cloned = try allocator.alloc(primitives.Receipt.Receipt, receipts.len);
        var cloned_count: usize = 0;
        errdefer {
            for (cloned[0..cloned_count]) |receipt| {
                receipt.deinit(allocator);
            }
            allocator.free(cloned);
        }

        for (receipts, 0..) |receipt, i| {
            cloned[i] = try receipt.clone(allocator);
            cloned_count += 1;
        }

        const receipt_count: u32 = std.math.cast(u32, receipts.len) orelse return error.OutOfMemory;
        try self.by_tx.ensureUnusedCapacity(receipt_count);
        try self.by_block.ensureUnusedCapacity(1);

        for (cloned) |receipt| {
            self.by_tx.putAssumeCapacity(receipt.transaction_hash, receipt);
        }
        self.by_block.putAssumeCapacity(block_hash, cloned);
    }

    /// Returns receipt for a tx hash, or null if not found.
    pub fn getByTxHash(
        self: *const ReceiptIndex,
        tx_hash: [32]u8,
    ) ?primitives.Receipt.Receipt {
        return self.by_tx.get(tx_hash);
    }

    /// Returns ordered receipts slice for a block hash.
    /// Returns null if block_hash was never stored (not found).
    pub fn getByBlockHash(
        self: *const ReceiptIndex,
        block_hash: [32]u8,
    ) ?[]const primitives.Receipt.Receipt {
        return self.by_block.get(block_hash);
    }
};
