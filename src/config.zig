const std = @import("std");
const cli = @import("cli.zig");
const consensus_sync = @import("consensus_sync.zig");
const mining = @import("mining.zig");
const node_runtime = @import("node/runtime.zig");

pub const Mode = cli.Mode;
pub const Network = cli.Network;

pub const DEFAULT_HOST = "127.0.0.1";
pub const DEFAULT_PORT: u16 = 8545;
pub const DEFAULT_BLOCK_GAS_LIMIT: u64 = 30_000_000;
pub const DEFAULT_MAX_CHECKPOINT_AGE_SECONDS: u64 = 1_209_600;
const DEFAULT_CHECKPOINT_DIR_TEMPLATE = ".zevm/checkpoints/<network>";

pub const LoadError = error{
    InvalidConfig,
    OutOfMemory,
};

pub const RpcConfig = struct {
    host: []const u8,
    port: u16,
};

pub const ForkConfig = struct {
    url: []const u8,
    block_number: ?u64 = null,
};

pub const TrustedConfig = struct {
    chain_id: u64,
    coinbase_index: u8,
    initial_balance: u256,
    gas_price: u256,
    base_fee: u256,
    blob_base_fee: u256,
    max_priority_fee_per_gas: u256,
    block_gas_limit: u64,
    mining_config: mining.MiningConfig,
    fork: ?ForkConfig,

    pub fn toNodeConfig(self: TrustedConfig) node_runtime.NodeConfig {
        return .{
            .chain_id = self.chain_id,
            .coinbase_index = self.coinbase_index,
            .initial_balance = self.initial_balance,
            .gas_price = self.gas_price,
            .base_fee = self.base_fee,
            .blob_base_fee = self.blob_base_fee,
            .max_priority_fee = self.max_priority_fee_per_gas,
            .mining_config = self.mining_config,
            .fork_url = if (self.fork) |fork| fork.url else null,
            .fork_block_number = if (self.fork) |fork| fork.block_number else null,
        };
    }
};

pub const CheckpointSource = enum {
    explicit,
    persisted,
    default,
};

pub const LightConfig = struct {
    network: Network,
    consensus_rpc_url: []const u8,
    execution_rpc_url: ?[]const u8,
    checkpoint: [32]u8,
    checkpoint_source: CheckpointSource,
    checkpoint_dir: []const u8,
    max_checkpoint_age_seconds: u64,
    strict_checkpoint_age: bool,

    pub fn toNodeConfig(self: LightConfig) node_runtime.NodeConfig {
        return .{
            .mode = .light,
            .light = .{
                .network = lightNetworkToRuntime(self.network),
                .consensus_rpc_url = self.consensus_rpc_url,
                .proof_rpc_url = self.execution_rpc_url,
                .checkpoint = self.checkpoint,
                .checkpoint_dir = self.checkpoint_dir,
                .checkpoint_source = checkpointSourceToRuntime(self.checkpoint_source),
                .max_checkpoint_age_seconds = self.max_checkpoint_age_seconds,
                .strict_checkpoint_age = self.strict_checkpoint_age,
            },
        };
    }
};

pub const ModeConfig = union(Mode) {
    trusted: TrustedConfig,
    light: LightConfig,
};

pub const AppConfig = struct {
    rpc: RpcConfig,
    mode: ModeConfig,

    pub fn deinit(self: *AppConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.rpc.host);
        switch (self.mode) {
            .trusted => |trusted| {
                if (trusted.fork) |fork| {
                    allocator.free(fork.url);
                }
            },
            .light => |light| {
                allocator.free(light.consensus_rpc_url);
                if (light.execution_rpc_url) |url| allocator.free(url);
                allocator.free(light.checkpoint_dir);
            },
        }
    }
};

fn lightNetworkToRuntime(network: Network) node_runtime.LightNetwork {
    return switch (network) {
        .mainnet => .mainnet,
        .sepolia => .sepolia,
        .holesky => .holesky,
    };
}

fn checkpointSourceToRuntime(source: CheckpointSource) node_runtime.CheckpointSource {
    return switch (source) {
        .explicit => .explicit,
        .persisted => .persisted,
        .default => .default,
    };
}

