//! Reads the text, files, and bytes a module renders through `output`.

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
    const evaluator = try manager.createEvaluator(zig_pkl.Options.preconfigured(), &rejected);
    defer evaluator.close();

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    const out = &stdout.interface;

    const module_uri = try zig_pkl.uri.fromFile(allocator, io, "site.pkl");
    defer allocator.free(module_uri);
    const site = zig_pkl.Source.uri(module_uri);
    var failure: ?[]u8 = null;
    defer if (failure) |text| allocator.free(text);

    // The module's own renderer produces `output.text`.
    var text = try evaluator.evaluateSource(site, "output.text", &failure);
    defer text.deinit();
    try out.print("output.text:\n{s}\n", .{text.root.string});

    // Each entry of `output.files` renders with its own renderer.
    var files = try evaluator.evaluateSource(site, "output.files.toMap().mapValues((_, file) -> file.text)", &failure);
    defer files.deinit();
    for (files.root.map) |entry| try out.print("file {s}:\n{s}", .{ entry.key.string, entry.value.string });

    // `output.bytes` exists from Pkl 0.29.
    const version = try zig_pkl.getVersion(allocator, io, pkl);
    if (version.atLeast(.{ .major = 0, .minor = 29, .patch = 0 })) {
        var bytes = try evaluator.evaluateSource(site, "output.bytes", &failure);
        defer bytes.deinit();
        try out.print("output.bytes: {d} bytes\n", .{bytes.root.bytes.len});
    }

    // `output_format` picks the renderer for modules that do not set one.
    var options = zig_pkl.Options.preconfigured();
    options.output_format = "yaml";
    const yaml = try manager.createEvaluator(options, &rejected);
    defer yaml.close();
    var rendered = try yaml.evaluateSource(.text("name = \"edge\"\nports = List(80, 443)"), "output.text", &failure);
    defer rendered.deinit();
    try out.print("as yaml:\n{s}", .{rendered.root.string});
    try out.flush();
}
