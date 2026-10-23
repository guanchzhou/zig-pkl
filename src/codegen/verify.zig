//! Type-checks planned bindings with the Zig compiler before they are
//! written. The files are staged in a private scratch directory together
//! with a root that forces analysis of every generated declaration,
//! including the `decode`, `deinit`, and `load` helpers.

const std = @import("std");
const output = @import("output.zig");
const Diagnostics = @import("diagnostics.zig").Diagnostics;

pub const Toolchain = struct {
    /// Zig executable.
    zig: []const u8,
    /// `src/root.zig` of the zig-pkl library the bindings import.
    library_root: []const u8,
    /// `codegen/Schema.pkl`, which the library embeds.
    schema: []const u8,
};

pub const Options = struct {
    toolchain: Toolchain,
    /// Parent of the scratch directory, created when missing.
    scratch_dir: []const u8,
};

/// Source of the analysis root. `bindings` is the generated index.
pub const analysis_root =
    \\const std = @import("std");
    \\const bindings = @import("bindings");
    \\
    \\fn analyze(comptime T: type) void {
    \\    inline for (comptime std.meta.declarations(T)) |name| {
    \\        if (comptime std.mem.startsWith(u8, name, "pkl_") or std.mem.eql(u8, name, "std") or std.mem.eql(u8, name, "zig_pkl")) continue;
    \\        if (@TypeOf(@field(T, name)) == type) {
    \\            switch (@typeInfo(@field(T, name))) {
    \\                .@"struct", .@"union", .@"enum" => analyze(@field(T, name)),
    \\                else => {},
    \\            }
    \\        } else _ = &@field(T, name);
    \\    }
    \\    switch (@typeInfo(T)) {
    \\        .@"struct", .@"union" => _ = @sizeOf(T),
    \\        else => {},
    \\    }
    \\}
    \\
    \\test "generated bindings compile" {
    \\    comptime analyze(bindings);
    \\}
    \\
;

/// Fails with `error.CodegenFailed`, reporting the compiler output, when
/// `files` do not type-check. `index_file` is the planned index path.
pub fn check(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    files: []const output.File,
    index_file: []const u8,
    diagnostics: *Diagnostics,
) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, options.scratch_dir);
    var random: [8]u8 = undefined;
    io.random(&random);
    const hex = std.fmt.bytesToHex(random, .lower);
    const scratch = try std.fmt.allocPrint(allocator, "{s}/zig-pkl-gen-{s}", .{ options.scratch_dir, &hex });
    defer allocator.free(scratch);
    try cwd.createDirPath(io, scratch);
    defer cwd.deleteTree(io, scratch) catch {};

    var dir = try cwd.openDir(io, scratch, .{});
    defer dir.close(io);
    for (files) |file| {
        const staged = try std.fmt.allocPrint(allocator, "bindings/{s}", .{file.path});
        defer allocator.free(staged);
        if (std.fs.path.dirnamePosix(staged)) |parent| try dir.createDirPath(io, parent);
        try dir.writeFile(io, .{ .sub_path = staged, .data = file.contents });
    }
    try dir.writeFile(io, .{ .sub_path = "check.zig", .data = analysis_root });

    const root_arg = try std.fmt.allocPrint(allocator, "-Mroot={s}/check.zig", .{scratch});
    defer allocator.free(root_arg);
    const bindings_arg = try std.fmt.allocPrint(allocator, "-Mbindings={s}/bindings/{s}", .{ scratch, index_file });
    defer allocator.free(bindings_arg);
    const library_arg = try std.fmt.allocPrint(allocator, "-Mzig_pkl={s}", .{options.toolchain.library_root});
    defer allocator.free(library_arg);
    const schema_arg = try std.fmt.allocPrint(allocator, "-Mzig_pkl_codegen_schema={s}", .{options.toolchain.schema});
    defer allocator.free(schema_arg);
    const cache_dir = try std.fmt.allocPrint(allocator, "{s}/cache", .{scratch});
    defer allocator.free(cache_dir);

    const result = std.process.run(allocator, io, .{
        .argv = &.{
            options.toolchain.zig, "test",     "-fno-emit-bin",          "--cache-dir", cache_dir,
            "--dep",               "bindings", root_arg,                 "--dep",       "zig_pkl",
            bindings_arg,          "--dep",    "zig_pkl_codegen_schema", library_arg,   schema_arg,
        },
        .stdout_limit = .limited(output.max_file_bytes),
        .stderr_limit = .limited(output.max_file_bytes),
    }) catch |err| {
        try diagnostics.add(null, "cannot run `{s}` to type-check the bindings: {t}; pass --zig or --no-verify", .{ options.toolchain.zig, err });
        return error.CodegenFailed;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term == .exited and result.term.exited == 0) return;

    const prefix = try std.fmt.allocPrint(allocator, "{s}/bindings/", .{scratch});
    defer allocator.free(prefix);
    const relative = try std.mem.replaceOwned(u8, allocator, result.stderr, prefix, "");
    defer allocator.free(relative);
    try diagnostics.add(null, "the generated bindings do not type-check, so nothing was written:\n{s}", .{std.mem.trimEnd(u8, relative, "\n")});
    return error.CodegenFailed;
}