const FileRpc = struct {
    host: ?[]const u8 = null,
    port: ?u16 = null,
};

const FileFork = struct {
    url: []const u8,
    block_number: ?u64 = null,
};

const FileTrusted = struct {
    chain_id: ?u64 = null,
    coinbase_index: ?u8 = null,
    initial_balance: ?u256 = null,
    gas_price: ?u256 = null,
    base_fee: ?u256 = null,
    blob_base_fee: ?u256 = null,
    max_priority_fee_per_gas: ?u256 = null,
    block_gas_limit: ?u64 = null,
    mining_config: ?mining.MiningConfig = null,
    fork: ?FileFork = null,
};

const FileLight = struct {
    network: ?Network = null,
    consensus_rpc_url: ?[]const u8 = null,
    execution_rpc_url: ?[]const u8 = null,
    checkpoint: ?[32]u8 = null,
    checkpoint_dir: ?[]const u8 = null,
    max_checkpoint_age_seconds: ?u64 = null,
    strict_checkpoint_age: ?bool = null,
};

const FileMode = union(Mode) {
    trusted: FileTrusted,
    light: FileLight,
};

const FileConfig = struct {
    rpc: FileRpc = .{},
    mode: FileMode,
};

pub fn load(allocator: std.mem.Allocator, args: []const []const u8) LoadError!AppConfig {
    const options = cli.parse(args) catch return error.InvalidConfig;

    if (options.config_path) |path| {
        const bytes = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| {
            return mapIoOrAllocError(err);
        };
        defer allocator.free(bytes);

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
            .allocate = .alloc_always,
        }) catch return error.InvalidConfig;
        defer parsed.deinit();

        const file_config = parseFileConfig(parsed.value) catch return error.InvalidConfig;
        return resolve(allocator, options, file_config) catch |err| return mapLoadError(err);
    }

    return resolve(allocator, options, null) catch |err| return mapLoadError(err);
}

fn resolve(
    allocator: std.mem.Allocator,
    options: cli.Options,
    file_config: ?FileConfig,
) LoadError!AppConfig {
    const resolved_mode = try resolveMode(options, file_config);

    if (resolved_mode == .trusted and options.hasLightOnly()) {
        return error.InvalidConfig;
    }
    if (resolved_mode == .light and options.hasTrustedOnly()) {
        return error.InvalidConfig;
    }

    const rpc = try resolveRpc(allocator, options, file_config);
    errdefer allocator.free(rpc.host);

    const mode_config: ModeConfig = switch (resolved_mode) {
        .trusted => .{ .trusted = try resolveTrusted(allocator, options, fileTrusted(file_config)) },
        .light => .{ .light = try resolveLight(allocator, options, fileLight(file_config)) },
    };
    errdefer deinitModeConfig(allocator, mode_config);

    return .{
        .rpc = rpc,
        .mode = mode_config,
    };
}

fn resolveMode(options: cli.Options, file_config: ?FileConfig) LoadError!Mode {
    if (file_config) |file| {
        const file_mode = std.meta.activeTag(file.mode);
        if (options.mode) |user_mode| {
            if (user_mode != file_mode) {
                return error.InvalidConfig;
            }
        }
        return file_mode;
    }

    return options.mode orelse .trusted;
}

fn resolveRpc(
    allocator: std.mem.Allocator,
    options: cli.Options,
    file_config: ?FileConfig,
) LoadError!RpcConfig {
    const file_rpc = if (file_config) |file| file.rpc else FileRpc{};
    return .{
        .host = try allocator.dupe(u8, options.host orelse file_rpc.host orelse DEFAULT_HOST),
        .port = options.port orelse file_rpc.port orelse DEFAULT_PORT,
    };
}

