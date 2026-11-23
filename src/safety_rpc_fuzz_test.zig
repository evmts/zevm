// The deterministic properties and coverage-guided targets share the same oracles.
// Fuzz bytes select individual fields/operations so a mutation stays local.
const std = @import("std");
const t = std.testing;
const alloc = t.allocator;
const primitives = @import("primitives");
const jsonrpc = @import("jsonrpc");
const NodeRuntime = @import("node/runtime.zig").NodeRuntime;
const processor = @import("tx_processor.zig");
const HostAdapter = @import("host_adapter.zig").HostAdapter;
const ReceiptIndex = @import("receipt_index.zig").ReceiptIndex;
const log_index = @import("log_index.zig");
const parse = @import("rpc/parse.zig");
const dispatcher = @import("rpc/dispatcher.zig");
const wiring = @import("rpc/dispatch_wiring.zig");
const queries = @import("rpc/handlers/block_query_handlers.zig");
const Receipt = primitives.Receipt.Receipt;
const Log = primitives.EventLog.EventLog;
const Value = std.json.Value;
const iterations = 1024;
const max = std.math.maxInt(u256);
const addr = "0x0000000000000000000000000000000000001234";
const addr2 = "0x0000000000000000000000000000000000002345";

const Input = struct {
    bytes: []const u8,

    fn byte(self: *Input) u8 {
        if (self.bytes.len == 0) return 0;
        const result = self.bytes[0];
        self.bytes = self.bytes[1..];
        return result;
    }

    fn word(self: *Input) u256 {
        const edges = [_]u256{ 0, 1, 1 << 64, 1 << 128, max };
        const choice = self.byte() % 8;
        if (choice < edges.len) {
            const edge = edges[choice];
            return switch (self.byte() % 3) {
                0 => edge,
                1 => edge -| 1,
                else => edge +| 1,
            };
        }
        var buf = [_]u8{0} ** 32;
        const n = @min(self.bytes.len, if (choice == 5) @as(usize, 2) else buf.len);
        @memcpy(buf[0..n], self.bytes[0..n]);
        self.bytes = self.bytes[n..];
        return std.mem.readInt(u256, &buf, .little);
    }
};

fn seeded(comptime seed: u64, comptime size: usize, ctx: anytype, comptime check: anytype) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    for (0..iterations) |_| {
        var bytes: [size]u8 = undefined;
        prng.random().bytes(&bytes);
        try check(ctx, &bytes);
    }
}

fn checkFees(_: void, bytes: []const u8) !void {
    var in = Input{ .bytes = bytes };
    const kind = in.byte() % 3;
    const gas: u64 = switch (in.byte() % 6) {
        0 => 0,
        1 => 1,
        2 => 21000,
        3 => 21000 + @as(u64, in.byte()),
        4 => std.math.maxInt(u64) - @as(u64, in.byte() % 2),
        else => @truncate(in.word()),
    };
    const price = in.word();
    const cap = if (kind == 0) price else in.word();
    const tip = in.word();
    const base = in.word();
    const value = in.word();
    const blob_cap = if (kind == 2) in.word() else 0;
    const blob_count: usize = if (kind == 2) 1 + (in.byte() % 6) else 0;
    var blob_hashes: [6][32]u8 = undefined;
    for (blob_hashes[0..blob_count], 0..) |*h, idx| {
        h.* = hash(@intCast(idx + 1));
        h[0] = 0x01;
    }
    const blobs: u256 = @as(u256, 131072) * blob_count;
    const blob_price = @min(blob_cap, in.word());
    // All products and their sum fit in 512 bits, even when the sender cannot pay.
    const cost = @as(u512, cap) * gas + @as(u512, blob_cap) * blobs + value;
    const threshold: u256 = @intCast(@min(cost, max));
    const balance = switch (in.byte() % 4) {
        0 => threshold,
        1 => threshold -| 1,
        2 => max,
        else => in.word(),
    };

    var state = try @import("state-manager").StateManager.init(alloc, null);
    defer state.deinit();
    var host = HostAdapter{ .state = &state };
    const sender = primitives.Address.fromU256(0x1234);
    const recipient = primitives.Address.fromU256(0x2345);
    const miner = primitives.Address.fromU256(0x3456);
    try state.setBalance(sender, balance);
    const result = processor.processTransactionWithOptions(alloc, &state, host.hostInterface(), sender, .{
        .to = recipient,
        .data = &.{},
        .gas_limit = gas,
        .gas_price = price,
        .value = value,
        .nonce = 0,
        .v = 0,
        .r = hash(0),
        .s = hash(0),
    }, .{
        .chain_id = 1,
        .block_number = 1,
        .block_timestamp = 1,
        .block_coinbase = miner,
        .block_base_fee = base,
        .blob_base_fee = blob_price,
        .block_gas_limit = std.math.maxInt(u64),
        .block_prevrandao = 0,
        .block_difficulty = 0,
    }, .{
        .hardfork_override = .CANCUN,
        .receipt_type = switch (kind) {
            0 => .legacy,
            1 => .eip1559,
            else => .eip4844,
        },
        .max_fee_per_gas = cap,
        .max_priority_fee_per_gas = tip,
        .max_fee_per_blob_gas = blob_cap,
        .blob_gas_used = blobs,
        .blob_gas_price = blob_price,
        .blob_versioned_hashes = if (kind == 2) blob_hashes[0..blob_count] else null,
    });
    const expected: ?processor.TxError = if (gas < 21000) error.IntrinsicGasExceedsLimit else if (kind != 0 and tip > cap) error.TipExceedsFeeCap else if (cap < base) error.GasPriceBelowBaseFee else if (cost > balance) error.InsufficientBalance else null;
    if (expected) |err| {
        if (result) |receipt| {
            receipt.deinit(alloc);
            return error.ExpectedRejection;
        } else |actual| try t.expectEqual(err, actual);
        try t.expectEqual(balance, try state.getBalance(sender));
        try t.expectEqual(0, try state.getNonce(sender));
        try t.expectEqual(0, try state.getBalance(recipient));
        try t.expectEqual(0, try state.getBalance(miner));
    } else {
        const receipt = try result;
        defer receipt.deinit(alloc);
        const effective: u512 = if (kind == 0) price else @min(cap, @as(u512, base) + tip);
        // The interpreter uses signed frame gas. A synthetic block above its
        // limit may exhaust gas; the fee ledger must still settle exactly.
        const success = receipt.status.?.success;
        if (!success) try t.expect(gas - 21000 > std.math.maxInt(i64));
        const used: u64 = if (success) 21000 else gas;
        const transferred: u256 = if (success) value else 0;
        try t.expectEqual(used, receipt.gas_used);
        try t.expectEqual(effective, receipt.effective_gas_price);
        try t.expectEqual(@as(u512, balance) - transferred - effective * used - @as(u512, blob_price) * blobs, try state.getBalance(sender));
        try t.expectEqual(transferred, try state.getBalance(recipient));
        try t.expectEqual((effective - base) * used, try state.getBalance(miner));
        try t.expectEqual(1, try state.getNonce(sender));
    }
}

