const std = @import("std");
const primitives = @import("primitives");
const state_manager = @import("state-manager");
const blockchain_mod = @import("blockchain");
const database = @import("database/root.zig");

pub const CHAIN_ID: u64 = 31337;
pub const MAINNET_CHAIN_ID: u64 = 1;
pub const DEVNET_CHAIN_ID: u64 = CHAIN_ID;
pub const DEV_BALANCE: u256 = 10_000 * 1_000_000_000_000_000_000;
pub const DEFAULT_GAS_LIMIT: u64 = 30_000_000;
pub const DEFAULT_BASE_FEE: u256 = 1_000_000_000;
pub const NUM_ACCOUNTS: usize = 10;
pub const MNEMONIC = "test test test test test test test test test test test junk";
pub const DERIVATION_PATH = "m/44'/60'/0'/0/";
pub const DEFAULT_MAINNET_ALLOC_JSON_PATH = "../guillotine-mini/execution-specs/src/ethereum/assets/mainnet.json";

pub const MAINNET_STATE_ROOT: primitives.Hash.Hash = .{
    0xd7, 0xf8, 0x97, 0x4f, 0xb5, 0xac, 0x78, 0xd9,
    0xac, 0x09, 0x9b, 0x9a, 0xd5, 0x01, 0x8b, 0xed,
    0xc2, 0xce, 0x0a, 0x72, 0xda, 0xd1, 0x82, 0x7a,
    0x17, 0x09, 0xda, 0x30, 0x58, 0x0f, 0x05, 0x44,
};

pub const MAINNET_EXTRA_DATA: [32]u8 = .{
    0x11, 0xbb, 0xe8, 0xdb, 0x4e, 0x34, 0x7b, 0x4e,
    0x8c, 0x93, 0x7c, 0x1c, 0x83, 0x70, 0xe4, 0xb5,
    0xed, 0x33, 0xad, 0xb3, 0xdb, 0x69, 0xcb, 0xdb,
    0x7a, 0x38, 0xe1, 0xe5, 0x0b, 0x1b, 0x82, 0xfa,
};

pub const MAINNET_NONCE: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0x42 };

pub const MAINNET_GENESIS_HASH: primitives.Hash.Hash = .{
    0xd4, 0xe5, 0x67, 0x40, 0xf8, 0x76, 0xae, 0xf8,
    0xc0, 0x10, 0xb8, 0x6a, 0x40, 0xd5, 0xf5, 0x67,
    0x45, 0xa1, 0x18, 0xd0, 0x90, 0x6a, 0x34, 0xe6,
    0x9a, 0xec, 0x8c, 0x0d, 0xb1, 0xcb, 0x8f, 0xa3,
};

pub const GenesisProfile = enum {
    mainnet,
    devnet,
};

pub const DevAccount = struct {
    address: primitives.Address.Address,
    private_key: [32]u8,
};

