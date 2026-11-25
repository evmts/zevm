const builtin = @import("builtin");
const std = @import("std");

const ModuleSet = struct {
    rust_crypto: RustCrypto,
    primitives_mod: *std.Build.Module,
    state_manager_mod: *std.Build.Module,
    blockchain_mod: *std.Build.Module,
    crypto_mod: *std.Build.Module,
    precompiles_mod: *std.Build.Module,
    jsonrpc_mod: *std.Build.Module,
    guillotine_mini_mod: *std.Build.Module,
    zevm_mod: *std.Build.Module,
    c_kzg_include_path: std.Build.LazyPath,
    blst_include_path: std.Build.LazyPath,
};

const RustCrypto = struct {
    build_step: ?*std.Build.Step,
    archive: std.Build.LazyPath,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const skip_rust_build = b.option(bool, "skip-rust-build", "Skip invoking cargo build for Voltaire Rust crypto (caller pre-built it)") orelse false;
    const fuzz_filter = b.option([]const u8, "fuzz-filter", "Filter tests in the fuzz and fuzz-c-abi steps");
    const fuzz_filters: []const []const u8 = if (fuzz_filter) |filter| &.{filter} else &.{};

    const launch_policy_preflight_step = b.step("launch-policy-preflight", "Check that locally built executables can launch on this host");
    if (builtin.os.tag == .macos) {
        const launch_policy_preflight_cmd = b.addSystemCommand(&.{ "bun", "tools/macos_launch_policy_preflight.js" });
        launch_policy_preflight_cmd.setName("launch-policy-preflight");
        launch_policy_preflight_step.dependOn(&launch_policy_preflight_cmd.step);
    }

    const release_metadata_exe = b.addExecutable(.{
        .name = "release-metadata",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/release_metadata.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });

    const release_metadata_step = b.step("release-metadata", "Generate release metadata artifacts");
    const release_metadata_cmd = b.addRunArtifact(release_metadata_exe);
    release_metadata_cmd.step.dependOn(launch_policy_preflight_step);
    if (b.args) |args| {
        release_metadata_cmd.addArgs(args);
    }
    release_metadata_step.dependOn(&release_metadata_cmd.step);

    const qualification_check_exe = b.addExecutable(.{
        .name = "qualification-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/qualification_check.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });

    const qualification_check_step = b.step("qualification-check", "Validate release qualification assertion map");
    const qualification_check_cmd = b.addRunArtifact(qualification_check_exe);
    qualification_check_cmd.step.dependOn(launch_policy_preflight_step);
    qualification_check_cmd.addArg("--map");
    qualification_check_cmd.addFileArg(b.path("docs/specs/qualification/assertion-map.json"));
    if (b.args) |args| {
        qualification_check_cmd.addArgs(args);
    }
    qualification_check_step.dependOn(&qualification_check_cmd.step);

    const test_graph_check_exe = b.addExecutable(.{
        .name = "test-graph-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/test_graph_check.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });

    const dependency_preflight_exe = b.addExecutable(.{
        .name = "dependency-preflight",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/dependency_preflight.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });

    const dependency_preflight_step = b.step("dependency-preflight", "Validate package dependency pins and optional expected revisions");
    const dependency_preflight_cmd = b.addRunArtifact(dependency_preflight_exe);
    dependency_preflight_cmd.step.dependOn(launch_policy_preflight_step);
    if (b.args) |args| {
        dependency_preflight_cmd.addArgs(args);
    }
    dependency_preflight_step.dependOn(&dependency_preflight_cmd.step);

    const qualification_check_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/qualification_check.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const run_qualification_check_tests = b.addRunArtifact(qualification_check_tests);
    run_qualification_check_tests.step.dependOn(launch_policy_preflight_step);
    const dependency_preflight_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/dependency_preflight.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const run_dependency_preflight_tests = b.addRunArtifact(dependency_preflight_tests);
    run_dependency_preflight_tests.step.dependOn(launch_policy_preflight_step);
    const run_test_graph_check = b.addRunArtifact(test_graph_check_exe);
    run_test_graph_check.step.dependOn(launch_policy_preflight_step);

    const release_binaries_step = b.step("release-binaries", "Build the selected target's ReleaseSafe ZEVM CLI under zig-out/dist/<target>/bin");
    const npm_platform_step = b.step("npm-platform-artifacts", "Build the selected target's ReleaseSafe Node-API addon under zig-out/npm/prebuilds");
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });
    const wasm_deps = voltaireDependency(b, wasm_target, .ReleaseSmall);
    const wasm_modules = createModuleSet(b, wasm_target, .ReleaseSmall, "zevm_browser", wasm_deps, configureRustCrypto(b, wasm_target, "wasm32-unknown-unknown", wasm_deps, true));
    const wasm_root = createCBindingsModule(b, wasm_target, .ReleaseSmall, wasm_modules);
    wasm_root.root_source_file = b.path("src/browser.zig");
    wasm_root.export_symbol_names = &.{ "zevm_alloc", "zevm_free", "zevm_node_create", "zevm_node_destroy", "zevm_node_rpc", "zevm_node_free_response" };
    const reactor = b.addExecutable(.{ .name = "zevm", .root_module = wasm_root });
    reactor.entry = .disabled;
    reactor.wasi_exec_model = .reactor;
    reactor.linkLibC();
    const wasm_install = b.addInstallFile(reactor.getEmittedBin(), "npm/browser/zevm.wasm");
    b.step("wasm", "Build the browser execution reactor").dependOn(&wasm_install.step);
    const rust_target = rustTargetTriple(target) orelse {
        const failure = b.addFail(if (target.result.cpu.arch == .wasm64)
            "ZEVM does not support wasm64"
        else
            b.fmt("ZEVM has no Voltaire Rust crypto target for {s}", .{target.result.zigTriple(b.allocator) catch unreachable}));
        b.getInstallStep().dependOn(&failure.step);
        release_binaries_step.dependOn(&failure.step);
        npm_platform_step.dependOn(&failure.step);
        return;
    };

    const voltaire = voltaireDependency(b, target, optimize);
    const rust_crypto = configureRustCrypto(b, target, rust_target, voltaire, skip_rust_build);
    const modules = createModuleSet(b, target, optimize, "zevm", voltaire, rust_crypto);
    const mod = modules.zevm_mod;

    const exe = addZevmCli(b, target, optimize, modules);
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(launch_policy_preflight_step);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Tests
    const test_filter = b.option([]const u8, "test-filter", "Run matching ZEVM module tests (e.g. safety_rpc_fuzz_test)");
    const mod_tests = b.addTest(.{
        .root_module = mod,
        .filters = if (test_filter) |filter| &.{filter} else &.{},
    });
    linkRustSupport(mod_tests, target, rust_crypto);
    const run_mod_tests = b.addRunArtifact(mod_tests);
    run_mod_tests.step.dependOn(launch_policy_preflight_step);

    const abi_tests_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/abi_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "primitives", .module = modules.primitives_mod },
            },
        }),
    });
    linkRustSupport(abi_tests_tests, target, rust_crypto);
    const run_abi_tests_tests = b.addRunArtifact(abi_tests_tests);
    run_abi_tests_tests.step.dependOn(launch_policy_preflight_step);

    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("src/fuzz_tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "primitives", .module = modules.primitives_mod },
            .{ .name = "state-manager", .module = modules.state_manager_mod },
            .{ .name = "blockchain", .module = modules.blockchain_mod },
            .{ .name = "crypto", .module = modules.crypto_mod },
            .{ .name = "precompiles", .module = modules.precompiles_mod },
            .{ .name = "guillotine_mini", .module = modules.guillotine_mini_mod },
            .{ .name = "jsonrpc", .module = modules.jsonrpc_mod },
        },
    });
    fuzz_mod.addIncludePath(modules.c_kzg_include_path);
    fuzz_mod.addIncludePath(modules.blst_include_path);

    const fuzz_tests = b.addTest(.{
        .name = "zevm-fuzz",
        .root_module = fuzz_mod,
        .filters = fuzz_filters,
        .use_llvm = true,
    });
    linkRustSupport(fuzz_tests, target, rust_crypto);
    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);
    run_fuzz_tests.step.dependOn(launch_policy_preflight_step);

    const c_abi_fuzz_c_mod = createCBindingsModule(b, target, optimize, modules);
    const c_abi_fuzz_mod = b.createModule(.{
        .root_source_file = b.path("tools/c_abi_fuzz_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "c_bindings", .module = c_abi_fuzz_c_mod },
        },
    });
    const c_abi_fuzz_tests = b.addTest(.{
        .name = "zevm-c-abi-fuzz",
        .root_module = c_abi_fuzz_mod,
        .filters = fuzz_filters,
        .use_llvm = true,
    });
    c_abi_fuzz_tests.linkLibC();
    linkRustSupport(c_abi_fuzz_tests, target, rust_crypto);
    const run_c_abi_fuzz_tests = b.addRunArtifact(c_abi_fuzz_tests);
    run_c_abi_fuzz_tests.step.dependOn(launch_policy_preflight_step);

    const fuzz_c_abi_step = b.step("fuzz-c-abi", "Run C ABI fuzz and property tests (supports -Dfuzz-filter and --fuzz on Linux)");
    fuzz_c_abi_step.dependOn(&run_c_abi_fuzz_tests.step);

    const fuzz_step = b.step("fuzz", "Run all zevm fuzz and property suites (supports -Dfuzz-filter and --fuzz on Linux)");
    fuzz_step.dependOn(&run_fuzz_tests.step);
    if (fuzz_filter == null) {
        fuzz_step.dependOn(&run_c_abi_fuzz_tests.step);
    }

    const lean_diff_fuzz = b.addExecutable(.{
        .name = "lean-diff-fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/lean_diff_fuzz.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zevm", .module = modules.zevm_mod },
                .{ .name = "primitives", .module = modules.primitives_mod },
                .{ .name = "precompiles", .module = modules.precompiles_mod },
                .{ .name = "guillotine_mini", .module = modules.guillotine_mini_mod },
            },
        }),
    });
    linkRustSupport(lean_diff_fuzz, target, rust_crypto);
    const run_lean_diff_fuzz = b.addRunArtifact(lean_diff_fuzz);
    run_lean_diff_fuzz.step.dependOn(launch_policy_preflight_step);
    if (b.args) |args| {
        run_lean_diff_fuzz.addArgs(args);
    } else {
        run_lean_diff_fuzz.addArgs(&.{ "--lean-bin", "spec/lean/.lake/build/bin/zevm-spec" });
    }
    const diff_fuzz_lean_step = b.step("diff-fuzz-lean", "Run differential fuzzing comparing Zig implementations against the Lean 4 reference spec");
    diff_fuzz_lean_step.dependOn(&run_lean_diff_fuzz.step);

    const startup_smoke_step = b.step("startup-smoke", "Run executable startup failure smoke tests");
    const startup_smoke_files = b.addWriteFiles();

    const missing_config_smoke = b.addRunArtifact(exe);
    missing_config_smoke.step.dependOn(launch_policy_preflight_step);
    missing_config_smoke.addArgs(&.{ "--config", ".zig-cache/startup-smoke/missing.json" });
    missing_config_smoke.expectExitCode(1);
    missing_config_smoke.addCheck(.{ .expect_stderr_match = "\"scope\":\"startup\"" });
    missing_config_smoke.addCheck(.{ .expect_stderr_match = "path=.zig-cache/startup-smoke/missing.json" });
    missing_config_smoke.addCheck(.{ .expect_stderr_match = "failureClass=missing-file" });
    startup_smoke_step.dependOn(&missing_config_smoke.step);

    const malformed_config = startup_smoke_files.add("malformed-config.json", "{");
    const malformed_config_smoke = b.addRunArtifact(exe);
    malformed_config_smoke.step.dependOn(launch_policy_preflight_step);
    malformed_config_smoke.addArg("--config");
    malformed_config_smoke.addFileArg(malformed_config);
    malformed_config_smoke.expectExitCode(1);
    malformed_config_smoke.addCheck(.{ .expect_stderr_match = "\"scope\":\"startup\"" });
    malformed_config_smoke.addCheck(.{ .expect_stderr_match = "malformed-config.json" });
    malformed_config_smoke.addCheck(.{ .expect_stderr_match = "failureClass=malformed-json" });
    startup_smoke_step.dependOn(&malformed_config_smoke.step);

    const schema_config = startup_smoke_files.add("schema-config.json",
        \\{ "unknown": true }
    );
    const schema_config_smoke = b.addRunArtifact(exe);
    schema_config_smoke.step.dependOn(launch_policy_preflight_step);
    schema_config_smoke.addArg("--config");
    schema_config_smoke.addFileArg(schema_config);
    schema_config_smoke.expectExitCode(1);
    schema_config_smoke.addCheck(.{ .expect_stderr_match = "\"scope\":\"startup\"" });
    schema_config_smoke.addCheck(.{ .expect_stderr_match = "schema-config.json" });
    schema_config_smoke.addCheck(.{ .expect_stderr_match = "failureClass=schema" });
    startup_smoke_step.dependOn(&schema_config_smoke.step);

    const rlp_tests_mod = b.createModule(.{
        .root_source_file = b.path("tools/rlp_tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "primitives", .module = modules.primitives_mod },
        },
    });
    const rlp_tests_unit = b.addTest(.{ .root_module = rlp_tests_mod });
    linkRustSupport(rlp_tests_unit, target, rust_crypto);
    const run_rlp_tests_unit = b.addRunArtifact(rlp_tests_unit);
    run_rlp_tests_unit.step.dependOn(launch_policy_preflight_step);

    const rlp_tests_exe = b.addExecutable(.{ .name = "rlp-tests", .root_module = rlp_tests_mod });
    linkRustSupport(rlp_tests_exe, target, rust_crypto);
    const run_rlp_tests = b.addRunArtifact(rlp_tests_exe);
    run_rlp_tests.step.dependOn(launch_policy_preflight_step);
    run_rlp_tests.addDirectoryArg(b.path("."));
    const verify_rlp_step = b.step("verify-rlp", "Run ethereum-tests/RLPTests against the RLP codec");
    verify_rlp_step.dependOn(&run_rlp_tests_unit.step);
    verify_rlp_step.dependOn(&run_rlp_tests.step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_test_graph_check.step);
    test_step.dependOn(startup_smoke_step);
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_c_abi_fuzz_tests.step);
    test_step.dependOn(&run_qualification_check_tests.step);
    test_step.dependOn(&run_dependency_preflight_tests.step);
    test_step.dependOn(&run_abi_tests_tests.step);
    test_step.dependOn(&run_rlp_tests_unit.step);

    const external_verify_exe = b.addExecutable(.{
        .name = "external-verify",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/external_verify.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zevm", .module = mod },
                .{ .name = "primitives", .module = modules.primitives_mod },
                .{ .name = "state-manager", .module = modules.state_manager_mod },
                .{ .name = "guillotine_mini", .module = modules.guillotine_mini_mod },
                .{ .name = "rlp_tests", .module = rlp_tests_mod },
            },
        }),
    });

    linkRustSupport(external_verify_exe, target, rust_crypto);
    const run_external_verify = b.addRunArtifact(external_verify_exe);
    run_external_verify.step.dependOn(launch_policy_preflight_step);
    run_external_verify.addDirectoryArg(b.path("."));
    run_external_verify.addArtifactArg(exe);
    if (b.args) |args| {
        run_external_verify.addArgs(args);
    }

    const trie_tests_module = b.createModule(.{
        .root_source_file = b.path("tools/trie_tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zevm", .module = mod },
            .{ .name = "primitives", .module = modules.primitives_mod },
        },
    });
    const trie_tests_exe = b.addExecutable(.{
        .name = "trie-tests",
        .root_module = trie_tests_module,
    });
    linkRustSupport(trie_tests_exe, target, rust_crypto);
    const run_trie_tests = b.addRunArtifact(trie_tests_exe);
    run_trie_tests.step.dependOn(launch_policy_preflight_step);
    run_trie_tests.addDirectoryArg(b.path("."));
    const trie_tests_step = b.step("trie-tests", "Run ethereum-tests/TrieTests against ZEVM trie roots and proofs");
    trie_tests_step.dependOn(&run_trie_tests.step);

    const trie_tests_unit = b.addTest(.{ .root_module = trie_tests_module });
    linkRustSupport(trie_tests_unit, target, rust_crypto);
    const run_trie_tests_unit = b.addRunArtifact(trie_tests_unit);
    run_trie_tests_unit.step.dependOn(launch_policy_preflight_step);
    test_step.dependOn(&run_trie_tests_unit.step);
    trie_tests_step.dependOn(&run_trie_tests_unit.step);

    const transaction_tests = b.addExecutable(.{
        .name = "transaction-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/transaction_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zevm", .module = mod },
                .{ .name = "guillotine_mini", .module = modules.guillotine_mini_mod },
            },
        }),
    });
    linkRustSupport(transaction_tests, target, rust_crypto);
    const run_transaction_tests = b.addRunArtifact(transaction_tests);
    run_transaction_tests.step.dependOn(launch_policy_preflight_step);
    if (b.args) |args| run_transaction_tests.addArgs(args);
    b.step("transaction-tests", "Run the ethereum-tests TransactionTests fixtures").dependOn(&run_transaction_tests.step);

    const difficulty_tests = b.addExecutable(.{
        .name = "difficulty-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/difficulty_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zevm", .module = mod },
            },
        }),
    });
    linkRustSupport(difficulty_tests, target, rust_crypto);
    const run_difficulty_tests = b.addRunArtifact(difficulty_tests);
    run_difficulty_tests.step.dependOn(launch_policy_preflight_step);
    if (b.args) |args| run_difficulty_tests.addArgs(args);
    b.step("difficulty-tests", "Run the ethereum-tests DifficultyTests fixtures").dependOn(&run_difficulty_tests.step);

    const eof_tests = b.addExecutable(.{
        .name = "eof-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/eof_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zevm", .module = mod },
            },
        }),
    });
    linkRustSupport(eof_tests, target, rust_crypto);
    const run_eof_tests = b.addRunArtifact(eof_tests);
    run_eof_tests.step.dependOn(launch_policy_preflight_step);
    if (b.args) |args| run_eof_tests.addArgs(args);
    b.step("eof-tests", "Run the ethereum-tests EOFTests static validation fixtures").dependOn(&run_eof_tests.step);

    const blockchain_tests_module = b.createModule(.{
        .root_source_file = b.path("tools/blockchain_tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zevm", .module = mod },
            .{ .name = "primitives", .module = modules.primitives_mod },
            .{ .name = "guillotine_mini", .module = modules.guillotine_mini_mod },
            .{ .name = "state-manager", .module = modules.state_manager_mod },
        },
    });
    const blockchain_tests = b.addExecutable(.{
        .name = "blockchain-tests",
        .root_module = blockchain_tests_module,
    });
    linkRustSupport(blockchain_tests, target, rust_crypto);
    const run_blockchain_tests = b.addRunArtifact(blockchain_tests);
    run_blockchain_tests.step.dependOn(launch_policy_preflight_step);
    if (b.args) |args| run_blockchain_tests.addArgs(args);
    const blockchain_tests_step = b.step("blockchain-tests", "Run the ethereum-tests BlockchainTests fixtures");
    blockchain_tests_step.dependOn(&run_blockchain_tests.step);

    const blockchain_tests_unit = b.addTest(.{ .root_module = blockchain_tests_module });
    linkRustSupport(blockchain_tests_unit, target, rust_crypto);
    const run_blockchain_tests_unit = b.addRunArtifact(blockchain_tests_unit);
    run_blockchain_tests_unit.step.dependOn(launch_policy_preflight_step);
    test_step.dependOn(&run_blockchain_tests_unit.step);
    blockchain_tests_step.dependOn(&run_blockchain_tests_unit.step);

    const early_state_step = b.step("verify-early-state", "Verify Frontier through Istanbul state fixtures and report each fork");
    const run_early_state = b.addRunArtifact(external_verify_exe);
    run_early_state.step.dependOn(launch_policy_preflight_step);
    run_early_state.addDirectoryArg(b.path("."));
    run_early_state.addArg("--early-state");
    if (b.args) |args| run_early_state.addArgs(args);
    early_state_step.dependOn(&run_early_state.step);

    const run_mid_forks = b.addRunArtifact(external_verify_exe);
    run_mid_forks.step.dependOn(launch_policy_preflight_step);
    run_mid_forks.addDirectoryArg(b.path("."));
    run_mid_forks.addArg("--mid-forks");
    if (b.args) |args| run_mid_forks.addArgs(args);
    b.step("verify-mid-forks", "Verify Berlin and Shanghai external state tests").dependOn(&run_mid_forks.step);

    const external_verify_tests = b.addTest(.{ .root_module = external_verify_exe.root_module });
    linkRustSupport(external_verify_tests, target, rust_crypto);
    const run_external_verify_tests = b.addRunArtifact(external_verify_tests);
    run_external_verify_tests.step.dependOn(launch_policy_preflight_step);
    test_step.dependOn(&run_external_verify_tests.step);
    const external_verify_test_step = b.step("test-external-verify", "Run external verification runner unit tests");
    external_verify_test_step.dependOn(&run_external_verify_tests.step);

    // Cancun/Prague GeneralStateTests report from the pinned ethereum/tests
    // archive, gated by tools/latest_fork_state_baseline.json.
    const run_latest_fork_state = b.addRunArtifact(external_verify_exe);
    run_latest_fork_state.step.dependOn(launch_policy_preflight_step);
    run_latest_fork_state.addDirectoryArg(b.path("."));
    run_latest_fork_state.addArtifactArg(exe);
    run_latest_fork_state.addArg("--latest-fork-state");
    if (b.args) |args| {
        run_latest_fork_state.addArgs(args);
    }
    const latest_fork_state_step = b.step("verify-latest-state", "Run Cancun and Prague GeneralStateTests and check per-category pass floors");
    latest_fork_state_step.dependOn(&run_latest_fork_state.step);

    const verify_fast_step = b.step("verify-fast", "Run fast local verification");
    verify_fast_step.dependOn(test_step);

    const verify_step = b.step("verify", "Run fast checks and active external suite slices");
    run_external_verify.step.dependOn(verify_fast_step);
    verify_step.dependOn(&run_external_verify.step);
    const run_verify_trie_tests = b.addRunArtifact(trie_tests_exe);
    run_verify_trie_tests.addDirectoryArg(b.path("."));
    run_verify_trie_tests.step.dependOn(verify_fast_step);
    verify_step.dependOn(&run_verify_trie_tests.step);

    const abi_tests_exe = b.addExecutable(.{
        .name = "abi-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/abi_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "primitives", .module = modules.primitives_mod },
            },
        }),
    });
    linkRustSupport(abi_tests_exe, target, rust_crypto);
    const run_abi_tests = b.addRunArtifact(abi_tests_exe);
    run_abi_tests.step.dependOn(launch_policy_preflight_step);
    run_abi_tests.addDirectoryArg(b.path("."));
    const abi_tests_step = b.step("abi-tests", "Run ethereum-tests/ABITests against primitives.Abi");
    abi_tests_step.dependOn(&run_abi_tests_tests.step);
    abi_tests_step.dependOn(&run_abi_tests.step);
    verify_step.dependOn(&run_abi_tests.step);

    // C ABI libraries for embedding in non-Zig hosts (Swift, C/C++, N-API).
    // Additive only: the default `zig build` step still produces the CLI.
    const static_lib = addCAbiLibrary(b, "zevm", .static, target, optimize, modules);
    const shared_lib = addCAbiLibrary(b, "zevm", .dynamic, target, optimize, modules);

    const install_static_lib = b.addInstallArtifact(static_lib, .{});
    const install_shared_lib = b.addInstallArtifact(shared_lib, .{});
    const install_zevm_header = b.addInstallFile(b.path("include/zevm.h"), "include/zevm.h");

    const static_lib_step = b.step("static-lib", "Build libzevm.a + install zevm.h for C/Swift consumers");
    static_lib_step.dependOn(&install_static_lib.step);
    static_lib_step.dependOn(&install_zevm_header.step);

    const shared_lib_step = b.step("shared-lib", "Build a shared C ABI library + install zevm.h");
    shared_lib_step.dependOn(&install_shared_lib.step);
    shared_lib_step.dependOn(&install_zevm_header.step);

    const c_ffi_step = b.step("c-ffi", "Build static/shared C ABI libraries and public header");
    c_ffi_step.dependOn(static_lib_step);
    c_ffi_step.dependOn(shared_lib_step);

    // C-side linkage smoke test. Exists to prove the static library is
    // self-contained enough to be linked from a vanilla C program; not
    // wired into `zig build test` because it is an integration check.
    const c_smoke_exe = b.addExecutable(.{
        .name = "zevm-c-smoke",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    c_smoke_exe.addCSourceFile(.{ .file = b.path("tools/c_smoke.c"), .flags = &.{"-std=c11"} });
    c_smoke_exe.addIncludePath(b.path("include"));
    c_smoke_exe.linkLibrary(static_lib);
    c_smoke_exe.linkLibC();
    linkRustSupport(c_smoke_exe, target, rust_crypto);

    const run_c_smoke = b.addRunArtifact(c_smoke_exe);
    run_c_smoke.step.dependOn(launch_policy_preflight_step);
    run_c_smoke.expectExitCode(0);
    run_c_smoke.addCheck(.{ .expect_stdout_match = "ok" });

    const c_smoke_step = b.step("c-smoke", "Compile and run a C program that links libzevm.a");
    c_smoke_step.dependOn(&install_static_lib.step);
    c_smoke_step.dependOn(&install_zevm_header.step);
    c_smoke_step.dependOn(&run_c_smoke.step);

    const npm_native_c_mod = createCBindingsModule(b, target, optimize, modules);
    const npm_native = addNapiAddon(b, target, modules, npm_native_c_mod, "npm/native", "zevm.node");
    const npm_native_step = b.step("npm-native", "Build the local Node-API addon at zig-out/npm/native/zevm.node");
    npm_native_step.dependOn(&npm_native.step);

    const npm_native_path = b.getInstallPath(.{ .custom = "npm/native" }, "zevm.node");
    const npm_smoke_cmd = b.addSystemCommand(&.{ "node", "npm/zevm/scripts/smoke.cjs", npm_native_path });
    const npm_smoke_step = b.step("npm-smoke", "Run a Node-API addon smoke test");
    npm_smoke_step.dependOn(&npm_native.step);
    npm_smoke_cmd.step.dependOn(&npm_native.step);
    npm_smoke_step.dependOn(&npm_smoke_cmd.step);
    const execution_smoke = b.addSystemCommand(&.{ "node", "npm/zevm/scripts/execution-smoke.cjs", npm_native_path });
    execution_smoke.step.dependOn(&npm_native.step);
    npm_smoke_step.dependOn(&execution_smoke.step);

    const release_name = releaseTargetName(b, target);
    const npm_platform_name = npmPlatformName(b, target);
    if (release_name != null or npm_platform_name != null) {
        const release_voltaire = voltaireDependency(b, target, .ReleaseSafe);
        const release_modules = createModuleSet(b, target, .ReleaseSafe, "zevm_release", release_voltaire, rust_crypto);
        if (release_name) |name| {
            const release_exe = addZevmCli(b, target, .ReleaseSafe, release_modules);
            const install_release_exe = b.addInstallArtifact(release_exe, .{
                .dest_dir = .{ .override = .{ .custom = b.fmt("dist/{s}/bin", .{name}) } },
            });
            release_binaries_step.dependOn(&install_release_exe.step);
        }
        if (npm_platform_name) |name| {
            const npm_platform_c_mod = createCBindingsModule(b, target, .ReleaseSafe, release_modules);
            npm_platform_c_mod.strip = true;
            const npm_platform_addon = addNapiAddon(
                b,
                target,
                release_modules,
                npm_platform_c_mod,
                b.fmt("npm/prebuilds/{s}", .{name}),
                "zevm.node",
            );
            npm_platform_step.dependOn(&npm_platform_addon.step);
        }
    }
    if (release_name == null) {
        release_binaries_step.dependOn(&b.addFail("No release binary is published for the selected target").step);
    }
    if (npm_platform_name == null) {
        npm_platform_step.dependOn(&b.addFail("No npm addon is published for the selected target").step);
    }

    // Performance benchmark suites (each wired as its own `bench-<suite>` step
    // so Smithers PACKAGE.ts targets can build and run only affected suites).
    const bench_harness_mod = b.createModule(.{
        .root_source_file = b.path("bench/harness.zig"),
        .target = target,
        .optimize = optimize,
    });
    const bench_suites = [_]struct {
        name: []const u8,
        root: []const u8,
        link_c_abi: bool = false,
    }{
        .{ .name = "database", .root = "bench/database/main.zig" },
        .{ .name = "host-adapter", .root = "bench/host-adapter/main.zig" },
        .{ .name = "tx-encoding", .root = "bench/tx-encoding/main.zig" },
        .{ .name = "blob-kzg", .root = "bench/blob-kzg/main.zig" },
        .{ .name = "tx-processor", .root = "bench/tx-processor/main.zig" },
        .{ .name = "txpool", .root = "bench/txpool/main.zig" },
        .{ .name = "block-builder", .root = "bench/block-builder/main.zig" },
        .{ .name = "indexes", .root = "bench/indexes/main.zig" },
        .{ .name = "mpt-proof", .root = "bench/mpt-proof/main.zig" },
        .{ .name = "consensus-light", .root = "bench/consensus-light/main.zig" },
        .{ .name = "chain-genesis", .root = "bench/chain-genesis/main.zig" },
        .{ .name = "mining-node", .root = "bench/mining-node/main.zig" },
        .{ .name = "rpc", .root = "bench/rpc/main.zig" },
        .{ .name = "config-cli-log", .root = "bench/config-cli-log/main.zig" },
        .{ .name = "c-ffi", .root = "bench/c-ffi/main.zig", .link_c_abi = true },
    };

    const bench_all_step = b.step("bench", "Run all performance benchmark suites");
    for (bench_suites) |suite| {
        const bench_exe = b.addExecutable(.{
            .name = b.fmt("bench-{s}", .{suite.name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(suite.root),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "harness", .module = bench_harness_mod },
                    .{ .name = "zevm", .module = mod },
                    .{ .name = "primitives", .module = modules.primitives_mod },
                    .{ .name = "state-manager", .module = modules.state_manager_mod },
                    .{ .name = "blockchain", .module = modules.blockchain_mod },
                    .{ .name = "crypto", .module = modules.crypto_mod },
                    .{ .name = "precompiles", .module = modules.precompiles_mod },
                    .{ .name = "guillotine_mini", .module = modules.guillotine_mini_mod },
                    .{ .name = "jsonrpc", .module = modules.jsonrpc_mod },
                },
            }),
        });
        if (suite.link_c_abi) {
            bench_exe.linkLibrary(static_lib);
            bench_exe.linkLibC();
        }
        linkRustSupport(bench_exe, target, rust_crypto);

        const run_bench = b.addRunArtifact(bench_exe);
        run_bench.step.dependOn(launch_policy_preflight_step);
        if (b.args) |args| {
            run_bench.addArgs(args);
        }

        const suite_step = b.step(
            b.fmt("bench-{s}", .{suite.name}),
            b.fmt("Run {s} performance benchmark suite", .{suite.name}),
        );
        suite_step.dependOn(&run_bench.step);
        bench_all_step.dependOn(&run_bench.step);
    }
}

