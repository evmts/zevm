const std = @import("std");
const state_manager = @import("state-manager");
const primitives = @import("primitives");
const mining = @import("../mining.zig");

/// Hardhat/Anvil-style deterministic dev accounts.
/// These are the same 10 accounts used by Hardhat/Anvil (derived from mnemonic
/// "test test test test test test test test test test test junk").
pub const DEFAULT_DEV_ACCOUNTS = [10]primitives.Address{
    parseAddr("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"),
    parseAddr("0x70997970C51812dc3A010C7d01b50e0d17dc79C8"),
    parseAddr("0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"),
    parseAddr("0x90F79bf6EB2c4f870365E785982E1f101E93b906"),
    parseAddr("0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65"),
    parseAddr("0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc"),
    parseAddr("0x976EA74026E726554dB657fA54763abd0C3a0aa9"),
    parseAddr("0x14dC79964da2C08dA15Fd353d30d9CBf55f12515"),
    parseAddr("0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f"),
    parseAddr("0xa0Ee7A142d267C1f36714E4a8F75612F20a79720"),
};

/// Default initial balance: 10,000 ETH in wei
pub const DEFAULT_BALANCE: u256 = 10_000 * 1_000_000_000_000_000_000;

/// Default chain ID matching Hardhat/Anvil
pub const DEFAULT_CHAIN_ID: u64 = 31337;

/// Default gas price: 2 gwei
pub const DEFAULT_GAS_PRICE: u256 = 2_000_000_000;

/// Default base fee: 1 gwei (EIP-1559)
pub const DEFAULT_BASE_FEE: u256 = 1_000_000_000;

/// Default blob base fee: 1 wei (EIP-4844 minimum)
pub const DEFAULT_BLOB_BASE_FEE: u256 = 1;

/// Default max priority fee: 1 gwei
pub const DEFAULT_MAX_PRIORITY_FEE: u256 = 1_000_000_000;

pub const ForkConfig = struct {
    url: []const u8,
    block_number: ?u64 = null,
};

pub const ForkRpcRequest = struct {
    url: []const u8,
    method: []const u8,
    params_json: []const u8,
};

pub const ForkRpcResolver = struct {
    context: ?*anyopaque,
    resolve: *const fn (
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        request: ForkRpcRequest,
    ) anyerror![]u8,
};

pub const ResetForkMode = union(enum) {
    keep_current,
    disable,
    replace: ForkConfig,
};

pub const NodeConfig = struct {
    chain_id: u64 = DEFAULT_CHAIN_ID,
    coinbase_index: u8 = 0,
    initial_balance: u256 = DEFAULT_BALANCE,
    gas_price: u256 = DEFAULT_GAS_PRICE,
    base_fee: u256 = DEFAULT_BASE_FEE,
    blob_base_fee: u256 = DEFAULT_BLOB_BASE_FEE,
    max_priority_fee: u256 = DEFAULT_MAX_PRIORITY_FEE,
    mining_config: mining.MiningConfig = mining.MiningConfig.default(),
    fork_url: ?[]const u8 = null,
    fork_block_number: ?u64 = null,
    fork_rpc_resolver: ?ForkRpcResolver = null,
};

const SnapshotEntry = struct {
    state_snapshot_id: u64,
    head_block_number: u64,
    coinbase: primitives.Address,
    gas_price: u256,
    base_fee: u256,
    blob_base_fee: u256,
    max_priority_fee: u256,
    mining_config: mining.MiningConfig,
    fork_config: ?ForkConfig,
};

