const std = @import("std");
const zig_pkl = @import("zig_pkl");
const Service = @import("bindings").service;

/// Evaluates `path` inside this directory's Pkl project and decodes it.
pub fn loadService(allocator: std.mem.Allocator, io: std.Io, manager: *zig_pkl.Manager, path: []const u8, failure: *?[]u8) !Service {
    var rejected: ?[]u8 = null;
    defer if (rejected) |text| manager.allocator.free(text);
    const loader = try manager.createEvaluator(zig_pkl.Options.preconfigured(), &rejected);
    defer loader.close();
    var project = try zig_pkl.project.loadFile(allocator, io, loader, "PklProject");
    defer project.deinit();

    var options = project.options;
    options.allowed_modules = zig_pkl.Options.preconfigured().allowed_modules;
    options.allowed_resources = zig_pkl.Options.preconfigured().allowed_resources;
    const evaluator = try manager.createEvaluator(options, &rejected);
    defer evaluator.close();
    const module_uri = try project.moduleUri(allocator, path);
    defer allocator.free(module_uri);
    return Service.load(allocator, evaluator, .uri(module_uri), failure);
}

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const path = if (args.len > 1) args[1] else "pkl/dev.pkl";
    const pkl = init.environ_map.get("PKL_EXEC") orelse "pkl";

    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout.interface;

    const manager = try zig_pkl.Manager.init(allocator, io, &.{ pkl, "server" }, zig_pkl.Logger.noop);
    defer manager.deinit();
    var failure: ?[]u8 = null;
    defer if (failure) |text| manager.allocator.free(text);
    var service = loadService(allocator, io, manager, path, &failure) catch |err| {
        if (failure) |text| std.debug.print("{s}\n", .{text});
        return err;
    };
    defer service.deinit(allocator);

    try out.print("listening on {s}:{d} (log level {t}, timeout {d}{s})\n", .{
        service.host, service.listen_port, service.log_level, service.timeout.value, service.timeout.unit,
    });
    for (service.routes) |route| {
        try out.print("route {s} -> {s} (", .{ route.path, route.backend });
        for (route.methods, 0..) |method, i| try out.print("{s}{t}", .{ if (i == 0) "" else ", ", method });
        try out.writeAll(")\n");
    }
    for (service.backends.entries) |entry| switch (entry.value) {
        .http_backend => |backend| try out.print("backend {s}: {s} weight {d}\n", .{ entry.key, backend.url, backend.weight }),
        .static_backend => |backend| try out.print("backend {s}: files in {s}\n", .{ entry.key, backend.directory }),
    };
    try out.flush();
    return 0;
}

test "the development configuration decodes into the generated types" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const pkl = std.process.Environ.getAlloc(std.testing.environ, allocator, "PKL_EXEC") catch |err| switch (err) {
        error.EnvironmentVariableMissing => try allocator.dupe(u8, "pkl"),
        else => return err,
    };
    defer allocator.free(pkl);
    const manager = zig_pkl.Manager.init(allocator, io, &.{ pkl, "server" }, zig_pkl.Logger.noop) catch |err| switch (err) {
        error.FileNotFound => return if (pklRequired()) error.PklRequired else error.SkipZigTest,
        else => return err,
    };
    defer manager.deinit();
    var failure: ?[]u8 = null;
    defer if (failure) |text| manager.allocator.free(text);
    var service = try loadService(allocator, io, manager, "pkl/dev.pkl", &failure);
    defer service.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 3000), service.listen_port);
    try std.testing.expectEqual(Service.LogLevel.debug, service.log_level);
    try std.testing.expectEqual(@as(f64, 1), service.max_body.value);
    try std.testing.expectEqualStrings("mib", service.max_body.unit);
    try std.testing.expectEqual(@as(usize, 2), service.routes.len);
    try std.testing.expectEqual(@as(usize, 2), service.routes[0].methods.len);
    try std.testing.expectEqual(Service.Method.post, service.routes[0].methods[1]);
    try std.testing.expectEqual(Service.Method.get, service.routes[1].methods[0]);
    try std.testing.expectEqual(@as(i64, 3), service.backends.get("api").?.http_backend.weight);
    try std.testing.expectEqualStrings("public", service.backends.get("assets").?.static_backend.directory);
    try std.testing.expect(service.tls == null);
}

/// Whether `ZIG_PKL_REQUIRE_PKL=1` asks for a missing Pkl to fail the test.
fn pklRequired() bool {
    const flag = std.process.Environ.getAlloc(std.testing.environ, std.testing.allocator, "ZIG_PKL_REQUIRE_PKL") catch return false;
    defer std.testing.allocator.free(flag);
    return std.mem.eql(u8, flag, "1");
}

test "the Pkl defaults are available without Pkl" {
    const service = Service{};
    try std.testing.expectEqual(@as(u16, 8080), service.listen_port);
    try std.testing.expectEqualStrings("127.0.0.1", service.host);
    try std.testing.expectEqual(@as(f64, 5), service.timeout.value);
    try std.testing.expectEqualStrings("s", service.timeout.unit);
    try std.testing.expectEqualStrings("mib", service.max_body.unit);
    try std.testing.expectEqual(@as(usize, 0), service.routes.len);
    try std.testing.expectEqual(@as(usize, 0), service.backends.entries.len);
    const route = Service.Route{ .path = "/", .backend = "api" };
    try std.testing.expectEqualSlices(Service.Method, &.{.get}, route.methods);
}
