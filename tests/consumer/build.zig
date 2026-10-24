const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zig_pkl = b.dependency("zig_pkl", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "consumer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zig_pkl", .module = zig_pkl.module("zig_pkl") }},
        }),
    });
    b.step("run", "Evaluate a module with the fetched zig-pkl").dependOn(&b.addRunArtifact(exe).step);

    const generator = b.addRunArtifact(zig_pkl.artifact("zig-pkl-gen"));
    generator.addArg("--version");
    b.step("generator", "Run the fetched zig-pkl-gen").dependOn(&generator.step);
}
