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

    /// `by_block` owns every stored receipt and its logs. `by_tx` holds shallow
    /// copies that alias a `by_block` receipt, so it frees nothing itself.
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

        var block_it = self.by_block.iterator();
        while (block_it.next()) |entry| {
            try cloned.putBlockReceipts(allocator, entry.key_ptr.*, entry.value_ptr.*);
        }

        return cloned;
    }

    /// Store receipts for a sealed block. Inserts into both indexes.
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

        const tx_capacity = std.math.cast(u32, receipts.len) orelse return error.OutOfMemory;
        try self.by_tx.ensureUnusedCapacity(tx_capacity);
        try self.by_block.ensureUnusedCapacity(1);

        // Nothing below can fail.
        if (self.by_block.fetchRemove(block_hash)) |replaced| {
            // Re-storing a block: drop the tx entries that still alias the old
            // receipts before freeing them.
            self.dropTxEntriesAliasing(replaced.value);
            freeReceipts(allocator, replaced.value);
        }
        for (cloned) |receipt| {
            // A tx hash already indexed for another block (a re-org re-seals it)
            // now resolves to this block. The other block keeps its own copy.
            self.by_tx.putAssumeCapacity(receipt.transaction_hash, receipt);
        }
        self.by_block.putAssumeCapacity(block_hash, cloned);
    }

    /// Remove a block's receipts and the tx entries that point at them. Used to
    /// roll back a block whose persistence failed part-way.
    pub fn removeBlockReceipts(self: *ReceiptIndex, allocator: std.mem.Allocator, block_hash: [32]u8) void {
        const removed = self.by_block.fetchRemove(block_hash) orelse return;
        self.dropTxEntriesAliasing(removed.value);
        freeReceipts(allocator, removed.value);
    }

    /// Remove the `by_tx` entries that are shallow copies of `receipts`, leaving
    /// entries that a later block re-pointed at its own receipts.
    fn dropTxEntriesAliasing(self: *ReceiptIndex, receipts: []const primitives.Receipt.Receipt) void {
        for (receipts) |old| {
            const indexed = self.by_tx.get(old.transaction_hash) orelse continue;
            if (indexed.logs.ptr == old.logs.ptr and
                indexed.transaction_index == old.transaction_index and
                std.mem.eql(u8, &indexed.block_hash, &old.block_hash))
            {
                _ = self.by_tx.remove(old.transaction_hash);
            }
        }
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
