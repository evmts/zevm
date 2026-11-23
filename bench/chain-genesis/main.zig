const std = @import("std");
const primitives = @import("primitives");
const blockchain = @import("blockchain");
const state_manager = @import("state-manager");
const zevm = @import("zevm");
const harness = @import("harness");

fn encodeListFromEncoded(allocator: std.mem.Allocator, fields: []const []const u8) ![]u8 {
    var total_len: usize = 0;
    for (fields) |f| total_len += f.len;
    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);
    if (total_len < 56) {
        try out.append(allocator, 0xc0 + @as(u8, @intCast(total_len)));
    } else {
        const len_bytes = try primitives.Rlp.encodeLength(allocator, total_len);
        defer allocator.free(len_bytes);
        try out.append(allocator, 0xf7 + @as(u8, @intCast(len_bytes.len)));
        try out.appendSlice(allocator, len_bytes);
    }
    for (fields) |f| try out.appendSlice(allocator, f);
    return try out.toOwnedSlice(allocator);
}

fn encodeChainFixture(allocator: std.mem.Allocator, block_count: usize) ![]u8 {
    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);

    var parent_hash = primitives.Hash.ZERO;
    for (0..block_count) |num| {
        const header = primitives.BlockHeader.BlockHeader{
            .parent_hash = parent_hash,
            .ommers_hash = primitives.BlockHeader.EMPTY_OMMERS_HASH,
            .beneficiary = primitives.Address.fromU256(0xaa),
            .state_root = primitives.State.EMPTY_TRIE_ROOT,
            .transactions_root = primitives.BlockHeader.EMPTY_TRANSACTIONS_ROOT,
            .receipts_root = primitives.BlockHeader.EMPTY_RECEIPTS_ROOT,
            .logs_bloom = [_]u8{0} ** primitives.BlockHeader.BLOOM_SIZE,
            .difficulty = 0,
            .number = num,
            .gas_limit = 30_000_000,
            .gas_used = 0,
            .timestamp = 1_700_000_000 + num * 12,
            .extra_data = "zevm-bench",
            .mix_hash = primitives.Hash.ZERO,
            .nonce = [_]u8{0} ** primitives.BlockHeader.NONCE_SIZE,
            .base_fee_per_gas = 1_000_000_000,
        };
        const header_rlp = try primitives.BlockHeader.rlpEncode(&header, allocator);
        defer allocator.free(header_rlp);

        std.crypto.hash.sha3.Keccak256.hash(header_rlp, &parent_hash, .{});

        const block_rlp = try encodeListFromEncoded(allocator, &.{
            header_rlp,
            &[_]u8{0xc0},
            &[_]u8{0xc0},
        });
        defer allocator.free(block_rlp);
        try out.appendSlice(allocator, block_rlp);
    }

    return try out.toOwnedSlice(allocator);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cfg = try harness.parseArgs(allocator, "chain-genesis");
    var runner = harness.Runner.init(allocator, cfg);
    defer runner.deinit();

    // 1. Genesis block creation & state initialization
    {
        const Ctx = struct { allocator: std.mem.Allocator };
        var ctx = Ctx{ .allocator = allocator };

        try runner.run("genesis/create_devnet_block", &ctx, struct {
            fn f(c: *Ctx) !void {
                var arena = std.heap.ArenaAllocator.init(c.allocator);
                defer arena.deinit();
                const blk = try zevm.genesis.createGenesisBlock(arena.allocator(), 31337);
                std.mem.doNotOptimizeAway(&blk.hash);
            }
        }.f, .{});

        try runner.run("genesis/init_genesis_state", &ctx, struct {
            fn f(c: *Ctx) !void {
                var db = try zevm.database.Database.init(c.allocator, null);
                defer db.deinit(c.allocator);
                const root = try zevm.genesis.initGenesisState(c.allocator, &db, .devnet, null);
                std.mem.doNotOptimizeAway(&root);
            }
        }.f, .{});
    }

    // 2. computeStateRootFromPremine for 100 premine accounts
    {
        var accounts: [100]zevm.genesis.PremineAccount = undefined;
        for (0..100) |i| {
            var addr = primitives.Address.ZERO;
            std.mem.writeInt(u64, addr.bytes[12..20], i + 1, .big);
            accounts[i] = .{
                .address = addr,
                .balance = (@as(u256, i + 1)) * 1_000_000_000_000_000_000,
                .nonce = i,
            };
        }

        const Ctx = struct {
            allocator: std.mem.Allocator,
            accounts: []const zevm.genesis.PremineAccount,
        };
        var ctx = Ctx{ .allocator = allocator, .accounts = &accounts };

        try runner.run("genesis/state_root_100_premine", &ctx, struct {
            fn f(c: *Ctx) !void {
                const root = try zevm.genesis.computeStateRootFromPremine(c.allocator, c.accounts);
                std.mem.doNotOptimizeAway(&root);
            }
        }.f, .{});
    }

    // 3. chain_import: decodeNextBlock and importChainBytes (20-block RLP stream)
    {
        const one_block_rlp = try encodeChainFixture(allocator, 1);
        defer allocator.free(one_block_rlp);

        const chain_20_rlp = try encodeChainFixture(allocator, 20);
        defer allocator.free(chain_20_rlp);

        const Ctx = struct {
            allocator: std.mem.Allocator,
            one_block_rlp: []const u8,
            chain_20_rlp: []const u8,
        };
        var ctx = Ctx{
            .allocator = allocator,
            .one_block_rlp = one_block_rlp,
            .chain_20_rlp = chain_20_rlp,
        };

        try runner.run("chain_import/decode_single_block_rlp", &ctx, struct {
            fn f(c: *Ctx) !void {
                var dec = try zevm.chain_import.decodeNextBlock(c.allocator, c.one_block_rlp);
                defer dec.deinit(c.allocator);
                std.mem.doNotOptimizeAway(&dec.block.hash);
            }
        }.f, .{ .bytes_per_op = one_block_rlp.len });

        try runner.run("chain_import/import_20_blocks_rlp", &ctx, struct {
            fn f(c: *Ctx) !void {
                var bc = try blockchain.Blockchain.init(c.allocator, null);
                defer bc.deinit();
                var owned_bodies = std.ArrayList(zevm.chain_import.OwnedBlockBody){};
                defer {
                    for (owned_bodies.items) |*b| b.deinit(c.allocator);
                    owned_bodies.deinit(c.allocator);
                }
                const stats = try zevm.chain_import.importChainBytes(c.allocator, &bc, &owned_bodies, c.chain_20_rlp);
                std.mem.doNotOptimizeAway(&stats);
            }
        }.f, .{ .bytes_per_op = chain_20_rlp.len });
    }

    try runner.finish();
}
