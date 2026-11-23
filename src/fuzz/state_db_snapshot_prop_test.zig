//! Stateful model-checking property and fuzz suite for the state layer:
//! `state_manager.StateManager`, `database.Database`, `host_adapter.HostAdapter`,
//! nested checkpoints and snapshots, and the derived account-trie state root.
//!
//! Part A runs an independent `ReferenceState` model in lockstep with the real
//! stack and asserts bit-exact agreement after every operation.
//! Part B drives the same machine from a byte stream under `std.testing.fuzz`.
//!
//! Tests named `known bug: ...` assert the correct behavior for defects found
//! while reading the code. They are skipped unless the environment variable
//! `ZEVM_FUZZ_KNOWN_BUGS` is set, because each one fails (or panics) until the
//! upstream defect is patched. See the fuzz log report for file:line details.

const std = @import("std");
const primitives = @import("primitives");
const state_manager = @import("state-manager");
const database = @import("../database/root.zig");
const host_adapter = @import("../host_adapter.zig");

// ---------------------------------------------------------------------------
// Finite universe shared by the lockstep property tests and the fuzz target.
// ---------------------------------------------------------------------------

const address_count = 6;
const slot_count = 6;
const max_code_len = 40;
const max_depth = 10;
const max_root_slots = 8;

const universe_addresses = [address_count]primitives.Address{
    .{ .bytes = [_]u8{0} ** 20 },
    .{ .bytes = [_]u8{0} ** 19 ++ [_]u8{0x01} },
    .{ .bytes = [_]u8{0xff} ** 20 },
    .{ .bytes = [_]u8{0x11} ++ [_]u8{0} ** 19 },
    .{ .bytes = [_]u8{0xab} ** 10 ++ [_]u8{0xcd} ** 10 },
    .{ .bytes = [_]u8{0x80} ++ [_]u8{0} ** 18 ++ [_]u8{0x01} },
};

/// An address no operation ever writes; it must stay absent and empty.
const outsider_address = primitives.Address{ .bytes = [_]u8{0x5a} ** 20 };

const slot_keys = [slot_count]u256{
    0,
    1,
    2,
    0xffff_ffff_ffff_ffff,
    @as(u256, 1) << 128,
    std.math.maxInt(u256),
};

/// A storage key no operation ever writes; it must always read zero.
const untouched_slot_key: u256 = 0xdead_beef;

fn knownBugReprosEnabled() bool {
    return std.process.hasEnvVarConstant("ZEVM_FUZZ_KNOWN_BUGS");
}

fn codeHash(code: []const u8) [32]u8 {
    if (code.len == 0) return primitives.State.EMPTY_CODE_HASH;
    var out: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(code, &out, .{});
    return out;
}

/// Storage root computed straight from (key, value) pairs, without going
/// through StateManager. Zero values are not part of the storage trie.
fn expectedStorageRoot(keys: []const u256, values: []const u256) ![32]u8 {
    const allocator = std.testing.allocator;
    var key_bytes: [max_root_slots][32]u8 = undefined;
    var key_slices: [max_root_slots][]const u8 = undefined;
    var value_slices: [max_root_slots][]const u8 = undefined;
    var count: usize = 0;
    defer {
        for (value_slices[0..count]) |encoded| allocator.free(encoded);
    }

    for (keys, values) |key, value| {
        if (value == 0) continue;
        std.mem.writeInt(u256, &key_bytes[count], key, .big);
        key_slices[count] = &key_bytes[count];
        value_slices[count] = try primitives.Rlp.encode(allocator, value);
        count += 1;
    }

    if (count == 0) return primitives.State.EMPTY_TRIE_ROOT;
    return try primitives.TrieHash.secure_trie_root(allocator, key_slices[0..count], value_slices[0..count]);
}

fn expectTrieLeaf(
    db: *database.Database,
    address: primitives.Address,
    nonce: u64,
    balance: u256,
    code: []const u8,
    storage_root: [32]u8,
) !void {
    const leaf = (try db.accounts.get(std.testing.allocator, address)) orelse return error.MissingTrieLeaf;
    try std.testing.expectEqual(nonce, leaf.nonce);
    try std.testing.expectEqual(balance, leaf.balance);
    const expected_code_hash = codeHash(code);
    try std.testing.expectEqualSlices(u8, &expected_code_hash, &leaf.code_hash);
    try std.testing.expectEqualSlices(u8, &storage_root, &leaf.storage_root);
}

fn expectDepth(state: *state_manager.StateManager, depth: usize) !void {
    try std.testing.expectEqual(depth, state.journaled_state.account_cache.checkpoints.items.len);
    try std.testing.expectEqual(depth, state.journaled_state.storage_cache.checkpoints.items.len);
    try std.testing.expectEqual(depth, state.journaled_state.contract_cache.checkpoints.items.len);
}

fn interestingU256(random: std.Random) u256 {
    return switch (random.uintLessThan(u8, 8)) {
        0 => 0,
        1 => 1,
        2 => std.math.maxInt(u256),
        3 => @as(u256, 1) << 255,
        4 => random.int(u8),
        5 => random.int(u64),
        6 => @as(u256, random.int(u64)) << 192,
        else => random.int(u256),
    };
}

fn nonZeroU256(random: std.Random) u256 {
    const value = interestingU256(random);
    return if (value == 0) 1 else value;
}

fn interestingU64(random: std.Random) u64 {
    return switch (random.uintLessThan(u8, 4)) {
        0 => 0,
        1 => 1,
        2 => std.math.maxInt(u64),
        else => random.int(u64),
    };
}

// ---------------------------------------------------------------------------
// ReferenceState: independent shadow model.
//
// The model is a dense map over the finite universe (address index -> account,
// slot index -> value) plus a stack of whole-state frames for checkpoints. It
// shares no code with StateManager: a revert pops a frame, a commit drops one.
// ---------------------------------------------------------------------------

const ModelAccount = struct {
    /// Mirrors presence in the account cache (any balance or nonce write).
    in_account_cache: bool = false,
    balance: u256 = 0,
    nonce: u64 = 0,
    /// Mirrors presence in the contract cache (any code write, even empty).
    in_contract_cache: bool = false,
    code_len: usize = 0,
    code: [max_code_len]u8 = [_]u8{0} ** max_code_len,
    /// Mirrors presence in the storage cache (any slot write, even zero).
    in_storage_cache: bool = false,
    slots: [slot_count]u256 = [_]u256{0} ** slot_count,

    fn codeSlice(self: *const ModelAccount) []const u8 {
        return self.code[0..self.code_len];
    }

    fn exists(self: *const ModelAccount) bool {
        return !self.isEmpty();
    }

    fn isEmpty(self: *const ModelAccount) bool {
        return self.balance == 0 and self.nonce == 0 and self.code_len == 0;
    }
};

const ModelState = struct {
    accounts: [address_count]ModelAccount = [_]ModelAccount{.{}} ** address_count,
};

const SnapshotRecord = struct {
    id: u64,
    depth: usize,
};

