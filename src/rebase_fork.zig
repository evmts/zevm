//! Rebase engine for `--fork-follow` (Issues #19 and #20).
//!
//! When a trusted-mode fork follows its upstream, ZEVM periodically moves the
//! fork point to the new upstream head and replays local transactions on top.
//! This module owns the state that decision needs and stays independent of
//! `NodeRuntime` so Wave 2 can wire it in without import cycles:
//!
//! - `TxAccessSet` records which accounts and storage slots a local tx touched.
//! - `UpstreamStateDiff` records which of those keys changed upstream between
//!   the old fork block and the new head.
//! - `RebaseTracker.planReplay` marks each local tx `.carry_forward` (reuse its
//!   cached deltas, skip execution) or `.reexecute`. Taint cascades in order: a
//!   re-executed tx adds its writes to the working diff, so later txs that read
//!   or write those keys re-execute too.
//! - `RebaseTracker.startPolling` runs a background loop that calls a supplied
//!   poll function every `poll_interval_ms` until `stopPolling`.
//!
//! Upstream RPC access goes through `UpstreamRpcHooks`, so tests and the
//! runtime supply their own transport.
//!
//! Limitation: classification uses the access set recorded on the previous
//! execution. A re-executed tx may touch new keys on the new base; the runtime
//! must refresh `access_set` from the re-execution before the next rebase.

const std = @import("std");
const primitives = @import("primitives");

pub const StorageSlotKey = struct {
    address: [20]u8,
    slot: u256,

    pub fn eql(a: StorageSlotKey, b: StorageSlotKey) bool {
        return std.mem.eql(u8, &a.address, &b.address) and a.slot == b.slot;
    }
};

/// Post-tx account state. `code` is owned by the containing `LocalTxEntry`.
pub const AccountDelta = struct {
    address: [20]u8,
    balance: u256,
    nonce: u64,
    code: ?[]u8 = null,
};

pub const StorageDelta = struct {
    address: [20]u8,
    slot: u256,
    value: u256,
};

fn containsAddress(list: []const [20]u8, address: [20]u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, &item, &address)) return true;
    }
    return false;
}

fn containsSlot(list: []const StorageSlotKey, key: StorageSlotKey) bool {
    for (list) |item| {
        if (item.eql(key)) return true;
    }
    return false;
}

fn anyAddressIn(haystack: []const [20]u8, needles: []const [20]u8) bool {
    for (needles) |address| {
        if (containsAddress(haystack, address)) return true;
    }
    return false;
}

fn anySlotIn(haystack: []const StorageSlotKey, needles: []const StorageSlotKey) bool {
    for (needles) |key| {
        if (containsSlot(haystack, key)) return true;
    }
    return false;
}

/// Deduplicated read and write sets of one executed transaction.
pub const TxAccessSet = struct {
    accounts_read: std.ArrayListUnmanaged([20]u8) = .empty,
    accounts_written: std.ArrayListUnmanaged([20]u8) = .empty,
    storage_read: std.ArrayListUnmanaged(StorageSlotKey) = .empty,
    storage_written: std.ArrayListUnmanaged(StorageSlotKey) = .empty,

    pub fn init() TxAccessSet {
        return .{};
    }

    pub fn deinit(self: *TxAccessSet, allocator: std.mem.Allocator) void {
        self.accounts_read.deinit(allocator);
        self.accounts_written.deinit(allocator);
        self.storage_read.deinit(allocator);
        self.storage_written.deinit(allocator);
        self.* = .{};
    }

    pub fn clone(self: *const TxAccessSet, allocator: std.mem.Allocator) std.mem.Allocator.Error!TxAccessSet {
        var copy = TxAccessSet{};
        errdefer copy.deinit(allocator);
        copy.accounts_read = try self.accounts_read.clone(allocator);
        copy.accounts_written = try self.accounts_written.clone(allocator);
        copy.storage_read = try self.storage_read.clone(allocator);
        copy.storage_written = try self.storage_written.clone(allocator);
        return copy;
    }

    pub fn recordAccountRead(self: *TxAccessSet, allocator: std.mem.Allocator, address: [20]u8) std.mem.Allocator.Error!void {
        if (containsAddress(self.accounts_read.items, address)) return;
        try self.accounts_read.append(allocator, address);
    }

    pub fn recordAccountWrite(self: *TxAccessSet, allocator: std.mem.Allocator, address: [20]u8) std.mem.Allocator.Error!void {
        if (containsAddress(self.accounts_written.items, address)) return;
        try self.accounts_written.append(allocator, address);
    }

    pub fn recordStorageRead(self: *TxAccessSet, allocator: std.mem.Allocator, address: [20]u8, slot: u256) std.mem.Allocator.Error!void {
        const key = StorageSlotKey{ .address = address, .slot = slot };
        if (containsSlot(self.storage_read.items, key)) return;
        try self.storage_read.append(allocator, key);
    }

    pub fn recordStorageWrite(self: *TxAccessSet, allocator: std.mem.Allocator, address: [20]u8, slot: u256) std.mem.Allocator.Error!void {
        const key = StorageSlotKey{ .address = address, .slot = slot };
        if (containsSlot(self.storage_written.items, key)) return;
        try self.storage_written.append(allocator, key);
    }

    /// True when any account or slot this tx read or wrote changed in `diff`.
    /// Account and storage keys are matched separately: a balance change on
    /// address A does not taint a tx that only touched A's storage.
    pub fn overlapsWith(self: *const TxAccessSet, diff: *const UpstreamStateDiff) bool {
        const changed_accounts = diff.changed_accounts.items;
        const changed_storage = diff.changed_storage.items;
        return anyAddressIn(changed_accounts, self.accounts_read.items) or
            anyAddressIn(changed_accounts, self.accounts_written.items) or
            anySlotIn(changed_storage, self.storage_read.items) or
            anySlotIn(changed_storage, self.storage_written.items);
    }

    /// True when the two txs conflict: either one's writes intersect the
    /// other's reads or writes. Read-read sharing is not a conflict.
    pub fn overlapsWithAccessSet(self: *const TxAccessSet, other: *const TxAccessSet) bool {
        return anyAddressIn(other.accounts_written.items, self.accounts_read.items) or
            anyAddressIn(other.accounts_written.items, self.accounts_written.items) or
            anyAddressIn(self.accounts_written.items, other.accounts_read.items) or
            anySlotIn(other.storage_written.items, self.storage_read.items) or
            anySlotIn(other.storage_written.items, self.storage_written.items) or
            anySlotIn(self.storage_written.items, other.storage_read.items);
    }
};

