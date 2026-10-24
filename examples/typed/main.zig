//! Decodes a Pkl module into Zig structs with `zig_pkl.convert`.

const std = @import("std");
const zig_pkl = @import("zig_pkl");
const convert = zig_pkl.convert;

const App = struct {
    name: []const u8,
    port: u16,
    debug: bool,
    timeout: convert.Duration,
    max_upload: convert.DataSize,
    tags: []const []const u8,
    limits: convert.Map([]const u8, i64),
    database: Database,

    pub const pkl_names = .{ .max_upload = "maxUpload" };
};

const Database = struct {
    host: []const u8,
    port: u16,
    replicas: []const []const u8,
};

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

    const module_uri = try zig_pkl.uri.fromFile(allocator, io, "prod.pkl");
    defer allocator.free(module_uri);
    var failure: ?[]u8 = null;
    defer if (failure) |text| allocator.free(text);
    const app = evaluator.evaluateInto(App, allocator, .uri(module_uri), null, &failure) catch |err| {
        if (failure) |text| std.debug.print("{s}\n", .{text});
        return err;
    };
    defer convert.freeInto(App, allocator, app);

    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    const out = &stdout.interface;
    try out.print("{s} on port {d}, debug {}\n", .{ app.name, app.port, app.debug });
    try out.print("timeout {d}{s}, uploads up to {d}{s}\n", .{ app.timeout.value, app.timeout.unit, app.max_upload.value, app.max_upload.unit });
    for (app.tags) |tag| try out.print("tag {s}\n", .{tag});
    for (app.limits.entries) |entry| try out.print("limit {s} = {d}\n", .{ entry.key, entry.value });
    try out.print("database {s}:{d} with {d} replicas\n", .{ app.database.host, app.database.port, app.database.replicas.len });
    try out.flush();
}
