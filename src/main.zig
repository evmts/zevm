const std = @import("std");
const builtin = @import("builtin");
const zevm = @import("zevm");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = zevm.log.logFn,
};

/// Written when `--authrpc.jwtsecret` is omitted so a consensus client can
/// reuse the same secret across restarts.
const GENERATED_JWT_SECRET_DIR = ".zevm";
const GENERATED_JWT_SECRET_PATH = ".zevm/jwtsecret";
const SHUTDOWN_POLL_NS = 100 * std.time.ns_per_ms;

var shutdown_requested = std.atomic.Value(bool).init(false);

pub fn main() !void {
    const allocator = std.heap.smp_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (zevm.cli.earlyAction(args[1..])) |action| {
        try printEarlyAction(action);
        return;
    }

    if (!zevm.log.initFromEnv(.info)) {
        zevm.log.warn(.startup, "invalid log level env={s} fallback=info", .{zevm.log.LEVEL_ENV_VAR});
    }

    var load_diagnostics = zevm.config.LoadDiagnostics{};
    var app_config = zevm.config.loadWithDiagnostics(
        allocator,
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
    defer app_config.deinit(allocator);

    installShutdownHandlers();

    const allow_dev_methods = app_config.engine_rpc == null and isLoopbackHost(app_config.rpc.host);
    switch (app_config.mode) {
        .trusted => |trusted_config| {
            zevm.log.info(.startup, "mode selected mode=trusted", .{});
            if (trusted_config.fork) |fork| {
                var url_buffer: [256]u8 = undefined;
                const safe_url = zevm.log.redactUrl(&url_buffer, fork.url);
                if (fork.block_number) |fork_block_number| {
                    zevm.log.info(.startup, "fork url url={s} block_number={}", .{ safe_url, fork_block_number });
                } else {
                    zevm.log.info(.startup, "fork url url={s} block_number=latest", .{safe_url});
                }
            } else {
                zevm.log.info(.startup, "fork url url=null", .{});
            }

            // Runtime initialization validates startup config before the listener opens.
            var runtime = zevm.node_runtime.NodeRuntime.init(
                allocator,
                trusted_config.toNodeConfig(),
            ) catch |err| exitStartupError("startup failed phase=runtime_init mode=trusted error={s}", .{@errorName(err)});
            defer runtime.deinit();
            runtime.startBackgroundServices() catch |err| exitStartupError("startup failed phase=background_services mode=trusted error={s}", .{@errorName(err)});

            var handlers = zevm.rpc.dispatcher.HandlerRegistry{};
            zevm.rpc.dispatch_wiring.install(&handlers, &runtime);

            var fixture_cache_ptr: ?*zevm.rpc.dispatch_wiring.FixtureCache = null;
            defer if (fixture_cache_ptr) |ptr| {
                ptr.deinit(allocator);
                allocator.destroy(ptr);
            };
            if (trusted_config.execution_fixture_rpc_dir) |dir| {
                fixture_cache_ptr = zevm.rpc.dispatch_wiring.loadFixtureCacheFromDir(allocator, dir) catch |err| exitStartupError("startup failed phase=fixture_rpc_cache dir={s} error={s}", .{ dir, @errorName(err) });
                if (fixture_cache_ptr) |ptr| {
                    zevm.rpc.dispatch_wiring.installFixtureCache(ptr);
                    zevm.log.info(.startup, "execution fixture RPC cache loaded dir={s} entries={}", .{ dir, ptr.entries.items.len });
                } else {
                    zevm.log.warn(.startup, "execution fixture RPC dir empty dir={s}", .{dir});
                }
            }

            var engine_jwt_secret: [zevm.config.ENGINE_JWT_SECRET_BYTES]u8 = undefined;
            defer std.crypto.secureZero(u8, &engine_jwt_secret);
            var engine_listener: ?zevm.rpc.server.RpcServer = null;
            defer if (engine_listener) |*listener| listener.deinit();

            if (app_config.engine_rpc) |engine_rpc| {
                resolveEngineJwtSecret(allocator, engine_rpc, &engine_jwt_secret) catch |err| exitStartupError("startup failed phase=engine_jwt_secret mode=trusted error={s}", .{@errorName(err)});
                const engine_cfg = engine_rpc.listener();
                engine_listener = zevm.rpc.server.RpcServer.init(
                    allocator,
                    engine_cfg,
                    &handlers,
                    .{
                        .allow_engine_methods = true,
                        .allow_dev_methods = false,
                        .jwt_secret = &engine_jwt_secret,
                        .jwt_max_time_drift_seconds = zevm.rpc.server.DEFAULT_ENGINE_JWT_MAX_TIME_DRIFT_SECONDS,
                        .max_body_bytes = zevm.rpc.server.ENGINE_MAX_BODY_BYTES,
                        .cors_allow_origin = null,
                        .validate_host = if (isLoopbackHost(engine_cfg.host)) engine_cfg.host else null,
                    },
                ) catch |err| exitStartupError("startup failed phase=engine_rpc_listener mode=trusted host={s} port={} error={s}", .{
                    engine_rpc.host,
                    engine_rpc.port,
                    @errorName(err),
                });
                engine_listener.?.start() catch |err| exitStartupError("startup failed phase=engine_rpc_listener mode=trusted host={s} port={} error={s}", .{
                    engine_rpc.host,
                    engine_rpc.port,
                    @errorName(err),
                });
            }
            servePublicRpc(allocator, app_config.rpc, &handlers, "trusted", allow_dev_methods);
        },
        .light => |light_config| {
            zevm.log.info(.startup, "mode selected mode=light", .{});
            zevm.log.info(.startup, "light network network={s}", .{zevm.cli.networkName(light_config.network)});

            var runtime = zevm.node_runtime.NodeRuntime.init(
                allocator,
                light_config.toNodeConfig(),
            ) catch |err| exitStartupError("startup failed phase=runtime_init mode=light error={s}", .{@errorName(err)});
            defer runtime.deinit();
            runtime.startBackgroundServices() catch |err| exitStartupError("startup failed phase=background_services mode=light error={s}", .{@errorName(err)});

            var handlers = zevm.rpc.dispatcher.HandlerRegistry{};
            zevm.rpc.dispatch_wiring.install(&handlers, &runtime);
            servePublicRpc(allocator, app_config.rpc, &handlers, "light", allow_dev_methods);
        },
    }
    zevm.log.info(.startup, "shutdown complete", .{});
}

/// Serves the public listener until SIGINT/SIGTERM. Returning lets the caller's
/// defers stop the engine listener and run `NodeRuntime.deinit`.
fn servePublicRpc(
    allocator: std.mem.Allocator,
    rpc_config: zevm.config.RpcConfig,
    handlers: *const zevm.rpc.dispatcher.HandlerRegistry,
    comptime mode_name: []const u8,
    allow_dev_methods: bool,
) void {
    var listener = zevm.rpc.server.RpcServer.init(allocator, rpc_config, handlers, .{
        .allow_dev_methods = allow_dev_methods,
        .validate_host = if (isLoopbackHost(rpc_config.host)) rpc_config.host else null,
    }) catch |err| exitStartupError("startup failed phase=rpc_listener mode=" ++ mode_name ++ " host={s} port={} error={s}", .{
        rpc_config.host,
        rpc_config.port,
        @errorName(err),
    });
    defer listener.deinit();

    const watcher = std.Thread.spawn(.{}, shutdownWatcher, .{&listener}) catch |err| exitStartupError("startup failed phase=shutdown_watcher mode=" ++ mode_name ++ " error={s}", .{@errorName(err)});
    defer watcher.join();

    listener.run() catch |err| exitStartupError("startup failed phase=rpc_listener mode=" ++ mode_name ++ " host={s} port={} error={s}", .{
        rpc_config.host,
        rpc_config.port,
        @errorName(err),
    });
    // Release the watcher if `run` returned for a reason other than a signal.
    listener.stop_requested.store(true, .seq_cst);
}

fn isLoopbackHost(host: []const u8) bool {
    const address = zevm.rpc.server.parseListenAddress(host, 0) catch return false;
    return switch (address.any.family) {
        std.posix.AF.INET => @as([4]u8, @bitCast(address.in.sa.addr))[0] == 127,
        std.posix.AF.INET6 => std.mem.eql(u8, &address.in6.sa.addr, &([_]u8{0} ** 15 ++ [_]u8{1})),
        else => false,
    };
}

fn shutdownWatcher(listener: *zevm.rpc.server.RpcServer) void {
    while (!shutdown_requested.load(.seq_cst)) {
        if (listener.stop_requested.load(.seq_cst)) return;
        std.Thread.sleep(SHUTDOWN_POLL_NS);
    }
    zevm.log.info(.startup, "shutdown requested reason=signal", .{});
    listener.requestShutdown();
}

/// The handler only flips an atomic; the watcher thread does the real work
/// outside signal context. A second signal exits immediately.
fn handleShutdownSignal(sig: i32) callconv(.c) void {
    _ = sig;
    if (shutdown_requested.swap(true, .seq_cst)) {
        std.posix.exit(130);
    }
}

fn installShutdownHandlers() void {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;
    const action = std.posix.Sigaction{
        .handler = .{ .handler = handleShutdownSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
    std.posix.sigaction(std.posix.SIG.TERM, &action, null);
}

/// Loads the configured or persisted JWT secret. On first startup, writes a
/// CSPRNG secret (hex, mode 0600) for the consensus client.
fn resolveEngineJwtSecret(
    allocator: std.mem.Allocator,
    engine_rpc: zevm.config.EngineRpcConfig,
    out: *[zevm.config.ENGINE_JWT_SECRET_BYTES]u8,
) !void {
    if (engine_rpc.jwt_secret_file) |path| {
        out.* = try zevm.config.loadJwtSecretFile(allocator, path);
        zevm.log.info(.startup, "engine jwt secret loaded path={s}", .{path});
        return;
    }

    if (zevm.config.loadJwtSecretFile(allocator, GENERATED_JWT_SECRET_PATH)) |secret| {
        out.* = secret;
        zevm.log.info(.startup, "engine jwt secret loaded path={s}", .{GENERATED_JWT_SECRET_PATH});
        return;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    try std.fs.cwd().makePath(GENERATED_JWT_SECRET_DIR);
    const file = try std.fs.cwd().createFile(GENERATED_JWT_SECRET_PATH, .{ .exclusive = true, .mode = 0o600 });
    errdefer std.fs.cwd().deleteFile(GENERATED_JWT_SECRET_PATH) catch {};
    defer file.close();

    std.crypto.random.bytes(out);
    var hex = std.fmt.bytesToHex(out.*, .lower);
    defer std.crypto.secureZero(u8, &hex);
    try file.writeAll(&hex);
    zevm.log.warn(.startup, "engine jwt secret generated path={s} hint=pass_--authrpc.jwtsecret_to_pin_a_secret", .{GENERATED_JWT_SECRET_PATH});
}

fn printEarlyAction(action: zevm.cli.EarlyAction) !void {
    var buffer: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buffer);
    switch (action) {
        .help => try stdout.interface.writeAll(zevm.cli.usage),
        .version => try stdout.interface.print("zevm {s}\n", .{zevm.cli.VERSION}),
    }
    try stdout.interface.flush();
}

fn exitStartupError(comptime fmt: []const u8, args: anytype) noreturn {
    zevm.log.err(.startup, fmt, args);
    std.process.exit(1);
}