/// Keys whose upstream value differs between the old fork block and the new
/// head. Entries are deduplicated.
pub const UpstreamStateDiff = struct {
    changed_accounts: std.ArrayListUnmanaged([20]u8) = .empty,
    changed_storage: std.ArrayListUnmanaged(StorageSlotKey) = .empty,

    pub fn init() UpstreamStateDiff {
        return .{};
    }

    pub fn deinit(self: *UpstreamStateDiff, allocator: std.mem.Allocator) void {
        self.changed_accounts.deinit(allocator);
        self.changed_storage.deinit(allocator);
        self.* = .{};
    }

    pub fn markAccountChanged(self: *UpstreamStateDiff, allocator: std.mem.Allocator, address: [20]u8) std.mem.Allocator.Error!void {
        if (containsAddress(self.changed_accounts.items, address)) return;
        try self.changed_accounts.append(allocator, address);
    }

    pub fn markStorageChanged(self: *UpstreamStateDiff, allocator: std.mem.Allocator, address: [20]u8, slot: u256) std.mem.Allocator.Error!void {
        const key = StorageSlotKey{ .address = address, .slot = slot };
        if (containsSlot(self.changed_storage.items, key)) return;
        try self.changed_storage.append(allocator, key);
    }

    pub fn isEmpty(self: *const UpstreamStateDiff) bool {
        return self.changed_accounts.items.len == 0 and self.changed_storage.items.len == 0;
    }
};

/// One locally mined transaction plus what is needed to carry it forward
/// without execution. Owns `raw_tx`, `access_set`, both delta lists, and each
/// `AccountDelta.code`.
pub const LocalTxEntry = struct {
    tx_hash: [32]u8,
    caller: primitives.Address,
    raw_tx: []u8,
    access_set: TxAccessSet,
    cached_account_deltas: std.ArrayListUnmanaged(AccountDelta) = .empty,
    cached_storage_deltas: std.ArrayListUnmanaged(StorageDelta) = .empty,
    cached_gas_used: u64,
    cached_status: bool,
    original_block_number: u64,

    pub fn deinit(self: *LocalTxEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.raw_tx);
        self.access_set.deinit(allocator);
        for (self.cached_account_deltas.items) |delta| {
            if (delta.code) |code| allocator.free(code);
        }
        self.cached_account_deltas.deinit(allocator);
        self.cached_storage_deltas.deinit(allocator);
    }
};

pub const ReplayDisposition = enum { carry_forward, reexecute };

/// Optional observers for one rebase. Every callback receives `context`.
pub const RebaseEventCallbacks = struct {
    context: ?*anyopaque = null,
    on_started: ?*const fn (ctx: ?*anyopaque, old_fork_block: u64, new_upstream_head: u64) void = null,
    on_tx_replayed: ?*const fn (ctx: ?*anyopaque, tx_hash: [32]u8, new_block_number: u64, skipped_execution: bool) void = null,
    on_tx_dropped: ?*const fn (ctx: ?*anyopaque, tx_hash: [32]u8, reason: []const u8) void = null,
    on_completed: ?*const fn (ctx: ?*anyopaque, new_fork_block: u64, replayed_count: usize, dropped_count: usize) void = null,
};

