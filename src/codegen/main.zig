//! `zig-pkl-gen`: generates Zig bindings for Pkl modules.

const std = @import("std");
const zig_pkl = @import("zig_pkl");
const codegen = zig_pkl.codegen;

const usage =
    \\Usage: zig-pkl-gen [options] <module>...
    \\
    \\Generates Zig bindings for each Pkl module and every module it references.
    \\A module is a path or an absolute URI such as package://... or modulepath:/...
    \\
    \\Options:
    \\  -o, --output-dir <dir>    Directory for generated files (required)
    \\  --project-dir <dir>       Directory with the PklProject that resolves @dependency imports
    \\  --package <match>=<path>  Place modules whose name or URI starts with <match> under <path>
    \\  --index-file <path>       Index file, a relative .zig path inside the output
    \\                            directory; modules go in its directory (default: root.zig)
    \\  --pkl <path>              Pkl executable (default: $PKL_EXEC, then pkl on PATH)
    \\  --allow-resource <regex>  Let defaults read resources whose URI matches this Pkl
    \\                            pattern, such as file: or env:HOME (repeatable; default: none)
    \\  --library <dir>           zig-pkl source directory used to type-check the bindings
    \\                            (default: $ZIG_PKL_LIBRARY)
    \\  --zig <path>              Zig executable for type-checking (default: $ZIG, then zig)
    \\  --no-verify               Write the bindings without type-checking them
    \\  --check                   Exit with status 1 when any generated file is out of date
    \\  --force                   Overwrite or delete files the generator did not write
    \\  -h, --help                Show this help
    \\
    \\The output directory records the files it generated in .zig-pkl-gen-manifest.
    \\Other files, and generated files edited since, are never changed without --force.
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buffer);
    var stderr_buffer: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &stderr_buffer);
    defer stdout.interface.flush() catch {};
    defer stderr.interface.flush() catch {};

    var modules: std.ArrayList([]const u8) = .empty;
    defer modules.deinit(allocator);
    var packages: std.ArrayList(codegen.PackageMapping) = .empty;
    defer packages.deinit(allocator);
    var resources: std.ArrayList([]const u8) = .empty;
    defer resources.deinit(allocator);
    var options = codegen.Options{ .modules = &.{}, .output_dir = "", .verify = .skip };
    var output_dir: ?[]const u8 = null;
    var pkl: ?[]const u8 = nonEmpty(init.environ_map.get("PKL_EXEC"));
    var library: ?[]const u8 = nonEmpty(init.environ_map.get("ZIG_PKL_LIBRARY"));
    var zig: []const u8 = nonEmpty(init.environ_map.get("ZIG")) orelse "zig";
    var verify = true;

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try stdout.interface.writeAll(usage);
            return 0;
        } else if (std.mem.eql(u8, arg, "--check")) {
            options.check = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
            options.force = true;
        } else if (std.mem.eql(u8, arg, "--no-verify")) {
            verify = false;
        } else if (std.mem.startsWith(u8, arg, "-") and !std.mem.eql(u8, arg, "-")) {
            if (index + 1 >= args.len) return usageError(&stderr.interface, "missing value for {s}", .{arg});
            index += 1;
            const next = args[index];
            if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output-dir")) {
                output_dir = next;
            } else if (std.mem.eql(u8, arg, "--project-dir")) {
                options.project_dir = next;
            } else if (std.mem.eql(u8, arg, "--index-file")) {
                options.index_file = next;
            } else if (std.mem.eql(u8, arg, "--pkl")) {
                pkl = next;
            } else if (std.mem.eql(u8, arg, "--allow-resource")) {
                try resources.append(allocator, next);
            } else if (std.mem.eql(u8, arg, "--library")) {
                library = next;
            } else if (std.mem.eql(u8, arg, "--zig")) {
                zig = next;
            } else if (std.mem.eql(u8, arg, "--package")) {
                const equals = std.mem.indexOfScalar(u8, next, '=') orelse
                    return usageError(&stderr.interface, "--package expects <match>=<path>, got `{s}`", .{next});
                try packages.append(allocator, .{ .match = next[0..equals], .package = next[equals + 1 ..] });
            } else return usageError(&stderr.interface, "unknown option {s}", .{arg});
        } else try modules.append(allocator, arg);
    }
    options.output_dir = output_dir orelse return usageError(&stderr.interface, "--output-dir is required", .{});
    if (modules.items.len == 0) return usageError(&stderr.interface, "no modules given", .{});
    if (!codegen.plan.isIndexPath(options.index_file)) {
        return usageError(&stderr.interface, "--index-file `{s}` is not a normalized relative .zig path", .{options.index_file});
    }
    options.modules = modules.items;
    options.packages = packages.items;
    options.allowed_resources = resources.items;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (verify) {
        const dir = library orelse return usageError(&stderr.interface, "type-checking needs the zig-pkl sources; pass --library <dir>, set ZIG_PKL_LIBRARY, or pass --no-verify", .{});
        options.verify = .{ .check = .{
            .toolchain = .{
                .zig = zig,
                .library_root = try std.fs.path.join(arena, &.{ dir, "src", "root.zig" }),
                .schema = try std.fs.path.join(arena, &.{ dir, "codegen", "Schema.pkl" }),
            },
            .scratch_dir = nonEmpty(init.environ_map.get("TMPDIR")) orelse nonEmpty(init.environ_map.get("TEMP")) orelse
                nonEmpty(init.environ_map.get("TMP")) orelse ".zig-cache/tmp",
        } };
    }

    var diagnostics = codegen.Diagnostics.init(allocator);
    defer diagnostics.deinit();
    const executable = pkl orelse "pkl";
    const report = codegen.generator.generateWithExecutable(allocator, io, executable, options, &diagnostics) catch |err| {
        try diagnostics.write(&stderr.interface);
        switch (err) {
            error.CodegenFailed => {},
            error.FileNotFound => try stderr.interface.print("error: cannot run `{s}`; install Pkl or set PKL_EXEC or --pkl\n", .{executable}),
            else => try stderr.interface.print("error: {t}\n", .{err}),
        }
        return 1;
    };
    try diagnostics.write(&stderr.interface);
    if (options.check) {
        if (report.outdated != 0) {
            try stderr.interface.print("{d} generated file(s) in {s} are out of date; rerun without --check\n", .{ report.outdated, options.output_dir });
            return 1;
        }
        try stdout.interface.print("{d} generated file(s) are up to date\n", .{report.unchanged});
        return 0;
    }
    try stdout.interface.print("{s}: {d} written, {d} unchanged, {d} removed\n", .{ options.output_dir, report.written, report.unchanged, report.removed });
    return 0;
}

fn nonEmpty(text: ?[]const u8) ?[]const u8 {
    const value = text orelse return null;
    return if (value.len == 0) null else value;
}

fn usageError(writer: *std.Io.Writer, comptime format: []const u8, args: anytype) !u8 {
    try writer.print("error: " ++ format ++ "\n\n", args);
    try writer.writeAll(usage);
    return 2;
}
