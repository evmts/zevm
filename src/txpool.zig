const std = @import("std");
const primitives = @import("primitives");
const tx_encoding = @import("transaction_encoding.zig");

/// Maximum number of transactions the pool stores.
pub const MAX_POOL_TXS: usize = 4096;
/// Maximum bytes the pool stores, counting raw envelopes, calldata copies,
/// blob versioned hashes, and blob sidecars.
pub const MAX_POOL_BYTES: usize = 64 * 1024 * 1024;
/// Maximum number of transactions one sender may hold in the pool.
pub const MAX_PER_SENDER: usize = 64;
/// Maximum distance between a transaction's nonce and its sender's base nonce.
pub const MAX_NONCE_GAP: u64 = 64;
/// Minimum fee bump, in percent, for a replacement transaction.
pub const REPLACEMENT_BUMP_PERCENT: u256 = 10;
/// Minimum fee bump, in percent, for a replacement blob transaction.
pub const BLOB_REPLACEMENT_BUMP_PERCENT: u256 = 100;

pub const AddError = error{
    /// The replacement does not raise every fee by the required bump, or it
    /// switches between a blob and a non-blob transaction.
    ReplacementUnderpriced,
    /// The pool holds `MAX_POOL_TXS` transactions or `MAX_POOL_BYTES` bytes.
    TxPoolFull,
    /// The sender already holds `MAX_PER_SENDER` transactions.
    SenderLimitExceeded,
    /// The nonce is more than `MAX_NONCE_GAP` above the sender's base nonce.
    NonceGapTooLarge,
    OutOfMemory,
};

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

/// A sender's next executable nonce as the pool knows it.
const BaseNonce = struct {
    nonce: u64,
    /// True when the entry was created by `setNonce` or `add`, whose callers
    /// rely on the pool to remember the nonce between transactions. False
    /// when it was created by `addWithBaseNonce`, whose caller supplies the
    /// nonce on every insert; such an entry is dropped with the sender's last
    /// pooled transaction so it cannot outlive the transactions it describes.
    retained: bool,
};