const ReferenceState = struct {
    current: ModelState = .{},
    frames: std.ArrayList(ModelState) = .empty,
    snapshots: std.ArrayList(SnapshotRecord) = .empty,
    next_snapshot_id: u64 = 0,

    fn deinit(self: *ReferenceState, allocator: std.mem.Allocator) void {
        self.frames.deinit(allocator);
        self.snapshots.deinit(allocator);
    }

    fn depth(self: *const ReferenceState) usize {
        return self.frames.items.len;
    }

    fn checkpoint(self: *ReferenceState, allocator: std.mem.Allocator) !void {
        try self.frames.append(allocator, self.current);
    }

    fn revert(self: *ReferenceState) void {
        if (self.frames.pop()) |frame| self.current = frame;
        self.dropConsumedSnapshots();
    }

    fn commit(self: *ReferenceState) void {
        _ = self.frames.pop();
        self.dropConsumedSnapshots();
    }

    fn dropConsumedSnapshots(self: *ReferenceState) void {
        const current_depth = self.depth();
        var index: usize = 0;
        while (index < self.snapshots.items.len) {
            if (self.snapshots.items[index].depth >= current_depth) {
                _ = self.snapshots.swapRemove(index);
            } else {
                index += 1;
            }
        }
    }

    fn snapshot(self: *ReferenceState, allocator: std.mem.Allocator) !u64 {
        const id = self.next_snapshot_id;
        try self.snapshots.append(allocator, .{ .id = id, .depth = self.depth() });
        errdefer _ = self.snapshots.pop();
        try self.checkpoint(allocator);
        self.next_snapshot_id += 1;
        return id;
    }

    fn snapshotDepth(self: *const ReferenceState, id: u64) ?usize {
        for (self.snapshots.items) |record| {
            if (record.id == id) return record.depth;
        }
        return null;
    }

    /// Multi-level revert: unwind every frame above the snapshot, then forget
    /// the snapshot and all younger ones.
    fn revertToSnapshot(self: *ReferenceState, id: u64) void {
        const target = self.snapshotDepth(id) orelse return;
        while (self.depth() > target) self.revert();

        var index: usize = 0;
        while (index < self.snapshots.items.len) {
            if (self.snapshots.items[index].id >= id) {
                _ = self.snapshots.swapRemove(index);
            } else {
                index += 1;
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Operations and the lockstep machine.
// ---------------------------------------------------------------------------

/// Which layer performs a write.
const Route = enum(u8) {
    /// `StateManager` method on `Database.state`.
    state,
    /// `HostAdapter` error-returning method.
    adapter,
    /// `guillotine_mini.HostInterface` vtable call.
    vtable,
};

const Op = union(enum) {
    set_balance: struct { account: usize, value: u256, route: Route },
    set_nonce: struct { account: usize, value: u64, route: Route },
    set_code: struct { account: usize, code: [max_code_len]u8, len: usize, route: Route },
    /// setCode(address, getCode(address)): the source slice aliases the cache.
    realias_code: struct { account: usize },
    set_storage: struct { account: usize, slot: usize, value: u256, route: Route },
    delete_account: struct { account: usize, through_vtable: bool },
    checkpoint,
    revert,
    commit,
    snapshot,
    revert_to_snapshot: struct { pick: u64 },
    revert_many: struct { levels: usize },
    trie_check: struct { order_seed: u64 },
};

const Machine = struct {
    db: *database.Database,
    adapter: *host_adapter.HostAdapter,
    changes: *std.ArrayList(host_adapter.HostAdapter.BalanceChange),
    reference: ReferenceState = .{},
    expected_change_count: usize = 0,
    depth_limit: usize = max_depth,
    trie_checks_left: usize = std.math.maxInt(usize),
    /// Counts revertToSnapshot calls withheld because they would hit the
    /// known usize underflow in StateManager.revertToSnapshot.
    stale_snapshot_skips: usize = 0,

    fn deinit(self: *Machine) void {
        self.reference.deinit(std.testing.allocator);
    }

    fn expectBalanceChange(self: *Machine, address: primitives.Address, before: u256, after: u256) !void {
        if (before == after) {
            try std.testing.expectEqual(self.expected_change_count, self.changes.items.len);
            return;
        }
        self.expected_change_count += 1;
        try std.testing.expectEqual(self.expected_change_count, self.changes.items.len);
        const last = self.changes.items[self.changes.items.len - 1];
        try std.testing.expectEqualSlices(u8, &address.bytes, &last.address.bytes);
        try std.testing.expectEqual(before, last.before);
        try std.testing.expectEqual(after, last.after);
    }

    fn apply(self: *Machine, op: Op) !void {
        const allocator = std.testing.allocator;
        const host = self.adapter.hostInterface();

        switch (op) {
            .set_balance => |args| {
                const address = universe_addresses[args.account];
                const account = &self.reference.current.accounts[args.account];
                switch (args.route) {
                    .state => try self.db.state.setBalance(address, args.value),
                    .adapter => {
                        try self.adapter.setBalance(address, args.value);
                        try self.expectBalanceChange(address, account.balance, args.value);
                    },
                    .vtable => {
                        host.setBalance(address, args.value);
                        try self.expectBalanceChange(address, account.balance, args.value);
                    },
                }
                account.in_account_cache = true;
                account.balance = args.value;
            },
            .set_nonce => |args| {
                const address = universe_addresses[args.account];
                const account = &self.reference.current.accounts[args.account];
                switch (args.route) {
                    .state => try self.db.state.setNonce(address, args.value),
                    .adapter => try self.adapter.setNonce(address, args.value),
                    .vtable => host.setNonce(address, args.value),
                }
                account.in_account_cache = true;
                account.nonce = args.value;
            },
            .set_code => |args| {
                const address = universe_addresses[args.account];
                const account = &self.reference.current.accounts[args.account];
                const code = args.code[0..args.len];
                switch (args.route) {
                    .state => try self.db.state.setCode(address, code),
                    .adapter => try self.adapter.setCode(address, code),
                    .vtable => host.setCode(address, code),
                }
                account.in_contract_cache = true;
                account.code = [_]u8{0} ** max_code_len;
                @memcpy(account.code[0..args.len], code);
                account.code_len = args.len;
            },
            .realias_code => |args| {
                const address = universe_addresses[args.account];
                const account = &self.reference.current.accounts[args.account];
                const current = try self.db.state.getCode(address);
                try self.db.state.setCode(address, current);
                account.in_contract_cache = true;
            },
            .set_storage => |args| {
                const address = universe_addresses[args.account];
                const account = &self.reference.current.accounts[args.account];
                const key = slot_keys[args.slot];
                switch (args.route) {
                    .state => try self.db.state.setStorage(address, key, args.value),
                    .adapter => try self.adapter.setStorage(address, key, args.value),
                    .vtable => host.setStorage(address, key, args.value),
                }
                account.in_storage_cache = true;
                account.slots[args.slot] = args.value;
            },
            .delete_account => |args| {
                const address = universe_addresses[args.account];
                const account = &self.reference.current.accounts[args.account];
                const before = account.balance;
                if (args.through_vtable) {
                    host.deleteAccount(address);
                } else {
                    try self.adapter.deleteAccount(address);
                }
                try self.expectBalanceChange(address, before, 0);
                account.* = .{};
            },
            .checkpoint => {
                if (self.reference.depth() >= self.depth_limit) return;
                try self.reference.checkpoint(allocator);
                try self.db.state.checkpoint();
            },
            .revert => {
                self.db.state.revert();
                self.reference.revert();
            },
            .commit => {
                self.db.state.commit();
                self.reference.commit();
            },
            .snapshot => {
                if (self.reference.depth() >= self.depth_limit) return;
                const expected_id = try self.reference.snapshot(allocator);
                const actual_id = try self.db.state.snapshot();
                try std.testing.expectEqual(expected_id, actual_id);
            },
            .revert_to_snapshot => |args| {
                const id = args.pick % (self.reference.next_snapshot_id + 2);
                const target = self.reference.snapshotDepth(id) orelse {
                    try std.testing.expectError(error.InvalidSnapshot, self.db.state.revertToSnapshot(id));
                    return;
                };
                if (target > self.reference.depth()) {
                    // Known bug: StateManager.revertToSnapshot computes
                    // `current_depth - target_depth` in usize and underflows
                    // when plain revert()/commit() already unwound past the
                    // snapshot. Withheld here so the suite does not panic;
                    // asserted by the gated "known bug" test below.
                    self.stale_snapshot_skips += 1;
                    return;
                }
                try self.db.state.revertToSnapshot(id);
                self.reference.revertToSnapshot(id);
            },
            .revert_many => |args| {
                var level: usize = 0;
                while (level < args.levels) : (level += 1) {
                    self.db.state.revert();
                    self.reference.revert();
                }
            },
            .trie_check => |args| {
                if (self.trie_checks_left == 0) return;
                self.trie_checks_left -= 1;
                try self.checkTrie(args.order_seed);
            },
        }
    }

    /// Bit-exact agreement on every balance, nonce, code byte, code hash and
    /// storage slot, through all three read paths, plus cache membership and
    /// checkpoint depth.
    fn check(self: *Machine) !void {
        const host = self.adapter.hostInterface();
        const journal = &self.db.state.journaled_state;

        try expectDepth(&self.db.state, self.reference.depth());

        var cached_accounts: usize = 0;
        var cached_contracts: usize = 0;
        for (universe_addresses, 0..) |address, index| {
            const expected = &self.reference.current.accounts[index];

            try std.testing.expectEqual(expected.balance, try self.db.state.getBalance(address));
            try std.testing.expectEqual(expected.balance, try self.adapter.getBalance(address));
            try std.testing.expectEqual(expected.balance, host.getBalance(address));

            try std.testing.expectEqual(expected.nonce, try self.db.state.getNonce(address));
            try std.testing.expectEqual(expected.nonce, try self.adapter.getNonce(address));
            try std.testing.expectEqual(expected.nonce, host.getNonce(address));

            const actual_code = try self.db.state.getCode(address);
            try std.testing.expectEqualSlices(u8, expected.codeSlice(), actual_code);
            try std.testing.expectEqualSlices(u8, expected.codeSlice(), try self.adapter.getCode(address));
            try std.testing.expectEqualSlices(u8, expected.codeSlice(), host.getCode(address));
            const expected_code_hash = codeHash(expected.codeSlice());
            var actual_code_hash: [32]u8 = undefined;
            std.crypto.hash.sha3.Keccak256.hash(actual_code, &actual_code_hash, .{});
            try std.testing.expectEqualSlices(u8, &expected_code_hash, &actual_code_hash);

            for (slot_keys, 0..) |key, slot_index| {
                const expected_value = expected.slots[slot_index];
                try std.testing.expectEqual(expected_value, try self.db.state.getStorage(address, key));
                try std.testing.expectEqual(expected_value, try self.adapter.getStorage(address, key));
                try std.testing.expectEqual(expected_value, host.getStorage(address, key));
            }
            try std.testing.expectEqual(@as(u256, 0), try self.db.state.getStorage(address, untouched_slot_key));

            try std.testing.expectEqual(expected.in_account_cache, journal.account_cache.has(address));
            try std.testing.expectEqual(expected.in_contract_cache, journal.contract_cache.has(address));
            try std.testing.expectEqual(expected.in_storage_cache, journal.storage_cache.cache.contains(address));
            try std.testing.expectEqual(expected.exists(), try self.adapter.accountExists(address));
            try std.testing.expectEqual(expected.exists(), host.accountExists(address));
            try std.testing.expectEqual(expected.isEmpty(), try self.adapter.accountIsEmpty(address));

            if (expected.in_account_cache) cached_accounts += 1;
            if (expected.in_contract_cache) cached_contracts += 1;
        }

        try std.testing.expectEqual(cached_accounts, journal.account_cache.count());
        try std.testing.expectEqual(cached_contracts, journal.contract_cache.count());

        try std.testing.expectEqual(@as(u256, 0), try self.db.state.getBalance(outsider_address));
        try std.testing.expectEqual(@as(u64, 0), try self.db.state.getNonce(outsider_address));
        try std.testing.expectEqual(@as(usize, 0), (try self.db.state.getCode(outsider_address)).len);
        try std.testing.expect(!try self.adapter.accountExists(outsider_address));
        try std.testing.expect(try self.adapter.accountIsEmpty(outsider_address));

        try std.testing.expectEqual(self.expected_change_count, self.changes.items.len);
        try std.testing.expect(self.adapter.getHostError() == null);
    }

    /// Rebuild the live account trie from the current StateManager view, check
    /// every leaf against the model, and require the same 32-byte root as a
    /// fresh Database populated straight from the model in a shuffled order.
    ///
    /// The trie is cleared first because Database has no way to drop leaves of
    /// reverted or deleted accounts (see the gated "known bug" tests).
    fn checkTrie(self: *Machine, order_seed: u64) !void {
        const allocator = std.testing.allocator;
        self.db.accounts.account_trie.clear();
        for (universe_addresses) |address| {
            try self.db.syncAccountToTrie(allocator, address);
        }

        for (universe_addresses, 0..) |address, index| {
            const expected = &self.reference.current.accounts[index];
            const storage_root = try expectedStorageRoot(&slot_keys, &expected.slots);
            try expectTrieLeaf(self.db, address, expected.nonce, expected.balance, expected.codeSlice(), storage_root);
        }

        const live_root = self.db.accounts.stateRoot() orelse return error.MissingStateRoot;
        const rebuilt_root = try rootFromModel(&self.reference.current, order_seed);
        try std.testing.expectEqualSlices(u8, &rebuilt_root, &live_root);
    }
};

/// State root of a fresh Database that only ever saw the model's final values.
fn rootFromModel(model: *const ModelState, order_seed: u64) ![32]u8 {
    const allocator = std.testing.allocator;
    var db = try database.Database.init(allocator, null);
    defer db.deinit(allocator);

    var prng = std.Random.DefaultPrng.init(order_seed);
    const random = prng.random();
    var order: [address_count]usize = undefined;
    for (&order, 0..) |*entry, index| entry.* = index;

    random.shuffle(usize, &order);
    for (order) |index| {
        const account = &model.accounts[index];
        const address = universe_addresses[index];
        if (account.balance != 0) try db.state.setBalance(address, account.balance);
        if (account.nonce != 0) try db.state.setNonce(address, account.nonce);
        if (account.code_len != 0) try db.state.setCode(address, account.codeSlice());
        for (slot_keys, 0..) |key, slot_index| {
            const value = account.slots[slot_index];
            if (value != 0) try db.state.setStorage(address, key, value);
        }
    }

    random.shuffle(usize, &order);
    for (order) |index| {
        try db.syncAccountToTrie(allocator, universe_addresses[index]);
    }
    return db.accounts.stateRoot() orelse error.MissingStateRoot;
}

fn randomCode(random: std.Random, code: *[max_code_len]u8) usize {
    code.* = [_]u8{0} ** max_code_len;
    const len: usize = switch (random.uintLessThan(u8, 5)) {
        0 => 0,
        1 => 1,
        2 => max_code_len,
        else => random.uintLessThan(usize, max_code_len + 1),
    };
    random.bytes(code[0..len]);
    return len;
}

fn randomStructuralOp(random: std.Random) Op {
    return switch (random.uintLessThan(u8, 12)) {
        0...3 => .checkpoint,
        4, 5 => .snapshot,
        6, 7 => .revert,
        8 => .commit,
        9 => .{ .revert_to_snapshot = .{ .pick = random.int(u64) } },
        10 => .{ .revert_many = .{ .levels = 2 + random.uintLessThan(usize, 3) } },
        else => .commit,
    };
}

fn randomOp(random: std.Random, structural_bias: bool) Op {
    if (structural_bias and random.boolean()) return randomStructuralOp(random);

    const account = random.uintLessThan(usize, address_count);
    const route = random.enumValue(Route);
    switch (random.uintLessThan(u8, 32)) {
        0...4 => return .{ .set_balance = .{ .account = account, .value = interestingU256(random), .route = route } },
        5...7 => return .{ .set_nonce = .{ .account = account, .value = interestingU64(random), .route = route } },
        8...10 => {
            var code: [max_code_len]u8 = undefined;
            const len = randomCode(random, &code);
            return .{ .set_code = .{ .account = account, .code = code, .len = len, .route = route } };
        },
        11 => return .{ .realias_code = .{ .account = account } },
        12...18 => {
            // One write in three stores zero, which must behave as a deletion.
            const value: u256 = if (random.uintLessThan(u8, 3) == 0) 0 else interestingU256(random);
            return .{ .set_storage = .{
                .account = account,
                .slot = random.uintLessThan(usize, slot_count),
                .value = value,
                .route = route,
            } };
        },
        19, 20 => return .{ .delete_account = .{ .account = account, .through_vtable = random.boolean() } },
        else => return randomStructuralOp(random),
    }
}

fn runLockstep(seed: u64, steps: usize, depth_limit: usize, structural_bias: bool, trie_interval: usize) !void {
    const allocator = std.testing.allocator;
    var db = try database.Database.init(allocator, null);
    defer db.deinit(allocator);
    var changes: std.ArrayList(host_adapter.HostAdapter.BalanceChange) = .empty;
    defer changes.deinit(allocator);
    var adapter = host_adapter.HostAdapter{
        .state = &db.state,
        .balance_change_allocator = allocator,
        .balance_changes = &changes,
    };
    var machine = Machine{ .db = &db, .adapter = &adapter, .changes = &changes, .depth_limit = depth_limit };
    defer machine.deinit();

    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    try machine.check();
    var step: usize = 0;
    while (step < steps) : (step += 1) {
        try machine.apply(randomOp(random, structural_bias));
        try machine.check();
        if (trie_interval != 0 and (step + 1) % trie_interval == 0) {
            try machine.checkTrie(seed ^ @as(u64, step));
        }
    }
    if (trie_interval != 0) try machine.checkTrie(seed);
    // The Database and StateManager are torn down at whatever checkpoint depth
    // the walk ended on; std.testing.allocator reports any frame that leaks.
}

// ---------------------------------------------------------------------------
// Part A: deterministic property tests.
// ---------------------------------------------------------------------------

test "property: StateManager, Database and HostAdapter match ReferenceState after every step" {
    const seeds = [_]u64{
        0x0000_0000_0000_0001,
        0x5eed_0000_c0ff_ee01,
        0xdead_beef_cafe_f00d,
        0x0123_4567_89ab_cdef,
        0xffff_ffff_ffff_ffff,
        0x9e37_79b9_7f4a_7c15,
    };
    for (seeds) |seed| {
        try runLockstep(seed, 240, max_depth, false, 8);
    }
}

test "property: arbitrary nested snapshot, revert and commit trees never leak or diverge" {
    var seed: u64 = 0x7ee5_0000;
    while (seed < 0x7ee5_0000 + 24) : (seed += 1) {
        try runLockstep(seed, 200, 20, true, 0);
    }
}

test "property: hand-written nested checkpoints revert single and multiple levels exactly" {
    const allocator = std.testing.allocator;
    var db = try database.Database.init(allocator, null);
    defer db.deinit(allocator);
    var changes: std.ArrayList(host_adapter.HostAdapter.BalanceChange) = .empty;
    defer changes.deinit(allocator);
    var adapter = host_adapter.HostAdapter{
        .state = &db.state,
        .balance_change_allocator = allocator,
        .balance_changes = &changes,
    };
    var machine = Machine{ .db = &db, .adapter = &adapter, .changes = &changes };
    defer machine.deinit();

    var code = [_]u8{0} ** max_code_len;
    code[0] = 0x60;
    code[1] = 0x00;
    code[2] = 0xfd;

    const program = [_]Op{
        .{ .set_balance = .{ .account = 3, .value = 100, .route = .vtable } },
        .{ .set_storage = .{ .account = 3, .slot = 1, .value = 7, .route = .adapter } },
        .checkpoint, // depth 1
        .{ .set_balance = .{ .account = 3, .value = 200, .route = .adapter } },
        .{ .set_code = .{ .account = 4, .code = code, .len = 3, .route = .state } },
        .snapshot, // id 0, depth 2
        .{ .set_storage = .{ .account = 3, .slot = 1, .value = 0, .route = .vtable } },
        .{ .set_nonce = .{ .account = 3, .value = std.math.maxInt(u64), .route = .state } },
        .checkpoint, // depth 3
        .{ .delete_account = .{ .account = 3, .through_vtable = true } },
        .{ .set_storage = .{ .account = 2, .slot = 5, .value = std.math.maxInt(u256), .route = .state } },
        .checkpoint, // depth 4
        .{ .set_code = .{ .account = 3, .code = code, .len = 1, .route = .vtable } },
        .revert, // single level: back to depth 3, account 3 deleted
        .commit, // depth 2 keeps the delete
        .{ .trie_check = .{ .order_seed = 1 } },
        .{ .revert_to_snapshot = .{ .pick = 0 } }, // multi-level: depth 1
        .{ .trie_check = .{ .order_seed = 2 } },
        .{ .revert_to_snapshot = .{ .pick = 0 } }, // id 0 is gone: InvalidSnapshot
        .checkpoint, // depth 2
        .checkpoint, // depth 3
        .{ .set_balance = .{ .account = 0, .value = 1, .route = .adapter } },
        .{ .revert_many = .{ .levels = 3 } }, // back to the state before depth 1
        .{ .trie_check = .{ .order_seed = 3 } },
        .revert, // no-op at depth 0
        .commit, // no-op at depth 0
    };

    for (program) |op| {
        try machine.apply(op);
        try machine.check();
    }

    try expectDepth(&db.state, 0);
    try std.testing.expectEqual(@as(u256, 100), try db.state.getBalance(universe_addresses[3]));
    try std.testing.expectEqual(@as(u256, 7), try db.state.getStorage(universe_addresses[3], slot_keys[1]));
    try std.testing.expectEqual(@as(u64, 0), try db.state.getNonce(universe_addresses[3]));
    try std.testing.expectEqual(@as(usize, 0), (try db.state.getCode(universe_addresses[4])).len);
    try std.testing.expect(!try adapter.accountExists(universe_addresses[2]));
}

// --- Path-independent state root -------------------------------------------

const path_account_max = 6;
const path_slot_max = 4;
const path_mutation_max = path_account_max * (3 + path_slot_max);

const PathAccount = struct {
    address: primitives.Address,
    balance: u256,
    nonce: u64,
    code: [max_code_len]u8,
    code_len: usize,
    slot_keys: [path_slot_max]u256,
    slot_values: [path_slot_max]u256,
    slot_count: usize,

    fn codeSlice(self: *const PathAccount) []const u8 {
        return self.code[0..self.code_len];
    }

    fn storageRoot(self: *const PathAccount) ![32]u8 {
        return expectedStorageRoot(self.slot_keys[0..self.slot_count], self.slot_values[0..self.slot_count]);
    }
};

const PathField = enum { balance, nonce, code, storage };

const PathMutation = struct {
    account: usize,
    field: PathField,
    slot: usize,
};

/// Final-state account. Byte 0 of the address is the index, so accounts are
/// distinct; the low byte of every real slot key is below 0x80.
fn randomPathAccount(random: std.Random, index: u8) PathAccount {
    var account: PathAccount = undefined;
    random.bytes(&account.address.bytes);
    account.address.bytes[0] = index;
    account.balance = interestingU256(random);
    account.nonce = interestingU64(random);
    account.code_len = randomCode(random, &account.code);
    account.slot_count = random.uintLessThan(usize, path_slot_max + 1);
    for (&account.slot_keys, &account.slot_values, 0..) |*key, *value, slot_index| {
        const low: u256 = slot_index;
        key.* = if (random.boolean()) low else (random.int(u256) & ~@as(u256, 0xff)) | low;
        value.* = nonZeroU256(random);
    }
    // Under EIP-161, completely empty accounts are omitted from the state trie.
    if (account.balance == 0 and account.nonce == 0 and account.code_len == 0 and account.slot_count == 0) {
        account.balance = 1;
    }
    return account;
}

/// A slot key that no final-state account uses (low byte has bit 7 set).
fn junkSlotKey(random: std.Random) u256 {
    return (random.int(u256) & ~@as(u256, 0xff)) | 0x80 | @as(u256, random.uintLessThan(u8, 0x80));
}

/// An address that no final-state account uses (byte 0 is 0xee).
fn junkAddress(random: std.Random) primitives.Address {
    var address: primitives.Address = undefined;
    random.bytes(&address.bytes);
    address.bytes[0] = 0xee;
    return address;
}

fn writePathField(
    db: *database.Database,
    adapter: *host_adapter.HostAdapter,
    route: Route,
    account: *const PathAccount,
    mutation: PathMutation,
) !void {
    const host = adapter.hostInterface();
    switch (mutation.field) {
        .balance => switch (route) {
            .state => try db.state.setBalance(account.address, account.balance),
            .adapter => try adapter.setBalance(account.address, account.balance),
            .vtable => host.setBalance(account.address, account.balance),
        },
        .nonce => switch (route) {
            .state => try db.state.setNonce(account.address, account.nonce),
            .adapter => try adapter.setNonce(account.address, account.nonce),
            .vtable => host.setNonce(account.address, account.nonce),
        },
        .code => switch (route) {
            .state => try db.state.setCode(account.address, account.codeSlice()),
            .adapter => try adapter.setCode(account.address, account.codeSlice()),
            .vtable => host.setCode(account.address, account.codeSlice()),
        },
        .storage => {
            const key = account.slot_keys[mutation.slot];
            const value = account.slot_values[mutation.slot];
            switch (route) {
                .state => try db.state.setStorage(account.address, key, value),
                .adapter => try adapter.setStorage(account.address, key, value),
                .vtable => host.setStorage(account.address, key, value),
            }
        },
    }
    try std.testing.expect(adapter.getHostError() == null);
}

/// Wrong-valued writes against real and junk accounts. Callers always revert.
fn scribble(
    db: *database.Database,
    adapter: *host_adapter.HostAdapter,
    random: std.Random,
    accounts: []const PathAccount,
) !void {
    const junk_code = [_]u8{ 0xde, 0xad, 0xc0, 0xde };
    var writes = 1 + random.uintLessThan(usize, 4);
    while (writes > 0) : (writes -= 1) {
        const account = &accounts[random.uintLessThan(usize, accounts.len)];
        switch (random.uintLessThan(u8, 8)) {
            0 => try adapter.setBalance(account.address, random.int(u256)),
            1 => try db.state.setNonce(account.address, random.int(u64)),
            2 => adapter.hostInterface().setCode(account.address, &junk_code),
            3 => try adapter.setStorage(account.address, junkSlotKey(random), random.int(u256)),
            4 => {
                if (account.slot_count > 0) {
                    const slot = random.uintLessThan(usize, account.slot_count);
                    try db.state.setStorage(account.address, account.slot_keys[slot], if (random.boolean()) 0 else random.int(u256));
                }
            },
            5 => try adapter.deleteAccount(account.address),
            6 => try db.state.setStorage(junkAddress(random), junkSlotKey(random), 1),
            else => try db.state.setBalance(junkAddress(random), random.int(u256)),
        }
    }
}

/// Junk that must leave no trace: reverted checkpoints (single level, nested
/// with an inner commit, multi-level through a snapshot) and a transient slot
/// written nonzero and then back to zero without any revert.
fn injectJunk(
    db: *database.Database,
    adapter: *host_adapter.HostAdapter,
    random: std.Random,
    accounts: []const PathAccount,
) !void {
    switch (random.uintLessThan(u8, 4)) {
        0 => {
            try db.state.checkpoint();
            try scribble(db, adapter, random, accounts);
            db.state.revert();
        },
        1 => {
            try db.state.checkpoint();
            try scribble(db, adapter, random, accounts);
            try db.state.checkpoint();
            try scribble(db, adapter, random, accounts);
            db.state.commit();
            db.state.revert();
        },
        2 => {
            const id = try db.state.snapshot();
            try scribble(db, adapter, random, accounts);
            try db.state.checkpoint();
            try scribble(db, adapter, random, accounts);
            try db.state.checkpoint();
            try scribble(db, adapter, random, accounts);
            try db.state.revertToSnapshot(id);
        },
        else => {
            const account = &accounts[random.uintLessThan(usize, accounts.len)];
            const key = junkSlotKey(random);
            try adapter.setStorage(account.address, key, nonZeroU256(random));
            try adapter.setStorage(account.address, key, 0);
        },
    }
    try std.testing.expect(adapter.getHostError() == null);
}

fn expectPathState(db: *database.Database, accounts: []const PathAccount) !void {
    for (accounts) |*account| {
        try std.testing.expectEqual(account.balance, try db.state.getBalance(account.address));
        try std.testing.expectEqual(account.nonce, try db.state.getNonce(account.address));
        try std.testing.expectEqualSlices(u8, account.codeSlice(), try db.state.getCode(account.address));
        for (account.slot_keys[0..account.slot_count], account.slot_values[0..account.slot_count]) |key, value| {
            try std.testing.expectEqual(value, try db.state.getStorage(account.address, key));
        }
        try expectTrieLeaf(db, account.address, account.nonce, account.balance, account.codeSlice(), try account.storageRoot());
    }
}

test "property: state_root is independent of mutation order, routing and reverted junk" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x7a7e_4007_0001);
    const random = prng.random();

    var iteration: usize = 0;
    while (iteration < 220) : (iteration += 1) {
        var accounts_buffer: [path_account_max]PathAccount = undefined;
        const account_count = 1 + random.uintLessThan(usize, path_account_max);
        for (accounts_buffer[0..account_count], 0..) |*account, index| {
            account.* = randomPathAccount(random, @intCast(index));
        }
        const accounts = accounts_buffer[0..account_count];

        var mutations_buffer: [path_mutation_max]PathMutation = undefined;
        var mutation_count: usize = 0;
        for (accounts, 0..) |*account, index| {
            for ([_]PathField{ .balance, .nonce, .code }) |field| {
                mutations_buffer[mutation_count] = .{ .account = index, .field = field, .slot = 0 };
                mutation_count += 1;
            }
            var slot: usize = 0;
            while (slot < account.slot_count) : (slot += 1) {
                mutations_buffer[mutation_count] = .{ .account = index, .field = .storage, .slot = slot };
                mutation_count += 1;
            }
        }
        const mutations = mutations_buffer[0..mutation_count];

        // Path A: generation order, StateManager writes, no junk, explicit
        // per-account sync in index order. Empty code is never written.
        var db_a = try database.Database.init(allocator, null);
        defer db_a.deinit(allocator);
        var adapter_a = host_adapter.HostAdapter{ .state = &db_a.state };
        for (mutations) |mutation| {
            const account = &accounts[mutation.account];
            if (mutation.field == .code and account.code_len == 0) continue;
            try writePathField(&db_a, &adapter_a, .state, account, mutation);
        }
        for (accounts) |*account| try db_a.syncAccountToTrie(allocator, account.address);
        try expectPathState(&db_a, accounts);
        const root_a = db_a.accounts.stateRoot() orelse return error.MissingStateRoot;

        // Path B: shuffled order, random routing, junk writes inserted and
        // reverted between real mutations, real mutations sometimes wrapped in
        // a committed checkpoint, bulk sync in hash-map iteration order.
        var db_b = try database.Database.init(allocator, null);
        defer db_b.deinit(allocator);
        var adapter_b = host_adapter.HostAdapter{ .state = &db_b.state };
        random.shuffle(PathMutation, mutations);
        for (mutations) |mutation| {
            if (random.boolean()) try injectJunk(&db_b, &adapter_b, random, accounts);
            const wrap = random.uintLessThan(u8, 4) == 0;
            if (wrap) try db_b.state.checkpoint();
            try writePathField(&db_b, &adapter_b, random.enumValue(Route), &accounts[mutation.account], mutation);
            if (wrap) db_b.state.commit();
        }
        try injectJunk(&db_b, &adapter_b, random, accounts);
        try expectDepth(&db_b.state, 0);
        try db_b.syncCachedAccountsToTrie(allocator);
        try expectPathState(&db_b, accounts);
        const root_b = db_b.accounts.stateRoot() orelse return error.MissingStateRoot;

        // Path C: reverse of B's order through the vtable, reverse sync order.
        var db_c = try database.Database.init(allocator, null);
        defer db_c.deinit(allocator);
        var adapter_c = host_adapter.HostAdapter{ .state = &db_c.state };
        var remaining = mutations.len;
        while (remaining > 0) : (remaining -= 1) {
            const mutation = mutations[remaining - 1];
            try writePathField(&db_c, &adapter_c, .vtable, &accounts[mutation.account], mutation);
        }
        remaining = accounts.len;
        while (remaining > 0) : (remaining -= 1) {
            try db_c.syncAccountToTrie(allocator, accounts[remaining - 1].address);
        }
        try expectPathState(&db_c, accounts);
        const root_c = db_c.accounts.stateRoot() orelse return error.MissingStateRoot;

        try std.testing.expectEqualSlices(u8, &root_a, &root_b);
        try std.testing.expectEqualSlices(u8, &root_a, &root_c);

        // Control: the root is sensitive to a one-wei balance difference.
        if (iteration % 4 == 0) {
            try db_c.state.setBalance(accounts[0].address, accounts[0].balance +% 1);
            try db_c.syncAccountToTrie(allocator, accounts[0].address);
            const root_changed = db_c.accounts.stateRoot() orelse return error.MissingStateRoot;
            try std.testing.expect(!std.mem.eql(u8, &root_a, &root_changed));
        }
    }
}

// --- Storage-zero deletion law ----------------------------------------------

fn populatePathAccount(db: *database.Database, account: *const PathAccount) !void {
    try db.state.setBalance(account.address, account.balance);
    try db.state.setNonce(account.address, account.nonce);
    if (account.code_len != 0) try db.state.setCode(account.address, account.codeSlice());
    for (account.slot_keys[0..account.slot_count], account.slot_values[0..account.slot_count]) |key, value| {
        try db.state.setStorage(account.address, key, value);
    }
}

fn syncedLeaf(db: *database.Database, address: primitives.Address) !primitives.AccountState.AccountState {
    try db.syncAccountToTrie(std.testing.allocator, address);
    return (try db.accounts.get(std.testing.allocator, address)) orelse error.MissingTrieLeaf;
}

test "property: slot set nonzero then back to zero equals never touching the slot" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x2e80_51a7_0002);
    const random = prng.random();

    var iteration: usize = 0;
    while (iteration < 256) : (iteration += 1) {
        const account = randomPathAccount(random, 0);
        const transient_key = junkSlotKey(random);
        const transient_value = nonZeroU256(random);

        // Never touches the transient slot.
        var untouched = try database.Database.init(allocator, null);
        defer untouched.deinit(allocator);
        try populatePathAccount(&untouched, &account);
        const untouched_leaf = try syncedLeaf(&untouched, account.address);
        const untouched_root = untouched.accounts.stateRoot() orelse return error.MissingStateRoot;

        // Writes the transient slot nonzero, then zero.
        var touched = try database.Database.init(allocator, null);
        defer touched.deinit(allocator);
        var adapter = host_adapter.HostAdapter{ .state = &touched.state };
        const host = adapter.hostInterface();
        const populate_first = random.boolean();
        if (populate_first) try populatePathAccount(&touched, &account);
        switch (random.uintLessThan(u8, 3)) {
            0 => {
                try adapter.setStorage(account.address, transient_key, transient_value);
                try std.testing.expectEqual(transient_value, try touched.state.getStorage(account.address, transient_key));
                try adapter.setStorage(account.address, transient_key, 0);
            },
            1 => {
                try touched.state.setStorage(account.address, transient_key, transient_value);
                try touched.state.checkpoint();
                host.setStorage(account.address, transient_key, 0);
                touched.state.commit();
            },
            else => {
                try touched.state.checkpoint();
                host.setStorage(account.address, transient_key, transient_value);
                try touched.state.checkpoint();
                try touched.state.setStorage(account.address, transient_key, 0);
                touched.state.commit();
                touched.state.commit();
            },
        }
        if (!populate_first) try populatePathAccount(&touched, &account);
        try std.testing.expect(adapter.getHostError() == null);
        try expectDepth(&touched.state, 0);
        try std.testing.expectEqual(@as(u256, 0), try touched.state.getStorage(account.address, transient_key));
        const touched_leaf = try syncedLeaf(&touched, account.address);
        const touched_root = touched.accounts.stateRoot() orelse return error.MissingStateRoot;

        const expected_storage_root = try account.storageRoot();
        try std.testing.expectEqualSlices(u8, &expected_storage_root, &untouched_leaf.storage_root);
        try std.testing.expectEqualSlices(u8, &untouched_leaf.storage_root, &touched_leaf.storage_root);
        try std.testing.expectEqualSlices(u8, &untouched_root, &touched_root);
        if (account.slot_count == 0) {
            try std.testing.expectEqualSlices(u8, &primitives.State.EMPTY_TRIE_ROOT, &touched_leaf.storage_root);
        }

        // Control: leaving the transient slot nonzero changes both roots.
        var dirty = try database.Database.init(allocator, null);
        defer dirty.deinit(allocator);
        try populatePathAccount(&dirty, &account);
        try dirty.state.setStorage(account.address, transient_key, transient_value);
        const dirty_leaf = try syncedLeaf(&dirty, account.address);
        const dirty_root = dirty.accounts.stateRoot() orelse return error.MissingStateRoot;
        try std.testing.expect(!std.mem.eql(u8, &untouched_leaf.storage_root, &dirty_leaf.storage_root));
        try std.testing.expect(!std.mem.eql(u8, &untouched_root, &dirty_root));

        // Overwrite law: zeroing an existing slot equals never writing it.
        if (account.slot_count > 0) {
            const victim = random.uintLessThan(usize, account.slot_count);

            var erased = try database.Database.init(allocator, null);
            defer erased.deinit(allocator);
            try populatePathAccount(&erased, &account);
            try erased.state.setStorage(account.address, account.slot_keys[victim], 0);
            const erased_leaf = try syncedLeaf(&erased, account.address);
            const erased_root = erased.accounts.stateRoot() orelse return error.MissingStateRoot;

            var without = account;
            without.slot_values[victim] = 0;
            var never = try database.Database.init(allocator, null);
            defer never.deinit(allocator);
            try never.state.setBalance(without.address, without.balance);
            try never.state.setNonce(without.address, without.nonce);
            if (without.code_len != 0) try never.state.setCode(without.address, without.codeSlice());
            for (without.slot_keys[0..without.slot_count], without.slot_values[0..without.slot_count]) |key, value| {
                if (value != 0) try never.state.setStorage(without.address, key, value);
            }
            const never_leaf = try syncedLeaf(&never, without.address);
            const never_root = never.accounts.stateRoot() orelse return error.MissingStateRoot;

            const without_storage_root = try without.storageRoot();
            try std.testing.expectEqualSlices(u8, &without_storage_root, &erased_leaf.storage_root);
            try std.testing.expectEqualSlices(u8, &never_leaf.storage_root, &erased_leaf.storage_root);
            try std.testing.expectEqualSlices(u8, &never_root, &erased_root);
        }
    }
}

