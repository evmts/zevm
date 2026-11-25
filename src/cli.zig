const std = @import("std");

pub const Mode = enum {
    trusted,
    light,
};

pub const Network = enum {
    mainnet,
    sepolia,
    holesky,
    hoodi,
};

pub const MiningType = enum {
    auto,
    manual,
    interval,
};

/// Matches `web3_clientVersion` (`zevm/<VERSION>`).
pub const VERSION = "0.1.0";

pub const usage =
    \\Usage: zevm [options]
    \\
    \\General:
    \\  --config <path>                    JSON config file
    \\  --mode <trusted|light>             Node mode (default: trusted)
    \\  --host <ip|localhost>              JSON-RPC bind host (default: 127.0.0.1)
    \\  --port <u16>                       JSON-RPC port (default: 8545)
    \\  -h, --help                         Print this help and exit
    \\  -V, --version                      Print the version and exit
    \\
    \\Engine API (trusted mode):
    \\  --engine-host <ip|localhost>       Engine API bind host
    \\  --engine-port <u16>                Engine API port (default: 8551)
    \\  --authrpc.jwtsecret <path>         Hex-encoded 32-byte JWT secret file; generated when omitted
    \\
    \\Trusted mode:
    \\  --chain-id <u64>                   Chain id (non-zero)
    \\  --coinbase-index <u8>              Dev account used as coinbase
    \\  --initial-balance <wei>            Dev account balance
    \\  --gas-price <wei>                  Legacy gas price
    \\  --base-fee <wei>                   Initial base fee
    \\  --blob-base-fee <wei>              Initial blob base fee
    \\  --max-priority-fee-per-gas <wei>   Default priority fee
    \\  --block-gas-limit <u64>            Block gas limit (non-zero)
    \\  --mining <auto|manual|interval>    Mining mode
    \\  --block-time <seconds>             Interval mining period (non-zero)
    \\  --fork-url <url>                   Upstream RPC to fork
    \\  --fork-block-number <u64>          Fork pin block
    \\  --fork-follow                      Follow the upstream head and rebase local txs (needs --fork-url)
    \\  --genesis <path>                   Genesis alloc JSON
    \\  --chain-rlp <path>                 Chain RLP to import
    \\  --execution-fixture-rpc-dir <dir>  Serve recorded .io fixtures (opt-in)
    \\
    \\Light mode:
    \\  --network <mainnet|sepolia|holesky|hoodi>
    \\  --consensus-rpc-url <url>
    \\  --execution-rpc-url <url>
    \\  --checkpoint <0x-hash>
    \\  --checkpoint-dir <path>
    \\  --max-checkpoint-age-seconds <u64>
    \\  --strict-checkpoint-age
    \\
    \\Environment:
    \\  ZEVM_LOG_LEVEL=<err|warn|info|debug>
    \\
;

pub const ParseError = error{
    UnknownArgument,
    MissingFlagValue,
    InvalidFlagValue,
};

