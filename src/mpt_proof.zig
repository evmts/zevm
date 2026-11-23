const std = @import("std");
const primitives = @import("primitives");

const Hash32 = [32]u8;
const EMPTY_BYTES: []const u8 = &.{};

pub const Proof = struct {
    root: Hash32,
    nodes: [][]u8,

    pub fn deinit(self: *Proof, allocator: std.mem.Allocator) void {
        for (self.nodes) |node| allocator.free(node);
        allocator.free(self.nodes);
        self.* = .{ .root = [_]u8{0} ** 32, .nodes = &.{} };
    }
};

const Entry = struct {
    key: []const u8,
    value: []const u8,
};

const NodeKind = union(enum) {
    empty,
    leaf: PathValue,
    extension: Extension,
    branch: Branch,
};

const Node = struct {
    kind: NodeKind,
    encoded: ?[]const u8 = null,
    ref: ?Data = null,
};

const PathValue = struct {
    path: []const u8,
    value: []const u8,
};

const Extension = struct {
    path: []const u8,
    child: *Node,
};

const Branch = struct {
    children: [16]?*Node,
    value: []const u8,
};

const Data = union(enum) {
    string: []const u8,
    list: []Data,
};

pub fn secureProof(
    allocator: std.mem.Allocator,
    keys: []const []const u8,
    values: []const []const u8,
    target_key: []const u8,
) !Proof {
    if (keys.len != values.len) return error.InvalidKey;
    if (keys.len == 0) {
        return .{
            .root = primitives.State.EMPTY_TRIE_ROOT,
            .nodes = try allocator.alloc([]u8, 0),
        };
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const hashed_entries = try arena_alloc.alloc(Entry, keys.len);
    for (keys, 0..) |key, index| {
        const hashed_value = hashBytes(key);
        const hashed = try arena_alloc.dupe(u8, &hashed_value);
        hashed_entries[index] = .{
            .key = try keyToNibbles(arena_alloc, hashed),
            .value = values[index],
        };
    }

    const root = try buildNode(arena_alloc, hashed_entries, 0);
    const root_hash = try computeRootHash(arena_alloc, root);

    var target_hash: Hash32 = undefined;
    keccak256(target_key, &target_hash);
    const target_nibbles = try keyToNibbles(arena_alloc, &target_hash);

    var proof_nodes = std.ArrayList([]u8){};
    errdefer {
        for (proof_nodes.items) |node| allocator.free(node);
        proof_nodes.deinit(allocator);
    }

    try collectProofNodes(allocator, arena_alloc, root, target_nibbles, 0, &proof_nodes, true);

    return .{
        .root = root_hash,
        .nodes = try proof_nodes.toOwnedSlice(allocator),
    };
}

fn buildNode(allocator: std.mem.Allocator, entries: []const Entry, level: usize) anyerror!*Node {
    const node = try allocator.create(Node);
    errdefer allocator.destroy(node);

    if (entries.len == 0) {
        node.* = .{ .kind = .empty };
        return node;
    }

    if (entries.len == 1) {
        node.* = .{ .kind = .{ .leaf = .{
            .path = entries[0].key[level..],
            .value = entries[0].value,
        } } };
        return node;
    }

    const prefix_length = commonPrefixLength(entries, level);
    if (prefix_length > 0) {
        node.* = .{ .kind = .{ .extension = .{
            .path = entries[0].key[level .. level + prefix_length],
            .child = try buildNode(allocator, entries, level + prefix_length),
        } } };
        return node;
    }

    var branch = Branch{
        .children = [_]?*Node{null} ** 16,
        .value = EMPTY_BYTES,
    };

    // Single counting pass across all 16 nibble buckets instead of 16 separate scans.
    var counts = [_]usize{0} ** 16;
    var total_children: usize = 0;
    var terminated = false;
    for (entries) |entry| {
        if (entry.key.len == level) {
            // Two entries ending at the same node share one key. Building on
            // would silently drop a value and yield a root no peer reproduces.
            if (terminated) return error.DuplicateKey;
            terminated = true;
            branch.value = entry.value;
        } else {
            counts[entry.key[level]] += 1;
            total_children += 1;
        }
    }

    if (total_children > 0) {
        // One contiguous partition buffer for all non-empty buckets at this branch.
        const partitioned = try allocator.alloc(Entry, total_children);
        var starts: [16]usize = undefined;
        var cursors: [16]usize = undefined;
        var offset: usize = 0;
        for (0..16) |bucket| {
            starts[bucket] = offset;
            cursors[bucket] = offset;
            offset += counts[bucket];
        }

        for (entries) |entry| {
            if (entry.key.len > level) {
                const b = entry.key[level];
                partitioned[cursors[b]] = entry;
                cursors[b] += 1;
            }
        }

        for (0..16) |bucket| {
            if (counts[bucket] == 0) continue;
            const slice = partitioned[starts[bucket] .. starts[bucket] + counts[bucket]];
            branch.children[bucket] = try buildNode(allocator, slice, level + 1);
        }
    }

    node.* = .{ .kind = .{ .branch = branch } };
    return node;
}

fn commonPrefixLength(entries: []const Entry, level: usize) usize {
    const first = entries[0].key[level..];
    var prefix_length = first.len;

    for (entries[1..]) |entry| {
        const suffix = entry.key[level..];
        const max = @min(prefix_length, suffix.len);
        var index: usize = 0;
        while (index < max and first[index] == suffix[index]) : (index += 1) {}
        prefix_length = index;
        if (prefix_length == 0) break;
    }

    return prefix_length;
}

fn computeRootHash(allocator: std.mem.Allocator, root: *Node) anyerror!Hash32 {
    const root_ref = try nodeReferenceData(allocator, root);
    const encoded = root.encoded orelse try encodeData(allocator, root_ref);

    if (encoded.len < 32) return hashBytes(encoded);

    return switch (root_ref) {
        .string => |bytes| blk: {
            if (bytes.len != 32) return error.InvalidNode;
            var out: Hash32 = undefined;
            @memcpy(out[0..], bytes[0..32]);
            break :blk out;
        },
        .list => error.InvalidNode,
    };
}

fn collectProofNodes(
    proof_allocator: std.mem.Allocator,
    arena_allocator: std.mem.Allocator,
    node: *Node,
    target_nibbles: []const u8,
    level: usize,
    proof_nodes: *std.ArrayList([]u8),
    is_root: bool,
) anyerror!void {
    // Reuse the RLP bytes cached during computeRootHash instead of re-encoding
    // and re-hashing every subtree along the proof path.
    const cached = node.encoded orelse blk: {
        _ = try nodeReferenceData(arena_allocator, node);
        break :blk node.encoded.?;
    };

    // Per EIP-1186, only hash-referenced nodes appear as standalone proof
    // entries. A child whose RLP encoding is < 32 bytes is embedded inline in
    // its parent (see nodeReferenceData) and must NOT be emitted separately.
    // The root node is always emitted even when < 32 bytes.
    if (is_root or cached.len >= 32) {
        // Reserve the slot first: once the copy exists, storing it cannot fail,
        // so an out-of-memory append can never strand the copy.
        try proof_nodes.ensureUnusedCapacity(proof_allocator, 1);
        const duped = try proof_allocator.dupe(u8, cached);
        proof_nodes.appendAssumeCapacity(duped);
    }

    switch (node.kind) {
        .empty => {},
        .leaf => {},
        .extension => |extension| {
            if (!startsWith(target_nibbles[level..], extension.path)) return;
            try collectProofNodes(
                proof_allocator,
                arena_allocator,
                extension.child,
                target_nibbles,
                level + extension.path.len,
                proof_nodes,
                false,
            );
        },
        .branch => |branch| {
            if (target_nibbles.len == level) return;
            const child = branch.children[target_nibbles[level]] orelse return;
            try collectProofNodes(
                proof_allocator,
                arena_allocator,
                child,
                target_nibbles,
                level + 1,
                proof_nodes,
                false,
            );
        },
    }
}

fn nodeReferenceData(allocator: std.mem.Allocator, node: *Node) anyerror!Data {
    if (node.ref) |cached_ref| return cached_ref;

    switch (node.kind) {
        .empty => {
            const empty_encoded = try encodeData(allocator, .{ .string = EMPTY_BYTES });
            node.encoded = empty_encoded;
            node.ref = .{ .string = EMPTY_BYTES };
            return node.ref.?;
        },
        else => {},
    }

    const full = try fullNodeData(allocator, node);
    const encoded = try encodeData(allocator, full);
    node.encoded = encoded;

    if (encoded.len < 32) {
        node.ref = full;
        return full;
    }

    const hashed = hashBytes(encoded);
    const ref_data = Data{ .string = try allocator.dupe(u8, &hashed) };
    node.ref = ref_data;
    return ref_data;
}

fn fullNodeData(allocator: std.mem.Allocator, node: *Node) anyerror!Data {
    return switch (node.kind) {
        .empty => .{ .string = EMPTY_BYTES },
        .leaf => |leaf| blk: {
            const items = try allocator.alloc(Data, 2);
            items[0] = .{ .string = try encodeHexPath(allocator, leaf.path, true) };
            items[1] = .{ .string = leaf.value };
            break :blk .{ .list = items };
        },
        .extension => |extension| blk: {
            const items = try allocator.alloc(Data, 2);
            items[0] = .{ .string = try encodeHexPath(allocator, extension.path, false) };
            items[1] = try nodeReferenceData(allocator, extension.child);
            break :blk .{ .list = items };
        },
        .branch => |branch| blk: {
            const items = try allocator.alloc(Data, 17);
            for (0..16) |index| {
                items[index] = if (branch.children[index]) |child|
                    try nodeReferenceData(allocator, child)
                else
                    .{ .string = EMPTY_BYTES };
            }
            items[16] = .{ .string = branch.value };
            break :blk .{ .list = items };
        },
    };
}

fn keyToNibbles(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    const nibbles = try allocator.alloc(u8, key.len * 2);
    for (key, 0..) |byte, index| {
        nibbles[index * 2] = byte >> 4;
        nibbles[index * 2 + 1] = byte & 0x0f;
    }
    return nibbles;
}

fn encodeHexPath(allocator: std.mem.Allocator, nibbles: []const u8, is_leaf: bool) ![]u8 {
    if (nibbles.len == 0) {
        const result = try allocator.alloc(u8, 1);
        result[0] = if (is_leaf) 0x20 else 0x00;
        return result;
    }

    const is_odd = nibbles.len % 2 == 1;
    const encoded_len = if (is_odd) (nibbles.len + 1) / 2 else (nibbles.len / 2) + 1;
    const encoded = try allocator.alloc(u8, encoded_len);

    if (is_odd) {
        encoded[0] = (if (is_leaf) @as(u8, 0x30) else @as(u8, 0x10)) | nibbles[0];
        for (1..encoded_len) |index| {
            encoded[index] = (nibbles[index * 2 - 1] << 4) | nibbles[index * 2];
        }
    } else {
        encoded[0] = if (is_leaf) 0x20 else 0x00;
        for (1..encoded_len) |index| {
            encoded[index] = (nibbles[(index - 1) * 2] << 4) | nibbles[(index - 1) * 2 + 1];
        }
    }

    return encoded;
}

fn startsWith(value: []const u8, prefix: []const u8) bool {
    if (value.len < prefix.len) return false;
    return std.mem.eql(u8, value[0..prefix.len], prefix);
}

fn keccak256(input: []const u8, out: *[32]u8) void {
    std.crypto.hash.sha3.Keccak256.hash(input, out, .{});
}

fn hashBytes(input: []const u8) Hash32 {
    var out: Hash32 = undefined;
    keccak256(input, &out);
    return out;
}

fn checkedAdd(left: usize, right: usize) !usize {
    return std.math.add(usize, left, right) catch error.OutOfMemory;
}

fn encodedLen(data: Data) anyerror!usize {
    return switch (data) {
        .string => |bytes| encodedLenBytes(bytes),
        .list => |items| encodedLenList(items),
    };
}

fn encodedLenBytes(bytes: []const u8) !usize {
    if (bytes.len == 1 and bytes[0] < 0x80) return 1;

    var header_len: usize = 1;
    if (bytes.len >= 56) header_len = try checkedAdd(header_len, lengthOfLength(bytes.len));
    return checkedAdd(header_len, bytes.len);
}

fn encodedLenList(items: []const Data) anyerror!usize {
    var payload_len: usize = 0;
    for (items) |item| {
        payload_len = try checkedAdd(payload_len, try encodedLen(item));
    }

    var header_len: usize = 1;
    if (payload_len >= 56) header_len = try checkedAdd(header_len, lengthOfLength(payload_len));
    return checkedAdd(header_len, payload_len);
}

fn encodeData(allocator: std.mem.Allocator, data: Data) anyerror![]u8 {
    const total_len = try encodedLen(data);
    const out = try allocator.alloc(u8, total_len);
    errdefer allocator.free(out);

    const written = try encodeInto(data, out);
    std.debug.assert(written == total_len);
    return out;
}

fn encodeInto(data: Data, out: []u8) anyerror!usize {
    return switch (data) {
        .string => |bytes| encodeBytesInto(bytes, out),
        .list => |items| encodeListInto(items, out),
    };
}

fn encodeBytesInto(bytes: []const u8, out: []u8) usize {
    if (bytes.len == 1 and bytes[0] < 0x80) {
        out[0] = bytes[0];
        return 1;
    }

    if (bytes.len < 56) {
        out[0] = 0x80 + @as(u8, @intCast(bytes.len));
        @memcpy(out[1 .. 1 + bytes.len], bytes);
        return 1 + bytes.len;
    }

    const len_len = lengthOfLength(bytes.len);
    out[0] = 0xb7 + @as(u8, @intCast(len_len));
    writeLength(bytes.len, out[1 .. 1 + len_len]);
    @memcpy(out[1 + len_len .. 1 + len_len + bytes.len], bytes);
    return 1 + len_len + bytes.len;
}

fn encodeListInto(items: []const Data, out: []u8) anyerror!usize {
    var payload_len: usize = 0;
    for (items) |item| {
        payload_len = try checkedAdd(payload_len, try encodedLen(item));
    }

    var offset: usize = 0;
    if (payload_len < 56) {
        out[0] = 0xc0 + @as(u8, @intCast(payload_len));
        offset = 1;
    } else {
        const len_len = lengthOfLength(payload_len);
        out[0] = 0xf7 + @as(u8, @intCast(len_len));
        writeLength(payload_len, out[1 .. 1 + len_len]);
        offset = 1 + len_len;
    }

    for (items) |item| {
        const written = try encodeInto(item, out[offset..]);
        offset += written;
    }

    return offset;
}

fn lengthOfLength(value: usize) usize {
    var tmp = value;
    var len: usize = 0;
    while (tmp > 0) : (tmp >>= 8) len += 1;
    return len;
}

fn writeLength(value: usize, out: []u8) void {
    var tmp = value;
    var index = out.len;
    while (index > 0) {
        index -= 1;
        out[index] = @as(u8, @intCast(tmp & 0xff));
        tmp >>= 8;
    }
}

test "secureProof root matches TrieHash root" {
    const allocator = std.testing.allocator;
    const keys = [_][]const u8{
        "account-a",
        "account-b",
        "account-c",
    };
    const values = [_][]const u8{
        "\x01",
        "\x02",
        "\x03",
    };

    var proof = try secureProof(allocator, &keys, &values, keys[1]);
    defer proof.deinit(allocator);

    const expected = try primitives.TrieHash.secure_trie_root(allocator, &keys, &values);
    try std.testing.expectEqualSlices(u8, &expected, &proof.root);
    try std.testing.expect(proof.nodes.len > 0);
}

test "secureProof does not emit inline (sub-32-byte) children as standalone entries" {
    const allocator = std.testing.allocator;
    // 3 single-byte values keyed by keccak hashes produce a branch whose
    // single-entry leaf children encode to well under 32 bytes. Those children
    // are inlined in the branch RLP and must NOT also appear as standalone
    // proof entries (EIP-1186: only hash-referenced nodes are emitted).
    const keys = [_][]const u8{
        "account-a",
        "account-b",
        "account-c",
    };
    const values = [_][]const u8{
        "\x01",
        "\x02",
        "\x03",
    };

    var proof = try secureProof(allocator, &keys, &values, keys[1]);
    defer proof.deinit(allocator);

    // The root is always emitted (even if < 32 bytes). Every subsequent entry
    // must be hash-referenced, i.e. its RLP encoding is at least 32 bytes.
    try std.testing.expect(proof.nodes.len > 0);
    for (proof.nodes[1..]) |node| {
        try std.testing.expect(node.len >= 32);
    }
}

test "secureProof rejects duplicate keys" {
    const allocator = std.testing.allocator;
    const key = [_]u8{0x11} ** 20;
    const other = [_]u8{0x22} ** 20;
    const keys = [_][]const u8{ &key, &other, &key };
    const values = [_][]const u8{ &[_]u8{0x01}, &[_]u8{0x02}, &[_]u8{0x03} };

    try std.testing.expectError(error.DuplicateKey, secureProof(allocator, &keys, &values, &key));
}

test "secureProof frees every node when an allocation fails" {
    const Harness = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var key_storage: [8][20]u8 = undefined;
            var keys: [8][]const u8 = undefined;
            var values: [8][]const u8 = undefined;
            const value = [_]u8{0xab} ** 40;
            for (&key_storage, 0..) |*key, i| {
                @memset(key, @intCast(i + 1));
                keys[i] = key;
                values[i] = &value;
            }
            var proof = try secureProof(allocator, &keys, &values, keys[3]);
            proof.deinit(allocator);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{});
}
