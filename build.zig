const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Import voltaire modules
    const voltaire = b.dependency("voltaire", .{
        .target = target,
        .optimize = optimize,
    });
    const voltaire_rust_crypto = b.addSystemCommand(&[_][]const u8{ "cargo", "build", "--release" });
    voltaire_rust_crypto.setName("voltaire-rust-crypto");
    voltaire_rust_crypto.setCwd(voltaire.path("."));
    const primitives_mod = voltaire.module("primitives");
    const state_manager_mod = voltaire.module("state-manager");
    const blockchain_mod = voltaire.module("blockchain");
    const crypto_mod = voltaire.module("crypto");
    const precompiles_mod = voltaire.module("precompiles");
    const jsonrpc_mod = voltaire.module("jsonrpc");

    // Get guillotine-mini dependency for source paths
    const guillotine_mini_dep = b.dependency("guillotine-mini", .{
        .target = target,
        .optimize = optimize,
    });

    // Create build_options module needed by guillotine-mini's evm_config.zig
    const gm_build_options = b.addOptions();
    gm_build_options.addOption(usize, "vector_length", 16);
    const gm_build_options_mod = gm_build_options.createModule();

    // Create guillotine-mini module using voltaire's primitives for type compatibility
    const guillotine_mini_mod = b.addModule("guillotine_mini", .{
        .root_source_file = guillotine_mini_dep.path("src/root.zig"),
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

    // zevm library module
    const mod = b.addModule("zevm", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
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

    // Executable
    const exe = b.addExecutable(.{
        .name = "zevm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zevm", .module = mod },
            },
        }),
    });

    exe.step.dependOn(&voltaire_rust_crypto.step);
    linkRustSupport(exe, target);
    b.installArtifact(exe);

    const launch_policy_preflight_cmd = b.addSystemCommand(&[_][]const u8{ "bun", "tools/macos_launch_policy_preflight.ts" });
    launch_policy_preflight_cmd.setName("launch-policy-preflight");
    const launch_policy_preflight_step = b.step("launch-policy-preflight", "Check that locally built executables can launch on this host");
    launch_policy_preflight_step.dependOn(&launch_policy_preflight_cmd.step);

    const release_metadata_exe = b.addExecutable(.{
        .name = "release-metadata",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/release_metadata.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const release_metadata_step = b.step("release-metadata", "Generate release metadata artifacts");
    const release_metadata_cmd = b.addRunArtifact(release_metadata_exe);
    release_metadata_cmd.step.dependOn(&launch_policy_preflight_cmd.step);
    if (b.args) |args| {
        release_metadata_cmd.addArgs(args);
    }
    release_metadata_step.dependOn(&release_metadata_cmd.step);

    const qualification_check_exe = b.addExecutable(.{
        .name = "qualification-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/qualification_check.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const qualification_check_step = b.step("qualification-check", "Validate release qualification assertion map");
    const qualification_check_cmd = b.addRunArtifact(qualification_check_exe);
    qualification_check_cmd.step.dependOn(&launch_policy_preflight_cmd.step);
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
            .target = target,
            .optimize = optimize,
        }),
    });

    const dependency_preflight_exe = b.addExecutable(.{
        .name = "dependency-preflight",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/dependency_preflight.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const dependency_preflight_step = b.step("dependency-preflight", "Validate sibling dependency worktrees and optional revision pins");
    const dependency_preflight_cmd = b.addRunArtifact(dependency_preflight_exe);
    dependency_preflight_cmd.step.dependOn(&launch_policy_preflight_cmd.step);
    if (b.args) |args| {
        dependency_preflight_cmd.addArgs(args);
    }
    dependency_preflight_step.dependOn(&dependency_preflight_cmd.step);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(&launch_policy_preflight_cmd.step);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Tests
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    mod_tests.step.dependOn(&voltaire_rust_crypto.step);
    linkRustSupport(mod_tests, target);
    const run_mod_tests = b.addRunArtifact(mod_tests);
    run_mod_tests.step.dependOn(&launch_policy_preflight_cmd.step);

    const qualification_check_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/qualification_check.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_qualification_check_tests = b.addRunArtifact(qualification_check_tests);
    run_qualification_check_tests.step.dependOn(&launch_policy_preflight_cmd.step);
    const dependency_preflight_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/dependency_preflight.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_dependency_preflight_tests = b.addRunArtifact(dependency_preflight_tests);
    run_dependency_preflight_tests.step.dependOn(&launch_policy_preflight_cmd.step);
    const run_test_graph_check = b.addRunArtifact(test_graph_check_exe);
    run_test_graph_check.step.dependOn(&launch_policy_preflight_cmd.step);

    const startup_smoke_step = b.step("startup-smoke", "Run executable startup failure smoke tests");
    const startup_smoke_files = b.addWriteFiles();

    const missing_config_smoke = b.addRunArtifact(exe);
    missing_config_smoke.step.dependOn(&launch_policy_preflight_cmd.step);
    missing_config_smoke.addArgs(&.{ "--config", ".zig-cache/startup-smoke/missing.json" });
    missing_config_smoke.expectExitCode(1);
    missing_config_smoke.addCheck(.{ .expect_stderr_match = "\"scope\":\"startup\"" });
    missing_config_smoke.addCheck(.{ .expect_stderr_match = "path=.zig-cache/startup-smoke/missing.json" });
    missing_config_smoke.addCheck(.{ .expect_stderr_match = "failureClass=missing-file" });
    startup_smoke_step.dependOn(&missing_config_smoke.step);

    const malformed_config = startup_smoke_files.add("malformed-config.json", "{");
    const malformed_config_smoke = b.addRunArtifact(exe);
    malformed_config_smoke.step.dependOn(&launch_policy_preflight_cmd.step);
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
    schema_config_smoke.step.dependOn(&launch_policy_preflight_cmd.step);
    schema_config_smoke.addArg("--config");
    schema_config_smoke.addFileArg(schema_config);
    schema_config_smoke.expectExitCode(1);
    schema_config_smoke.addCheck(.{ .expect_stderr_match = "\"scope\":\"startup\"" });
    schema_config_smoke.addCheck(.{ .expect_stderr_match = "schema-config.json" });
    schema_config_smoke.addCheck(.{ .expect_stderr_match = "failureClass=schema" });
    startup_smoke_step.dependOn(&schema_config_smoke.step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_test_graph_check.step);
    test_step.dependOn(startup_smoke_step);
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_qualification_check_tests.step);
    test_step.dependOn(&run_dependency_preflight_tests.step);

    const external_verify_exe = b.addExecutable(.{
        .name = "external-verify",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/external_verify.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zevm", .module = mod },
                .{ .name = "primitives", .module = primitives_mod },
                .{ .name = "state-manager", .module = state_manager_mod },
                .{ .name = "guillotine_mini", .module = guillotine_mini_mod },
            },
        }),
    });

    external_verify_exe.step.dependOn(&voltaire_rust_crypto.step);
    linkRustSupport(external_verify_exe, target);
    const run_external_verify = b.addRunArtifact(external_verify_exe);
    run_external_verify.step.dependOn(&launch_policy_preflight_cmd.step);
    run_external_verify.addDirectoryArg(b.path("."));
    run_external_verify.addArtifactArg(exe);
    if (b.args) |args| {
        run_external_verify.addArgs(args);
    }

    const verify_fast_step = b.step("verify-fast", "Run fast local verification");
    verify_fast_step.dependOn(test_step);

    const verify_step = b.step("verify", "Run fast checks and active external suite slices");
    run_external_verify.step.dependOn(verify_fast_step);
    verify_step.dependOn(&run_external_verify.step);

    // C ABI static library for embedding in non-Zig hosts (e.g. Swift).
    // Additive only: the default `zig build` step still produces just the
    // executable; this library is opt-in via `zig build static-lib`.
    const c_bindings_mod = b.createModule(.{
        .root_source_file = b.path("src/c_bindings.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "primitives", .module = primitives_mod },
            .{ .name = "crypto", .module = crypto_mod },
        },
    });
    const static_lib = b.addLibrary(.{
        .name = "zevm",
        .linkage = .static,
        .root_module = c_bindings_mod,
    });
    static_lib.linkLibC();
    static_lib.step.dependOn(&voltaire_rust_crypto.step);
    linkRustSupport(static_lib, target);

    const install_static_lib = b.addInstallArtifact(static_lib, .{});
    const install_zevm_header = b.addInstallFile(b.path("include/zevm.h"), "include/zevm.h");

    const static_lib_step = b.step("static-lib", "Build libzevm.a + install zevm.h for C/Swift consumers");
    static_lib_step.dependOn(&install_static_lib.step);
    static_lib_step.dependOn(&install_zevm_header.step);

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
    linkRustSupport(c_smoke_exe, target);
    c_smoke_exe.step.dependOn(&voltaire_rust_crypto.step);

    const run_c_smoke = b.addRunArtifact(c_smoke_exe);
    run_c_smoke.step.dependOn(&launch_policy_preflight_cmd.step);
    run_c_smoke.expectExitCode(0);
    run_c_smoke.addCheck(.{ .expect_stdout_match = "ok" });

    const c_smoke_step = b.step("c-smoke", "Compile and run a C program that links libzevm.a");
    c_smoke_step.dependOn(&install_static_lib.step);
    c_smoke_step.dependOn(&install_zevm_header.step);
    c_smoke_step.dependOn(&run_c_smoke.step);
}

fn linkRustSupport(compile: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) void {
    if (target.result.os.tag == .linux) {
        compile.linkSystemLibrary("gcc_s");
    }
}
