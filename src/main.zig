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

    var load_diagnostics = zevm.config.LoadDiagnostics{};
    var app_config = zevm.config.loadWithDiagnostics(
        std.heap.page_allocator,
        args[1..],
        &load_diagnostics,
    ) catch |err| {
        if (load_diagnostics.config_path) |path| {
            zevm.log.err(.startup, "config load failed path={s} failureClass={s} error={s}", .{
                path,
                load_diagnostics.failure_class.name(),
                @errorName(err),
            });
        } else {
            zevm.log.err(.startup, "config load failed failureClass={s} error={s}", .{
                load_diagnostics.failure_class.name(),
                @errorName(err),
            });
        }
        std.process.exit(1);
    };
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
            var runtime = zevm.node_runtime.NodeRuntime.init(
                std.heap.page_allocator,
                trusted_config.toNodeConfig(),
            ) catch |err| exitStartupError("startup failed phase=runtime_init mode=trusted error={s}", .{@errorName(err)});
            defer runtime.deinit();
            runtime.startBackgroundServices() catch |err| exitStartupError("startup failed phase=background_services mode=trusted error={s}", .{@errorName(err)});

            var handlers = zevm.rpc.dispatcher.HandlerRegistry{};
            zevm.rpc.dispatch_wiring.install(&handlers, &runtime);
            if (app_config.engine_rpc) |engine_rpc| {
                var engine_listener = zevm.rpc.server.RpcServer.init(
                    std.heap.page_allocator,
                    engine_rpc,
                    &handlers,
                    .{},
                ) catch |err| exitStartupError("startup failed phase=engine_rpc_listener mode=trusted host={s} port={} error={s}", .{
                    engine_rpc.host,
                    engine_rpc.port,
                    @errorName(err),
                });
                defer engine_listener.deinit();
                engine_listener.start() catch |err| exitStartupError("startup failed phase=engine_rpc_listener mode=trusted host={s} port={} error={s}", .{
                    engine_rpc.host,
                    engine_rpc.port,
                    @errorName(err),
                });
            }
            zevm.rpc.server.run(std.heap.page_allocator, app_config.rpc, &handlers) catch |err| exitStartupError("startup failed phase=rpc_listener mode=trusted host={s} port={} error={s}", .{
                app_config.rpc.host,
                app_config.rpc.port,
                @errorName(err),
            });
        },
        .light => |light_config| {
            zevm.log.info(.startup, "mode selected mode=light", .{});
            zevm.log.info(.startup, "light network network={s}", .{zevm.cli.networkName(light_config.network)});

            var runtime = zevm.node_runtime.NodeRuntime.init(
                std.heap.page_allocator,
                light_config.toNodeConfig(),
            ) catch |err| exitStartupError("startup failed phase=runtime_init mode=light error={s}", .{@errorName(err)});
            defer runtime.deinit();
            runtime.startBackgroundServices() catch |err| exitStartupError("startup failed phase=background_services mode=light error={s}", .{@errorName(err)});

            var handlers = zevm.rpc.dispatcher.HandlerRegistry{};
            zevm.rpc.dispatch_wiring.install(&handlers, &runtime);
            zevm.rpc.server.run(std.heap.page_allocator, app_config.rpc, &handlers) catch |err| exitStartupError("startup failed phase=rpc_listener mode=light host={s} port={} error={s}", .{
                app_config.rpc.host,
                app_config.rpc.port,
                @errorName(err),
            });
        },
    }
}

fn exitStartupError(comptime fmt: []const u8, args: anytype) noreturn {
    zevm.log.err(.startup, fmt, args);
    std.process.exit(1);
}