/// Upstream transport. `fetch_*_changed` report whether the key's value at
/// `new_block` differs from `old_block`.
pub const UpstreamRpcHooks = struct {
    context: ?*anyopaque,
    fetch_block_number: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, url: []const u8) anyerror!u64,
    fetch_account_changed: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, url: []const u8, addr: [20]u8, old_block: u64, new_block: u64) anyerror!bool,
    fetch_storage_changed: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, url: []const u8, addr: [20]u8, slot: u256, old_block: u64, new_block: u64) anyerror!bool,
};

pub const PollingError = error{
    AlreadyPolling,
    FollowDisabled,
} || std.Thread.SpawnError;

/// Owns the upstream URL, the local tx log, and the background poller.
/// `mutex` guards `upstream_url`, `current_fork_block`, and `local_txs`.
/// The tracker must not move after `startPolling`; the worker holds `self`.
pub const RebaseTracker = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    upstream_url: []u8,
    follow: bool,
    current_fork_block: u64,
    poll_interval_ms: u64 = 1000,
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    worker_thread: ?std.Thread = null,
    local_txs: std.ArrayListUnmanaged(LocalTxEntry) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        url: []const u8,
        initial_fork_block: u64,
        follow: bool,
    ) std.mem.Allocator.Error!RebaseTracker {
        return .{
            .allocator = allocator,
            .upstream_url = try allocator.dupe(u8, url),
            .follow = follow,
            .current_fork_block = initial_fork_block,
        };
    }

    pub fn deinit(self: *RebaseTracker) void {
        self.stopPolling();
        for (self.local_txs.items) |*entry| entry.deinit(self.allocator);
        self.local_txs.deinit(self.allocator);
        self.allocator.free(self.upstream_url);
        self.* = undefined;
    }

    /// Appends `entry` in execution order and takes ownership of it.
    pub fn recordLocalTx(self: *RebaseTracker, entry: LocalTxEntry) std.mem.Allocator.Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.local_txs.append(self.allocator, entry);
    }

    pub fn clearLocalTxs(self: *RebaseTracker) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.local_txs.items) |*entry| entry.deinit(self.allocator);
        self.local_txs.clearRetainingCapacity();
    }

    /// Replaces the upstream URL (for example after `anvil_reset`/`hardhat_reset`).
    /// `follow` and the fork block are left unchanged.
    pub fn setRpcUrl(self: *RebaseTracker, new_url: []const u8) std.mem.Allocator.Error!void {
        const owned = try self.allocator.dupe(u8, new_url);
        self.mutex.lock();
        defer self.mutex.unlock();
        self.allocator.free(self.upstream_url);
        self.upstream_url = owned;
    }

    /// Returns a caller-owned copy of the current upstream URL.
    pub fn getUrlAlloc(self: *RebaseTracker, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return allocator.dupe(u8, self.upstream_url);
    }

    /// Queries upstream for every account and slot any local tx touched and
    /// returns the ones that changed between `old_block` and `new_block`.
    /// The key set and URL are snapshotted under the lock; RPC calls run
    /// without it so recordLocalTx and setRpcUrl are not blocked on network I/O.
    pub fn computeUpstreamDiff(
        self: *RebaseTracker,
        allocator: std.mem.Allocator,
        hooks: UpstreamRpcHooks,
        old_block: u64,
        new_block: u64,
    ) !UpstreamStateDiff {
        var accounts: std.ArrayListUnmanaged([20]u8) = .empty;
        defer accounts.deinit(allocator);
        var slots: std.ArrayListUnmanaged(StorageSlotKey) = .empty;
        defer slots.deinit(allocator);

        const url = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            for (self.local_txs.items) |*entry| {
                const set = &entry.access_set;
                for ([_][]const [20]u8{ set.accounts_read.items, set.accounts_written.items }) |list| {
                    for (list) |address| {
                        if (!containsAddress(accounts.items, address)) try accounts.append(allocator, address);
                    }
                }
                for ([_][]const StorageSlotKey{ set.storage_read.items, set.storage_written.items }) |list| {
                    for (list) |key| {
                        if (!containsSlot(slots.items, key)) try slots.append(allocator, key);
                    }
                }
            }
            break :blk try allocator.dupe(u8, self.upstream_url);
        };
        defer allocator.free(url);

        var diff = UpstreamStateDiff{};
        errdefer diff.deinit(allocator);
        for (accounts.items) |address| {
            if (try hooks.fetch_account_changed(hooks.context, allocator, url, address, old_block, new_block)) {
                try diff.markAccountChanged(allocator, address);
            }
        }
        for (slots.items) |key| {
            if (try hooks.fetch_storage_changed(hooks.context, allocator, url, key.address, key.slot, old_block, new_block)) {
                try diff.markStorageChanged(allocator, key.address, key.slot);
            }
        }
        return diff;
    }

    /// Classifies each local tx, in recorded order. Result index `i` belongs to
    /// `local_txs.items[i]`; the caller owns the returned slice.
    ///
    /// A tx re-executes when its access set overlaps the upstream diff or the
    /// writes of any earlier re-executed tx. Every re-executed tx adds its
    /// written accounts and slots to a working copy of the diff, so taint
    /// cascades through dependent txs (including same-sender nonce chains).
    pub fn planReplay(
        self: *const RebaseTracker,
        allocator: std.mem.Allocator,
        diff: *const UpstreamStateDiff,
    ) std.mem.Allocator.Error![]ReplayDisposition {
        // The lock guards `local_txs`; locking does not change tracker state.
        const mutex = @constCast(&self.mutex);
        mutex.lock();
        defer mutex.unlock();

        var working = UpstreamStateDiff{};
        defer working.deinit(allocator);
        working.changed_accounts = try diff.changed_accounts.clone(allocator);
        working.changed_storage = try diff.changed_storage.clone(allocator);

        const plan = try allocator.alloc(ReplayDisposition, self.local_txs.items.len);
        errdefer allocator.free(plan);

        for (self.local_txs.items, plan) |*entry, *disposition| {
            const set = &entry.access_set;
            if (!set.overlapsWith(&working)) {
                disposition.* = .carry_forward;
                continue;
            }
            disposition.* = .reexecute;
            for (set.accounts_written.items) |address| try working.markAccountChanged(allocator, address);
            for (set.storage_written.items) |key| try working.markStorageChanged(allocator, key.address, key.slot);
        }
        return plan;
    }

    /// Spawns the poller. It calls `poll_fn(poll_ctx)` every `poll_interval_ms`
    /// without holding `mutex`, so `poll_fn` may call tracker methods.
    pub fn startPolling(
        self: *RebaseTracker,
        poll_ctx: ?*anyopaque,
        poll_fn: *const fn (?*anyopaque) void,
    ) PollingError!void {
        if (comptime @import("builtin").single_threaded) return error.FollowDisabled;
        if (!self.follow) return error.FollowDisabled;
        if (self.worker_thread != null) return error.AlreadyPolling;
        self.stop_flag.store(false, .release);
        self.worker_thread = try std.Thread.spawn(.{}, pollLoop, .{ self, poll_ctx, poll_fn });
    }

    /// Signals the poller, joins it, and leaves the tracker ready to restart.
    /// Safe to call when no poller runs. Must not be called from `poll_fn`.
    pub fn stopPolling(self: *RebaseTracker) void {
        const thread = self.worker_thread orelse return;
        self.stop_flag.store(true, .release);
        {
            // Signal under the lock so the worker cannot miss the wakeup between
            // checking `stop_flag` and entering `timedWait`.
            self.mutex.lock();
            defer self.mutex.unlock();
            self.cond.broadcast();
        }
        thread.join();
        self.worker_thread = null;
        self.stop_flag.store(false, .release);
    }

    fn pollLoop(self: *RebaseTracker, poll_ctx: ?*anyopaque, poll_fn: *const fn (?*anyopaque) void) void {
        while (true) {
            if (self.waitForNextPoll()) return;
            poll_fn(poll_ctx);
        }
    }

    /// Sleeps for one poll interval. Returns true when stop was requested.
    fn waitForNextPoll(self: *RebaseTracker) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const interval_ns = self.poll_interval_ms *| std.time.ns_per_ms;
        var timer = std.time.Timer.start() catch {
            // No monotonic clock: fall back to a single wait.
            if (self.stop_flag.load(.acquire)) return true;
            self.cond.timedWait(&self.mutex, interval_ns) catch {};
            return self.stop_flag.load(.acquire);
        };
        while (!self.stop_flag.load(.acquire)) {
            const elapsed = timer.read();
            if (elapsed >= interval_ns) return false;
            // Loop on spurious wakeups until the interval elapses or stop is set.
            self.cond.timedWait(&self.mutex, interval_ns - elapsed) catch return self.stop_flag.load(.acquire);
        }
        return true;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn testAddress(byte: u8) [20]u8 {
    return [_]u8{byte} ++ [_]u8{0} ** 19;
}

