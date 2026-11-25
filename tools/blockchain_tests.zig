//! Replay ethereum-tests BlockchainTests from the wire encoding.
const std = @import("std");
const primitives = @import("primitives");
const zevm = @import("zevm");
const evm = @import("guillotine_mini");
const State = @import("state-manager").StateManager;
const builder = zevm.block_builder;
const encoding = zevm.transaction_encoding;
const Block = primitives.Block.Block;
const Hash = [32]u8;
const Json = std.json.Value;
const Allocator = std.mem.Allocator;
const Fork = evm.Hardfork;
const eq = std.mem.eql;

const Outcome = enum {
    passed,
    failed,
    ethash_pow_seal,
    other_seal,
    transition_fork,
    legacy_pow,
    other_fork,

    fn reason(self: Outcome) []const u8 {
        return switch (self) {
            .passed => "all block and final-state expectations met",
            .failed => "fixture, import, or verification failure",
            .ethash_pow_seal => "Ethash DAG proof-of-work verification is outside ZEVM's scope",
            .other_seal => "unrecognized fixture seal engine",
            .transition_fork => "fixture-specific activation schedule required",
            .legacy_pow => "PoW difficulty, ommer ancestry and total-difficulty fork choice required",
            .other_fork => "network outside the supported Merge through Prague rules",
        };
    }
};

fn parseFork(name: []const u8) ?Fork {
    if (eq(u8, name, "EIP150")) return .TANGERINE_WHISTLE;
    if (eq(u8, name, "EIP158")) return .SPURIOUS_DRAGON;
    if (eq(u8, name, "ConstantinopleFix")) return .PETERSBURG;
    if (eq(u8, name, "Paris")) return .MERGE;
    return Fork.fromString(name);
}

fn classify(seal: []const u8, network: []const u8) ?Outcome {
    if (eq(u8, seal, "Ethash")) return .ethash_pow_seal;
    if (!eq(u8, seal, "NoProof")) return .other_seal;
    if (std.mem.indexOf(u8, network, "To") != null) return .transition_fork;
    const fork = parseFork(network) orelse return .other_fork;
    if (fork.isBefore(.MERGE)) return .legacy_pow;
    if (fork.isAtLeast(.OSAKA)) return .other_fork;
    return null;
}

fn field(obj: Json, key: []const u8) !Json {
    if (obj != .object) return error.InvalidFixture;
    return obj.object.get(key) orelse error.MissingField;
}
fn string(obj: Json, key: []const u8) ![]const u8 {
    const v = try field(obj, key);
    if (v != .string) return error.InvalidFixture;
    return v.string;
}
fn bytes(a: Allocator, s: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, s, "0x") or s.len % 2 != 0) return error.InvalidHex;
    return std.fmt.hexToBytes(try a.alloc(u8, (s.len - 2) / 2), s[2..]);
}
fn hash(obj: Json, key: []const u8) !Hash {
    const s = try string(obj, key);
    if (s.len != 66 or !std.mem.startsWith(u8, s, "0x")) return error.InvalidHash;
    var h: Hash = undefined;
    _ = try std.fmt.hexToBytes(&h, s[2..]);
    return h;
}
fn seed(a: Allocator, sm: *State, accounts: Json) !void {
    if (accounts != .object) return error.InvalidFixture;
    var it = accounts.object.iterator();
    while (it.next()) |entry| {
        const addr = try primitives.Address.fromHex(entry.key_ptr.*);
        const account = entry.value_ptr.*;
        try sm.initAccount(addr, try std.fmt.parseInt(u256, try string(account, "balance"), 0));
        try sm.setNonce(addr, try std.fmt.parseInt(u64, try string(account, "nonce"), 0));
        try sm.setCode(addr, try bytes(a, try string(account, "code")));
        const storage = try field(account, "storage");
        if (storage != .object) return error.InvalidFixture;
        var slots = storage.object.iterator();
        while (slots.next()) |slot| {
            if (slot.value_ptr.* != .string) return error.InvalidFixture;
            try sm.setStorage(addr, try std.fmt.parseInt(u256, slot.key_ptr.*, 0), try std.fmt.parseInt(u256, slot.value_ptr.string, 0));
        }
    }
}
fn transaction(a: Allocator, raw: []const u8, fork: Fork, chain_id: u64, blob_fee: u256) !zevm.tx_processor.ExecutionTx {
    try encoding.requireCanonicalEnvelope(raw);
    const d = try encoding.decodeEnvelope(a, raw);
    _ = try zevm.tx_processor.validateEnvelope(d, fork, chain_id);
    const list = encoding.envelopeAccessList(d);
    const access = try a.alloc(primitives.AccessList.AccessListEntry, list.len);
    for (list, access) |src, *dst| dst.* = .{ .address = src.address, .storage_keys = src.storage_keys };
    const auth = encoding.envelopeAuthorizationList(d);
    const gas = encoding.envelopeBlobGasUsed(d);
    return .{
        .caller = try encoding.recoverEnvelopeSenderForFork(a, d, fork),
        .tx = encoding.envelopeToLegacyLikeTx(d),
        .raw = raw,
        .tx_hash = encoding.transactionHash(raw),
        .receipt_type = encoding.envelopeReceiptType(d),
        .access_list = if (access.len > 0) access else null,
        .authorization_list = if (auth.len > 0) auth else null,
        .blob_gas_used = gas,
        .blob_gas_price = if (gas != null) blob_fee else null,
        .blob_versioned_hashes = try encoding.envelopeBlobVersionedHashBytes(a, d),
        .max_fee_per_blob_gas = encoding.envelopeMaxFeePerBlobGas(d),
        .max_fee_per_gas = encoding.envelopeMaxFeePerGas(d),
        .max_priority_fee_per_gas = encoding.envelopeMaxPriorityFeePerGas(d),
    };
}