fn resolveTrusted(
    allocator: std.mem.Allocator,
    options: cli.Options,
    file: ?FileTrusted,
) LoadError!TrustedConfig {
    const file_value = file orelse FileTrusted{};
    const coinbase_index = options.coinbase_index orelse file_value.coinbase_index orelse 0;
    if (coinbase_index >= node_runtime.DEFAULT_DEV_ACCOUNTS.len) {
        return error.InvalidConfig;
    }

    const fork = try resolveFork(allocator, options, file_value.fork);
    errdefer freeFork(allocator, fork);

    return .{
        .chain_id = options.chain_id orelse file_value.chain_id orelse node_runtime.DEFAULT_CHAIN_ID,
        .coinbase_index = coinbase_index,
        .initial_balance = options.initial_balance orelse file_value.initial_balance orelse node_runtime.DEFAULT_BALANCE,
        .gas_price = options.gas_price orelse file_value.gas_price orelse node_runtime.DEFAULT_GAS_PRICE,
        .base_fee = options.base_fee orelse file_value.base_fee orelse node_runtime.DEFAULT_BASE_FEE,
        .blob_base_fee = options.blob_base_fee orelse file_value.blob_base_fee orelse node_runtime.DEFAULT_BLOB_BASE_FEE,
        .max_priority_fee_per_gas = options.max_priority_fee_per_gas orelse file_value.max_priority_fee_per_gas orelse node_runtime.DEFAULT_MAX_PRIORITY_FEE,
        .block_gas_limit = options.block_gas_limit orelse file_value.block_gas_limit orelse DEFAULT_BLOCK_GAS_LIMIT,
        .mining_config = try resolveMining(options, file_value.mining_config),
        .fork = fork,
    };
}

fn resolveMining(options: cli.Options, file_mining: ?mining.MiningConfig) LoadError!mining.MiningConfig {
    if (options.hasMiningUnit()) {
        const mining_type = options.mining orelse .auto;
        return makeMiningConfig(mining_type, options.block_time);
    }

    return file_mining orelse mining.MiningConfig.default();
}

fn makeMiningConfig(mining_type: cli.MiningType, block_time: ?u64) LoadError!mining.MiningConfig {
    return switch (mining_type) {
        .auto => if (block_time == null) .auto else error.InvalidConfig,
        .manual => if (block_time == null) .manual else error.InvalidConfig,
        .interval => .{ .interval = .{ .block_time = block_time orelse return error.InvalidConfig } },
    };
}

fn resolveFork(
    allocator: std.mem.Allocator,
    options: cli.Options,
    file_fork: ?FileFork,
) LoadError!?ForkConfig {
    if (options.hasForkUnit()) {
        if (options.fork_block_number != null and options.fork_url == null) {
            return error.InvalidConfig;
        }
        if (options.fork_url) |url| {
            return .{
                .url = try allocator.dupe(u8, url),
                .block_number = options.fork_block_number,
            };
        }
        return null;
    }

    if (file_fork) |fork| {
        return .{
            .url = try allocator.dupe(u8, fork.url),
            .block_number = fork.block_number,
        };
    }

    return null;
}

fn resolveLight(
    allocator: std.mem.Allocator,
    options: cli.Options,
    file: ?FileLight,
) LoadError!LightConfig {
    const file_value = file orelse FileLight{};
    const network = options.network orelse file_value.network orelse .mainnet;

    const consensus_rpc_url = options.consensus_rpc_url orelse file_value.consensus_rpc_url orelse return error.InvalidConfig;
    const owned_consensus_rpc_url = try allocator.dupe(u8, consensus_rpc_url);
    errdefer allocator.free(owned_consensus_rpc_url);

    const execution_rpc_url = options.execution_rpc_url orelse file_value.execution_rpc_url;
    const owned_execution_rpc_url = if (execution_rpc_url) |url| try allocator.dupe(u8, url) else null;
    errdefer if (owned_execution_rpc_url) |url| allocator.free(url);

    const checkpoint_dir_template = options.checkpoint_dir orelse file_value.checkpoint_dir orelse DEFAULT_CHECKPOINT_DIR_TEMPLATE;
    const checkpoint_dir = try resolveCheckpointDir(allocator, checkpoint_dir_template, network);
    errdefer allocator.free(checkpoint_dir);

    const selected_checkpoint = try selectCheckpoint(
        allocator,
        network,
        options.checkpoint,
        file_value.checkpoint,
        checkpoint_dir,
    );

    return .{
        .network = network,
        .consensus_rpc_url = owned_consensus_rpc_url,
        .execution_rpc_url = owned_execution_rpc_url,
        .checkpoint = selected_checkpoint.hash,
        .checkpoint_source = selected_checkpoint.source,
        .checkpoint_dir = checkpoint_dir,
        .max_checkpoint_age_seconds = options.max_checkpoint_age_seconds orelse file_value.max_checkpoint_age_seconds orelse DEFAULT_MAX_CHECKPOINT_AGE_SECONDS,
        .strict_checkpoint_age = if (options.strict_checkpoint_age_present) true else file_value.strict_checkpoint_age orelse false,
    };
}

