const std = @import("std");
const zevm = @import("zevm");
const harness = @import("harness");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cfg = try harness.parseArgs(allocator, "config-cli-log");
    var runner = harness.Runner.init(allocator, cfg);
    defer runner.deinit();

    // 1. CLI parsing & config loading
    {
        const dev_args = [_][]const u8{
            "--mode", "trusted", "--port", "8545", "--chain-id", "31337",
        };
        const light_args = [_][]const u8{
            "--mode",
            "light",
            "--network",
            "mainnet",
            "--consensus-rpc-url",
            "https://beacon.example.invalid",
            "--execution-rpc-url",
            "https://exec.example.invalid",
        };

        const Ctx = struct {
            allocator: std.mem.Allocator,
            dev_args: []const []const u8,
            light_args: []const []const u8,
        };
        var ctx = Ctx{
            .allocator = allocator,
            .dev_args = &dev_args,
            .light_args = &light_args,
        };

        try runner.run("cli/parse_dev_args", &ctx, struct {
            fn f(c: *Ctx) !void {
                const opts = try zevm.cli.parse(c.dev_args);
                std.mem.doNotOptimizeAway(&opts);
            }
        }.f, .{});

        try runner.run("cli/parse_light_args", &ctx, struct {
            fn f(c: *Ctx) !void {
                const opts = try zevm.cli.parse(c.light_args);
                std.mem.doNotOptimizeAway(&opts);
            }
        }.f, .{});

        try runner.run("config/load_dev_defaults", &ctx, struct {
            fn f(c: *Ctx) !void {
                var app_cfg = try zevm.config.load(c.allocator, c.dev_args);
                defer app_cfg.deinit(c.allocator);
                std.mem.doNotOptimizeAway(&app_cfg.rpc.port);
            }
        }.f, .{});
    }

    // 2. Logging (level-filtered fast path)
    {
        zevm.log.init(.err);
        const Ctx = struct { counter: u64 = 0 };
        var ctx = Ctx{};
        try runner.run("log/filtered_info_noop", &ctx, struct {
            fn f(c: *Ctx) !void {
                c.counter +%= 1;
                zevm.log.info(.bench, "tx processed nonce={d}", .{c.counter});
                std.mem.doNotOptimizeAway(&c.counter);
            }
        }.f, .{});
    }

    try runner.finish();
}
