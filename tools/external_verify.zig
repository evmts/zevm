const std = @import("std");
const builtin = @import("builtin");
const primitives = @import("primitives");
const state_manager = @import("state-manager");
const guillotine_mini = @import("guillotine_mini");
const zevm = @import("zevm");
const rlp_tests = @import("rlp_tests");

const VerifyError = error{
    MissingArgument,
    InvalidArgument,
    MissingField,
    InvalidFixture,
    InvalidAddress,
    InvalidQuantity,
    InvalidHexData,
    UnexpectedState,
    UnexpectedGasUsed,
    UnexpectedTransactionResult,
    UnexpectedRpcResponse,
    RpcSmokeFailed,
    LatestForkStateRegression,
};

const execution_spec_state_fixture_paths = [_][]const u8{
    "lib/execution-spec-tests/src/ethereum_test_specs/tests/fixtures/chainid_paris_state_test_tx_type_0.json",
    "lib/execution-spec-tests/src/ethereum_test_specs/tests/fixtures/chainid_cancun_state_test_tx_type_0.json",
    "lib/execution-spec-tests/src/ethereum_test_specs/tests/fixtures/chainid_cancun_state_test_tx_type_1.json",
    "lib/execution-spec-tests/src/ethereum_test_specs/tests/fixtures/chainid_shanghai_state_test_tx_type_0.json",
};

const execution_spec_blockchain_fixture_paths = [_][]const u8{
    "lib/execution-spec-tests/src/ethereum_test_specs/tests/fixtures/blockchain_london_invalid_filled.json",
    "lib/execution-spec-tests/src/ethereum_test_specs/tests/fixtures/blockchain_london_valid_filled.json",
    "lib/execution-spec-tests/src/ethereum_test_specs/tests/fixtures/blockchain_shanghai_invalid_filled_engine.json",
    "lib/execution-spec-tests/src/ethereum_test_specs/tests/fixtures/blockchain_shanghai_valid_filled_engine.json",
    "lib/execution-spec-tests/src/ethereum_test_specs/tests/fixtures/chainid_cancun_blockchain_test_engine_tx_type_0.json",
    "lib/execution-spec-tests/src/ethereum_test_specs/tests/fixtures/chainid_cancun_blockchain_test_tx_type_0.json",
    "lib/execution-spec-tests/src/ethereum_test_specs/tests/fixtures/chainid_istanbul_blockchain_test_tx_type_0.json",
    "lib/execution-spec-tests/src/ethereum_test_specs/tests/fixtures/chainid_london_blockchain_test_tx_type_0.json",
    "lib/execution-spec-tests/src/ethereum_test_specs/tests/fixtures/chainid_paris_blockchain_test_engine_tx_type_0.json",
    "lib/execution-spec-tests/src/ethereum_test_specs/tests/fixtures/chainid_shanghai_blockchain_test_engine_tx_type_0.json",
};

const legacy_state_fixture_dirs = [_][]const u8{
    "lib/ethereum-tests/LegacyTests/Cancun/GeneralStateTests/stArgsZeroOneBalance",
    "lib/ethereum-tests/LegacyTests/Cancun/GeneralStateTests/stAttackTest",
    "lib/ethereum-tests/LegacyTests/Cancun/GeneralStateTests/stBugs",
    "lib/ethereum-tests/LegacyTests/Cancun/GeneralStateTests/stCallCodes",
    "lib/ethereum-tests/LegacyTests/Cancun/GeneralStateTests/stChainId",
    "lib/ethereum-tests/LegacyTests/Cancun/GeneralStateTests/stCodeCopyTest",
    "lib/ethereum-tests/LegacyTests/Cancun/GeneralStateTests/stCodeSizeLimit",
    "lib/ethereum-tests/LegacyTests/Cancun/GeneralStateTests/stEIP150Specific",
    "lib/ethereum-tests/LegacyTests/Cancun/GeneralStateTests/stEIP1559",
    "lib/ethereum-tests/LegacyTests/Cancun/GeneralStateTests/stEIP158Specific",
    "lib/ethereum-tests/LegacyTests/Cancun/GeneralStateTests/stEIP2930",
    "lib/ethereum-tests/LegacyTests/Cancun/GeneralStateTests/stEIP3607",
    "lib/ethereum-tests/LegacyTests/Cancun/GeneralStateTests/stExample",
    "lib/ethereum-tests/LegacyTests/Cancun/GeneralStateTests/stHomesteadSpecific",
    "lib/ethereum-tests/LegacyTests/Cancun/GeneralStateTests/stLogTests",
    "lib/ethereum-tests/LegacyTests/Cancun/GeneralStateTests/stMemExpandingEIP150Calls",
    "lib/ethereum-tests/LegacyTests/Cancun/GeneralStateTests/stPreCompiledContracts",
    "lib/ethereum-tests/LegacyTests/Cancun/GeneralStateTests/stRecursiveCreate",
    "lib/ethereum-tests/LegacyTests/Cancun/GeneralStateTests/stSLoadTest",
    "lib/ethereum-tests/LegacyTests/Cancun/GeneralStateTests/stSelfBalance",
    "lib/ethereum-tests/LegacyTests/Cancun/GeneralStateTests/stShift",
    "lib/ethereum-tests/LegacyTests/Cancun/GeneralStateTests/stStackTests",
    "lib/ethereum-tests/LegacyTests/Cancun/GeneralStateTests/stStaticFlagEnabled",
    "lib/ethereum-tests/LegacyTests/Cancun/GeneralStateTests/stTransitionTest",
};

const hive_rpc_head_forkchoice_path = "lib/execution-apis/tests/headfcu.json";

const legacy_state_root = "lib/ethereum-tests/LegacyTests/Cancun/GeneralStateTests/";
const mid_fork_state_dirs = [_][]const u8{
    legacy_state_root ++ "stEIP150singleCodeGasPrices",
    legacy_state_root ++ "stEIP2930",
    legacy_state_root ++ "Shanghai/stEIP3651-warmcoinbase",
    legacy_state_root ++ "Shanghai/stEIP3855-push0",
    legacy_state_root ++ "Shanghai/stEIP3860-limitmeterinitcode",
    legacy_state_root ++ "Pyspecs/berlin/eip2930_access_list",
    legacy_state_root ++ "Pyspecs/shanghai/eip3651_warm_coinbase",
    legacy_state_root ++ "Pyspecs/shanghai/eip3855_push0",
    legacy_state_root ++ "Pyspecs/shanghai/eip3860_initcode",
};

// External fixture expansion remains tracked by release-readiness tickets:
// state/block fixture discovery, broader legacy-state coverage, and the
// non-rpc Hive simulator coverage are not complete yet.

const VerifyOptions = struct {
    shard_index: usize = 0,
    shard_total: usize = 1,
    timeout_seconds: u64 = 30,
    progress_every: usize = 100,
    match: ?[]const u8 = null,
    extra_legacy_state_dir: ?[]const u8 = null,
    dump_state_on_mismatch: bool = false,
    latest_fork_state: bool = false,
    latest_fork_state_archive: []const u8 = latest_fork_state_archive_path,
    latest_fork_state_baseline: []const u8 = latest_fork_state_baseline_path,
};

const ProgressState = struct {
    discovered: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    selected: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    skipped: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    unsupported: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    completed: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    failed: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    task_started_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    task_sequence: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    mutex: std.Thread.Mutex = .{},
    current_task: [1024]u8 = [_]u8{0} ** 1024,
    current_task_len: usize = 0,

    fn setCurrentTask(self: *ProgressState, label: []const u8, started_ns: u64) void {
        self.mutex.lock();
        const len = @min(label.len, self.current_task.len);
        @memcpy(self.current_task[0..len], label[0..len]);
        self.current_task_len = len;
        self.mutex.unlock();
        self.task_started_ns.store(started_ns, .release);
        _ = self.task_sequence.fetchAdd(1, .release);
    }

    fn clearCurrentTask(self: *ProgressState) void {
        self.task_started_ns.store(0, .release);
        self.mutex.lock();
        self.current_task_len = 0;
        self.mutex.unlock();
    }

    fn copyCurrentTask(self: *ProgressState, buffer: []u8) []const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const len = @min(self.current_task_len, buffer.len);
        @memcpy(buffer[0..len], self.current_task[0..len]);
        return buffer[0..len];
    }
};

// These are names from the post map. ConstantinopleFix is Petersburg.
const EarlyFork = enum { Frontier, Homestead, Byzantium, Constantinople, Istanbul };
const ForkCounts = struct { discovered: usize = 0, passed: usize = 0, failed: usize = 0 };
const EarlyCounts = std.EnumArray(EarlyFork, ForkCounts);

const VerifyContext = struct {
    options: VerifyOptions,
    early_counts: ?*EarlyCounts = null,
    progress: *ProgressState,
    timer: *std.time.Timer,
    mid_forks_only: bool,
    state_counts: std.EnumArray(guillotine_mini.Hardfork, struct { passed: usize = 0, failed: usize = 0 }) = .initFill(.{}),

    fn claimTask(self: *VerifyContext, label: []const u8) ?usize {
        if (!self.matchesLabel(label)) return null;
        const zero_based = self.progress.discovered.fetchAdd(1, .monotonic);
        if (zero_based % self.options.shard_total != self.options.shard_index) {
            _ = self.progress.skipped.fetchAdd(1, .monotonic);
            return null;
        }
        _ = self.progress.selected.fetchAdd(1, .monotonic);
        return zero_based + 1;
    }

    fn matchesLabel(self: *const VerifyContext, label: []const u8) bool {
        const pattern = self.options.match orelse return true;
        return std.mem.indexOf(u8, label, pattern) != null;
    }

    fn startTask(self: *VerifyContext, task_id: usize, suite: []const u8, label: []const u8) u64 {
        const started_ns = self.timer.read();
        self.progress.setCurrentTask(label, monotonicNowNs());
        if ((task_id - 1) % self.options.progress_every == 0) {
            std.debug.print("external-verify: start #{d} suite={s} fixture=\"{s}\"\n", .{ task_id, suite, label });
        }
        return started_ns;
    }

    fn finishTask(self: *VerifyContext, task_id: usize, suite: []const u8, started_ns: u64) void {
        const elapsed_ms = (self.timer.read() - started_ns) / std.time.ns_per_ms;
        _ = self.progress.completed.fetchAdd(1, .monotonic);
        if ((task_id - 1) % self.options.progress_every == 0) {
            std.debug.print("external-verify: ok #{d} suite={s} elapsed_ms={d}\n", .{ task_id, suite, elapsed_ms });
        }
        self.progress.clearCurrentTask();
    }

    fn skipTask(self: *VerifyContext, task_id: usize, suite: []const u8, label: []const u8, reason: []const u8) void {
        _ = self.progress.unsupported.fetchAdd(1, .monotonic);
        if ((task_id - 1) % self.options.progress_every == 0) {
            std.debug.print("external-verify: skip #{d} suite={s} fixture=\"{s}\" reason=\"{s}\"\n", .{ task_id, suite, label, reason });
        }
    }

    fn failTask(self: *VerifyContext, task_id: usize, suite: []const u8, label: []const u8, started_ns: u64, err: anyerror) void {
        const elapsed_ms = (self.timer.read() - started_ns) / std.time.ns_per_ms;
        _ = self.progress.failed.fetchAdd(1, .monotonic);
        std.debug.print("external-verify: FAIL #{d} suite={s} fixture=\"{s}\" elapsed_ms={d} error={s}\n", .{ task_id, suite, label, elapsed_ms, @errorName(err) });
        printMemoryDiagnostics("external-verify: failure diagnostics", null);
        self.progress.clearCurrentTask();
    }
};

fn parseVerifyOptions(allocator: std.mem.Allocator, args: []const []const u8) !VerifyOptions {
    var options = VerifyOptions{};

    if (try envOwned(allocator, "ZEVM_VERIFY_SHARD")) |value| {
        defer allocator.free(value);
        try parseShard(value, &options);
    }
    if (try envOwned(allocator, "ZEVM_VERIFY_SHARD_INDEX")) |value| {
        defer allocator.free(value);
        options.shard_index = try parseUsizeText(value);
    }
    if (try envOwned(allocator, "ZEVM_VERIFY_SHARD_TOTAL")) |value| {
        defer allocator.free(value);
        options.shard_total = try parseUsizeText(value);
    }
    if (try envOwned(allocator, "ZEVM_VERIFY_TIMEOUT_SECONDS")) |value| {
        defer allocator.free(value);
        options.timeout_seconds = try parseU64Text(value);
    }
    if (try envOwned(allocator, "ZEVM_VERIFY_PROGRESS_EVERY")) |value| {
        defer allocator.free(value);
        options.progress_every = try parseUsizeText(value);
    }

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--shard")) {
            index += 1;
            if (index >= args.len) return VerifyError.MissingArgument;
            try parseShard(args[index], &options);
        } else if (std.mem.startsWith(u8, arg, "--shard=")) {
            try parseShard(arg["--shard=".len..], &options);
        } else if (std.mem.eql(u8, arg, "--shard-index")) {
            index += 1;
            if (index >= args.len) return VerifyError.MissingArgument;
            options.shard_index = try parseUsizeText(args[index]);
        } else if (std.mem.startsWith(u8, arg, "--shard-index=")) {
            options.shard_index = try parseUsizeText(arg["--shard-index=".len..]);
        } else if (std.mem.eql(u8, arg, "--shard-total")) {
            index += 1;
            if (index >= args.len) return VerifyError.MissingArgument;
            options.shard_total = try parseUsizeText(args[index]);
        } else if (std.mem.startsWith(u8, arg, "--shard-total=")) {
            options.shard_total = try parseUsizeText(arg["--shard-total=".len..]);
        } else if (std.mem.eql(u8, arg, "--timeout-seconds")) {
            index += 1;
            if (index >= args.len) return VerifyError.MissingArgument;
            options.timeout_seconds = try parseU64Text(args[index]);
        } else if (std.mem.startsWith(u8, arg, "--timeout-seconds=")) {
            options.timeout_seconds = try parseU64Text(arg["--timeout-seconds=".len..]);
        } else if (std.mem.eql(u8, arg, "--progress-every")) {
            index += 1;
            if (index >= args.len) return VerifyError.MissingArgument;
            options.progress_every = try parseUsizeText(args[index]);
        } else if (std.mem.startsWith(u8, arg, "--progress-every=")) {
            options.progress_every = try parseUsizeText(arg["--progress-every=".len..]);
        } else if (std.mem.eql(u8, arg, "--match")) {
            index += 1;
            if (index >= args.len) return VerifyError.MissingArgument;
            options.match = args[index];
        } else if (std.mem.startsWith(u8, arg, "--match=")) {
            options.match = arg["--match=".len..];
        } else if (std.mem.eql(u8, arg, "--legacy-state-dir")) {
            index += 1;
            if (index >= args.len) return VerifyError.MissingArgument;
            options.extra_legacy_state_dir = args[index];
        } else if (std.mem.startsWith(u8, arg, "--legacy-state-dir=")) {
            options.extra_legacy_state_dir = arg["--legacy-state-dir=".len..];
        } else if (std.mem.eql(u8, arg, "--dump-state-on-mismatch")) {
            options.dump_state_on_mismatch = true;
        } else if (std.mem.eql(u8, arg, "--latest-fork-state")) {
            options.latest_fork_state = true;
        } else if (std.mem.startsWith(u8, arg, "--latest-fork-state-archive=")) {
            options.latest_fork_state_archive = arg["--latest-fork-state-archive=".len..];
        } else if (std.mem.startsWith(u8, arg, "--latest-fork-state-baseline=")) {
            options.latest_fork_state_baseline = arg["--latest-fork-state-baseline=".len..];
        } else {
            return VerifyError.InvalidArgument;
        }
    }

    if (options.shard_total == 0 or options.shard_index >= options.shard_total or options.progress_every == 0) {
        return VerifyError.InvalidArgument;
    }
    return options;
}

fn envOwned(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => err,
    };
}

fn parseShard(text: []const u8, options: *VerifyOptions) !void {
    const slash = std.mem.indexOfScalar(u8, text, '/') orelse return VerifyError.InvalidArgument;
    options.shard_index = try parseUsizeText(text[0..slash]);
    options.shard_total = try parseUsizeText(text[slash + 1 ..]);
}