test "checked fees agree with 512-bit accounting and settlement" {
    try seeded(0x55, 320, {}, checkFees);
}

test "fuzz checked fees" {
    try t.fuzz({}, checkFees, .{ .corpus = &.{ "\x01\x02" ** 48, "\x02\x03\x00\x04\x00" ** 24 } });
}

fn nibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'A'...'F' => c - 'A' + 10,
        'a'...'f' => c - 'a' + 10,
        else => null,
    };
}

fn checkText(_: void, bytes: []const u8) !void {
    const prefixed = std.mem.startsWith(u8, bytes, "0x");
    const digits = if (prefixed) bytes[2..] else "";
    var hex = prefixed;
    for (digits) |c| if (nibble(c) == null) {
        hex = false;
        break;
    };
    const is_quantity = hex and digits.len != 0 and (digits.len == 1 or digits[0] != '0');
    const v: Value = .{ .string = bytes };
    try t.expectEqual(is_quantity, parse.isQuantityHex(bytes));
    if (is_quantity) try parse.validateQuantityValue(v) else try t.expectError(error.InvalidParams, parse.validateQuantityValue(v));
    inline for (.{ u64, u256 }) |T| {
        if (is_quantity and digits.len <= @bitSizeOf(T) / 4) {
            var expected: T = 0;
            for (digits) |c| expected = (expected << 4) | nibble(c).?;
            try t.expectEqual(expected, try parse.parseQuantityValue(T, v));
        } else try t.expectError(error.InvalidParams, parse.parseQuantityValue(T, v));
    }
    if (hex and digits.len % 2 == 0) {
        const decoded = try parse.parseHexDataBytes(alloc, v);
        defer alloc.free(decoded);
        try t.expectEqual(digits.len / 2, decoded.len);
        for (decoded, 0..) |b, i| try t.expectEqual(nibble(digits[2 * i]).? * 16 + nibble(digits[2 * i + 1]).?, b);
    } else try t.expectError(error.InvalidParams, parse.parseHexDataBytes(alloc, v));
}

test "quantity and data grammar including oversized and non-string inputs" {
    var prng = std.Random.DefaultPrng.init(0x4448);
    for (0..iterations) |_| {
        var buf: [132]u8 = undefined;
        prng.random().bytes(&buf);
        const len = prng.random().uintAtMost(usize, buf.len);
        try checkText({}, buf[0..len]);
        @memcpy(buf[0..2], "0x");
        for (buf[2..]) |*c| c.* = "0123456789abCDef"[c.* % 16];
        try checkText({}, buf[0..len]);
        buf[prng.random().uintLessThan(usize, buf.len)] = prng.random().int(u8);
        try checkText({}, buf[0..len]);
        for ([_]Value{ .{ .integer = prng.random().int(i64) }, .{ .float = -prng.random().float(f64) }, .{ .number_string = "-18446744073709551617" }, .{ .bool = prng.random().boolean() }, .null }) |v| {
            try t.expectError(error.InvalidParams, parse.parseQuantityValue(u256, v));
            try t.expectError(error.InvalidParams, parse.parseHexDataBytes(alloc, v));
        }
    }
    for ([_][]const u8{ "0x", "0x00", "0X1", "0x-1", "-0x1", "0xFF", "0x1_2", "0x\xff", "0x" ++ "f" ** 8192 }) |text|
        try checkText({}, text);
}

test "fuzz raw quantity and hex data bytes" {
    try t.fuzz({}, checkText, .{ .corpus = &.{ "0x" ++ "aB" ** 32, "0x" ++ "0" ** 64, "0x" ++ "a" ** 65 } });
}

fn hash(id: u8) [32]u8 {
    return [_]u8{id} ** 32;
}

const sample_topics = [_][32]u8{hash(1)};

