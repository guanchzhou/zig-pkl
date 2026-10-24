//! Loads `PklProject` settings and dependencies, then evaluates a module
//! that imports a dependency by name.

const std = @import("std");
const zig_pkl = @import("zig_pkl");

const Settings = struct {
    environment: []const u8,
    buffer_size: zig_pkl.convert.DataSize,
    timeout: zig_pkl.convert.Duration,

    pub const pkl_names = .{ .buffer_size = "bufferSize" };
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const pkl = init.environ_map.get("PKL_EXEC") orelse "pkl";

    const manager = try zig_pkl.Manager.init(allocator, io, &.{ pkl, "server" }, zig_pkl.Logger.noop);
    defer manager.deinit();
    var rejected: ?[]u8 = null;
    defer if (rejected) |text| allocator.free(text);

    // Any evaluator can evaluate the project file itself.
    const loader = try manager.createEvaluator(zig_pkl.Options.preconfigured(), &rejected);
    defer loader.close();
    var project = try zig_pkl.project.loadFile(allocator, io, loader, "PklProject");
    defer project.deinit();

    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    const out = &stdout.interface;
    try out.print("project {s}\n", .{project.projectUri()});
    for (project.project.dependencies) |dependency| try out.print("dependency @{s}\n", .{dependency.name});

    // The project supplies its settings and dependencies; this program keeps
    // its own allow lists because the project does not set any.
    var options = project.options;
    if (options.allowed_modules == null) options.allowed_modules = zig_pkl.Options.preconfigured().allowed_modules;
    if (options.allowed_resources == null) options.allowed_resources = zig_pkl.Options.preconfigured().allowed_resources;
    const evaluator = try manager.createEvaluator(options, &rejected);
    defer evaluator.close();

    // Modules inside the project are addressed beside the canonical PklProject.
    const main_uri = try project.moduleUri(allocator, "main.pkl");
    defer allocator.free(main_uri);
    var failure: ?[]u8 = null;
    defer if (failure) |text| allocator.free(text);
    const settings = evaluator.evaluateInto(Settings, allocator, .uri(main_uri), null, &failure) catch |err| {
        if (failure) |text| std.debug.print("{s}\n", .{text});
        return err;
    };
    defer zig_pkl.convert.freeInto(Settings, allocator, settings);
    try out.print("environment {s}, buffer {d}{s}, timeout {d}{s}\n", .{
        settings.environment,
        settings.buffer_size.value,
        settings.buffer_size.unit,
        settings.timeout.value,
        settings.timeout.unit,
    });
    try out.flush();
}