const TestAccess = struct {
    accounts_read: []const u8 = &.{},
    accounts_written: []const u8 = &.{},
    storage_read: []const StorageSlotKey = &.{},
    storage_written: []const StorageSlotKey = &.{},
};

fn testSlot(address_byte: u8, slot: u256) StorageSlotKey {
    return .{ .address = testAddress(address_byte), .slot = slot };
}

fn makeAccessSet(allocator: std.mem.Allocator, access: TestAccess) !TxAccessSet {
    var set = TxAccessSet.init();
    errdefer set.deinit(allocator);
    for (access.accounts_read) |b| try set.recordAccountRead(allocator, testAddress(b));
    for (access.accounts_written) |b| try set.recordAccountWrite(allocator, testAddress(b));
    for (access.storage_read) |k| try set.recordStorageRead(allocator, k.address, k.slot);
    for (access.storage_written) |k| try set.recordStorageWrite(allocator, k.address, k.slot);
    return set;
}

fn makeEntry(allocator: std.mem.Allocator, hash_byte: u8, caller_byte: u8, access: TestAccess) !LocalTxEntry {
    var entry = LocalTxEntry{
        .tx_hash = [_]u8{hash_byte} ** 32,
        .caller = primitives.Address{ .bytes = testAddress(caller_byte) },
        .raw_tx = try allocator.dupe(u8, &[_]u8{ 0x02, hash_byte }),
        .access_set = TxAccessSet.init(),
        .cached_gas_used = 21_000,
        .cached_status = true,
        .original_block_number = 100,
    };
    errdefer entry.deinit(allocator);
    entry.access_set = try makeAccessSet(allocator, access);
    try entry.cached_account_deltas.ensureUnusedCapacity(allocator, 1);
    entry.cached_account_deltas.appendAssumeCapacity(.{
        .address = testAddress(caller_byte),
        .balance = 1,
        .nonce = 1,
        .code = try allocator.dupe(u8, &[_]u8{0x60}),
    });
    try entry.cached_storage_deltas.append(allocator, .{ .address = testAddress(caller_byte), .slot = 0, .value = 1 });
    return entry;
}

