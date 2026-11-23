const std = @import("std");
const primitives = @import("primitives");
const jsonrpc = @import("jsonrpc");
const mpt_proof = @import("../mpt_proof.zig");
const blob_kzg = @import("../blob_kzg.zig");
const transaction_encoding = @import("../transaction_encoding.zig");
const execution_fixture_rpc = @import("../execution_fixture_rpc.zig");

fn fuzzMptSecureProof(_: void, input: []const u8) anyerror!void {
    const allocator = std.testing.allocator;
    if (input.len == 0) {
        var empty = try mpt_proof.secureProof(allocator, &.{}, &.{}, "missing");
        defer empty.deinit(allocator);
        try std.testing.expectEqual(primitives.State.EMPTY_TRIE_ROOT, empty.root);
        try std.testing.expectEqual(@as(usize, 0), empty.nodes.len);
        return;
    }

    const entry_count: usize = @min(@as(usize, input[0] & 0x0f) + 1, 16);
    var keys_storage: [16][32]u8 = undefined;
    var vals_storage: [16][36]u8 = undefined;
    var keys: [16][]const u8 = undefined;
    var vals: [16][]const u8 = undefined;

    var cursor: usize = 1;
    var actual_count: usize = 0;

    for (0..entry_count) |i| {
        const key_len: usize = if (cursor < input.len) blk: {
            const k = @as(usize, input[cursor] % 32) + 1;
            cursor += 1;
            break :blk k;
        } else 20;

        // Build key with deterministic uniqueness byte to avoid duplicate-key collisions in TrieHash,
        // while keeping arbitrary lengths and shared prefixes.
        @memset(&keys_storage[i], 0);
        const avail_k = @min(key_len, input.len -| cursor);
        if (avail_k > 0) {
            @memcpy(keys_storage[i][0..avail_k], input[cursor .. cursor + avail_k]);
            cursor += avail_k;
        }
        keys_storage[i][key_len - 1] = @intCast(i);
        keys[i] = keys_storage[i][0..key_len];

        // Build non-empty canonical RLP-like payload (1..33 bytes) so both inline (<32B) and
        // hash-referenced (>=32B) trie nodes are heavily exercised.
        const raw_len: usize = if (cursor < input.len) blk: {
            const v = @as(usize, input[cursor] % 33) + 1;
            cursor += 1;
            break :blk v;
        } else 1;

        var raw_val = [_]u8{0} ** 33;
        const avail_v = @min(raw_len, input.len -| cursor);
        if (avail_v > 0) {
            @memcpy(raw_val[0..avail_v], input[cursor .. cursor + avail_v]);
            cursor += avail_v;
        }
        if (raw_val[0] == 0) raw_val[0] = @intCast((i % 127) + 1);

        const encoded = try primitives.Rlp.encodeBytes(allocator, raw_val[0..raw_len]);
        defer allocator.free(encoded);
        @memcpy(vals_storage[i][0..encoded.len], encoded);
        vals[i] = vals_storage[i][0..encoded.len];
        actual_count += 1;
    }

    const expected_root = try primitives.TrieHash.secure_trie_root(allocator, keys[0..actual_count], vals[0..actual_count]);

    // Check inclusion proof for selected target key.
    const target_idx = if (input.len > 1) input[input.len - 1] % actual_count else 0;
    var proof = try mpt_proof.secureProof(allocator, keys[0..actual_count], vals[0..actual_count], keys[target_idx]);
    defer proof.deinit(allocator);

    // CRITICAL DIFFERENTIAL LAW: mpt_proof root MUST match Voltaire's secure_trie_root!
    try std.testing.expectEqual(expected_root, proof.root);
    try std.testing.expect(proof.nodes.len >= 1);

    // Proof MUST verify against Voltaire's independent EIP-1186 proof verifier!
    try std.testing.expect(try primitives.Proof.verifyStorageSlotProof(
        allocator,
        &proof.root,
        keys[target_idx],
        vals[target_idx],
        proof.nodes,
    ));

    // Tampered root MUST fail verification!
    var bad_root = proof.root;
    bad_root[0] ^= 0x01;
    try std.testing.expect(!(primitives.Proof.verifyStorageSlotProof(
        allocator,
        &bad_root,
        keys[target_idx],
        vals[target_idx],
        proof.nodes,
    ) catch false));

    // Tampered value MUST fail verification!
    var bad_val = try allocator.dupe(u8, vals[target_idx]);
    defer allocator.free(bad_val);
    bad_val[bad_val.len - 1] ^= 0xff;
    try std.testing.expect(!(primitives.Proof.verifyStorageSlotProof(
        allocator,
        &proof.root,
        keys[target_idx],
        bad_val,
        proof.nodes,
    ) catch false));

    // Non-inclusion proof for an absent key MUST produce the same root and reject any non-empty value!
    const absent_key = [_]u8{0xff} ** 32;
    var absent_proof = try mpt_proof.secureProof(allocator, keys[0..actual_count], vals[0..actual_count], &absent_key);
    defer absent_proof.deinit(allocator);
    try std.testing.expectEqual(expected_root, absent_proof.root);
    try std.testing.expect(!(primitives.Proof.verifyStorageSlotProof(
        allocator,
        &absent_proof.root,
        &absent_key,
        vals[target_idx],
        absent_proof.nodes,
    ) catch false));
}

