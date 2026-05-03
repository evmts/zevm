pub const Database = @import("database.zig").Database;
pub const Accounts = @import("accounts.zig").Accounts;
pub const Contracts = @import("contracts.zig").Contracts;

test {
    _ = @import("database_test.zig");
}