pub const Options = struct {
    config_path: ?[]const u8 = null,
    mode: ?Mode = null,
    host: ?[]const u8 = null,
    port: ?u16 = null,
    engine_host: ?[]const u8 = null,
    engine_port: ?u16 = null,
    engine_jwt_secret_file: ?[]const u8 = null,
    help: bool = false,
    version: bool = false,

    chain_id: ?u64 = null,
    coinbase_index: ?u8 = null,
    initial_balance: ?u256 = null,
    gas_price: ?u256 = null,
    base_fee: ?u256 = null,
    blob_base_fee: ?u256 = null,
    max_priority_fee_per_gas: ?u256 = null,
    block_gas_limit: ?u64 = null,
    mining: ?MiningType = null,
    block_time: ?u64 = null,
    fork_url: ?[]const u8 = null,
    fork_block_number: ?u64 = null,
    /// `--fork-follow` presence flag. Fork flags resolve as one unit.
    fork_follow: bool = false,
    genesis_alloc_path: ?[]const u8 = null,
    chain_rlp_path: ?[]const u8 = null,
    execution_fixture_rpc_dir: ?[]const u8 = null,

    network: ?Network = null,
    consensus_rpc_url: ?[]const u8 = null,
    execution_rpc_url: ?[]const u8 = null,
    checkpoint: ?[32]u8 = null,
    checkpoint_dir: ?[]const u8 = null,
    max_checkpoint_age_seconds: ?u64 = null,
    strict_checkpoint_age: bool = false,
    strict_checkpoint_age_present: bool = false,

    pub fn hasTrustedOnly(self: Options) bool {
        return self.chain_id != null or
            self.coinbase_index != null or
            self.initial_balance != null or
            self.gas_price != null or
            self.base_fee != null or
            self.blob_base_fee != null or
            self.max_priority_fee_per_gas != null or
            self.block_gas_limit != null or
            self.mining != null or
            self.block_time != null or
            self.fork_url != null or
            self.fork_block_number != null or
            self.fork_follow or
            self.genesis_alloc_path != null or
            self.chain_rlp_path != null or
            self.execution_fixture_rpc_dir != null;
    }

    pub fn hasEngineRpc(self: Options) bool {
        return self.engine_host != null or self.engine_port != null or self.engine_jwt_secret_file != null;
    }

    pub fn hasLightOnly(self: Options) bool {
        return self.network != null or
            self.consensus_rpc_url != null or
            self.execution_rpc_url != null or
            self.checkpoint != null or
            self.checkpoint_dir != null or
            self.max_checkpoint_age_seconds != null or
            self.strict_checkpoint_age_present;
    }

    pub fn hasMiningUnit(self: Options) bool {
        return self.mining != null or self.block_time != null;
    }

    pub fn hasForkUnit(self: Options) bool {
        return self.fork_url != null or self.fork_block_number != null or self.fork_follow;
    }
};

pub fn parse(args: []const []const u8) ParseError!Options {
    var options = Options{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            options.help = true;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            options.version = true;
        } else if (std.mem.eql(u8, arg, "--config")) {
            options.config_path = try nextValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--mode")) {
            options.mode = modeFromString(try nextValue(args, &index)) orelse return error.InvalidFlagValue;
        } else if (std.mem.eql(u8, arg, "--host")) {
            options.host = try nextValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--port")) {
            options.port = try parseIntValue(u16, try nextValue(args, &index));
        } else if (std.mem.eql(u8, arg, "--engine-host")) {
            options.engine_host = try nextValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--engine-port")) {
            options.engine_port = try parseIntValue(u16, try nextValue(args, &index));
        } else if (std.mem.eql(u8, arg, "--authrpc.jwtsecret")) {
            options.engine_jwt_secret_file = try nonEmptyValue(try nextValue(args, &index));
        } else if (std.mem.eql(u8, arg, "--chain-id")) {
            options.chain_id = try parseIntValue(u64, try nextValue(args, &index));
        } else if (std.mem.eql(u8, arg, "--coinbase-index")) {
            options.coinbase_index = try parseIntValue(u8, try nextValue(args, &index));
        } else if (std.mem.eql(u8, arg, "--initial-balance")) {
            options.initial_balance = try parseIntValue(u256, try nextValue(args, &index));
        } else if (std.mem.eql(u8, arg, "--gas-price")) {
            options.gas_price = try parseIntValue(u256, try nextValue(args, &index));
        } else if (std.mem.eql(u8, arg, "--base-fee")) {
            options.base_fee = try parseIntValue(u256, try nextValue(args, &index));
        } else if (std.mem.eql(u8, arg, "--blob-base-fee")) {
            options.blob_base_fee = try parseIntValue(u256, try nextValue(args, &index));
        } else if (std.mem.eql(u8, arg, "--max-priority-fee-per-gas")) {
            options.max_priority_fee_per_gas = try parseIntValue(u256, try nextValue(args, &index));
        } else if (std.mem.eql(u8, arg, "--block-gas-limit")) {
            options.block_gas_limit = try parseIntValue(u64, try nextValue(args, &index));
        } else if (std.mem.eql(u8, arg, "--mining")) {
            options.mining = miningTypeFromString(try nextValue(args, &index)) orelse return error.InvalidFlagValue;
        } else if (std.mem.eql(u8, arg, "--block-time")) {
            options.block_time = try parseIntValue(u64, try nextValue(args, &index));
        } else if (std.mem.eql(u8, arg, "--fork-url")) {
            options.fork_url = try nextValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--fork-block-number")) {
            options.fork_block_number = try parseIntValue(u64, try nextValue(args, &index));
        } else if (std.mem.eql(u8, arg, "--fork-follow")) {
            options.fork_follow = true;
        } else if (std.mem.startsWith(u8, arg, "--fork-follow=")) {
            return error.InvalidFlagValue;
        } else if (std.mem.eql(u8, arg, "--genesis")) {
            options.genesis_alloc_path = try nextValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--chain-rlp")) {
            options.chain_rlp_path = try nextValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--execution-fixture-rpc-dir")) {
            options.execution_fixture_rpc_dir = try nonEmptyValue(try nextValue(args, &index));
        } else if (std.mem.eql(u8, arg, "--network")) {
            options.network = networkFromString(try nextValue(args, &index)) orelse return error.InvalidFlagValue;
        } else if (std.mem.eql(u8, arg, "--consensus-rpc-url")) {
            options.consensus_rpc_url = try nextValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--execution-rpc-url")) {
            options.execution_rpc_url = try nextValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--checkpoint")) {
            options.checkpoint = try parsePrefixedHash32(try nextValue(args, &index));
        } else if (std.mem.eql(u8, arg, "--checkpoint-dir")) {
            options.checkpoint_dir = try nextValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--max-checkpoint-age-seconds")) {
            options.max_checkpoint_age_seconds = try parseIntValue(u64, try nextValue(args, &index));
        } else if (std.mem.eql(u8, arg, "--strict-checkpoint-age")) {
            options.strict_checkpoint_age = true;
            options.strict_checkpoint_age_present = true;
        } else if (std.mem.startsWith(u8, arg, "--strict-checkpoint-age=")) {
            return error.InvalidFlagValue;
        } else {
            return error.UnknownArgument;
        }
    }

    return options;
}