test "fuzz: mpt_proof.secureProof root and EIP-1186 verification agree with TrieHash across arbitrary tries" {
    try fuzzMptSecureProof({}, "");
    try std.testing.fuzz({}, fuzzMptSecureProof, .{ .corpus = &.{
        "\x00\x14\x01\x42",
        "\x01\x14\x01\xaa\x14\x01\xbb",
        "\x05\x01\x01\x02\x01\x01\x03\x01\x01\x04\x01\x01\x05\x01\x01\x06\x01\x01\x07",
        "\x0f" ++ "\x1f\x20" ** 16,
    } });
}

test "property: mpt_proof order independence and full multi-key verification" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x1186_9700_cafe_babe);
    const random = prng.random();

    for (0..128) |_| {
        const count = random.intRangeAtMost(usize, 1, 12);
        var keys_buf: [12][32]u8 = undefined;
        var vals_buf: [12][33]u8 = undefined;
        var keys: [12][]const u8 = undefined;
        var vals: [12][]const u8 = undefined;

        for (0..count) |i| {
            random.bytes(&keys_buf[i]);
            keys_buf[i][0] = @intCast(i);
            keys[i] = &keys_buf[i];

            const vlen = random.intRangeAtMost(usize, 1, 32);
            vals_buf[i][0] = if (vlen == 1) @as(u8, @intCast(random.intRangeAtMost(u8, 1, 0x7f))) else 0x80 + @as(u8, @intCast(vlen));
            if (vlen > 1) {
                random.bytes(vals_buf[i][1 .. 1 + vlen]);
                vals_buf[i][1] |= 1;
                vals[i] = vals_buf[i][0 .. 1 + vlen];
            } else {
                vals[i] = vals_buf[i][0..1];
            }
        }

        const expected_root = try primitives.TrieHash.secure_trie_root(allocator, keys[0..count], vals[0..count]);

        // Shuffle order and verify root & every key's proof.
        var shuffled_keys: [12][]const u8 = undefined;
        var shuffled_vals: [12][]const u8 = undefined;
        var perm: [12]usize = undefined;
        for (0..count) |i| perm[i] = i;
        random.shuffle(usize, perm[0..count]);
        for (0..count) |i| {
            shuffled_keys[i] = keys[perm[i]];
            shuffled_vals[i] = vals[perm[i]];
        }

        for (0..count) |i| {
            var proof = try mpt_proof.secureProof(allocator, shuffled_keys[0..count], shuffled_vals[0..count], keys[i]);
            defer proof.deinit(allocator);
            try std.testing.expectEqual(expected_root, proof.root);
            try std.testing.expect(try primitives.Proof.verifyStorageSlotProof(allocator, &proof.root, keys[i], vals[i], proof.nodes));
        }
    }
}

var shared_kzg_verifier: blob_kzg.Verifier = .{};