fn createModuleSet(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zevm_module_name: []const u8,
    voltaire: *std.Build.Dependency,
    rust_crypto: RustCrypto,
) ModuleSet {
    const primitives_mod = voltaire.module("primitives");
    const state_manager_mod = voltaire.module("state-manager");
    const blockchain_mod = voltaire.module("blockchain");
    const crypto_mod = voltaire.module("crypto");
    const precompiles_mod = voltaire.module("precompiles");
    const jsonrpc_mod = voltaire.module("jsonrpc");

    // Import the maintained interpreter sources using the same Voltaire modules
    // as ZEVM. Evaluating its standalone build would instantiate a second graph
    // with paths relative to its checkout (which may be a symlink).

    const gm_build_options = b.addOptions();
    gm_build_options.addOption(usize, "vector_length", 16);
    const gm_build_options_mod = gm_build_options.createModule();

    const guillotine_mini_mod = b.addModule(b.fmt("guillotine_mini_for_{s}", .{zevm_module_name}), .{
        .root_source_file = b.path("../guillotine-mini/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "primitives", .module = primitives_mod },
            .{ .name = "voltaire", .module = primitives_mod },
            .{ .name = "precompiles", .module = precompiles_mod },
            .{ .name = "crypto", .module = crypto_mod },
            .{ .name = "build_options", .module = gm_build_options_mod },
        },
    });

    const zevm_mod = b.addModule(zevm_module_name, .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "primitives", .module = primitives_mod },
            .{ .name = "state-manager", .module = state_manager_mod },
            .{ .name = "blockchain", .module = blockchain_mod },
            .{ .name = "crypto", .module = crypto_mod },
            .{ .name = "precompiles", .module = precompiles_mod },
            .{ .name = "guillotine_mini", .module = guillotine_mini_mod },
            .{ .name = "jsonrpc", .module = jsonrpc_mod },
        },
    });

    const c_kzg_include_path = voltaire.path("packages/voltaire-zig/lib/c-kzg-4844/src");
    const blst_include_path = voltaire.path("packages/voltaire-zig/lib/c-kzg-4844/blst/bindings");
    zevm_mod.addIncludePath(c_kzg_include_path);
    zevm_mod.addIncludePath(blst_include_path);

    return .{
        .rust_crypto = rust_crypto,
        .primitives_mod = primitives_mod,
        .state_manager_mod = state_manager_mod,
        .blockchain_mod = blockchain_mod,
        .crypto_mod = crypto_mod,
        .precompiles_mod = precompiles_mod,
        .jsonrpc_mod = jsonrpc_mod,
        .guillotine_mini_mod = guillotine_mini_mod,
        .zevm_mod = zevm_mod,
        .c_kzg_include_path = c_kzg_include_path,
        .blst_include_path = blst_include_path,
    };
}