const SelectedCheckpoint = struct {
    hash: [32]u8,
    source: CheckpointSource,
};

fn selectCheckpoint(
    allocator: std.mem.Allocator,
    network: Network,
    cli_checkpoint: ?[32]u8,
    config_checkpoint: ?[32]u8,
    checkpoint_dir: []const u8,
) LoadError!SelectedCheckpoint {
    if (cli_checkpoint) |hash| {
        return .{ .hash = hash, .source = .explicit };
    }
    if (config_checkpoint) |hash| {
        return .{ .hash = hash, .source = .explicit };
    }

    if (try readPersistedCheckpoint(allocator, checkpoint_dir)) |hash| {
        return .{ .hash = hash, .source = .persisted };
    }

    return .{ .hash = defaultCheckpoint(network), .source = .default };
}

fn readPersistedCheckpoint(
    allocator: std.mem.Allocator,
    checkpoint_dir: []const u8,
) LoadError!?[32]u8 {
    var dir = std.fs.openDirAbsolute(checkpoint_dir, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return error.InvalidConfig,
    };
    defer dir.close();

    const bytes = dir.readFileAlloc(allocator, "checkpoint", 1024) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidConfig,
    };
    defer allocator.free(bytes);

    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    return cli.parseUnprefixedHash32(trimmed) catch error.InvalidConfig;
}

fn defaultCheckpoint(network: Network) [32]u8 {
    return switch (network) {
        .mainnet => consensus_sync.NetworkConfig.mainnet("").default_checkpoint,
        .sepolia => consensus_sync.NetworkConfig.sepolia("").default_checkpoint,
        .holesky => consensus_sync.NetworkConfig.holesky("").default_checkpoint,
    };
}

fn resolveCheckpointDir(
    allocator: std.mem.Allocator,
    template: []const u8,
    network: Network,
) LoadError![]u8 {
    const expanded = try expandNetworkTemplate(allocator, template, cli.networkName(network));
    defer allocator.free(expanded);

    if (std.fs.path.isAbsolute(expanded)) {
        return allocator.dupe(u8, expanded);
    }

    const cwd = std.process.getCwdAlloc(allocator) catch |err| return mapIoOrAllocError(err);
    defer allocator.free(cwd);

    return std.fs.path.resolve(allocator, &.{ cwd, expanded });
}

fn expandNetworkTemplate(
    allocator: std.mem.Allocator,
    template: []const u8,
    network_name: []const u8,
) LoadError![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    var remainder = template;
    while (std.mem.indexOf(u8, remainder, "<network>")) |index| {
        try output.appendSlice(allocator, remainder[0..index]);
        try output.appendSlice(allocator, network_name);
        remainder = remainder[index + "<network>".len ..];
    }
    try output.appendSlice(allocator, remainder);

    return output.toOwnedSlice(allocator);
}

fn parseFileConfig(value: std.json.Value) LoadError!FileConfig {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidConfig,
    };

    var rpc = FileRpc{};
    var mode: ?FileMode = null;

    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "rpc")) {
            rpc = try parseRpc(entry.value_ptr.*);
        } else if (std.mem.eql(u8, key, "mode")) {
            mode = try parseModeObject(entry.value_ptr.*);
        } else {
            return error.InvalidConfig;
        }
    }

    return .{
        .rpc = rpc,
        .mode = mode orelse return error.InvalidConfig,
    };
}

