const state_manager = @import("state-manager");
const blockchain = @import("blockchain");

pub const RpcConfig = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8545,
    cors_enabled: bool = true,
};

pub const Node = struct {
    state_manager: *state_manager.StateManager,
    blockchain: *blockchain.Blockchain,
    rpc_config: RpcConfig,
    chain_id: u64,
};