// ---------------------------------------------------------------------------
// Known-bug repros. Skipped unless ZEVM_FUZZ_KNOWN_BUGS is set.
// ---------------------------------------------------------------------------

test "known bug: revertToSnapshot on a snapshot already unwound by revert must not underflow" {
    if (!knownBugReprosEnabled()) return error.SkipZigTest;

    var state = try state_manager.StateManager.init(std.testing.allocator, null);
    defer state.deinit();

    try state.checkpoint(); // depth 1
    const id = try state.snapshot(); // records depth 1, now depth 2
    state.revert(); // depth 1
    state.revert(); // depth 0, below the recorded snapshot depth

    // Today: `current_depth - target_depth` underflows usize (panic in safe
    // builds, a ~2^64-iteration loop otherwise).
    try std.testing.expectError(error.InvalidSnapshot, state.revertToSnapshot(id));
}

test "known bug: revertToSnapshot after commit must restore the snapshot or reject the id" {
    if (!knownBugReprosEnabled()) return error.SkipZigTest;

    var state = try state_manager.StateManager.init(std.testing.allocator, null);
    defer state.deinit();
    const address = universe_addresses[3];

    try state.setBalance(address, 1000);
    const id = try state.snapshot();
    try state.setBalance(address, 2000);
    state.commit(); // drops the snapshot's checkpoint; the id stays registered

    // Today: returns success without restoring anything.
    if (state.revertToSnapshot(id)) |_| {
        try std.testing.expectEqual(@as(u256, 1000), try state.getBalance(address));
    } else |err| {
        try std.testing.expectEqual(error.InvalidSnapshot, err);
    }
}