pub const DEV_ACCOUNTS: [10]DevAccount = .{
    // Account 0: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
    .{
        .address = .{ .bytes = .{ 0xf3, 0x9f, 0xd6, 0xe5, 0x1a, 0xad, 0x88, 0xf6, 0xf4, 0xce, 0x6a, 0xb8, 0x82, 0x72, 0x79, 0xcf, 0xff, 0xb9, 0x22, 0x66 } },
        .private_key = .{ 0xac, 0x09, 0x74, 0xbe, 0xc3, 0x9a, 0x17, 0xe3, 0x6b, 0xa4, 0xa6, 0xb4, 0xd2, 0x38, 0xff, 0x94, 0x4b, 0xac, 0xb4, 0x78, 0xcb, 0xed, 0x5e, 0xfc, 0xae, 0x78, 0x4d, 0x7b, 0xf4, 0xf2, 0xff, 0x80 },
    },
    // Account 1: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8
    .{
        .address = .{ .bytes = .{ 0x70, 0x99, 0x79, 0x70, 0xc5, 0x18, 0x12, 0xdc, 0x3a, 0x01, 0x0c, 0x7d, 0x01, 0xb5, 0x0e, 0x0d, 0x17, 0xdc, 0x79, 0xc8 } },
        .private_key = .{ 0x59, 0xc6, 0x99, 0x5e, 0x99, 0x8f, 0x97, 0xa5, 0xa0, 0x04, 0x49, 0x66, 0xf0, 0x94, 0x53, 0x89, 0xdc, 0x9e, 0x86, 0xda, 0xe8, 0x8c, 0x7a, 0x84, 0x12, 0xf4, 0x60, 0x3b, 0x6b, 0x78, 0x69, 0x0d },
    },
    // Account 2: 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
    .{
        .address = .{ .bytes = .{ 0x3c, 0x44, 0xcd, 0xdd, 0xb6, 0xa9, 0x00, 0xfa, 0x2b, 0x58, 0x5d, 0xd2, 0x99, 0xe0, 0x3d, 0x12, 0xfa, 0x42, 0x93, 0xbc } },
        .private_key = .{ 0x5d, 0xe4, 0x11, 0x1a, 0xfa, 0x1a, 0x4b, 0x94, 0x90, 0x8f, 0x83, 0x10, 0x3e, 0xb1, 0xf9, 0x3b, 0x9c, 0xea, 0xba, 0xfe, 0x3c, 0x62, 0x6d, 0xfe, 0xdb, 0xb7, 0x0d, 0x5b, 0xdb, 0x28, 0x97, 0x45 },
    },
    // Account 3: 0x90F79bf6EB2c4f870365E785982E1f101E93b906
    .{
        .address = .{ .bytes = .{ 0x90, 0xf7, 0x9b, 0xf6, 0xeb, 0x2c, 0x4f, 0x87, 0x03, 0x65, 0xe7, 0x85, 0x98, 0x2e, 0x1f, 0x10, 0x1e, 0x93, 0xb9, 0x06 } },
        .private_key = .{ 0x7c, 0x85, 0x2e, 0x7d, 0x04, 0x4e, 0x13, 0x6d, 0xeb, 0x9c, 0xf4, 0xa5, 0x44, 0x82, 0xf0, 0xad, 0x4a, 0xc5, 0x4f, 0xd1, 0x93, 0xba, 0xf3, 0xb8, 0x3b, 0xed, 0x42, 0x01, 0x3d, 0x89, 0xf9, 0x41 },
    },
    // Account 4: 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65
    .{
        .address = .{ .bytes = .{ 0x15, 0xd3, 0x4a, 0xaf, 0x54, 0x26, 0x7d, 0xb7, 0xd7, 0xc3, 0x67, 0x83, 0x9a, 0xaf, 0x71, 0xa0, 0x0a, 0x2c, 0x6a, 0x65 } },
        .private_key = .{ 0x47, 0xe1, 0x79, 0xec, 0x19, 0x7b, 0x33, 0x83, 0x79, 0xfa, 0xee, 0x53, 0x67, 0xee, 0x54, 0xe4, 0x7f, 0xf3, 0xf7, 0x05, 0x36, 0xc5, 0x51, 0xcd, 0x28, 0x7e, 0x72, 0xba, 0x1c, 0x3e, 0x03, 0x48 },
    },
    // Account 5: 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc
    .{
        .address = .{ .bytes = .{ 0x99, 0x65, 0x50, 0x7d, 0x1a, 0x55, 0xbc, 0xc2, 0x69, 0x5c, 0x58, 0xba, 0x16, 0xfb, 0x37, 0xd8, 0x19, 0xb0, 0xa4, 0xdc } },
        .private_key = .{ 0x8b, 0x3a, 0x35, 0x04, 0x05, 0x69, 0xa3, 0x26, 0x7e, 0xe4, 0xee, 0xe8, 0xe3, 0xea, 0xbe, 0xe0, 0x10, 0x80, 0x6f, 0xaf, 0xf3, 0xef, 0x28, 0x81, 0x5f, 0x97, 0x89, 0x4a, 0x36, 0xe2, 0x80, 0x97 },
    },
    // Account 6: 0x976EA74026E726554dB657fA54763abd0C3a0aa9
    .{
        .address = .{ .bytes = .{ 0x97, 0x6e, 0xa7, 0x40, 0x26, 0xe7, 0x26, 0x55, 0x4d, 0xb6, 0x57, 0xfa, 0x54, 0x76, 0x3a, 0xbd, 0x0c, 0x3a, 0x0a, 0xa9 } },
        .private_key = .{ 0x92, 0xdb, 0x14, 0xe4, 0x03, 0xb8, 0x3d, 0xfe, 0x3d, 0xf7, 0xe1, 0x4b, 0x81, 0xd7, 0x85, 0xab, 0x65, 0xd4, 0x71, 0xc4, 0x3f, 0xb6, 0x3c, 0xc9, 0x39, 0x90, 0x71, 0xb3, 0xc5, 0x26, 0xbb, 0x0c },
    },
    // Account 7: 0x14dC79964da2C08dfa0D27a59B592d04F7EFdc76
    .{
        .address = .{ .bytes = .{ 0x14, 0xdc, 0x79, 0x96, 0x4d, 0xa2, 0xc0, 0x8d, 0xfa, 0x0d, 0x27, 0xa5, 0x9b, 0x59, 0x2d, 0x04, 0xf7, 0xef, 0xdc, 0x76 } },
        .private_key = .{ 0x4b, 0xbb, 0xf9, 0xd1, 0x10, 0x0a, 0x0d, 0x01, 0x04, 0xce, 0x41, 0x3d, 0x72, 0x5a, 0xf6, 0x48, 0xb0, 0xde, 0xfe, 0x39, 0x0e, 0xba, 0x82, 0x8f, 0xdd, 0xc2, 0xe1, 0x04, 0x6e, 0x57, 0xa1, 0x93 },
    },
    // Account 8: 0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f
    .{
        .address = .{ .bytes = .{ 0x23, 0x61, 0x8e, 0x81, 0xe3, 0xf5, 0xcd, 0xf7, 0xf5, 0x4c, 0x3d, 0x65, 0xf7, 0xfb, 0xc0, 0xab, 0xf5, 0xb2, 0x1e, 0x8f } },
        .private_key = .{ 0xdb, 0xda, 0x1b, 0xed, 0xf5, 0x7b, 0x01, 0xf3, 0x39, 0x73, 0xba, 0xcc, 0xb4, 0x13, 0x22, 0x18, 0x73, 0x80, 0x27, 0x45, 0xac, 0x5a, 0x45, 0xe3, 0x43, 0x91, 0xbb, 0xda, 0xc9, 0x03, 0xcc, 0x09 },
    },
    // Account 9: 0xa0Ee7A142d267C1f36714E4a8F75612F20a79720
    .{
        .address = .{ .bytes = .{ 0xa0, 0xee, 0x7a, 0x14, 0x2d, 0x26, 0x7c, 0x1f, 0x36, 0x71, 0x4e, 0x4a, 0x8f, 0x75, 0x61, 0x2f, 0x20, 0xa7, 0x97, 0x20 } },
        .private_key = .{ 0x2a, 0x87, 0x10, 0x12, 0x05, 0xef, 0x87, 0x1f, 0x91, 0xe5, 0xf2, 0x16, 0x9e, 0x91, 0x23, 0xa9, 0x41, 0x57, 0x04, 0x4b, 0x26, 0xa3, 0xa7, 0x5e, 0xbd, 0xae, 0xde, 0xab, 0x79, 0x92, 0x8f, 0xd4 },
    },
};