fn voltaireDependency(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Dependency {
    const dependency = b.dependency("voltaire", .{ .target = target, .optimize = optimize });
    if (target.result.os.tag == .windows) {
        // MSVC translates the C KeccakResult enum as signed. Keep the upstream
        // wrapper and select its actual ABI type in the generated crypto module.
        const crypto_dir = dependency.path("packages/voltaire-zig/src/crypto");
        const wrapper = crypto_dir.path(b, "keccak_asm.zig");
        const source = std.fs.cwd().readFileAlloc(b.allocator, wrapper.getPath(b), 1024 * 1024) catch |err|
            std.debug.panic("cannot read Voltaire Keccak wrapper: {s}", .{@errorName(err)});
        const old_signature = "fn keccakResultToError(result: c_uint)";
        if (std.mem.indexOf(u8, source, old_signature) != null) {
            const files = b.addWriteFiles();
            const dir = files.addCopyDirectory(crypto_dir, "crypto", .{ .exclude_extensions = &.{"keccak_asm.zig"} });
            const patched = std.mem.replaceOwned(u8, b.allocator, source, old_signature, "fn keccakResultToError(result: c.KeccakResult)") catch @panic("OOM");
            _ = files.add("crypto/keccak_asm.zig", patched);
            dependency.module("crypto").root_source_file = dir.path(b, "root.zig");
        }

        // The pinned Voltaire passes the ELF -fPIC flag to its C archives.
        // COFF uses relocations directly, and Clang rejects the flag on MSVC.
        for ([_][]const u8{ "blst", "c-kzg-4844" }) |name| {
            const module = dependency.artifact(name).root_module;
            for (module.link_objects.items) |object| {
                if (object != .c_source_files) continue;
                const sources = object.c_source_files;
                for (sources.flags, 0..) |flag, i| {
                    if (std.mem.eql(u8, flag, "-fPIC")) {
                        sources.flags = std.mem.concat(b.allocator, []const u8, &.{ sources.flags[0..i], sources.flags[i + 1 ..] }) catch @panic("OOM");
                        break;
                    }
                }
            }
        }
    }
    return dependency;
}

fn configureRustCrypto(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    rust_target: []const u8,
    voltaire: *std.Build.Dependency,
    skip_rust_build: bool,
) RustCrypto {
    const explicit_target = usesExplicitRustTarget(target);
    const filename = if (target.result.os.tag == .windows and target.result.abi == .msvc)
        "crypto_wrappers.lib"
    else
        "libcrypto_wrappers.a";
    const target_dir = b.graph.env_map.get("CARGO_TARGET_DIR") orelse "";
    const cargo_output: std.Build.LazyPath = if (std.fs.path.isAbsolute(target_dir))
        .{ .cwd_relative = target_dir }
    else
        voltaire.path(if (target_dir.len == 0) "target" else target_dir);
    const archive_path = if (explicit_target)
        b.fmt("{s}/release/{s}", .{ rust_target, filename })
    else
        b.fmt("release/{s}", .{filename});
    const archive = cargo_output.path(b, archive_path);
    if (skip_rust_build) return .{ .build_step = null, .archive = archive };

    const cargo_build = b.addSystemCommand(&.{ "cargo", "build", "--release" });
    cargo_build.setName("voltaire-rust-crypto");
    cargo_build.setCwd(voltaire.path("."));
    if (explicit_target) {
        cargo_build.addArgs(&.{ "--target", rust_target, "--no-default-features", "--features", "portable" });
    }
    return .{ .build_step = &cargo_build.step, .archive = archive };
}

fn rustTargetTriple(target: std.Build.ResolvedTarget) ?[]const u8 {
    if (target.result.cpu.arch == .wasm64) return null;
    if (target.result.cpu.arch == .wasm32) return "wasm32-unknown-unknown";

    return switch (target.result.os.tag) {
        .linux => switch (target.result.abi) {
            .gnu => switch (target.result.cpu.arch) {
                .x86_64 => "x86_64-unknown-linux-gnu",
                .aarch64 => "aarch64-unknown-linux-gnu",
                else => return null,
            },
            .musl => switch (target.result.cpu.arch) {
                .x86_64 => "x86_64-unknown-linux-musl",
                .aarch64 => "aarch64-unknown-linux-musl",
                else => return null,
            },
            else => return null,
        },
        .freebsd => switch (target.result.cpu.arch) {
            .x86_64 => "x86_64-unknown-freebsd",
            .aarch64 => "aarch64-unknown-freebsd",
            else => return null,
        },
        .macos => switch (target.result.cpu.arch) {
            .x86_64 => "x86_64-apple-darwin",
            .aarch64 => "aarch64-apple-darwin",
            else => return null,
        },
        .windows => switch (target.result.abi) {
            .gnu => switch (target.result.cpu.arch) {
                .x86_64 => "x86_64-pc-windows-gnu",
                .x86 => "i686-pc-windows-gnu",
                .aarch64 => "aarch64-pc-windows-gnu",
                else => return null,
            },
            .msvc => switch (target.result.cpu.arch) {
                .x86_64 => "x86_64-pc-windows-msvc",
                .x86 => "i686-pc-windows-msvc",
                .aarch64 => "aarch64-pc-windows-msvc",
                else => return null,
            },
            else => return null,
        },
        else => return null,
    };
}

fn usesExplicitRustTarget(target: std.Build.ResolvedTarget) bool {
    // Match Voltaire even when Zig and rustup choose different Windows host ABIs.
    if (target.result.os.tag == .windows) return true;
    if (target.result.cpu.arch == .wasm32) return true;
    if (target.result.os.tag != builtin.target.os.tag) return true;
    if (target.result.cpu.arch != builtin.target.cpu.arch) return true;
    if (target.result.abi != builtin.target.abi) return true;
    return false;
}

fn releaseTargetName(b: *std.Build, target: std.Build.ResolvedTarget) ?[]const u8 {
    const arch = switch (target.result.cpu.arch) {
        .aarch64 => "aarch64",
        .x86 => "x86",
        .x86_64 => "x86_64",
        else => return null,
    };
    const os = switch (target.result.os.tag) {
        .freebsd => "freebsd",
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
        else => return null,
    };
    if (target.result.os.tag == .linux or target.result.os.tag == .windows) {
        return b.fmt("{s}-{s}-{s}", .{ arch, os, @tagName(target.result.abi) });
    }
    return b.fmt("{s}-{s}", .{ arch, os });
}

fn npmPlatformName(b: *std.Build, target: std.Build.ResolvedTarget) ?[]const u8 {
    const arch = switch (target.result.cpu.arch) {
        .aarch64 => "arm64",
        .x86 => "ia32",
        .x86_64 => "x64",
        else => return null,
    };
    const os = switch (target.result.os.tag) {
        .freebsd => "freebsd",
        .macos => "darwin",
        .linux => "linux",
        .windows => "win32",
        else => return null,
    };
    if (target.result.os.tag == .linux or target.result.os.tag == .windows) {
        return b.fmt("{s}-{s}-{s}", .{ os, arch, @tagName(target.result.abi) });
    }
    return b.fmt("{s}-{s}", .{ os, arch });
}

fn addZevmCli(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    modules: ModuleSet,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "zevm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zevm", .module = modules.zevm_mod },
            },
        }),
    });
    linkRustSupport(exe, target, modules.rust_crypto);
    return exe;
}

