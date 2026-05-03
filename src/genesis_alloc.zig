const std = @import("std");
const primitives = @import("primitives");
const state_manager = @import("state-manager");

pub const Error = error{
    InvalidGenesisAlloc,
};

pub const HeaderConfig = struct {
    parent_hash: primitives.Hash.Hash = primitives.Hash.ZERO,
    beneficiary: ?primitives.Address = null,
    difficulty: u256 = 0,
    gas_limit: ?u64 = null,
    timestamp: u64 = 0,
    extra_data: ?[]u8 = null,
    mix_hash: primitives.Hash.Hash = primitives.Hash.ZERO,
    nonce: [8]u8 = [_]u8{0} ** 8,
    base_fee_per_gas: ?u256 = null,
    withdrawals_root: ?primitives.Hash.Hash = null,
    blob_gas_used: ?u64 = null,
    excess_blob_gas: ?u64 = null,
    parent_beacon_block_root: ?primitives.Hash.Hash = null,

    pub fn deinit(self: *HeaderConfig, allocator: std.mem.Allocator) void {
        if (self.extra_data) |bytes| {
            allocator.free(bytes);
            self.extra_data = null;
        }
    }

    pub fn extraData(self: HeaderConfig) []const u8 {
        return self.extra_data orelse &.{};
    }
};

pub const LoadedGenesis = struct {
    account_count: usize,
    header: HeaderConfig,

    pub fn deinit(self: *LoadedGenesis, allocator: std.mem.Allocator) void {
        self.header.deinit(allocator);
    }
};

pub fn loadGenesisFile(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    path: []const u8,
) !LoadedGenesis {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024);
    defer allocator.free(bytes);

    return try loadGenesisJson(allocator, sm, bytes);
}

pub fn loadGenesisJson(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    bytes: []const u8,
) !LoadedGenesis {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
    }) catch |err| return mapJsonError(err);
    defer parsed.deinit();

    return try loadGenesisValue(allocator, sm, parsed.value);
}

pub fn loadGenesisValue(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    value: std.json.Value,
) !LoadedGenesis {
    const root = switch (value) {
        .object => |object| object,
        else => return error.InvalidGenesisAlloc,
    };

    var header = try parseHeaderConfig(allocator, root);
    errdefer header.deinit(allocator);

    return .{
        .account_count = try applyAllocObject(allocator, sm, root),
        .header = header,
    };
}

pub fn applyGenesisFile(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    path: []const u8,
) !usize {
    var loaded = try loadGenesisFile(allocator, sm, path);
    defer loaded.deinit(allocator);
    return loaded.account_count;
}

pub fn applyGenesisJson(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    bytes: []const u8,
) !usize {
    var loaded = try loadGenesisJson(allocator, sm, bytes);
    defer loaded.deinit(allocator);
    return loaded.account_count;
}

pub fn applyGenesisValue(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    value: std.json.Value,
) !usize {
    var loaded = try loadGenesisValue(allocator, sm, value);
    defer loaded.deinit(allocator);
    return loaded.account_count;
}

fn applyAllocObject(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    root: std.json.ObjectMap,
) !usize {
    const alloc_value = root.get("alloc") orelse return error.InvalidGenesisAlloc;
    const alloc = switch (alloc_value) {
        .object => |object| object,
        else => return error.InvalidGenesisAlloc,
    };

    var it = alloc.iterator();
    var account_count: usize = 0;
    while (it.next()) |entry| {
        if (std.mem.startsWith(u8, entry.key_ptr.*, "//")) continue;
        try applyGenesisAccount(allocator, sm, entry.key_ptr.*, entry.value_ptr.*);
        account_count += 1;
    }
    return account_count;
}

fn parseHeaderConfig(allocator: std.mem.Allocator, root: std.json.ObjectMap) !HeaderConfig {
    var header = HeaderConfig{};
    errdefer header.deinit(allocator);

    if (root.get("parentHash")) |value| {
        header.parent_hash = try parseHashValue(value);
    }
    if (root.get("coinbase")) |value| {
        header.beneficiary = try parseAddressValue(value);
    } else if (root.get("beneficiary")) |value| {
        header.beneficiary = try parseAddressValue(value);
    }
    if (root.get("difficulty")) |value| {
        header.difficulty = try parseQuantity(value);
    }
    if (root.get("gasLimit")) |value| {
        header.gas_limit = try parseU64Quantity(value);
    }
    if (root.get("timestamp")) |value| {
        header.timestamp = try parseU64Quantity(value);
    }
    if (root.get("extraData")) |value| {
        const text = try parseString(value);
        header.extra_data = try parseHexBytes(allocator, text);
    }
    if (root.get("mixHash")) |value| {
        header.mix_hash = try parseHashValue(value);
    } else if (root.get("mixhash")) |value| {
        header.mix_hash = try parseHashValue(value);
    }
    if (root.get("nonce")) |value| {
        const nonce = try parseU64Quantity(value);
        std.mem.writeInt(u64, &header.nonce, nonce, .big);
    }
    if (root.get("baseFeePerGas")) |value| {
        header.base_fee_per_gas = try parseOptionalQuantity(value);
    }
    if (root.get("withdrawalsRoot")) |value| {
        header.withdrawals_root = try parseOptionalHashValue(value);
    }
    if (root.get("blobGasUsed")) |value| {
        header.blob_gas_used = try parseOptionalU64Quantity(value);
    }
    if (root.get("excessBlobGas")) |value| {
        header.excess_blob_gas = try parseOptionalU64Quantity(value);
    }
    if (root.get("parentBeaconBlockRoot")) |value| {
        header.parent_beacon_block_root = try parseOptionalHashValue(value);
    }

    return header;
}