pub const GenesisResult = struct {
    chain_id: u64,
    profile: GenesisProfile,
    genesis_hash: primitives.Hash.Hash,
    state_root: primitives.Hash.Hash,
    coinbase: primitives.Address.Address,
    managed_accounts: []const DevAccount,
};

pub const PremineAccount = struct {
    address: primitives.Address.Address,
    balance: u256,
    nonce: u64 = 0,
};

const NO_MANAGED_ACCOUNTS: [0]DevAccount = .{};

const GenesisTrieEntry = struct {
    nibbles: [64]u8,
    value: []const u8,
};

const GenesisTrieNode = union(enum) {
    leaf: struct {
        path: []const u8,
        value: []const u8,
    },
    extension: struct {
        path: []const u8,
        child: *GenesisTrieNode,
    },
    branch: struct {
        children: [16]?*GenesisTrieNode,
        value: ?[]const u8,
    },
};

pub fn profileForChainId(chain_id: u64) !GenesisProfile {
    return switch (chain_id) {
        MAINNET_CHAIN_ID => .mainnet,
        DEVNET_CHAIN_ID => .devnet,
        else => error.UnsupportedGenesisChainId,
    };
}

pub fn createGenesisBlock(allocator: std.mem.Allocator, chain_id: u64) !primitives.Block.Block {
    const profile = try profileForChainId(chain_id);
    const state_root = switch (profile) {
        .mainnet => MAINNET_STATE_ROOT,
        .devnet => try computeDevnetStateRoot(allocator),
    };
    return try createGenesisBlockWithProfile(allocator, profile, chain_id, state_root);
}