pub const NodeRuntime = struct {
    allocator: std.mem.Allocator,
    chain_id: u64,
    initial_balance: u256,
    default_coinbase: primitives.Address,
    default_gas_price: u256,
    default_base_fee: u256,
    default_blob_base_fee: u256,
    default_max_priority_fee: u256,
    default_mining_config: mining.MiningConfig,
    coinbase: primitives.Address,
    head_block_number: u64,
    gas_price: u256,
    base_fee: u256,
    blob_base_fee: u256,
    max_priority_fee: u256,
    mining_config: mining.MiningConfig,
    state: state_manager.StateManager,
    fork_config: ?ForkConfig,
    fork_backend: ?*state_manager.ForkBackend,
    fork_rpc_resolver: ?ForkRpcResolver,
    snapshots: std.AutoHashMap(u64, SnapshotEntry),
    next_snapshot_id: u64,

    pub fn init(allocator: std.mem.Allocator, config_opt: ?NodeConfig) !NodeRuntime {
        const config = config_opt orelse NodeConfig{};

        if (config.fork_block_number != null and config.fork_url == null) {
            return error.InvalidForkConfig;
        }
        if (config.coinbase_index >= DEFAULT_DEV_ACCOUNTS.len) {
            return error.InvalidCoinbaseIndex;
        }

        const initial_fork_config = try allocForkConfig(allocator, if (config.fork_url) |url| .{
            .url = url,
            .block_number = config.fork_block_number,
        } else null);
        errdefer freeForkConfig(allocator, initial_fork_config);

        const fork_backend = try createForkBackend(allocator, initial_fork_config);
        errdefer destroyForkBackend(allocator, fork_backend);

        var state = try state_manager.StateManager.init(allocator, fork_backend);
        errdefer state.deinit();

        // Seed deterministic dev accounts as the local writable overlay.
        // Use initAccount to bypass fork backend reads — dev accounts are
        // unconditional local overrides regardless of remote state.
        for (&DEFAULT_DEV_ACCOUNTS) |addr| {
            try state.initAccount(addr, config.initial_balance);
        }

        var snapshots = std.AutoHashMap(u64, SnapshotEntry).init(allocator);
        errdefer snapshots.deinit();

        const resolver: ?ForkRpcResolver = if (initial_fork_config != null) blk: {
            if (config.fork_rpc_resolver) |custom| {
                break :blk custom;
            }
            break :blk ForkRpcResolver{
                .context = null,
                .resolve = &resolveForkRpcViaHttp,
            };
        } else null;

        return .{
            .allocator = allocator,
            .chain_id = config.chain_id,
            .initial_balance = config.initial_balance,
            .default_coinbase = DEFAULT_DEV_ACCOUNTS[config.coinbase_index],
            .default_gas_price = config.gas_price,
            .default_base_fee = config.base_fee,
            .default_blob_base_fee = config.blob_base_fee,
            .default_max_priority_fee = config.max_priority_fee,
            .default_mining_config = config.mining_config,
            .coinbase = DEFAULT_DEV_ACCOUNTS[config.coinbase_index],
            .head_block_number = 0,
            .gas_price = config.gas_price,
            .base_fee = config.base_fee,
            .blob_base_fee = config.blob_base_fee,
            .max_priority_fee = config.max_priority_fee,
            .mining_config = config.mining_config,
            .state = state,
            .fork_config = initial_fork_config,
            .fork_backend = fork_backend,
            .fork_rpc_resolver = resolver,
            .snapshots = snapshots,
            .next_snapshot_id = 1,
        };
    }

    pub fn setMiningConfig(self: *NodeRuntime, config: mining.MiningConfig) void {
        self.mining_config = config;
    }

    pub fn isForkingEnabled(self: *const NodeRuntime) bool {
        return self.fork_config != null;
    }

    pub fn getBalance(self: *NodeRuntime, address: primitives.Address) !u256 {
        while (true) {
            return self.state.getBalance(address) catch |err| switch (err) {
                error.RpcPending => {
                    try self.serviceForkRequests();
                    continue;
                },
                else => return err,
            };
        }
    }

    pub fn getNonce(self: *NodeRuntime, address: primitives.Address) !u64 {
        while (true) {
            return self.state.getNonce(address) catch |err| switch (err) {
                error.RpcPending => {
                    try self.serviceForkRequests();
                    continue;
                },
                else => return err,
            };
        }
    }

    pub fn getCode(self: *NodeRuntime, address: primitives.Address) ![]const u8 {
        while (true) {
            return self.state.getCode(address) catch |err| switch (err) {
                error.RpcPending => {
                    try self.serviceForkRequests();
                    continue;
                },
                else => return err,
            };
        }
    }

    pub fn getStorage(self: *NodeRuntime, address: primitives.Address, slot: u256) !u256 {
        while (true) {
            return self.state.getStorage(address, slot) catch |err| switch (err) {
                error.RpcPending => {
                    try self.serviceForkRequests();
                    continue;
                },
                else => return err,
            };
        }
    }

    pub fn setBalance(self: *NodeRuntime, address: primitives.Address, balance: u256) !void {
        while (true) {
            self.state.setBalance(address, balance) catch |err| switch (err) {
                error.RpcPending => {
                    try self.serviceForkRequests();
                    continue;
                },
                else => return err,
            };
            return;
        }
    }

    pub fn setNonce(self: *NodeRuntime, address: primitives.Address, nonce: u64) !void {
        while (true) {
            self.state.setNonce(address, nonce) catch |err| switch (err) {
                error.RpcPending => {
                    try self.serviceForkRequests();
                    continue;
                },
                else => return err,
            };
            return;
        }
    }

    pub fn setCode(self: *NodeRuntime, address: primitives.Address, code: []const u8) !void {
        try self.state.setCode(address, code);
    }

    pub fn setStorage(self: *NodeRuntime, address: primitives.Address, slot: u256, value: u256) !void {
        try self.state.setStorage(address, slot, value);
    }

    pub fn snapshot(self: *NodeRuntime) !u64 {
        const snapshot_id = self.next_snapshot_id;
        self.next_snapshot_id += 1;

        const state_snapshot_id = try self.state.snapshot();
        const fork_copy = try allocForkConfig(self.allocator, self.fork_config);
        errdefer freeForkConfig(self.allocator, fork_copy);

        try self.snapshots.put(snapshot_id, .{
            .state_snapshot_id = state_snapshot_id,
            .head_block_number = self.head_block_number,
            .coinbase = self.coinbase,
            .gas_price = self.gas_price,
            .base_fee = self.base_fee,
            .blob_base_fee = self.blob_base_fee,
            .max_priority_fee = self.max_priority_fee,
            .mining_config = self.mining_config,
            .fork_config = fork_copy,
        });

        return snapshot_id;
    }

    pub fn revertToSnapshot(self: *NodeRuntime, snapshot_id: u64) !bool {
        const entry = self.snapshots.get(snapshot_id) orelse return false;

        self.state.revertToSnapshot(entry.state_snapshot_id) catch return false;

        self.head_block_number = entry.head_block_number;
        self.coinbase = entry.coinbase;
        self.gas_price = entry.gas_price;
        self.base_fee = entry.base_fee;
        self.blob_base_fee = entry.blob_base_fee;
        self.max_priority_fee = entry.max_priority_fee;
        self.mining_config = entry.mining_config;

        try self.restoreForkStateFromSnapshot(entry.fork_config);

        var to_remove = std.ArrayList(u64){};
        defer to_remove.deinit(self.allocator);

        var it = self.snapshots.iterator();
        while (it.next()) |kv| {
            if (kv.key_ptr.* >= snapshot_id) {
                try to_remove.append(self.allocator, kv.key_ptr.*);
            }
        }

        for (to_remove.items) |id| {
            if (self.snapshots.fetchRemove(id)) |removed| {
                freeForkConfig(self.allocator, removed.value.fork_config);
            }
        }

        return true;
    }

    pub fn reset(self: *NodeRuntime, mode: ResetForkMode) !void {
        const target_fork: ?ForkConfig = switch (mode) {
            .keep_current => self.fork_config,
            .disable => null,
            .replace => |fork| fork,
        };

        if (target_fork) |fork| {
            try validateForkUrl(fork.url);
        }

        try self.rebuildState(target_fork);
        self.coinbase = self.default_coinbase;
        self.head_block_number = 0;
        self.gas_price = self.default_gas_price;
        self.base_fee = self.default_base_fee;
        self.blob_base_fee = self.default_blob_base_fee;
        self.max_priority_fee = self.default_max_priority_fee;
        self.mining_config = self.default_mining_config;
        self.clearSnapshots();
    }

    pub fn setRpcUrl(self: *NodeRuntime, new_url: []const u8) !void {
        try validateForkUrl(new_url);

        var fork_cfg = self.fork_config orelse return error.ForkNotEnabled;
        const new_url_owned = try self.allocator.dupe(u8, new_url);
        self.allocator.free(fork_cfg.url);
        fork_cfg.url = new_url_owned;
        self.fork_config = fork_cfg;

        // Upstream changed; clear only remote cache while preserving local overlays.
        self.state.clearForkCache();
    }

    pub fn deinit(self: *NodeRuntime) void {
        self.clearSnapshots();
        self.snapshots.deinit();
        self.state.deinit();
        destroyForkBackend(self.allocator, self.fork_backend);
        freeForkConfig(self.allocator, self.fork_config);
        self.fork_backend = null;
        self.fork_config = null;
    }

    fn rebuildState(self: *NodeRuntime, target_fork: ?ForkConfig) !void {
        const new_fork_config = try allocForkConfig(self.allocator, target_fork);
        errdefer freeForkConfig(self.allocator, new_fork_config);

        const new_backend = try createForkBackend(self.allocator, new_fork_config);
        errdefer destroyForkBackend(self.allocator, new_backend);

        var new_state = try state_manager.StateManager.init(self.allocator, new_backend);
        errdefer new_state.deinit();

        for (&DEFAULT_DEV_ACCOUNTS) |addr| {
            try new_state.initAccount(addr, self.initial_balance);
        }

        self.state.deinit();
        destroyForkBackend(self.allocator, self.fork_backend);
        freeForkConfig(self.allocator, self.fork_config);

        self.state = new_state;
        self.fork_backend = new_backend;
        self.fork_config = new_fork_config;
        if (new_fork_config != null and self.fork_rpc_resolver == null) {
            self.fork_rpc_resolver = .{
                .context = null,
                .resolve = &resolveForkRpcViaHttp,
            };
        }
    }

    fn restoreForkStateFromSnapshot(self: *NodeRuntime, snapshot_fork: ?ForkConfig) !void {
        if (self.fork_config == null and snapshot_fork == null) {
            return;
        }
        if (self.fork_config == null or snapshot_fork == null) {
            return error.ForkSnapshotMismatch;
        }

        var current = self.fork_config.?;
        const target = snapshot_fork.?;
        if (current.block_number != target.block_number or !std.mem.eql(u8, current.url, target.url)) {
            const updated_url = try self.allocator.dupe(u8, target.url);
            self.allocator.free(current.url);
            current.url = updated_url;
            current.block_number = target.block_number;
            self.fork_config = current;
            self.state.clearForkCache();
        }
    }

    fn serviceForkRequests(self: *NodeRuntime) !void {
        const resolver = self.fork_rpc_resolver orelse return error.ForkResolverUnavailable;
        const backend = self.fork_backend orelse return error.ForkNotEnabled;
        const fork_cfg = self.fork_config orelse return error.ForkNotEnabled;

        while (backend.nextRequest()) |request| {
            const method_name: []const u8 = switch (request.kind) {
                .code => "eth_getCode",
                .account_proof, .storage_proof => "eth_getProof",
            };

            const response_payload = try resolver.resolve(
                resolver.context,
                self.allocator,
                .{
                    .url = fork_cfg.url,
                    .method = method_name,
                    .params_json = request.params_json,
                },
            );
            defer self.allocator.free(response_payload);

            try backend.continueRequest(request.id, response_payload);
        }
    }

    fn clearSnapshots(self: *NodeRuntime) void {
        var it = self.snapshots.valueIterator();
        while (it.next()) |entry| {
            freeForkConfig(self.allocator, entry.fork_config);
        }
        self.snapshots.clearRetainingCapacity();
        self.next_snapshot_id = 1;
    }
};

