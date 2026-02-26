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
    pub fn put(self: *Contracts, allocator: std.mem.Allocator, code_hash: primitives.Hash.Hash, bytecode: []const u8) !void {
        const result = try self.code.getOrPut(allocator, code_hash);
        if (result.found_existing) {
            allocator.free(result.value_ptr.*);
        }
        result.value_ptr.* = try allocator.dupe(u8, bytecode);
    }

    /// Remove contract bytecode by its code hash.
    pub fn remove(self: *Contracts, allocator: std.mem.Allocator, code_hash: primitives.Hash.Hash) void {
        if (self.code.fetchRemove(code_hash)) |entry| {
            allocator.free(entry.value);
        }
    }
};
