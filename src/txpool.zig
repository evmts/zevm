const std = @import("std");
const primitives = @import("primitives");
const tx_encoding = @import("transaction_encoding.zig");

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
    blob_sidecars: []const tx_encoding.BlobSidecar = &.{},
    v: u64 = 0,
    r: [32]u8 = [_]u8{0} ** 32,
    s: [32]u8 = [_]u8{0} ** 32,
};

const SenderNonceKey = struct {
    sender: [20]u8,
    nonce: u64,
};

pub const TransactionPool = struct {
    allocator: std.mem.Allocator,
    transactions: std.ArrayList(PooledTransaction),
    base_nonces: std.AutoHashMapUnmanaged([20]u8, u64),
    sender_nonce_index: std.AutoHashMapUnmanaged(SenderNonceKey, usize),
    hash_index: std.AutoHashMapUnmanaged([32]u8, usize),
    has_duplicate_hashes: bool,

    pub fn init(allocator: std.mem.Allocator) TransactionPool {
        return .{
            .allocator = allocator,
            .transactions = .{},
            .base_nonces = .{},
            .sender_nonce_index = .{},
            .hash_index = .{},
            .has_duplicate_hashes = false,
        };
    }

    pub fn deinit(self: *TransactionPool) void {
        self.clear();
        self.transactions.deinit(self.allocator);
        self.base_nonces.deinit(self.allocator);
        self.sender_nonce_index.deinit(self.allocator);
        self.hash_index.deinit(self.allocator);
    }

    pub fn clear(self: *TransactionPool) void {
        for (self.transactions.items) |tx| {
            self.freeStoredTransaction(tx);
        }
        self.transactions.clearRetainingCapacity();
        self.base_nonces.clearRetainingCapacity();
        self.sender_nonce_index.clearRetainingCapacity();
        self.hash_index.clearRetainingCapacity();
        self.has_duplicate_hashes = false;
    }

    pub fn clone(self: *const TransactionPool, allocator: std.mem.Allocator) !TransactionPool {
        var out = TransactionPool.init(allocator);
        errdefer out.deinit();

        try out.base_nonces.ensureTotalCapacity(allocator, self.base_nonces.count());
        var bn_it = self.base_nonces.iterator();
        while (bn_it.next()) |entry| {
            out.base_nonces.putAssumeCapacity(entry.key_ptr.*, entry.value_ptr.*);
        }

        try out.transactions.ensureTotalCapacity(allocator, self.transactions.items.len);
        try out.sender_nonce_index.ensureTotalCapacity(allocator, @intCast(self.transactions.items.len));
        try out.hash_index.ensureTotalCapacity(allocator, @intCast(self.transactions.items.len));
        out.has_duplicate_hashes = self.has_duplicate_hashes;

        for (self.transactions.items, 0..) |tx, idx| {
            const cloned = try cloneTransaction(allocator, tx);
            errdefer out.freeStoredTransaction(cloned);
            out.transactions.appendAssumeCapacity(cloned);
            out.sender_nonce_index.putAssumeCapacity(.{ .sender = cloned.sender.bytes, .nonce = cloned.nonce }, idx);
            if (!out.hash_index.contains(cloned.hash)) {
                out.hash_index.putAssumeCapacity(cloned.hash, idx);
            }
        }

        return out;
    }

    pub fn setNonce(self: *TransactionPool, sender: primitives.Address, nonce: u64) !void {
        try self.base_nonces.put(self.allocator, sender.bytes, nonce);
    }

    pub fn add(self: *TransactionPool, _: std.mem.Allocator, tx: PooledTransaction) !void {
        const key = SenderNonceKey{ .sender = tx.sender.bytes, .nonce = tx.nonce };
        if (self.sender_nonce_index.get(key)) |index| {
            const existing = self.transactions.items[index];
            if (sameHash(tx.hash, existing.hash)) {
                // Across the Osaka boundary the same signed blob tx may be
                // resubmitted with cell proofs; a bare resubmission preserves
                // existing sidecars.
                if (tx.blob_sidecars.len == 0) return;
                if (existing.blob_sidecars.len != 0 and
                    std.meta.activeTag(tx.blob_sidecars[0].proofs) == std.meta.activeTag(existing.blob_sidecars[0].proofs))
                {
                    return;
                }
            } else if (!isPriceReplacement(existing, tx)) {
                return error.ReplacementUnderpriced;
            }

            const stored = try cloneTransaction(self.allocator, tx);
            errdefer self.freeStoredTransaction(stored);

            if (!sameHash(existing.hash, stored.hash)) {
                if (self.hash_index.get(existing.hash)) |mapped| {
                    if (mapped == index) _ = self.hash_index.remove(existing.hash);
                }
                // Reclaim tombstones in-place before growing so repeated gas-price
                // replacements do not double hash_index capacity unboundedly.
                try ensureMapSlotNoTombstoneGrow([32]u8, &self.hash_index, self.allocator);
                if (self.hash_index.contains(stored.hash)) {
                    self.has_duplicate_hashes = true;
                } else {
                    self.hash_index.putAssumeCapacity(stored.hash, index);
                }
            }

            self.freeStoredTransaction(existing);
            self.transactions.items[index] = stored;
            return;
        }

        const stored = try cloneTransaction(self.allocator, tx);
        errdefer self.freeStoredTransaction(stored);

        try self.transactions.ensureUnusedCapacity(self.allocator, 1);
        try ensureMapSlotNoTombstoneGrow(SenderNonceKey, &self.sender_nonce_index, self.allocator);
        try ensureMapSlotNoTombstoneGrow([32]u8, &self.hash_index, self.allocator);

        const new_index = self.transactions.items.len;
        self.transactions.appendAssumeCapacity(stored);
        self.sender_nonce_index.putAssumeCapacity(key, new_index);
        if (self.hash_index.contains(stored.hash)) {
            self.has_duplicate_hashes = true;
        } else {
            self.hash_index.putAssumeCapacity(stored.hash, new_index);
        }
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
            // Anchor each sender once at its base nonce and walk its contiguous pending chain in O(1)/step.
            if (tx.nonce != self.baseNonce(tx.sender)) continue;
            var next_nonce = tx.nonce;
            while (self.findTransactionIndex(tx.sender, next_nonce) != null) {
                count += 1;
                if (next_nonce == std.math.maxInt(u64)) break;
                next_nonce += 1;
            }
        }
        return count;
    }

    pub fn queuedCount(self: *const TransactionPool) usize {
        return self.transactions.items.len - self.pendingCount();
    }

    /// Returns the next usable nonce for `sender` given the committed `state_nonce`,
    /// i.e. the highest consecutive pending mempool nonce + 1, starting from
    /// `state_nonce`. Used to implement eth_getTransactionCount(addr, "pending"),
    /// which must reflect transactions already accepted into the pool but not yet
    /// mined (Geth/Anvil semantics). Returns `state_nonce` when no contiguous
    /// pending transaction exists for the sender at that nonce.
    pub fn pendingNonce(self: *const TransactionPool, sender: primitives.Address, state_nonce: u64) u64 {
        var next_nonce = state_nonce;
        while (self.findTransactionIndex(sender, next_nonce) != null) {
            if (next_nonce == std.math.maxInt(u64)) return next_nonce;
            next_nonce += 1;
        }
        return next_nonce;
    }

    /// Returns the pending (ready-to-execute) transactions grouped by sender and
    /// ordered by strictly ascending nonce within each sender. The EVM requires a
    /// sender's transactions to execute in ascending nonce order, so the returned
    /// slice must reflect that ordering rather than raw insertion order (otherwise
    /// valid transactions are dropped or the block build fails on a NonceMismatch).
    pub fn getReady(self: *const TransactionPool, allocator: std.mem.Allocator) ![]PooledTransaction {
        const count = self.pendingCount();
        const ready = try allocator.alloc(PooledTransaction, count);
        errdefer allocator.free(ready);

        var index: usize = 0;
        // Walk each distinct sender from its base nonce upward, emitting contiguous
        // pending nonces in order. We anchor senders by the order in which their
        // first pending transaction appears in storage to keep results stable.
        for (self.transactions.items) |tx| {
            if (tx.nonce != self.baseNonce(tx.sender)) continue;

            var next_nonce = tx.nonce;
            while (self.findTransactionIndex(tx.sender, next_nonce)) |tx_index| {
                ready[index] = self.transactions.items[tx_index];
                index += 1;
                if (next_nonce == std.math.maxInt(u64)) break;
                next_nonce += 1;
            }
        }

        std.debug.assert(index == count);
        return ready;
    }

    pub fn removeMined(self: *TransactionPool, hashes: []const [32]u8) void {
        if (hashes.len == 0 or self.transactions.items.len == 0) return;

        if (!self.has_duplicate_hashes) {
            for (hashes) |hash| {
                const idx = self.hash_index.get(hash) orelse continue;
                const tx = self.transactions.items[idx];
                self.advanceSenderNonce(tx.sender, tx.nonce);
                self.removeAtSwap(idx);
            }
            return;
        }

        var index: usize = 0;
        while (index < self.transactions.items.len) {
            const tx = self.transactions.items[index];
            if (!containsHash(hashes, tx.hash)) {
                index += 1;
                continue;
            }
            self.advanceSenderNonce(tx.sender, tx.nonce);
            self.removeAtSwap(index);
        }
    }

    pub fn removeByHash(self: *TransactionPool, hash: [32]u8) bool {
        if (!self.has_duplicate_hashes) {
            const idx = self.hash_index.get(hash) orelse return false;
            self.removeAtSwap(idx);
            return true;
        }

        for (self.transactions.items, 0..) |tx, index| {
            if (!sameHash(tx.hash, hash)) continue;
            self.removeAtSwap(index);
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

    fn removeAtSwap(self: *TransactionPool, index: usize) void {
        const removed = self.transactions.swapRemove(index);
        _ = self.sender_nonce_index.remove(.{ .sender = removed.sender.bytes, .nonce = removed.nonce });
        if (self.hash_index.get(removed.hash)) |mapped| {
            if (mapped == index) _ = self.hash_index.remove(removed.hash);
        }

        if (index < self.transactions.items.len) {
            const moved = self.transactions.items[index];
            self.sender_nonce_index.put(self.allocator, .{ .sender = moved.sender.bytes, .nonce = moved.nonce }, index) catch {};
            if (self.hash_index.getPtr(moved.hash)) |ptr| {
                if (ptr.* == self.transactions.items.len) ptr.* = index;
            }
        }
        self.freeStoredTransaction(removed);
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
        return self.base_nonces.get(sender.bytes) orelse 0;
    }

    fn advanceSenderNonce(self: *TransactionPool, sender: primitives.Address, mined_nonce: u64) void {
        const next_nonce = mined_nonce +| 1;
        if (self.base_nonces.getPtr(sender.bytes)) |ptr| {
            if (next_nonce > ptr.*) ptr.* = next_nonce;
            return;
        }
        self.base_nonces.put(self.allocator, sender.bytes, next_nonce) catch {};
    }

    fn findTransactionIndex(self: *const TransactionPool, sender: primitives.Address, nonce: u64) ?usize {
        return self.sender_nonce_index.get(.{ .sender = sender.bytes, .nonce = nonce });
    }

    fn freeStoredTransaction(self: *TransactionPool, tx: PooledTransaction) void {
        if (tx.input.len > 0) self.allocator.free(tx.input);
        if (tx.raw.len > 0) self.allocator.free(tx.raw);
        if (tx.blob_versioned_hashes.len > 0) self.allocator.free(tx.blob_versioned_hashes);
        if (tx.blob_sidecars.len > 0) self.allocator.free(tx.blob_sidecars);
    }
};

fn ensureMapSlotNoTombstoneGrow(
    comptime K: type,
    map: *std.AutoHashMapUnmanaged(K, usize),
    allocator: std.mem.Allocator,
) !void {
    if (map.capacity() > 0 and map.available == 0 and @as(usize, map.count()) * 2 < @as(usize, map.capacity())) {
        map.rehash(std.hash_map.AutoContext(K){});
        if (map.available >= 1) return;
    }
    try map.ensureUnusedCapacity(allocator, 1);
}

fn cloneTransaction(
    allocator: std.mem.Allocator,
    tx: PooledTransaction,
) !PooledTransaction {
    var cloned = tx;
    cloned.input = if (tx.input.len > 0) try allocator.dupe(u8, tx.input) else &.{};
    errdefer if (cloned.input.len > 0) allocator.free(cloned.input);
    cloned.raw = if (tx.raw.len > 0) try allocator.dupe(u8, tx.raw) else &.{};
    errdefer if (cloned.raw.len > 0) allocator.free(cloned.raw);
    cloned.blob_versioned_hashes = if (tx.blob_versioned_hashes.len > 0) try allocator.dupe([32]u8, tx.blob_versioned_hashes) else &.{};
    errdefer if (cloned.blob_versioned_hashes.len > 0) allocator.free(cloned.blob_versioned_hashes);
    cloned.blob_sidecars = if (tx.blob_sidecars.len > 0) try allocator.dupe(tx_encoding.BlobSidecar, tx.blob_sidecars) else &.{};
    errdefer if (cloned.blob_sidecars.len > 0) allocator.free(cloned.blob_sidecars);
    return cloned;
}

/// Returns true if `replacement` is allowed to evict `existing` (same sender/nonce)
/// under replacement-underpriced policy: the fee cap and the priority fee (and, for
/// blob txs, the blob fee cap) must each STRICTLY increase. Previously only
/// `max_fee_per_gas` was compared, which let a replacement raise the fee cap while
/// silently lowering the priority fee (or, for a blob tx, the blob fee cap). A
/// strict increase on every fee field ensures no field regresses; a positive bump of
/// any size is accepted (matching this client's existing dev replacement semantics).
fn isPriceReplacement(existing: PooledTransaction, replacement: PooledTransaction) bool {
    if (replacement.max_fee_per_gas <= existing.max_fee_per_gas) return false;
    if (replacement.max_priority_fee_per_gas <= existing.max_priority_fee_per_gas) return false;

    // For blob (EIP-4844) transactions the blob fee cap must also be bumped.
    if (existing.max_fee_per_blob_gas) |existing_blob_fee| {
        const replacement_blob_fee = replacement.max_fee_per_blob_gas orelse return false;
        if (replacement_blob_fee <= existing_blob_fee) return false;
    }

    return true;
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

const testing = std.testing;

fn testTx(sender: primitives.Address, nonce: u64, hash_byte: u8, max_fee: u256, max_priority: u256) PooledTransaction {
    return .{
        .sender = sender,
        .nonce = nonce,
        .gas_limit = 21000,
        .max_fee_per_gas = max_fee,
        .max_priority_fee_per_gas = max_priority,
        .hash = [_]u8{hash_byte} ** 32,
    };
}

test "txpool getReady orders pending txs by ascending nonce per sender" {
    // Regression for finding #4: getReady must emit a sender's transactions in
    // ascending nonce order even when the higher nonce was submitted first.
    const allocator = testing.allocator;
    var pool = TransactionPool.init(allocator);
    defer pool.deinit();

    const sender = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0} ** 19 };

    // Submit nonce=1 first (queued), then nonce=0. Both become pending once nonce=0
    // exists, and storage order is [nonce1, nonce0].
    try pool.add(allocator, testTx(sender, 1, 0xb1, 100, 1));
    try pool.add(allocator, testTx(sender, 0, 0xb0, 100, 1));

    const ready = try pool.getReady(allocator);
    defer allocator.free(ready);

    try testing.expectEqual(@as(usize, 2), ready.len);
    try testing.expectEqual(@as(u64, 0), ready[0].nonce);
    try testing.expectEqual(@as(u64, 1), ready[1].nonce);
}