fn parseRpc(value: std.json.Value) LoadError!FileRpc {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidConfig,
    };

    var rpc = FileRpc{};
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "host")) {
            rpc.host = try parseString(entry.value_ptr.*);
        } else if (std.mem.eql(u8, key, "port")) {
            rpc.port = try parseU16(entry.value_ptr.*);
        } else {
            return error.InvalidConfig;
        }
    }
    return rpc;
}

fn parseModeObject(value: std.json.Value) LoadError!FileMode {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidConfig,
    };

    var trusted: ?FileTrusted = null;
    var light: ?FileLight = null;
    var branch_count: u8 = 0;

    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "trusted")) {
            trusted = try parseTrusted(entry.value_ptr.*);
            branch_count += 1;
        } else if (std.mem.eql(u8, key, "light")) {
            light = try parseLight(entry.value_ptr.*);
            branch_count += 1;
        } else {
            return error.InvalidConfig;
        }
    }

    if (branch_count != 1) {
        return error.InvalidConfig;
    }
    if (trusted) |trusted_value| {
        return .{ .trusted = trusted_value };
    }
    return .{ .light = light.? };
}

fn parseTrusted(value: std.json.Value) LoadError!FileTrusted {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidConfig,
    };

    var trusted = FileTrusted{};
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "chainId")) {
            trusted.chain_id = try parseU64(entry.value_ptr.*);
        } else if (std.mem.eql(u8, key, "coinbaseIndex")) {
            trusted.coinbase_index = try parseU8(entry.value_ptr.*);
        } else if (std.mem.eql(u8, key, "initialBalance")) {
            trusted.initial_balance = try parseDecimalU256String(entry.value_ptr.*);
        } else if (std.mem.eql(u8, key, "gasPrice")) {
            trusted.gas_price = try parseDecimalU256String(entry.value_ptr.*);
        } else if (std.mem.eql(u8, key, "baseFee")) {
            trusted.base_fee = try parseDecimalU256String(entry.value_ptr.*);
        } else if (std.mem.eql(u8, key, "blobBaseFee")) {
            trusted.blob_base_fee = try parseDecimalU256String(entry.value_ptr.*);
        } else if (std.mem.eql(u8, key, "maxPriorityFeePerGas")) {
            trusted.max_priority_fee_per_gas = try parseDecimalU256String(entry.value_ptr.*);
        } else if (std.mem.eql(u8, key, "blockGasLimit")) {
            trusted.block_gas_limit = try parseU64(entry.value_ptr.*);
        } else if (std.mem.eql(u8, key, "mining")) {
            trusted.mining_config = try parseMining(entry.value_ptr.*);
        } else if (std.mem.eql(u8, key, "fork")) {
            trusted.fork = try parseFork(entry.value_ptr.*);
        } else {
            return error.InvalidConfig;
        }
    }
    return trusted;
}

fn parseMining(value: std.json.Value) LoadError!mining.MiningConfig {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidConfig,
    };

    var mining_type: ?cli.MiningType = null;
    var block_time: ?u64 = null;

    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "type")) {
            mining_type = cli.miningTypeFromString(try parseString(entry.value_ptr.*)) orelse return error.InvalidConfig;
        } else if (std.mem.eql(u8, key, "blockTime")) {
            block_time = try parseU64(entry.value_ptr.*);
        } else {
            return error.InvalidConfig;
        }
    }

    return makeMiningConfig(mining_type orelse return error.InvalidConfig, block_time);
}

fn parseFork(value: std.json.Value) LoadError!?FileFork {
    if (value == .null) {
        return null;
    }

    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidConfig,
    };

    var url: ?[]const u8 = null;
    var block_number: ?u64 = null;

    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "url")) {
            url = try parseString(entry.value_ptr.*);
        } else if (std.mem.eql(u8, key, "blockNumber")) {
            block_number = try parseU64(entry.value_ptr.*);
        } else {
            return error.InvalidConfig;
        }
    }

    return .{
        .url = url orelse return error.InvalidConfig,
        .block_number = block_number,
    };
}

