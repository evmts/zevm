const builtin = @import("builtin");
const std = @import("std");

const ModuleSet = struct {
    voltaire_rust_crypto: *std.Build.Step.Run,
    primitives_mod: *std.Build.Module,
    state_manager_mod: *std.Build.Module,
    blockchain_mod: *std.Build.Module,
    crypto_mod: *std.Build.Module,
    precompiles_mod: *std.Build.Module,
    jsonrpc_mod: *std.Build.Module,
    guillotine_mini_mod: *std.Build.Module,
    zevm_mod: *std.Build.Module,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const modules = createModuleSet(b, target, optimize, "zevm");
    const mod = modules.zevm_mod;

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

    exe.step.dependOn(&modules.voltaire_rust_crypto.step);
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

    const dependency_preflight_step = b.step("dependency-preflight", "Validate package dependency pins and optional expected revisions");
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
    mod_tests.step.dependOn(&modules.voltaire_rust_crypto.step);
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
                .{ .name = "primitives", .module = modules.primitives_mod },
                .{ .name = "state-manager", .module = modules.state_manager_mod },
                .{ .name = "guillotine_mini", .module = modules.guillotine_mini_mod },
            },
        }),
    });

    external_verify_exe.step.dependOn(&modules.voltaire_rust_crypto.step);
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

    // C ABI libraries for embedding in non-Zig hosts (Swift, C/C++, N-API).
    // Additive only: the default `zig build` step still produces the CLI.
    const c_bindings_mod = createCBindingsModule(b, target, optimize, modules);
    const static_lib = addCAbiLibrary(b, "zevm", .static, c_bindings_mod, target, modules);
    const shared_lib = addCAbiLibrary(b, "zevm", .dynamic, c_bindings_mod, target, modules);

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
    linkRustSupport(c_smoke_exe, target);
    c_smoke_exe.step.dependOn(&modules.voltaire_rust_crypto.step);

    const run_c_smoke = b.addRunArtifact(c_smoke_exe);
    run_c_smoke.step.dependOn(&launch_policy_preflight_cmd.step);
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
    npm_smoke_step.dependOn(&npm_smoke_cmd.step);

    const release_name = releaseTargetName(b, target);
    const release_binaries_step = b.step("release-binaries", "Build the selected target's ReleaseSafe ZEVM CLI under zig-out/dist/<target>/bin");
    const release_modules = createModuleSet(b, target, .ReleaseSafe, "zevm_release");
    const release_exe = addZevmCli(b, target, .ReleaseSafe, release_modules);
    const install_release_exe = b.addInstallArtifact(release_exe, .{
        .dest_dir = .{ .override = .{ .custom = b.fmt("dist/{s}/bin", .{release_name}) } },
    });
    release_binaries_step.dependOn(&install_release_exe.step);

    const npm_platform_name = npmPlatformName(b, target);
    const npm_platform_step = b.step("npm-platform-artifacts", "Build the selected target's ReleaseSafe Node-API addon under zig-out/npm/prebuilds");
    const npm_platform_modules = createModuleSet(b, target, .ReleaseSafe, "zevm_npm_platform");
    const npm_platform_c_mod = createCBindingsModule(b, target, .ReleaseSafe, npm_platform_modules);
    const npm_platform_addon = addNapiAddon(
        b,
        target,
        npm_platform_modules,
        npm_platform_c_mod,
        b.fmt("npm/prebuilds/{s}", .{npm_platform_name}),
        "zevm.node",
    );
    npm_platform_step.dependOn(&npm_platform_addon.step);
}