fn logFor(block: u64, tx: u8, data: []const u8) Log {
    return .{
        .address = primitives.Address.fromU256(0x1234),
        .topics = &sample_topics,
        .data = data,
        .block_number = block,
        .transaction_hash = hash(tx),
        .transaction_index = 0,
        .log_index = 0,
        .removed = false,
    };
}

fn receiptFor(block: u8, tx: u8, logs: []const Log) Receipt {
    return .{
        .transaction_hash = hash(tx),
        .block_hash = hash(block),
        .block_number = block,
        .transaction_index = 0,
        .sender = primitives.Address.ZERO_ADDRESS,
        .to = null,
        .contract_address = null,
        .logs = logs,
        .logs_bloom = [_]u8{0} ** 256,
        .cumulative_gas_used = 21000,
        .gas_used = 21000,
        .status = .{ .success = true, .gas_used = 21000 },
        .root = null,
        .type = .legacy,
        .effective_gas_price = 1,
        .blob_gas_used = null,
        .blob_gas_price = null,
    };
}

const ReceiptModel = struct {
    // At most one receipt per model block. Re-sealing the same tx re-points
    // its tx lookup; removing its owner drops that lookup.
    blocks: [8]?u8 = @splat(null),
    owners: [8]?u8 = @splat(null),

    fn remove(self: *ReceiptModel, block: u8) void {
        if (self.blocks[block]) |tx| {
            if (self.owners[tx] == block) self.owners[tx] = null;
            self.blocks[block] = null;
        }
    }

    fn verify(self: ReceiptModel, idx: *const ReceiptIndex) !void {
        for (self.blocks, self.owners, 0..) |block_tx, owner, i| {
            const key = hash(@intCast(i));
            if (block_tx) |tx| {
                const list = idx.getByBlockHash(key) orelse return error.MissingBlock;
                try t.expectEqual(1, list.len);
                try t.expectEqual(hash(tx), list[0].transaction_hash);
                try t.expectEqualSlices(u8, &.{tx}, list[0].logs[0].data);
            } else try t.expect(idx.getByBlockHash(key) == null);
            if (owner) |block| {
                const receipt = idx.getByTxHash(key) orelse return error.MissingTransaction;
                try t.expectEqual(hash(block), receipt.block_hash);
                try t.expectEqualSlices(u8, &.{@intCast(i)}, receipt.logs[0].data);
                try t.expectEqual(hash(1), receipt.logs[0].topics[0]);
            } else try t.expect(idx.getByTxHash(key) == null);
        }
    }
};

fn receiptSequence(_: void, bytes: []const u8) !void {
    var failing = t.FailingAllocator.init(alloc, .{});
    const a = failing.allocator();
    var idx = ReceiptIndex.init(a);
    defer idx.deinit(a);
    var model: ReceiptModel = .{};
    var in = Input{ .bytes = bytes[0..@min(bytes.len, 128)] };
    while (in.bytes.len != 0) {
        const op = in.byte();
        const block = (op >> 2) % 8;
        const tx = in.byte() % 8;
        switch (op % 4) {
            0 => {
                idx.removeBlockReceipts(a, hash(block));
                model.remove(block);
            },
            1 => {
                var snapshot = try idx.clone(a);
                defer snapshot.deinit(a);
                try model.verify(&snapshot);
            },
            else => {
                failing.fail_index = if (op % 4 == 2) failing.alloc_index + (in.byte() % 9) else std.math.maxInt(usize);
                const logs = [_]Log{logFor(block, tx, &.{tx})};
                if (idx.putBlockReceipts(a, hash(block), &.{receiptFor(block, tx, &logs)})) |_| {
                    model.remove(block);
                    model.blocks[block] = tx;
                    model.owners[tx] = block;
                } else |err| try t.expectEqual(error.OutOfMemory, err);
                failing.fail_index = std.math.maxInt(usize);
            },
        }
        try model.verify(&idx);
    }
}

test "receipt index randomized put replace rollback snapshot and OOM" {
    try seeded(0x53, 32, {}, receiptSequence);
}

test "fuzz receipt index operation sequences" {
    try t.fuzz({}, receiptSequence, .{ .corpus = &.{"\x03\x00\x07\x00\x04\x00\x01\x00"} });
}

test "receipt snapshot preserves an absent tx lookup after re-seal and removal" {
    try receiptSequence({}, "\x03\x00\x07\x00\x04\x00\x01\x00");
}

fn verifyLogs(idx: *const log_index.LogIndex, expected: []const u8, from: u8, to: u8, by_hash: bool, a: std.mem.Allocator) !void {
    const filter: log_index.LogFilter = if (by_hash) .{ .block_hash = hash(from) } else .{ .from_block = from, .to_block = to };
    const rows = try idx.query(a, filter, to);
    defer a.free(rows);
    var n: usize = 0;
    for (expected, 0..) |len, block| {
        if (block < from or block > to or (by_hash and block != from)) continue;
        for (0..len) |j| {
            try t.expect(n < rows.len);
            const row = rows[n];
            try t.expectEqual(hash(@intCast(block)), row.block_hash);
            try t.expectEqual(block, row.log.block_number.?);
            try t.expectEqual(hash(1), row.log.topics[0]);
            try t.expectEqualSlices(u8, &.{ @intCast(block), @intCast(j) }, row.log.data);
            n += 1;
        }
    }
    try t.expectEqual(n, rows.len);
}

