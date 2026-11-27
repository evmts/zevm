const std = @import("std");
const primitives = @import("primitives");

/// Contract bytecode storage keyed by code hash.
///
/// Maps keccak256(bytecode) → bytecode, allowing contract code to be
/// shared across accounts that reference the same code hash.
pub const Contracts = struct {
    code: std.AutoHashMapUnmanaged(primitives.Hash.Hash, []const u8) = .empty,

    pub fn init() Contracts {
        return .{};
    }

    pub fn deinit(self: *Contracts, allocator: std.mem.Allocator) void {
        var it = self.code.valueIterator();
        while (it.next()) |v| {
            allocator.free(v.*);
        }
        self.code.deinit(allocator);
    }

    /// Retrieve contract bytecode by its code hash.
    pub fn get(self: *const Contracts, code_hash: primitives.Hash.Hash) ?[]const u8 {
        return self.code.get(code_hash);
    }

    /// Store contract bytecode keyed by its code hash.
    pub fn put(
        self: *Contracts,
        allocator: std.mem.Allocator,
        code_hash: primitives.Hash.Hash,
        bytecode: []const u8,
    ) !void {
        // Allocate the replacement before touching the map. Freeing the old
        // slice first would leave a dangling entry (and a double free in
        // `deinit`) when the dupe fails.
        const owned = try allocator.dupe(u8, bytecode);
        errdefer allocator.free(owned);
        const result = try self.code.getOrPut(allocator, code_hash);
        if (result.found_existing) {
            allocator.free(result.value_ptr.*);
        }
        result.value_ptr.* = owned;
    }

    /// Remove contract bytecode by its code hash.
    pub fn remove(self: *Contracts, allocator: std.mem.Allocator, code_hash: primitives.Hash.Hash) void {
        if (self.code.fetchRemove(code_hash)) |entry| {
            allocator.free(entry.value);
        }
    }
};

test "Contracts put, overwrite without leaks, get, and remove" {
    const allocator = std.testing.allocator;
    var contracts = Contracts.init();
    defer contracts.deinit(allocator);

    var code_hash: primitives.Hash.Hash = [_]u8{0xab} ** 32;
    try std.testing.expectEqual(@as(?[]const u8, null), contracts.get(code_hash));

    try contracts.put(allocator, code_hash, &[_]u8{ 0x60, 0x00, 0x60, 0x00, 0xf3 });
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0x60, 0x00, 0x60, 0x00, 0xf3 },
        contracts.get(code_hash).?,
    );

    // Overwriting an existing code hash frees the previous owned copy cleanly.
    try contracts.put(allocator, code_hash, &[_]u8{ 0x60, 0x2a, 0x60, 0x00, 0x52 });
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0x60, 0x2a, 0x60, 0x00, 0x52 },
        contracts.get(code_hash).?,
    );

    contracts.remove(allocator, code_hash);
    try std.testing.expectEqual(@as(?[]const u8, null), contracts.get(code_hash));
    // Removing a missing key is a safe no-op.
    code_hash[0] = 0xcd;
    contracts.remove(allocator, code_hash);
}
