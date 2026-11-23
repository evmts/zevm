const std = @import("std");
const primitives = @import("primitives");
const pool_mod = @import("../txpool.zig");
const encoding = @import("../transaction_encoding.zig");
const receipts = @import("../receipt_index.zig");
const logs = @import("../log_index.zig");
const processor = @import("../tx_processor.zig");

fn hash(id: usize) [32]u8 {
    var result = [_]u8{0} ** 32;
    std.mem.writeInt(u64, result[0..8], id, .little);
    return result;
}

fn address(id: u8) primitives.Address {
    return .{ .bytes = @splat(id) };
}

const Entry = struct {
    id: usize,
    kind: u8,
    cap: u64,
    tip: u64,
    blob_fee: u64,
};

const PoolModel = struct {
    slots: [2][6]?Entry = @splat(@splat(null)),
    base: [2]usize = .{ 0, 0 },

    fn check(self: *const PoolModel, pool: *pool_mod.TransactionPool) !void {
        var total: usize = 0;
        var pending: usize = 0;
        for (self.slots, 0..) |row, sender| {
            var end = self.base[sender];
            while (end < row.len and row[end] != null) end += 1;
            try std.testing.expectEqual(end, pool.pendingNonce(address(@intCast(sender)), self.base[sender]));
            pending += end - self.base[sender];
            for (row, 0..) |slot, nonce| {
                const e = slot orelse continue;
                total += 1;
                const tx = for (pool.items()) |tx| {
                    if (std.meta.eql(tx.hash, hash(e.id))) break tx;
                } else return error.MissingHash;
                try std.testing.expectEqual(nonce, tx.nonce);
                try std.testing.expectEqualDeep(address(@intCast(sender)), tx.sender);
                try std.testing.expectEqual(e.cap, tx.max_fee_per_gas);
                try std.testing.expectEqual(e.tip, tx.max_priority_fee_per_gas);
                try std.testing.expectEqual(@as(?u256, if (e.kind >= 2) e.blob_fee else null), tx.max_fee_per_blob_gas);
                try std.testing.expectEqualSlices(u8, &hash(e.id), tx.input);
                try std.testing.expectEqualSlices(u8, tx.input, tx.raw);
                try std.testing.expectEqual(e.kind >= 2, tx.blob_sidecars.len == 1);
                if (e.kind >= 2) {
                    try std.testing.expectEqualDeep(hash(e.id), tx.blob_versioned_hashes[0]);
                    const side = &tx.blob_sidecars[0];
                    try std.testing.expectEqual(@as(u8, @truncate(e.id)), side.blob[0]);
                    try std.testing.expectEqual(e.kind == 3, side.proofs == .cells);
                }
                try std.testing.expectEqual(nonce >= self.base[sender] and nonce < end, pool.statusOf(tx.sender, nonce) == .pending);
            }
        }
        try std.testing.expectEqual(total, pool.items().len);
        try std.testing.expectEqual(pending, pool.pendingCount());
        try std.testing.expectEqual(total - pending, pool.queuedCount());
        const ready = try pool.getReady(std.testing.allocator);
        defer std.testing.allocator.free(ready);
        try std.testing.expectEqual(pending, ready.len);
        var next = self.base;
        for (ready) |tx| {
            const s = tx.sender.bytes[0];
            try std.testing.expect(s < next.len);
            try std.testing.expectEqual(next[s], tx.nonce);
            const e = self.slots[s][next[s]] orelse return error.UnexpectedReady;
            try std.testing.expectEqualDeep(hash(e.id), tx.hash);
            next[s] += 1;
        }
    }
};

