const std = @import("std");
const primitives = @import("primitives");
const guillotine_mini = @import("guillotine_mini");

/// Hardhat `console.sol` target: `0x000000000000000000636f6e736f6c652e6c6f67` (ASCII "console.log").
pub const ADDRESS = primitives.Address{ .bytes = .{
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x63,
    0x6f, 0x6e, 0x73, 0x6f, 0x6c, 0x65, 0x2e, 0x6c, 0x6f, 0x67,
} };

pub const DEFAULT_CAPACITY: usize = 4096;

/// Node-owned FIFO ring buffer of raw calldata sent to the Hardhat console address.
/// When full, the oldest entry is dropped.
pub const ConsoleLogBuffer = struct {
    allocator: std.mem.Allocator,
    capacity: usize = DEFAULT_CAPACITY,
    mutex: std.Thread.Mutex = .{},
    entries: std.ArrayList([]u8) = .{},

    pub const Drained = struct {
        allocator: std.mem.Allocator,
        entries: std.ArrayList([]u8),

        pub fn deinit(self: *Drained) void {
            for (self.entries.items) |entry| self.allocator.free(entry);
            self.entries.deinit(self.allocator);
        }
    };

    pub fn init(allocator: std.mem.Allocator) ConsoleLogBuffer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ConsoleLogBuffer) void {
        var drained = self.drain();
        drained.deinit();
    }

    /// Records one console call. Capture is best effort: an allocation failure
    /// drops the entry instead of failing the EVM call.
    pub fn record(self: *ConsoleLogBuffer, calldata: []const u8) void {
        if (self.capacity == 0) return;
        const copy = self.allocator.dupe(u8, calldata) catch return;

        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.entries.items.len >= self.capacity) {
            self.allocator.free(self.entries.orderedRemove(0));
        }
        self.entries.append(self.allocator, copy) catch self.allocator.free(copy);
    }

    pub fn len(self: *ConsoleLogBuffer) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.entries.items.len;
    }

    /// Removes and returns every captured entry in FIFO order. Caller calls `deinit`.
    pub fn drain(self: *ConsoleLogBuffer) Drained {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entries = self.entries;
        self.entries = .{};
        return .{ .allocator = self.allocator, .entries = entries };
    }

    /// EVM hook: a call to `ADDRESS` succeeds with empty output, uses no gas, and records calldata.
    pub fn precompileOverride(self: *ConsoleLogBuffer) guillotine_mini.PrecompileOverride {
        return .{
            .address = ADDRESS,
            .execute = executeCapture,
            .context = self,
        };
    }

    fn executeCapture(
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        input: []const u8,
        gas_limit: u64,
    ) anyerror!guillotine_mini.PrecompileOutput {
        _ = allocator;
        _ = gas_limit;
        const self: *ConsoleLogBuffer = @ptrCast(@alignCast(ctx.?));
        self.record(input);
        return .{ .output = &.{}, .gas_used = 0, .success = true };
    }
};

test "console address matches the Hardhat console.log address" {
    const expected = try primitives.Address.fromHex("0x000000000000000000636f6e736f6c652e6c6f67");
    try std.testing.expect(ADDRESS.equals(expected));
    try std.testing.expectEqualSlices(u8, "console.log", ADDRESS.bytes[9..]);
}

test "ConsoleLogBuffer drains entries in FIFO order and clears" {
    var buffer = ConsoleLogBuffer.init(std.testing.allocator);
    defer buffer.deinit();

    buffer.record(&.{ 0x01, 0x02 });
    buffer.record(&.{});
    buffer.record(&.{0x03});

    var drained = buffer.drain();
    defer drained.deinit();
    try std.testing.expectEqual(@as(usize, 3), drained.entries.items.len);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x02 }, drained.entries.items[0]);
    try std.testing.expectEqualSlices(u8, &.{}, drained.entries.items[1]);
    try std.testing.expectEqualSlices(u8, &.{0x03}, drained.entries.items[2]);
    try std.testing.expectEqual(@as(usize, 0), buffer.len());
}

test "ConsoleLogBuffer drops the oldest entry when full" {
    var buffer = ConsoleLogBuffer.init(std.testing.allocator);
    defer buffer.deinit();
    buffer.capacity = 2;

    buffer.record(&.{0x01});
    buffer.record(&.{0x02});
    buffer.record(&.{0x03});

    var drained = buffer.drain();
    defer drained.deinit();
    try std.testing.expectEqual(@as(usize, 2), drained.entries.items.len);
    try std.testing.expectEqualSlices(u8, &.{0x02}, drained.entries.items[0]);
    try std.testing.expectEqualSlices(u8, &.{0x03}, drained.entries.items[1]);
}

test "ConsoleLogBuffer precompile override succeeds with empty output and records calldata" {
    var buffer = ConsoleLogBuffer.init(std.testing.allocator);
    defer buffer.deinit();

    const override = buffer.precompileOverride();
    try std.testing.expect(override.address.equals(ADDRESS));
    const output = try override.execute(override.context, std.testing.allocator, &.{ 0xf8, 0x2c, 0x50, 0xf1 }, 100);
    try std.testing.expect(output.success);
    try std.testing.expectEqual(@as(usize, 0), output.output.len);
    try std.testing.expectEqual(@as(u64, 0), output.gas_used);
    try std.testing.expectEqual(@as(usize, 1), buffer.len());
}