const Replay = struct {
    a: Allocator,
    chain: zevm.blockchain.Blockchain,
    sm: State,
    pre: Json,
    fork: Fork,
    chain_id: u64,
    config: zevm.hardfork_schedule.ChainConfig,
    state_tip: Hash,
    head: Block,

    fn execute(self: *Replay, block: Block) !void {
        const h = block.header;
        const parent = self.chain.getBlockLocal(h.parent_hash) orelse return error.InvalidParentHash;
        const f = builder.hardforkFromEvm(self.fork);
        try zevm.chain_import.validateBlockLinkage(h, parent.hash, parent.header.number);
        try builder.validateHeader(&h, &parent.header, f);
        if (h.gas_limit > std.math.maxInt(i64)) return error.InvalidGasLimit;
        if (block.body.ommers.len != 0) return error.InvalidOmmersHash;
        try zevm.chain_import.validateImportedBlobHeader(self.config, parent.header, h);
        const fee = zevm.blob_fee.blobParamsForFork(self.config, self.fork, h.timestamp).baseFee(h.excess_blob_gas orelse 0);
        const txs = try self.a.alloc(zevm.tx_processor.ExecutionTx, block.body.transactions.len);
        for (block.body.transactions, txs) |data, *tx| tx.* = try transaction(self.a, data.raw, self.fork, self.chain_id, fee);
        var recent: [256]Hash = undefined;
        const ctx = evm.BlockContext{
            .chain_id = self.chain_id,
            .block_number = h.number,
            .block_timestamp = h.timestamp,
            .block_coinbase = h.beneficiary,
            .block_difficulty = h.difficulty,
            .block_prevrandao = std.mem.readInt(u256, &h.mix_hash, .big),
            .block_gas_limit = h.gas_limit,
            .block_base_fee = h.base_fee_per_gas orelse 0,
            .blob_base_fee = fee,
            .block_hashes = try self.chain.last256BlockHashesLocal(parent.hash, &recent),
        };
        var adapter = zevm.host_adapter.HostAdapter{ .state = &self.sm };
        try self.sm.checkpoint();
        errdefer self.sm.revert();
        var result = try builder.buildBlockWithOptions(self.a, &self.sm, adapter.hostInterface(), txs, ctx, .{
            .fork = f,
            .hardfork_config = self.config,
            .parent_hash = parent.hash,
            .withdrawals = block.body.withdrawals,
            .parent_beacon_block_root = h.parent_beacon_block_root,
            .require_system_contracts = true,
        });
        defer result.deinit(self.a);
        _ = try builder.validateBlock(self.a, .{
            .header = &h,
            .parent_header = &parent.header,
            .parent_hash = parent.hash,
            .ommers_hash = primitives.BlockHeader.EMPTY_OMMERS_HASH,
            .fork = f,
            .hardfork_config = self.config,
            .execution_transactions = txs,
            .transaction_envelopes = block.body.transactions,
            .receipts = result.receipts,
            .withdrawals = block.body.withdrawals,
            .state_root = result.state_root,
            .requests_hash = h.requests_hash,
            .computed_requests_hash = result.computed_requests_hash,
        });
        self.sm.commit();
        self.state_tip = block.hash;
    }

    // Branch labels are descriptive. Follow the authenticated RLP parent links.
    fn checkout(self: *Replay, tip: Hash) !void {
        if (eq(u8, &tip, &self.state_tip)) return;
        var branch: std.ArrayList(Block) = .empty;
        var cursor = self.chain.getBlockLocal(tip) orelse return error.InvalidParentHash;
        while (cursor.header.number != 0) {
            try branch.append(self.a, cursor);
            cursor = self.chain.getBlockLocal(cursor.header.parent_hash) orelse return error.BrokenReplayHistory;
        }
        const fresh = try State.init(self.a, null);
        self.sm.deinit();
        self.sm = fresh;
        try seed(self.a, &self.sm, self.pre);
        self.state_tip = cursor.hash;
        var i = branch.items.len;
        while (i > 0) {
            i -= 1;
            self.execute(branch.items[i]) catch return error.BranchReplayFailed;
        }
    }
};