fn parseUsizeText(text: []const u8) !usize {
    if (text.len == 0) return VerifyError.InvalidArgument;
    return std.fmt.parseInt(usize, text, 10) catch VerifyError.InvalidArgument;
}

fn parseU64Text(text: []const u8) !u64 {
    if (text.len == 0) return VerifyError.InvalidArgument;
    return std.fmt.parseInt(u64, text, 10) catch VerifyError.InvalidArgument;
}

fn watchdogMain(progress: *ProgressState, timeout_ns: u64) void {
    if (timeout_ns == 0) return;

    var last_reported_sequence: u64 = std.math.maxInt(u64);
    while (!progress.done.load(.acquire)) {
        std.Thread.sleep(@min(timeout_ns, 5 * std.time.ns_per_s));

        const started_ns = progress.task_started_ns.load(.acquire);
        if (started_ns == 0) continue;
        const now_u64 = monotonicNowNs();
        if (now_u64 < started_ns or now_u64 - started_ns < timeout_ns) continue;

        const sequence = progress.task_sequence.load(.acquire);
        if (sequence == last_reported_sequence) continue;
        last_reported_sequence = sequence;

        var task_buffer: [1024]u8 = undefined;
        const task = progress.copyCurrentTask(&task_buffer);
        const elapsed_ms = (now_u64 - started_ns) / std.time.ns_per_ms;
        std.debug.print("external-verify: timeout diagnostic elapsed_ms={d} fixture=\"{s}\"\n", .{ elapsed_ms, task });
        printMemoryDiagnostics("external-verify: timeout diagnostics", null);
    }
}

fn monotonicNowNs() u64 {
    const now_ns = std.time.nanoTimestamp();
    return if (now_ns < 0) 0 else @intCast(now_ns);
}

fn printMemoryDiagnostics(prefix: []const u8, active_alloc_bytes: ?usize) void {
    const usage = std.posix.getrusage(std.posix.rusage.SELF);
    const max_rss_mib = maxResidentSetBytes(usage.maxrss) / (1024 * 1024);
    if (active_alloc_bytes) |bytes| {
        std.debug.print("{s}: max_rss_mib={d} active_alloc_mib={d} major_faults={d} involuntary_ctx_switches={d}\n", .{
            prefix,
            max_rss_mib,
            bytes / (1024 * 1024),
            usage.majflt,
            usage.nivcsw,
        });
    } else {
        std.debug.print("{s}: max_rss_mib={d} major_faults={d} involuntary_ctx_switches={d}\n", .{
            prefix,
            max_rss_mib,
            usage.majflt,
            usage.nivcsw,
        });
    }
}

fn maxResidentSetBytes(raw: isize) u64 {
    if (raw <= 0) return 0;
    const value: u64 = @intCast(raw);
    return switch (builtin.os.tag) {
        .linux => value * 1024,
        else => value,
    };
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{
        .stack_trace_frames = 0,
        .enable_memory_limit = true,
        .thread_safe = false,
    }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 3) return VerifyError.MissingArgument;

    const repo_root = args[1];
    const options = try parseVerifyOptions(allocator, args[3..]);

    var timer = try std.time.Timer.start();
    var progress = ProgressState{};
    var ctx = VerifyContext{
        .options = options,
        .progress = &progress,
        .timer = &timer,
        .mid_forks_only = std.mem.eql(u8, args[2], "--mid-forks"),
    };
    defer for (std.enums.values(guillotine_mini.Hardfork)) |fork| {
        const counts = ctx.state_counts.get(fork);
        if (counts.passed + counts.failed > 0 or (ctx.mid_forks_only and (fork == .BERLIN or fork == .SHANGHAI))) {
            std.debug.print("external-verify: legacy-state fork={s} passed={d} failed={d}\n", .{ fork.toString(), counts.passed, counts.failed });
        }
    };

    std.debug.print("external-verify: start shard={d}/{d} timeout_seconds={d} progress_every={d}\n", .{
        options.shard_index,
        options.shard_total,
        options.timeout_seconds,
        options.progress_every,
    });
    if (options.match) |pattern| {
        std.debug.print("external-verify: match=\"{s}\"\n", .{pattern});
    }
    if (options.extra_legacy_state_dir) |relative_path| {
        std.debug.print("external-verify: extra_legacy_state_dir=\"{s}\"\n", .{relative_path});
    }
    if (options.dump_state_on_mismatch) {
        std.debug.print("external-verify: dump_state_on_mismatch=true\n", .{});
    }

    const timeout_ns = options.timeout_seconds * std.time.ns_per_s;
    const watchdog = try std.Thread.spawn(.{}, watchdogMain, .{ &progress, timeout_ns });
    defer watchdog.join();
    defer progress.done.store(true, .release);

    const verification = if (options.latest_fork_state)
        runLatestForkStateReport(allocator, repo_root, &ctx)
    else if (std.mem.eql(u8, args[2], "--early-state"))
        runEarlyStateFixtures(allocator, repo_root, &ctx)
    else if (ctx.mid_forks_only)
        runMidForkStateFixtures(allocator, repo_root, &ctx)
    else
        runExternalVerify(allocator, repo_root, args[2], &ctx);
    verification catch |err| {
        var task_buffer: [1024]u8 = undefined;
        const current = progress.copyCurrentTask(&task_buffer);
        std.debug.print("external-verify: failed error={s} elapsed_ms={d} current=\"{s}\"\n", .{
            @errorName(err),
            timer.read() / std.time.ns_per_ms,
            current,
        });
        printMemoryDiagnostics("external-verify: final diagnostics", gpa.total_requested_bytes);
        return err;
    };

    if (options.match != null and progress.selected.load(.monotonic) == 0) return VerifyError.InvalidFixture;

    progress.done.store(true, .release);
    std.debug.print("external-verify: complete discovered={d} selected={d} completed={d} quarantined={d} failed={d} shard_skipped={d} elapsed_ms={d}\n", .{
        progress.discovered.load(.monotonic),
        progress.selected.load(.monotonic),
        progress.completed.load(.monotonic),
        progress.unsupported.load(.monotonic),
        progress.failed.load(.monotonic),
        progress.skipped.load(.monotonic),
        timer.read() / std.time.ns_per_ms,
    });
    printMemoryDiagnostics("external-verify: final diagnostics", gpa.total_requested_bytes);
}

fn runExternalVerify(allocator: std.mem.Allocator, repo_root: []const u8, zevm_bin: []const u8, ctx: *VerifyContext) !void {
    try runExecutionSpecStateFixtures(allocator, repo_root, ctx);
    try runLegacyInvalidIntrinsicGasFixture(allocator, repo_root, ctx);
    try runLegacyStateFixtures(allocator, repo_root, &legacy_state_fixture_dirs, ctx);
    try runBlockchainFixtureSmoke(allocator, repo_root, ctx);
    try runExecutionSpecBlockchainStructuralFixtures(allocator, repo_root, ctx);
    try runRlpFixtures(allocator, repo_root, ctx);
    try runHiveRpcCompatibilityFixtures(allocator, repo_root, zevm_bin, ctx);
}

fn runRlpFixtures(allocator: std.mem.Allocator, repo_root: []const u8, ctx: *VerifyContext) !void {
    const root_path = try std.fs.path.join(allocator, &.{ repo_root, rlp_tests.fixture_root });
    defer allocator.free(root_path);
    const files = try rlp_tests.listFixtureFiles(allocator, root_path);
    defer rlp_tests.freeFixtureFiles(allocator, files);
    if (files.len == 0) return VerifyError.InvalidFixture;

    for (files) |relative_path| {
        const path = try std.fs.path.join(allocator, &.{ root_path, relative_path });
        defer allocator.free(path);
        var parsed = try readJson(allocator, path);
        defer parsed.deinit();
        if (parsed.value != .object or parsed.value.object.count() == 0) return VerifyError.InvalidFixture;

        var it = parsed.value.object.iterator();
        while (it.next()) |entry| {
            const task_label = try std.fmt.allocPrint(allocator, "{s}/{s} :: {s}", .{ rlp_tests.fixture_root, relative_path, entry.key_ptr.* });
            defer allocator.free(task_label);
            const task_id = ctx.claimTask(task_label) orelse continue;
            const started_ns = ctx.startTask(task_id, "rlp", task_label);
            rlp_tests.runCase(allocator, entry.value_ptr.*) catch |err| {
                ctx.failTask(task_id, "rlp", task_label, started_ns, err);
                return err;
            };
            ctx.finishTask(task_id, "rlp", started_ns);
        }
    }
}

fn runExecutionSpecStateFixtures(allocator: std.mem.Allocator, repo_root: []const u8, ctx: *VerifyContext) !void {
    for (execution_spec_state_fixture_paths) |relative_path| {
        const path = try std.fs.path.join(allocator, &.{ repo_root, relative_path });
        defer allocator.free(path);
        try runStateFixtureFile(allocator, path, relative_path, ctx);
    }
}

fn runStateFixtureFile(allocator: std.mem.Allocator, path: []const u8, label_path: []const u8, ctx: *VerifyContext) !void {
    var parsed = try readJson(allocator, path);
    defer parsed.deinit();

    var case_count: usize = 0;
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        try runGeneratedStateFixture(allocator, entry.value_ptr.*, label_path, entry.key_ptr.*, ctx);
        case_count += 1;
    }

    if (case_count == 0) return VerifyError.InvalidFixture;
}

fn runGeneratedStateFixture(
    allocator: std.mem.Allocator,
    fixture: std.json.Value,
    label_path: []const u8,
    fixture_name: []const u8,
    ctx: *VerifyContext,
) !void {
    const post_by_fork = try field(fixture, "post");
    var ran: usize = 0;
    var fork_it = post_by_fork.object.iterator();
    while (fork_it.next()) |fork_entry| {
        const hardfork = try hardforkFromFixtureName(fork_entry.key_ptr.*);
        const post_cases = fork_entry.value_ptr.*;
        if (post_cases != .array) return VerifyError.InvalidFixture;

        for (post_cases.array.items, 0..) |post_case, post_index| {
            const task_label = try std.fmt.allocPrint(allocator, "{s} :: {s} :: {s} post={d}", .{
                label_path,
                fixture_name,
                fork_entry.key_ptr.*,
                post_index,
            });
            defer allocator.free(task_label);
            if (ctx.claimTask(task_label)) |task_id| {
                const started_ns = ctx.startTask(task_id, "execution-spec-state", task_label);
                runGeneratedStatePostCase(allocator, fixture, post_case, hardfork) catch |err| {
                    ctx.failTask(task_id, "execution-spec-state", task_label, started_ns, err);
                    return err;
                };
                ctx.finishTask(task_id, "execution-spec-state", started_ns);
            }
            ran += 1;
        }
    }

    if (ran == 0) return VerifyError.InvalidFixture;
}

fn runGeneratedStatePostCase(parent_allocator: std.mem.Allocator, fixture: std.json.Value, post_case: std.json.Value, hardfork: guillotine_mini.Hardfork) !void {
    var arena = std.heap.ArenaAllocator.init(parent_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    if (post_case.object.get("expectException")) |_| return VerifyError.UnexpectedTransactionResult;

    var sm = try state_manager.StateManager.init(allocator, null);
    defer sm.deinit();
    try seedPreState(allocator, &sm, try field(fixture, "pre"));

    const indexes = try indexesFromPostCase(post_case);
    const tx = try legacyTxFromFixtureCase(allocator, fixture, indexes);
    defer tx.deinit(allocator);

    const block_ctx = try blockContextFromFixture(fixture, hardfork);
    var adapter = zevm.host_adapter.HostAdapter{ .state = &sm };
    var receipt = try zevm.tx_processor.processTransactionWithOptions(
        allocator,
        &sm,
        adapter.hostInterface(),
        tx.sender,
        tx.tx,
        block_ctx,
        tx.options.withHardfork(hardfork),
    );
    defer receipt.deinit(allocator);

    const status = receipt.status orelse return VerifyError.UnexpectedTransactionResult;
    if (!status.success) return VerifyError.UnexpectedTransactionResult;

    try assertState(allocator, &sm, try field(post_case, "state"));
}

fn runLegacyInvalidIntrinsicGasFixture(allocator: std.mem.Allocator, repo_root: []const u8, ctx: *VerifyContext) !void {
    const label = "lib/execution-spec-tests/tests/static/state_tests/stExample/invalidTrFiller.json";
    const task_id = ctx.claimTask(label) orelse return;
    const started_ns = ctx.startTask(task_id, "legacy-state-filler", label);
    runLegacyInvalidIntrinsicGasFixtureTask(allocator, repo_root) catch |err| {
        ctx.failTask(task_id, "legacy-state-filler", label, started_ns, err);
        return err;
    };
    ctx.finishTask(task_id, "legacy-state-filler", started_ns);
}

fn runLegacyInvalidIntrinsicGasFixtureTask(parent_allocator: std.mem.Allocator, repo_root: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(parent_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const path = try std.fs.path.join(allocator, &.{
        repo_root,
        "lib/execution-spec-tests/tests/static/state_tests/stExample/invalidTrFiller.json",
    });
    defer allocator.free(path);

    var parsed = try readJson(allocator, path);
    defer parsed.deinit();

    const fixture = firstObjectValue(parsed.value);
    var sm = try state_manager.StateManager.init(allocator, null);
    defer sm.deinit();
    try seedPreState(allocator, &sm, try field(fixture, "pre"));

    const tx = try legacyTxFromFixture(allocator, fixture);
    defer tx.deinit(allocator);

    var adapter = zevm.host_adapter.HostAdapter{ .state = &sm };
    const result = zevm.tx_processor.processTransaction(
        allocator,
        &sm,
        adapter.hostInterface(),
        tx.sender,
        tx.tx,
        try blockContextFromFixture(fixture, .CANCUN),
    );
    try expectTxError(zevm.tx_processor.TxError.IntrinsicGasExceedsLimit, result);

    const expect_items = try field(fixture, "expect");
    const expected = try field(expect_items.array.items[0], "result");
    try assertState(allocator, &sm, expected);
}

fn runEarlyStateFixtures(allocator: std.mem.Allocator, repo_root: []const u8, ctx: *VerifyContext) !void {
    var counts = EarlyCounts.initFill(.{});
    ctx.early_counts = &counts;
    defer ctx.early_counts = null;
    var files = std.mem.tokenizeScalar(u8, @embedFile("early_state_files.txt"), '\n');
    while (files.next()) |relative_path| {
        const path = try std.fs.path.join(allocator, &.{ repo_root, ".cache/early-state-v5.4.0", relative_path });
        defer allocator.free(path);
        try runLegacyStateFixtureFile(allocator, path, relative_path, ctx);
    }

    if (ctx.options.extra_legacy_state_dir) |relative_path| {
        const path = try resolveRepoPath(allocator, repo_root, relative_path);
        defer allocator.free(path);
        try runLegacyStateFixtureDir(allocator, path, relative_path, ctx);
    }

    var missing_fork = false;
    for (std.enums.values(EarlyFork)) |fork| {
        const count = counts.get(fork);
        std.debug.print("early-state: fork={s} discovered={d} passed={d} failed={d}\n", .{ @tagName(fork), count.discovered, count.passed, count.failed });
        if (count.discovered == 0) missing_fork = true;
    }
    if (missing_fork) return VerifyError.InvalidFixture;
    if (ctx.progress.failed.load(.monotonic) != 0) return VerifyError.UnexpectedState;
}

fn runMidForkStateFixtures(allocator: std.mem.Allocator, repo_root: []const u8, ctx: *VerifyContext) !void {
    try runLegacyStateFixtures(allocator, repo_root, &mid_fork_state_dirs, ctx);
    if (ctx.progress.failed.load(.monotonic) > 0) return VerifyError.UnexpectedState;
    if (ctx.options.match == null and ctx.options.shard_total == 1) {
        if (ctx.state_counts.get(.BERLIN).passed == 0 or ctx.state_counts.get(.SHANGHAI).passed == 0) return VerifyError.InvalidFixture;
    }
}

fn runLegacyStateFixtures(allocator: std.mem.Allocator, repo_root: []const u8, dirs: []const []const u8, ctx: *VerifyContext) !void {
    for (dirs) |relative_path| {
        const path = try std.fs.path.join(allocator, &.{ repo_root, relative_path });
        defer allocator.free(path);
        try runLegacyStateFixtureDir(allocator, path, relative_path, ctx);
    }
    if (ctx.options.extra_legacy_state_dir) |relative_path| {
        const path = try resolveRepoPath(allocator, repo_root, relative_path);
        defer allocator.free(path);
        try runLegacyStateFixtureDir(allocator, path, relative_path, ctx);
    }
}

fn resolveRepoPath(allocator: std.mem.Allocator, repo_root: []const u8, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    return std.fs.path.join(allocator, &.{ repo_root, path });
}

fn runLegacyStateFixtureDir(allocator: std.mem.Allocator, path: []const u8, label_path: []const u8, ctx: *VerifyContext) !void {
    var dir = try std.fs.openDirAbsolute(path, .{ .iterate = true });
    defer dir.close();

    var names = std.ArrayList([]const u8){};
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThanBytes);

    if (names.items.len == 0) return VerifyError.InvalidFixture;
    for (names.items) |name| {
        const file_path = try std.fs.path.join(allocator, &.{ path, name });
        defer allocator.free(file_path);
        const file_label = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ label_path, name });
        defer allocator.free(file_label);
        runLegacyStateFixtureFile(allocator, file_path, file_label, ctx) catch |err| {
            std.debug.print("legacy state fixture failed: {s}: {s}\n", .{ file_path, @errorName(err) });
            return err;
        };
    }
}

