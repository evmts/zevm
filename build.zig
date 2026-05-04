const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Import voltaire modules
    const voltaire = b.dependency("voltaire", .{
        .target = target,
        .optimize = optimize,
    });
    const voltaire_primitives_mod = voltaire.module("primitives");
    const state_manager_mod = voltaire.module("state-manager");
    const blockchain_mod = voltaire.module("blockchain");
    const crypto_mod = voltaire.module("crypto");
    const precompiles_mod = voltaire.module("precompiles");
    const jsonrpc_mod = voltaire.module("jsonrpc");

    const primitives_mod = b.addModule("zevm_primitives_compat", .{
        .root_source_file = b.path("src/primitives_compat.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "voltaire_primitives", .module = voltaire_primitives_mod },
        },
    });
    primitives_mod.addImport("primitives", primitives_mod);

    const consensus_spec_mod = b.createModule(.{
        .root_source_file = voltaire.path("packages/voltaire-zig/src/primitives/ConsensusSpec/ConsensusSpec.zig"),
        .target = target,
        .optimize = optimize,
    });
    consensus_spec_mod.addImport("primitives", primitives_mod);
    const fork_config_mod = b.createModule(.{
        .root_source_file = voltaire.path("packages/voltaire-zig/src/primitives/ForkConfig/ForkConfig.zig"),
        .target = target,
        .optimize = optimize,
    });
    fork_config_mod.addImport("primitives", primitives_mod);
    const light_client_header_mod = b.createModule(.{
        .root_source_file = voltaire.path("packages/voltaire-zig/src/primitives/LightClientHeader/LightClientHeader.zig"),
        .target = target,
        .optimize = optimize,
    });
    light_client_header_mod.addImport("primitives", primitives_mod);
    const light_client_update_mod = b.createModule(.{
        .root_source_file = voltaire.path("packages/voltaire-zig/src/primitives/LightClientUpdate/LightClientUpdate.zig"),
        .target = target,
        .optimize = optimize,
    });
    light_client_update_mod.addImport("primitives", primitives_mod);
    const sync_aggregate_mod = b.createModule(.{
        .root_source_file = voltaire.path("packages/voltaire-zig/src/primitives/SyncAggregate/SyncAggregate.zig"),
        .target = target,
        .optimize = optimize,
    });
    sync_aggregate_mod.addImport("primitives", primitives_mod);
    const sync_committee_mod = b.createModule(.{
        .root_source_file = voltaire.path("packages/voltaire-zig/src/primitives/SyncCommittee/SyncCommittee.zig"),
        .target = target,
        .optimize = optimize,
    });
    sync_committee_mod.addImport("primitives", primitives_mod);
    const consensus_mod = b.createModule(.{
        .root_source_file = voltaire.path("packages/voltaire-zig/src/primitives/consensus/consensus.zig"),
        .target = target,
        .optimize = optimize,
    });
    consensus_mod.addImport("primitives", primitives_mod);
    consensus_mod.addImport("crypto", crypto_mod);

    primitives_mod.addImport("consensus_spec", consensus_spec_mod);
    primitives_mod.addImport("fork_config", fork_config_mod);
    primitives_mod.addImport("light_client_header", light_client_header_mod);
    primitives_mod.addImport("light_client_update", light_client_update_mod);
    primitives_mod.addImport("sync_aggregate", sync_aggregate_mod);
    primitives_mod.addImport("sync_committee", sync_committee_mod);
    primitives_mod.addImport("consensus", consensus_mod);

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

    b.installArtifact(exe);

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
    qualification_check_cmd.addArg("--map");
    qualification_check_cmd.addFileArg(b.path("docs/specs/qualification/assertion-map.json"));
    if (b.args) |args| {
        qualification_check_cmd.addArgs(args);
    }
    qualification_check_step.dependOn(&qualification_check_cmd.step);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Tests
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const qualification_check_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/qualification_check.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_qualification_check_tests = b.addRunArtifact(qualification_check_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_qualification_check_tests.step);

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

    const run_external_verify = b.addRunArtifact(external_verify_exe);
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
}