fn createCBindingsModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    modules: ModuleSet,
) *std.Build.Module {
    const c_bindings_mod = b.createModule(.{
        .root_source_file = b.path("src/c_bindings.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "primitives", .module = modules.primitives_mod },
            .{ .name = "crypto", .module = modules.crypto_mod },
            .{ .name = "state-manager", .module = modules.state_manager_mod },
            .{ .name = "blockchain", .module = modules.blockchain_mod },
            .{ .name = "precompiles", .module = modules.precompiles_mod },
            .{ .name = "guillotine_mini", .module = modules.guillotine_mini_mod },
            .{ .name = "jsonrpc", .module = modules.jsonrpc_mod },
        },
    });
    c_bindings_mod.addIncludePath(modules.c_kzg_include_path);
    c_bindings_mod.addIncludePath(modules.blst_include_path);
    return c_bindings_mod;
}

fn addCAbiLibrary(
    b: *std.Build,
    name: []const u8,
    linkage: std.builtin.LinkMode,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    modules: ModuleSet,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = name,
        .linkage = linkage,
        .root_module = createCBindingsModule(b, target, optimize, modules),
        // Zig 0.15.2's self-hosted x86_64 backend (the Debug default on
        // x86_64-linux) miscompiles this shared library: the first RPC
        // dereferences a null allocator vtable. The static archive keeps the
        // default backend, which bundles the Rust crypto objects c-smoke needs.
        .use_llvm = if (linkage == .dynamic) true else null,
    });
    lib.linkLibC();
    linkRustSupport(lib, target, modules.rust_crypto);
    return lib;
}