fn lessThanBytes(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

fn runLegacyStateFixtureFile(allocator: std.mem.Allocator, path: []const u8, label_path: []const u8, ctx: *VerifyContext) !void {
    var parsed = try readJson(allocator, path);
    defer parsed.deinit();

    if (parsed.value != .object) return VerifyError.InvalidFixture;
    var case_count: usize = 0;
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        try runLegacyStateFixture(allocator, entry.value_ptr.*, label_path, entry.key_ptr.*, ctx);
        case_count += 1;
    }

    if (case_count == 0) return VerifyError.InvalidFixture;
}

fn runLegacyStateFixture(
    allocator: std.mem.Allocator,
    fixture: std.json.Value,
    label_path: []const u8,
    fixture_name: []const u8,
    ctx: *VerifyContext,
) !void {
    const post_by_fork = try field(fixture, "post");
    if (post_by_fork != .object or post_by_fork.object.count() == 0) return VerifyError.InvalidFixture;
    var post_count: usize = 0;
    const suite = if (ctx.early_counts != null) "early-state" else "legacy-state";
    var fork_it = post_by_fork.object.iterator();
    while (fork_it.next()) |fork_entry| {
        const fork_name = fork_entry.key_ptr.*;
        const count = if (ctx.early_counts) |counts|
            counts.getPtr(std.meta.stringToEnum(EarlyFork, fork_name) orelse continue)
        else
            null;
        const hardfork = try hardforkFromFixtureName(fork_name);
        const post_cases = fork_entry.value_ptr.*;
        if (post_cases != .array) return VerifyError.InvalidFixture;
        post_count += post_cases.array.items.len;
        if (count) |c| c.discovered += post_cases.array.items.len;

        if (ctx.mid_forks_only and hardfork != .BERLIN and hardfork != .SHANGHAI) continue;

        for (post_cases.array.items, 0..) |post_case, post_index| {
            const task_label = try std.fmt.allocPrint(allocator, "{s} :: {s} :: {s} post={d}", .{
                label_path,
                fixture_name,
                fork_entry.key_ptr.*,
                post_index,
            });
            defer allocator.free(task_label);
            if (ctx.claimTask(task_label)) |task_id| {
                const started_ns = ctx.startTask(task_id, suite, task_label);
                runLegacyStatePostCase(allocator, fixture, post_case, hardfork, ctx.options.dump_state_on_mismatch, .exact) catch |err| {
                    ctx.state_counts.getPtr(hardfork).failed += 1;
                    ctx.failTask(task_id, suite, task_label, started_ns, err);
                    if (count) |c| {
                        c.failed += 1;
                        continue;
                    }
                    if (ctx.mid_forks_only) continue;
                    return err;
                };
                if (count) |c| c.passed += 1;
                ctx.state_counts.getPtr(hardfork).passed += 1;
                ctx.finishTask(task_id, suite, started_ns);
            }
        }
    }
    if (ctx.early_counts == null and post_count == 0) return VerifyError.InvalidFixture;
}

fn runLegacyStatePostCase(
    parent_allocator: std.mem.Allocator,
    fixture: std.json.Value,
    post_case: std.json.Value,
    hardfork: guillotine_mini.Hardfork,
    dump_state_on_mismatch: bool,
    exception_match: ExceptionMatch,
) !void {
    var arena = std.heap.ArenaAllocator.init(parent_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var sm = try state_manager.StateManager.init(allocator, null);
    defer sm.deinit();
    try seedPreState(allocator, &sm, try field(fixture, "pre"));

    const indexes = try indexesFromPostCase(post_case);
    const tx = try legacyTxFromFixtureCase(allocator, fixture, indexes);
    defer tx.deinit(allocator);

    const block_ctx = try blockContextFromFixture(fixture, hardfork);
    var adapter = zevm.host_adapter.HostAdapter{ .state = &sm };
    const receipt_result = zevm.tx_processor.processTransactionWithOptions(
        allocator,
        &sm,
        adapter.hostInterface(),
        tx.sender,
        tx.tx,
        block_ctx,
        tx.options.withHardfork(hardfork),
    );

    if (post_case.object.get("expectException")) |expected_exception| {
        try expectFixtureTxError(allocator, expected_exception, receipt_result, exception_match);
        try assertLegacyStateRoot(allocator, &sm, hardfork, block_ctx.block_coinbase, try field(fixture, "pre"), post_case, indexes, dump_state_on_mismatch);
        try assertLegacyLogsHash(allocator, &.{}, post_case);
        return;
    }

    var receipt = try receipt_result;
    defer receipt.deinit(allocator);

    try assertLegacyStateRoot(allocator, &sm, hardfork, block_ctx.block_coinbase, try field(fixture, "pre"), post_case, indexes, dump_state_on_mismatch);
    try assertLegacyLogsHash(allocator, receipt.logs, post_case);
}

// ---------------------------------------------------------------------------
// Latest-fork state report (Cancun and Prague GeneralStateTests).
//
// Source: `fixtures_general_state_tests.tgz` in the pinned `ethereum/tests`
// submodule, read in place without extraction. Every Cancun and Prague post
// case is classified as passed, failed, or unsupported and tallied per fork
// and per category (the directory below `GeneralStateTests/`). Failures do
// not stop the run. A full run then compares the tallies against the
// committed floor in `latest_fork_state_baseline_path`. See
// docs/reference/latest-fork-state-tests.md for the fixture source strategy.
// ---------------------------------------------------------------------------

const latest_fork_state_archive_path = "lib/ethereum-tests/fixtures_general_state_tests.tgz";
const latest_fork_state_baseline_path = "tools/latest_fork_state_baseline.json";
const latest_fork_state_forks = [_][]const u8{ "Cancun", "Prague" };
const latest_fork_state_max_fixture_bytes = 256 * 1024 * 1024;

const LatestForkStateUnsupportedCategory = struct {
    category: []const u8,
    reason: []const u8,
};

/// Categories ZEVM's state runner does not execute. Every case in them is
/// counted as `unsupported` with this reason; nothing is skipped silently.
const latest_fork_state_unsupported_categories = [_]LatestForkStateUnsupportedCategory{};

const LatestForkStateTally = struct {
    fork: []const u8,
    category: []const u8,
    passed: usize = 0,
    failed: usize = 0,
    unsupported: usize = 0,
};

const LatestForkStateReport = struct {
    tallies: std.StringArrayHashMapUnmanaged(LatestForkStateTally) = .empty,
    other_fork_cases: usize = 0,

    fn deinit(self: *LatestForkStateReport, allocator: std.mem.Allocator) void {
        for (self.tallies.keys(), self.tallies.values()) |key, entry| {
            allocator.free(key);
            allocator.free(entry.category);
        }
        self.tallies.deinit(allocator);
    }

    fn tally(self: *LatestForkStateReport, allocator: std.mem.Allocator, fork: []const u8, category: []const u8) !*LatestForkStateTally {
        const fork_name = latestForkStateForkName(fork) orelse return VerifyError.InvalidFixture;
        const key = try std.fmt.allocPrint(allocator, "{s}|{s}", .{ fork_name, category });
        const entry = self.tallies.getOrPut(allocator, key) catch |err| {
            allocator.free(key);
            return err;
        };
        if (entry.found_existing) {
            allocator.free(key);
        } else {
            errdefer {
                _ = self.tallies.pop();
                allocator.free(key);
            }
            entry.value_ptr.* = .{ .fork = fork_name, .category = try allocator.dupe(u8, category) };
        }
        return entry.value_ptr;
    }

    fn get(self: *const LatestForkStateReport, allocator: std.mem.Allocator, fork: []const u8, category: []const u8) !?LatestForkStateTally {
        const key = try std.fmt.allocPrint(allocator, "{s}|{s}", .{ fork, category });
        defer allocator.free(key);
        return self.tallies.get(key);
    }

    fn sort(self: *LatestForkStateReport) void {
        const Context = struct {
            keys: []const []const u8,
            pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                return std.mem.lessThan(u8, ctx.keys[a], ctx.keys[b]);
            }
        };
        self.tallies.sort(Context{ .keys = self.tallies.keys() });
    }
};

/// Canonical fork name when `name` is one of `latest_fork_state_forks`.
fn latestForkStateForkName(name: []const u8) ?[]const u8 {
    for (latest_fork_state_forks) |fork| {
        if (std.mem.eql(u8, fork, name)) return fork;
    }
    return null;
}

/// Category for an archive member: its directory below `GeneralStateTests/`,
/// for example `Cancun/stEIP4844-blobtransactions` or `stCreate2`. Returns
/// null for non-fixture members (directories, `.meta`, non-JSON files).
fn latestForkStateCategory(member_name: []const u8) ?[]const u8 {
    const marker = "GeneralStateTests/";
    if (!std.mem.endsWith(u8, member_name, ".json")) return null;
    const start = (std.mem.indexOf(u8, member_name, marker) orelse return null) + marker.len;
    const relative = member_name[start..];
    const slash = std.mem.lastIndexOfScalar(u8, relative, '/') orelse return null;
    const category = relative[0..slash];
    if (category.len == 0 or category[0] == '.') return null;
    return category;
}

fn latestForkStateUnsupportedReason(category: []const u8) ?[]const u8 {
    for (latest_fork_state_unsupported_categories) |entry| {
        if (std.mem.eql(u8, entry.category, category)) return entry.reason;
    }
    return null;
}

fn runLatestForkStateReport(allocator: std.mem.Allocator, repo_root: []const u8, ctx: *VerifyContext) !void {
    const archive_path = try resolveRepoPath(allocator, repo_root, ctx.options.latest_fork_state_archive);
    defer allocator.free(archive_path);
    std.debug.print("latest-fork-state: archive=\"{s}\" forks=Cancun,Prague\n", .{ctx.options.latest_fork_state_archive});

    var report = LatestForkStateReport{};
    defer report.deinit(allocator);

    var file = try std.fs.openFileAbsolute(archive_path, .{});
    defer file.close();
    var file_buffer: [64 * 1024]u8 = undefined;
    var file_reader = file.reader(&file_buffer);
    const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(window);
    var decompress = std.compress.flate.Decompress.init(&file_reader.interface, .gzip, window);
    var file_name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var link_name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var it = std.tar.Iterator.init(&decompress.reader, .{
        .file_name_buffer = &file_name_buffer,
        .link_name_buffer = &link_name_buffer,
    });

    var fixture_files: usize = 0;
    while (try it.next()) |member| {
        if (member.kind != .file) continue;
        const category = latestForkStateCategory(member.name) orelse continue;
        if (member.size > latest_fork_state_max_fixture_bytes) return VerifyError.InvalidFixture;

        var contents: std.Io.Writer.Allocating = .init(allocator);
        defer contents.deinit();
        try it.streamRemaining(member, &contents.writer);

        const label_path = try allocator.dupe(u8, member.name);
        defer allocator.free(label_path);
        const category_owned = try allocator.dupe(u8, category);
        defer allocator.free(category_owned);

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, contents.written(), .{ .allocate = .alloc_always });
        defer parsed.deinit();
        if (parsed.value != .object) return VerifyError.InvalidFixture;
        fixture_files += 1;

        var fixture_it = parsed.value.object.iterator();
        while (fixture_it.next()) |entry| {
            try runLatestForkStateFixture(allocator, &report, entry.value_ptr.*, label_path, category_owned, entry.key_ptr.*, ctx);
        }
    }
    if (fixture_files == 0) return VerifyError.InvalidFixture;

    report.sort();
    printLatestForkStateReport(&report);

    const full_run = ctx.options.match == null and ctx.options.shard_total == 1;
    if (!full_run) {
        std.debug.print("latest-fork-state: baseline check skipped for a filtered or sharded run\n", .{});
        return;
    }
    const baseline_path = try resolveRepoPath(allocator, repo_root, ctx.options.latest_fork_state_baseline);
    defer allocator.free(baseline_path);
    var baseline = try readJson(allocator, baseline_path);
    defer baseline.deinit();
    const regressions = try checkLatestForkStateBaseline(allocator, &report, baseline.value, true);
    if (regressions != 0) {
        std.debug.print("latest-fork-state: {d} categories fell below {s}\n", .{ regressions, ctx.options.latest_fork_state_baseline });
        return VerifyError.LatestForkStateRegression;
    }
    std.debug.print("latest-fork-state: baseline ok ({s})\n", .{ctx.options.latest_fork_state_baseline});
}

fn runLatestForkStateFixture(
    allocator: std.mem.Allocator,
    report: *LatestForkStateReport,
    fixture: std.json.Value,
    label_path: []const u8,
    category: []const u8,
    fixture_name: []const u8,
    ctx: *VerifyContext,
) !void {
    const post_by_fork = try field(fixture, "post");
    if (post_by_fork != .object) return VerifyError.InvalidFixture;
    var fork_it = post_by_fork.object.iterator();
    while (fork_it.next()) |fork_entry| {
        const fork_key = fork_entry.key_ptr.*;
        const post_cases = fork_entry.value_ptr.*;
        if (post_cases != .array) return VerifyError.InvalidFixture;
        if (latestForkStateForkName(fork_key) == null) {
            report.other_fork_cases += post_cases.array.items.len;
            continue;
        }
        const hardfork = try hardforkFromFixtureName(fork_key);

        for (post_cases.array.items, 0..) |post_case, post_index| {
            const task_label = try std.fmt.allocPrint(allocator, "{s} :: {s} :: {s} post={d}", .{ label_path, fixture_name, fork_key, post_index });
            defer allocator.free(task_label);
            const task_id = ctx.claimTask(task_label) orelse continue;
            const tally = try report.tally(allocator, fork_key, category);

            if (latestForkStateUnsupportedReason(category)) |reason| {
                tally.unsupported += 1;
                ctx.skipTask(task_id, "latest-fork-state", task_label, reason);
                continue;
            }

            const started_ns = ctx.startTask(task_id, "latest-fork-state", task_label);
            if (runLegacyStatePostCase(allocator, fixture, post_case, hardfork, ctx.options.dump_state_on_mismatch, .any_rejection)) {
                tally.passed += 1;
                ctx.finishTask(task_id, "latest-fork-state", started_ns);
            } else |err| {
                if (err == error.OutOfMemory) return err;
                tally.failed += 1;
                _ = ctx.progress.failed.fetchAdd(1, .monotonic);
                ctx.progress.clearCurrentTask();
                std.debug.print("latest-fork-state: FAIL #{d} fixture=\"{s}\" error={s}\n", .{ task_id, task_label, @errorName(err) });
            }
        }
    }
}

