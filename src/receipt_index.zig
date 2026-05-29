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
    pub fn putBlockReceipts(
        self: *ReceiptIndex,
        allocator: std.mem.Allocator,
        block_hash: [32]u8,
        receipts: []const primitives.Receipt.Receipt,
    ) !void {
        const cloned = try allocator.alloc(primitives.Receipt.Receipt, receipts.len);
        errdefer allocator.free(cloned);

        // Track how many by_tx entries we have successfully inserted so we can roll
        // them back (and free their logs) if a later insertion fails. Without this,
        // a failed putBlockReceipts would leave by_tx populated for a block that was
        // never stored in by_block, an inconsistent index. `cloned_count` tracks how
        // many slots of `cloned` hold a valid (initialized) clone.
        var inserted: usize = 0;
        var cloned_count: usize = 0;
        errdefer {
            // Remove the by_tx entries we inserted during this call, freeing the
            // logs each one owns (the by_tx value and the cloned[j] struct share the
            // same logs pointer, so free exactly once via the map entry).
            var j: usize = 0;
            while (j < inserted) : (j += 1) {
                if (self.by_tx.fetchRemove(cloned[j].transaction_hash)) |kv| {
                    var removed = kv.value;
                    removed.deinit(allocator);
                }
            }
            // Free the logs of any valid clone that was produced but never inserted
            // into by_tx (e.g. the current iteration's clone after a failed put).
            var k: usize = inserted;
            while (k < cloned_count) : (k += 1) {
                cloned[k].deinit(allocator);
            }
        }

        for (receipts, 0..) |receipt, i| {
            cloned[i] = try cloneReceipt(allocator, receipt);
            cloned_count = i + 1;
            // If a prior receipt with this tx hash exists (e.g. a re-org re-seals a
            // block containing an already-indexed tx), free its owned logs before
            // overwriting so they are not leaked.
            if (self.by_tx.fetchRemove(cloned[i].transaction_hash)) |kv| {
                var prior = kv.value;
                prior.deinit(allocator);
            }
            try self.by_tx.put(cloned[i].transaction_hash, cloned[i]);
            inserted = i + 1;
        }

        try self.by_block.put(block_hash, cloned);
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
