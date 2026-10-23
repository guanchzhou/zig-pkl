const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zig_pkl", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zig_pkl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig_pkl", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Print library information");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    const unit_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const integration_mod = b.createModule(.{
        .root_source_file = b.path("tests/integration.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zig_pkl", .module = mod },
        },
    });
    const integration_tests = b.addTest(.{
        .root_module = integration_mod,
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    const integration_step = b.step("integration-test", "Run tests that use the pkl executable when it is installed");
    integration_step.dependOn(&run_integration_tests.step);

    const fuzz_config = b.addOptions();
    fuzz_config.addOption(u64, "iterations", b.option(u64, "fuzz-iterations", "Mutated inputs per fuzz run (default 20000)") orelse 20_000);
    fuzz_config.addOption(u64, "seed", b.option(u64, "fuzz-seed", "Seed for reproducible fuzz runs") orelse 0x5eed_9c1a);
    const fuzz_exe = b.addExecutable(.{
        .name = "fuzz-decoders",
        .root_module = b.createModule(.{
            .root_source_file = b.path("fuzz/decoders.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig_pkl", .module = mod },
                .{ .name = "fuzz_config", .module = fuzz_config.createModule() },
            },
        }),
    });
    const run_fuzz = b.addRunArtifact(fuzz_exe);
    const fuzz_step = b.step("fuzz", "Run bounded deterministic fuzzing of the protocol and value decoders");
    fuzz_step.dependOn(&run_fuzz.step);
}