fn printLatestForkStateReport(report: *const LatestForkStateReport) void {
    for (latest_fork_state_forks) |fork| {
        var passed: usize = 0;
        var failed: usize = 0;
        var unsupported: usize = 0;
        for (report.tallies.values()) |tally| {
            if (!std.mem.eql(u8, tally.fork, fork)) continue;
            std.debug.print("latest-fork-state: fork={s} category={s} passed={d} failed={d} unsupported={d}\n", .{ fork, tally.category, tally.passed, tally.failed, tally.unsupported });
            passed += tally.passed;
            failed += tally.failed;
            unsupported += tally.unsupported;
        }
        std.debug.print("latest-fork-state: fork={s} total passed={d} failed={d} unsupported={d}\n", .{ fork, passed, failed, unsupported });
    }
    for (latest_fork_state_unsupported_categories) |entry| {
        std.debug.print("latest-fork-state: unsupported category={s} reason=\"{s}\"\n", .{ entry.category, entry.reason });
    }
    std.debug.print("latest-fork-state: other_fork_cases={d}\n", .{report.other_fork_cases});
}

/// Compares `report` with a baseline of the form
/// `{"minimumPassed": {"<fork>": {"<category>": <count>}}}` and returns the
/// number of categories whose pass count fell below its floor. A baseline
/// category missing from the report counts as a regression.
fn checkLatestForkStateBaseline(
    allocator: std.mem.Allocator,
    report: *const LatestForkStateReport,
    baseline: std.json.Value,
    log: bool,
) !usize {
    const minimum_passed = try field(baseline, "minimumPassed");
    if (minimum_passed != .object) return VerifyError.InvalidFixture;
    var regressions: usize = 0;
    var fork_it = minimum_passed.object.iterator();
    while (fork_it.next()) |fork_entry| {
        if (fork_entry.value_ptr.* != .object) return VerifyError.InvalidFixture;
        var category_it = fork_entry.value_ptr.object.iterator();
        while (category_it.next()) |category_entry| {
            const floor = std.math.cast(usize, try parseQuantity(category_entry.value_ptr.*)) orelse return VerifyError.InvalidQuantity;
            const actual = if (try report.get(allocator, fork_entry.key_ptr.*, category_entry.key_ptr.*)) |tally| tally.passed else 0;
            if (actual < floor) {
                regressions += 1;
                if (log) std.debug.print("latest-fork-state: REGRESSION fork={s} category={s} passed={d} baseline={d}\n", .{ fork_entry.key_ptr.*, category_entry.key_ptr.*, actual, floor });
            }
        }
    }
    return regressions;
}

fn assertLegacyStateRoot(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    hardfork: guillotine_mini.Hardfork,
    block_coinbase: primitives.Address,
    pre_state: std.json.Value,
    post_case: std.json.Value,
    indexes: TransactionIndexes,
    dump_state_on_mismatch: bool,
) !void {
    const actual_state_root = try computeStateRoot(allocator, sm, hardfork, block_coinbase, pre_state);
    const expected_state_root = try parseHashValue(try field(post_case, "hash"));
    if (!std.mem.eql(u8, &actual_state_root, &expected_state_root)) {
        const actual_hex = std.fmt.bytesToHex(actual_state_root, .lower);
        const expected_hex = std.fmt.bytesToHex(expected_state_root, .lower);
        std.debug.print("legacy state root mismatch fork={s} indexes(data={}, gas={}, value={}) actual=0x{s} expected=0x{s}\n", .{ hardfork.toString(), indexes.data, indexes.gas, indexes.value, &actual_hex, &expected_hex });
        if (dump_state_on_mismatch) dumpStateForMismatch(allocator, sm, hardfork, block_coinbase, pre_state) catch {};
        return VerifyError.UnexpectedState;
    }
}

fn dumpStateForMismatch(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    hardfork: guillotine_mini.Hardfork,
    block_coinbase: primitives.Address,
    pre_state: std.json.Value,
) !void {
    var it = sm.accountIterator();
    while (it.next()) |entry| {
        const address = entry.key_ptr.*;
        const balance = try sm.getBalance(address);
        const nonce = try sm.getNonce(address);
        const code = try sm.getCode(address);
        var code_hash = primitives.State.EMPTY_CODE_HASH;
        if (code.len > 0) std.crypto.hash.sha3.Keccak256.hash(code, &code_hash, .{});
        const storage_root = try computeStorageRoot(allocator, sm, address);
        const addr_hex = std.fmt.bytesToHex(address.bytes, .lower);
        const code_hash_hex = std.fmt.bytesToHex(code_hash, .lower);
        const storage_root_hex = std.fmt.bytesToHex(storage_root, .lower);
        std.debug.print("state account=0x{s} nonce={d} balance=0x{x} code_len={d} code_hash=0x{s} storage_root=0x{s}\n", .{ &addr_hex, nonce, balance, code.len, &code_hash_hex, &storage_root_hex });
    }
    var storage_it = sm.journaled_state.storage_cache.cache.iterator();
    while (storage_it.next()) |entry| {
        const address = entry.key_ptr.*;
        const addr_hex = std.fmt.bytesToHex(address.bytes, .lower);
        var slots = entry.value_ptr.*;
        var slot_it = slots.iterator();
        while (slot_it.next()) |slot_entry| {
            std.debug.print("state storage=0x{s} slot=0x{x} value=0x{x}\n", .{ &addr_hex, slot_entry.key_ptr.*, slot_entry.value_ptr.* });
        }
    }
    try dumpStateRootHypotheses(allocator, sm, hardfork, block_coinbase, pre_state);
}

fn dumpStateRootHypotheses(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    hardfork: guillotine_mini.Hardfork,
    block_coinbase: primitives.Address,
    pre_state: std.json.Value,
) !void {
    try sm.checkpoint();
    sm.setBalance(block_coinbase, 0) catch {};
    const no_coinbase_root = try computeStateRoot(allocator, sm, hardfork, block_coinbase, pre_state);
    sm.revert();
    const no_coinbase_hex = std.fmt.bytesToHex(no_coinbase_root, .lower);
    std.debug.print("state root hypothesis=no-coinbase-fee root=0x{s}\n", .{&no_coinbase_hex});

    var storage_addresses = std.ArrayList(primitives.Address){};
    defer storage_addresses.deinit(allocator);
    var storage_it = sm.journaled_state.storage_cache.cache.iterator();
    while (storage_it.next()) |entry| {
        try storage_addresses.append(allocator, entry.key_ptr.*);
    }

    for (storage_addresses.items) |address| {
        try sm.checkpoint();
        if (sm.journaled_state.storage_cache.cache.fetchRemove(address)) |removed| {
            var slots = removed.value;
            slots.deinit();
        }
        const root = try computeStateRoot(allocator, sm, hardfork, block_coinbase, pre_state);
        sm.revert();
        const addr_hex = std.fmt.bytesToHex(address.bytes, .lower);
        const root_hex = std.fmt.bytesToHex(root, .lower);
        std.debug.print("state root hypothesis=clear-storage address=0x{s} root=0x{s}\n", .{ &addr_hex, &root_hex });
    }
}

fn assertLegacyLogsHash(allocator: std.mem.Allocator, logs: []const primitives.EventLog.EventLog, post_case: std.json.Value) !void {
    const actual_logs_hash = try computeLogsHash(allocator, logs);
    const expected_logs_hash = try parseHashValue(try field(post_case, "logs"));
    if (!std.mem.eql(u8, &actual_logs_hash, &expected_logs_hash)) return VerifyError.UnexpectedTransactionResult;
}

fn runBlockchainFixtureSmoke(allocator: std.mem.Allocator, repo_root: []const u8, ctx: *VerifyContext) !void {
    const label = "lib/ethereum-tests/BlockchainTests/ValidBlocks/bcExample/optionsTest.json";
    const task_id = ctx.claimTask(label) orelse return;
    const started_ns = ctx.startTask(task_id, "blockchain-smoke", label);
    runBlockchainFixtureSmokeTask(allocator, repo_root) catch |err| {
        ctx.failTask(task_id, "blockchain-smoke", label, started_ns, err);
        return err;
    };
    ctx.finishTask(task_id, "blockchain-smoke", started_ns);
}

fn runBlockchainFixtureSmokeTask(parent_allocator: std.mem.Allocator, repo_root: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(parent_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const path = try std.fs.path.join(allocator, &.{
        repo_root,
        "lib/ethereum-tests/BlockchainTests/ValidBlocks/bcExample/optionsTest.json",
    });
    defer allocator.free(path);

    var parsed = try readJson(allocator, path);
    defer parsed.deinit();

    var case_count: usize = 0;
    var saw_empty_block = false;
    var saw_transaction_block = false;
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        case_count += 1;
        const fixture = entry.value_ptr.*;
        const genesis_hash = try stringField(try field(fixture, "genesisBlockHeader"), "hash");
        const blocks = try field(fixture, "blocks");
        if (blocks.array.items.len == 0) return VerifyError.InvalidFixture;

        var expected_parent = genesis_hash;
        for (blocks.array.items, 1..) |block, expected_number| {
            const header = try field(block, "blockHeader");
            const parent_hash = try stringField(header, "parentHash");
            if (!std.mem.eql(u8, expected_parent, parent_hash)) return VerifyError.InvalidFixture;
            const block_number = try parseQuantity(try field(header, "number"));
            if (block_number != expected_number) return VerifyError.InvalidFixture;
            expected_parent = try stringField(header, "hash");

            const txs = try field(block, "transactions");
            if (txs.array.items.len == 0) saw_empty_block = true else saw_transaction_block = true;
        }
    }

    if (case_count == 0 or !saw_empty_block or !saw_transaction_block) return VerifyError.InvalidFixture;
}

fn runExecutionSpecBlockchainStructuralFixtures(allocator: std.mem.Allocator, repo_root: []const u8, ctx: *VerifyContext) !void {
    for (execution_spec_blockchain_fixture_paths) |relative_path| {
        const path = try std.fs.path.join(allocator, &.{ repo_root, relative_path });
        defer allocator.free(path);
        const task_id = ctx.claimTask(relative_path) orelse continue;
        const started_ns = ctx.startTask(task_id, "execution-spec-blockchain", relative_path);
        runBlockchainFixtureStructuralFile(allocator, path) catch |err| {
            ctx.failTask(task_id, "execution-spec-blockchain", relative_path, started_ns, err);
            return err;
        };
        ctx.finishTask(task_id, "execution-spec-blockchain", started_ns);
    }
}

fn runBlockchainFixtureStructuralFile(parent_allocator: std.mem.Allocator, path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(parent_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var parsed = try readJson(allocator, path);
    defer parsed.deinit();

    var case_count: usize = 0;
    var block_count: usize = 0;
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        case_count += 1;
        const fixture = entry.value_ptr.*;
        const genesis_hash = try stringField(try field(fixture, "genesisBlockHeader"), "hash");
        const valid_chain = std.mem.indexOf(u8, path, "invalid") == null;
        if (fixture.object.get("blocks")) |blocks| {
            if (blocks.array.items.len == 0) return VerifyError.InvalidFixture;

            var expected_parent = genesis_hash;
            for (blocks.array.items, 1..) |block, expected_number| {
                const header = try blockHeaderFromFixtureBlock(block);
                const parent_hash = try stringField(header, "parentHash");
                if (valid_chain and !std.mem.eql(u8, expected_parent, parent_hash)) return VerifyError.InvalidFixture;
                const block_number = try parseQuantity(try field(header, "number"));
                if (valid_chain and block_number != expected_number) return VerifyError.InvalidFixture;
                expected_parent = try stringField(header, "hash");

                if (block.object.get("transactions")) |txs| {
                    if (txs != .array) return VerifyError.InvalidFixture;
                } else if (valid_chain) {
                    return VerifyError.MissingField;
                }
                block_count += 1;
            }

            if (valid_chain) {
                const last_hash = try stringField(fixture, "lastblockhash");
                if (!std.mem.eql(u8, expected_parent, last_hash)) return VerifyError.InvalidFixture;
            }
        } else if (fixture.object.get("engineNewPayloads")) |payloads| {
            if (payloads.array.items.len == 0) return VerifyError.InvalidFixture;

            var expected_parent = genesis_hash;
            for (payloads.array.items, 1..) |payload_item, expected_number| {
                const params = try field(payload_item, "params");
                if (params.array.items.len == 0) return VerifyError.InvalidFixture;
                const payload = params.array.items[0];
                const parent_hash = try stringField(payload, "parentHash");
                if (valid_chain and !std.mem.eql(u8, expected_parent, parent_hash)) return VerifyError.InvalidFixture;
                const block_number = try parseQuantity(try field(payload, "blockNumber"));
                if (valid_chain and block_number != expected_number) return VerifyError.InvalidFixture;
                expected_parent = try stringField(payload, "blockHash");

                const txs = try field(payload, "transactions");
                if (txs != .array) return VerifyError.InvalidFixture;
                block_count += 1;
            }

            if (valid_chain) {
                const last_hash = try stringField(fixture, "lastblockhash");
                if (!std.mem.eql(u8, expected_parent, last_hash)) return VerifyError.InvalidFixture;
            }
        } else {
            return VerifyError.MissingField;
        }
    }

    if (case_count == 0 or block_count == 0) return VerifyError.InvalidFixture;
}

fn blockHeaderFromFixtureBlock(block: std.json.Value) !std.json.Value {
    if (block.object.get("blockHeader")) |header| return header;
    if (block.object.get("rlp_decoded")) |decoded| return try field(decoded, "blockHeader");
    return VerifyError.MissingField;
}

fn runHiveRpcCompatibilityFixtures(allocator: std.mem.Allocator, repo_root: []const u8, zevm_bin: []const u8, ctx: *VerifyContext) !void {
    const simulator_path = try std.fs.path.join(allocator, &.{
        repo_root,
        "lib/hive/simulators/ethereum/rpc-compat/testload.go",
    });
    defer allocator.free(simulator_path);
    std.fs.accessAbsolute(simulator_path, .{}) catch return VerifyError.InvalidFixture;

    const forkenv_path = try std.fs.path.join(allocator, &.{ repo_root, "lib/execution-apis/tests/forkenv.json" });
    defer allocator.free(forkenv_path);
    var forkenv = try readJson(allocator, forkenv_path);
    defer forkenv.deinit();
    const genesis_path = try std.fs.path.join(allocator, &.{ repo_root, "lib/execution-apis/tests/genesis.json" });
    defer allocator.free(genesis_path);
    const chain_rlp_path = try std.fs.path.join(allocator, &.{ repo_root, "lib/execution-apis/tests/chain.rlp" });
    defer allocator.free(chain_rlp_path);

    const ports = try reserveDistinctLoopbackPorts();
    const port = ports.rpc;
    const engine_port = ports.engine;
    const config_path = try writeHiveRpcCompatibilityConfig(allocator, repo_root, forkenv.value, port, genesis_path, chain_rlp_path);
    defer {
        std.fs.cwd().deleteFile(config_path) catch {};
        allocator.free(config_path);
    }

    const secret_path = try std.mem.concat(allocator, u8, &.{ config_path, ".jwt" });
    defer allocator.free(secret_path);
    var secret: [32]u8 = undefined;
    std.crypto.random.bytes(&secret);
    const secret_file = try std.fs.cwd().createFile(secret_path, .{ .exclusive = true, .mode = 0o600 });
    defer std.fs.cwd().deleteFile(secret_path) catch {};
    {
        defer secret_file.close();
        try secret_file.writeAll(&std.fmt.bytesToHex(secret, .lower));
    }

    var port_buf: [5]u8 = undefined;
    const port_arg = try std.fmt.bufPrint(&port_buf, "{d}", .{engine_port});
    var engine_child = try spawnFixtureNode(allocator, repo_root, &.{ zevm_bin, "--config", config_path, "--engine-port", port_arg, "--authrpc.jwtsecret", secret_path });
    defer _ = engine_child.kill() catch {};

    if (ctx.claimTask(hive_rpc_head_forkchoice_path)) |task_id| {
        const started_ns = ctx.startTask(task_id, "hive-rpc-compat", hive_rpc_head_forkchoice_path);
        const path = try std.fs.path.join(allocator, &.{ repo_root, hive_rpc_head_forkchoice_path });
        defer allocator.free(path);
        runHiveHeadForkchoice(allocator, engine_port, path, &secret) catch |err| {
            ctx.failTask(task_id, "hive-rpc-compat", hive_rpc_head_forkchoice_path, started_ns, err);
            return err;
        };
        ctx.finishTask(task_id, "hive-rpc-compat", started_ns);
    }

    // Dev RPC methods are available on the loopback-only node with Engine RPC disabled.
    var dev_port_buf: [5]u8 = undefined;
    const dev_port_arg = try std.fmt.bufPrint(&dev_port_buf, "{d}", .{ports.dev});
    var dev_child = try spawnFixtureNode(allocator, repo_root, &.{ zevm_bin, "--config", config_path, "--port", dev_port_arg });
    defer _ = dev_child.kill() catch {};

    const hive_rpc_fixture_paths = try discoverHiveRpcFixturePaths(allocator, repo_root);
    defer freeStringList(allocator, hive_rpc_fixture_paths);

    for (hive_rpc_fixture_paths) |relative_path| {
        const path = try std.fs.path.join(allocator, &.{ repo_root, relative_path });
        defer allocator.free(path);
        const task_id = ctx.claimTask(relative_path) orelse continue;
        const started_ns = ctx.startTask(task_id, "hive-rpc-compat", relative_path);
        var test_case = readRpcIoTest(allocator, path) catch |err| {
            ctx.failTask(task_id, "hive-rpc-compat", relative_path, started_ns, err);
            return err;
        };
        defer test_case.deinit(allocator);
        const fixture_port = if (std.mem.startsWith(u8, relative_path, "lib/execution-apis/tests/testing_")) ports.dev else port;
        runRpcIoTest(allocator, fixture_port, test_case, std.fs.path.basename(std.fs.path.dirname(relative_path).?)) catch |err| {
            ctx.failTask(task_id, "hive-rpc-compat", relative_path, started_ns, err);
            return err;
        };
        ctx.finishTask(task_id, "hive-rpc-compat", started_ns);
    }
}

