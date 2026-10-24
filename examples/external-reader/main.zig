//! Runs this same program as an external resource reader that Pkl starts.
//!
//! Without arguments it evaluates Pkl that reads `vault:` resources. Pkl then
//! starts `<this program> --serve`, which answers over standard input and
//! output. External readers need Pkl 0.27 or newer.

const std = @import("std");
const zig_pkl = @import("zig_pkl");

/// Resources served to Pkl as `vault:<name>`.
const Vault = struct {
    fn resourceReader(self: *Vault) zig_pkl.ResourceReader {
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
        return "vault";
    }

    fn no(_: *anyopaque) bool {
        return false;
    }

    fn read(_: *anyopaque, allocator: std.mem.Allocator, uri: []const u8) anyerror![]u8 {
        const name = uri["vault:".len..];
        return std.fmt.allocPrint(allocator, "token-for-{s}", .{name});
    }

    fn list(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8) anyerror![]zig_pkl.reader.PathElement {
        return allocator.alloc(zig_pkl.reader.PathElement, 0);
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 1 and std.mem.eql(u8, args[1], "--serve")) return serve(allocator, io);

    const pkl = init.environ_map.get("PKL_EXEC") orelse "pkl";
    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const version = try zig_pkl.getVersion(allocator, io, pkl);
    if (!version.atLeast(.{ .major = 0, .minor = 27, .patch = 0 })) {
        try out.print("external readers need Pkl 0.27 or newer; this is {d}.{d}.{d}\n", .{ version.major, version.minor, version.patch });
        return;
    }

    const self_path = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_path);
    var options = zig_pkl.Options.restricted();
    options.allowed_resources = &.{"vault:"};
    options.external_resource_readers = &.{.{
        .scheme = "vault",
        .executable = self_path,
        .arguments = &.{"--serve"},
    }};

    const manager = try zig_pkl.Manager.init(allocator, io, &.{ pkl, "server" }, zig_pkl.Logger.noop);
    defer manager.deinit();
    var rejected: ?[]u8 = null;
    defer if (rejected) |text| allocator.free(text);
    const evaluator = try manager.createEvaluator(options, &rejected);
    defer evaluator.close();

    var failure: ?[]u8 = null;
    defer if (failure) |text| allocator.free(text);
    var tree = evaluator.evaluateSource(
        .text("database = read(\"vault:database\").text\ncache = read(\"vault:cache\").text"),
        null,
        &failure,
    ) catch |err| {
        if (failure) |text| std.debug.print("{s}\n", .{text});
        return err;
    };
    defer tree.deinit();
    for (tree.root.object.members) |member| {
        try out.print("{s} = {s}\n", .{ member.property.name, member.property.value.string });
    }
}

/// The reader side. Standard output carries protocol frames only.
fn serve(allocator: std.mem.Allocator, io: std.Io) !void {
    var vault = Vault{};
    const client = zig_pkl.ExternalClient{ .resource_readers = &.{vault.resourceReader()} };
    var input_buffer: [64 * 1024]u8 = undefined;
    var output_buffer: [64 * 1024]u8 = undefined;
    var input = std.Io.File.stdin().readerStreaming(io, &input_buffer);
    var output = std.Io.File.stdout().writerStreaming(io, &output_buffer);
    try client.run(allocator, &input.interface, &output.interface);
}
