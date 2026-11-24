const std = @import("std");
const primitives = @import("primitives");
const beacon = @import("../beacon_api.zig");
const sync = @import("../consensus_sync.zig");
const verifier = @import("../consensus_verifier.zig");
const light = @import("../light_proof.zig");
const mpt = @import("../mpt_proof.zig");

test "fork version follows the network schedule throughout the u64 domain" {
    var prng = std.Random.DefaultPrng.init(0xf042);
    const r = prng.random();
    const networks = [_]sync.NetworkConfig{ sync.NetworkConfig.mainnet(""), sync.NetworkConfig.sepolia(""), sync.NetworkConfig.holesky(""), sync.NetworkConfig.hoodi("") };
    const schedules = [_][]const u64{ &.{ 0, 74240, 144896, 194048, 269568, 364032, 411392 }, &.{ 0, 50, 100, 56832, 132608, 222464, 272640, 353024 }, &.{ 0, 0, 0, 256, 29696, 115968, 165120 }, &.{ 0, 0, 0, 0, 0, 2048, 50688 } };
    for (networks, schedules, 0..) |network, epochs, id| {
        for (0..384) |i| {
            const boundary = epochs[i % epochs.len];
            for ([_]u64{ boundary -| 1, boundary, boundary + 1, std.math.maxInt(u64), r.int(u64), r.uintLessThan(u64, epochs[epochs.len - 1] + 1) }) |epoch| {
                var fork: u8 = 0;
                for (epochs, 0..) |start, j| {
                    if (start <= epoch) fork = @intCast(j);
                }
                const version: [4]u8 = switch (id) {
                    0 => .{ fork, 0, 0, 0 },
                    1 => .{ 0x90, 0, 0, if (fork == 0) 0x69 else 0x6f + fork },
                    2 => .{ fork + 1, 1, 0x70, 0 },
                    else => .{ (fork + 1) * 16, 0, 9, 0x10 },
                };
                try std.testing.expectEqual(version, network.fork_config.forkVersionForEpoch(epoch));
            }
        }
    }
}

test "weak subjectivity age saturates and the strict cutoff is exclusive" {
    var prng = std.Random.DefaultPrng.init(0xa9e);
    const r = prng.random();
    var engine = sync.ConsensusSyncEngine.init(sync.NetworkConfig.mainnet(""));
    for (0..320) |_| {
        const checkpoint = r.int(u64);
        const limit = r.int(u32);
        engine.config.max_checkpoint_age = limit;
        for ([_]u64{ r.int(u64), checkpoint -| 1, checkpoint, checkpoint +| limit, checkpoint +| limit +| 1 }) |startup| {
            const info = engine.checkpointAgeInfoFromTimes(checkpoint, startup);
            const expected = if (startup >= checkpoint) startup - checkpoint else 0;
            try std.testing.expectEqual(expected, info.age_seconds);
            try std.testing.expectEqual(expected > limit, info.stale);
            const later = engine.checkpointAgeInfoFromTimes(checkpoint, startup +| r.int(u64));
            try std.testing.expect(later.age_seconds >= info.age_seconds and (!info.stale or later.stale));
            for ([_]bool{ false, true }) |strict| {
                engine.config.strict_checkpoint_age = strict;
                const result = engine.enforceStartupCheckpointAge(engine.config.default_checkpoint, .{ .source = "property" }, info);
                if (strict and expected > limit) try std.testing.expectError(error.CheckpointTooOld, result) else try result;
            }
        }
    }
}

fn flip(bytes: []u8, r: std.Random) void {
    bytes[r.uintLessThan(usize, bytes.len)] ^= @as(u8, 1) << r.int(u3);
}

