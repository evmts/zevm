pub const database = @import("database/root.zig");
pub const blockchain = @import("blockchain");
pub const Database = database.Database;
pub const Accounts = database.Accounts;
pub const Contracts = database.Contracts;
pub const BlockHashes = database.BlockHashes;
pub const HostAdapter = @import("host_adapter.zig").HostAdapter;
pub const TxProcessor = @import("tx_processor.zig");
pub const BlockBuilder = @import("block_builder.zig");

test {
    _ = @import("database/root.zig");
    _ = @import("host_adapter_test.zig");
    _ = @import("tx_processor_test.zig");
    _ = @import("block_builder_test.zig");
}