test "txpool getReady groups multiple senders each in nonce order" {
    const allocator = testing.allocator;
    var pool = TransactionPool.init(allocator);
    defer pool.deinit();

    const a = primitives.Address{ .bytes = [_]u8{0x0a} ++ [_]u8{0} ** 19 };
    const b = primitives.Address{ .bytes = [_]u8{0x0b} ++ [_]u8{0} ** 19 };

    // Interleaved, out-of-nonce submission across two senders.
    try pool.add(allocator, testTx(a, 1, 0xa1, 100, 1));
    try pool.add(allocator, testTx(b, 1, 0xb1, 100, 1));
    try pool.add(allocator, testTx(a, 0, 0xa0, 100, 1));
    try pool.add(allocator, testTx(b, 0, 0xb0, 100, 1));

    const ready = try pool.getReady(allocator);
    defer allocator.free(ready);

    try testing.expectEqual(@as(usize, 4), ready.len);
    // Each sender's two txs must appear in ascending nonce order; senders may be in
    // any group order, so verify per-sender contiguity and ordering.
    var seen_a_nonce: ?u64 = null;
    var seen_b_nonce: ?u64 = null;
    for (ready) |tx| {
        if (sameAddress(tx.sender, a)) {
            if (seen_a_nonce) |prev| try testing.expect(tx.nonce > prev);
            seen_a_nonce = tx.nonce;
        } else {
            if (seen_b_nonce) |prev| try testing.expect(tx.nonce > prev);
            seen_b_nonce = tx.nonce;
        }
    }
    try testing.expectEqual(@as(?u64, 1), seen_a_nonce);
    try testing.expectEqual(@as(?u64, 1), seen_b_nonce);
}