fn decode(a: Allocator, raw: []const u8) !Block {
    const d = try zevm.chain_import.decodeNextBlock(a, raw);
    if (d.block.size != raw.len) return error.InvalidChainRlp;
    var b = d.block;
    b.header.requests_hash = d.owned_body.requests_hash;
    return b;
}
fn deterministic(err: anyerror) bool {
    return zevm.node_runtime.isDeterministicPayloadError(err) or switch (err) {
        error.InvalidChainRlp, error.InvalidBlockHeader, error.MissingBlobGas, error.UnexpectedBlobGas, error.InvalidIncludedTransaction, error.ChainIdMismatch, error.NonceTooLarge, error.GasCostOverflow => true,
        else => false,
    };
}
fn runCase(a: Allocator, v: Json) !Outcome {
    const network = try string(v, "network");
    if (classify(try string(v, "sealEngine"), network)) |outcome| return outcome;
    const fork = parseFork(network).?;
    const genesis = try decode(a, try bytes(a, try string(v, "genesisRLP")));
    if (genesis.header.number != 0 or !eq(u8, &genesis.hash, &try hash(try field(v, "genesisBlockHeader"), "hash"))) return error.InvalidGenesis;
    const never = std.math.maxInt(u64);
    const pre = try field(v, "pre");
    const id = if (v.object.get("config")) |config| try std.fmt.parseInt(u64, try string(config, "chainid"), 0) else 1;
    var replay = Replay{
        .a = a,
        .chain = try zevm.blockchain.Blockchain.init(a, null),
        .sm = try State.init(a, null),
        .pre = pre,
        .fork = fork,
        .chain_id = id,
        .config = .{
            .merge_block = 0,
            .shanghai_timestamp = if (fork.isAtLeast(.SHANGHAI)) 0 else never,
            .cancun_timestamp = if (fork.isAtLeast(.CANCUN)) 0 else never,
            .prague_timestamp = if (fork.isAtLeast(.PRAGUE)) 0 else never,
            .osaka_timestamp = never,
        },
        .state_tip = genesis.hash,
        .head = genesis,
    };
    defer replay.chain.deinit();
    defer replay.sm.deinit();
    try seed(a, &replay.sm, pre);
    if (!eq(u8, &try builder.computeStateRoot(a, &replay.sm), &genesis.header.state_root)) return error.GenesisStateMismatch;
    try replay.chain.putBlock(genesis);
    try replay.chain.setCanonicalHead(genesis.hash);

    const blocks = try field(v, "blocks");
    if (blocks != .array) return error.InvalidFixture;
    for (blocks.array.items) |item| {
        const raw = try bytes(a, try string(item, "rlp"));
        const rejection = item.object.get("expectException");
        if (rejection) |e| {
            if (e != .string or e.string.len == 0) return error.InvalidFixture;
        }
        const b = decode(a, raw) catch |err| {
            if (rejection != null and deterministic(err)) continue;
            return err;
        };
        replay.checkout(b.header.parent_hash) catch |err| {
            if (rejection != null and err == error.InvalidParentHash) continue;
            return err;
        };
        replay.execute(b) catch |err| {
            if (rejection != null and deterministic(err)) continue;
            return err;
        };
        if (rejection != null) return error.ExpectedBlockRejection;
        if (item.object.get("blockHeader")) |header| {
            if (!eq(u8, &b.hash, &try hash(header, "hash"))) return error.FixtureBlockHashMismatch;
        }
        try replay.chain.putBlock(b);
        if (b.header.number > replay.head.header.number) {
            try replay.chain.setCanonicalHead(b.hash);
            replay.head = b;
        }
    }
    const canonical = replay.chain.getCanonicalHash(replay.head.header.number) orelse return error.MissingHead;
    if (!eq(u8, &canonical, &try hash(v, "lastblockhash"))) return error.HeadMismatch;
    try replay.checkout(canonical);
    const root = try builder.computeStateRoot(a, &replay.sm);
    if (!eq(u8, &root, &replay.head.header.state_root)) return error.FinalStateMismatch;
    if (v.object.contains("postStateHash") and !eq(u8, &root, &try hash(v, "postStateHash"))) return error.FinalStateMismatch;
    if (v.object.get("postState")) |post| {
        var expected = try State.init(a, null);
        defer expected.deinit();
        try seed(a, &expected, post);
        if (!eq(u8, &root, &try builder.computeStateRoot(a, &expected))) return error.FinalStateMismatch;
    } else if (!v.object.contains("postStateHash")) return error.MissingExpectedState;
    return .passed;
}

