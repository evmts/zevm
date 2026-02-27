pub const eth_read = @import("handlers/eth_read.zig");
pub const block_spec = @import("handlers/block_spec.zig");

test {
    _ = @import("handlers/eth_read_test.zig");
    _ = @import("handlers/block_spec_test.zig");
}