fn fuzzBlobKzgVerifier(_: void, input: []const u8) anyerror!void {
    const allocator = std.testing.allocator;
    const sidecar = try allocator.create(transaction_encoding.BlobSidecar);
    defer allocator.destroy(sidecar);

    @memset(&sidecar.blob, 0);
    const infinity = [_]u8{0xc0} ++ [_]u8{0} ** 47;
    sidecar.commitment = infinity;

    const mode: u8 = if (input.len > 0) input[0] & 3 else 0;
    const payload = if (input.len > 1) input[1..] else &[_]u8{};

    switch (mode) {
        0 => {
            // Mutate v0 blob proof bytes around the valid zero-polynomial proof.
            sidecar.proofs = .{ .blob = infinity };
            if (payload.len >= 3) {
                const target = payload[0] % 3;
                const delta = if (payload[1] == 0) @as(u8, 1) else payload[1];
                if (target == 0) {
                    const pos = @as(usize, payload[2]) % sidecar.blob.len;
                    sidecar.blob[pos] ^= delta;
                } else if (target == 1) {
                    sidecar.commitment[payload[2] % 48] ^= delta;
                } else {
                    sidecar.proofs.blob[payload[2] % 48] ^= delta;
                }
                // Any single-byte mutation away from zero-poly infinity MUST fail cleanly, never crash!
                try std.testing.expectError(error.InvalidBlobProof, shared_kzg_verifier.verify(allocator, sidecar[0..1]));
            } else {
                try shared_kzg_verifier.verify(allocator, sidecar[0..1]);
            }
        },
        1 => {
            // Arbitrary commitment & v0 proof bytes with sparse blob mutations.
            sidecar.proofs = .{ .blob = [_]u8{0} ** 48 };
            const c_len: usize = @min(@as(usize, 48), payload.len);
            @memcpy(sidecar.commitment[0..c_len], payload[0..c_len]);
            if (payload.len > 48) {
                const p_len: usize = @min(@as(usize, 48), payload.len - 48);
                @memcpy(sidecar.proofs.blob[0..p_len], payload[48 .. 48 + p_len]);
            }
            if (payload.len > 96) {
                const b_len: usize = @min(@as(usize, 256), payload.len - 96);
                @memcpy(sidecar.blob[0..b_len], payload[96 .. 96 + b_len]);
            }
            shared_kzg_verifier.verify(allocator, sidecar[0..1]) catch |err| {
                if (err == error.OutOfMemory) return err;
            };
        },
        else => {
            // PeerDAS v1 cell proofs: valid zero-poly or mutated cell proof / blob byte.
            sidecar.proofs = .{ .cells = [_][48]u8{infinity} ** transaction_encoding.CELLS_PER_EXT_BLOB };
            if (payload.len >= 3) {
                const target = payload[0] % 3;
                const delta = if (payload[1] == 0) @as(u8, 1) else payload[1];
                if (target == 0) {
                    sidecar.blob[@as(usize, payload[2]) % sidecar.blob.len] ^= delta;
                } else if (target == 1) {
                    sidecar.commitment[payload[2] % 48] ^= delta;
                } else {
                    const cell_idx = payload[2] % transaction_encoding.CELLS_PER_EXT_BLOB;
                    sidecar.proofs.cells[cell_idx][payload[1] % 48] ^= delta;
                }
                try std.testing.expectError(error.InvalidBlobProof, shared_kzg_verifier.verify(allocator, sidecar[0..1]));
            } else {
                try shared_kzg_verifier.verify(allocator, sidecar[0..1]);
            }
        },
    }
}

test "fuzz: blob_kzg.Verifier v0 blob and v1 PeerDAS cell proof verification on arbitrary mutations" {
    defer shared_kzg_verifier.deinit();
    try std.testing.fuzz({}, fuzzBlobKzgVerifier, .{ .corpus = &.{
        "\x00",
        "\x00\x00\x01\x1f",
        "\x00\x01\x01\x00",
        "\x00\x02\x01\x00",
        "\x01" ++ "\xff" ** 100,
        "\x02",
        "\x02\x00\x01\x1f",
        "\x02\x02\x01\x05",
    } });
}

fn fuzzExecutionFixtureRpc(_: void, input: []const u8) anyerror!void {
    const allocator = std.testing.allocator;
    if (input.len > 32 * 1024) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("eth_call");
    try tmp.dir.writeFile(.{ .sub_path = "eth_call/case.io", .data = input });

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);

    const maybe_cache = execution_fixture_rpc.Cache.loadFromTestsDir(allocator, dir_path) catch |err| {
        if (err == error.OutOfMemory) return err;
        return;
    };
    if (maybe_cache) |cache_val| {
        var cache = cache_val;
        defer cache.deinit(allocator);

        const req = jsonrpc.envelope.RequestEnvelope{
            .jsonrpc = "2.0",
            .method = "eth_call",
            .params = null,
            .id = .{ .integer = 1 },
        };
        if (cache.matchResponse(allocator, req) catch |err| {
            if (err == error.OutOfMemory) return err;
            return;
        }) |resp_val| {
            var resp = resp_val;
            resp.deinit(allocator);
        }
    }
}

test "fuzz: execution_fixture_rpc.Cache .io fixture parsing and matching on arbitrary bytes" {
    try fuzzExecutionFixtureRpc({}, "");
    try std.testing.fuzz({}, fuzzExecutionFixtureRpc, .{ .corpus = &.{
        ">> {\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_call\"}\n<< {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"0x\"}\n",
        ">> {\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_call\",\"params\":[]}\n<< {\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32000,\"message\":\"reverted\"}}\n",
        ">> {\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_call\"}\n",
        "<< {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"0x\"}\n",
        ">> not json\n<< also not json\n",
    } });
}
