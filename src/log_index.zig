const std = @import("std");
const primitives = @import("primitives");

/// Filter parameters matching eth_getLogs spec.
pub const LogFilter = struct {
    from_block: ?u64 = null,
    to_block: ?u64 = null,
    block_hash: ?[32]u8 = null,
    addresses: ?[]const primitives.Address.Address = null,
    topics: ?[]const ?[]const [32]u8 = null,
};

pub fn deinitLogFilter(allocator: std.mem.Allocator, filter: *LogFilter) void {
    if (filter.addresses) |addresses| {
        allocator.free(addresses);
        filter.addresses = null;
    }
    if (filter.topics) |topics| {
        for (topics) |maybe_topic_set| {
            if (maybe_topic_set) |topic_set| allocator.free(topic_set);
        }
        allocator.free(topics);
        filter.topics = null;
    }
}

/// An indexed log entry with block_hash stored alongside (EventLog lacks block_hash).
pub const IndexedLog = struct {
    log: primitives.EventLog.EventLog,
    block_hash: [32]u8,
};

const BlockRange = struct {
    start: usize,
    end: usize,
    bloom: [4]u64 = .{ 0, 0, 0, 0 },
    /// Block the range belongs to, so `removeBlocksAbove` can retire the
    /// by-hash entry of a block that carries no logs.
    block_number: u64 = 0,
};

