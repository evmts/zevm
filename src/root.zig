pub const database = @import("database/root.zig");
pub const blockchain = @import("blockchain");
pub const host_adapter = @import("host_adapter.zig");
pub const tx_processor = @import("tx_processor.zig");
pub const block_builder = @import("block_builder.zig");
pub const consensus_verifier = @import("consensus_verifier.zig");
pub const beacon_api = @import("beacon_api.zig");
pub const consensus_sync = @import("consensus_sync.zig");
pub const checkpoint = @import("checkpoint.zig");
pub const rpc_server = @import("rpc_server.zig");
pub const node_runtime = @import("node/runtime.zig");
pub const rpc = @import("rpc/root.zig");

test {
    _ = @import("database/root.zig");
    _ = @import("host_adapter_test.zig");
    _ = @import("tx_processor_test.zig");
    _ = @import("block_builder_test.zig");
    _ = @import("consensus_verifier_test.zig");
    _ = @import("beacon_api_test.zig");
    _ = @import("consensus_sync_test.zig");
    _ = @import("checkpoint_test.zig");
    _ = @import("rpc_server_test.zig");
    _ = @import("node/runtime_test.zig");
    _ = @import("rpc/root.zig");
}

test "rpc_server module is reachable from root test build" {
    _ = rpc_server;
}
