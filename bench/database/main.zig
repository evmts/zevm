const std = @import("std");
const primitives = @import("primitives");
const zevm = @import("zevm");
const harness = @import("harness");

fn makeAddress(seed: u64) primitives.Address {
    var addr = primitives.Address.ZERO;
    std.mem.writeInt(u64, addr.bytes[12..20], seed, .big);
    return addr;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cfg = try harness.parseArgs(allocator, "database");
    var runner = harness.Runner.init(allocator, cfg);
    defer runner.deinit();

    // 1. StateManager hot balance read/write
    {
        var db = try zevm.database.Database.init(allocator, null);
        defer db.deinit(allocator);
        const addr = makeAddress(1);
        try db.state.setBalance(addr, 1_000_000_000);

        const Ctx = struct {
            db: *zevm.database.Database,
            addr: primitives.Address,
            acc: u256 = 0,
        };
        var ctx = Ctx{ .db = &db, .addr = addr };
        try runner.run("database/state_get_balance_hot", &ctx, struct {
            fn f(c: *Ctx) !void {
                const v = try c.db.state.getBalance(c.addr);
                c.acc +%= v;
                std.mem.doNotOptimizeAway(&c.acc);
            }
        }.f, .{});

        try runner.run("database/state_set_balance", &ctx, struct {
            fn f(c: *Ctx) !void {
                c.acc +%= 1;
                try c.db.state.setBalance(c.addr, c.acc);
            }
        }.f, .{});
    }

    // 2. StateManager storage read/write
    {
        var db = try zevm.database.Database.init(allocator, null);
        defer db.deinit(allocator);
        const addr = makeAddress(2);
        for (0..64) |i| {
            try db.state.setStorage(addr, i, i * 17 + 1);
        }

        const Ctx = struct {
            db: *zevm.database.Database,
            addr: primitives.Address,
            slot: u256 = 0,
            acc: u256 = 0,
        };
        var ctx = Ctx{ .db = &db, .addr = addr };
        try runner.run("database/state_get_storage_hot", &ctx, struct {
            fn f(c: *Ctx) !void {
                c.slot = (c.slot + 1) & 63;
                const v = try c.db.state.getStorage(c.addr, c.slot);
                c.acc +%= v;
                std.mem.doNotOptimizeAway(&c.acc);
            }
        }.f, .{});

        try runner.run("database/state_set_storage", &ctx, struct {
            fn f(c: *Ctx) !void {
                c.slot = (c.slot + 1) & 63;
                c.acc +%= 1;
                try c.db.state.setStorage(c.addr, c.slot, c.acc);
            }
        }.f, .{});
    }

    // 3. Snapshot + revert (1 level and 8 nested levels)
    {
        var db = try zevm.database.Database.init(allocator, null);
        defer db.deinit(allocator);
        const addr = makeAddress(3);
        try db.state.setBalance(addr, 500_000);

        const Ctx = struct {
            db: *zevm.database.Database,
            addr: primitives.Address,
        };
        var ctx = Ctx{ .db = &db, .addr = addr };
        try runner.run("database/checkpoint_revert_shallow", &ctx, struct {
            fn f(c: *Ctx) !void {
                try c.db.state.checkpoint();
                try c.db.state.setBalance(c.addr, 999_999);
                try c.db.state.setStorage(c.addr, 1, 42);
                c.db.state.revert();
            }
        }.f, .{});

        try runner.run("database/checkpoint_commit_8_levels", &ctx, struct {
            fn f(c: *Ctx) !void {
                for (0..8) |depth| {
                    try c.db.state.checkpoint();
                    try c.db.state.setStorage(c.addr, depth, depth + 1);
                }
                for (0..8) |_| {
                    c.db.state.revert();
                }
            }
        }.f, .{});
    }

    // 4. Contracts store put/get
    {
        var contracts = zevm.database.Contracts.init();
        defer contracts.deinit(allocator);
        const code = [_]u8{0x60} ** 2048;
        var hash: primitives.Hash.Hash = undefined;
        std.crypto.hash.sha3.Keccak256.hash(&code, &hash, .{});
        try contracts.put(allocator, hash, &code);

        const Ctx = struct {
            contracts: *zevm.database.Contracts,
            allocator: std.mem.Allocator,
            hash: primitives.Hash.Hash,
            code: []const u8,
        };
        var ctx = Ctx{ .contracts = &contracts, .allocator = allocator, .hash = hash, .code = &code };
        try runner.run("database/contracts_get_2kb", &ctx, struct {
            fn f(c: *Ctx) !void {
                const got = c.contracts.get(c.hash);
                std.mem.doNotOptimizeAway(&got);
            }
        }.f, .{ .bytes_per_op = 2048 });

        try runner.run("database/contracts_put_2kb", &ctx, struct {
            fn f(c: *Ctx) !void {
                try c.contracts.put(c.allocator, c.hash, c.code);
            }
        }.f, .{ .bytes_per_op = 2048 });
    }

    // 5. syncAccountToTrie (EOA and contract with 32 storage slots) & syncCachedAccountsToTrie (64 accounts)
    {
        var db = try zevm.database.Database.init(allocator, null);
        defer db.deinit(allocator);
        const eoa = makeAddress(10);
        try db.state.setBalance(eoa, 123_456);
        try db.state.setNonce(eoa, 7);

        const contract = makeAddress(11);
        const code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0xf3 } ** 64;
        try db.state.setCode(contract, &code);
        for (0..32) |slot| {
            try db.state.setStorage(contract, slot + 1, (slot + 1) * 9999);
        }

        const Ctx = struct {
            db: *zevm.database.Database,
            allocator: std.mem.Allocator,
            eoa: primitives.Address,
            contract: primitives.Address,
        };
        var ctx = Ctx{ .db = &db, .allocator = allocator, .eoa = eoa, .contract = contract };

        try runner.run("database/sync_account_to_trie_eoa", &ctx, struct {
            fn f(c: *Ctx) !void {
                try c.db.syncAccountToTrie(c.allocator, c.eoa);
                const root = c.db.accounts.stateRoot();
                std.mem.doNotOptimizeAway(&root);
            }
        }.f, .{});

        try runner.run("database/sync_account_to_trie_32slots", &ctx, struct {
            fn f(c: *Ctx) !void {
                try c.db.syncAccountToTrie(c.allocator, c.contract);
                const root = c.db.accounts.stateRoot();
                std.mem.doNotOptimizeAway(&root);
            }
        }.f, .{});
    }

    {
        var db = try zevm.database.Database.init(allocator, null);
        defer db.deinit(allocator);
        for (0..64) |i| {
            const addr = makeAddress(100 + i);
            try db.state.setBalance(addr, (i + 1) * 1000);
            try db.state.setNonce(addr, i);
            if (i % 4 == 0) {
                try db.state.setStorage(addr, 1, i + 1);
                try db.state.setStorage(addr, 2, i + 2);
            }
        }

        const Ctx = struct {
            db: *zevm.database.Database,
            allocator: std.mem.Allocator,
        };
        var ctx = Ctx{ .db = &db, .allocator = allocator };
        try runner.run("database/sync_cached_accounts_64", &ctx, struct {
            fn f(c: *Ctx) !void {
                try c.db.syncCachedAccountsToTrie(c.allocator);
                const root = c.db.accounts.stateRoot();
                std.mem.doNotOptimizeAway(&root);
            }
        }.f, .{});
    }

    try runner.finish();
}