fn createModuleSet(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zevm_module_name: []const u8,
) ModuleSet {
    const voltaire = b.dependency("voltaire", .{
        .target = target,
        .optimize = optimize,
    });
    const voltaire_rust_crypto = addVoltaireRustCryptoStep(b, target);
    voltaire_rust_crypto.setName("voltaire-rust-crypto");
    voltaire_rust_crypto.setCwd(voltaire.path("."));
    const primitives_mod = voltaire.module("primitives");
    const state_manager_mod = voltaire.module("state-manager");
    const blockchain_mod = voltaire.module("blockchain");
    const crypto_mod = voltaire.module("crypto");
    const precompiles_mod = voltaire.module("precompiles");
    const jsonrpc_mod = voltaire.module("jsonrpc");

    const guillotine_mini_dep = b.dependency("guillotine-mini", .{
        .target = target,
        .optimize = optimize,
    });

    const gm_build_options = b.addOptions();
    gm_build_options.addOption(usize, "vector_length", 16);
    const gm_build_options_mod = gm_build_options.createModule();

    const guillotine_mini_mod = b.addModule(b.fmt("guillotine_mini_for_{s}", .{zevm_module_name}), .{
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

    return .{
        .voltaire_rust_crypto = voltaire_rust_crypto,
        .primitives_mod = primitives_mod,
        .state_manager_mod = state_manager_mod,
        .blockchain_mod = blockchain_mod,
        .crypto_mod = crypto_mod,
        .precompiles_mod = precompiles_mod,
        .jsonrpc_mod = jsonrpc_mod,
        .guillotine_mini_mod = guillotine_mini_mod,
        .zevm_mod = zevm_mod,
    };
}

fn addVoltaireRustCryptoStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
) *std.Build.Step.Run {
    const cargo_build = b.addSystemCommand(&[_][]const u8{ "cargo", "build", "--release" });
    if (usesExplicitRustTarget(target)) {
        cargo_build.addArg("--target");
        cargo_build.addArg(rustTargetTriple(target));
    }
    if (needsPortableRustCrypto(target)) {
        cargo_build.addArg("--no-default-features");
        cargo_build.addArg("--features");
        cargo_build.addArg("portable");
    }
    return cargo_build;
}

fn rustTargetTriple(target: std.Build.ResolvedTarget) []const u8 {
    if (target.result.cpu.arch == .wasm32 or target.result.cpu.arch == .wasm64) {
        return "wasm32-unknown-unknown";
    }

    return switch (target.result.os.tag) {
        .linux => switch (target.result.abi) {
            .gnu => switch (target.result.cpu.arch) {
                .x86_64 => "x86_64-unknown-linux-gnu",
                .aarch64 => "aarch64-unknown-linux-gnu",
                else => unsupportedTarget("unsupported Linux GNU Rust architecture"),
            },
            .musl => switch (target.result.cpu.arch) {
                .x86_64 => "x86_64-unknown-linux-musl",
                .aarch64 => "aarch64-unknown-linux-musl",
                else => unsupportedTarget("unsupported Linux musl Rust architecture"),
            },
            else => unsupportedTarget("unsupported Linux Rust ABI"),
        },
        .freebsd => switch (target.result.cpu.arch) {
            .x86_64 => "x86_64-unknown-freebsd",
            .aarch64 => "aarch64-unknown-freebsd",
            else => unsupportedTarget("unsupported FreeBSD Rust architecture"),
        },
        .macos => switch (target.result.cpu.arch) {
            .x86_64 => "x86_64-apple-darwin",
            .aarch64 => "aarch64-apple-darwin",
            else => unsupportedTarget("unsupported macOS Rust architecture"),
        },
        .windows => switch (target.result.abi) {
            .gnu => switch (target.result.cpu.arch) {
                .x86_64 => "x86_64-pc-windows-gnu",
                .x86 => "i686-pc-windows-gnu",
                .aarch64 => "aarch64-pc-windows-gnu",
                else => unsupportedTarget("unsupported Windows GNU Rust architecture"),
            },
            .msvc => switch (target.result.cpu.arch) {
                .x86_64 => "x86_64-pc-windows-msvc",
                .x86 => "i686-pc-windows-msvc",
                .aarch64 => "aarch64-pc-windows-msvc",
                else => unsupportedTarget("unsupported Windows MSVC Rust architecture"),
            },
            else => unsupportedTarget("unsupported Windows Rust architecture"),
        },
        else => unsupportedTarget("unsupported Rust target OS"),
    };
}

fn usesExplicitRustTarget(target: std.Build.ResolvedTarget) bool {
    if (target.result.cpu.arch == .wasm32 or target.result.cpu.arch == .wasm64) return true;
    if (target.result.os.tag != builtin.target.os.tag) return true;
    if (target.result.cpu.arch != builtin.target.cpu.arch) return true;
    if (target.result.os.tag == .linux and target.result.abi != builtin.target.abi) return true;
    return false;
}

fn needsPortableRustCrypto(target: std.Build.ResolvedTarget) bool {
    return usesExplicitRustTarget(target);
}

fn releaseTargetName(b: *std.Build, target: std.Build.ResolvedTarget) []const u8 {
    const arch = switch (target.result.cpu.arch) {
        .aarch64 => "aarch64",
        .x86 => "x86",
        .x86_64 => "x86_64",
        else => unsupportedTarget("unsupported release CPU architecture"),
    };
    const os = switch (target.result.os.tag) {
        .freebsd => "freebsd",
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
        else => unsupportedTarget("unsupported release OS"),
    };
    if (target.result.os.tag == .linux or target.result.os.tag == .windows) {
        return b.fmt("{s}-{s}-{s}", .{ arch, os, @tagName(target.result.abi) });
    }
    return b.fmt("{s}-{s}", .{ arch, os });
}

fn npmPlatformName(b: *std.Build, target: std.Build.ResolvedTarget) []const u8 {
    const arch = switch (target.result.cpu.arch) {
        .aarch64 => "arm64",
        .x86 => "ia32",
        .x86_64 => "x64",
        else => unsupportedTarget("unsupported npm CPU architecture"),
    };
    const os = switch (target.result.os.tag) {
        .freebsd => "freebsd",
        .macos => "darwin",
        .linux => "linux",
        .windows => "win32",
        else => unsupportedTarget("unsupported npm OS"),
    };
    if (target.result.os.tag == .linux or target.result.os.tag == .windows) {
        return b.fmt("{s}-{s}-{s}", .{ os, arch, @tagName(target.result.abi) });
    }
    return b.fmt("{s}-{s}", .{ os, arch });
}

fn unsupportedTarget(message: []const u8) noreturn {
    std.debug.print("error: {s}\n", .{message});
    std.process.exit(1);
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
    exe.step.dependOn(&modules.voltaire_rust_crypto.step);
    linkRustSupport(exe, target);
    return exe;
}

fn createCBindingsModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    modules: ModuleSet,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/c_bindings.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "primitives", .module = modules.primitives_mod },
            .{ .name = "crypto", .module = modules.crypto_mod },
        },
    });
}