fn parseLight(value: std.json.Value) LoadError!FileLight {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidConfig,
    };

    var light = FileLight{};
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "network")) {
            light.network = cli.networkFromString(try parseString(entry.value_ptr.*)) orelse return error.InvalidConfig;
        } else if (std.mem.eql(u8, key, "consensusRpcUrl")) {
            light.consensus_rpc_url = try parseString(entry.value_ptr.*);
        } else if (std.mem.eql(u8, key, "executionRpcUrl")) {
            light.execution_rpc_url = try parseString(entry.value_ptr.*);
        } else if (std.mem.eql(u8, key, "checkpoint")) {
            light.checkpoint = try parseOptionalPrefixedHash32(entry.value_ptr.*);
        } else if (std.mem.eql(u8, key, "checkpointDir")) {
            light.checkpoint_dir = try parseString(entry.value_ptr.*);
        } else if (std.mem.eql(u8, key, "maxCheckpointAgeSeconds")) {
            light.max_checkpoint_age_seconds = try parseU64(entry.value_ptr.*);
        } else if (std.mem.eql(u8, key, "strictCheckpointAge")) {
            light.strict_checkpoint_age = try parseBool(entry.value_ptr.*);
        } else {
            return error.InvalidConfig;
        }
    }
    return light;
}

fn parseOptionalPrefixedHash32(value: std.json.Value) LoadError!?[32]u8 {
    if (value == .null) {
        return null;
    }
    return cli.parsePrefixedHash32(try parseString(value)) catch error.InvalidConfig;
}

fn parseString(value: std.json.Value) LoadError![]const u8 {
    return switch (value) {
        .string => |string| string,
        else => error.InvalidConfig,
    };
}

fn parseBool(value: std.json.Value) LoadError!bool {
    return switch (value) {
        .bool => |boolean| boolean,
        else => error.InvalidConfig,
    };
}

fn parseU64(value: std.json.Value) LoadError!u64 {
    const integer = switch (value) {
        .integer => |integer| integer,
        else => return error.InvalidConfig,
    };
    if (integer < 0) {
        return error.InvalidConfig;
    }
    return @intCast(integer);
}

fn parseU16(value: std.json.Value) LoadError!u16 {
    const integer = try parseU64(value);
    if (integer > std.math.maxInt(u16)) {
        return error.InvalidConfig;
    }
    return @intCast(integer);
}

fn parseU8(value: std.json.Value) LoadError!u8 {
    const integer = try parseU64(value);
    if (integer > std.math.maxInt(u8)) {
        return error.InvalidConfig;
    }
    return @intCast(integer);
}

fn parseDecimalU256String(value: std.json.Value) LoadError!u256 {
    return std.fmt.parseInt(u256, try parseString(value), 10) catch error.InvalidConfig;
}

fn fileTrusted(file_config: ?FileConfig) ?FileTrusted {
    if (file_config) |file| {
        return switch (file.mode) {
            .trusted => |trusted| trusted,
            .light => null,
        };
    }
    return null;
}

fn fileLight(file_config: ?FileConfig) ?FileLight {
    if (file_config) |file| {
        return switch (file.mode) {
            .trusted => null,
            .light => |light| light,
        };
    }
    return null;
}

fn deinitModeConfig(allocator: std.mem.Allocator, mode_config: ModeConfig) void {
    switch (mode_config) {
        .trusted => |trusted| freeFork(allocator, trusted.fork),
        .light => |light| {
            allocator.free(light.consensus_rpc_url);
            if (light.execution_rpc_url) |url| allocator.free(url);
            allocator.free(light.checkpoint_dir);
        },
    }
}

fn freeFork(allocator: std.mem.Allocator, fork: ?ForkConfig) void {
    if (fork) |value| {
        allocator.free(value.url);
    }
}

fn mapLoadError(err: anyerror) LoadError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidConfig,
    };
}

fn mapIoOrAllocError(err: anyerror) LoadError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidConfig,
    };
}