fn appendLogs(idx: *log_index.LogIndex, a: std.mem.Allocator, block: u8, count: u8) !void {
    var logs: [4]Log = undefined;
    var data: [4][2]u8 = undefined;
    for (0..count) |j| {
        data[j] = .{ block, @intCast(j) };
        logs[j] = logFor(block, block, &data[j]);
    }
    try idx.appendBlockLogs(a, block, hash(block), &.{receiptFor(block, block, logs[0..count])});
}

fn logSequence(_: void, bytes: []const u8) !void {
    var failing = t.FailingAllocator.init(alloc, .{});
    const a = failing.allocator();
    var idx = log_index.LogIndex.init();
    defer idx.deinit(a);
    var counts = [_]u8{0} ** 32;
    for (bytes[0..@min(bytes.len, counts.len)], 0..) |op, i| {
        const block: u8 = @intCast(i);
        if (op & 1 == 1) failing.fail_index = failing.alloc_index + (op >> 1) % 12;
        const len = (op >> 4) % 5;
        if (appendLogs(&idx, a, block, len)) |_| {
            counts[i] = len;
            try t.expect(idx.block_range.contains(block));
        } else |err| {
            try t.expectEqual(error.OutOfMemory, err);
            try t.expect(!idx.block_range.contains(block));
        }
        failing.fail_index = std.math.maxInt(usize);
        try verifyLogs(&idx, &counts, 0, block, false, alloc);
        try verifyLogs(&idx, &counts, op % (block + 1), block, op & 2 != 0, alloc);
        // A partial append can be invisible to a range query yet visible by hash.
        try verifyLogs(&idx, &counts, block, block, true, alloc);
    }
}

test "log index randomized append rollback query and OOM" {
    try seeded(0x5300, 12, {}, logSequence);
}

test "fuzz log index operation sequences" {
    try t.fuzz({}, logSequence, .{ .corpus = &.{"\x10\x20\x43\x30"} });
}

// Start each allocation-failure replay from scratch. On every error read back
// the full public state using the independent testing allocator.
fn indexAllocations(a: std.mem.Allocator) !void {
    var receipts = ReceiptIndex.init(a);
    defer receipts.deinit(a);
    var logs = log_index.LogIndex.init();
    defer logs.deinit(a);
    var counts = [_]u8{0} ** 8;
    for (0..counts.len) |i| {
        const block: u8 = @intCast(i);
        const events = [_]Log{ logFor(block, block, "abc"), logFor(block, block, "d") };
        const rows = [_]Receipt{receiptFor(block, block, &events)};
        receipts.putBlockReceipts(a, hash(block), &rows) catch |err| {
            try t.expect(receipts.getByBlockHash(hash(block)) == null);
            try t.expect(receipts.getByTxHash(hash(block)) == null);
            try verifyPriorReceipts(&receipts, i);
            return err;
        };
        appendLogs(&logs, a, block, 2) catch |err| {
            receipts.removeBlockReceipts(a, hash(block));
            try t.expect(!logs.block_range.contains(block));
            try t.expect(receipts.getByBlockHash(hash(block)) == null);
            try t.expect(receipts.getByTxHash(hash(block)) == null);
            try verifyPriorReceipts(&receipts, i);
            try verifyLogs(&logs, &counts, 0, block, false, alloc);
            try verifyLogs(&logs, &counts, block, block, true, alloc);
            return err;
        };
        counts[i] = 2;
    }
    try verifyPriorReceipts(&receipts, counts.len);
    var copy = receipts.clone(a) catch |err| {
        try verifyPriorReceipts(&receipts, counts.len);
        return err;
    };
    defer copy.deinit(a);
    try verifyPriorReceipts(&copy, counts.len);
    var log_copy = logs.clone(a) catch |err| {
        try verifyLogs(&logs, &counts, 0, 7, false, alloc);
        return err;
    };
    defer log_copy.deinit(a);
    verifyLogs(&log_copy, &counts, 0, 7, false, a) catch |err| {
        try verifyLogs(&log_copy, &counts, 0, 7, false, alloc);
        return err;
    };
}

fn verifyPriorReceipts(ri: *const ReceiptIndex, n: usize) !void {
    try t.expectEqual(n, ri.by_tx.count());
    try t.expectEqual(n, ri.by_block.count());
    for (0..n) |i| {
        const key = hash(@intCast(i));
        const rows = ri.getByBlockHash(key) orelse return error.MissingBlock;
        try t.expectEqual(1, rows.len);
        const tx = ri.getByTxHash(key) orelse return error.MissingTransaction;
        try t.expectEqual(rows[0].logs.ptr, tx.logs.ptr);
        try t.expectEqual(2, tx.logs.len);
        try t.expectEqualSlices(u8, "abc", tx.logs[0].data);
        try t.expectEqualSlices(u8, "d", tx.logs[1].data);
    }
}

test "every allocation in receipt and log growth cloning rollback and query" {
    try t.checkAllAllocationFailures(alloc, indexAllocations, .{});
}

test "inclusive log range ends at the largest u64 height" {
    var idx = log_index.LogIndex.init();
    defer idx.deinit(alloc);
    const last = std.math.maxInt(u64);
    const logs = [_]Log{logFor(last, 0, "x")};
    try idx.appendBlockLogs(alloc, last, hash(1), &.{receiptFor(1, 0, &logs)});
    const rows = try idx.query(alloc, .{ .from_block = last, .to_block = last }, last);
    defer alloc.free(rows);
    try t.expectEqual(1, rows.len);
    try t.expectEqual(last, rows[0].log.block_number.?);
}

fn str(s: []const u8) Value {
    return .{ .string = s };
}