pub const TransactionPool = struct {
    allocator: std.mem.Allocator,
    transactions: std.ArrayList(PooledTransaction),
    base_nonces: std.AutoHashMapUnmanaged([20]u8, BaseNonce),
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

    /// Records `nonce` as the sender's base nonce and keeps the entry until
    /// `clear`. The entry is allocated whether or not the sender has pooled
    /// transactions, so never call this for an unauthenticated submission;
    /// use `addWithBaseNonce` there.
    pub fn setNonce(self: *TransactionPool, sender: primitives.Address, nonce: u64) !void {
        try self.base_nonces.put(self.allocator, sender.bytes, .{ .nonce = nonce, .retained = true });
    }

    /// Adds `tx` using the base nonce the pool already holds for its sender
    /// (zero for an unknown sender).
    pub fn add(self: *TransactionPool, _: std.mem.Allocator, tx: PooledTransaction) AddError!void {
        return self.insert(tx, null);
    }

    /// Adds `tx` for a sender whose next executable nonce is `base_nonce`.
    /// A rejected transaction allocates nothing and leaves no per-sender
    /// state behind. The base-nonce entry this creates is removed together
    /// with the sender's last pooled transaction.
    pub fn addWithBaseNonce(self: *TransactionPool, tx: PooledTransaction, base_nonce: u64) AddError!void {
        return self.insert(tx, base_nonce);
    }

    fn insert(self: *TransactionPool, tx: PooledTransaction, caller_base_nonce: ?u64) AddError!void {
        const key = SenderNonceKey{ .sender = tx.sender.bytes, .nonce = tx.nonce };
        const new_bytes = storedBytes(tx);
        if (self.sender_nonce_index.get(key)) |index| {
            // The sender already has a pooled transaction, so its entry
            // exists and refreshing it cannot allocate.
            if (caller_base_nonce) |nonce| {
                if (self.base_nonces.getPtr(tx.sender.bytes)) |entry| entry.nonce = nonce;
            }
            const existing = self.transactions.items[index];
            if (sameHash(tx.hash, existing.hash)) {
                // Across the Osaka boundary the same signed blob tx may be
                // resubmitted with cell proofs; a bare resubmission preserves
                // existing sidecars.
                if (tx.blob_sidecars.len == 0) return;
                if (existing.blob_sidecars.len != 0 and
                    std.meta.activeTag(tx.blob_sidecars[0].proofs) ==
                        std.meta.activeTag(existing.blob_sidecars[0].proofs))
                {
                    return;
                }
            } else if (!isPriceReplacement(existing, tx)) {
                return error.ReplacementUnderpriced;
            }

            const usage = self.usageFor(tx.sender);
            if (usage.bytes - storedBytes(existing) + new_bytes > MAX_POOL_BYTES) return error.TxPoolFull;

            const stored = try cloneTransaction(self.allocator, tx);
            errdefer self.freeStoredTransaction(stored);

            if (!sameHash(existing.hash, stored.hash)) {
                // Reclaim tombstones in-place before growing so repeated gas-price
                // replacements do not double hash_index capacity unboundedly.
                // Reserve before unlinking the old hash so a failed reservation
                // leaves the existing entry indexed.
                try ensureMapSlotNoTombstoneGrow([32]u8, usize, &self.hash_index, self.allocator);
                if (self.hash_index.get(existing.hash)) |mapped| {
                    if (mapped == index) _ = self.hash_index.remove(existing.hash);
                }
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

        const base_nonce = caller_base_nonce orelse self.baseNonce(tx.sender);
        if (tx.nonce > base_nonce and tx.nonce - base_nonce > MAX_NONCE_GAP) return error.NonceGapTooLarge;
        if (self.transactions.items.len >= MAX_POOL_TXS) return error.TxPoolFull;
        const usage = self.usageFor(tx.sender);
        if (usage.sender_txs >= MAX_PER_SENDER) return error.SenderLimitExceeded;
        if (usage.bytes + new_bytes > MAX_POOL_BYTES) return error.TxPoolFull;

        const stored = try cloneTransaction(self.allocator, tx);
        errdefer self.freeStoredTransaction(stored);

        try self.transactions.ensureUnusedCapacity(self.allocator, 1);
        try ensureMapSlotNoTombstoneGrow(SenderNonceKey, usize, &self.sender_nonce_index, self.allocator);
        try ensureMapSlotNoTombstoneGrow([32]u8, usize, &self.hash_index, self.allocator);
        // Every pooled sender owns a base-nonce entry, so advancing the base
        // nonce when a transaction is mined never allocates and cannot fail.
        // Only capacity is reserved here: the entry is written below, after
        // the last fallible step, so a rejected transaction creates none.
        const tracked = self.base_nonces.getPtr(tx.sender.bytes);
        if (tracked == null) try ensureMapSlotNoTombstoneGrow([20]u8, BaseNonce, &self.base_nonces, self.allocator);

        if (tracked) |entry| {
            if (caller_base_nonce) |nonce| entry.nonce = nonce;
        } else {
            self.base_nonces.putAssumeCapacity(tx.sender.bytes, .{
                .nonce = caller_base_nonce orelse 0,
                .retained = caller_base_nonce == null,
            });
        }

        const new_index = self.transactions.items.len;
        self.transactions.appendAssumeCapacity(stored);
        self.sender_nonce_index.putAssumeCapacity(key, new_index);
        if (self.hash_index.contains(stored.hash)) {
            self.has_duplicate_hashes = true;
        } else {
            self.hash_index.putAssumeCapacity(stored.hash, new_index);
        }
    }

    const Usage = struct {
        bytes: usize,
        sender_txs: usize,
    };

    /// Bytes stored by the whole pool and the number of transactions `sender`
    /// holds. One pass over at most `MAX_POOL_TXS` entries.
    fn usageFor(self: *const TransactionPool, sender: primitives.Address) Usage {
        var out = Usage{ .bytes = 0, .sender_txs = 0 };
        for (self.transactions.items) |tx| {
            out.bytes += storedBytes(tx);
            if (sameAddress(tx.sender, sender)) out.sender_txs += 1;
        }
        return out;
    }

    /// Bytes the pool stores for all transactions.
    pub fn totalBytes(self: *const TransactionPool) usize {
        var bytes: usize = 0;
        for (self.transactions.items) |tx| bytes += storedBytes(tx);
        return bytes;
    }

    pub fn items(self: *const TransactionPool) []const PooledTransaction {
        return self.transactions.items;
    }

    pub fn statusOf(self: *const TransactionPool, sender: primitives.Address, nonce: u64) EntryStatus {
        return if (self.isPending(sender, nonce)) .pending else .queued;
    }

    /// Contiguous run of executable nonces for one sender.
    pub const ReadyRange = struct {
        /// The sender's base nonce.
        start: u64,
        /// Number of pooled transactions at `start`, `start + 1`, ...
        count: u64,

        pub fn contains(self: ReadyRange, nonce: u64) bool {
            return nonce >= self.start and nonce - self.start < self.count;
        }
    };

    /// Returns the sender's pending nonce range. Costs one index lookup per
    /// pending transaction, so a caller that classifies every pooled
    /// transaction computes this once per sender instead of calling
    /// `statusOf` per transaction.
    pub fn readyRange(self: *const TransactionPool, sender: primitives.Address) ReadyRange {
        const start = self.baseNonce(sender);
        var count: u64 = 0;
        var next_nonce = start;
        while (self.findTransactionIndex(sender, next_nonce) != null) {
            count += 1;
            if (next_nonce == std.math.maxInt(u64)) break;
            next_nonce += 1;
        }
        return .{ .start = start, .count = count };
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

    pub fn pruneBelowNonce(self: *TransactionPool, sender: primitives.Address, state_nonce: u64) void {
        const entry = self.base_nonces.getPtr(sender.bytes) orelse return;
        if (state_nonce <= entry.nonce) return;
        entry.nonce = state_nonce;
        self.evictStale();
    }

    pub fn revalidateAgainstState(
        self: *TransactionPool,
        senders: []const primitives.Address,
        state_nonces: []const u64,
    ) void {
        for (senders, state_nonces) |sender, nonce| {
            const entry = self.base_nonces.getPtr(sender.bytes) orelse continue;
            if (nonce == entry.nonce) continue;
            entry.nonce = nonce;
        }
        self.evictStale();
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
        } else {
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
        self.evictStale();
    }

    /// Removes every transaction whose nonce is below its sender's base nonce.
    /// Such a transaction can never execute: a different transaction with the
    /// same nonce was mined, or the base nonce moved past it.
    fn evictStale(self: *TransactionPool) void {
        var index: usize = 0;
        while (index < self.transactions.items.len) {
            const tx = self.transactions.items[index];
            if (tx.nonce < self.baseNonce(tx.sender)) {
                self.removeAtSwap(index);
            } else {
                index += 1;
            }
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
            // The moved transaction is already indexed, so its entry is
            // updated in place. An insert could allocate and fail.
            const moved_key: SenderNonceKey = .{ .sender = moved.sender.bytes, .nonce = moved.nonce };
            if (self.sender_nonce_index.getPtr(moved_key)) |ptr| ptr.* = index;
            if (self.hash_index.getPtr(moved.hash)) |ptr| {
                if (ptr.* == self.transactions.items.len) ptr.* = index;
            }
        }
        self.dropUnretainedBaseNonce(removed.sender);
        self.freeStoredTransaction(removed);
    }

    /// Removes the sender's base-nonce entry once its last pooled transaction
    /// is gone, unless `setNonce` or `add` asked the pool to retain it.
    fn dropUnretainedBaseNonce(self: *TransactionPool, sender: primitives.Address) void {
        const entry = self.base_nonces.get(sender.bytes) orelse return;
        if (entry.retained) return;
        for (self.transactions.items) |tx| {
            if (sameAddress(tx.sender, sender)) return;
        }
        _ = self.base_nonces.remove(sender.bytes);
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
        const entry = self.base_nonces.get(sender.bytes) orelse return 0;
        return entry.nonce;
    }

    fn advanceSenderNonce(self: *TransactionPool, sender: primitives.Address, mined_nonce: u64) void {
        const next_nonce = mined_nonce +| 1;
        // `add` creates the base-nonce entry for every pooled sender, so the
        // entry exists for any transaction that reaches this point.
        const entry = self.base_nonces.getPtr(sender.bytes) orelse return;
        if (next_nonce > entry.nonce) entry.nonce = next_nonce;
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
    comptime V: type,
    map: *std.AutoHashMapUnmanaged(K, V),
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
    cloned.blob_versioned_hashes = if (tx.blob_versioned_hashes.len > 0)
        try allocator.dupe([32]u8, tx.blob_versioned_hashes)
    else
        &.{};
    errdefer if (cloned.blob_versioned_hashes.len > 0) allocator.free(cloned.blob_versioned_hashes);
    cloned.blob_sidecars = if (tx.blob_sidecars.len > 0)
        try allocator.dupe(tx_encoding.BlobSidecar, tx.blob_sidecars)
    else
        &.{};
    errdefer if (cloned.blob_sidecars.len > 0) allocator.free(cloned.blob_sidecars);
    return cloned;
}

/// Bytes the pool allocates to store `tx`.
fn storedBytes(tx: PooledTransaction) usize {
    return tx.input.len + tx.raw.len +
        tx.blob_versioned_hashes.len * @sizeOf([32]u8) +
        tx.blob_sidecars.len * @sizeOf(tx_encoding.BlobSidecar);
}

fn isBlobTransaction(tx: PooledTransaction) bool {
    return tx.receipt_type == .eip4844 or tx.max_fee_per_blob_gas != null;
}

/// Smallest fee that bumps `fee` by `percent`: `fee * (100 + percent) / 100`,
/// saturating at the maximum u256.
fn bumpedFee(fee: u256, percent: u256) u256 {
    const scaled = std.math.mul(u256, fee, 100 + percent) catch return std.math.maxInt(u256);
    return scaled / 100;
}

/// Returns true if `replacement` may evict `existing` (same sender and nonce).
/// The fee cap and the priority fee must each strictly increase and reach the
/// bump threshold: 10% for execution transactions, 100% for blob transactions.
/// A blob transaction must also bump its blob fee cap by 100%. A blob
/// transaction cannot replace a non-blob transaction, or the reverse.
fn isPriceReplacement(existing: PooledTransaction, replacement: PooledTransaction) bool {
    const is_blob = isBlobTransaction(existing);
    if (is_blob != isBlobTransaction(replacement)) return false;
    const percent = if (is_blob) BLOB_REPLACEMENT_BUMP_PERCENT else REPLACEMENT_BUMP_PERCENT;

    if (replacement.max_fee_per_gas <= existing.max_fee_per_gas) return false;
    if (replacement.max_priority_fee_per_gas <= existing.max_priority_fee_per_gas) return false;
    if (replacement.max_fee_per_gas < bumpedFee(existing.max_fee_per_gas, percent)) return false;
    if (replacement.max_priority_fee_per_gas < bumpedFee(existing.max_priority_fee_per_gas, percent)) return false;

    if (is_blob) {
        const existing_blob_fee = existing.max_fee_per_blob_gas orelse 0;
        const replacement_blob_fee = replacement.max_fee_per_blob_gas orelse return false;
        if (replacement_blob_fee <= existing_blob_fee) return false;
        if (replacement_blob_fee < bumpedFee(existing_blob_fee, percent)) return false;
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

    // Cap and tip doubled, but blob fee not bumped: rejected.
    var replacement = testTx(sender, 0, 0x02, 200, 100);
    replacement.max_fee_per_blob_gas = 100;
    try testing.expectError(error.ReplacementUnderpriced, pool.add(allocator, replacement));

    // A 10% bump on every fee is below the 100% blob threshold: rejected.
    replacement = testTx(sender, 0, 0x03, 110, 55);
    replacement.max_fee_per_blob_gas = 110;
    try testing.expectError(error.ReplacementUnderpriced, pool.add(allocator, replacement));

    // All three doubled: accepted.
    replacement = testTx(sender, 0, 0x04, 200, 100);
    replacement.max_fee_per_blob_gas = 200;
    try pool.add(allocator, replacement);
    try testing.expectEqual(@as(u256, 200), pool.items()[0].max_fee_per_gas);
}

test "txpool replacement requires a 10% bump, not a 1 wei nudge" {
    const allocator = testing.allocator;
    var pool = TransactionPool.init(allocator);
    defer pool.deinit();

    const sender = primitives.Address{ .bytes = [_]u8{0x09} ++ [_]u8{0} ** 19 };
    try pool.add(allocator, testTx(sender, 0, 0x01, 1000, 1000));
    try testing.expectError(error.ReplacementUnderpriced, pool.add(allocator, testTx(sender, 0, 0x02, 1001, 1001)));
    try testing.expectError(error.ReplacementUnderpriced, pool.add(allocator, testTx(sender, 0, 0x03, 1099, 1099)));
    try pool.add(allocator, testTx(sender, 0, 0x04, 1100, 1100));
    try testing.expectEqual(@as(usize, 1), pool.items().len);

    // A fee near the u256 maximum must not overflow the threshold computation.
    const huge = std.math.maxInt(u256) - 1;
    try pool.add(allocator, testTx(sender, 1, 0x05, huge, huge));
    try testing.expectError(error.ReplacementUnderpriced, pool.add(allocator, testTx(sender, 1, 0x06, huge, huge)));
}

test "txpool rejects replacing a blob tx with a non-blob tx and the reverse" {
    const allocator = testing.allocator;
    var pool = TransactionPool.init(allocator);
    defer pool.deinit();

    const sender = primitives.Address{ .bytes = [_]u8{0x0c} ++ [_]u8{0} ** 19 };
    var blob_tx = testTx(sender, 0, 0x01, 100, 50);
    blob_tx.receipt_type = .eip4844;
    blob_tx.max_fee_per_blob_gas = 100;
    try pool.add(allocator, blob_tx);
    try testing.expectError(error.ReplacementUnderpriced, pool.add(allocator, testTx(sender, 0, 0x02, 1000, 1000)));

    try pool.add(allocator, testTx(sender, 1, 0x03, 100, 50));
    var blob_replacement = testTx(sender, 1, 0x04, 1000, 1000);
    blob_replacement.receipt_type = .eip4844;
    blob_replacement.max_fee_per_blob_gas = 1000;
    try testing.expectError(error.ReplacementUnderpriced, pool.add(allocator, blob_replacement));
}

test "txpool enforces the per-sender limit and the nonce gap" {
    const allocator = testing.allocator;
    var pool = TransactionPool.init(allocator);
    defer pool.deinit();

    const sender = primitives.Address{ .bytes = [_]u8{0x0d} ++ [_]u8{0} ** 19 };
    try pool.setNonce(sender, 10);
    try testing.expectError(error.NonceGapTooLarge, pool.add(allocator, testTxWithHash(sender, 10 + MAX_NONCE_GAP + 1, 9999)));
    try pool.add(allocator, testTxWithHash(sender, 10 + MAX_NONCE_GAP, 9998));

    var nonce: u64 = 10;
    while (pool.items().len < MAX_PER_SENDER) : (nonce += 1) {
        try pool.add(allocator, testTxWithHash(sender, nonce, nonce));
    }
    try testing.expectError(error.SenderLimitExceeded, pool.add(allocator, testTxWithHash(sender, nonce, nonce)));

    // A replacement does not add a transaction, so the limit does not block it.
    var replacement = testTxWithHash(sender, 10, 7777);
    replacement.max_fee_per_gas = 1000;
    replacement.max_priority_fee_per_gas = 1000;
    try pool.add(allocator, replacement);
    try testing.expectEqual(MAX_PER_SENDER, pool.items().len);
}

test "txpool enforces the transaction count limit" {
    const allocator = testing.allocator;
    var pool = TransactionPool.init(allocator);
    defer pool.deinit();

    var id: u64 = 0;
    while (id < MAX_POOL_TXS) : (id += 1) {
        try pool.add(allocator, testTxWithHash(testSender(id / MAX_PER_SENDER), id % MAX_PER_SENDER, id));
    }
    try testing.expectEqual(MAX_POOL_TXS, pool.items().len);
    try testing.expectError(error.TxPoolFull, pool.add(allocator, testTxWithHash(testSender(1_000_000), 0, id)));
}

test "txpool enforces the byte limit including calldata and raw bytes" {
    const allocator = testing.allocator;
    var pool = TransactionPool.init(allocator);
    defer pool.deinit();

    const payload = try allocator.alloc(u8, 4 * 1024 * 1024);
    defer allocator.free(payload);
    @memset(payload, 0xaa);

    // Each transaction stores the payload twice: once as input, once as raw.
    const per_tx = 2 * payload.len;
    var id: u64 = 0;
    while ((id + 1) * per_tx <= MAX_POOL_BYTES) : (id += 1) {
        var tx = testTxWithHash(testSender(id), 0, id);
        tx.input = payload;
        tx.raw = payload;
        try pool.add(allocator, tx);
    }
    try testing.expectEqual(MAX_POOL_BYTES, pool.totalBytes());

    var overflow = testTxWithHash(testSender(id), 0, id);
    overflow.input = payload[0..1];
    try testing.expectError(error.TxPoolFull, pool.add(allocator, overflow));
}

test "txpool removeMined evicts stale lower-nonce entries" {
    const allocator = testing.allocator;
    var pool = TransactionPool.init(allocator);
    defer pool.deinit();

    const sender = primitives.Address{ .bytes = [_]u8{0x0e} ++ [_]u8{0} ** 19 };
    const other = primitives.Address{ .bytes = [_]u8{0x0f} ++ [_]u8{0} ** 19 };
    try pool.add(allocator, testTx(sender, 0, 0xa0, 100, 1));
    try pool.add(allocator, testTx(sender, 1, 0xa1, 100, 1));
    try pool.add(allocator, testTx(sender, 2, 0xa2, 100, 1));
    try pool.add(allocator, testTx(other, 0, 0xb0, 100, 1));

    // Mining nonce 1 moves the base nonce to 2, so nonce 0 can never execute.
    pool.removeMined(&.{[_]u8{0xa1} ** 32});

    try testing.expectEqual(@as(usize, 2), pool.items().len);
    try testing.expectEqual(@as(usize, 2), pool.pendingCount());
    try testing.expect(!pool.removeByHash([_]u8{0xa0} ** 32));
    try testing.expect(pool.removeByHash([_]u8{0xa2} ** 32));
    try testing.expect(pool.removeByHash([_]u8{0xb0} ** 32));
    try testing.expectEqual(@as(usize, 0), pool.items().len);
}

fn testSender(id: u64) primitives.Address {
    var bytes = [_]u8{0} ** 20;
    std.mem.writeInt(u64, bytes[12..20], id, .big);
    bytes[0] = 0xf0;
    return .{ .bytes = bytes };
}

fn testTxWithHash(sender: primitives.Address, nonce: u64, id: u64) PooledTransaction {
    var hash = [_]u8{0} ** 32;
    std.mem.writeInt(u64, hash[24..32], id, .big);
    hash[0] = 0x77;
    return .{
        .sender = sender,
        .nonce = nonce,
        .gas_limit = 21000,
        .max_fee_per_gas = 100,
        .max_priority_fee_per_gas = 1,
        .hash = hash,
    };
}

test "txpool readyRange matches statusOf for pending, queued, and stale nonces" {
    const allocator = testing.allocator;
    var pool = TransactionPool.init(allocator);
    defer pool.deinit();

    const sender = primitives.Address{ .bytes = [_]u8{0x1a} ++ [_]u8{0} ** 19 };
    try pool.setNonce(sender, 2);
    for ([_]u64{ 1, 2, 3, 5 }) |nonce| {
        try pool.add(allocator, testTxWithHash(sender, nonce, nonce));
    }

    const range = pool.readyRange(sender);
    try testing.expectEqual(@as(u64, 2), range.start);
    try testing.expectEqual(@as(u64, 2), range.count);
    for ([_]u64{ 1, 2, 3, 5 }) |nonce| {
        try testing.expectEqual(pool.statusOf(sender, nonce) == .pending, range.contains(nonce));
    }

    const unknown = primitives.Address{ .bytes = [_]u8{0x1b} ++ [_]u8{0} ** 19 };
    try testing.expectEqual(@as(u64, 0), pool.readyRange(unknown).count);
}

test "txpool addWithBaseNonce leaves no sender entry for a rejected transaction" {
    const allocator = testing.allocator;
    var pool = TransactionPool.init(allocator);
    defer pool.deinit();

    // One rejected transaction per sender: a distinct key each time must not
    // grow the pool's per-sender state.
    for (0..32) |id| {
        const sender = testSender(id);
        try testing.expectError(
            error.NonceGapTooLarge,
            pool.addWithBaseNonce(testTxWithHash(sender, MAX_NONCE_GAP + 8, id), 7),
        );
    }
    try testing.expectEqual(@as(usize, 0), pool.items().len);
    try testing.expectEqual(@as(u32, 0), pool.base_nonces.count());
}

test "txpool addWithBaseNonce drops the sender entry with its last transaction" {
    const allocator = testing.allocator;
    var pool = TransactionPool.init(allocator);
    defer pool.deinit();

    const sender = testSender(1);
    try pool.addWithBaseNonce(testTxWithHash(sender, 5, 50), 5);
    try pool.addWithBaseNonce(testTxWithHash(sender, 6, 60), 5);
    try testing.expectEqual(EntryStatus.pending, pool.statusOf(sender, 6));
    try testing.expectEqual(@as(u32, 1), pool.base_nonces.count());

    // Mining nonce 5 advances the base nonce and keeps the entry: nonce 6
    // still needs it.
    pool.removeMined(&.{testTxWithHash(sender, 5, 50).hash});
    try testing.expectEqual(@as(u64, 6), pool.readyRange(sender).start);
    try testing.expectEqual(@as(u32, 1), pool.base_nonces.count());

    try testing.expect(pool.removeByHash(testTxWithHash(sender, 6, 60).hash));
    try testing.expectEqual(@as(u32, 0), pool.base_nonces.count());

    // A later submission supplies the state nonce again.
    try pool.addWithBaseNonce(testTxWithHash(sender, 7, 70), 7);
    try testing.expectEqual(EntryStatus.pending, pool.statusOf(sender, 7));
}

test "txpool pruneBelowNonce evicts consumed-nonce txs" {
    const allocator = testing.allocator;
    var pool = TransactionPool.init(allocator);
    defer pool.deinit();

    const sender = testSender(10);
    try pool.setNonce(sender, 0);
    try pool.add(allocator, testTxWithHash(sender, 0, 100));
    try pool.add(allocator, testTxWithHash(sender, 1, 101));
    try pool.add(allocator, testTxWithHash(sender, 2, 102));
    try testing.expectEqual(@as(usize, 3), pool.items().len);

    pool.pruneBelowNonce(sender, 2);
    try testing.expectEqual(@as(usize, 1), pool.items().len);
    try testing.expectEqual(@as(u64, 2), pool.items()[0].nonce);

    pool.pruneBelowNonce(sender, 2);
    try testing.expectEqual(@as(usize, 1), pool.items().len);
}

test "txpool pruneBelowNonce is a no-op for unknown senders" {
    const allocator = testing.allocator;
    var pool = TransactionPool.init(allocator);
    defer pool.deinit();

    const unknown = testSender(99);
    pool.pruneBelowNonce(unknown, 5);
    try testing.expectEqual(@as(usize, 0), pool.items().len);
}

test "txpool revalidateAgainstState prunes multiple senders" {
    const allocator = testing.allocator;
    var pool = TransactionPool.init(allocator);
    defer pool.deinit();

    const a = testSender(20);
    const b = testSender(21);
    try pool.setNonce(a, 0);
    try pool.setNonce(b, 0);
    try pool.add(allocator, testTxWithHash(a, 0, 200));
    try pool.add(allocator, testTxWithHash(a, 1, 201));
    try pool.add(allocator, testTxWithHash(b, 0, 300));
    try pool.add(allocator, testTxWithHash(b, 1, 301));
    try testing.expectEqual(@as(usize, 4), pool.items().len);

    pool.revalidateAgainstState(
        &[_]primitives.Address{ a, b },
        &[_]u64{ 1, 2 },
    );
    try testing.expectEqual(@as(usize, 1), pool.items().len);
    try testing.expectEqual(@as(u64, 1), pool.items()[0].nonce);
    try testing.expect(sameAddress(pool.items()[0].sender, a));
}

test "txpool setNonce and add keep the sender entry after its last transaction" {
    const allocator = testing.allocator;
    var pool = TransactionPool.init(allocator);
    defer pool.deinit();

    const pinned = testSender(2);
    try pool.setNonce(pinned, 3);
    try pool.add(allocator, testTxWithHash(pinned, 3, 30));
    pool.removeMined(&.{testTxWithHash(pinned, 3, 30).hash});
    try pool.add(allocator, testTxWithHash(pinned, 4, 40));
    try testing.expectEqual(EntryStatus.pending, pool.statusOf(pinned, 4));

    const implicit = testSender(3);
    try pool.add(allocator, testTxWithHash(implicit, 0, 100));
    pool.removeMined(&.{testTxWithHash(implicit, 0, 100).hash});
    try pool.add(allocator, testTxWithHash(implicit, 1, 101));
    try testing.expectEqual(EntryStatus.pending, pool.statusOf(implicit, 1));
}
