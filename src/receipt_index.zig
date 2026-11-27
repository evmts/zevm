const std = @import("std");
const primitives = @import("primitives");

/// Position of a receipt inside the block that owns it.
pub const ReceiptLocator = struct {
    block_hash: [32]u8,
    tx_index: u32,
};

/// Receipt lookup by block hash and by transaction hash.
///
/// `by_block` is the sole owner of every receipt allocation. `by_tx` stores
/// locators only, so the same transaction hash appearing under two blocks
/// (a reorg) can never alias or double-free receipt memory.
pub const ReceiptIndex = struct {
    by_tx: std.AutoHashMap([32]u8, ReceiptLocator),
    by_block: std.AutoHashMap([32]u8, []primitives.Receipt.Receipt),

    pub fn init(allocator: std.mem.Allocator) ReceiptIndex {
        return .{
            .by_tx = std.AutoHashMap([32]u8, ReceiptLocator).init(allocator),
            .by_block = std.AutoHashMap([32]u8, []primitives.Receipt.Receipt).init(allocator),
        };
    }

    /// `by_block` owns every stored receipt and its logs. `by_tx` holds locators
    /// (block hash + tx index) only, so it frees nothing itself.
    pub fn deinit(self: *ReceiptIndex, allocator: std.mem.Allocator) void {
        self.by_tx.deinit();

        var block_it = self.by_block.valueIterator();
        while (block_it.next()) |receipts| {
            freeReceipts(allocator, receipts.*);
        }
        self.by_block.deinit();
    }

    pub fn clone(self: *const ReceiptIndex, allocator: std.mem.Allocator) !ReceiptIndex {
        var cloned = ReceiptIndex.init(allocator);
        errdefer cloned.deinit(allocator);

        try cloned.by_block.ensureTotalCapacity(self.by_block.count());
        var block_it = self.by_block.iterator();
        while (block_it.next()) |entry| {
            const copies = try cloneReceipts(allocator, entry.value_ptr.*);
            cloned.by_block.putAssumeCapacity(entry.key_ptr.*, copies);
        }

        try cloned.by_tx.ensureTotalCapacity(self.by_tx.count());
        var tx_it = self.by_tx.iterator();
        while (tx_it.next()) |entry| {
            cloned.by_tx.putAssumeCapacity(entry.key_ptr.*, entry.value_ptr.*);
        }

        return cloned;
    }

    /// Store receipts for a sealed block. Inserts into both indexes, retiring
    /// any previously stored receipts for the same block hash.
    ///
    /// Failure-atomic: every allocation (receipt clones and hash-map capacity)
    /// happens before the first index mutation, so an allocation error leaves
    /// both indexes exactly as they were.
    pub fn putBlockReceipts(
        self: *ReceiptIndex,
        allocator: std.mem.Allocator,
        block_hash: [32]u8,
        receipts: []const primitives.Receipt.Receipt,
    ) !void {
        const tx_count = std.math.cast(u32, receipts.len) orelse return error.TooManyReceipts;

        const cloned = try cloneReceipts(allocator, receipts);
        errdefer freeReceipts(allocator, cloned);

        try self.by_tx.ensureUnusedCapacity(tx_count);
        try self.by_block.ensureUnusedCapacity(1);

        // Nothing below can fail.
        //
        // Retire any previous receipts stored under this block hash. A
        // transaction locator is removed only when it still points at the
        // retiring block: a locator that a later block took over stays.
        if (self.by_block.fetchRemove(block_hash)) |old_block| {
            for (old_block.value) |old_receipt| {
                if (self.by_tx.get(old_receipt.transaction_hash)) |locator| {
                    if (std.mem.eql(u8, &locator.block_hash, &block_hash)) {
                        _ = self.by_tx.remove(old_receipt.transaction_hash);
                    }
                }
            }
            freeReceipts(allocator, old_block.value);
        }

        for (cloned, 0..) |receipt, i| {
            // The most recently stored block wins a transaction hash shared
            // with another block (a reorg). The earlier block keeps its own
            // receipt, reachable through `getByBlockHash`.
            self.by_tx.putAssumeCapacity(receipt.transaction_hash, .{
                .block_hash = block_hash,
                .tx_index = @intCast(i),
            });
        }
        self.by_block.putAssumeCapacity(block_hash, cloned);
    }

    /// Remove a block's receipts and the tx entries that point at them. Used to
    /// roll back a block whose persistence failed part-way.
    pub fn removeBlockReceipts(self: *ReceiptIndex, allocator: std.mem.Allocator, block_hash: [32]u8) void {
        const removed = self.by_block.fetchRemove(block_hash) orelse return;
        for (removed.value) |old_receipt| {
            if (self.by_tx.get(old_receipt.transaction_hash)) |locator| {
                if (std.mem.eql(u8, &locator.block_hash, &block_hash)) {
                    _ = self.by_tx.remove(old_receipt.transaction_hash);
                }
            }
        }
        freeReceipts(allocator, removed.value);
    }

    /// Returns the block and position holding a tx hash, or null if not found.
    pub fn locateByTxHash(self: *const ReceiptIndex, tx_hash: [32]u8) ?ReceiptLocator {
        return self.by_tx.get(tx_hash);
    }

    /// Returns receipt for a tx hash, or null if not found. The receipt
    /// borrows memory owned by the index.
    pub fn getByTxHash(
        self: *const ReceiptIndex,
        tx_hash: [32]u8,
    ) ?primitives.Receipt.Receipt {
        const locator = self.by_tx.get(tx_hash) orelse return null;
        const receipts = self.by_block.get(locator.block_hash) orelse return null;
        if (locator.tx_index >= receipts.len) return null;
        return receipts[locator.tx_index];
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

fn cloneReceipts(
    allocator: std.mem.Allocator,
    receipts: []const primitives.Receipt.Receipt,
) ![]primitives.Receipt.Receipt {
    const cloned = try allocator.alloc(primitives.Receipt.Receipt, receipts.len);
    var cloned_count: usize = 0;
    errdefer {
        for (cloned[0..cloned_count]) |receipt| receipt.deinit(allocator);
        allocator.free(cloned);
    }
    for (receipts, 0..) |receipt, i| {
        cloned[i] = try cloneReceipt(allocator, receipt);
        cloned_count = i + 1;
    }
    return cloned;
}

fn freeReceipts(allocator: std.mem.Allocator, receipts: []primitives.Receipt.Receipt) void {
    for (receipts) |receipt| receipt.deinit(allocator);
    allocator.free(receipts);
}
fn cloneReceipt(allocator: std.mem.Allocator, receipt: primitives.Receipt.Receipt) !primitives.Receipt.Receipt {
    const logs = try allocator.alloc(primitives.EventLog.EventLog, receipt.logs.len);
    var cloned_logs: usize = 0;
    errdefer {
        for (logs[0..cloned_logs]) |log| {
            deinitEventLog(allocator, log);
        }
        allocator.free(logs);
    }

    for (receipt.logs, 0..) |log, i| {
        logs[i] = try cloneEventLog(allocator, log);
        cloned_logs += 1;
    }

    return .{
        .transaction_hash = receipt.transaction_hash,
        .transaction_index = receipt.transaction_index,
        .block_hash = receipt.block_hash,
        .block_number = receipt.block_number,
        .sender = receipt.sender,
        .to = receipt.to,
        .cumulative_gas_used = receipt.cumulative_gas_used,
        .gas_used = receipt.gas_used,
        .contract_address = receipt.contract_address,
        .logs = logs,
        .logs_bloom = receipt.logs_bloom,
        .status = receipt.status,
        .root = receipt.root,
        .effective_gas_price = receipt.effective_gas_price,
        .type = receipt.type,
        .blob_gas_used = receipt.blob_gas_used,
        .blob_gas_price = receipt.blob_gas_price,
    };
}

fn cloneEventLog(allocator: std.mem.Allocator, log: primitives.EventLog.EventLog) !primitives.EventLog.EventLog {
    const topics = try allocator.dupe([32]u8, log.topics);
    errdefer allocator.free(topics);
    const data = try allocator.dupe(u8, log.data);

    return .{
        .address = log.address,
        .topics = topics,
        .data = data,
        .block_number = log.block_number,
        .transaction_hash = log.transaction_hash,
        .transaction_index = log.transaction_index,
        .log_index = log.log_index,
        .removed = log.removed,
    };
}

fn deinitEventLog(allocator: std.mem.Allocator, log: primitives.EventLog.EventLog) void {
    allocator.free(log.topics);
    allocator.free(log.data);
}