fn quantity(a: std.mem.Allocator, n: anytype) !Value {
    return str(try std.fmt.allocPrint(a, "0x{x}", .{n}));
}

fn rpc(rt: *NodeRuntime, method: []const u8, args: []const Value) !jsonrpc.envelope.ResponseEnvelope {
    var handlers: dispatcher.HandlerRegistry = .{};
    wiring.install(&handlers, rt);
    var params = std.json.Array.init(alloc);
    defer params.deinit();
    try params.appendSlice(args);
    return dispatcher.dispatch(alloc, .{ .jsonrpc = "2.0", .id = .{ .integer = 1 }, .method = method, .params = .{ .array = params } }, &handlers);
}

fn expectRpcError(response: jsonrpc.envelope.ResponseEnvelope, code: i32) !void {
    try t.expect(response.result == null);
    try t.expectEqual(code, (response.error_value orelse return error.ExpectedRpcError).code);
}

fn setupRpc(rt: *NodeRuntime) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    _ = try submit.handleSendTransaction(alloc, rt, try request(arena.allocator(), dev_addr, 21000, rt.gas_price, 1));
    try rt.mineBlocks(2, 0);
    // One synthetic indexed event per height makes both endpoints observable.
    rt.log_index.deinit(alloc);
    rt.log_index = log_index.LogIndex.init();
    for (0..4) |i| {
        const height: u8 = @intCast(i);
        const logs = [_]Log{logFor(height, height, &.{height})};
        try rt.log_index.appendBlockLogs(alloc, height, rt.blockchain.getCanonicalHash(height).?, &.{receiptFor(height, height, &logs)});
    }
    rt.engine_safe_hash = rt.blockchain.getCanonicalHash(2);
    rt.engine_finalized_hash = rt.blockchain.getCanonicalHash(1);
}

const Selector = struct { value: Value, height: ?u64 };

fn selector(a: std.mem.Allocator, control: u8) !Selector {
    const n = control % 14;
    const tags = [_][]const u8{ "earliest", "latest", "pending", "safe", "finalized" };
    const heights = [_]u64{ 0, 3, 3, 2, 1 };
    if (n < tags.len) return .{ .value = str(tags[n]), .height = heights[n] };
    if (n < 11) return .{ .value = try quantity(a, n - 5), .height = n - 5 };
    return .{ .value = switch (n) {
        11 => str("0x00"),
        12 => str("0x10000000000000000"),
        else => .{ .integer = -1 },
    }, .height = null };
}