pub fn createGenesisBlockWithProfile(
    allocator: std.mem.Allocator,
    profile: GenesisProfile,
    chain_id: u64,
    state_root: primitives.Hash.Hash,
) !primitives.Block.Block {
    try validateProfileChainId(profile, chain_id);

    if (profile == .mainnet and !primitives.Hash.equals(&state_root, &MAINNET_STATE_ROOT)) {
        return error.GenesisStateRootMismatch;
    }

    const header = switch (profile) {
        .mainnet => primitives.BlockHeader.BlockHeader{
            .parent_hash = primitives.Hash.ZERO,
            .ommers_hash = primitives.BlockHeader.EMPTY_OMMERS_HASH,
            .beneficiary = primitives.Address.ZERO_ADDRESS,
            .state_root = state_root,
            .transactions_root = primitives.BlockHeader.EMPTY_TRANSACTIONS_ROOT,
            .receipts_root = primitives.BlockHeader.EMPTY_RECEIPTS_ROOT,
            .logs_bloom = [_]u8{0} ** primitives.BlockHeader.BLOOM_SIZE,
            .difficulty = 0x400000000,
            .number = 0,
            .gas_limit = 0x1388,
            .gas_used = 0,
            .timestamp = 0,
            .extra_data = &MAINNET_EXTRA_DATA,
            .mix_hash = primitives.Hash.ZERO,
            .nonce = MAINNET_NONCE,
        },
        .devnet => primitives.BlockHeader.BlockHeader{
            .number = 0,
            .gas_limit = DEFAULT_GAS_LIMIT,
            .base_fee_per_gas = DEFAULT_BASE_FEE,
            .timestamp = @intCast(std.time.timestamp()),
            .beneficiary = DEV_ACCOUNTS[0].address,
            .state_root = state_root,
            .difficulty = 0,
            .ommers_hash = primitives.BlockHeader.EMPTY_OMMERS_HASH,
            .transactions_root = primitives.BlockHeader.EMPTY_TRANSACTIONS_ROOT,
            .receipts_root = primitives.BlockHeader.EMPTY_RECEIPTS_ROOT,
        },
    };
    const body = primitives.BlockBody.init();
    return primitives.Block.from(&header, &body, allocator);
}

pub fn initGenesisState(
    allocator: std.mem.Allocator,
    db: *database.Database,
    profile: GenesisProfile,
    mainnet_alloc_path: ?[]const u8,
) !primitives.Hash.Hash {
    return switch (profile) {
        .mainnet => blk: {
            const allocation = try loadMainnetAllocation(allocator, mainnet_alloc_path orelse DEFAULT_MAINNET_ALLOC_JSON_PATH);
            defer allocator.free(allocation);

            const state_root = try applyPremineAllocation(allocator, db, allocation);
            if (!primitives.Hash.equals(&state_root, &MAINNET_STATE_ROOT)) {
                return error.GenesisStateRootMismatch;
            }
            break :blk state_root;
        },
        .devnet => try applyDevnetPremine(allocator, db),
    };
}

pub fn initGenesis(
    allocator: std.mem.Allocator,
    db: *database.Database,
    chain: *blockchain_mod.Blockchain,
    chain_id: u64,
    mainnet_alloc_path: ?[]const u8,
) !GenesisResult {
    const profile = try profileForChainId(chain_id);
    return try initGenesisWithProfile(allocator, db, chain, profile, chain_id, mainnet_alloc_path);
}

pub fn initGenesisWithProfile(
    allocator: std.mem.Allocator,
    db: *database.Database,
    chain: *blockchain_mod.Blockchain,
    profile: GenesisProfile,
    chain_id: u64,
    mainnet_alloc_path: ?[]const u8,
) !GenesisResult {
    try validateProfileChainId(profile, chain_id);

    const state_root = try initGenesisState(allocator, db, profile, mainnet_alloc_path);
    const genesis_block = try createGenesisBlockWithProfile(allocator, profile, chain_id, state_root);

    try chain.putBlock(genesis_block);
    try chain.setCanonicalHead(genesis_block.hash);

    try db.block_hashes.put(allocator, 0, genesis_block.hash);

    return .{
        .chain_id = chain_id,
        .profile = profile,
        .genesis_hash = genesis_block.hash,
        .state_root = state_root,
        .coinbase = if (profile == .devnet) DEV_ACCOUNTS[0].address else primitives.Address.ZERO_ADDRESS,
        .managed_accounts = if (profile == .devnet) &DEV_ACCOUNTS else &NO_MANAGED_ACCOUNTS,
    };
}