test "known bug: re-syncing an unchanged account into the trie must not leak" {
    if (!knownBugReprosEnabled()) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var db = try database.Database.init(allocator, null);
    defer db.deinit(allocator);

    try db.state.setBalance(universe_addresses[3], 5);
    try db.syncAccountToTrie(allocator, universe_addresses[3]);
    const first_root = db.accounts.stateRoot() orelse return error.MissingStateRoot;
    // Today: Trie.store_node re-inserts a node whose hash is already a key;
    // the map keeps the old key, so the new key string and the old node's
    // heap data leak (reported by std.testing.allocator at test exit).
    try db.syncAccountToTrie(allocator, universe_addresses[3]);
    try db.syncCachedAccountsToTrie(allocator);
    const second_root = db.accounts.stateRoot() orelse return error.MissingStateRoot;
    try std.testing.expectEqualSlices(u8, &first_root, &second_root);
}

test "known bug: Database state root must equal the canonical secure MPT root" {
    if (!knownBugReprosEnabled()) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var db = try database.Database.init(allocator, null);
    defer db.deinit(allocator);

    const balances = [_]u256{ 1, 1_000_000_000_000_000_000, std.math.maxInt(u256) };
    const nonces = [_]u64{ 0, 7, std.math.maxInt(u64) };
    var keys: [3][]const u8 = undefined;
    var values: [3][]const u8 = undefined;
    var encoded_count: usize = 0;
    defer {
        for (values[0..encoded_count]) |encoded| allocator.free(encoded);
    }

    for (balances, nonces, 0..) |balance, nonce, index| {
        const address = &universe_addresses[index + 1];
        try db.state.setBalance(address.*, balance);
        try db.state.setNonce(address.*, nonce);
        try db.syncAccountToTrie(allocator, address.*);

        const account = primitives.AccountState.AccountState.from(.{ .nonce = nonce, .balance = balance });
        keys[index] = &address.bytes;
        values[index] = try account.rlpEncode(allocator);
        encoded_count += 1;
    }

    // Today: Trie.hash_node RLP-encodes every list item twice and never
    // inlines short nodes, so the root is deterministic but not canonical.
    const canonical_root = try primitives.TrieHash.secure_trie_root(allocator, &keys, &values);
    const actual_root = db.accounts.stateRoot() orelse return error.MissingStateRoot;
    try std.testing.expectEqualSlices(u8, &canonical_root, &actual_root);
}

