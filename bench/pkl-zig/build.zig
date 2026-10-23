//! Builds the pkl-zig side of the comparative benchmark with Zig 0.16.0,
//! the toolchain that pkl-zig 6a113ab requires.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const pkl = b.dependency("pkl", .{ .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{
        .name = "bench-pkl-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pkl", .module = pkl.module("pkl") },
            },
        }),
    });
    b.installArtifact(exe);
}