fn spawnFixtureNode(allocator: std.mem.Allocator, repo_root: []const u8, args: []const []const u8) !std.process.Child {
    var child = std.process.Child.init(args, allocator);
    child.cwd = repo_root;
    child.stdin_behavior = .Close;
    child.stdout_behavior = .Close;
    child.stderr_behavior = .Close;
    try child.spawn();
    return child;
}

fn discoverHiveRpcFixturePaths(allocator: std.mem.Allocator, repo_root: []const u8) ![][]const u8 {
    const tests_dir = try std.fs.path.join(allocator, &.{ repo_root, "lib/execution-apis/tests" });
    defer allocator.free(tests_dir);

    var root = try std.fs.openDirAbsolute(tests_dir, .{ .iterate = true });
    defer root.close();

    var method_dirs = std.ArrayList([]const u8){};
    defer {
        for (method_dirs.items) |method_dir| allocator.free(method_dir);
        method_dirs.deinit(allocator);
    }

    var root_it = root.iterate();
    while (try root_it.next()) |entry| {
        if (entry.kind != .directory) continue;
        try method_dirs.append(allocator, try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, method_dirs.items, {}, lessThanBytes);

    var paths = std.ArrayList([]const u8){};
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }

    for (method_dirs.items) |method_dir| {
        var subdir = try root.openDir(method_dir, .{ .iterate = true });
        defer subdir.close();

        var file_names = std.ArrayList([]const u8){};
        defer {
            for (file_names.items) |file_name| allocator.free(file_name);
            file_names.deinit(allocator);
        }

        var sub_it = subdir.iterate();
        while (try sub_it.next()) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".io")) continue;
            try file_names.append(allocator, try allocator.dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, file_names.items, {}, lessThanBytes);

        for (file_names.items) |file_name| {
            try paths.append(allocator, try std.fmt.allocPrint(
                allocator,
                "lib/execution-apis/tests/{s}/{s}",
                .{ method_dir, file_name },
            ));
        }
    }

    if (paths.items.len == 0) return VerifyError.InvalidFixture;
    return try paths.toOwnedSlice(allocator);
}

fn freeStringList(allocator: std.mem.Allocator, strings: []const []const u8) void {
    for (strings) |string| allocator.free(string);
    allocator.free(strings);
}

const ReservedPorts = struct {
    dev: u16,
    rpc: u16,
    engine: u16,
};

fn writeHiveRpcCompatibilityConfig(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    forkenv: std.json.Value,
    rpc_port: u16,
    genesis_path: []const u8,
    chain_rlp_path: []const u8,
) ![]u8 {
    const temp_dir = try std.fs.path.join(allocator, &.{ repo_root, ".zig-cache", "tmp" });
    defer allocator.free(temp_dir);
    try std.fs.cwd().makePath(temp_dir);

    const timestamp = std.time.nanoTimestamp();
    const file_name = try std.fmt.allocPrint(allocator, "external-verify-hive-rpc-{d}.json", .{timestamp});
    defer allocator.free(file_name);
    const config_path = try std.fs.path.join(allocator, &.{ temp_dir, file_name });
    errdefer allocator.free(config_path);

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    const writer = &out.writer;

    const chain_id = try forkenvU64(forkenv, "HIVE_CHAIN_ID");
    const json_max_i64: u64 = 9223372036854775807;

    try writer.print(
        \\{{
        \\  "rpc": {{ "host": "127.0.0.1", "port": {d} }},
        \\  "mode": {{
        \\    "trusted": {{
        \\      "chainId": {d},
        \\      "blobBaseFee": "1",
        \\      "mining": {{ "type": "manual" }},
        \\      "genesis":
    , .{ rpc_port, chain_id });
    try std.json.Stringify.value(genesis_path, .{}, writer);
    try writer.writeAll(
        \\
        \\,
        \\      "chainRlp":
    );
    try std.json.Stringify.value(chain_rlp_path, .{}, writer);
    try writer.print(
        \\,
        \\      "hardfork": {{
        \\        "homesteadBlock": {d},
        \\        "tangerineWhistleBlock": {d},
        \\        "spuriousDragonBlock": {d},
        \\        "byzantiumBlock": {d},
        \\        "constantinopleBlock": {d},
        \\        "petersburgBlock": {d},
        \\        "istanbulBlock": {d},
        \\        "muirGlacierBlock": {d},
        \\        "berlinBlock": {d},
        \\        "londonBlock": {d},
        \\        "arrowGlacierBlock": {d},
        \\        "grayGlacierBlock": {d},
        \\        "mergeBlock": {d},
        \\        "shanghaiTimestamp": {d},
        \\        "cancunTimestamp": {d},
        \\        "pragueTimestamp": {d},
        \\        "osakaTimestamp": {d}
        \\      }}
        \\    }}
        \\  }}
        \\}}
        \\
    , .{
        try forkenvU64Default(forkenv, "HIVE_FORK_HOMESTEAD", 0),
        try forkenvU64Default(forkenv, "HIVE_FORK_TANGERINE", 0),
        try forkenvU64Default(forkenv, "HIVE_FORK_SPURIOUS", 0),
        try forkenvU64Default(forkenv, "HIVE_FORK_BYZANTIUM", 0),
        try forkenvU64Default(forkenv, "HIVE_FORK_CONSTANTINOPLE", 0),
        try forkenvU64Default(forkenv, "HIVE_FORK_PETERSBURG", 0),
        try forkenvU64Default(forkenv, "HIVE_FORK_ISTANBUL", 0),
        try forkenvU64Default(forkenv, "HIVE_FORK_MUIR_GLACIER", 0),
        try forkenvU64Default(forkenv, "HIVE_FORK_BERLIN", 0),
        try forkenvU64Default(forkenv, "HIVE_FORK_LONDON", 0),
        try forkenvU64Default(forkenv, "HIVE_FORK_ARROW_GLACIER", 0),
        try forkenvU64Default(forkenv, "HIVE_FORK_GRAY_GLACIER", 0),
        try forkenvU64Default(forkenv, "HIVE_MERGE_BLOCK_ID", 0),
        try forkenvU64Default(forkenv, "HIVE_SHANGHAI_TIMESTAMP", 0),
        try forkenvU64Default(forkenv, "HIVE_CANCUN_TIMESTAMP", 0),
        try forkenvU64Default(forkenv, "HIVE_PRAGUE_TIMESTAMP", json_max_i64),
        try forkenvU64Default(forkenv, "HIVE_OSAKA_TIMESTAMP", json_max_i64),
    });

    const body = try out.toOwnedSlice();
    defer allocator.free(body);

    var file = try std.fs.cwd().createFile(config_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(body);

    return config_path;
}

fn forkenvU64(forkenv: std.json.Value, name: []const u8) !u64 {
    const object = switch (forkenv) {
        .object => |object| object,
        else => return VerifyError.InvalidFixture,
    };
    return parseDecimalU64Json(object.get(name) orelse return VerifyError.MissingField);
}

fn forkenvU64Default(forkenv: std.json.Value, name: []const u8, default: u64) !u64 {
    const object = switch (forkenv) {
        .object => |object| object,
        else => return VerifyError.InvalidFixture,
    };
    const value = object.get(name) orelse return default;
    return parseDecimalU64Json(value);
}

fn parseDecimalU64Json(value: std.json.Value) !u64 {
    return switch (value) {
        .integer => |integer| blk: {
            if (integer < 0) return VerifyError.InvalidQuantity;
            break :blk @intCast(integer);
        },
        .string => |text| std.fmt.parseInt(u64, text, 10) catch VerifyError.InvalidQuantity,
        else => VerifyError.InvalidQuantity,
    };
}

fn runHiveHeadForkchoice(allocator: std.mem.Allocator, engine_port: u16, path: []const u8, secret: *const [32]u8) !void {
    const body = try std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024);
    defer allocator.free(body);

    var parsed_request = std.json.parseFromSlice(std.json.Value, allocator, body, .{
        .allocate = .alloc_always,
    }) catch return VerifyError.InvalidFixture;
    defer parsed_request.deinit();
    const params = try field(parsed_request.value, "params");
    if (params != .array or params.array.items.len < 1) return VerifyError.InvalidFixture;
    const head_hash = try stringField(params.array.items[0], "headBlockHash");

    const authorization = try zevm.rpc.server.engineJwtAuthorization(allocator, secret, std.time.timestamp());
    defer allocator.free(authorization);
    const response_text = try waitForRpc(allocator, engine_port, body, authorization);
    defer allocator.free(response_text);
    var parsed_response = std.json.parseFromSlice(std.json.Value, allocator, response_text, .{
        .allocate = .alloc_always,
    }) catch return VerifyError.UnexpectedRpcResponse;
    defer parsed_response.deinit();

    const result = try field(parsed_response.value, "result");
    const payload_status = try field(result, "payloadStatus");
    const status = try stringField(payload_status, "status");
    if (!std.mem.eql(u8, status, "VALID")) return VerifyError.UnexpectedRpcResponse;
    const latest_valid_hash = try stringField(payload_status, "latestValidHash");
    if (!std.mem.eql(u8, latest_valid_hash, head_hash)) return VerifyError.UnexpectedRpcResponse;
    const payload_id = try field(result, "payloadId");
    if (payload_id != .null) return VerifyError.UnexpectedRpcResponse;
}

const RpcIoMessage = struct {
    data: []const u8,
    send: bool,
};

const RpcIoTest = struct {
    messages: []RpcIoMessage,
    speconly: bool,

    fn deinit(self: *RpcIoTest, allocator: std.mem.Allocator) void {
        for (self.messages) |message| {
            allocator.free(message.data);
        }
        allocator.free(self.messages);
    }
};

fn readRpcIoTest(allocator: std.mem.Allocator, path: []const u8) !RpcIoTest {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(bytes);

    var messages = std.ArrayList(RpcIoMessage){};
    var in_header = true;
    var speconly = false;
    errdefer {
        for (messages.items) |message| allocator.free(message.data);
        messages.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "//")) {
            if (in_header) {
                const comment = std.mem.trim(u8, line[2..], " \t\r");
                if (std.mem.startsWith(u8, comment, "speconly:")) speconly = true;
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, ">>") or std.mem.startsWith(u8, line, "<<")) {
            in_header = false;
            const data = std.mem.trim(u8, line[2..], " \t\r");
            var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{ .allocate = .alloc_always }) catch return VerifyError.InvalidFixture;
            parsed.deinit();
            try messages.append(allocator, .{
                .data = try allocator.dupe(u8, data),
                .send = std.mem.startsWith(u8, line, ">>"),
            });
        } else {
            return VerifyError.InvalidFixture;
        }
    }

    if (messages.items.len == 0) return VerifyError.InvalidFixture;
    return .{
        .messages = try messages.toOwnedSlice(allocator),
        .speconly = speconly,
    };
}

fn runRpcIoTest(allocator: std.mem.Allocator, port: u16, test_case: RpcIoTest, method: []const u8) !void {
    var response: ?[]u8 = null;
    defer if (response) |body| allocator.free(body);

    for (test_case.messages) |message| {
        if (message.send) {
            if (response) |old_body| {
                allocator.free(old_body);
                response = null;
            }
            response = try waitForRpc(allocator, port, message.data, null);
        } else {
            const body = response orelse return VerifyError.InvalidFixture;
            if (test_case.speconly and !try jsonTextHasError(allocator, body)) {
                try expectJsonStructure(allocator, message.data, body, method);
            } else {
                try expectJsonEqual(allocator, message.data, body);
            }
            allocator.free(body);
            response = null;
        }
    }

    if (response != null) return VerifyError.InvalidFixture;
}

fn reserveDistinctLoopbackPorts() !ReservedPorts {
    const address = try std.net.Address.parseIp("127.0.0.1", 0);
    var rpc_server = try address.listen(.{});
    defer rpc_server.deinit();
    var engine_server = try address.listen(.{});
    defer engine_server.deinit();
    var dev_server = try address.listen(.{});
    defer dev_server.deinit();

    return .{
        .dev = dev_server.listen_address.getPort(),
        .rpc = rpc_server.listen_address.getPort(),
        .engine = engine_server.listen_address.getPort(),
    };
}

// The pinned execution-apis fixtures include blockTimestamp on transactions and
// logs. ZEVM's phase-1 contract omits it (#38). Adapt the expected shape only,
// so an actual response that leaks the field still fails exact comparison.
fn applyTransactionAndLogContract(value: *std.json.Value) void {
    switch (value.*) {
        .object => |*object| {
            const tx = object.contains("hash") and object.contains("nonce") and object.contains("transactionIndex");
            const log = object.contains("transactionHash") and object.contains("logIndex") and object.contains("topics");
            if (tx or log) _ = object.swapRemove("blockTimestamp");
            for (object.values()) |*child| applyTransactionAndLogContract(child);
        },
        .array => |array| for (array.items) |*child| applyTransactionAndLogContract(child),
        else => {},
    }
}

fn expectJsonEqual(allocator: std.mem.Allocator, expected_text: []const u8, actual_text: []const u8) !void {
    var expected = std.json.parseFromSlice(std.json.Value, allocator, expected_text, .{ .allocate = .alloc_always }) catch return VerifyError.UnexpectedRpcResponse;
    defer expected.deinit();
    applyTransactionAndLogContract(&expected.value);
    var actual = std.json.parseFromSlice(std.json.Value, allocator, actual_text, .{ .allocate = .alloc_always }) catch return VerifyError.UnexpectedRpcResponse;
    defer actual.deinit();

    if (!jsonValuesEqual(expected.value, actual.value, false)) {
        std.debug.print("external-verify: expected response {s}\nexternal-verify: actual response {s}\n", .{ expected_text, actual_text });
        return VerifyError.UnexpectedRpcResponse;
    }
}

fn jsonTextHasError(allocator: std.mem.Allocator, text: []const u8) !bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{ .allocate = .alloc_always }) catch return VerifyError.UnexpectedRpcResponse;
    defer parsed.deinit();
    return switch (parsed.value) {
        .object => |object| object.get("error") != null,
        else => false,
    };
}

