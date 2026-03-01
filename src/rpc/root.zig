pub const dispatcher = @import("dispatcher.zig");
pub const server = @import("server.zig");
pub const eth_handler = @import("eth_handler.zig");
pub const node_handler = @import("node_handler.zig");
pub const block_queries = @import("block_queries.zig");
pub const dev_runtime = @import("dev_runtime.zig");
pub const dev_handlers = @import("dev_handlers.zig");
pub const handlers = @import("handlers.zig");

test {
    _ = @import("dispatcher_test.zig");
    _ = @import("server_test.zig");
    _ = @import("eth_handler_test.zig");
    _ = @import("node_handler_test.zig");
    _ = @import("block_queries_test.zig");
    _ = @import("handlers/block_spec_test.zig");
    _ = @import("handlers/eth_read_test.zig");
    _ = @import("handlers/tx_submission_test.zig");
    _ = @import("handlers/block_query_handlers_test.zig");
}
