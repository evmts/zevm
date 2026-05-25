const std = @import("std");
const primitives = @import("primitives");

pub const EntryStatus = enum {
    pending,
    queued,
};

pub const PooledTransaction = struct {
    sender: primitives.Address,
    nonce: u64,
    gas_limit: u64,
    max_fee_per_gas: u256,
    max_priority_fee_per_gas: u256 = 0,
    max_fee_per_blob_gas: ?u256 = null,
    receipt_type: primitives.Receipt.TransactionType = .legacy,
    hash: [32]u8,
    to: ?primitives.Address = null,
    value: u256 = 0,
    input: []const u8 = &.{},
    raw: []const u8 = &.{},
    blob_versioned_hashes: []const [32]u8 = &.{},
    blob_sidecars: []const primitives.Blob.BlobSidecar = &.{},
    v: u64 = 0,
    r: [32]u8 = [_]u8{0} ** 32,
    s: [32]u8 = [_]u8{0} ** 32,
};

const SenderNonce = struct {
    sender: primitives.Address,
    nonce: u64,
};

pub const TransactionPool = struct {
    allocator: std.mem.Allocator,
    transactions: std.ArrayList(PooledTransaction),
    sender_nonces: std.ArrayList(SenderNonce),

    pub fn init(allocator: std.mem.Allocator) TransactionPool {
        return .{
            .allocator = allocator,
            .transactions = .{},
            .sender_nonces = .{},
        };
    }

    pub fn deinit(self: *TransactionPool) void {
        self.clear();
        self.transactions.deinit(self.allocator);
        self.sender_nonces.deinit(self.allocator);
    }

    pub fn clear(self: *TransactionPool) void {
        for (self.transactions.items) |tx| {
            self.freeStoredTransaction(tx);
        }
        self.transactions.clearRetainingCapacity();
        self.sender_nonces.clearRetainingCapacity();
    }

    pub fn clone(self: *const TransactionPool, allocator: std.mem.Allocator) !TransactionPool {
        var out = TransactionPool.init(allocator);
        errdefer out.deinit();

        for (self.sender_nonces.items) |entry| {
            try out.sender_nonces.append(allocator, entry);
        }

        for (self.transactions.items) |tx| {
            const cloned = try cloneTransaction(allocator, tx);
            try out.transactions.append(allocator, cloned);
        }

        return out;
    }

    pub fn setNonce(self: *TransactionPool, sender: primitives.Address, nonce: u64) !void {
        if (self.findSenderNonceIndex(sender)) |index| {
            self.sender_nonces.items[index].nonce = nonce;
            return;
        }
        try self.sender_nonces.append(self.allocator, .{
            .sender = sender,
            .nonce = nonce,
        });
    }

    pub fn add(self: *TransactionPool, _: std.mem.Allocator, tx: PooledTransaction) !void {
        if (self.findTransactionIndex(tx.sender, tx.nonce)) |index| {
            if (sameHash(tx.hash, self.transactions.items[index].hash)) {
                return;
            }
            if (tx.max_fee_per_gas <= self.transactions.items[index].max_fee_per_gas) {
                return error.ReplacementUnderpriced;
            }

            const stored = try cloneTransaction(self.allocator, tx);
            self.freeStoredTransaction(self.transactions.items[index]);
            self.transactions.items[index] = stored;
            return;
        }

        const stored = try cloneTransaction(self.allocator, tx);
        try self.transactions.append(self.allocator, stored);
    }

    pub fn items(self: *const TransactionPool) []const PooledTransaction {
        return self.transactions.items;
    }

    pub fn statusOf(self: *const TransactionPool, sender: primitives.Address, nonce: u64) EntryStatus {
        return if (self.isPending(sender, nonce)) .pending else .queued;
    }

    pub fn pendingCount(self: *const TransactionPool) usize {
        var count: usize = 0;
        for (self.transactions.items) |tx| {
            if (self.isPending(tx.sender, tx.nonce)) count += 1;
        }
        return count;
    }

    pub fn queuedCount(self: *const TransactionPool) usize {
        return self.transactions.items.len - self.pendingCount();
    }

    pub fn getReady(self: *const TransactionPool, allocator: std.mem.Allocator) ![]PooledTransaction {
        const count = self.pendingCount();
        const ready = try allocator.alloc(PooledTransaction, count);
        var index: usize = 0;
        for (self.transactions.items) |tx| {
            if (!self.isPending(tx.sender, tx.nonce)) continue;
            ready[index] = tx;
            index += 1;
        }
        return ready;
    }

    pub fn removeMined(self: *TransactionPool, hashes: []const [32]u8) void {
        var index: usize = 0;
        while (index < self.transactions.items.len) {
            const tx = self.transactions.items[index];
            if (!containsHash(hashes, tx.hash)) {
                index += 1;
                continue;
            }

            self.advanceSenderNonce(tx.sender, tx.nonce);
            self.freeStoredTransaction(tx);
            _ = self.transactions.orderedRemove(index);
        }
    }

    pub fn removeByHash(self: *TransactionPool, hash: [32]u8) bool {
        var index: usize = 0;
        while (index < self.transactions.items.len) : (index += 1) {
            const tx = self.transactions.items[index];
            if (!sameHash(tx.hash, hash)) continue;

            self.freeStoredTransaction(tx);
            _ = self.transactions.orderedRemove(index);
            return true;
        }
        return false;
    }

    pub fn removeManyByHash(self: *TransactionPool, hashes: []const [32]u8) usize {
        var removed: usize = 0;
        for (hashes) |hash| {
            if (self.removeByHash(hash)) removed += 1;
        }
        return removed;
    }

    fn isPending(self: *const TransactionPool, sender: primitives.Address, nonce: u64) bool {
        var next_nonce = self.baseNonce(sender);
        while (next_nonce <= nonce) : (next_nonce += 1) {
            if (self.findTransactionIndex(sender, next_nonce) == null) return false;
            if (next_nonce == nonce) return true;
            if (next_nonce == std.math.maxInt(u64)) return false;
        }
        return false;
    }

    fn baseNonce(self: *const TransactionPool, sender: primitives.Address) u64 {
        if (self.findSenderNonceIndex(sender)) |index| {
            return self.sender_nonces.items[index].nonce;
        }
        return 0;
    }

    fn advanceSenderNonce(self: *TransactionPool, sender: primitives.Address, mined_nonce: u64) void {
        const next_nonce = mined_nonce +| 1;
        if (self.findSenderNonceIndex(sender)) |index| {
            if (next_nonce > self.sender_nonces.items[index].nonce) {
                self.sender_nonces.items[index].nonce = next_nonce;
            }
            return;
        }
        self.sender_nonces.append(self.allocator, .{
            .sender = sender,
            .nonce = next_nonce,
        }) catch {};
    }

    fn findSenderNonceIndex(self: *const TransactionPool, sender: primitives.Address) ?usize {
        for (self.sender_nonces.items, 0..) |entry, index| {
            if (sameAddress(entry.sender, sender)) return index;
        }
        return null;
    }

    fn findTransactionIndex(self: *const TransactionPool, sender: primitives.Address, nonce: u64) ?usize {
        for (self.transactions.items, 0..) |tx, index| {
            if (tx.nonce == nonce and sameAddress(tx.sender, sender)) return index;
        }
        return null;
    }

    fn freeStoredTransaction(self: *TransactionPool, tx: PooledTransaction) void {
        if (tx.input.len > 0) self.allocator.free(tx.input);
        if (tx.raw.len > 0) self.allocator.free(tx.raw);
        if (tx.blob_versioned_hashes.len > 0) self.allocator.free(tx.blob_versioned_hashes);
        if (tx.blob_sidecars.len > 0) self.allocator.free(tx.blob_sidecars);
    }
};

fn cloneTransaction(
    allocator: std.mem.Allocator,
    tx: PooledTransaction,
) !PooledTransaction {
    var cloned = tx;
    cloned.input = try allocator.dupe(u8, tx.input);
    errdefer allocator.free(cloned.input);
    cloned.raw = try allocator.dupe(u8, tx.raw);
    errdefer allocator.free(cloned.raw);
    cloned.blob_versioned_hashes = try allocator.dupe([32]u8, tx.blob_versioned_hashes);
    errdefer allocator.free(cloned.blob_versioned_hashes);
    cloned.blob_sidecars = try allocator.dupe(primitives.Blob.BlobSidecar, tx.blob_sidecars);
    errdefer allocator.free(cloned.blob_sidecars);
    return cloned;
}

fn containsHash(hashes: []const [32]u8, hash: [32]u8) bool {
    for (hashes) |candidate| {
        if (sameHash(candidate, hash)) return true;
    }
    return false;
}

fn sameHash(a: [32]u8, b: [32]u8) bool {
    return std.mem.eql(u8, &a, &b);
}

fn sameAddress(a: primitives.Address, b: primitives.Address) bool {
    return std.mem.eql(u8, &a.bytes, &b.bytes);
}