fn expectJsonStructure(allocator: std.mem.Allocator, expected_text: []const u8, actual_text: []const u8, method: []const u8) !void {
    var expected = std.json.parseFromSlice(std.json.Value, allocator, expected_text, .{ .allocate = .alloc_always }) catch return VerifyError.UnexpectedRpcResponse;
    defer expected.deinit();
    applyTransactionAndLogContract(&expected.value);
    var actual = std.json.parseFromSlice(std.json.Value, allocator, actual_text, .{ .allocate = .alloc_always }) catch return VerifyError.UnexpectedRpcResponse;
    defer actual.deinit();

    // Sender addresses and nonces in the spec-only example are dynamic map keys.
    // Validate the envelope and the contents of each actual map.
    if (std.mem.eql(u8, method, "txpool_content") or std.mem.eql(u8, method, "txpool_contentFrom")) {
        const result = try field(actual.value, "result");
        if (result != .object or result.object.count() != 2 or actual.value.object.count() != 3) return VerifyError.UnexpectedRpcResponse;
        if (!std.mem.eql(u8, try stringField(actual.value, "jsonrpc"), "2.0") or
            !jsonValuesEqual(try field(expected.value, "id"), try field(actual.value, "id"), false)) return VerifyError.UnexpectedRpcResponse;
        for ([_][]const u8{ "pending", "queued" }) |section_name| {
            const section = try field(result, section_name);
            if (section != .object) return VerifyError.UnexpectedRpcResponse;
            if (std.mem.eql(u8, method, "txpool_contentFrom")) {
                try checkPendingTransactions(section, null);
            } else {
                var senders = section.object.iterator();
                while (senders.next()) |sender| {
                    const address = try parseAddressText(sender.key_ptr.*);
                    try checkPendingTransactions(sender.value_ptr.*, address);
                }
            }
        }
        return;
    }
    if (!jsonStructureMatches(expected.value, actual.value)) {
        std.debug.print("external-verify: expected response {s}\nexternal-verify: actual response {s}\n", .{ expected_text, actual_text });
        return VerifyError.UnexpectedRpcResponse;
    }
}

fn checkPendingTransactions(entries: std.json.Value, sender: ?primitives.Address) !void {
    if (entries != .object) return VerifyError.UnexpectedRpcResponse;
    var nonces = entries.object.iterator();
    while (nonces.next()) |entry| {
        const tx = entry.value_ptr.*;
        const nonce = try std.fmt.parseInt(u64, entry.key_ptr.*, 10);
        if (try parseQuantity(try field(tx, "nonce")) != nonce) return VerifyError.UnexpectedRpcResponse;
        const from = try parseAddressValue(try field(tx, "from"));
        if (sender) |address| if (!std.mem.eql(u8, &address.bytes, &from.bytes)) return VerifyError.UnexpectedRpcResponse;
        _ = try parseHashValue(try field(tx, "hash"));
        _ = try stringField(tx, "input");
        for ([_][]const u8{ "type", "gas", "value", "r", "s", "v" }) |key| {
            _ = try parseQuantity(try field(tx, key));
        }
        const to = try field(tx, "to");
        if (to != .null) _ = try parseAddressValue(to);
        for ([_][]const u8{ "blockHash", "blockNumber", "transactionIndex" }) |key| {
            if (try field(tx, key) != .null) return VerifyError.UnexpectedRpcResponse;
        }
        if (tx.object.contains("blockTimestamp")) return VerifyError.UnexpectedRpcResponse;
    }
}

fn jsonStructureMatches(expected: std.json.Value, actual: std.json.Value) bool {
    if (expected != .object) return @as(std.meta.Tag(std.json.Value), expected) == @as(std.meta.Tag(std.json.Value), actual);
    if (actual != .object) return false;

    var expected_it = expected.object.iterator();
    while (expected_it.next()) |entry| {
        const actual_value = actual.object.get(entry.key_ptr.*) orelse return false;
        if (@as(std.meta.Tag(std.json.Value), entry.value_ptr.*) != @as(std.meta.Tag(std.json.Value), actual_value)) return false;
        if ((entry.value_ptr.* == .object or entry.value_ptr.* == .array) and !jsonStructureMatches(entry.value_ptr.*, actual_value)) return false;
    }

    var actual_it = actual.object.iterator();
    while (actual_it.next()) |entry| {
        if (expected.object.get(entry.key_ptr.*) == null) return false;
    }
    return true;
}

fn jsonValuesEqual(expected: std.json.Value, actual: std.json.Value, ignore_error_message: bool) bool {
    if (@as(std.meta.Tag(std.json.Value), expected) != @as(std.meta.Tag(std.json.Value), actual)) return false;
    return switch (expected) {
        .null => true,
        .bool => |value| value == actual.bool,
        .integer => |value| value == actual.integer,
        .float => |value| value == actual.float,
        .number_string => |value| std.mem.eql(u8, value, actual.number_string),
        .string => |value| std.mem.eql(u8, value, actual.string),
        .array => |array| blk: {
            if (array.items.len != actual.array.items.len) break :blk false;
            for (array.items, actual.array.items) |expected_item, actual_item| {
                if (!jsonValuesEqual(expected_item, actual_item, false)) break :blk false;
            }
            break :blk true;
        },
        .object => |object| blk: {
            if (jsonObjectComparableFieldCount(object, ignore_error_message) !=
                jsonObjectComparableFieldCount(actual.object, ignore_error_message))
            {
                break :blk false;
            }
            var it = object.iterator();
            while (it.next()) |entry| {
                if (ignore_error_message and std.mem.eql(u8, entry.key_ptr.*, "message")) continue;
                const actual_value = actual.object.get(entry.key_ptr.*) orelse break :blk false;
                const child_ignore_error_message = std.mem.eql(u8, entry.key_ptr.*, "error");
                if (!jsonValuesEqual(entry.value_ptr.*, actual_value, child_ignore_error_message)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn jsonObjectComparableFieldCount(object: std.json.ObjectMap, ignore_error_message: bool) usize {
    if (!ignore_error_message) return object.count();
    var count: usize = 0;
    var it = object.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "message")) continue;
        count += 1;
    }
    return count;
}

fn readJson(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(std.json.Value) {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 32 * 1024 * 1024);
    defer allocator.free(bytes);
    return std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .allocate = .alloc_always });
}

fn firstObjectValue(value: std.json.Value) std.json.Value {
    var it = value.object.iterator();
    return it.next().?.value_ptr.*;
}

fn field(value: std.json.Value, name: []const u8) !std.json.Value {
    if (value != .object) return VerifyError.InvalidFixture;
    return value.object.get(name) orelse VerifyError.MissingField;
}

fn stringField(value: std.json.Value, name: []const u8) ![]const u8 {
    const item = try field(value, name);
    if (item != .string) return VerifyError.InvalidFixture;
    return item.string;
}

fn seedPreState(allocator: std.mem.Allocator, sm: *state_manager.StateManager, pre: std.json.Value) !void {
    var it = pre.object.iterator();
    while (it.next()) |entry| {
        if (std.mem.startsWith(u8, entry.key_ptr.*, "//")) continue;
        const address = try parseAddressText(entry.key_ptr.*);
        const account = entry.value_ptr.*;
        const balance = try parseQuantity(try field(account, "balance"));
        const nonce = try parseQuantity(try field(account, "nonce"));

        try sm.initAccount(address, balance);
        try sm.setNonce(address, std.math.cast(u64, nonce) orelse return VerifyError.InvalidQuantity);

        const code_text = try stringField(account, "code");
        if (try maybeHexBytes(allocator, code_text)) |code| {
            defer allocator.free(code);
            try sm.setCode(address, code);
        }

        const storage = try field(account, "storage");
        var storage_it = storage.object.iterator();
        while (storage_it.next()) |storage_entry| {
            const slot = try parseQuantityString(storage_entry.key_ptr.*);
            const value = try parseQuantity(storage_entry.value_ptr.*);
            try sm.setStorage(address, slot, value);
        }
    }
}

const FixtureTx = struct {
    sender: primitives.Address,
    tx: primitives.Transaction.LegacyTransaction,

    options: zevm.tx_processor.ProcessTransactionOptions = .{},

    fn deinit(self: FixtureTx, allocator: std.mem.Allocator) void {
        allocator.free(self.tx.data);
        if (self.options.access_list) |access_list| {
            freeAccessList(allocator, access_list);
        }
        if (self.options.blob_versioned_hashes) |hashes| allocator.free(hashes);
        if (self.options.authorization_list) |authorizations| allocator.free(authorizations);
    }
};

const TransactionIndexes = struct {
    data: usize = 0,
    gas: usize = 0,
    value: usize = 0,
};

fn legacyTxFromFixture(allocator: std.mem.Allocator, fixture: std.json.Value) !FixtureTx {
    return legacyTxFromFixtureCase(allocator, fixture, .{});
}

fn legacyTxFromFixtureCase(allocator: std.mem.Allocator, fixture: std.json.Value, indexes: TransactionIndexes) !FixtureTx {
    const transaction = try field(fixture, "transaction");
    const sender = if (transaction.object.get("sender")) |sender_value|
        try parseAddressValue(sender_value)
    else
        try senderFromPre(try field(fixture, "pre"));

    const gas_limit = try parseQuantityAtIndex(try field(transaction, "gasLimit"), indexes.gas);
    const value = try parseQuantityAtIndex(try field(transaction, "value"), indexes.value);
    const data = try dataFromTransactionAtIndex(allocator, transaction, indexes.data);
    errdefer allocator.free(data);
    const access_list = try accessListFromTransactionAtIndex(allocator, transaction, indexes.data);
    errdefer if (access_list) |list| freeAccessList(allocator, list);
    const gas_price = try effectiveGasPriceFromFixture(fixture, transaction);
    const max_fee_per_gas: ?u256 = if (transaction.object.get("maxFeePerGas")) |max_fee_value|
        try parseQuantity(max_fee_value)
    else
        null;
    const max_priority_fee_per_gas: ?u256 = if (transaction.object.get("maxPriorityFeePerGas")) |priority_fee_value|
        try parseQuantity(priority_fee_value)
    else
        null;

    const blob_versioned_hashes = try blobVersionedHashesFromTransaction(allocator, transaction);
    errdefer if (blob_versioned_hashes) |hashes| allocator.free(hashes);
    const max_fee_per_blob_gas: ?u256 = if (transaction.object.get("maxFeePerBlobGas")) |blob_fee_value|
        try parseQuantity(blob_fee_value)
    else
        null;
    const authorization_list = try authorizationListFromTransaction(allocator, transaction);
    errdefer if (authorization_list) |authorizations| allocator.free(authorizations);

    const to_text = try stringField(transaction, "to");
    const to = if (to_text.len == 0) null else try parseAddressText(to_text);
    const receipt_type: primitives.Receipt.TransactionType = if (authorization_list != null)
        .eip7702
    else if (blob_versioned_hashes != null)
        .eip4844
    else if (transaction.object.get("maxFeePerGas") != null)
        .eip1559
    else if (access_list != null)
        .eip2930
    else
        .legacy;
    const blob_gas_used: ?u256 = if (blob_versioned_hashes) |hashes|
        @as(u256, hashes.len) * zevm.blob_fee.GAS_PER_BLOB
    else
        null;

    return .{
        .sender = sender,
        .tx = .{
            .nonce = std.math.cast(u64, try parseQuantity(try field(transaction, "nonce"))) orelse return VerifyError.InvalidQuantity,
            .gas_price = gas_price,
            .gas_limit = std.math.cast(u64, gas_limit) orelse return VerifyError.InvalidQuantity,
            .to = to,
            .value = value,
            .data = data,
            .v = 0,
            .r = [_]u8{0} ** 32,
            .s = [_]u8{0} ** 32,
        },
        .options = .{
            .access_list = access_list,
            .receipt_type = receipt_type,
            .max_fee_per_gas = max_fee_per_gas,
            .max_priority_fee_per_gas = max_priority_fee_per_gas,
            .authorization_list = authorization_list,
            .blob_gas_used = blob_gas_used,
            .max_fee_per_blob_gas = max_fee_per_blob_gas,
            .blob_versioned_hashes = blob_versioned_hashes,
        },
    };
}

fn blobVersionedHashesFromTransaction(allocator: std.mem.Allocator, transaction: std.json.Value) !?[]const [32]u8 {
    const hashes_value = transaction.object.get("blobVersionedHashes") orelse return null;
    if (hashes_value != .array) return VerifyError.InvalidFixture;
    const hashes = try allocator.alloc([32]u8, hashes_value.array.items.len);
    errdefer allocator.free(hashes);
    for (hashes_value.array.items, 0..) |hash_value, i| {
        hashes[i] = try parseHashValue(hash_value);
    }
    return hashes;
}

/// EIP-7702 authorization tuples. Out-of-range `chainId`, `nonce`, and `v`
/// values saturate to `maxInt(u64)`: each saturated value is still invalid
/// for the same reason, so ZEVM skips the tuple exactly as it would the
/// original. The fixture's `signer` hint is ignored; ZEVM recovers it.
fn authorizationListFromTransaction(allocator: std.mem.Allocator, transaction: std.json.Value) !?[]const primitives.Authorization.Authorization {
    const list_value = transaction.object.get("authorizationList") orelse return null;
    if (list_value != .array) return VerifyError.InvalidFixture;
    const authorizations = try allocator.alloc(primitives.Authorization.Authorization, list_value.array.items.len);
    errdefer allocator.free(authorizations);
    for (list_value.array.items, 0..) |item, i| {
        const y_parity = item.object.get("v") orelse try field(item, "yParity");
        authorizations[i] = .{
            .chain_id = saturatingU64(try parseQuantity(try field(item, "chainId"))),
            .address = try parseAddressValue(try field(item, "address")),
            .nonce = saturatingU64(try parseQuantity(try field(item, "nonce"))),
            .v = saturatingU64(try parseQuantity(y_parity)),
            .r = std.mem.toBytes(std.mem.nativeToBig(u256, try parseQuantity(try field(item, "r")))),
            .s = std.mem.toBytes(std.mem.nativeToBig(u256, try parseQuantity(try field(item, "s")))),
        };
    }
    return authorizations;
}

fn saturatingU64(value: u256) u64 {
    return std.math.cast(u64, value) orelse std.math.maxInt(u64);
}

fn effectiveGasPriceFromFixture(fixture: std.json.Value, transaction: std.json.Value) !u256 {
    if (transaction.object.get("gasPrice")) |gas_price| {
        return parseQuantity(gas_price);
    }

    const max_fee_per_gas = try parseQuantity(try field(transaction, "maxFeePerGas"));
    const max_priority_fee_per_gas = try parseQuantity(try field(transaction, "maxPriorityFeePerGas"));
    const env = try field(fixture, "env");
    const base_fee = if (env.object.get("currentBaseFee")) |base_fee_value|
        try parseQuantity(base_fee_value)
    else
        0;
    const fee_cap_with_tip = std.math.add(u256, base_fee, max_priority_fee_per_gas) catch return VerifyError.InvalidQuantity;
    return @min(max_fee_per_gas, fee_cap_with_tip);
}

fn dataFromTransactionAtIndex(allocator: std.mem.Allocator, transaction: std.json.Value, index: usize) ![]u8 {
    const data_value = try field(transaction, "data");
    const data_text = switch (data_value) {
        .array => |array| blk: {
            if (index >= array.items.len or array.items[index] != .string) return VerifyError.InvalidFixture;
            break :blk array.items[index].string;
        },
        .string => |text| blk: {
            if (index != 0) return VerifyError.InvalidFixture;
            break :blk text;
        },
        else => return VerifyError.InvalidFixture,
    };
    return try hexBytes(allocator, data_text);
}

fn accessListFromTransactionAtIndex(allocator: std.mem.Allocator, transaction: std.json.Value, index: usize) !?primitives.AccessList.AccessList {
    const access_lists_value = transaction.object.get("accessLists") orelse return null;
    if (access_lists_value != .array) return VerifyError.InvalidFixture;
    if (index >= access_lists_value.array.items.len) return VerifyError.InvalidFixture;

    const selected = access_lists_value.array.items[index];
    if (selected == .null) return null;
    if (selected != .array) return VerifyError.InvalidFixture;

    var entries = try allocator.alloc(primitives.AccessList.AccessListEntry, selected.array.items.len);
    var initialized_entries: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < initialized_entries) : (i += 1) {
            allocator.free(entries[i].storage_keys);
        }
        allocator.free(entries);
    }

    for (selected.array.items, 0..) |item, i| {
        const storage_keys_value = try field(item, "storageKeys");
        if (storage_keys_value != .array) return VerifyError.InvalidFixture;

        const storage_keys = try allocator.alloc(primitives.Hash.Hash, storage_keys_value.array.items.len);
        errdefer allocator.free(storage_keys);
        for (storage_keys_value.array.items, 0..) |storage_key_value, j| {
            storage_keys[j] = try parseHashValue(storage_key_value);
        }

        entries[i] = .{
            .address = try parseAddressValue(try field(item, "address")),
            .storage_keys = storage_keys,
        };
        initialized_entries += 1;
    }

    return entries;
}

