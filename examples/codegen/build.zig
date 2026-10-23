const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zig_pkl = b.dependency("zig_pkl", .{ .target = target, .optimize = optimize });
    const zig_pkl_mod = zig_pkl.module("zig_pkl");

    const bindings = b.createModule(.{
        .root_source_file = b.path("src/bindings/root.zig"),
        .imports = &.{
            .{ .name = "zig_pkl", .module = zig_pkl_mod },
        },
    });
    const app = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zig_pkl", .module = zig_pkl_mod },
            .{ .name = "bindings", .module = bindings },
        },
    });

    const exe = b.addExecutable(.{ .name = "service-config", .root_module = app });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.setCwd(b.path("."));
    run.addPassthruArgs();
    b.step("run", "Print the decoded development configuration").dependOn(&run.step);

    const tests = b.addRunArtifact(b.addTest(.{ .root_module = app }));
    tests.setCwd(b.path("."));
    tests.has_side_effects = true;
    b.step("test", "Decode the development configuration").dependOn(&tests.step);

    const codegen = b.addRunArtifact(zig_pkl.artifact("zig-pkl-gen"));
    codegen.setCwd(b.path("."));
    codegen.addArgs(&.{ "--zig", b.graph.zig_exe, "--library" });
    codegen.addDirectoryArg(zig_pkl.path("."));
    codegen.addArgs(&.{ "--project-dir", ".", "-o", "src/bindings", "pkl/Service.pkl" });
    codegen.addPassthruArgs();
    b.step("codegen", "Regenerate src/bindings from pkl/Service.pkl").dependOn(&codegen.step);
}