fn applyGenesisAccount(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    address_text: []const u8,
    value: std.json.Value,
) !void {
    const address = try parseAddress(address_text);
    const object = switch (value) {
        .object => |account| account,
        else => return error.InvalidGenesisAlloc,
    };

    try validateAccountFields(object);

    const balance = try parseBalance(object);
    const nonce = if (object.get("nonce")) |nonce_value|
        try parseU64Quantity(nonce_value)
    else
        0;

    try sm.initAccount(address, balance);
    if (nonce != 0) {
        try sm.setNonce(address, nonce);
    }

    if (object.get("code")) |code_value| {
        const code_text = switch (code_value) {
            .string => |text| text,
            else => return error.InvalidGenesisAlloc,
        };
        const code = try parseHexBytes(allocator, code_text);
        defer allocator.free(code);
        try sm.setCode(address, code);
    }

    if (object.get("storage")) |storage_value| {
        const storage = switch (storage_value) {
            .object => |storage| storage,
            else => return error.InvalidGenesisAlloc,
        };
        var storage_it = storage.iterator();
        while (storage_it.next()) |storage_entry| {
            const slot = try parseQuantityString(storage_entry.key_ptr.*);
            const storage_value_quantity = try parseQuantity(storage_entry.value_ptr.*);
            try sm.setStorage(address, slot, storage_value_quantity);
        }
    }
}

fn validateAccountFields(object: std.json.ObjectMap) Error!void {
    var it = object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "balance") or
            std.mem.eql(u8, key, "wei") or
            std.mem.eql(u8, key, "nonce") or
            std.mem.eql(u8, key, "code") or
            std.mem.eql(u8, key, "storage") or
            std.mem.eql(u8, key, "privateKey") or
            std.mem.eql(u8, key, "secretKey"))
        {
            continue;
        }
        return error.InvalidGenesisAlloc;
    }
}

fn parseBalance(object: std.json.ObjectMap) Error!u256 {
    const balance_value = object.get("balance");
    const wei_value = object.get("wei");
    if (balance_value != null and wei_value != null) return error.InvalidGenesisAlloc;
    if (balance_value) |value| return try parseQuantity(value);
    if (wei_value) |value| return try parseQuantity(value);
    return 0;
}

fn parseAddressValue(value: std.json.Value) Error!primitives.Address {
    return try parseAddress(try parseString(value));
}

fn parseAddress(text: []const u8) Error!primitives.Address {
    return primitives.Address.fromHex(text) catch error.InvalidGenesisAlloc;
}

fn parseHashValue(value: std.json.Value) Error!primitives.Hash.Hash {
    const text = try parseString(value);
    var hex = text;
    if (std.mem.startsWith(u8, hex, "0x") or std.mem.startsWith(u8, hex, "0X")) {
        hex = hex[2..];
    }
    if (hex.len != 64) return error.InvalidGenesisAlloc;
    var hash: primitives.Hash.Hash = undefined;
    _ = std.fmt.hexToBytes(&hash, hex) catch return error.InvalidGenesisAlloc;
    return hash;
}

fn parseOptionalHashValue(value: std.json.Value) Error!?primitives.Hash.Hash {
    if (value == .null) return null;
    return try parseHashValue(value);
}

fn parseString(value: std.json.Value) Error![]const u8 {
    return switch (value) {
        .string => |text| text,
        else => error.InvalidGenesisAlloc,
    };
}

fn parseQuantity(value: std.json.Value) Error!u256 {
    return switch (value) {
        .string => |text| try parseQuantityString(text),
        .integer => |number| if (number < 0) error.InvalidGenesisAlloc else @intCast(number),
        else => error.InvalidGenesisAlloc,
    };
}

fn parseOptionalQuantity(value: std.json.Value) Error!?u256 {
    if (value == .null) return null;
    return try parseQuantity(value);
}

fn parseU64Quantity(value: std.json.Value) Error!u64 {
    const quantity = try parseQuantity(value);
    return std.math.cast(u64, quantity) orelse error.InvalidGenesisAlloc;
}

fn parseOptionalU64Quantity(value: std.json.Value) Error!?u64 {
    if (value == .null) return null;
    return try parseU64Quantity(value);
}

fn parseQuantityString(text: []const u8) Error!u256 {
    if (std.mem.startsWith(u8, text, "0x") or std.mem.startsWith(u8, text, "0X")) {
        if (text.len == 2) return 0;
        return std.fmt.parseInt(u256, text[2..], 16) catch error.InvalidGenesisAlloc;
    }
    if (text.len == 0) return 0;
    return std.fmt.parseInt(u256, text, 10) catch error.InvalidGenesisAlloc;
}

fn parseHexBytes(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var hex = text;
    if (std.mem.startsWith(u8, hex, "0x") or std.mem.startsWith(u8, hex, "0X")) {
        hex = hex[2..];
    } else {
        return error.InvalidGenesisAlloc;
    }
    if (hex.len == 0) return try allocator.alloc(u8, 0);
    if (hex.len % 2 != 0) return error.InvalidGenesisAlloc;

    const out = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(out);
    _ = std.fmt.hexToBytes(out, hex) catch return error.InvalidGenesisAlloc;
    return out;
}

fn mapJsonError(err: anyerror) anyerror {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidGenesisAlloc,
    };
}