fn makeDiff(allocator: std.mem.Allocator, accounts: []const u8, slots: []const StorageSlotKey) !UpstreamStateDiff {
    var diff = UpstreamStateDiff.init();
    errdefer diff.deinit(allocator);
    for (accounts) |b| try diff.markAccountChanged(allocator, testAddress(b));
    for (slots) |k| try diff.markStorageChanged(allocator, k.address, k.slot);
    return diff;
}

test "TxAccessSet deduplicates records and clones independently" {
    const allocator = std.testing.allocator;
    var set = try makeAccessSet(allocator, .{
        .accounts_read = &.{ 1, 1, 2 },
        .accounts_written = &.{ 3, 3 },
        .storage_read = &.{ testSlot(4, 1), testSlot(4, 1) },
        .storage_written = &.{ testSlot(4, 2), testSlot(5, 2) },
    });
    defer set.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), set.accounts_read.items.len);
    try std.testing.expectEqual(@as(usize, 1), set.accounts_written.items.len);
    try std.testing.expectEqual(@as(usize, 1), set.storage_read.items.len);
    try std.testing.expectEqual(@as(usize, 2), set.storage_written.items.len);

    var copy = try set.clone(allocator);
    defer copy.deinit(allocator);
    try set.recordAccountRead(allocator, testAddress(9));
    try std.testing.expectEqual(@as(usize, 3), set.accounts_read.items.len);
    try std.testing.expectEqual(@as(usize, 2), copy.accounts_read.items.len);
}

test "overlapsWith detects account and slot overlap and ignores disjoint keys" {
    const allocator = std.testing.allocator;
    var set = try makeAccessSet(allocator, .{
        .accounts_read = &.{1},
        .accounts_written = &.{2},
        .storage_read = &.{testSlot(3, 7)},
        .storage_written = &.{testSlot(4, 8)},
    });
    defer set.deinit(allocator);

    const Case = struct { accounts: []const u8, slots: []const StorageSlotKey, overlaps: bool };
    const cases = comptime [_]Case{
        .{ .accounts = &.{}, .slots = &.{}, .overlaps = false },
        .{ .accounts = &.{1}, .slots = &.{}, .overlaps = true },
        .{ .accounts = &.{2}, .slots = &.{}, .overlaps = true },
        .{ .accounts = &.{}, .slots = &.{testSlot(3, 7)}, .overlaps = true },
        .{ .accounts = &.{}, .slots = &.{testSlot(4, 8)}, .overlaps = true },
        // Same address, different slot.
        .{ .accounts = &.{}, .slots = &.{testSlot(3, 8)}, .overlaps = false },
        // Account change on an address the tx only touched via storage.
        .{ .accounts = &.{3}, .slots = &.{}, .overlaps = false },
        .{ .accounts = &.{ 9, 10 }, .slots = &.{testSlot(9, 7)}, .overlaps = false },
    };
    for (cases) |case| {
        var diff = try makeDiff(allocator, case.accounts, case.slots);
        defer diff.deinit(allocator);
        try std.testing.expectEqual(case.overlaps, set.overlapsWith(&diff));
    }
}