fn poolStream(_: void, input: []const u8) !void {
    const a = std.testing.allocator;
    var pool = pool_mod.TransactionPool.init(a);
    defer pool.deinit();
    var model = PoolModel{};
    var sides = [1]encoding.BlobSidecar{.{ .blob = @splat(0), .commitment = @splat(0), .proofs = .{ .blob = @splat(0) } }};
    for (input[0..@min(input.len, 512)], 0..) |byte, i| {
        const sender = (byte >> 4) & 1;
        const nonce = (byte >> 5) % 6;
        const slot = &model.slots[sender][nonce];
        const op = byte & 15;
        if (op == 15 and sender == 1 and nonce == 0) {
            pool.clear();
            model = .{};
        } else if (op == 14) {
            model.base[sender] = @max(model.base[sender], nonce);
            try pool.setNonce(address(sender), model.base[sender]);
        } else if (op >= 12) {
            const h = hash(if (slot.*) |e| e.id else 0);
            if (op == 12) {
                pool.removeMined(&.{h});
                if (slot.* != null) model.base[sender] = @max(model.base[sender], @as(usize, nonce) + 1);
            } else try std.testing.expectEqual(slot.* != null, pool.removeByHash(h));
            slot.* = null;
        } else {
            const old = slot.* orelse Entry{ .id = 0, .kind = 0, .cap = 10, .tip = 1, .blob_fee = 1 };
            var e = Entry{ .id = i + 1, .kind = op % 4, .cap = old.cap + @intFromBool(op != 4), .tip = old.tip + @intFromBool(op != 5), .blob_fee = old.blob_fee + @intFromBool(op != 6) };
            const duplicate = slot.* != null and op >= 8;
            if (duplicate) {
                e = old;
                if (old.kind >= 2 and op == 11) e.kind = 5 - old.kind;
            }
            const h = hash(e.id);
            sides[0].blob[0] = @truncate(e.id);
            sides[0].proofs = if (e.kind == 3) .{ .cells = std.mem.zeroes([encoding.CELLS_PER_EXT_BLOB][encoding.BYTES_PER_PROOF]u8) } else .{ .blob = @splat(0) };
            const result = pool.add(a, .{
                .sender = address(sender),
                .nonce = nonce,
                .hash = h,
                .gas_limit = 21000,
                .receipt_type = switch (e.kind) {
                    0 => .legacy,
                    1 => .eip1559,
                    else => .eip4844,
                },
                .max_fee_per_gas = e.cap,
                .max_priority_fee_per_gas = e.tip,
                .max_fee_per_blob_gas = if (e.kind >= 2) e.blob_fee else null,
                .input = &h,
                .raw = &h,
                .blob_versioned_hashes = if (e.kind >= 2) &.{h} else &.{},
                .blob_sidecars = if (e.kind >= 2 and !(duplicate and op == 10)) &sides else &.{},
            });
            if (slot.* != null and !duplicate and (e.cap <= old.cap or e.tip <= old.tip or (old.kind >= 2 and (e.kind < 2 or e.blob_fee <= old.blob_fee)))) {
                try std.testing.expectError(error.ReplacementUnderpriced, result);
            } else {
                try result;
                slot.* = e;
            }
        }
        try model.check(&pool);
    }
}

fn receipt(height: usize, block: usize, id: usize, position: u32, events: []const primitives.EventLog.EventLog) primitives.Receipt.Receipt {
    return .{ .transaction_hash = hash(id), .transaction_index = position, .block_hash = hash(block), .block_number = height, .sender = address(@truncate(id)), .to = null, .cumulative_gas_used = 21000 * (@as(u64, position) + 1), .gas_used = 21000, .contract_address = null, .logs = events, .logs_bloom = processor.computeLogsBloom(events), .status = .{ .success = true, .gas_used = 21000 }, .root = null, .effective_gas_price = 100, .type = .legacy, .blob_gas_used = null, .blob_gas_price = null };
}

const ReceiptFixture = struct {
    topic: [1][32]u8 = undefined,
    data: [2]u8 = undefined,
    events: [1]primitives.EventLog.EventLog = undefined,

    fn make(self: *ReceiptFixture, height: usize, block: usize, j: usize) primitives.Receipt.Receipt {
        const id = block * 3 + j;
        self.topic = .{hash(id)};
        self.data = .{ @truncate(block), @intCast(j) };
        self.events[0] = .{ .address = address(@truncate(id)), .topics = &self.topic, .data = &self.data, .block_number = height, .transaction_hash = hash(id), .transaction_index = @intCast(j), .log_index = @intCast(j), .removed = false };
        return receipt(height, block, id, @intCast(j), &self.events);
    }
};

const Block = struct { id: usize, count: usize };

