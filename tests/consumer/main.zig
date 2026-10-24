//! Evaluates Pkl through a zig-pkl package fetched with `zig fetch`.

const std = @import("std");
const zig_pkl = @import("zig_pkl");

const Service = struct {
    name: []const u8,
    port: u16,
    tags: []const []const u8,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const pkl = init.environ_map.get("PKL_EXEC") orelse "pkl";

    const manager = try zig_pkl.Manager.init(allocator, io, &.{ pkl, "server" }, zig_pkl.Logger.noop);
    defer manager.deinit();
    var rejected: ?[]u8 = null;
    defer if (rejected) |text| allocator.free(text);
    const evaluator = try manager.createEvaluator(zig_pkl.Options.restricted(), &rejected);
    defer evaluator.close();

    var failure: ?[]u8 = null;
    defer if (failure) |text| allocator.free(text);
    const module =
        \\name = "consumer"
        \\port = 8080
        \\tags = new Listing { "fetched"; "release" }
    ;
    const service = evaluator.evaluateInto(Service, allocator, .text(module), null, &failure) catch |err| {
        if (failure) |text| std.debug.print("{s}\n", .{text});
        return err;
    };
    defer zig_pkl.convert.freeInto(Service, allocator, service);

    if (!std.mem.eql(u8, service.name, "consumer") or service.port != 8080 or service.tags.len != 2) {
        return error.UnexpectedValue;
    }
    std.debug.print("{s} on port {d} with {d} tags\n", .{ service.name, service.port, service.tags.len });
}