test "overlapsWithAccessSet treats write conflicts as overlap and read-read as disjoint" {
    const allocator = std.testing.allocator;
    var reader = try makeAccessSet(allocator, .{ .accounts_read = &.{1}, .storage_read = &.{testSlot(2, 5)} });
    defer reader.deinit(allocator);
    var other_reader = try makeAccessSet(allocator, .{ .accounts_read = &.{1}, .storage_read = &.{testSlot(2, 5)} });
    defer other_reader.deinit(allocator);
    var slot_writer = try makeAccessSet(allocator, .{ .storage_written = &.{testSlot(2, 5)} });
    defer slot_writer.deinit(allocator);
    var account_writer = try makeAccessSet(allocator, .{ .accounts_written = &.{1} });
    defer account_writer.deinit(allocator);
    var unrelated = try makeAccessSet(allocator, .{ .accounts_written = &.{7}, .storage_written = &.{testSlot(2, 6)} });
    defer unrelated.deinit(allocator);

    try std.testing.expect(!reader.overlapsWithAccessSet(&other_reader));
    try std.testing.expect(reader.overlapsWithAccessSet(&slot_writer));
    try std.testing.expect(slot_writer.overlapsWithAccessSet(&reader));
    try std.testing.expect(reader.overlapsWithAccessSet(&account_writer));
    try std.testing.expect(account_writer.overlapsWithAccessSet(&reader));
    try std.testing.expect(!reader.overlapsWithAccessSet(&unrelated));
    try std.testing.expect(!unrelated.overlapsWithAccessSet(&reader));
}

test "UpstreamStateDiff deduplicates and reports emptiness" {
    const allocator = std.testing.allocator;
    var diff = UpstreamStateDiff.init();
    defer diff.deinit(allocator);
    try std.testing.expect(diff.isEmpty());
    try diff.markAccountChanged(allocator, testAddress(1));
    try diff.markAccountChanged(allocator, testAddress(1));
    try diff.markStorageChanged(allocator, testAddress(1), 3);
    try diff.markStorageChanged(allocator, testAddress(1), 3);
    try std.testing.expect(!diff.isEmpty());
    try std.testing.expectEqual(@as(usize, 1), diff.changed_accounts.items.len);
    try std.testing.expectEqual(@as(usize, 1), diff.changed_storage.items.len);
}

test "planReplay carries forward disjoint txs and skips re-execution" {
    const allocator = std.testing.allocator;
    var tracker = try RebaseTracker.init(allocator, "https://rpc.example", 100, true);
    defer tracker.deinit();
    try tracker.recordLocalTx(try makeEntry(allocator, 0xA1, 0x10, .{ .accounts_written = &.{0x10}, .storage_written = &.{testSlot(0x20, 1)} }));
    try tracker.recordLocalTx(try makeEntry(allocator, 0xA2, 0x11, .{ .accounts_written = &.{0x11}, .storage_read = &.{testSlot(0x21, 1)} }));

    // Upstream changed unrelated keys only.
    var diff = try makeDiff(allocator, &.{0x99}, &.{ testSlot(0x20, 2), testSlot(0x22, 1) });
    defer diff.deinit(allocator);

    const plan = try tracker.planReplay(allocator, &diff);
    defer allocator.free(plan);
    try std.testing.expectEqualSlices(ReplayDisposition, &.{ .carry_forward, .carry_forward }, plan);

    var empty = UpstreamStateDiff.init();
    defer empty.deinit(allocator);
    const empty_plan = try tracker.planReplay(allocator, &empty);
    defer allocator.free(empty_plan);
    try std.testing.expectEqualSlices(ReplayDisposition, &.{ .carry_forward, .carry_forward }, empty_plan);
}

test "planReplay cascades re-execution through dependent txs" {
    const allocator = std.testing.allocator;
    var tracker = try RebaseTracker.init(allocator, "https://rpc.example", 100, true);
    defer tracker.deinit();
    // tx0 reads a slot upstream changed and writes pool slot P.
    try tracker.recordLocalTx(try makeEntry(allocator, 0xB0, 0x10, .{
        .accounts_written = &.{0x10},
        .storage_read = &.{testSlot(0x30, 1)},
        .storage_written = &.{testSlot(0x31, 9)},
    }));
    // tx1 is disjoint from upstream and from tx0.
    try tracker.recordLocalTx(try makeEntry(allocator, 0xB1, 0x11, .{ .accounts_written = &.{0x11}, .storage_written = &.{testSlot(0x40, 1)} }));
    // tx2 reads P, which tx0 wrote.
    try tracker.recordLocalTx(try makeEntry(allocator, 0xB2, 0x12, .{
        .accounts_written = &.{0x12},
        .storage_read = &.{testSlot(0x31, 9)},
        .storage_written = &.{testSlot(0x32, 1)},
    }));
    // tx3 reads what tx2 wrote: second-hop cascade.
    try tracker.recordLocalTx(try makeEntry(allocator, 0xB3, 0x13, .{ .accounts_written = &.{0x13}, .storage_read = &.{testSlot(0x32, 1)} }));
    // tx4 is the same sender as tx0: nonce dependency via the caller account.
    try tracker.recordLocalTx(try makeEntry(allocator, 0xB4, 0x10, .{ .accounts_read = &.{0x10}, .accounts_written = &.{0x10} }));

    var diff = try makeDiff(allocator, &.{}, &.{testSlot(0x30, 1)});
    defer diff.deinit(allocator);

    const plan = try tracker.planReplay(allocator, &diff);
    defer allocator.free(plan);
    try std.testing.expectEqualSlices(
        ReplayDisposition,
        &.{ .reexecute, .carry_forward, .reexecute, .reexecute, .reexecute },
        plan,
    );
    // planReplay must not mutate the caller's diff.
    try std.testing.expectEqual(@as(usize, 1), diff.changed_storage.items.len);
    try std.testing.expectEqual(@as(usize, 0), diff.changed_accounts.items.len);
}

