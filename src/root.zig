const std = @import("std");
const builtin = @import("builtin");
const log_mod = @import("log.zig");

pub const is_test = builtin.is_test;

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = log_mod.logFn,
};

pub const database = @import("database/root.zig");
pub const blockchain = @import("blockchain");
pub const host_adapter = @import("host_adapter.zig");
pub const tx_processor = @import("tx_processor.zig");
pub const block_builder = @import("block_builder.zig");
pub const consensus_verifier = @import("consensus_verifier.zig");
pub const beacon_api = @import("beacon_api.zig");
pub const consensus_sync = @import("consensus_sync.zig");
pub const light_proof = @import("light_proof.zig");
pub const checkpoint = @import("checkpoint.zig");
pub const mining = @import("mining.zig");
pub const cli = @import("cli.zig");
pub const config = @import("config.zig");
pub const node_runtime = @import("node/runtime.zig");
pub const rpc = @import("rpc/root.zig");
pub const release_metadata = @import("release_metadata.zig");
pub const log = log_mod;

test {
    _ = @import("log.zig");
    _ = @import("database/root.zig");
    _ = @import("host_adapter_test.zig");
    _ = @import("tx_processor_test.zig");
    _ = @import("block_builder_test.zig");
    _ = @import("consensus_verifier_test.zig");
    _ = @import("beacon_api_test.zig");
    _ = @import("consensus_sync_test.zig");
    _ = @import("light_proof.zig");
    _ = @import("checkpoint_test.zig");
    _ = @import("mining_test.zig");
    _ = @import("cli_test.zig");
    _ = @import("config_test.zig");
    _ = @import("genesis_test.zig");
    _ = @import("log_index_test.zig");
    _ = @import("main_test.zig");
    _ = @import("node_test.zig");
    _ = @import("node/runtime_test.zig");
    _ = @import("receipt_index_test.zig");
    _ = @import("rpc/root.zig");
    _ = @import("release_metadata.zig");
}
