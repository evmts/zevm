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

    var app_config = try zevm.config.load(std.heap.page_allocator, args[1..]);
    defer app_config.deinit(std.heap.page_allocator);

    switch (app_config.mode) {
        .trusted => |trusted_config| {
            zevm.log.info(.startup, "mode selected mode=trusted", .{});
            if (trusted_config.fork) |fork| {
                if (fork.block_number) |fork_block_number| {
                    zevm.log.info(.startup, "fork url url={s} block_number={}", .{ fork.url, fork_block_number });
                } else {
                    zevm.log.info(.startup, "fork url url={s} block_number=latest", .{fork.url});
                }
            } else {
                zevm.log.info(.startup, "fork url url=null", .{});
            }

            // Runtime initialization validates startup config before the listener opens.
            var runtime = try zevm.node_runtime.NodeRuntime.init(
                std.heap.page_allocator,
                trusted_config.toNodeConfig(),
            );
            defer runtime.deinit();

            var handlers = zevm.rpc.dispatcher.HandlerRegistry{};
            zevm.rpc.dispatch_wiring.install(&handlers, &runtime);
            try zevm.rpc.server.run(std.heap.page_allocator, app_config.rpc, &handlers);
        },
        .light => |light_config| {
            zevm.log.info(.startup, "mode selected mode=light", .{});
            zevm.log.info(.startup, "light network network={s}", .{zevm.cli.networkName(light_config.network)});

            var runtime = try zevm.node_runtime.NodeRuntime.init(
                std.heap.page_allocator,
                light_config.toNodeConfig(),
            );
            defer runtime.deinit();
            try runtime.startLightSync();

            var handlers = zevm.rpc.dispatcher.HandlerRegistry{};
            zevm.rpc.dispatch_wiring.install(&handlers, &runtime);
            try zevm.rpc.server.run(std.heap.page_allocator, app_config.rpc, &handlers);
        },
    }
}