fn validateForkUrl(url: []const u8) !void {
    if (url.len == 0) return error.InvalidForkUrl;
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
        return error.InvalidForkUrl;
    }
}

fn allocForkConfig(allocator: std.mem.Allocator, fork: ?ForkConfig) !?ForkConfig {
    if (fork) |value| {
        try validateForkUrl(value.url);
        return .{
            .url = try allocator.dupe(u8, value.url),
            .block_number = value.block_number,
        };
    }
    return null;
}

fn freeForkConfig(allocator: std.mem.Allocator, fork: ?ForkConfig) void {
    if (fork) |value| {
        allocator.free(value.url);
    }
}

fn createForkBackend(
    allocator: std.mem.Allocator,
    fork: ?ForkConfig,
) !?*state_manager.ForkBackend {
    if (fork) |fork_cfg| {
        _ = fork_cfg.url;

        const block_tag = if (fork_cfg.block_number) |block_number|
            try std.fmt.allocPrint(allocator, "0x{x}", .{block_number})
        else
            try allocator.dupe(u8, "latest");
        defer allocator.free(block_tag);

        const backend = try allocator.create(state_manager.ForkBackend);
        errdefer allocator.destroy(backend);
        backend.* = try state_manager.ForkBackend.init(allocator, block_tag, .{});
        return backend;
    }
    return null;
}

