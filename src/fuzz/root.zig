const std = @import("std");

// Keep fuzz test output quiet so high-throughput coverage-guided runs are not
// bottlenecked on stderr logging.
pub const std_options: std.Options = .{
    .log_level = .err,
};

test {
    _ = @import("blob_fee_fuzz_test.zig");
    _ = @import("block_chain_import_prop_test.zig");
    _ = @import("config_cli_genesis_fuzz_test.zig");
    _ = @import("engine_api_fuzz_test.zig");
    _ = @import("light_consensus_fuzz_test.zig");
    _ = @import("mpt_kzg_fixture_fuzz_test.zig");
    _ = @import("node_runtime_rpc_stateful_fuzz_test.zig");
    _ = @import("rpc_parse_transport_fuzz_test.zig");
    _ = @import("simulation_metamorphic_fuzz_test.zig");
    _ = @import("state_db_snapshot_prop_test.zig");
    _ = @import("tx_encoding_fuzz_test.zig");
    _ = @import("tx_processor_prop_test.zig");
    _ = @import("txpool_receipt_log_prop_test.zig");
}
