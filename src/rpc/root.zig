pub const dispatcher = @import("dispatcher.zig");
pub const dispatch_wiring = @import("dispatch_wiring.zig");
pub const server = @import("server.zig");
pub const parse = @import("parse.zig");
pub const block_queries = @import("block_queries.zig");
pub const trusted_fork_handlers = @import("trusted_fork_handlers.zig");
pub const simulation = @import("handlers/simulation.zig");
pub const txpool = @import("handlers/txpool.zig");
pub const dev_erc20_handlers = @import("handlers/dev_erc20.zig");

test {
    _ = @import("block_queries_test.zig");
    _ = @import("dispatcher_test.zig");
    _ = @import("dispatch_wiring_test.zig");
    _ = @import("listener_smoke_test.zig");
    _ = @import("server_test.zig");
    _ = @import("parse.zig");
    _ = @import("trusted_fork_handlers.zig");
    _ = @import("handlers/block_query_handlers_test.zig");
    _ = @import("handlers/block_spec_test.zig");
    _ = @import("handlers/eth_read_test.zig");
    _ = @import("handlers/simulation_test.zig");
    _ = @import("handlers/tx_submission_test.zig");
    _ = @import("handlers/txpool_test.zig");
    _ = @import("handlers/dev_erc20_test.zig");
}
