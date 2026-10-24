//! Evaluates expressions against a module instead of the whole module.

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

    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    const out = &stdout.interface;

    const module_uri = try zig_pkl.uri.fromFile(allocator, io, "service.pkl");
    defer allocator.free(module_uri);
    const service = zig_pkl.Source.uri(module_uri);

    const expressions = [_][]const u8{
        "port",
        "endpoints.length",
        "url(endpoints.first)",
        "endpoints.map((path) -> url(path)).join(\", \")",
    };
    var failure: ?[]u8 = null;
    defer if (failure) |text| allocator.free(text);
    for (expressions) |expression| {
        var result = evaluator.evaluateSource(service, expression, &failure) catch |err| {
            if (failure) |text| std.debug.print("{s}\n", .{text});
            return err;
        };
        defer result.deinit();
        try out.print("{s} = ", .{expression});
        switch (result.root.*) {
            .int => |number| try out.print("{d}\n", .{number.signed}),
            .string => |text| try out.print("{s}\n", .{text}),
            else => |other| try out.print("({t})\n", .{other}),
        }
    }

    // An inline module needs no file.
    var sum = try evaluator.evaluateSource(.text("numbers = List(1, 2, 3, 4)"), "numbers.fold(0, (total, n) -> total + n)", &failure);
    defer sum.deinit();
    try out.print("sum of numbers = {d}\n", .{sum.root.int.signed});
    try out.flush();
}