fn destroyForkBackend(allocator: std.mem.Allocator, backend: ?*state_manager.ForkBackend) void {
    if (backend) |fork_backend| {
        fork_backend.deinit();
        allocator.destroy(fork_backend);
    }
}

fn resolveForkRpcViaHttp(
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    request: ForkRpcRequest,
) ![]u8 {
    _ = context;

    const request_body = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\",\"params\":{s}}}",
        .{ request.method, request.params_json },
    );
    defer allocator.free(request_body);

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var response_writer = std.Io.Writer.Allocating.init(allocator);
    defer response_writer.deinit();

    const response = try client.fetch(.{
        .location = .{ .url = request.url },
        .method = .POST,
        .payload = request_body,
        .extra_headers = &[_]std.http.Header{
            .{
                .name = "content-type",
                .value = "application/json",
            },
        },
        .response_writer = &response_writer.writer,
    });
    if (response.status != .ok) {
        return error.UpstreamRpcFailed;
    }

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_writer.written(), .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidUpstreamRpcResponse;
    const result = parsed.value.object.get("result") orelse return error.InvalidUpstreamRpcResponse;
    return try stringifyJsonValue(allocator, result);
}

fn stringifyJsonValue(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    try std.json.Stringify.value(value, .{}, &writer.writer);
    return writer.toOwnedSlice();
}

fn parseAddr(comptime hex: *const [42]u8) primitives.Address {
    var out: [20]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex[2..]) catch unreachable;
    return .{ .bytes = out };
}