test "a deleted account disappears from the state root after syncCachedAccountsToTrie" {
    const allocator = std.testing.allocator;
    const keep = universe_addresses[3];
    const drop = universe_addresses[4];

    var reference_db = try database.Database.init(allocator, null);
    defer reference_db.deinit(allocator);
    try reference_db.state.setBalance(keep, 100);
    try reference_db.syncCachedAccountsToTrie(allocator);
    const expected_root = reference_db.accounts.stateRoot() orelse return error.MissingStateRoot;

    var db = try database.Database.init(allocator, null);
    defer db.deinit(allocator);
    var adapter = host_adapter.HostAdapter{ .state = &db.state };
    try db.state.setBalance(keep, 100);
    try db.state.setBalance(drop, 200);
    try db.syncCachedAccountsToTrie(allocator);
    try adapter.deleteAccount(drop);
    try db.syncCachedAccountsToTrie(allocator);
    const synced_root = db.accounts.stateRoot() orelse return error.MissingStateRoot;
    try std.testing.expectEqualSlices(u8, &expected_root, &synced_root);
}

test "known bug: Accounts.remove must restore the root of the smaller trie" {
    if (!knownBugReprosEnabled()) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const keep_account = primitives.AccountState.AccountState.from(.{ .nonce = 1, .balance = 100 });
    const drop_account = primitives.AccountState.AccountState.from(.{ .nonce = 2, .balance = 200 });

    var reference_db = try database.Database.init(allocator, null);
    defer reference_db.deinit(allocator);
    try reference_db.accounts.put(allocator, universe_addresses[3], &keep_account);
    const expected_root = reference_db.accounts.stateRoot() orelse return error.MissingStateRoot;

    // Today: Trie.delete_at leaves a one-child branch instead of collapsing
    // it back into a leaf, so the root differs from the insert-only trie.
    var db = try database.Database.init(allocator, null);
    defer db.deinit(allocator);
    try db.accounts.put(allocator, universe_addresses[3], &keep_account);
    try db.accounts.put(allocator, universe_addresses[4], &drop_account);
    try db.accounts.remove(universe_addresses[4]);
    const actual_root = db.accounts.stateRoot() orelse return error.MissingStateRoot;
    try std.testing.expectEqualSlices(u8, &expected_root, &actual_root);
}