test "property: receipt indexes follow canonical checkpoints through forks" {
    const a = std.testing.allocator;
    for (seeds) |seed| {
        var rng = std.Random.DefaultPrng.init(seed);
        var index = receipts.ReceiptIndex.init(a);
        defer index.deinit(a);
        var chain: [8]Block = undefined;
        var height: usize = 0;
        var snapshots: [8]receipts.ReceiptIndex = undefined;
        defer for (snapshots[0..height]) |*snapshot| snapshot.deinit(a);
        for (1..322) |id| {
            if (height == chain.len or (height > 0 and rng.random().boolean())) {
                height -= 1;
                index.deinit(a);
                index = snapshots[height];
                const orphan = chain[height];
                try std.testing.expect(index.getByBlockHash(hash(orphan.id)) == null);
                for (0..orphan.count) |j| try std.testing.expect(index.getByTxHash(hash(orphan.id * 3 + j)) == null);
            } else {
                const count = rng.random().uintLessThan(usize, 4);
                var batch: [3]primitives.Receipt.Receipt = undefined;
                var fixtures: [3]ReceiptFixture = undefined;
                for (batch[0..count], 0..) |*r, j| r.* = fixtures[j].make(height, id, j);
                var checkpoint = try index.clone(a);
                errdefer checkpoint.deinit(a);
                try index.putBlockReceipts(a, hash(id), batch[0..count]);
                snapshots[height] = checkpoint;
                chain[height] = .{ .id = id, .count = count };
                height += 1;
            }
            var count: usize = 0;
            for (chain[0..height], 0..) |b, n| {
                const stored = index.getByBlockHash(hash(b.id)) orelse return error.MissingBlock;
                try std.testing.expectEqual(b.count, stored.len);
                count += b.count;
                for (stored, 0..) |actual, j| {
                    var fixture: ReceiptFixture = undefined;
                    const expected = fixture.make(n, b.id, j);
                    try std.testing.expectEqualDeep(expected, actual);
                    try std.testing.expectEqualDeep(expected, index.getByTxHash(expected.transaction_hash) orelse return error.MissingTx);
                }
            }
            try std.testing.expectEqual(count, index.by_tx.count());
            try std.testing.expectEqual(height, index.by_block.count());
        }
    }
}

test "property: replacing a block retires displaced receipts and owned slice" {
    const a = std.testing.allocator;
    var index = receipts.ReceiptIndex.init(a);
    defer index.deinit(a);
    const first = receipt(1, 1, 10, 0, &.{});
    const second = receipt(1, 1, 11, 1, &.{});
    try index.putBlockReceipts(a, hash(1), &.{ first, second });
    try index.putBlockReceipts(a, hash(1), &.{first});
    try std.testing.expectEqualDeep(first, index.getByTxHash(first.transaction_hash) orelse return error.MissingTx);
    try std.testing.expectEqual(@as(usize, 1), index.getByBlockHash(hash(1)).?.len);
    try std.testing.expect(index.getByTxHash(second.transaction_hash) == null);
}

const LogRecord = struct {
    height: usize,
    position: u32,
    addr: u8,
    topic_count: usize,
    topics: [4][32]u8,
    data: [2]u8,

    fn event(self: *const LogRecord) primitives.EventLog.EventLog {
        return .{ .block_number = self.height, .transaction_hash = hash(self.height), .transaction_index = 0, .log_index = self.position, .removed = false, .address = address(self.addr), .topics = self.topics[0..self.topic_count], .data = &self.data };
    }

    fn matches(self: *const LogRecord, filter: logs.LogFilter) bool {
        if (filter.block_hash) |h| if (!std.meta.eql(h, hash(self.height))) return false;
        if (self.height < (filter.from_block orelse 0) or self.height > (filter.to_block orelse std.math.maxInt(u64))) return false;
        if (filter.addresses) |list| {
            for (list) |wanted| {
                if (std.meta.eql(address(self.addr), wanted)) break;
            } else return false;
        }
        if (filter.topics) |matrix| {
            if (matrix.len > self.topic_count) return false;
            for (matrix, 0..) |choices, i| {
                const options = choices orelse continue;
                if (options.len == 0) continue;
                for (options) |choice| {
                    if (std.meta.eql(choice, self.topics[i])) break;
                } else return false;
            }
        }
        return true;
    }
};

fn expectBloomMember(bloom: *const [256]u8, value: []const u8) !void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(value, &digest, .{});
    for (0..3) |i| {
        const bit = (@as(usize, digest[2 * i] & 7) << 8) + digest[2 * i + 1];
        try std.testing.expect((bloom[255 - bit / 8] >> @intCast(bit % 8)) & 1 == 1);
    }
}

fn checkFilter(index: *logs.LogIndex, records: []const LogRecord, head: usize, filter: logs.LogFilter) !void {
    const actual = try index.query(std.testing.allocator, filter, head);
    defer std.testing.allocator.free(actual);
    var pos: usize = 0;
    for (records) |*record| {
        if (!record.matches(filter)) continue;
        try std.testing.expect(pos < actual.len);
        try std.testing.expectEqualDeep(hash(record.height), actual[pos].block_hash);
        try std.testing.expectEqualDeep(record.event(), actual[pos].log);
        pos += 1;
    }
    try std.testing.expectEqual(pos, actual.len);
}

