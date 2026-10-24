//! Evaluates untrusted Pkl with no file, network, or environment access.

const std = @import("std");
const zig_pkl = @import("zig_pkl");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const pkl = init.environ_map.get("PKL_EXEC") orelse "pkl";

    const manager = try zig_pkl.Manager.init(allocator, io, &.{ pkl, "server" }, zig_pkl.Logger.noop);
    defer manager.deinit();
    var rejected: ?[]u8 = null;
    defer if (rejected) |text| allocator.free(text);

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    const out = &stdout.interface;

    // Only `pkl:` and `repl:` modules, no resources, an empty environment,
    // and a deadline for runaway evaluation.
    var options = zig_pkl.Options.restricted();
    options.timeout_seconds = 5;
    const sandbox = try manager.createEvaluator(options, &rejected);
    defer sandbox.close();

    const attempts = [_][]const u8{
        "result = 6 * 7",
        "result = read(\"env:HOME\")",
        "result = import(\"file:///etc/hosts\")",
        "result = read(\"https://example.com/\")",
    };
    for (attempts) |text| {
        var failure: ?[]u8 = null;
        defer if (failure) |message| allocator.free(message);
        if (sandbox.evaluateSource(.text(text), "result", &failure)) |result| {
            var tree = result;
            defer tree.deinit();
            try out.print("allowed: {s} -> {d}\n", .{ text, tree.root.int.signed });
        } else |err| switch (err) {
            error.EvaluationFailed => try out.print("denied:  {s}\n         {s}\n", .{ text, reason(failure.?) }),
            else => return err,
        }
    }

    // Grant exactly one environment variable and nothing else.
    var narrow = zig_pkl.Options.restricted();
    narrow.allowed_resources = &.{"env:"};
    narrow.env = &.{.{ .key = "REGION", .value = "eu-west-1" }};
    const scoped = try manager.createEvaluator(narrow, &rejected);
    defer scoped.close();
    var failure: ?[]u8 = null;
    defer if (failure) |message| allocator.free(message);
    var region = try scoped.evaluateSource(.text("region = read(\"env:REGION\")\nhome = read?(\"env:HOME\")"), null, &failure);
    defer region.deinit();
    const home = zig_pkl.value.findProperty(region.root, "home").?;
    try out.print("REGION = {s}, HOME visible: {}\n", .{ zig_pkl.value.findProperty(region.root, "region").?.string, home.* != .nil });
    try out.flush();
}

/// The reason in a Pkl error message, after its `–– Pkl Error ––` banner.
fn reason(text: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " ");
        if (trimmed.len != 0 and std.mem.indexOf(u8, trimmed, "Pkl Error") == null) return trimmed;
    }
    return text;
}