test "txpool replacement requires bump on both fee cap and priority fee" {
    // Regression for finding #31: a replacement must not pay a lower tip nor be a
    // sub-bump nudge. Existing tx: cap=100, tip=50.
    const allocator = testing.allocator;
    var pool = TransactionPool.init(allocator);
    defer pool.deinit();

    const sender = primitives.Address{ .bytes = [_]u8{0x07} ++ [_]u8{0} ** 19 };
    try pool.add(allocator, testTx(sender, 0, 0x01, 100, 50));

    // Cap nudged up by 1 wei but tip slashed to 1: must be rejected.
    try testing.expectError(error.ReplacementUnderpriced, pool.add(allocator, testTx(sender, 0, 0x02, 101, 1)));

    // Cap bumped >=10% but tip unchanged (no tip bump): must be rejected.
    try testing.expectError(error.ReplacementUnderpriced, pool.add(allocator, testTx(sender, 0, 0x03, 110, 50)));

    // Both bumped by >=10%: accepted.
    try pool.add(allocator, testTx(sender, 0, 0x04, 110, 55));
    const stored = pool.items()[0];
    try testing.expectEqual(@as(u256, 110), stored.max_fee_per_gas);
    try testing.expectEqual(@as(u256, 55), stored.max_priority_fee_per_gas);
}

test "txpool replacement of blob tx requires blob fee bump" {
    const allocator = testing.allocator;
    var pool = TransactionPool.init(allocator);
    defer pool.deinit();

    const sender = primitives.Address{ .bytes = [_]u8{0x08} ++ [_]u8{0} ** 19 };
    var blob_tx = testTx(sender, 0, 0x01, 100, 50);
    blob_tx.max_fee_per_blob_gas = 100;
    try pool.add(allocator, blob_tx);

    // Cap and tip bumped enough, but blob fee not bumped: rejected.
    var replacement = testTx(sender, 0, 0x02, 110, 55);
    replacement.max_fee_per_blob_gas = 100;
    try testing.expectError(error.ReplacementUnderpriced, pool.add(allocator, replacement));

    // All three bumped: accepted.
    replacement.hash = [_]u8{0x03} ** 32;
    replacement.max_fee_per_blob_gas = 110;
    try pool.add(allocator, replacement);
}