fn freeAccessList(allocator: std.mem.Allocator, access_list: primitives.AccessList.AccessList) void {
    for (access_list) |entry| {
        allocator.free(entry.storage_keys);
    }
    allocator.free(access_list);
}

fn indexesFromPostCase(post_case: std.json.Value) !TransactionIndexes {
    const indexes = try field(post_case, "indexes");
    return .{
        .data = try parseIndex(try field(indexes, "data")),
        .gas = try parseIndex(try field(indexes, "gas")),
        .value = try parseIndex(try field(indexes, "value")),
    };
}

fn parseIndex(value: std.json.Value) !usize {
    return switch (value) {
        .integer => |number| if (number < 0) 0 else std.math.cast(usize, number) orelse VerifyError.InvalidQuantity,
        .string => |text| blk: {
            const parsed = try parseQuantityString(text);
            break :blk std.math.cast(usize, parsed) orelse VerifyError.InvalidQuantity;
        },
        else => VerifyError.InvalidFixture,
    };
}

fn senderFromPre(pre: std.json.Value) !primitives.Address {
    var it = pre.object.iterator();
    while (it.next()) |entry| {
        if (std.mem.indexOf(u8, entry.key_ptr.*, "sender")) |_| {
            return parseAddressText(entry.key_ptr.*);
        }
    }
    return VerifyError.InvalidFixture;
}

fn hardforkFromFixtureName(name: []const u8) !guillotine_mini.Hardfork {
    if (guillotine_mini.Hardfork.fromString(name)) |hardfork| return hardfork;
    if (std.ascii.eqlIgnoreCase(name, "EIP150")) return .TANGERINE_WHISTLE;
    if (std.ascii.eqlIgnoreCase(name, "EIP158")) return .SPURIOUS_DRAGON;
    return VerifyError.InvalidFixture;
}

fn blockContextFromFixture(fixture: std.json.Value, hardfork: guillotine_mini.Hardfork) !guillotine_mini.BlockContext {
    const env = try field(fixture, "env");
    const base_fee = if (env.object.get("currentBaseFee")) |value| try parseQuantity(value) else 0;
    const random = if (env.object.get("currentRandom")) |value| try parseQuantity(value) else 0;
    const difficulty = if (hardfork.isAtLeast(.MERGE))
        0
    else if (env.object.get("currentDifficulty")) |value|
        try parseQuantity(value)
    else
        0;
    const chain_id = if (fixture.object.get("config")) |config_value|
        std.math.cast(u64, try parseQuantity(try field(config_value, "chainid"))) orelse return VerifyError.InvalidQuantity
    else
        1;
    return .{
        .chain_id = chain_id,
        .block_number = std.math.cast(u64, try parseQuantity(try field(env, "currentNumber"))) orelse return VerifyError.InvalidQuantity,
        .block_timestamp = std.math.cast(u64, try parseQuantity(try field(env, "currentTimestamp"))) orelse return VerifyError.InvalidQuantity,
        .block_difficulty = difficulty,
        .block_prevrandao = if (hardfork.isAtLeast(.MERGE)) random else 0,
        .block_coinbase = try parseAddressValue(try field(env, "currentCoinbase")),
        .block_gas_limit = std.math.cast(u64, try parseQuantity(try field(env, "currentGasLimit"))) orelse return VerifyError.InvalidQuantity,
        .block_base_fee = base_fee,
        .blob_base_fee = try blobBaseFeeFromFixtureEnv(env, hardfork),
    };
}

/// EIP-4844 blob base fee for a state-test `env`. Uses the mainnet blob
/// schedule of the fixture fork; pre-Cancun forks have no blob fee.
fn blobBaseFeeFromFixtureEnv(env: std.json.Value, hardfork: guillotine_mini.Hardfork) !u256 {
    const excess_value = env.object.get("currentExcessBlobGas") orelse return 0;
    const excess = std.math.cast(u64, try parseQuantity(excess_value)) orelse return VerifyError.InvalidQuantity;
    const timestamp = std.math.cast(u64, try parseQuantity(try field(env, "currentTimestamp"))) orelse return VerifyError.InvalidQuantity;
    const params = zevm.blob_fee.blobParamsForFork(zevm.hardfork_schedule.MAINNET_CHAIN_CONFIG, hardfork, timestamp);
    return params.baseFee(excess);
}

fn assertState(allocator: std.mem.Allocator, sm: *state_manager.StateManager, expected_state: std.json.Value) !void {
    var it = expected_state.object.iterator();
    while (it.next()) |entry| {
        if (std.mem.startsWith(u8, entry.key_ptr.*, "//")) continue;
        const address = try parseAddressText(entry.key_ptr.*);
        const account = entry.value_ptr.*;
        if (account.object.get("shouldnotexist")) |_| {
            if (try sm.getBalance(address) != 0) return VerifyError.UnexpectedState;
            if (try sm.getNonce(address) != 0) return VerifyError.UnexpectedState;
            if ((try sm.getCode(address)).len != 0) return VerifyError.UnexpectedState;
            continue;
        }

        if (account.object.get("balance")) |balance_value| {
            const actual = try sm.getBalance(address);
            const expected = try parseQuantity(balance_value);
            if (actual != expected) return VerifyError.UnexpectedState;
        }
        if (account.object.get("nonce")) |nonce_value| {
            const actual = try sm.getNonce(address);
            const expected = try parseQuantity(nonce_value);
            if (actual != expected) return VerifyError.UnexpectedState;
        }
        if (account.object.get("code")) |code_value| {
            if (code_value != .string) return VerifyError.InvalidFixture;
            if (try maybeHexBytes(allocator, code_value.string)) |expected_code| {
                defer allocator.free(expected_code);
                const actual = try sm.getCode(address);
                if (!std.mem.eql(u8, actual, expected_code)) return VerifyError.UnexpectedState;
            }
        }
        if (account.object.get("storage")) |storage| {
            var storage_it = storage.object.iterator();
            while (storage_it.next()) |storage_entry| {
                const slot = try parseQuantityString(storage_entry.key_ptr.*);
                const expected = try parseQuantity(storage_entry.value_ptr.*);
                const actual = try sm.getStorage(address, slot);
                if (actual != expected) return VerifyError.UnexpectedState;
            }
        }
    }
}

fn computeStateRoot(
    allocator: std.mem.Allocator,
    sm: *state_manager.StateManager,
    hardfork: guillotine_mini.Hardfork,
    block_coinbase: primitives.Address,
    pre_state: std.json.Value,
) !primitives.Hash.Hash {
    var keys = std.ArrayList([]const u8){};
    defer {
        for (keys.items) |key| allocator.free(key);
        keys.deinit(allocator);
    }
    var values = std.ArrayList([]const u8){};
    defer {
        for (values.items) |value| allocator.free(value);
        values.deinit(allocator);
    }

    var saw_coinbase = false;
    var it = sm.accountIterator();
    while (it.next()) |entry| {
        const address = entry.key_ptr.*;
        if (address.equals(block_coinbase)) saw_coinbase = true;
        const nonce = try sm.getNonce(address);
        const balance = try sm.getBalance(address);
        const code = try sm.getCode(address);

        var code_hash = primitives.State.EMPTY_CODE_HASH;
        if (code.len > 0) {
            std.crypto.hash.sha3.Keccak256.hash(code, &code_hash, .{});
        }

        const storage_root = try computeStorageRoot(allocator, sm, address);
        const empty_account_core = nonce == 0 and
            balance == 0 and
            std.mem.eql(u8, &code_hash, &primitives.State.EMPTY_CODE_HASH);
        const storage_only_empty_account = empty_account_core and
            !std.mem.eql(u8, &storage_root, &primitives.State.EMPTY_TRIE_ROOT);
        const seeded_empty_account = empty_account_core and
            try preStateHasEmptyAccount(pre_state, address);

        // EIP-161 (Spurious Dragon) defines emptiness by nonce, balance, and
        // code. Explicitly seeded untouched empty accounts remain trie entries,
        // while new empty artifacts and impossible storage-only empty accounts
        // are pruned from post-Spurious roots.
        if (hardfork.isAtLeast(.SPURIOUS_DRAGON) and empty_account_core and (!seeded_empty_account or storage_only_empty_account)) {
            continue;
        }

        try appendAccountTrieEntry(allocator, &keys, &values, address, nonce, balance, storage_root, code_hash);
    }

    // Legacy state tests model the pre-Spurious zero block reward as a
    // coinbase touch. Empty touched accounts stayed in the trie before EIP-161.
    if (hardfork.isBefore(.SPURIOUS_DRAGON) and !saw_coinbase) {
        try appendAccountTrieEntry(
            allocator,
            &keys,
            &values,
            block_coinbase,
            0,
            0,
            primitives.State.EMPTY_TRIE_ROOT,
            primitives.State.EMPTY_CODE_HASH,
        );
    }

    return try primitives.TrieHash.secure_trie_root(allocator, keys.items, values.items);
}

fn appendAccountTrieEntry(
    allocator: std.mem.Allocator,
    keys: *std.ArrayList([]const u8),
    values: *std.ArrayList([]const u8),
    address: primitives.Address,
    nonce: u64,
    balance: u256,
    storage_root: primitives.Hash.Hash,
    code_hash: primitives.Hash.Hash,
) !void {
    const account = primitives.AccountState.AccountState.from(.{
        .nonce = nonce,
        .balance = balance,
        .storage_root = storage_root,
        .code_hash = code_hash,
    });

    const key = try allocator.dupe(u8, address.bytes[0..]);
    var key_owned = true;
    errdefer if (key_owned) allocator.free(key);
    const value = try account.rlpEncode(allocator);
    var value_owned = true;
    errdefer if (value_owned) allocator.free(value);

    try keys.append(allocator, key);
    key_owned = false;
    try values.append(allocator, value);
    value_owned = false;
}

fn preStateHasEmptyAccount(pre_state: std.json.Value, address: primitives.Address) !bool {
    var it = pre_state.object.iterator();
    while (it.next()) |entry| {
        if (std.mem.startsWith(u8, entry.key_ptr.*, "//")) continue;
        const pre_address = try parseAddressText(entry.key_ptr.*);
        if (!pre_address.equals(address)) continue;

        const account = entry.value_ptr.*;
        const balance = try parseQuantity(try field(account, "balance"));
        const nonce = try parseQuantity(try field(account, "nonce"));
        const code_text = try stringField(account, "code");
        var code_hex = code_text;
        if (std.mem.startsWith(u8, code_hex, "0x") or std.mem.startsWith(u8, code_hex, "0X")) {
            code_hex = code_hex[2..];
        }

        const storage = try field(account, "storage");
        var storage_it = storage.object.iterator();
        while (storage_it.next()) |storage_entry| {
            if (try parseQuantity(storage_entry.value_ptr.*) != 0) return false;
        }

        return balance == 0 and nonce == 0 and code_hex.len == 0;
    }
    return false;
}

fn computeStorageRoot(allocator: std.mem.Allocator, sm: *state_manager.StateManager, address: primitives.Address) !primitives.Hash.Hash {
    const slots = sm.journaled_state.storage_cache.cache.getPtr(address) orelse return primitives.State.EMPTY_TRIE_ROOT;

    var keys = std.ArrayList([]const u8){};
    defer {
        for (keys.items) |key| allocator.free(key);
        keys.deinit(allocator);
    }
    var values = std.ArrayList([]const u8){};
    defer {
        for (values.items) |value| allocator.free(value);
        values.deinit(allocator);
    }

    var it = slots.iterator();
    while (it.next()) |entry| {
        const value = entry.value_ptr.*;
        if (value == 0) continue;

        var slot_bytes: primitives.Hash.Hash = undefined;
        std.mem.writeInt(u256, &slot_bytes, entry.key_ptr.*, .big);
        const key = try allocator.dupe(u8, slot_bytes[0..]);
        var key_owned = true;
        errdefer if (key_owned) allocator.free(key);
        const encoded_value = try primitives.Rlp.encode(allocator, value);
        var value_owned = true;
        errdefer if (value_owned) allocator.free(encoded_value);

        try keys.append(allocator, key);
        key_owned = false;
        try values.append(allocator, encoded_value);
        value_owned = false;
    }

    return try primitives.TrieHash.secure_trie_root(allocator, keys.items, values.items);
}

fn computeLogsHash(allocator: std.mem.Allocator, logs: []const primitives.EventLog.EventLog) !primitives.Hash.Hash {
    var encoded_logs = std.ArrayList([]const u8){};
    defer {
        for (encoded_logs.items) |encoded| allocator.free(encoded);
        encoded_logs.deinit(allocator);
    }

    for (logs) |log| {
        try encoded_logs.append(allocator, try encodeLogForHash(allocator, log));
    }

    const encoded = try encodeRlpListFromEncoded(allocator, encoded_logs.items);
    defer allocator.free(encoded);

    var out: primitives.Hash.Hash = undefined;
    std.crypto.hash.sha3.Keccak256.hash(encoded, &out, .{});
    return out;
}

fn encodeLogForHash(allocator: std.mem.Allocator, log: primitives.EventLog.EventLog) ![]const u8 {
    const address = try primitives.Rlp.encodeBytes(allocator, log.address.bytes[0..]);
    defer allocator.free(address);

    var encoded_topics = std.ArrayList([]const u8){};
    defer {
        for (encoded_topics.items) |topic| allocator.free(topic);
        encoded_topics.deinit(allocator);
    }
    for (log.topics) |topic| {
        try encoded_topics.append(allocator, try primitives.Rlp.encodeBytes(allocator, topic[0..]));
    }
    const topics = try encodeRlpListFromEncoded(allocator, encoded_topics.items);
    defer allocator.free(topics);

    const data = try primitives.Rlp.encodeBytes(allocator, log.data);
    defer allocator.free(data);

    const fields = [_][]const u8{ address, topics, data };
    return try encodeRlpListFromEncoded(allocator, &fields);
}

fn encodeRlpListFromEncoded(allocator: std.mem.Allocator, encoded_items: []const []const u8) ![]const u8 {
    var payload_len: usize = 0;
    for (encoded_items) |item| {
        payload_len = std.math.add(usize, payload_len, item.len) catch return VerifyError.InvalidFixture;
    }

    var result = std.ArrayList(u8){};
    errdefer result.deinit(allocator);
    if (payload_len < 56) {
        try result.append(allocator, 0xc0 + @as(u8, @intCast(payload_len)));
    } else {
        const len_bytes = try primitives.Rlp.encodeLength(allocator, payload_len);
        defer allocator.free(len_bytes);
        try result.append(allocator, 0xf7 + @as(u8, @intCast(len_bytes.len)));
        try result.appendSlice(allocator, len_bytes);
    }

    for (encoded_items) |item| {
        try result.appendSlice(allocator, item);
    }
    return try result.toOwnedSlice(allocator);
}

fn expectTxError(expected: zevm.tx_processor.TxError, actual: zevm.tx_processor.TxError!primitives.Receipt.Receipt) !void {
    if (actual) |receipt| {
        var owned_receipt = receipt;
        owned_receipt.deinit(std.heap.page_allocator);
        return VerifyError.UnexpectedTransactionResult;
    } else |err| {
        if (err != expected) return VerifyError.UnexpectedTransactionResult;
    }
}

