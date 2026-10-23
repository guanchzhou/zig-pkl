const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zig_pkl", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addAnonymousImport("zig_pkl_codegen_schema", .{ .root_source_file = b.path("codegen/Schema.pkl") });

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

    const toolchain = testToolchain(b);
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "codegen_test_toolchain", .module = toolchain },
        },
    });
    test_mod.addAnonymousImport("zig_pkl_codegen_schema", .{ .root_source_file = b.path("codegen/Schema.pkl") });

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    runInRoot(b, run_unit_tests);
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
    run_integration_tests.has_side_effects = true;
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

    const bench_exe = b.addExecutable(.{
        .name = "bench-zig-pkl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/zig-pkl.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig_pkl", .module = mod },
            },
        }),
    });
    const install_bench = b.addInstallArtifact(bench_exe, .{});
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.addDirectoryArg(b.path("bench/fixtures"));
    run_bench.addArg(b.option([]const u8, "pkl", "pkl executable used by the bench step (default pkl)") orelse "pkl");
    run_bench.has_side_effects = true;
    const bench_step = b.step("bench", "Run the zig-pkl benchmark once; use -Doptimize=ReleaseFast and -Dpkl=<path>");
    bench_step.dependOn(&install_bench.step);
    bench_step.dependOn(&run_bench.step);

    addCodegen(b, mod, test_mod, toolchain, target, optimize);
}

/// Generator invocations whose output is checked in. `zig build codegen`
/// refreshes them; `zig build codegen-test` fails when they are stale.
const checked_in_bindings = [_][]const []const u8{
    &.{ "--project-dir", "tests/codegen/fixtures", "--package", "shared=deps.shared", "-o", "tests/codegen/snapshots", "tests/codegen/fixtures/app.pkl", "tests/codegen/fixtures/refs.pkl" },
    &.{ "--project-dir", "examples/codegen", "-o", "examples/codegen/src/bindings", "examples/codegen/pkl/Service.pkl" },
};

const compile_targets = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
    .{ .cpu_arch = .riscv64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .x86, .os_tag = .linux, .abi = .musl },
};

fn addCodegen(
    b: *std.Build,
    mod: *std.Build.Module,
    test_mod: *std.Build.Module,
    toolchain: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const generator = b.addExecutable(.{
        .name = "zig-pkl-gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/codegen/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig_pkl", .module = mod },
            },
        }),
    });
    b.installArtifact(generator);

    const codegen_step = b.step("codegen", "Regenerate the checked-in bindings; arguments after -- such as --check or --pkl are passed to every run");
    for (checked_in_bindings) |args| {
        const run = b.addRunArtifact(generator);
        run.setCwd(b.path("."));
        run.addArgs(&.{ "--zig", b.graph.zig_exe, "--library", "." });
        run.addArgs(args);
        run.addPassthruArgs();
        codegen_step.dependOn(&run.step);
    }

    const codegen_test_step = b.step("codegen-test", "Run code generation tests, compile generated bindings for several targets, and test the example consumer");

    const unit_tests = b.addTest(.{ .root_module = test_mod, .filters = &.{"codegen"} });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    runInRoot(b, run_unit_tests);
    codegen_test_step.dependOn(&run_unit_tests.step);

    const bindings = fixtureBindings(b, mod, target, optimize);
    const live_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/codegen/live.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig_pkl", .module = mod },
                .{ .name = "fixture_bindings", .module = bindings },
                .{ .name = "codegen_test_toolchain", .module = toolchain },
            },
        }),
    });
    const run_live = b.addRunArtifact(live_tests);
    runInRoot(b, run_live);
    codegen_test_step.dependOn(&run_live.step);

    const native_compile = compileBindings(b, mod, target, optimize, bindings);
    codegen_test_step.dependOn(&b.addRunArtifact(native_compile).step);
    for (compile_targets) |query| {
        const cross = b.resolveTargetQuery(query);
        const cross_mod = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = cross,
            .optimize = optimize,
        });
        cross_mod.addAnonymousImport("zig_pkl_codegen_schema", .{ .root_source_file = b.path("codegen/Schema.pkl") });
        const compiled = compileBindings(b, cross_mod, cross, optimize, fixtureBindings(b, cross_mod, cross, optimize));
        _ = compiled.getEmittedBin();
        codegen_test_step.dependOn(&compiled.step);
    }

    const example = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "test", "--summary", "none" });
    example.setCwd(b.path("examples/codegen"));
    example.has_side_effects = true;
    codegen_test_step.dependOn(&example.step);
}

/// The toolchain tests use to type-check generated files. Paths are
/// relative to the build root; see `runInRoot`.
fn testToolchain(b: *std.Build) *std.Build.Module {
    const options = b.addOptions();
    options.addOption([]const u8, "zig", b.graph.zig_exe);
    options.addOption([]const u8, "library_root", "src/root.zig");
    options.addOption([]const u8, "schema", "codegen/Schema.pkl");
    return options.createModule();
}

/// Runs tests from the build root with the caller's environment, so that
/// `PKL_EXEC` and `ZIG_PKL_REQUIRE_PKL` are read when the tests run.
fn runInRoot(b: *std.Build, run: *std.Build.Step.Run) void {
    run.setCwd(b.path("."));
    run.has_side_effects = true;
}

fn fixtureBindings(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("tests/codegen/snapshots/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zig_pkl", .module = mod },
        },
    });
}

fn compileBindings(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    bindings: *std.Build.Module,
) *std.Build.Step.Compile {
    return b.addTest(.{
        .name = b.fmt("codegen-compile-{s}", .{target.result.zigTriple(b.allocator) catch @panic("OOM")}),
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/codegen/compile.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig_pkl", .module = mod },
                .{ .name = "fixture_bindings", .module = bindings },
            },
        }),
    });
}