fn checkpointUnderAllocationFailure(allocator: std.mem.Allocator) !void {
    var state = try state_manager.StateManager.init(allocator, null);
    defer state.deinit();
    const address = universe_addresses[3];

    try state.setBalance(address, 1);
    try state.setCode(address, &[_]u8{ 0x60, 0x00 });
    try state.setStorage(address, 1, 2);
    try state.checkpoint();
    try state.setCode(address, &[_]u8{0xfe});
    state.revert();
}

test "known bug: checkpoint must not leak when an allocation fails" {
    if (!knownBugReprosEnabled()) return error.SkipZigTest;

    // Today: AccountCache/StorageCache/ContractCache.checkpoint build the
    // snapshot map without errdefer, so a failed put leaks the partial copy.
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkpointUnderAllocationFailure, .{});
}

// ---------------------------------------------------------------------------
// Part B: native coverage-guided fuzz target.
// ---------------------------------------------------------------------------

const fuzz_max_ops = 256;
const fuzz_max_trie_checks = 4;
const fuzz_opcode_count = 13;

const ByteReader = struct {
    bytes: []const u8,
    index: usize = 0,

    fn next(self: *ByteReader) ?u8 {
        if (self.index >= self.bytes.len) return null;
        const byte = self.bytes[self.index];
        self.index += 1;
        return byte;
    }

    fn nextOrZero(self: *ByteReader) u8 {
        return self.next() orelse 0;
    }

    fn nextU64(self: *ByteReader) u64 {
        var value: u64 = 0;
        var count: usize = 0;
        while (count < 8) : (count += 1) {
            value = (value << 8) | self.nextOrZero();
        }
        return value;
    }

    fn nextU256(self: *ByteReader) u256 {
        return switch (self.nextOrZero() % 8) {
            0 => 0,
            1 => 1,
            2 => std.math.maxInt(u256),
            3 => @as(u256, 1) << 255,
            4 => self.nextOrZero(),
            5 => self.nextU64(),
            6 => @as(u256, self.nextU64()) << 192,
            else => blk: {
                var value: u256 = 0;
                var count: usize = 0;
                while (count < 32) : (count += 1) {
                    value = (value << 8) | self.nextOrZero();
                }
                break :blk value;
            },
        };
    }

    fn nextRoute(self: *ByteReader) Route {
        return @enumFromInt(self.nextOrZero() % 3);
    }

    fn nextAccount(self: *ByteReader) usize {
        return self.nextOrZero() % address_count;
    }
};