const Counts = std.EnumArray(Outcome, usize);
const Options = struct {
    path: []const u8 = "lib/ethereum-tests/BlockchainTests",
    filter: []const u8 = "",
    mode: enum { normal, verbose, summary } = .normal,
};
fn options(args: []const []const u8) !Options {
    var opts: Options = .{};
    var seen_path = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eq(u8, arg, "--filter")) {
            i += 1;
            if (i == args.len) return error.MissingFilter;
            opts.filter = args[i];
        } else if (eq(u8, arg, "--summary-only")) {
            opts.mode = .summary;
        } else if (eq(u8, arg, "--verbose")) {
            opts.mode = .verbose;
        } else {
            if (std.mem.startsWith(u8, arg, "-") or seen_path) return error.InvalidArgument;
            opts.path = arg;
            seen_path = true;
        }
    }
    return opts;
}
fn runFile(dir: std.fs.Dir, path: []const u8, opts: Options, counts: *Counts) !void {
    var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer file_arena.deinit();
    const a = file_arena.allocator();
    const data = try dir.readFileAlloc(a, path, 256 * 1024 * 1024);
    const fixtures = try std.json.parseFromSliceLeaky(Json, a, data, .{});
    if (fixtures != .object or fixtures.object.count() == 0) return error.EmptyFixtureFile;
    var it = fixtures.object.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (std.mem.indexOf(u8, path, opts.filter) == null and std.mem.indexOf(u8, name, opts.filter) == null) continue;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const outcome = runCase(arena.allocator(), entry.value_ptr.*) catch |err| {
            if (opts.mode != .summary) std.debug.print("{s} [{s}] {s}\n", .{ path, name, @errorName(err) });
            counts.getPtr(.failed).* += 1;
            continue;
        };
        counts.getPtr(outcome).* += 1;
        if (opts.mode == .verbose) std.debug.print("{s} [{s}] {s}\n", .{ path, name, @tagName(outcome) });
    }
}
fn less(_: void, l: []const u8, r: []const u8) bool {
    return std.mem.lessThan(u8, l, r);
}
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    const opts = try options(args[1..]);
    var dir = try std.fs.cwd().openDir(opts.path, .{ .iterate = true });
    defer dir.close();
    var walker = try dir.walk(a);
    defer walker.deinit();
    var paths: std.ArrayList([]const u8) = .empty;
    while (try walker.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".json") and !eq(u8, entry.path, ".meta/index.json")) try paths.append(a, try a.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, paths.items, {}, less);
    var counts = Counts.initFill(0);
    var file_errors: usize = 0;
    for (paths.items) |path| runFile(dir, path, opts, &counts) catch |err| {
        if (opts.mode != .summary) std.debug.print("{s} {s}\n", .{ path, @errorName(err) });
        file_errors += 1;
    };
    std.debug.print("BlockchainTests\n{s:<20} {s:>8}  {s}\n", .{ "outcome", "cases", "reason" });
    var total: usize = 0;
    inline for (std.meta.tags(Outcome)) |o| {
        const count = counts.get(o);
        total += count;
        std.debug.print("{s:<20} {d:>8}  {s}\n", .{ @tagName(o), count, o.reason() });
    }
    std.debug.print("{d} selected cases, {d} file errors\n", .{ total, file_errors });
    if (file_errors != 0 or counts.get(.failed) != 0) return error.BlockchainTestsFailed;
    if (total == 0) return error.NoMatchingFixtures;
}