test "SSZ branches bind the leaf, sibling hashes, path bits and root" {
    var prng = std.Random.DefaultPrng.init(0x55a);
    const r = prng.random();
    for (0..384) |_| {
        const depth = r.intRangeAtMost(u6, 1, 12);
        var siblings: [12][32]u8 = undefined;
        const branch = siblings[0..depth];
        var leaf: [32]u8 = undefined;
        r.bytes(&leaf);
        r.bytes(std.mem.sliceAsBytes(branch));
        const index = r.uintLessThan(u64, @as(u64, 1) << depth);
        var root = leaf;
        for (branch, 0..) |sibling, i| {
            var h = std.crypto.hash.sha2.Sha256.init(.{});
            const right = (index >> @intCast(i)) & 1 != 0;
            h.update(if (right) &sibling else &root);
            h.update(if (right) &root else &sibling);
            h.final(&root);
        }
        const verify = primitives.consensus.isValidMerkleBranch;
        try std.testing.expect(verify(leaf, branch, depth, index, root));
        var bad = leaf;
        flip(&bad, r);
        try std.testing.expect(!verify(bad, branch, depth, index, root));
        bad = root;
        flip(&bad, r);
        try std.testing.expect(!verify(leaf, branch, depth, index, bad));
        try std.testing.expect(!verify(leaf, branch, depth, index ^ (@as(u64, 1) << r.uintLessThan(u6, depth)), root));
        flip(&branch[r.uintLessThan(usize, depth)], r);
        try std.testing.expect(!verify(leaf, branch, depth, index, root));
    }
}

fn checkProof(comptime verify: anytype, proof: *mpt.Proof, key: []const u8, value: []const u8, r: std.Random) !void {
    const a = std.testing.allocator;
    try std.testing.expect(try verify(a, &proof.root, key, value, proof.nodes));
    const bad_key = try a.dupe(u8, key);
    defer a.free(bad_key);
    flip(bad_key, r);
    try std.testing.expect(!(verify(a, &proof.root, bad_key, value, proof.nodes) catch false));
    const bad_value = try a.dupe(u8, value);
    defer a.free(bad_value);
    flip(bad_value, r);
    try std.testing.expect(!(verify(a, &proof.root, key, bad_value, proof.nodes) catch false));
    var root = proof.root;
    flip(&root, r);
    try std.testing.expect(!(verify(a, &root, key, value, proof.nodes) catch false));
    for (proof.nodes) |node| {
        const pos = r.uintLessThan(usize, node.len);
        const mask = @as(u8, 1) << r.int(u3);
        node[pos] ^= mask;
        defer node[pos] ^= mask;
        try std.testing.expect(!(verify(a, &proof.root, key, value, proof.nodes) catch false));
    }
}

test "secure account and storage tries bind every component of inclusion proofs" {
    var prng = std.Random.DefaultPrng.init(0xe1186);
    const r = prng.random();
    const a = std.testing.allocator;
    for (0..300) |_| {
        var slots: [3][32]u8 = undefined;
        var addresses: [3][20]u8 = undefined;
        var values: [3][33]u8 = undefined;
        var slot_keys: [3][]const u8 = undefined;
        var address_keys: [3][]const u8 = undefined;
        var storage_values: [3][]const u8 = undefined;
        const target = r.uintLessThan(usize, 3);
        for (0..3) |i| {
            r.bytes(&slots[i]);
            r.bytes(&addresses[i]);
            slots[i][0] = @intCast(i);
            addresses[i][0] = @intCast(i);
            slot_keys[i] = &slots[i];
            address_keys[i] = &addresses[i];
            // Canonical RLP of a full-width nonzero storage integer.
            values[i][0] = 0xa0;
            r.bytes(values[i][1..]);
            values[i][1] |= 1;
            storage_values[i] = &values[i];
        }
        var storage = try mpt.secureProof(a, &slot_keys, &storage_values, slot_keys[target]);
        defer storage.deinit(a);
        try checkProof(primitives.Proof.verifyStorageSlotProof, &storage, slot_keys[target], storage_values[target], r);
        var accounts: [3][]const u8 = undefined;
        var target_account: primitives.AccountState.AccountState = undefined;
        var built: usize = 0;
        defer for (accounts[0..built]) |value| a.free(value);
        for (&accounts) |*value| {
            const account = primitives.AccountState.AccountState.from(.{ .nonce = r.int(u64), .balance = r.int(u256), .storage_root = storage.root });
            if (built == target) target_account = account;
            value.* = try account.rlpEncode(a);
            built += 1;
        }
        var state = try mpt.secureProof(a, &address_keys, &accounts, address_keys[target]);
        defer state.deinit(a);
        try checkProof(primitives.Proof.verifyAccountProof, &state, address_keys[target], accounts[target], r);
        // Resolve the JSON at the RPC boundary and authenticate both nested tries.
        var json = std.Io.Writer.Allocating.init(a);
        defer json.deinit();
        const w = &json.writer;
        try w.print("{{\"nonce\":\"0x{x}\",\"balance\":\"0x{x}\",\"codeHash\":\"0x{x}\",\"storageHash\":\"0x{x}\",\"accountProof\":", .{ target_account.nonce, target_account.balance, &target_account.code_hash, &storage.root });
        try writeNodes(w, state.nodes);
        const slot = std.mem.readInt(u256, &slots[target], .big);
        const expected = std.mem.readInt(u256, values[target][1..33], .big);
        try w.print(",\"storageProof\":[{{\"key\":\"0x{x}\",\"value\":\"0x{x}\",\"proof\":", .{ slot, expected });
        try writeNodes(w, storage.nodes);
        try w.writeAll("}]}");
        const source = light.ProofSource{ .url = json.written(), .resolver = .{ .resolve = fixture, .context = null } };
        try std.testing.expectEqual(expected, try light.readStorage(a, source, state.root, .{ .bytes = addresses[target] }, slot, "latest"));
    }
}

