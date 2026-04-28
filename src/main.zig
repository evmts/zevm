const std = @import("std");
const zevm = @import("zevm");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = zevm.log.logFn,
};

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    zevm.log.init(.info);

    const config = try zevm.rpc.server.parseConfig(std.heap.page_allocator, args[1..]);
    zevm.log.info(.startup, "mode selected mode=trusted", .{});
    if (config.fork_url) |fork_url| {
        if (config.fork_block_number) |fork_block_number| {
            zevm.log.info(.startup, "fork url url={s} block_number={}", .{ fork_url, fork_block_number });
        } else {
            zevm.log.info(.startup, "fork url url={s} block_number=latest", .{fork_url});
        }
    } else {
        zevm.log.info(.startup, "fork url url=null", .{});
    }

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