pub const EarlyAction = enum { help, version };

/// Returns the informational action requested anywhere in `args`, so
/// `--help` and `--version` work even when other flags are invalid.
pub fn earlyAction(args: []const []const u8) ?EarlyAction {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return .help;
    }
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) return .version;
    }
    return null;
}

pub fn modeFromString(value: []const u8) ?Mode {
    if (std.mem.eql(u8, value, "trusted")) return .trusted;
    if (std.mem.eql(u8, value, "light")) return .light;
    return null;
}

pub fn networkFromString(value: []const u8) ?Network {
    if (std.mem.eql(u8, value, "mainnet")) return .mainnet;
    if (std.mem.eql(u8, value, "sepolia")) return .sepolia;
    if (std.mem.eql(u8, value, "holesky")) return .holesky;
    if (std.mem.eql(u8, value, "hoodi")) return .hoodi;
    return null;
}

pub fn networkName(network: Network) []const u8 {
    return switch (network) {
        .mainnet => "mainnet",
        .sepolia => "sepolia",
        .holesky => "holesky",
        .hoodi => "hoodi",
    };
}

pub fn miningTypeFromString(value: []const u8) ?MiningType {
    if (std.mem.eql(u8, value, "auto")) return .auto;
    if (std.mem.eql(u8, value, "manual")) return .manual;
    if (std.mem.eql(u8, value, "interval")) return .interval;
    return null;
}

pub fn parsePrefixedHash32(value: []const u8) ParseError![32]u8 {
    if (value.len != 66 or !std.mem.startsWith(u8, value, "0x")) {
        return error.InvalidFlagValue;
    }

    return parseUnprefixedHash32(value[2..]) catch return error.InvalidFlagValue;
}

pub fn parseUnprefixedHash32(value: []const u8) ParseError![32]u8 {
    if (value.len != 64) {
        return error.InvalidFlagValue;
    }

    var hash: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(hash[0..], value) catch return error.InvalidFlagValue;
    return hash;
}

fn nextValue(args: []const []const u8, index: *usize) ParseError![]const u8 {
    index.* += 1;
    if (index.* >= args.len) {
        return error.MissingFlagValue;
    }
    return args[index.*];
}

fn nonEmptyValue(value: []const u8) ParseError![]const u8 {
    if (std.mem.trim(u8, value, " \t\r\n").len == 0) return error.InvalidFlagValue;
    return value;
}

fn parseIntValue(comptime T: type, value: []const u8) ParseError!T {
    return std.fmt.parseInt(T, value, 10) catch error.InvalidFlagValue;
}