test "planReplay does not taint earlier txs with later writes" {
    const allocator = std.testing.allocator;
    var tracker = try RebaseTracker.init(allocator, "https://rpc.example", 100, true);
    defer tracker.deinit();
    // tx0 reads S; tx1 (later) is tainted by upstream and writes S.
    try tracker.recordLocalTx(try makeEntry(allocator, 0xC0, 0x10, .{ .storage_read = &.{testSlot(0x50, 1)} }));
    try tracker.recordLocalTx(try makeEntry(allocator, 0xC1, 0x11, .{ .accounts_read = &.{0x60}, .storage_written = &.{testSlot(0x50, 1)} }));

    var diff = try makeDiff(allocator, &.{0x60}, &.{});
    defer diff.deinit(allocator);
    const plan = try tracker.planReplay(allocator, &diff);
    defer allocator.free(plan);
    try std.testing.expectEqualSlices(ReplayDisposition, &.{ .carry_forward, .reexecute }, plan);
}

test "planReplay preserves recorded order and clearLocalTxs frees entries" {
    const allocator = std.testing.allocator;
    var tracker = try RebaseTracker.init(allocator, "https://rpc.example", 100, true);
    defer tracker.deinit();
    const hashes = [_]u8{ 0xD3, 0xD1, 0xD2, 0xD0 };
    for (hashes, 0..) |h, i| {
        const touched: u8 = @intCast(0x70 + i);
        try tracker.recordLocalTx(try makeEntry(allocator, h, touched, .{ .accounts_written = &.{touched} }));
    }
    var diff = try makeDiff(allocator, &.{0x72}, &.{});
    defer diff.deinit(allocator);

    const plan = try tracker.planReplay(allocator, &diff);
    defer allocator.free(plan);
    try std.testing.expectEqual(hashes.len, plan.len);
    for (tracker.local_txs.items, hashes) |entry, h| {
        try std.testing.expectEqual(h, entry.tx_hash[0]);
    }
    try std.testing.expectEqualSlices(ReplayDisposition, &.{ .carry_forward, .carry_forward, .reexecute, .carry_forward }, plan);

    tracker.clearLocalTxs();
    try std.testing.expectEqual(@as(usize, 0), tracker.local_txs.items.len);
    const empty_plan = try tracker.planReplay(allocator, &diff);
    defer allocator.free(empty_plan);
    try std.testing.expectEqual(@as(usize, 0), empty_plan.len);
}

test "setRpcUrl replaces the URL and preserves follow and fork block" {
    const allocator = std.testing.allocator;
    var tracker = try RebaseTracker.init(allocator, "https://old.example", 42, true);
    defer tracker.deinit();

    try tracker.setRpcUrl("https://new.example");
    const url = try tracker.getUrlAlloc(allocator);
    defer allocator.free(url);
    try std.testing.expectEqualStrings("https://new.example", url);
    try std.testing.expect(tracker.follow);
    try std.testing.expectEqual(@as(u64, 42), tracker.current_fork_block);

    var pinned = try RebaseTracker.init(allocator, "https://old.example", 1, false);
    defer pinned.deinit();
    try pinned.setRpcUrl("https://other.example");
    try std.testing.expect(!pinned.follow);
}

const FakeUpstream = struct {
    changed_account: [20]u8,
    changed_slot: StorageSlotKey,
    account_queries: usize = 0,
    storage_queries: usize = 0,
    last_url: [64]u8 = undefined,
    last_url_len: usize = 0,

    fn hooks(self: *FakeUpstream) UpstreamRpcHooks {
        return .{
            .context = self,
            .fetch_block_number = fetchBlockNumber,
            .fetch_account_changed = fetchAccountChanged,
            .fetch_storage_changed = fetchStorageChanged,
        };
    }

    fn fetchBlockNumber(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8) anyerror!u64 {
        return 200;
    }

    fn fetchAccountChanged(ctx: ?*anyopaque, _: std.mem.Allocator, url: []const u8, addr: [20]u8, old_block: u64, new_block: u64) anyerror!bool {
        const self: *FakeUpstream = @ptrCast(@alignCast(ctx.?));
        try std.testing.expectEqual(@as(u64, 100), old_block);
        try std.testing.expectEqual(@as(u64, 200), new_block);
        @memcpy(self.last_url[0..url.len], url);
        self.last_url_len = url.len;
        self.account_queries += 1;
        return std.mem.eql(u8, &addr, &self.changed_account);
    }

    fn fetchStorageChanged(ctx: ?*anyopaque, _: std.mem.Allocator, _: []const u8, addr: [20]u8, slot: u256, _: u64, _: u64) anyerror!bool {
        const self: *FakeUpstream = @ptrCast(@alignCast(ctx.?));
        self.storage_queries += 1;
        return (StorageSlotKey{ .address = addr, .slot = slot }).eql(self.changed_slot);
    }
};