fn expectFixtureTxError(
    allocator: std.mem.Allocator,
    expected_exception: std.json.Value,
    actual: zevm.tx_processor.TxError!primitives.Receipt.Receipt,
    exception_match: ExceptionMatch,
) !void {
    if (expected_exception != .string) return VerifyError.InvalidFixture;
    const expected = txErrorFromFixtureException(expected_exception.string);
    if (expected == null and exception_match == .exact) return VerifyError.InvalidFixture;
    if (actual) |receipt| {
        var owned_receipt = receipt;
        owned_receipt.deinit(allocator);
        return VerifyError.UnexpectedTransactionResult;
    } else |err| {
        if (expected) |expected_err| {
            if (err != expected_err) return VerifyError.UnexpectedTransactionResult;
        }
    }
}

/// How a fixture's `expectException` is compared with ZEVM's rejection.
/// `.exact` requires a mapped exception name and the matching `TxError`.
/// `.any_rejection` also accepts any rejection for exception names that have
/// no `TxError` mapping (for example EEST `TransactionException.*` names);
/// the post-state root check still applies.
const ExceptionMatch = enum { exact, any_rejection };

fn txErrorFromFixtureException(name: []const u8) ?zevm.tx_processor.TxError {
    if (std.ascii.eqlIgnoreCase(name, "SenderNotEOA")) return zevm.tx_processor.TxError.SenderNotEOA;
    if (std.ascii.eqlIgnoreCase(name, "TR_TypeNotSupported")) return zevm.tx_processor.TxError.UnsupportedTransactionType;
    if (std.ascii.eqlIgnoreCase(name, "TR_IntrinsicGas") or
        std.mem.eql(u8, name, "TransactionException.INTRINSIC_GAS_TOO_LOW")) return zevm.tx_processor.TxError.IntrinsicGasExceedsLimit;
    if (std.ascii.eqlIgnoreCase(name, "TR_InitCodeLimitExceeded") or
        std.mem.eql(u8, name, "TransactionException.INITCODE_SIZE_EXCEEDED")) return zevm.tx_processor.TxError.InitcodeTooLarge;
    if (std.ascii.eqlIgnoreCase(name, "TR_FeeCapLessThanBlocks")) return zevm.tx_processor.TxError.GasPriceBelowBaseFee;
    if (std.ascii.eqlIgnoreCase(name, "TR_TipGtFeeCap")) return zevm.tx_processor.TxError.TipExceedsFeeCap;
    if (std.ascii.eqlIgnoreCase(name, "TR_NoFunds")) return zevm.tx_processor.TxError.InsufficientBalance;
    if (std.ascii.eqlIgnoreCase(name, "TR_GasLimitReached")) return zevm.tx_processor.TxError.BlockGasLimitExceeded;
    return null;
}

fn parseAddressValue(value: std.json.Value) !primitives.Address {
    if (value != .string) return VerifyError.InvalidAddress;
    return parseAddressText(value.string);
}

fn parseAddressText(text: []const u8) !primitives.Address {
    const start = if (std.mem.lastIndexOf(u8, text, "0x")) |index| index + 2 else 0;
    if (text.len < start + 40) return VerifyError.InvalidAddress;
    const hex = text[start .. start + 40];
    var bytes: [20]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, hex) catch return VerifyError.InvalidAddress;
    return .{ .bytes = bytes };
}

fn parseHashValue(value: std.json.Value) !primitives.Hash.Hash {
    if (value != .string) return VerifyError.InvalidHexData;
    return parseHashText(value.string);
}

fn parseHashText(text: []const u8) !primitives.Hash.Hash {
    var hex = text;
    if (std.mem.startsWith(u8, hex, "0x") or std.mem.startsWith(u8, hex, "0X")) {
        hex = hex[2..];
    }
    if (hex.len != 64) return VerifyError.InvalidHexData;
    var out: primitives.Hash.Hash = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch return VerifyError.InvalidHexData;
    return out;
}

fn parseQuantityAtIndex(value: std.json.Value, index: usize) !u256 {
    return switch (value) {
        .array => |array| blk: {
            if (index >= array.items.len) return VerifyError.InvalidFixture;
            break :blk try parseQuantity(array.items[index]);
        },
        else => blk: {
            if (index != 0) return VerifyError.InvalidFixture;
            break :blk try parseQuantity(value);
        },
    };
}

fn parseQuantity(value: std.json.Value) !u256 {
    return switch (value) {
        .string => |text| parseQuantityString(text),
        .integer => |number| if (number < 0) VerifyError.InvalidQuantity else @intCast(number),
        else => VerifyError.InvalidQuantity,
    };
}

fn parseQuantityString(text: []const u8) !u256 {
    if (std.mem.startsWith(u8, text, "0x") or std.mem.startsWith(u8, text, "0X")) {
        if (text.len == 2) return 0;
        return std.fmt.parseInt(u256, text[2..], 16) catch VerifyError.InvalidQuantity;
    }
    if (text.len == 0) return 0;
    return std.fmt.parseInt(u256, text, 10) catch VerifyError.InvalidQuantity;
}

fn maybeHexBytes(allocator: std.mem.Allocator, text: []const u8) !?[]u8 {
    if (text.len == 0) return try allocator.alloc(u8, 0);
    if (!std.mem.startsWith(u8, text, "0x") and !std.mem.startsWith(u8, text, "0X")) return null;
    return try hexBytes(allocator, text);
}

fn hexBytes(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var hex = text;
    if (std.mem.startsWith(u8, hex, "0x") or std.mem.startsWith(u8, hex, "0X")) {
        hex = hex[2..];
    }
    if (hex.len == 0) return try allocator.alloc(u8, 0);
    if (hex.len % 2 != 0) return VerifyError.InvalidHexData;
    const out = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(out);
    _ = std.fmt.hexToBytes(out, hex) catch return VerifyError.InvalidHexData;
    return out;
}

fn waitForRpc(allocator: std.mem.Allocator, port: u16, body: []const u8, authorization: ?[]const u8) ![]u8 {
    var attempt: usize = 0;
    var last_error: ?anyerror = null;
    while (attempt < 100) : (attempt += 1) {
        if (sendRpcRequest(allocator, port, body, authorization)) |response| {
            return response;
        } else |err| {
            last_error = err;
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }
    if (last_error) |err| {
        std.debug.print("external-verify: rpc smoke failed port={d} attempts={d} last_error={s}\n", .{
            port,
            attempt,
            @errorName(err),
        });
    } else {
        std.debug.print("external-verify: rpc smoke failed port={d} attempts={d} last_error=none\n", .{ port, attempt });
    }
    return VerifyError.RpcSmokeFailed;
}

fn sendRpcRequest(allocator: std.mem.Allocator, port: u16, body: []const u8, authorization: ?[]const u8) ![]u8 {
    var stream = try std.net.tcpConnectToHost(allocator, "127.0.0.1", port);
    defer stream.close();

    const request = if (authorization) |value| try std.fmt.allocPrint(
        allocator,
        "POST / HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nAuthorization: {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ port, value, body.len, body },
    ) else try std.fmt.allocPrint(
        allocator,
        "POST / HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ port, body.len, body },
    );
    defer allocator.free(request);
    try stream.writeAll(request);

    var response = std.ArrayList(u8){};
    errdefer response.deinit(allocator);
    var body_start: ?usize = null;
    var content_length: ?usize = null;
    var buffer: [4096]u8 = undefined;
    while (true) {
        const amount = try stream.read(&buffer);
        if (amount == 0) {
            if (body_start == null or content_length == null) return VerifyError.RpcSmokeFailed;
            break;
        }
        try response.appendSlice(allocator, buffer[0..amount]);

        if (body_start == null) {
            if (std.mem.indexOf(u8, response.items, "\r\n\r\n")) |index| {
                body_start = index + 4;
                content_length = parseHttpContentLength(response.items[0..index]) orelse return VerifyError.RpcSmokeFailed;
            }
        }

        if (body_start) |start| {
            const len = content_length orelse return VerifyError.RpcSmokeFailed;
            if (response.items.len >= start + len) break;
        }
    }

    const raw = try response.toOwnedSlice(allocator);
    errdefer allocator.free(raw);
    const start = body_start orelse return VerifyError.RpcSmokeFailed;
    const len = content_length orelse return VerifyError.RpcSmokeFailed;
    if (raw.len < start + len) return VerifyError.RpcSmokeFailed;
    const out = try allocator.dupe(u8, std.mem.trim(u8, raw[start .. start + len], " \t\r\n"));
    allocator.free(raw);
    return out;
}

fn parseHttpContentLength(headers: []const u8) ?usize {
    var lines = std.mem.splitScalar(u8, headers, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t\r");
        if (!std.ascii.eqlIgnoreCase(name, "content-length")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t\r");
        return std.fmt.parseInt(usize, value, 10) catch null;
    }
    return null;
}

fn parseTestJson(allocator: std.mem.Allocator, text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, text, .{ .allocate = .alloc_always });
}

test "latest-fork state categories come from the directory below GeneralStateTests" {
    try std.testing.expectEqualStrings("stCreate2", latestForkStateCategory("GeneralStateTests/stCreate2/create2collisionBalance.json").?);
    try std.testing.expectEqualStrings("Cancun/stEIP4844-blobtransactions", latestForkStateCategory("./GeneralStateTests/Cancun/stEIP4844-blobtransactions/blobhashListBounds3.json").?);
    try std.testing.expectEqualStrings("VMTests/vmArithmeticTest", latestForkStateCategory("GeneralStateTests/VMTests/vmArithmeticTest/add.json").?);
    try std.testing.expect(latestForkStateCategory("GeneralStateTests/.meta/meta.json") == null);
    try std.testing.expect(latestForkStateCategory("GeneralStateTests/stCreate2/") == null);
    try std.testing.expect(latestForkStateCategory("GeneralStateTests/top.json") == null);
    try std.testing.expect(latestForkStateForkName("Prague") != null);
    try std.testing.expect(latestForkStateForkName("Cancun") != null);
    try std.testing.expect(latestForkStateForkName("Shanghai") == null);
    try std.testing.expectEqual(guillotine_mini.Hardfork.PRAGUE, try hardforkFromFixtureName("Prague"));
}

test "state fixture blob transactions map to EIP-4844 options" {
    const allocator = std.testing.allocator;
    var parsed = try parseTestJson(allocator,
        \\{"env":{"currentCoinbase":"0x2adc25665018aa1fe0e6bc666dac8fc2697ff9ba","currentGasLimit":"0x016345785d8a0000","currentNumber":"0x01","currentTimestamp":"0x03e8","currentBaseFee":"0x07","currentExcessBlobGas":"0x00"},
        \\ "pre":{},
        \\ "transaction":{"nonce":"0x00","maxFeePerGas":"0x0a","maxPriorityFeePerGas":"0x01","maxFeePerBlobGas":"0x64",
        \\  "gasLimit":["0x0186a0"],"to":"0x0000000000000000000000000000000000001000","value":["0x00"],"data":["0x"],
        \\  "accessLists":[[]],"sender":"0xa94f5374fce5edbc8e2a8697c15331677e6ebf0b",
        \\  "blobVersionedHashes":["0x0100000000000000000000000000000000000000000000000000000000000000","0x0100000000000000000000000000000000000000000000000000000000000001"]}}
    );
    defer parsed.deinit();

    const tx = try legacyTxFromFixtureCase(allocator, parsed.value, .{});
    defer tx.deinit(allocator);
    try std.testing.expectEqual(primitives.Receipt.TransactionType.eip4844, tx.options.receipt_type);
    try std.testing.expectEqual(@as(usize, 2), tx.options.blob_versioned_hashes.?.len);
    try std.testing.expectEqual(@as(u8, 0x01), tx.options.blob_versioned_hashes.?[1][31]);
    try std.testing.expectEqual(@as(u256, 2 * zevm.blob_fee.GAS_PER_BLOB), tx.options.blob_gas_used.?);
    try std.testing.expectEqual(@as(u256, 100), tx.options.max_fee_per_blob_gas.?);

    const cancun_ctx = try blockContextFromFixture(parsed.value, .CANCUN);
    try std.testing.expectEqual(@as(u256, 1), cancun_ctx.blob_base_fee);
    const shanghai_ctx = try blockContextFromFixture(parsed.value, .SHANGHAI);
    try std.testing.expectEqual(@as(u256, 0), shanghai_ctx.blob_base_fee);
}

test "state fixture authorization lists map to EIP-7702 options" {
    const allocator = std.testing.allocator;
    var parsed = try parseTestJson(allocator,
        \\{"env":{"currentBaseFee":"0x07"},"pre":{},
        \\ "transaction":{"nonce":"0x00","maxFeePerGas":"0x0a","maxPriorityFeePerGas":"0x01",
        \\  "gasLimit":["0x0186a0"],"to":"0x0000000000000000000000000000000000001000","value":["0x00"],"data":["0x"],
        \\  "sender":"0xa94f5374fce5edbc8e2a8697c15331677e6ebf0b",
        \\  "authorizationList":[
        \\   {"chainId":"0x01","address":"0x0000000000000000000000000000000000002000","nonce":"0x00","v":"0x01","r":"0x02","s":"0x03","signer":"0x8a0a19589531694250d570040a0c4b74576919b8"},
        \\   {"chainId":"0x010000000000000000","address":"0x0000000000000000000000000000000000002000","nonce":"0xffffffffffffffff","yParity":"0x00","r":"0x01","s":"0x01"}]}}
    );
    defer parsed.deinit();

    const tx = try legacyTxFromFixtureCase(allocator, parsed.value, .{});
    defer tx.deinit(allocator);
    try std.testing.expectEqual(primitives.Receipt.TransactionType.eip7702, tx.options.receipt_type);
    const authorizations = tx.options.authorization_list.?;
    try std.testing.expectEqual(@as(usize, 2), authorizations.len);
    try std.testing.expectEqual(@as(u64, 1), authorizations[0].chain_id);
    try std.testing.expectEqual(@as(u64, 1), authorizations[0].v);
    try std.testing.expectEqual(@as(u8, 0x02), authorizations[0].r[31]);
    try std.testing.expectEqual(@as(u8, 0x03), authorizations[0].s[31]);
    try std.testing.expectEqual(std.math.maxInt(u64), authorizations[1].chain_id);
    try std.testing.expectEqual(std.math.maxInt(u64), authorizations[1].nonce);
}

test "unmapped expectException names accept any rejection only in any_rejection mode" {
    const allocator = std.testing.allocator;
    const rejected: zevm.tx_processor.TxError!primitives.Receipt.Receipt = zevm.tx_processor.TxError.TooManyBlobs;
    const unmapped = std.json.Value{ .string = "TransactionException.TYPE_3_TX_MAX_BLOB_GAS_ALLOWANCE_EXCEEDED" };
    try expectFixtureTxError(allocator, unmapped, rejected, .any_rejection);
    try std.testing.expectError(VerifyError.InvalidFixture, expectFixtureTxError(allocator, unmapped, rejected, .exact));
    const mapped = std.json.Value{ .string = "TR_NoFunds" };
    try std.testing.expectError(VerifyError.UnexpectedTransactionResult, expectFixtureTxError(allocator, mapped, rejected, .any_rejection));
}

test "latest-fork state baseline flags categories below their floor" {
    const allocator = std.testing.allocator;
    var report = LatestForkStateReport{};
    defer report.deinit(allocator);
    (try report.tally(allocator, "Prague", "stCreate2")).passed = 5;
    (try report.tally(allocator, "Cancun", "stCreate2")).passed = 3;
    (try report.tally(allocator, "Prague", "stCreate2")).failed += 1;
    try std.testing.expectEqual(@as(usize, 2), report.tallies.count());
    try std.testing.expectEqual(@as(usize, 1), (try report.get(allocator, "Prague", "stCreate2")).?.failed);

    var ok = try parseTestJson(allocator,
        \\{"minimumPassed":{"Prague":{"stCreate2":5},"Cancun":{"stCreate2":3}}}
    );
    defer ok.deinit();
    try std.testing.expectEqual(@as(usize, 0), try checkLatestForkStateBaseline(allocator, &report, ok.value, false));

    var regressed = try parseTestJson(allocator,
        \\{"minimumPassed":{"Prague":{"stCreate2":6,"stMissing":1},"Cancun":{"stCreate2":3}}}
    );
    defer regressed.deinit();
    try std.testing.expectEqual(@as(usize, 2), try checkLatestForkStateBaseline(allocator, &report, regressed.value, false));
}