pub const LogIndex = struct {
    logs: std.ArrayListUnmanaged(IndexedLog),
    block_range: std.AutoHashMapUnmanaged(u64, BlockRange),
    block_hash_range: std.AutoHashMapUnmanaged([32]u8, BlockRange),
    block_numbers: std.ArrayListUnmanaged(u64),
    /// Logs at or past this offset were retired by `removeBlocksAbove`. No
    /// range references them; the next append or `deinit` frees them.
    live_len: usize = 0,

    pub fn init() LogIndex {
        return .{
            .logs = .{},
            .block_range = .{},
            .block_hash_range = .{},
            .block_numbers = .{},
        };
    }

    pub fn deinit(self: *LogIndex, allocator: std.mem.Allocator) void {
        for (self.logs.items) |entry| {
            allocator.free(entry.log.topics);
            allocator.free(entry.log.data);
        }
        self.logs.deinit(allocator);
        self.block_range.deinit(allocator);
        self.block_hash_range.deinit(allocator);
        self.block_numbers.deinit(allocator);
    }

    pub fn clone(self: *const LogIndex, allocator: std.mem.Allocator) !LogIndex {
        var cloned = LogIndex.init();
        errdefer cloned.deinit(allocator);

        const live_logs = self.logs.items[0..@min(self.live_len, self.logs.items.len)];
        try cloned.logs.ensureTotalCapacity(allocator, live_logs.len);
        for (live_logs) |entry| {
            const cloned_log = try cloneEventLog(allocator, entry.log);
            var log_owned = false;
            errdefer if (!log_owned) {
                allocator.free(cloned_log.topics);
                allocator.free(cloned_log.data);
            };
            cloned.logs.appendAssumeCapacity(.{
                .log = cloned_log,
                .block_hash = entry.block_hash,
            });
            log_owned = true;
        }
        cloned.live_len = cloned.logs.items.len;

        try cloned.block_range.ensureTotalCapacity(allocator, self.block_range.count());
        var range_it = self.block_range.iterator();
        while (range_it.next()) |entry| {
            cloned.block_range.putAssumeCapacity(entry.key_ptr.*, entry.value_ptr.*);
        }

        try cloned.block_hash_range.ensureTotalCapacity(allocator, self.block_hash_range.count());
        var hash_it = self.block_hash_range.iterator();
        while (hash_it.next()) |entry| {
            cloned.block_hash_range.putAssumeCapacity(entry.key_ptr.*, entry.value_ptr.*);
        }

        try cloned.block_numbers.appendSlice(allocator, self.block_numbers.items);

        return cloned;
    }

    /// Append all logs from a mined block's receipts. Must be called in ascending block order.
    /// On error the index is unchanged.
    pub fn appendBlockLogs(
        self: *LogIndex,
        allocator: std.mem.Allocator,
        block_number: u64,
        block_hash: [32]u8,
        receipts: []const primitives.Receipt.Receipt,
    ) !void {
        var log_count: usize = 0;
        for (receipts) |receipt| {
            log_count = std.math.add(usize, log_count, receipt.logs.len) catch return error.OutOfMemory;
        }

        // Free logs retired by `removeBlocksAbove`; no range references them.
        self.truncateLogs(allocator, self.live_len);

        // Reserve every container before the first mutation so a failed
        // allocation cannot leave logs without a range or a range without its
        // sorted block number.
        try self.logs.ensureUnusedCapacity(allocator, log_count);
        try self.block_range.ensureUnusedCapacity(allocator, 1);
        try self.block_hash_range.ensureUnusedCapacity(allocator, 1);
        try self.block_numbers.ensureUnusedCapacity(allocator, 1);

        const start = self.logs.items.len;
        var bloom = [_]u64{ 0, 0, 0, 0 };
        errdefer {
            for (self.logs.items[start..]) |entry| {
                allocator.free(entry.log.topics);
                allocator.free(entry.log.data);
            }
            self.logs.shrinkRetainingCapacity(start);
        }

        for (receipts) |receipt| {
            for (receipt.logs) |log| {
                const cloned = try cloneEventLog(allocator, log);
                self.logs.appendAssumeCapacity(.{
                    .log = cloned,
                    .block_hash = block_hash,
                });
                bloomAdd(&bloom, &cloned.address.bytes);
                for (cloned.topics) |topic| {
                    bloomAdd(&bloom, &topic);
                }
            }
        }

        // Infallible from here: capacity is reserved.
        const end = self.logs.items.len;
        self.live_len = end;
        const range = BlockRange{ .start = start, .end = end, .bloom = bloom, .block_number = block_number };
        const existed = self.block_range.contains(block_number);
        // Capacity was reserved above, so nothing below can fail.
        self.block_range.putAssumeCapacity(block_number, range);
        self.block_hash_range.putAssumeCapacity(block_hash, range);
        if (!existed) {
            const bn = self.block_numbers.items;
            if (bn.len == 0 or bn[bn.len - 1] < block_number) {
                self.block_numbers.appendAssumeCapacity(block_number);
            } else {
                const pos = lowerBound(self.block_numbers.items, block_number);
                self.block_numbers.insertAssumeCapacity(pos, block_number);
            }
        }
    }

    /// Remove every indexed block strictly above `max_block_number` (reorg to
    /// a shorter or different canonical chain). Lookups by number and by hash
    /// for the removed blocks return nothing afterwards.
    ///
    /// The index stores no allocator, so the removed blocks' log buffers are
    /// retired here and freed by the next `appendBlockLogs` or by `deinit`.
    pub fn removeBlocksAbove(self: *LogIndex, max_block_number: u64) void {
        // `block_numbers` is sorted ascending: drop its tail.
        const keep = if (max_block_number == std.math.maxInt(u64))
            self.block_numbers.items.len
        else
            lowerBound(self.block_numbers.items, max_block_number + 1);
        for (self.block_numbers.items[keep..]) |block_number| {
            _ = self.block_range.remove(block_number);
        }
        self.block_numbers.shrinkRetainingCapacity(keep);

        // `removeByPtr` only tombstones the slot, so the iterator stays valid.
        var hash_it = self.block_hash_range.iterator();
        while (hash_it.next()) |entry| {
            if (entry.value_ptr.block_number > max_block_number) {
                self.block_hash_range.removeByPtr(entry.key_ptr);
            }
        }

        // Retire the log tail that no surviving range references. Logs below
        // the highest surviving range stay in place so every range keeps its
        // offsets.
        var live_end: usize = 0;
        var range_it = self.block_range.valueIterator();
        while (range_it.next()) |range| live_end = @max(live_end, range.end);
        var hash_range_it = self.block_hash_range.valueIterator();
        while (hash_range_it.next()) |range| live_end = @max(live_end, range.end);
        self.live_len = @min(self.live_len, live_end);
    }

    fn truncateLogs(self: *LogIndex, allocator: std.mem.Allocator, new_len: usize) void {
        if (new_len >= self.logs.items.len) return;
        for (self.logs.items[new_len..]) |entry| {
            allocator.free(entry.log.topics);
            allocator.free(entry.log.data);
        }
        self.logs.shrinkRetainingCapacity(new_len);
    }

    /// Execute a filter query. Returns owned slice of matching logs (caller frees).
    pub fn query(
        self: *const LogIndex,
        allocator: std.mem.Allocator,
        filter: LogFilter,
        head_block_number: u64,
    ) ![]IndexedLog {
        // Validation
        if (filter.block_hash != null and (filter.from_block != null or filter.to_block != null)) {
            return error.InvalidFilter;
        }
        const from = filter.from_block orelse 0;
        const to = filter.to_block orelse head_block_number;
        if (from > to) {
            return error.InvalidFilter;
        }
        if (to > head_block_number) {
            return error.InvalidFilter;
        }

        var results = std.ArrayListUnmanaged(IndexedLog){};
        errdefer results.deinit(allocator);

        // O(1) lookup by blockHash when specified
        if (filter.block_hash) |bh| {
            if (self.block_hash_range.get(bh)) |range| {
                if (range.start < range.end and bloomMayMatchFilter(range.bloom, filter)) {
                    for (self.logs.items[range.start..range.end]) |entry| {
                        if (matchesFilter(entry, filter)) {
                            try results.append(allocator, entry);
                        }
                    }
                }
            }
            return try results.toOwnedSlice(allocator);
        }

        // Binary search populated blocks in [from, to] so sparse ranges are O(log B + populated)
        const start_idx = lowerBound(self.block_numbers.items, from);
        for (self.block_numbers.items[start_idx..]) |block_num| {
            if (block_num > to) break;
            if (self.block_range.get(block_num)) |range| {
                if (range.start == range.end) continue;
                if (!bloomMayMatchFilter(range.bloom, filter)) continue;
                for (self.logs.items[range.start..range.end]) |entry| {
                    if (matchesFilter(entry, filter)) {
                        try results.append(allocator, entry);
                    }
                }
            }
        }

        return try results.toOwnedSlice(allocator);
    }
};