fn addCAbiLibrary(
    b: *std.Build,
    name: []const u8,
    linkage: std.builtin.LinkMode,
    c_bindings_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    modules: ModuleSet,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = name,
        .linkage = linkage,
        .root_module = c_bindings_mod,
    });
    lib.linkLibC();
    lib.step.dependOn(&modules.voltaire_rust_crypto.step);
    linkRustSupport(lib, target);
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
    });
    napi_lib.addCSourceFile(.{ .file = b.path("npm/zevm/native/zevm_napi.c"), .flags = &.{"-std=c11"} });
    napi_lib.addIncludePath(b.path("include"));
    napi_lib.addIncludePath(b.path("npm/zevm/native"));
    napi_lib.linkLibC();
    napi_lib.linker_allow_shlib_undefined = true;
    napi_lib.step.dependOn(&modules.voltaire_rust_crypto.step);
    linkRustSupport(napi_lib, target);

    return b.addInstallArtifact(napi_lib, .{
        .dest_dir = .{ .override = .{ .custom = install_dir } },
        .dest_sub_path = filename,
    });
}

fn linkRustSupport(compile: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) void {
    if (target.result.os.tag == .linux) {
        compile.linkSystemLibrary("gcc_s");
    } else if (target.result.os.tag == .windows and target.result.abi == .gnu) {
        compile.linkSystemLibrary("gcc_eh");
    }
}