/// Every byte string is a valid program: one opcode byte, then operands that
/// read as zero once the input is exhausted.
fn decodeOp(reader: *ByteReader) ?Op {
    const opcode = reader.next() orelse return null;
    switch (opcode % fuzz_opcode_count) {
        0 => {
            const account = reader.nextAccount();
            const route = reader.nextRoute();
            return .{ .set_balance = .{ .account = account, .value = reader.nextU256(), .route = route } };
        },
        1 => {
            const account = reader.nextAccount();
            const route = reader.nextRoute();
            const value: u64 = switch (reader.nextOrZero() % 4) {
                0 => 0,
                1 => 1,
                2 => std.math.maxInt(u64),
                else => reader.nextU64(),
            };
            return .{ .set_nonce = .{ .account = account, .value = value, .route = route } };
        },
        2 => {
            const account = reader.nextAccount();
            const route = reader.nextRoute();
            const len: usize = reader.nextOrZero() % (max_code_len + 1);
            var code = [_]u8{0} ** max_code_len;
            for (code[0..len]) |*byte| byte.* = reader.nextOrZero();
            return .{ .set_code = .{ .account = account, .code = code, .len = len, .route = route } };
        },
        3 => return .{ .realias_code = .{ .account = reader.nextAccount() } },
        4 => {
            const account = reader.nextAccount();
            const route = reader.nextRoute();
            const slot: usize = reader.nextOrZero() % slot_count;
            return .{ .set_storage = .{ .account = account, .slot = slot, .value = reader.nextU256(), .route = route } };
        },
        5 => {
            const account = reader.nextAccount();
            return .{ .delete_account = .{ .account = account, .through_vtable = reader.nextOrZero() % 2 == 1 } };
        },
        6 => return .checkpoint,
        7 => return .revert,
        8 => return .commit,
        9 => return .snapshot,
        10 => return .{ .revert_to_snapshot = .{ .pick = reader.nextOrZero() } },
        11 => return .{ .revert_many = .{ .levels = 2 + @as(usize, reader.nextOrZero() % 4) } },
        else => return .{ .trie_check = .{ .order_seed = reader.nextOrZero() } },
    }
}

