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

/// An indexed log entry with block_hash stored alongside (EventLog lacks block_hash).
pub const IndexedLog = struct {
    log: primitives.EventLog.EventLog,
    block_hash: [32]u8,
};

pub const LogIndex = struct {
    logs: std.ArrayListUnmanaged(IndexedLog),
    block_range: std.AutoHashMapUnmanaged(u64, struct { start: usize, end: usize }),

    pub fn init() LogIndex {
        return .{
            .logs = .{},
            .block_range = .{},
        };
    }

    pub fn deinit(self: *LogIndex, allocator: std.mem.Allocator) void {
        for (self.logs.items) |entry| {
            deinitOwnedLog(allocator, entry.log);
        }
        self.logs.deinit(allocator);
        self.block_range.deinit(allocator);
    }

    /// Append all logs from a mined block's receipts. Must be called in ascending block order.
    pub fn appendBlockLogs(
        self: *LogIndex,
        allocator: std.mem.Allocator,
        block_number: u64,
        block_hash: [32]u8,
        receipts: []const primitives.Receipt.Receipt,
    ) !void {
        var staged = std.ArrayListUnmanaged(IndexedLog){};
        errdefer {
            for (staged.items) |entry| {
                deinitOwnedLog(allocator, entry.log);
            }
            staged.deinit(allocator);
        }

        for (receipts) |receipt| {
            for (receipt.logs) |log| {
                const cloned = try primitives.EventLog.clone(allocator, log);
                errdefer deinitOwnedLog(allocator, cloned);
                try staged.append(allocator, .{
                    .log = cloned,
                    .block_hash = block_hash,
                });
            }
        }

        try self.logs.ensureUnusedCapacity(allocator, staged.items.len);
        try self.block_range.ensureUnusedCapacity(allocator, 1);

        const start = self.logs.items.len;
        for (staged.items) |entry| {
            self.logs.appendAssumeCapacity(entry);
        }
        const end = self.logs.items.len;
        self.block_range.putAssumeCapacity(block_number, .{ .start = start, .end = end });

        staged.deinit(allocator);
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

        // If blockHash filter, find that block's number from our range map
        if (filter.block_hash) |bh| {
            for (self.logs.items) |entry| {
                if (!std.mem.eql(u8, &entry.block_hash, &bh)) continue;
                if (matchesFilter(entry, filter)) {
                    try results.append(allocator, entry);
                }
            }
            return try results.toOwnedSlice(allocator);
        }

        // Range scan
        var block_num = from;
        while (block_num <= to) : (block_num += 1) {
            if (self.block_range.get(block_num)) |range| {
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

fn matchesFilter(entry: IndexedLog, filter: LogFilter) bool {
    // Address filter
    if (filter.addresses) |addrs| {
        var found = false;
        for (addrs) |addr| {
            if (std.mem.eql(u8, &entry.log.address.bytes, &addr.bytes)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }

    // Topic filter
    if (filter.topics) |topics| {
        for (topics, 0..) |maybe_topic_set, i| {
            if (maybe_topic_set) |topic_set| {
                if (i >= entry.log.topics.len) return false;
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

fn deinitOwnedLog(allocator: std.mem.Allocator, log: primitives.EventLog.EventLog) void {
    allocator.free(log.topics);
    allocator.free(log.data);
}