fn logStream(_: void, input: []const u8) !void {
    const a = std.testing.allocator;
    var index = logs.LogIndex.init();
    defer index.deinit(a);
    var records: std.ArrayList(LogRecord) = .empty;
    defer records.deinit(a);
    var head: usize = 0;
    var chunks = std.mem.window(u8, input[0..@min(input.len, 2048)], 4, 4);
    while (chunks.next()) |bytes| {
        if (bytes.len != 4) break;
        const op = bytes[0];
        if (op & 3 == 0) {
            head += 1;
            const count = (op >> 2) % 4;
            var events: [3]primitives.EventLog.EventLog = undefined;
            try records.ensureUnusedCapacity(a, count);
            for (events[0..count], 0..) |*event, j| {
                var r = LogRecord{ .height = head, .position = @intCast(j), .addr = @truncate((bytes[1] +% @as(u8, @intCast(j))) % 8), .topic_count = (@as(usize, bytes[2]) + j) % 5, .topics = undefined, .data = .{ bytes[3], @intCast(j) } };
                for (&r.topics, 0..) |*t, k| t.* = hash((@as(usize, bytes[3]) + k + j) % 8);
                records.appendAssumeCapacity(r);
                event.* = records.items[records.items.len - 1].event();
            }
            const r = receipt(head, head, head, 0, events[0..count]);
            try index.appendBlockLogs(a, head, hash(head), &.{r});
            for (r.logs) |event| {
                try expectBloomMember(&r.logs_bloom, &event.address.bytes);
                for (event.topics) |t| try expectBloomMember(&r.logs_bloom, &t);
            }
        } else {
            const x = @as(usize, bytes[1]) % (head + 1);
            const y = @as(usize, bytes[2]) % (head + 1);
            var filter: logs.LogFilter = switch (op & 3) {
                1 => .{ .from_block = @min(x, y), .to_block = @max(x, y) },
                2 => .{ .block_hash = hash(x) },
                else => .{},
            };
            const addresses = [_]primitives.Address{ address(bytes[1] % 8), address(bytes[2] % 8) };
            if (op & 4 != 0) filter.addresses = addresses[0 .. 1 + @as(usize, (op >> 3) & 1)];
            var terms: [4][2][32]u8 = undefined;
            var matrix: [4]?[]const [32]u8 = undefined;
            for (&matrix, 0..) |*m, k| {
                terms[k] = .{ hash((@as(usize, bytes[1]) + k) % 8), hash((@as(usize, bytes[2]) + k) % 8) };
                m.* = if (bytes[3] & (@as(u8, 1) << @intCast(k)) != 0) null else &terms[k];
            }
            filter.topics = matrix[0 .. (op >> 4) % 5];
            try checkFilter(&index, records.items, head, filter);
        }
    }
    try checkFilter(&index, records.items, head, .{});
}

const seeds = [_]u64{ 0, 42, 0x4844, 0xfaceb00c };
test "property: stateful transaction pool agrees with nonce table" {
    for (seeds) |seed| {
        var random = std.Random.DefaultPrng.init(seed);
        var stream: [384]u8 = undefined;
        random.random().bytes(&stream);
        try poolStream({}, &stream);
    }
}

test "property: block log queries agree with an ordered full scan" {
    for (seeds) |seed| {
        var random = std.Random.DefaultPrng.init(seed);
        var stream: [384 * 4]u8 = undefined;
        random.random().bytes(&stream);
        try logStream({}, &stream);
    }
}

test "fuzz: transaction pool opcode stream" {
    try poolStream({}, "");
    try std.testing.fuzz({}, poolStream, .{ .corpus = &.{ "\x20\x00\x0c", "\x02\x0b\x0a\x0d", "\x03\x06\x07\x1f", "\x00\x04\x05\x01", "\x42\x4e\x4c", "\x13\x03\x33\x23" } });
}

test "fuzz: log insertion and eth_getLogs filter stream" {
    try logStream({}, "");
    try std.testing.fuzz({}, logStream, .{ .corpus = &.{ "\x00\x00\x00\x00", "\x04\x01\x02\x03\x03\x00\x00\x00", "\x08\x01\x00\x00\x13\x01\x00\xff", "\x0c\x07\x04\x07\x46\x01\x07\x02", "\x08\x00\x04\x01\x25\x00\x01\x02" } });
}
