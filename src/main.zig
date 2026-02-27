const std = @import("std");
const zevm = @import("zevm");

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    const config = try zevm.rpc.server.parseConfig(std.heap.page_allocator, args[1..]);
    var handlers = zevm.rpc.dispatcher.HandlerRegistry{};
    try zevm.rpc.server.run(std.heap.page_allocator, config, &handlers);
}
