const std = @import("std");
const builtin = @import("builtin");

pub const Config = struct {
    suite: []const u8,
    min_ms: u64 = 40,
    samples: usize = 11,
    min_iters: usize = 1,
    max_iters: usize = 2_000_000,
    filter: ?[]const u8 = null,
    json_out: ?[]const u8 = null,
    quick: bool = false,
};

pub const Metric = struct {
    name: []const u8,
    iters: usize,
    samples: usize,
    min_ns: f64,
    p50_ns: f64,
    mean_ns: f64,
    p95_ns: f64,
    p99_ns: f64,
    max_ns: f64,
    ops_per_sec: f64,
    bytes_per_op: ?u64 = null,
    gas_per_op: ?u64 = null,
};

pub const BenchOptions = struct {
    bytes_per_op: ?u64 = null,
    gas_per_op: ?u64 = null,
    warmup_iters: usize = 3,
    min_iters: ?usize = null,
    max_iters: ?usize = null,
};

pub fn parseArgs(allocator: std.mem.Allocator, default_suite: []const u8) !Config {
    var cfg = Config{ .suite = default_suite };
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // argv[0]

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--min-ms")) {
            const val = args.next() orelse return error.MissingArgValue;
            cfg.min_ms = try std.fmt.parseInt(u64, val, 10);
        } else if (std.mem.eql(u8, arg, "--samples")) {
            const val = args.next() orelse return error.MissingArgValue;
            cfg.samples = @max(1, try std.fmt.parseInt(usize, val, 10));
        } else if (std.mem.eql(u8, arg, "--filter")) {
            const val = args.next() orelse return error.MissingArgValue;
            cfg.filter = try allocator.dupe(u8, val);
        } else if (std.mem.eql(u8, arg, "--json-out")) {
            const val = args.next() orelse return error.MissingArgValue;
            cfg.json_out = try allocator.dupe(u8, val);
        } else if (std.mem.eql(u8, arg, "--suite")) {
            const val = args.next() orelse return error.MissingArgValue;
            cfg.suite = try allocator.dupe(u8, val);
        } else if (std.mem.eql(u8, arg, "--quick")) {
            cfg.quick = true;
            cfg.min_ms = 10;
            cfg.samples = 5;
        }
    }
    return cfg;
}