fn writeNodes(w: *std.Io.Writer, nodes: []const []const u8) !void {
    try w.writeByte('[');
    for (nodes, 0..) |node, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("\"0x{x}\"", .{node});
    }
    try w.writeByte(']');
}

const hash_json = "\"0x" ++ "00" ** 32 ++ "\"";
const aggregate = "\"sync_aggregate\":{\"sync_committee_bits\":\"0x" ++ "00" ** 64 ++ "\",\"sync_committee_signature\":\"0x" ++ "00" ** 96 ++ "\"}";
const committee = "\"current_sync_committee\":{\"pubkeys\":[],\"aggregate_pubkey\":\"0x\"}";
const six_roots = "[" ++ (hash_json ++ ",") ** 5 ++ hash_json ++ "]";
const header = "{\"beacon\":{\"slot\":\"1\",\"proposer_index\":\"0\",\"parent_root\":\"0x0000000000000000000000000000000000000000000000000000000000000000\",\"state_root\":\"0x0000000000000000000000000000000000000000000000000000000000000000\",\"body_root\":\"0x0000000000000000000000000000000000000000000000000000000000000000\"},\"execution\":{\"parent_hash\":\"0x0000000000000000000000000000000000000000000000000000000000000000\",\"state_root\":\"0x0000000000000000000000000000000000000000000000000000000000000000\",\"receipts_root\":\"0x0000000000000000000000000000000000000000000000000000000000000000\",\"prev_randao\":\"0x0000000000000000000000000000000000000000000000000000000000000000\",\"block_hash\":\"0x0000000000000000000000000000000000000000000000000000000000000000\",\"transactions_root\":\"0x0000000000000000000000000000000000000000000000000000000000000000\",\"withdrawals_root\":\"0x0000000000000000000000000000000000000000000000000000000000000000\",\"block_number\":\"0\",\"gas_limit\":\"0\",\"gas_used\":\"0\",\"timestamp\":\"0\",\"base_fee_per_gas\":\"0\",\"blob_gas_used\":\"0\",\"excess_blob_gas\":\"0\",\"fee_recipient\":\"0x0000000000000000000000000000000000000000\",\"logs_bloom\":\"0x00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000\"},\"execution_branch\":[\"0x0000000000000000000000000000000000000000000000000000000000000000\",\"0x0000000000000000000000000000000000000000000000000000000000000000\",\"0x0000000000000000000000000000000000000000000000000000000000000000\",\"0x0000000000000000000000000000000000000000000000000000000000000000\"]}";
const key_json = "\"0x" ++ "00" ** 48 ++ "\"";
const committee_json = "{\"pubkeys\":[" ++ (key_json ++ ",") ** 511 ++ key_json ++ "],\"aggregate_pubkey\":" ++ key_json ++ "}";
const seven_roots = "[" ++ (hash_json ++ ",") ** 6 ++ hash_json ++ "]";
const optimistic_fields = aggregate ++ ",\"signature_slot\":\"2\",\"attested_header\":" ++ header;
const finality_fields = optimistic_fields ++ ",\"finalized_header\":" ++ header ++ ",\"finality_branch\":" ++ seven_roots;
const bootstrap_fields = "\"header\":" ++ header ++ ",\"current_sync_committee\":" ++ committee_json ++ ",\"current_sync_committee_branch\":" ++ six_roots;
const electra_prefix = "{\"version\":\"electra\",\"data\":{";
const bootstrap_json = electra_prefix ++ bootstrap_fields ++ "}}";