fn checkRpc(rt: *NodeRuntime, bytes: []const u8) !void {
    var in = Input{ .bytes = bytes };
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const slot = in.word();
    const value = in.word();
    const address = primitives.Address.fromU256(0x1234);
    try rt.state.setStorage(address, slot, value);
    const slot_text = if (in.byte() % 2 == 0) try quantity(a, slot) else str(try std.fmt.allocPrint(a, "0x{x:0>64}", .{slot}));
    var storage = try rpc(rt, "eth_getStorageAt", &.{ str(addr), slot_text, str("latest") });
    defer storage.deinit(alloc);
    const data = (storage.result orelse return error.MissingStorage).string;
    try t.expectEqual(66, data.len);
    try t.expectEqualStrings("0x", data[0..2]);
    var expected: [32]u8 = undefined;
    std.mem.writeInt(u256, &expected, value, .big);
    var decoded: [32]u8 = undefined;
    try t.expectEqualSlices(u8, &expected, try std.fmt.hexToBytes(&decoded, data[2..]));

    if (in.byte() % 4 == 0) {
        var historical = try rpc(rt, "eth_getStorageAt", &.{ str(addr), slot_text, str("earliest") });
        defer historical.deinit(alloc);
        try t.expectEqualStrings("0x" ++ "0" ** 64, (historical.result orelse return error.MissingStorage).string);
    }

    const selected_height = in.byte() % 4;
    const block = (try rt.blockchain.getBlockByNumber(selected_height)).?;
    const by_hash = in.byte() % 2 == 0;
    const block_arg = if (by_hash) str(try std.fmt.allocPrint(a, "0x{x}", .{&block.hash})) else try quantity(a, selected_height);
    var block_result = try rpc(rt, if (by_hash) "eth_getBlockByHash" else "eth_getBlockByNumber", &.{ block_arg, .{ .bool = true } });
    defer block_result.deinit(alloc);
    const header = (block_result.result orelse return error.MissingBlock).object;
    try t.expectEqual(block.header.difficulty, try parse.parseQuantityValue(u256, header.get("difficulty").?));
    try t.expect(header.get("totalDifficulty") == null);
    var selected_receipts = try rpc(rt, "eth_getBlockReceipts", &.{block_arg});
    defer selected_receipts.deinit(alloc);
    const receipts = (selected_receipts.result orelse return error.MissingBlock).array.items;
    try t.expectEqual(@intFromBool(selected_height == 1), receipts.len);
    for (receipts) |receipt| {
        try t.expectEqual(block.hash, try parse.parseHash32Value(receipt.object.get("blockHash").?));
        try t.expectEqual(selected_height, try parse.parseQuantityValue(u64, receipt.object.get("blockNumber").?));
    }

    const before = try rt.getBalance(address);
    const negative: i64 = -1 - @as(i64, @intCast(in.word() & std.math.maxInt(i64)));
    const invalid = switch (in.byte() % 5) {
        0 => Value{ .integer = negative },
        1 => Value{ .float = @floatFromInt(negative) },
        2 => str(try std.fmt.allocPrint(a, "{d}", .{negative})),
        3 => str("0x-1"),
        else => Value.null,
    };
    var mutation = try rpc(rt, "anvil_setBalance", &.{ str(addr), invalid });
    defer mutation.deinit(alloc);
    try expectRpcError(mutation, -32602);
    try t.expectEqual(before, try rt.getBalance(address));

    var filter = std.json.ObjectMap.init(a);
    var from = try selector(a, in.byte());
    var to = try selector(a, in.byte());
    const flags = in.byte();
    if (flags & 1 == 0) try filter.put("fromBlock", from.value) else from.height = 3;
    if (flags & 2 == 0) try filter.put("toBlock", to.value) else to.height = 3;
    var valid = from.height != null and to.height != null and from.height.? <= to.height.? and to.height.? <= 3;
    if (flags & 4 != 0) {
        const height = in.byte() % 4;
        const h = rt.blockchain.getCanonicalHash(height).?;
        try filter.put("blockHash", str(try std.fmt.allocPrint(a, "0x{x}", .{&h})));
        valid = flags & 3 == 3;
        from.height = height;
        to.height = height;
    }
    if (flags & 8 != 0) try filter.put("address", str(if (flags & 16 == 0) addr else addr2));
    var logs = try rpc(rt, "eth_getLogs", &.{.{ .object = filter }});
    defer logs.deinit(alloc);
    if (!valid) {
        try expectRpcError(logs, -32602);
    } else {
        const rows = (logs.result orelse return error.MissingLogs).array.items;
        const count = if (flags & 24 == 24) 0 else to.height.? - from.height.? + 1;
        try t.expectEqual(count, rows.len);
        for (rows, 0..) |row, i| {
            const height = from.height.? + i;
            try t.expectEqual(height, try parse.parseQuantityValue(u64, row.object.get("blockNumber").?));
            try t.expectEqual(rt.blockchain.getCanonicalHash(height).?, try parse.parseHash32Value(row.object.get("blockHash").?));
        }
    }

    const newest = try selector(a, in.byte());
    const count: u64 = switch (in.byte() % 5) {
        0 => 0,
        1 => std.math.maxInt(u64),
        else => 1 + @as(u64, in.byte() % 5),
    };
    var args = std.json.Array.init(a);
    try args.append(try quantity(a, count));
    try args.append(newest.value);
    var percentiles = std.json.Array.init(a);
    var valid_rewards = true;
    const want_rewards = in.byte() % 4 != 0;
    if (want_rewards) {
        const mode = in.byte() % 9;
        const p: f64 = @as(f64, @floatFromInt(in.byte() % 201)) / 2.0;
        switch (mode) {
            0 => {},
            1 => try percentiles.appendSlice(&.{ .{ .float = p }, .{ .float = p }, .{ .integer = 100 } }),
            2 => try percentiles.appendSlice(&.{ .{ .integer = 0 }, .{ .float = p } }),
            3 => {
                try percentiles.appendSlice(&.{ .{ .integer = 100 }, .{ .integer = 99 } });
                valid_rewards = false;
            },
            4 => {
                try percentiles.append(.{ .float = -0.5 });
                valid_rewards = false;
            },
            5 => {
                try percentiles.append(.{ .float = 100.5 });
                valid_rewards = false;
            },
            6 => {
                try percentiles.append(str("1"));
                valid_rewards = false;
            },
            7, 8 => {
                const len: usize = if (mode == 7) 100 else 101;
                try percentiles.appendNTimes(.{ .integer = 1 }, len);
                valid_rewards = len <= 100;
            },
            else => unreachable,
        }
        try args.append(.{ .array = percentiles });
    }
    var fees = try rpc(rt, "eth_feeHistory", args.items);
    defer fees.deinit(alloc);
    if (count == 0 or newest.height == null or newest.height.? > 3 or !valid_rewards) {
        try expectRpcError(fees, -32602);
    } else {
        const obj = (fees.result orelse return error.MissingFeeHistory).object;
        const n = @min(count, newest.height.? + 1);
        try t.expectEqual(newest.height.? + 1 - n, try parse.parseQuantityValue(u64, obj.get("oldestBlock").?));
        for ([_][]const u8{ "baseFeePerGas", "baseFeePerBlobGas" }) |key| {
            const values = obj.get(key).?.array.items;
            try t.expectEqual(n + 1, values.len);
            for (values, 0..) |v, i| {
                const actual = try parse.parseQuantityValue(u256, v);
                if (std.mem.eql(u8, key, "baseFeePerGas")) {
                    const number = newest.height.? + 1 - n + i;
                    const expected_fee = if (try rt.blockchain.getBlockByNumber(number)) |b| b.header.base_fee_per_gas.? else rt.base_fee;
                    try t.expectEqual(expected_fee, actual);
                }
            }
        }
        for ([_][]const u8{ "gasUsedRatio", "blobGasUsedRatio" }) |key| {
            const ratios = obj.get(key).?.array.items;
            try t.expectEqual(n, ratios.len);
            for (ratios, 0..) |v, i| {
                const number = newest.height.? + 1 - n + i;
                const b = (try rt.blockchain.getBlockByNumber(number)).?;
                const ratio: f64 = if (std.mem.eql(u8, key, "gasUsedRatio"))
                    @as(f64, @floatFromInt(b.header.gas_used)) / @as(f64, @floatFromInt(b.header.gas_limit))
                else
                    0;
                try t.expectEqual(ratio, v.float);
            }
        }
        if (want_rewards) {
            const rows = obj.get("reward").?.array.items;
            try t.expectEqual(n, rows.len);
            for (rows, 0..) |row, i| {
                try t.expectEqual(percentiles.items.len, row.array.items.len);
                for (row.array.items) |v| {
                    const reward = try parse.parseQuantityValue(u256, v);
                    if (newest.height.? + 1 - n + i != 1) try t.expectEqual(0, reward);
                }
            }
        } else try t.expect(!obj.contains("reward"));
    }
}