pub const Runner = struct {
    allocator: std.mem.Allocator,
    config: Config,
    metrics: std.ArrayListUnmanaged(Metric) = .{},

    pub fn init(allocator: std.mem.Allocator, config: Config) Runner {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *Runner) void {
        self.metrics.deinit(self.allocator);
    }

    pub fn shouldRun(self: *const Runner, name: []const u8) bool {
        if (self.config.filter) |flt| {
            return std.mem.indexOf(u8, name, flt) != null;
        }
        return true;
    }

    /// Run a benchmark function `fn (ctx: *Ctx) anyerror!void` with warmup and calibrated samples.
    pub fn run(
        self: *Runner,
        name: []const u8,
        ctx: anytype,
        comptime benchFn: anytype,
        opts: BenchOptions,
    ) !void {
        if (!self.shouldRun(name)) return;

        // Warmup
        var w: usize = 0;
        while (w < opts.warmup_iters) : (w += 1) {
            try benchFn(ctx);
        }

        const min_iters = opts.min_iters orelse self.config.min_iters;
        const max_iters = opts.max_iters orelse self.config.max_iters;
        const target_total_ns: u64 = self.config.min_ms * std.time.ns_per_ms;
        const target_sample_ns: u64 = @max(1_000_000, target_total_ns / self.config.samples);

        // Calibrate iterations per sample
        var iters_per_sample: usize = min_iters;
        while (iters_per_sample < max_iters) {
            var timer = try std.time.Timer.start();
            var i: usize = 0;
            while (i < iters_per_sample) : (i += 1) {
                try benchFn(ctx);
            }
            const elapsed = timer.read();
            if (elapsed >= target_sample_ns) break;
            if (elapsed == 0) {
                iters_per_sample = @min(max_iters, iters_per_sample * 10);
            } else {
                const scale = @max(@as(u64, 2), (target_sample_ns + elapsed - 1) / elapsed);
                const next = iters_per_sample *| @as(usize, @intCast(@min(scale, 16)));
                iters_per_sample = @min(max_iters, @max(iters_per_sample + 1, next));
            }
        }

        const sample_count = self.config.samples;
        const sample_ns = try self.allocator.alloc(f64, sample_count);
        defer self.allocator.free(sample_ns);

        var total_iters: usize = 0;
        for (0..sample_count) |s| {
            var timer = try std.time.Timer.start();
            var i: usize = 0;
            while (i < iters_per_sample) : (i += 1) {
                try benchFn(ctx);
            }
            const elapsed = timer.read();
            sample_ns[s] = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iters_per_sample));
            total_iters += iters_per_sample;
        }

        std.mem.sort(f64, sample_ns, {}, comptime std.sort.asc(f64));

        var sum: f64 = 0;
        for (sample_ns) |v| sum += v;
        const mean = sum / @as(f64, @floatFromInt(sample_count));
        const p50 = percentile(sample_ns, 0.50);
        const p95 = percentile(sample_ns, 0.95);
        const p99 = percentile(sample_ns, 0.99);
        const ops = if (p50 > 0) 1_000_000_000.0 / p50 else 0.0;

        try self.metrics.append(self.allocator, .{
            .name = name,
            .iters = total_iters,
            .samples = sample_count,
            .min_ns = sample_ns[0],
            .p50_ns = p50,
            .mean_ns = mean,
            .p95_ns = p95,
            .p99_ns = p99,
            .max_ns = sample_ns[sample_count - 1],
            .ops_per_sec = ops,
            .bytes_per_op = opts.bytes_per_op,
            .gas_per_op = opts.gas_per_op,
        });
    }

    pub fn finish(self: *const Runner) !void {
        // Print human-readable table to stdout
        var out_buf: [16 * 1024]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&out_buf);
        const w = &stdout_writer.interface;

        try w.print("\n=== Benchmark Suite: {s} ({s}, zig {s}) ===\n", .{
            self.config.suite,
            @tagName(builtin.mode),
            builtin.zig_version_string,
        });
        try w.print("{s:<44} {s:>12} {s:>12} {s:>12} {s:>12} {s:>10}\n", .{
            "Benchmark",
            "p50",
            "mean",
            "p95",
            "ops/s",
            "iters",
        });
        try w.print("{s}\n", .{"-" ** 108});

        for (self.metrics.items) |m| {
            var p50_buf: [32]u8 = undefined;
            var mean_buf: [32]u8 = undefined;
            var p95_buf: [32]u8 = undefined;
            var ops_buf: [32]u8 = undefined;
            const p50_s = formatDuration(&p50_buf, m.p50_ns);
            const mean_s = formatDuration(&mean_buf, m.mean_ns);
            const p95_s = formatDuration(&p95_buf, m.p95_ns);
            const ops_s = formatOps(&ops_buf, m.ops_per_sec);
            try w.print("{s:<44} {s:>12} {s:>12} {s:>12} {s:>12} {d:>10}", .{
                m.name,
                p50_s,
                mean_s,
                p95_s,
                ops_s,
                m.iters,
            });
            if (m.bytes_per_op) |b| {
                const mb_s = if (m.p50_ns > 0)
                    (@as(f64, @floatFromInt(b)) / (1024.0 * 1024.0)) / (m.p50_ns / 1_000_000_000.0)
                else
                    0.0;
                try w.print("  ({d:.1} MiB/s)", .{mb_s});
            }
            if (m.gas_per_op) |g| {
                const mgas_s = if (m.p50_ns > 0)
                    (@as(f64, @floatFromInt(g)) / 1_000_000.0) / (m.p50_ns / 1_000_000_000.0)
                else
                    0.0;
                try w.print("  ({d:.2} Mgas/s)", .{mgas_s});
            }
            try w.writeAll("\n");
        }
        try w.flush();

        if (self.config.json_out) |json_path| {
            try self.writeJson(json_path);
        }
    }

    fn writeJson(self: *const Runner, path: []const u8) !void {
        if (std.fs.path.dirname(path)) |dir| {
            try std.fs.cwd().makePath(dir);
        }
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();

        var buf: [16 * 1024]u8 = undefined;
        var file_writer = file.writer(&buf);
        const w = &file_writer.interface;

        try w.print(
            \\{{
            \\  "schemaVersion": "zevm-bench.v1",
            \\  "suite": "{s}",
            \\  "zigVersion": "{s}",
            \\  "optimize": "{s}",
            \\  "arch": "{s}",
            \\  "os": "{s}",
            \\  "benchmarks": [
            \\
        , .{
            self.config.suite,
            builtin.zig_version_string,
            @tagName(builtin.mode),
            @tagName(builtin.cpu.arch),
            @tagName(builtin.os.tag),
        });

        for (self.metrics.items, 0..) |m, idx| {
            try w.print(
                \\    {{
                \\      "name": "{s}",
                \\      "iters": {d},
                \\      "samples": {d},
                \\      "min_ns": {d:.2},
                \\      "p50_ns": {d:.2},
                \\      "mean_ns": {d:.2},
                \\      "p95_ns": {d:.2},
                \\      "p99_ns": {d:.2},
                \\      "max_ns": {d:.2},
                \\      "ops_per_sec": {d:.2}
            , .{
                m.name,
                m.iters,
                m.samples,
                m.min_ns,
                m.p50_ns,
                m.mean_ns,
                m.p95_ns,
                m.p99_ns,
                m.max_ns,
                m.ops_per_sec,
            });
            if (m.bytes_per_op) |b| {
                try w.print(",\n      \"bytes_per_op\": {d}", .{b});
            }
            if (m.gas_per_op) |g| {
                try w.print(",\n      \"gas_per_op\": {d}", .{g});
            }
            if (idx + 1 < self.metrics.items.len) {
                try w.writeAll("\n    },\n");
            } else {
                try w.writeAll("\n    }\n");
            }
        }

        try w.writeAll("  ]\n}\n");
        try w.flush();
    }
};

fn percentile(sorted: []const f64, q: f64) f64 {
    if (sorted.len == 0) return 0;
    if (sorted.len == 1) return sorted[0];
    const pos = q * @as(f64, @floatFromInt(sorted.len - 1));
    const lo: usize = @intFromFloat(@floor(pos));
    const hi: usize = @min(sorted.len - 1, lo + 1);
    const frac = pos - @as(f64, @floatFromInt(lo));
    return sorted[lo] * (1.0 - frac) + sorted[hi] * frac;
}

fn formatDuration(buf: []u8, ns: f64) []const u8 {
    if (ns >= 1_000_000_000.0) {
        return std.fmt.bufPrint(buf, "{d:.3} s", .{ns / 1_000_000_000.0}) catch "?";
    } else if (ns >= 1_000_000.0) {
        return std.fmt.bufPrint(buf, "{d:.3} ms", .{ns / 1_000_000.0}) catch "?";
    } else if (ns >= 1_000.0) {
        return std.fmt.bufPrint(buf, "{d:.2} us", .{ns / 1_000.0}) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d:.1} ns", .{ns}) catch "?";
    }
}

fn formatOps(buf: []u8, ops: f64) []const u8 {
    if (ops >= 1_000_000.0) {
        return std.fmt.bufPrint(buf, "{d:.2}M/s", .{ops / 1_000_000.0}) catch "?";
    } else if (ops >= 1_000.0) {
        return std.fmt.bufPrint(buf, "{d:.2}K/s", .{ops / 1_000.0}) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d:.1}/s", .{ops}) catch "?";
    }
}