test "Fulu bootstrap accepts the post-Electra committee branch depth" {
    _ = try beacon.parseBootstrapResponse(std.testing.allocator, bootstrap_json);
    _ = try beacon.parseBootstrapResponse(std.testing.allocator, "{\"version\":\"fulu\",\"data\":{" ++ bootstrap_fields ++ "}}");
}
test "fuzz: beacon light client responses and bootstrap verification" {
    try std.testing.fuzz({}, fuzzBeacon, .{ .corpus = &.{
        bootstrap_json,
        electra_prefix ++ optimistic_fields ++ "}}",
        electra_prefix ++ finality_fields ++ "}}",
        "[" ++ electra_prefix ++ finality_fields ++ ",\"next_sync_committee\":" ++ committee_json ++ ",\"next_sync_committee_branch\":" ++ six_roots ++ "}}]",
        "[]",
        "{\"data\":[]}",
        "{\"version\":\"electra\",\"data\":{" ++ committee ++ ",\"current_sync_committee_branch\":" ++ six_roots ++ "}}",
        "[{\"version\":\"deneb\",\"data\":{" ++ aggregate ++ ",\"next_sync_committee\":{}}}]",
        "{" ++ aggregate ++ ",\"finality_branch\":" ++ six_roots ++ "}",
        "{" ++ aggregate ++ ",\"attested_header\":{\"beacon\":{\"slot\":\"18446744073709551616\"}}}",
        "{\"version\":\"fulu\",\"data\":null}",
        "\xff",
    } });
}
fn fuzzBeacon(_: void, input: []const u8) !void {
    const a = std.testing.allocator;
    if (beacon.parseBootstrapResponse(a, input)) |bootstrap| {
        verifier.verifyBootstrap(bootstrap, verifier.beaconHeaderRoot(bootstrap.header.beacon), primitives.ForkConfig.ForkConfig.mainnet(), a) catch {};
    } else |_| {}
    if (beacon.parseUpdatesResponse(a, input)) |updates| {
        defer a.free(updates);
        const engine = sync.ConsensusSyncEngine.init(sync.NetworkConfig.mainnet(""));
        for (updates) |update| verifier.verifyUpdate(sync.genericFromLightClientUpdate(update), update.signature_slot, engine.store, engine.config.genesis_validators_root, engine.config.fork_config, a) catch {};
    } else |_| {}
    _ = beacon.parseFinalityUpdateResponse(a, input) catch {};
    _ = beacon.parseOptimisticUpdateResponse(a, input) catch {};
}

fn fixture(_: ?*anyopaque, a: std.mem.Allocator, request: light.RpcRequest) ![]u8 {
    return a.dupe(u8, request.url);
}
const empty_account = "{\"nonce\":\"0x0\",\"balance\":\"0x0\",\"codeHash\":\"0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470\",\"storageHash\":\"0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421\",\"accountProof\":[],\"storageProof\":[{\"key\":\"0x0\",\"value\":\"0x0\",\"proof\":[]}]}";
test "fuzz: EIP-1186 response decoding and authenticated RLP nodes" {
    try fuzzProof({}, "");
    try std.testing.fuzz({}, fuzzProof, .{ .corpus = &.{
        empty_account,          "{\"accountProof\":[\"0xc0\",\"0xgg\"]}", "{\"accountProof\":[],\"storageProof\":[{\"key\":\"0x0\",\"value\":\"0x1\",\"proof\":[\"0xc0\"]},null]}",
        "\xc0",                 "\x80",                                   "\xc2\x20\x01",
        "\xd1" ++ "\x80" ** 17, "\xe3\xa1\x20" ++ "\x00" ** 32 ++ "\x01",
    } });
}
fn fuzzProof(_: void, input: []const u8) !void {
    const a = std.testing.allocator;
    const source = light.ProofSource{ .url = input, .resolver = .{ .resolve = fixture, .context = null } };
    _ = light.readStorage(a, source, primitives.State.EMPTY_TRIE_ROOT, .{ .bytes = [_]u8{0} ** 20 }, 0, "latest") catch {};
    // Authenticate the mutated node so the verifier actually decodes its RLP.
    var root: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(input, &root, .{});
    _ = primitives.Proof.verifyStorageSlotProof(a, &root, &([_]u8{0} ** 32), "\x01", &.{input}) catch {};
}
