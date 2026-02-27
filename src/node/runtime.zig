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

pub const NodeConfig = struct {
    chain_id: u64 = DEFAULT_CHAIN_ID,
    coinbase_index: u8 = 0,
    initial_balance: u256 = DEFAULT_BALANCE,
    gas_price: u256 = DEFAULT_GAS_PRICE,
    base_fee: u256 = DEFAULT_BASE_FEE,
    blob_base_fee: u256 = DEFAULT_BLOB_BASE_FEE,
    max_priority_fee: u256 = DEFAULT_MAX_PRIORITY_FEE,
    mining_config: mining.MiningConfig = mining.MiningConfig.default(),
};

pub const NodeRuntime = struct {
    chain_id: u64,
    coinbase: primitives.Address,
    head_block_number: u64,
    gas_price: u256,
    base_fee: u256,
    blob_base_fee: u256,
    max_priority_fee: u256,
    mining_config: mining.MiningConfig,
    state: state_manager.StateManager,

    pub fn init(allocator: std.mem.Allocator, config_opt: ?NodeConfig) !NodeRuntime {
        const config = config_opt orelse NodeConfig{};

        var state = try state_manager.StateManager.init(allocator, null);
        errdefer state.deinit();

        // Seed dev accounts with initial balance
        for (&DEFAULT_DEV_ACCOUNTS) |addr| {
            try state.setBalance(addr, config.initial_balance);
        }

        return .{
            .chain_id = config.chain_id,
            .coinbase = DEFAULT_DEV_ACCOUNTS[config.coinbase_index],
            .head_block_number = 0,
            .gas_price = config.gas_price,
            .base_fee = config.base_fee,
            .blob_base_fee = config.blob_base_fee,
            .max_priority_fee = config.max_priority_fee,
            .mining_config = config.mining_config,
            .state = state,
        };
    }

    pub fn setMiningConfig(self: *NodeRuntime, config: mining.MiningConfig) void {
        self.mining_config = config;
    }

    pub fn deinit(self: *NodeRuntime) void {
        self.state.deinit();
    }
};

fn parseAddr(comptime hex: *const [42]u8) primitives.Address {
    var out: [20]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex[2..]) catch unreachable;
    return .{ .bytes = out };
}