fn rpcFuzz(_: void, bytes: []const u8) !void {
    var rt = try NodeRuntime.init(alloc, null);
    defer rt.deinit();
    try setupRpc(&rt);
    try checkRpc(&rt, bytes);
}

test "storage data mutation rejection log ranges and fee history over JSON-RPC" {
    var rt = try NodeRuntime.init(alloc, null);
    defer rt.deinit();
    try setupRpc(&rt);
    try seeded(0x34384048, 160, &rt, checkRpc);
}

test "fuzz JSON-RPC storage logs and fee history" {
    try t.fuzz({}, rpcFuzz, .{ .corpus = &.{ "\x00" ** 24, "\x04\x00" ** 10, "mixed selectors and percentiles" } });
}

const submit = @import("rpc/handlers/tx_submission.zig");
const dev_addr = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";

fn request(a: std.mem.Allocator, from: []const u8, gas: u64, price: u256, value: u256) !jsonrpc.eth.SendTransaction.Params {
    var obj = std.json.ObjectMap.init(a);
    try obj.put("from", str(from));
    try obj.put("to", str(addr2));
    try obj.put("gas", try quantity(a, gas));
    try obj.put("gasPrice", try quantity(a, price));
    try obj.put("value", try quantity(a, value));
    return .{ .transaction = .{ .value = .{ .object = obj } } };
}

fn setupSubmission(rt: *NodeRuntime) !void {
    try rt.impersonateAccount(primitives.Address.fromU256(0x1234));
    try rt.setBalance(primitives.Address.fromU256(0x1234), max);
    try rt.setMiningConfig(.manual);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var params = try request(arena.allocator(), addr, 21000, rt.gas_price, 0);
    try params.transaction.value.object.put("nonce", str("0x4"));
    _ = try submit.handleSendTransaction(alloc, rt, params);
}

// Keep a queued transaction across failures, including ones from its own sender.
// Check both RPC submission paths and the balance threshold before pool insertion.
fn checkSubmission(rt: *NodeRuntime, bytes: []const u8) !void {
    var in = Input{ .bytes = bytes };
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const sender = primitives.Address.fromU256(0x1234);
    const queued = rt.pool.items()[0].hash;
    const gas: u64 = switch (in.byte() % 5) {
        0 => std.math.maxInt(u64),
        1 => in.byte(),
        else => 21000 + @as(u64, in.byte()),
    };
    const price = @max(rt.gas_price, in.word());
    const value = in.word();
    const cost = @as(u512, price) * gas + value;
    const threshold: u256 = @intCast(@min(cost, max));
    const balance = switch (in.byte() % 3) {
        0 => threshold,
        1 => threshold -| 1,
        else => in.word(),
    };
    try rt.setBalance(sender, balance);
    try rt.setMiningConfig(.manual);
    const submitted = submit.handleSendTransaction(alloc, rt, try request(a, addr, gas, price, value));
    if (gas < 21000 or gas > rt.dev_runtime.config.block_gas_limit) {
        try t.expectError(error.IntrinsicGasExceedsLimit, submitted);
    } else if (cost > balance) {
        try t.expectError(error.InsufficientBalance, submitted);
    } else {
        const result = try submitted;
        try t.expectEqual(1, rt.pool.pendingCount());
        try t.expect(rt.pool.removeByHash(result.value.bytes));
    }
    try t.expectEqual(balance, try rt.getBalance(sender));
    try t.expectEqual(0, try rt.getNonce(sender));

    try rt.setMiningConfig(.auto);
    try rt.setBalance(sender, max);
    rt.next_block_timestamp = rt.head_block_timestamp -| in.byte();
    const raw = in.byte() % 4 == 1;
    const params = try request(a, if (raw) dev_addr else addr, 21000 + @as(u64, in.byte()), rt.gas_price, in.byte());
    const active_sender = if (raw) @import("node/runtime.zig").DEFAULT_DEV_ACCOUNTS[0] else sender;
    const prior_balance = try rt.getBalance(active_sender);
    const nonce = try rt.getNonce(active_sender);
    const head = rt.head_block_number;
    const receipts = rt.receipt_index.by_tx.count();
    if (raw) {
        const signed = try submit.handleSignTransaction(a, rt, params);
        try t.expectError(error.MiningFailed, submit.handleSendRawTransaction(alloc, rt, .{ .transaction = signed.value }));
    } else {
        try t.expectError(error.MiningFailed, submit.handleSendTransaction(alloc, rt, params));
    }
    try t.expectEqual(head, rt.head_block_number);
    try t.expectEqual(nonce, try rt.getNonce(active_sender));
    try t.expectEqual(prior_balance, try rt.getBalance(active_sender));
    try t.expectEqual(receipts, rt.receipt_index.by_tx.count());
    try t.expectEqual(0, rt.pool.pendingCount());
    try t.expectEqual(1, rt.pool.queuedCount());
    try t.expectEqual(queued, rt.pool.items()[0].hash);
}