fn addNapiAddon(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    modules: ModuleSet,
    c_bindings_mod: *std.Build.Module,
    install_dir: []const u8,
    filename: []const u8,
) *std.Build.Step.InstallArtifact {
    const napi_lib = b.addLibrary(.{
        .name = "zevm_napi",
        .linkage = .dynamic,
        .root_module = c_bindings_mod,
        // See addCAbiLibrary: the self-hosted x86_64 backend segfaults this
        // addon on its first nodeRpc call.
        .use_llvm = true,
    });
    napi_lib.addCSourceFile(.{ .file = b.path("npm/zevm/native/zevm_napi.c"), .flags = &.{"-std=c11"} });
    napi_lib.addIncludePath(b.path("include"));
    napi_lib.addIncludePath(b.path("npm/zevm/native"));
    napi_lib.linkLibC();
    if (target.result.os.tag == .windows) {
        if (b.graph.env_map.get("ZEVM_NODE_IMPORT_LIB")) |lib| {
            napi_lib.root_module.addObjectFile(.{ .cwd_relative = lib });
        } else {
            napi_lib.linkSystemLibrary("node");
        }
    } else {
        napi_lib.linker_allow_shlib_undefined = true;
    }
    linkRustSupport(napi_lib, target, modules.rust_crypto);

    return b.addInstallArtifact(napi_lib, .{
        .dest_dir = .{ .override = .{ .custom = install_dir } },
        .dest_sub_path = filename,
    });
}