test "fork aliases and seal engines" {
    try std.testing.expectEqual(Fork.PETERSBURG, parseFork("ConstantinopleFix").?);
    try std.testing.expectEqual(Fork.TANGERINE_WHISTLE, parseFork("EIP150").?);
    try std.testing.expectEqual(Fork.SPURIOUS_DRAGON, parseFork("EIP158").?);
    try std.testing.expect(classify("NoProof", "Paris") == null);
    try std.testing.expectEqual(Outcome.legacy_pow, classify("NoProof", "Frontier").?);
    try std.testing.expectEqual(Outcome.ethash_pow_seal, classify("Ethash", "London").?);
    try std.testing.expectEqual(Outcome.transition_fork, classify("NoProof", "FrontierToHomesteadAt5").?);
}

fn emptyBlockRlp(a: Allocator, h: *const primitives.BlockHeader.BlockHeader) ![]const u8 {
    const header = try primitives.BlockHeader.rlpEncode(h, a);
    const payload = header.len + 2;
    const wire = try a.alloc(u8, 3 + payload);
    wire[0] = 0xf9;
    std.mem.writeInt(u16, wire[1..3], @intCast(payload), .big);
    @memcpy(wire[3..][0..header.len], header);
    @memset(wire[3 + header.len ..], 0xc0);
    return wire;
}
test "inline NoProof valid import and invalid commitment leave the expected head" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var h = primitives.BlockHeader.BlockHeader{
        .ommers_hash = primitives.BlockHeader.EMPTY_OMMERS_HASH,
        .transactions_root = primitives.BlockHeader.EMPTY_TRANSACTIONS_ROOT,
        .receipts_root = primitives.BlockHeader.EMPTY_RECEIPTS_ROOT,
        .state_root = primitives.State.EMPTY_TRIE_ROOT,
        .difficulty = 0,
        .base_fee_per_gas = 8,
        .gas_limit = 1000000,
    };
    const genesis = try emptyBlockRlp(a, &h);
    const genesis_hash = (try decode(a, genesis)).hash;
    h.parent_hash = genesis_hash;
    h.number = 1;
    h.timestamp = 1;
    h.base_fee_per_gas = 7;
    const child = try emptyBlockRlp(a, &h);
    const child_hash = (try decode(a, child)).hash;
    h.receipts_root = [_]u8{0xff} ** 32;
    const invalid = try emptyBlockRlp(a, &h);
    for ([_]bool{ false, true }) |expect_invalid| {
        const json = try std.json.Stringify.valueAlloc(a, .{
            .network = "Paris",
            .sealEngine = "NoProof",
            .genesisBlockHeader = .{ .hash = try std.fmt.allocPrint(a, "0x{x}", .{&genesis_hash}) },
            .genesisRLP = try std.fmt.allocPrint(a, "0x{x}", .{genesis}),
            .pre = struct {}{},
            .postState = struct {}{},
            .lastblockhash = try std.fmt.allocPrint(a, "0x{x}", .{if (expect_invalid) &genesis_hash else &child_hash}),
            .blocks = .{.{ .rlp = try std.fmt.allocPrint(a, "0x{x}", .{if (expect_invalid) invalid else child}), .expectException = if (expect_invalid) @as(?[]const u8, "InvalidReceiptsRoot") else null }},
        }, .{ .emit_null_optional_fields = false });
        const fixture = try std.json.parseFromSliceLeaky(Json, a, json, .{});
        try std.testing.expectEqual(Outcome.passed, try runCase(a, fixture));
    }
}
