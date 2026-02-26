pub const Database = @import("database.zig").Database;
pub const Accounts = @import("accounts.zig").Accounts;
pub const Contracts = @import("contracts.zig").Contracts;
pub const BlockHashes = @import("block_hashes.zig").BlockHashes;

test {
    _ = @import("database_test.zig");
}