fn fuzzStateDbAgainstReference(_: void, input: []const u8) anyerror!void {
    const allocator = std.testing.allocator;
    var db = try database.Database.init(allocator, null);
    defer db.deinit(allocator);
    var changes: std.ArrayList(host_adapter.HostAdapter.BalanceChange) = .empty;
    defer changes.deinit(allocator);
    var adapter = host_adapter.HostAdapter{
        .state = &db.state,
        .balance_change_allocator = allocator,
        .balance_changes = &changes,
    };
    var machine = Machine{
        .db = &db,
        .adapter = &adapter,
        .changes = &changes,
        .trie_checks_left = fuzz_max_trie_checks,
    };
    defer machine.deinit();

    var reader = ByteReader{ .bytes = input };
    var executed: usize = 0;
    while (executed < fuzz_max_ops) : (executed += 1) {
        const op = decodeOp(&reader) orelse break;
        try machine.apply(op);
        try machine.check();
    }

    // Final trie agreement at whatever checkpoint depth the program ended on.
    try machine.checkTrie(input.len);
}

test "fuzz: byte-stream state mutations and nested snapshots agree with ReferenceState" {
    // Empty program: an untouched database must still sync and agree.
    try fuzzStateDbAgainstReference({}, "");
    try std.testing.fuzz({}, fuzzStateDbAgainstReference, .{
        .corpus = &.{
            // Balance writes through all three routes, then a trie check.
            "\x00\x03\x00\x02" ++ "\x00\x03\x01\x01" ++ "\x00\x03\x02\x04\x7f" ++ "\x0c\x01",
            // Slot set nonzero, zeroed inside a committed checkpoint, trie check.
            "\x04\x04\x01\x01\x02" ++ "\x06" ++ "\x04\x04\x02\x01\x00" ++ "\x08" ++ "\x0c\x09",
            // Three nested checkpoints, writes at each level, multi-level revert.
            "\x06\x00\x00\x00\x01" ++ "\x06\x01\x01\x01\x02" ++ "\x06\x04\x02\x02\x05\x03\x02" ++ "\x0b\x01" ++ "\x07\x07",
            // Snapshots: nested ids, revert to the outer id, then stale and bogus ids.
            "\x09\x00\x01\x00\x01" ++ "\x09\x04\x01\x00\x00\x02" ++ "\x09\x02\x02\x00\x03\x60\x00\xfd" ++ "\x0a\x00\x0a\x01\x0a\x07\x0a\xff",
            // Code: max length, empty, self-aliased rewrite, delete, revert of the delete.
            "\x02\x05\x00\x28" ++ ("\xfe" ** 40) ++ "\x06\x02\x05\x02\x00\x03\x05\x05\x05\x01\x07\x0c\x03",
            // Delete under a checkpoint via the vtable, commit, re-create, snapshot unwind.
            "\x00\x01\x01\x02\x04\x01\x00\x05\x02\x06\x05\x01\x01\x08\x01\x01\x02\x02\x09\x04\x01\x02\x00\x01\x0a\x00",
            // Commit and revert at depth zero, snapshot then plain reverts past it.
            "\x08\x07\x0b\x03\x06\x09\x07\x07\x0a\x00\x0a\x01\x09\x08\x0a\x01\x0c\x00",
            // Extreme values: max balance, max nonce, 1<<255 and max in the max slot key.
            "\x00\x02\x01\x02" ++ "\x01\x02\x00\x02" ++ "\x04\x02\x02\x05\x03" ++ "\x04\x02\x00\x05\x02" ++ "\x04\x02\x01\x05\x00" ++ "\x0c\xaa",
            // Checkpoint flood past the depth limit, then a deep unwind.
            ("\x06" ** 14) ++ "\x00\x00\x00\x04\x09" ++ ("\x09" ** 3) ++ "\x0b\x03\x0b\x03\x0b\x03\x0b\x03\x0c\x10",
            // Opcode bytes above the table wrap modulo 13; operands run out mid-op.
            "\xff\xfe\xfd\xfc\xfb\xfa\xf9\xf8\xf7\xf6\xf5\xf4\xf3\xf2\xf1\xf0\x0d\x1a\x27\x04",
            // Interleaved storage churn on one account across reverted snapshots.
            "\x04\x03\x00\x00\x07\xaa\xbb\xcc\xdd\xee\xff\x11\x22\x33\x44\x55\x66\x77\x88\x99\xaa\xbb\xcc\xdd\xee\xff\x11\x22\x33\x44\x55\x66\x77\x88\x99\xaa\xbb" ++
                "\x09\x04\x03\x01\x00\x00\x04\x03\x02\x03\x01\x0a\x00\x0c\x05",
        },
    });
}