test "computeUpstreamDiff queries each touched key once and keeps changed ones" {
    const allocator = std.testing.allocator;
    var tracker = try RebaseTracker.init(allocator, "https://rpc.example", 100, true);
    defer tracker.deinit();
    try tracker.recordLocalTx(try makeEntry(allocator, 0xE0, 0x10, .{
        .accounts_read = &.{ 0x10, 0x20 },
        .accounts_written = &.{0x10},
        .storage_read = &.{testSlot(0x30, 1)},
        .storage_written = &.{testSlot(0x30, 2)},
    }));
    try tracker.recordLocalTx(try makeEntry(allocator, 0xE1, 0x11, .{
        .accounts_read = &.{0x20},
        .storage_read = &.{testSlot(0x30, 1)},
    }));

    var upstream = FakeUpstream{ .changed_account = testAddress(0x20), .changed_slot = testSlot(0x30, 2) };
    var diff = try tracker.computeUpstreamDiff(allocator, upstream.hooks(), 100, 200);
    defer diff.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), upstream.account_queries);
    try std.testing.expectEqual(@as(usize, 2), upstream.storage_queries);
    try std.testing.expectEqualStrings("https://rpc.example", upstream.last_url[0..upstream.last_url_len]);
    try std.testing.expectEqual(@as(usize, 1), diff.changed_accounts.items.len);
    try std.testing.expectEqualSlices(u8, &testAddress(0x20), &diff.changed_accounts.items[0]);
    try std.testing.expectEqual(@as(usize, 1), diff.changed_storage.items.len);
    try std.testing.expect(diff.changed_storage.items[0].eql(testSlot(0x30, 2)));

    const plan = try tracker.planReplay(allocator, &diff);
    defer allocator.free(plan);
    try std.testing.expectEqualSlices(ReplayDisposition, &.{ .reexecute, .reexecute }, plan);
}

const PollCounter = struct {
    count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn poll(ctx: ?*anyopaque) void {
        const self: *PollCounter = @ptrCast(@alignCast(ctx.?));
        _ = self.count.fetchAdd(1, .acq_rel);
    }

    fn waitFor(self: *PollCounter, target: usize) !void {
        var attempts: usize = 0;
        while (self.count.load(.acquire) < target) : (attempts += 1) {
            if (attempts > 5_000) return error.PollerDidNotRun;
            std.Thread.sleep(std.time.ns_per_ms);
        }
    }
};

test "polling thread starts, polls, stops, and restarts cleanly" {
    const allocator = std.testing.allocator;
    var tracker = try RebaseTracker.init(allocator, "https://rpc.example", 100, true);
    defer tracker.deinit();
    tracker.poll_interval_ms = 1;

    var counter = PollCounter{};
    try tracker.startPolling(&counter, PollCounter.poll);
    try std.testing.expectError(error.AlreadyPolling, tracker.startPolling(&counter, PollCounter.poll));
    try counter.waitFor(3);
    tracker.stopPolling();
    try std.testing.expect(tracker.worker_thread == null);

    const after_stop = counter.count.load(.acquire);
    std.Thread.sleep(10 * std.time.ns_per_ms);
    try std.testing.expectEqual(after_stop, counter.count.load(.acquire));

    // Stopping twice is a no-op; the tracker can restart.
    tracker.stopPolling();
    try tracker.startPolling(&counter, PollCounter.poll);
    try counter.waitFor(after_stop + 1);
    // deinit stops the running poller.
}

test "stopPolling wakes a poller sleeping on a long interval" {
    const allocator = std.testing.allocator;
    var tracker = try RebaseTracker.init(allocator, "https://rpc.example", 100, true);
    defer tracker.deinit();
    tracker.poll_interval_ms = 60 * 60 * 1000;

    var counter = PollCounter{};
    try tracker.startPolling(&counter, PollCounter.poll);
    var timer = try std.time.Timer.start();
    tracker.stopPolling();
    try std.testing.expect(timer.read() < 5 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(usize, 0), counter.count.load(.acquire));
}

test "startPolling refuses a tracker that does not follow" {
    const allocator = std.testing.allocator;
    var tracker = try RebaseTracker.init(allocator, "https://rpc.example", 100, false);
    defer tracker.deinit();
    var counter = PollCounter{};
    try std.testing.expectError(error.FollowDisabled, tracker.startPolling(&counter, PollCounter.poll));
}
