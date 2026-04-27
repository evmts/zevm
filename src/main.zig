const std = @import("std");
const zevm = @import("zevm");

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    const config = try zevm.rpc.server.parseConfig(std.heap.page_allocator, args[1..]);

    // Bootstrap trusted runtime so startup configuration (including fork config)
    // is validated and initialized before opening the RPC listener.
    var runtime = try zevm.node_runtime.NodeRuntime.init(std.heap.page_allocator, .{
        .fork_url = config.fork_url,
        .fork_block_number = config.fork_block_number,
    });
    defer runtime.deinit();

    var handlers = zevm.rpc.dispatcher.HandlerRegistry{};
    zevm.rpc.dispatch_wiring.install(&handlers, &runtime);
    try zevm.rpc.server.run(std.heap.page_allocator, config, &handlers);
}