fn linkRustSupport(compile: *std.Build.Step.Compile, target: std.Build.ResolvedTarget, rust_crypto: RustCrypto) void {
    if (rust_crypto.build_step) |step| compile.step.dependOn(step);
    if (target.result.cpu.arch != .wasm32) compile.root_module.addObjectFile(rust_crypto.archive);
    if (target.result.os.tag == .linux) {
        compile.linkSystemLibrary(if (target.result.abi == .musl) "unwind" else "gcc_s");
    } else if (target.result.os.tag == .windows and target.result.abi == .msvc) {
        // Rust's staticlib already supplies compiler_builtins. On COFF the
        // weak aliases in Zig's second runtime collide at final link.
        compile.bundle_compiler_rt = false;
        // std.json uses roundq for checked integer conversion. Rust lacks this
        // quad-precision math routine and the two f80 conversions it uses.
        const b = compile.step.owner;
        for ([_][]const u8{ "round.zig", "extendxftf2.zig", "trunctfxf2.zig" }) |file| {
            const source = b.graph.zig_lib_directory.join(b.allocator, &.{ "compiler_rt", file }) catch @panic("OOM");
            const obj = b.addObject(.{
                .name = std.fs.path.stem(file),
                .root_module = b.createModule(.{
                    .root_source_file = .{ .cwd_relative = source },
                    .target = target,
                    .optimize = .ReleaseFast,
                    .link_libc = true,
                }),
            });
            obj.bundle_compiler_rt = false;
            compile.addObject(obj);
        }
        // Synchronization.lib supplies the Win32 address waits used by std.
        for ([_][]const u8{ "kernel32", "ntdll", "userenv", "ws2_32", "dbghelp", "synchronization" }) |lib|
            compile.linkSystemLibrary(lib);
    } else if (target.result.os.tag == .windows and target.result.abi == .gnu) {
        compile.linkSystemLibrary("gcc_eh");
    }
}