fn lowerBound(sorted: []const u64, target: u64) usize {
    var lo: usize = 0;
    var hi: usize = sorted.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (sorted[mid] < target) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

inline fn bloomMask(bytes: []const u8) [4]u64 {
    const h = std.hash.Wyhash.hash(0, bytes);
    const b0: u8 = @truncate(h);
    const b1: u8 = @truncate(h >> 8);
    const b2: u8 = @truncate(h >> 16);
    var mask = [_]u64{ 0, 0, 0, 0 };
    mask[b0 >> 6] |= @as(u64, 1) << @as(u6, @truncate(b0));
    mask[b1 >> 6] |= @as(u64, 1) << @as(u6, @truncate(b1));
    mask[b2 >> 6] |= @as(u64, 1) << @as(u6, @truncate(b2));
    return mask;
}

inline fn bloomAdd(bloom: *[4]u64, bytes: []const u8) void {
    const mask = bloomMask(bytes);
    bloom[0] |= mask[0];
    bloom[1] |= mask[1];
    bloom[2] |= mask[2];
    bloom[3] |= mask[3];
}

inline fn bloomContains(bloom: [4]u64, bytes: []const u8) bool {
    const mask = bloomMask(bytes);
    return (bloom[0] & mask[0]) == mask[0] and
        (bloom[1] & mask[1]) == mask[1] and
        (bloom[2] & mask[2]) == mask[2] and
        (bloom[3] & mask[3]) == mask[3];
}

fn bloomMayMatchFilter(bloom: [4]u64, filter: LogFilter) bool {
    // An empty address list is no address constraint (matches Geth).
    if (filter.addresses) |addrs| if (addrs.len != 0) {
        var any = false;
        for (addrs) |addr| {
            if (bloomContains(bloom, &addr.bytes)) {
                any = true;
                break;
            }
        }
        if (!any) return false;
    };
    if (filter.topics) |topics| {
        for (topics) |maybe_topic_set| {
            if (maybe_topic_set) |topic_set| {
                if (topic_set.len == 0) continue;
                var any = false;
                for (topic_set) |topic| {
                    if (bloomContains(bloom, &topic)) {
                        any = true;
                        break;
                    }
                }
                if (!any) return false;
            }
        }
    }
    return true;
}

fn matchesFilter(entry: IndexedLog, filter: LogFilter) bool {
    // Address filter. An empty list is no address constraint (matches Geth).
    if (filter.addresses) |addrs| if (addrs.len != 0) {
        var found = false;
        for (addrs) |addr| {
            if (std.mem.eql(u8, &entry.log.address.bytes, &addr.bytes)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    };

    // Topic filter
    if (filter.topics) |topics| {
        if (topics.len > entry.log.topics.len) return false;
        for (topics, 0..) |maybe_topic_set, i| {
            if (maybe_topic_set) |topic_set| {
                if (topic_set.len == 0) continue;
                var topic_match = false;
                for (topic_set) |required_topic| {
                    if (std.mem.eql(u8, &entry.log.topics[i], &required_topic)) {
                        topic_match = true;
                        break;
                    }
                }
                if (!topic_match) return false;
            }
        }
    }

    return true;
}

fn cloneEventLog(
    allocator: std.mem.Allocator,
    log: primitives.EventLog.EventLog,
) !primitives.EventLog.EventLog {
    var cloned = log;
    cloned.topics = try allocator.dupe(primitives.Hash.Hash, log.topics);
    errdefer allocator.free(cloned.topics);
    cloned.data = try allocator.dupe(u8, log.data);
    return cloned;
}
