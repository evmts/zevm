const std = @import("std");
const primitives = @import("primitives");
const zevm = @import("zevm");
const harness = @import("harness");

fn populateKeysAndValues(
    allocator: std.mem.Allocator,
    count: usize,
) !struct { keys: [][]u8, values: [][]u8 } {
    const keys = try allocator.alloc([]u8, count);
    const values = try allocator.alloc([]u8, count);
    for (0..count) |i| {
        const k = try allocator.alloc(u8, 20);
        @memset(k, 0);
        std.mem.writeInt(u64, k[12..20], i + 1, .big);
        keys[i] = k;

        const v = try allocator.alloc(u8, 64);
        @memset(v, @intCast((i * 13 + 7) & 0xff));
        std.mem.writeInt(u64, v[0..8], i + 1, .big);
        values[i] = v;
    }
    return .{ .keys = keys, .values = values };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cfg = try harness.parseArgs(allocator, "mpt-proof");
    var runner = harness.Runner.init(allocator, cfg);
    defer runner.deinit();

    // 1. MPT secureProof on 64 keys
    {
        const kv = try populateKeysAndValues(allocator, 64);
        defer {
            for (kv.keys) |k| allocator.free(k);
            for (kv.values) |v| allocator.free(v);
            allocator.free(kv.keys);
            allocator.free(kv.values);
        }

        const Ctx = struct {
            allocator: std.mem.Allocator,
            keys: []const []const u8,
            values: []const []const u8,
            idx: usize = 0,
        };
        var ctx = Ctx{ .allocator = allocator, .keys = kv.keys, .values = kv.values };

        try runner.run("mpt_proof/secure_proof_64_keys", &ctx, struct {
            fn f(c: *Ctx) !void {
                c.idx = (c.idx + 1) % c.keys.len;
                var proof = try zevm.mpt_proof.secureProof(c.allocator, c.keys, c.values, c.keys[c.idx]);
                defer proof.deinit(c.allocator);
                std.mem.doNotOptimizeAway(&proof.root);
            }
        }.f, .{});
    }

    // 2. MPT secureProof on 512 keys
    {
        const kv = try populateKeysAndValues(allocator, 512);
        defer {
            for (kv.keys) |k| allocator.free(k);
            for (kv.values) |v| allocator.free(v);
            allocator.free(kv.keys);
            allocator.free(kv.values);
        }

        const Ctx = struct {
            allocator: std.mem.Allocator,
            keys: []const []const u8,
            values: []const []const u8,
            idx: usize = 0,
        };
        var ctx = Ctx{ .allocator = allocator, .keys = kv.keys, .values = kv.values };

        try runner.run("mpt_proof/secure_proof_512_keys", &ctx, struct {
            fn f(c: *Ctx) !void {
                c.idx = (c.idx + 1) % c.keys.len;
                var proof = try zevm.mpt_proof.secureProof(c.allocator, c.keys, c.values, c.keys[c.idx]);
                defer proof.deinit(c.allocator);
                std.mem.doNotOptimizeAway(&proof.root);
            }
        }.f, .{ .warmup_iters = 2 });
    }

    // 3. Secure trie root computation on 256 keys (baseline comparison against proof generation)
    {
        const kv = try populateKeysAndValues(allocator, 256);
        defer {
            for (kv.keys) |k| allocator.free(k);
            for (kv.values) |v| allocator.free(v);
            allocator.free(kv.keys);
            allocator.free(kv.values);
        }

        const Ctx = struct {
            allocator: std.mem.Allocator,
            keys: []const []const u8,
            values: []const []const u8,
        };
        var ctx = Ctx{
            .allocator = allocator,
            .keys = kv.keys,
            .values = kv.values,
        };

        try runner.run("mpt_proof/secure_trie_root_256_keys", &ctx, struct {
            fn f(c: *Ctx) !void {
                const root = try primitives.TrieHash.secure_trie_root(c.allocator, c.keys, c.values);
                std.mem.doNotOptimizeAway(&root);
            }
        }.f, .{});
    }

    try runner.finish();
}