fn submissionFuzz(_: void, bytes: []const u8) !void {
    var rt = try NodeRuntime.init(alloc, null);
    defer rt.deinit();
    try setupSubmission(&rt);
    try checkSubmission(&rt, bytes);
}

test "submission balance threshold and selective automine eviction" {
    var rt = try NodeRuntime.init(alloc, null);
    defer rt.deinit();
    try setupSubmission(&rt);
    const level = t.log_level;
    defer t.log_level = level;
    t.log_level = .err;
    try seeded(0x5556, 128, &rt, checkSubmission);
}

test "fuzz submission and automine eviction" {
    try t.fuzz({}, submissionFuzz, .{ .corpus = &.{ "\x02\x00\x01" ** 8, "\xff" ** 40 } });
}

fn parseOwnedFilter(a: std.mem.Allocator, ctx: *queries.BlockQueryContext, value: Value) !void {
    var filter = try queries.rpcFilterToInternal(a, ctx, .{ .value = value });
    defer log_index.deinitLogFilter(a, &filter);
    try t.expectEqual(1, filter.addresses.?.len);
    try t.expectEqual(2, filter.topics.?.len);
}

test "owned log filter cleans up partial addresses and topics on rejection and OOM" {
    var rt = try NodeRuntime.init(alloc, null);
    defer rt.deinit();
    var ctx: queries.BlockQueryContext = .{ .rt = &rt, .blockchain = &rt.blockchain, .log_index = &rt.log_index, .receipt_index = &rt.receipt_index };
    const topic = "\"" ++ "0x" ++ "11" ** 32 ++ "\"";
    const filter = "{\"address\":[\"" ++ addr ++ "\"],\"topics\":[" ++ topic ++ ",[" ++ topic ++ "]]}";
    const valid = try std.json.parseFromSlice(Value, alloc, filter, .{});
    defer valid.deinit();
    try t.checkAllAllocationFailures(alloc, parseOwnedFilter, .{ &ctx, valid.value });
    for ([_][]const u8{
        "{\"address\":\"\"}",                   "{\"address\":[null]}",
        "{\"topics\":[\"\"]}",                  "{\"topics\":[[null]]}",
        "{\"topics\":[" ++ topic ++ ",false]}", "{\"address\":\"" ++ addr ++ "\",\"fromBlock\":\"0x1\",\"toBlock\":\"0x0\"}",
    }) |invalid| {
        const parsed = try std.json.parseFromSlice(Value, alloc, invalid, .{});
        defer parsed.deinit();
        try t.expectError(error.InvalidParams, queries.rpcFilterToInternal(alloc, &ctx, .{ .value = parsed.value }));
    }
}

fn checkCadence(rt: *NodeRuntime, bytes: []const u8) !void {
    var in = Input{ .bytes = bytes };
    const configured: u64 = in.byte() + @as(u64, 1);
    rt.setBlockTimestampInterval(configured);
    const control = in.byte();
    if (control & 7 == 7) {
        const head = rt.head_block_number;
        const timestamp = rt.head_block_timestamp;
        rt.setNextBlockTimestamp(std.math.maxInt(u64));
        var overflow = try rpc(rt, "anvil_mine", &.{ str("0x2"), str("0x1") });
        defer overflow.deinit(alloc);
        try expectRpcError(overflow, -32602);
        try t.expectEqual(head, rt.head_block_number);
        try t.expectEqual(timestamp, rt.head_block_timestamp);
        try t.expectEqual(@as(?u64, std.math.maxInt(u64)), rt.next_block_timestamp);
        rt.next_block_timestamp = null;
        rt.dev_runtime.config.next_block_timestamp = null;
        return;
    }
    const interval: u64 = in.byte();
    const explicit = control & 1 != 0;
    const step = if (explicit) @max(1, interval) else configured;
    const parent = rt.head_block_timestamp;
    const head = rt.head_block_number;
    const first = if (control & 2 != 0) blk: {
        const override = parent + 1 + in.byte();
        rt.setNextBlockTimestamp(override);
        break :blk override;
    } else parent + step;
    var buf: [18]u8 = undefined;
    const params = [_]Value{ str("0x2"), str(try std.fmt.bufPrint(&buf, "0x{x}", .{interval})) };
    var mined = try rpc(rt, "anvil_mine", params[0..if (explicit) @as(usize, 2) else 1]);
    defer mined.deinit(alloc);
    try t.expect((mined.result orelse return error.MiningFailed).bool);
    try t.expectEqual(head + 2, rt.head_block_number);
    try t.expectEqual(first, (try rt.blockchain.getBlockByNumber(head + 1)).?.header.timestamp);
    try t.expectEqual(first + step, rt.head_block_timestamp);
}

test "empty block timestamps follow one-shot explicit and configured intervals" {
    var rt = try NodeRuntime.init(alloc, null);
    defer rt.deinit();
    try seeded(0x40, 4, &rt, checkCadence);
}

fn cadenceFuzz(_: void, bytes: []const u8) !void {
    var rt = try NodeRuntime.init(alloc, null);
    defer rt.deinit();
    try checkCadence(&rt, bytes);
}

test "fuzz mining cadence" {
    try t.fuzz({}, cadenceFuzz, .{ .corpus = &.{"\x00\x01\x02\x03" ** 16} });
}

test "explicit two-second interval applies to the first block too" {
    try cadenceFuzz({}, "\x00\x01\x02");
}

test "two blocks starting at the last representable timestamp are rejected atomically" {
    try cadenceFuzz({}, "\x00\x07");
}
