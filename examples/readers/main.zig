//! Serves modules and resources from the Zig program instead of the disk.

const std = @import("std");
const zig_pkl = @import("zig_pkl");

/// A resource reader for `secret:<name>` URIs backed by a fixed table.
const Secrets = struct {
    table: []const [2][]const u8,

    fn resourceReader(self: *Secrets) zig_pkl.ResourceReader {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = zig_pkl.ResourceReader.VTable{
        .scheme = scheme,
        .has_hierarchical_uris = no,
        .is_globbable = no,
        .read = read,
        .list = list,
    };

    fn scheme(_: *anyopaque) []const u8 {
        return "secret";
    }

    fn no(_: *anyopaque) bool {
        return false;
    }

    /// Runs on a reader thread. The result must come from `allocator`.
    fn read(ptr: *anyopaque, allocator: std.mem.Allocator, uri: []const u8) anyerror![]u8 {
        const self: *Secrets = @ptrCast(@alignCast(ptr));
        const name = uri["secret:".len..];
        for (self.table) |row| {
            if (std.mem.eql(u8, row[0], name)) return allocator.dupe(u8, row[1]);
        }
        return error.SecretNotFound;
    }

    fn list(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8) anyerror![]zig_pkl.reader.PathElement {
        return allocator.alloc(zig_pkl.reader.PathElement, 0);
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const pkl = init.environ_map.get("PKL_EXEC") orelse "pkl";

    // Modules compiled into the program, addressed as `embedded:/...`.
    var embedded = zig_pkl.reader.Embed{
        .scheme_name = "embedded",
        .entries = &.{
            .{ .path = "/base.pkl", .contents = "region = \"eu-west-1\"\nreplicas = 2\npassword: String\n" },
            .{ .path = "/services/api.pkl", .contents = "amends \"../base.pkl\"\nreplicas = 4\npassword = read(\"secret:api-password\").text\n" },
            .{ .path = "/services/worker.pkl", .contents = "amends \"../base.pkl\"\npassword = read(\"secret:worker-password\").text\n" },
        },
    };
    var secrets = Secrets{ .table = &.{
        .{ "api-password", "correct horse" },
        .{ "worker-password", "battery staple" },
    } };
    const module_readers = [_]zig_pkl.ModuleReader{embedded.moduleReader()};
    const resource_readers = [_]zig_pkl.ResourceReader{secrets.resourceReader()};

    // The builder adds `embedded:` and `secret:` to the allow lists.
    var builder = try zig_pkl.Builder.restricted(allocator);
    defer builder.deinit();
    _ = try builder.moduleReaders(&module_readers);
    _ = try builder.resourceReaders(&resource_readers);

    const manager = try zig_pkl.Manager.init(allocator, io, &.{ pkl, "server" }, zig_pkl.Logger.noop);
    defer manager.deinit();
    var rejected: ?[]u8 = null;
    defer if (rejected) |text| allocator.free(text);
    const evaluator = try manager.createEvaluator(builder.options, &rejected);
    defer evaluator.close();

    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    const out = &stdout.interface;
    var failure: ?[]u8 = null;
    defer if (failure) |text| allocator.free(text);

    // Globbing lists modules through the same reader.
    var names = evaluator.evaluateSource(
        .text("services = import*(\"embedded:/services/*.pkl\").keys.toList()"),
        "services",
        &failure,
    ) catch |err| {
        if (failure) |text| std.debug.print("{s}\n", .{text});
        return err;
    };
    defer names.deinit();
    for (names.root.list) |name| {
        var service = evaluator.evaluateSource(.uri(name.string), null, &failure) catch |err| {
            if (failure) |text| std.debug.print("{s}\n", .{text});
            return err;
        };
        defer service.deinit();
        const replicas = zig_pkl.value.findProperty(service.root, "replicas").?.int.signed;
        const password = zig_pkl.value.findProperty(service.root, "password").?.string;
        try out.print("{s}: {d} replicas, password {d} characters\n", .{ name.string, replicas, password.len });
    }
    try out.flush();
}