pub fn applyPremineAllocation(
    allocator: std.mem.Allocator,
    db: *database.Database,
    allocation: []const PremineAccount,
) !primitives.Hash.Hash {
    for (allocation) |account| {
        try db.state.initAccount(account.address, account.balance);
        if (account.nonce != 0) {
            try db.state.setNonce(account.address, account.nonce);
        }
        try db.syncAccountToTrie(allocator, account.address);
    }

    return try computeStateRootFromPremine(allocator, allocation);
}

pub fn computeStateRootFromPremine(
    allocator: std.mem.Allocator,
    allocation: []const PremineAccount,
) !primitives.Hash.Hash {
    if (allocation.len == 0) {
        return primitives.State.EMPTY_TRIE_ROOT;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const entries = try arena_allocator.alloc(GenesisTrieEntry, allocation.len);
    for (allocation, 0..) |account, index| {
        var hashed_key: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(&account.address.bytes, &hashed_key, .{});
        entries[index].nibbles = keyToNibbles(hashed_key);

        const account_state = primitives.AccountState.AccountState.from(.{
            .nonce = account.nonce,
            .balance = account.balance,
        });
        entries[index].value = try account_state.rlpEncode(arena_allocator);
    }

    std.mem.sort(GenesisTrieEntry, entries, {}, struct {
        fn lessThan(_: void, a: GenesisTrieEntry, b: GenesisTrieEntry) bool {
            return std.mem.order(u8, &a.nibbles, &b.nibbles) == .lt;
        }
    }.lessThan);

    const root = try buildGenesisTrie(arena_allocator, entries, 0);
    const encoded = try encodeGenesisTrieNode(arena_allocator, root);

    var state_root: primitives.Hash.Hash = undefined;
    std.crypto.hash.sha3.Keccak256.hash(encoded, &state_root, .{});
    return state_root;
}

pub fn loadMainnetAllocation(allocator: std.mem.Allocator, path: []const u8) ![]PremineAccount {
    const json_bytes = try std.fs.cwd().readFileAlloc(allocator, path, 8 * 1024 * 1024);
    defer allocator.free(json_bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const root_object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidGenesisAlloc,
    };
    const alloc_value = root_object.get("alloc") orelse return error.InvalidGenesisAlloc;
    const alloc_object = switch (alloc_value) {
        .object => |object| object,
        else => return error.InvalidGenesisAlloc,
    };

    var allocation = std.ArrayList(PremineAccount){};
    errdefer allocation.deinit(allocator);

    var iterator = alloc_object.iterator();
    while (iterator.next()) |entry| {
        const account_object = switch (entry.value_ptr.*) {
            .object => |object| object,
            else => return error.InvalidGenesisAlloc,
        };
        const balance_value = account_object.get("balance") orelse return error.InvalidGenesisAlloc;
        const balance_text = switch (balance_value) {
            .string => |text| text,
            else => return error.InvalidGenesisAlloc,
        };

        try allocation.append(allocator, .{
            .address = try parseHexAddress(entry.key_ptr.*),
            .balance = try parseHexU256(balance_text),
        });
    }

    return try allocation.toOwnedSlice(allocator);
}

fn validateProfileChainId(profile: GenesisProfile, chain_id: u64) !void {
    const expected = try profileForChainId(chain_id);
    if (profile != expected) {
        return error.ProfileChainIdMismatch;
    }
}

fn computeDevnetStateRoot(allocator: std.mem.Allocator) !primitives.Hash.Hash {
    var allocation: [DEV_ACCOUNTS.len]PremineAccount = undefined;
    fillDevnetPremine(&allocation);
    return try computeStateRootFromPremine(allocator, &allocation);
}

fn applyDevnetPremine(allocator: std.mem.Allocator, db: *database.Database) !primitives.Hash.Hash {
    var allocation: [DEV_ACCOUNTS.len]PremineAccount = undefined;
    fillDevnetPremine(&allocation);
    return try applyPremineAllocation(allocator, db, &allocation);
}

fn fillDevnetPremine(allocation: []PremineAccount) void {
    for (&DEV_ACCOUNTS, 0..) |*account, index| {
        allocation[index] = .{
            .address = account.address,
            .balance = DEV_BALANCE,
        };
    }
}

fn buildGenesisTrie(
    allocator: std.mem.Allocator,
    entries: []const GenesisTrieEntry,
    depth: usize,
) !*GenesisTrieNode {
    const node = try allocator.create(GenesisTrieNode);

    if (entries.len == 1) {
        node.* = .{ .leaf = .{
            .path = entries[0].nibbles[depth..],
            .value = entries[0].value,
        } };
        return node;
    }

    const common = commonPrefixLen(entries, depth);
    if (common > 0) {
        node.* = .{ .extension = .{
            .path = entries[0].nibbles[depth .. depth + common],
            .child = try buildGenesisTrie(allocator, entries, depth + common),
        } };
        return node;
    }

    var children = [_]?*GenesisTrieNode{null} ** 16;
    var value: ?[]const u8 = null;
    var start: usize = 0;
    while (start < entries.len) {
        if (depth == 64) {
            value = entries[start].value;
            start += 1;
            continue;
        }

        const nibble = entries[start].nibbles[depth];
        var end = start + 1;
        while (end < entries.len and entries[end].nibbles[depth] == nibble) : (end += 1) {}

        children[nibble] = try buildGenesisTrie(allocator, entries[start..end], depth + 1);
        start = end;
    }

    node.* = .{ .branch = .{
        .children = children,
        .value = value,
    } };
    return node;
}

fn commonPrefixLen(entries: []const GenesisTrieEntry, depth: usize) usize {
    var len: usize = 0;
    while (depth + len < 64) : (len += 1) {
        const nibble = entries[0].nibbles[depth + len];
        for (entries[1..]) |entry| {
            if (entry.nibbles[depth + len] != nibble) {
                return len;
            }
        }
    }
    return len;
}

fn encodeGenesisTrieNode(allocator: std.mem.Allocator, node: *const GenesisTrieNode) ![]u8 {
    return switch (node.*) {
        .leaf => |leaf| blk: {
            var fields = std.ArrayList([]const u8){};
            try fields.append(allocator, try primitives.Rlp.encodeBytes(allocator, try encodeHexPrefix(allocator, leaf.path, true)));
            try fields.append(allocator, try primitives.Rlp.encodeBytes(allocator, leaf.value));
            break :blk try encodeRlpListFromEncoded(allocator, fields.items);
        },
        .extension => |extension| blk: {
            var fields = std.ArrayList([]const u8){};
            try fields.append(allocator, try primitives.Rlp.encodeBytes(allocator, try encodeHexPrefix(allocator, extension.path, false)));
            try fields.append(allocator, try encodeChildReference(allocator, extension.child));
            break :blk try encodeRlpListFromEncoded(allocator, fields.items);
        },
        .branch => |branch| blk: {
            var fields = std.ArrayList([]const u8){};
            for (branch.children) |child| {
                if (child) |present| {
                    try fields.append(allocator, try encodeChildReference(allocator, present));
                } else {
                    try fields.append(allocator, try primitives.Rlp.encodeBytes(allocator, &.{}));
                }
            }
            if (branch.value) |value| {
                try fields.append(allocator, try primitives.Rlp.encodeBytes(allocator, value));
            } else {
                try fields.append(allocator, try primitives.Rlp.encodeBytes(allocator, &.{}));
            }
            break :blk try encodeRlpListFromEncoded(allocator, fields.items);
        },
    };
}

fn encodeChildReference(allocator: std.mem.Allocator, node: *const GenesisTrieNode) ![]const u8 {
    const encoded = try encodeGenesisTrieNode(allocator, node);
    if (encoded.len < 32) {
        return encoded;
    }

    var hash: primitives.Hash.Hash = undefined;
    std.crypto.hash.sha3.Keccak256.hash(encoded, &hash, .{});
    return try primitives.Rlp.encodeBytes(allocator, &hash);
}

fn encodeHexPrefix(allocator: std.mem.Allocator, path: []const u8, is_leaf: bool) ![]u8 {
    const odd = path.len % 2 == 1;
    const flags: u8 = (if (is_leaf) @as(u8, 2) else 0) + (if (odd) @as(u8, 1) else 0);
    const out_len = if (odd) 1 + ((path.len - 1) / 2) else 1 + (path.len / 2);
    const out = try allocator.alloc(u8, out_len);

    var path_index: usize = 0;
    if (odd) {
        out[0] = (flags << 4) | path[0];
        path_index = 1;
    } else {
        out[0] = flags << 4;
    }

    var out_index: usize = 1;
    while (path_index < path.len) : ({
        path_index += 2;
        out_index += 1;
    }) {
        out[out_index] = (path[path_index] << 4) | path[path_index + 1];
    }

    return out;
}

fn encodeRlpListFromEncoded(allocator: std.mem.Allocator, fields: []const []const u8) ![]u8 {
    var total_len: usize = 0;
    for (fields) |field| {
        total_len += field.len;
    }

    var result = std.ArrayList(u8){};
    errdefer result.deinit(allocator);

    if (total_len < 56) {
        try result.append(allocator, 0xc0 + @as(u8, @intCast(total_len)));
    } else {
        const len_bytes = try primitives.Rlp.encodeLength(allocator, total_len);
        try result.append(allocator, 0xf7 + @as(u8, @intCast(len_bytes.len)));
        try result.appendSlice(allocator, len_bytes);
    }

    for (fields) |field| {
        try result.appendSlice(allocator, field);
    }

    return try result.toOwnedSlice(allocator);
}

fn keyToNibbles(key: [32]u8) [64]u8 {
    var nibbles: [64]u8 = undefined;
    for (key, 0..) |byte, index| {
        nibbles[index * 2] = byte >> 4;
        nibbles[index * 2 + 1] = byte & 0x0f;
    }
    return nibbles;
}

fn parseHexAddress(text: []const u8) !primitives.Address.Address {
    const hex = stripHexPrefix(text);
    if (hex.len != 40) {
        return error.InvalidHex;
    }
    var address: primitives.Address.Address = undefined;
    _ = std.fmt.hexToBytes(&address.bytes, hex) catch return error.InvalidHex;
    return address;
}

fn parseHexU256(text: []const u8) !u256 {
    const hex = stripHexPrefix(text);
    if (hex.len == 0) {
        return 0;
    }
    return std.fmt.parseInt(u256, hex, 16) catch error.InvalidHex;
}

fn stripHexPrefix(text: []const u8) []const u8 {
    if (text.len >= 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) {
        return text[2..];
    }
    return text;
}

pub fn devnetHeaderForTests(state_root: primitives.Hash.Hash) primitives.BlockHeader.BlockHeader {
    return .{
        .number = 0,
        .gas_limit = DEFAULT_GAS_LIMIT,
        .base_fee_per_gas = DEFAULT_BASE_FEE,
        .timestamp = @intCast(std.time.timestamp()),
        .beneficiary = DEV_ACCOUNTS[0].address,
        .state_root = state_root,
        .difficulty = 0,
        .ommers_hash = primitives.BlockHeader.EMPTY_OMMERS_HASH,
        .transactions_root = primitives.BlockHeader.EMPTY_TRANSACTIONS_ROOT,
        .receipts_root = primitives.BlockHeader.EMPTY_RECEIPTS_ROOT,
    };
}

pub fn printBanner(writer: anytype) !void {
    try writer.writeAll("\nzevm - Ethereum local node\n");
    try writer.print("Chain ID: {d}\n\n", .{CHAIN_ID});
    try writer.writeAll("Available Accounts\n==================\n");
    for (&DEV_ACCOUNTS, 0..) |*account, i| {
        const addr_hex = std.fmt.bytesToHex(account.address.bytes, .lower);
        try writer.print("({d}) 0x{s} (10000 ETH)\n", .{ i, addr_hex });
    }
    try writer.writeAll("\nPrivate Keys\n==================\n");
    for (&DEV_ACCOUNTS, 0..) |*account, i| {
        const key_hex = std.fmt.bytesToHex(account.private_key, .lower);
        try writer.print("({d}) 0x{s}\n", .{ i, key_hex });
    }
    try writer.print("\nWallet\n==================\nMnemonic: {s}\nDerivation path: {s}\n", .{ MNEMONIC, DERIVATION_PATH });
    try writer.print("\nBase Fee: {d} (1 gwei)\nGas Limit: {d}\n\n", .{ @as(u64, @intCast(DEFAULT_BASE_FEE)), DEFAULT_GAS_LIMIT });
}
