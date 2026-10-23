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

    const marker = try std.fmt.allocPrint(allocator, "zig-pkl-gen-{s}", .{&hex});
    defer allocator.free(marker);
    const relative = try relativize(allocator, result.stderr, marker);
    defer allocator.free(relative);
    try diagnostics.add(null, "the generated bindings do not type-check, so nothing was written:\n{s}", .{std.mem.trimEnd(u8, relative, "\n")});
    return error.CodegenFailed;
}

/// Rewrites every path in `text` that runs through the scratch directory
/// named `marker` to the binding's path relative to the output directory,
/// with `/` separators on every platform. The compiler may print the scratch
/// path relative or absolute, with `/` or `\`.
fn relativize(allocator: std.mem.Allocator, text: []const u8, marker: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var rest = text;
    while (std.mem.indexOf(u8, rest, marker)) |at| {
        const start = pathStart(rest, at);
        const after = rest[at + marker.len ..];
        if (!startsWithBindings(after)) {
            try out.appendSlice(allocator, rest[0 .. at + marker.len]);
            rest = after;
            continue;
        }
        try out.appendSlice(allocator, rest[0..start]);
        var index: usize = "/bindings/".len;
        while (index < after.len and after[index] != ':' and after[index] != '\n') : (index += 1) {
            try out.append(allocator, if (after[index] == '\\') '/' else after[index]);
        }
        rest = after[index..];
    }
    try out.appendSlice(allocator, rest);
    return out.toOwnedSlice(allocator);
}

fn startsWithBindings(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "/bindings/") or std.mem.startsWith(u8, text, "\\bindings\\");
}

/// Start of the path token that contains `at`: after the previous
/// whitespace, or the start of `text`.
fn pathStart(text: []const u8, at: usize) usize {
    var index = at;
    while (index > 0) : (index -= 1) {
        switch (text[index - 1]) {
            ' ', '\t', '\n', '\r', '\'', '"', '(' => return index,
            else => {},
        }
    }
    return 0;
}

test "compiler paths through the scratch directory become output paths" {
    const allocator = std.testing.allocator;
    const marker = "zig-pkl-gen-0123456789abcdef";
    const cases = [_][2][]const u8{
        .{
            ".zig-cache/tmp/zig-pkl-gen-0123456789abcdef/bindings/app/config.zig:4:9: error: use of undeclared identifier 'NoSuchType'\n",
            "app/config.zig:4:9: error: use of undeclared identifier 'NoSuchType'\n",
        },
        .{
            "D:\\a\\repo\\.zig-cache\\tmp\\zig-pkl-gen-0123456789abcdef\\bindings\\app\\config.zig:4:9: error: x\n    note: in .zig-cache\\tmp\\zig-pkl-gen-0123456789abcdef\\bindings\\root.zig:2:1\n",
            "app/config.zig:4:9: error: x\n    note: in root.zig:2:1\n",
        },
        .{ "src\\lib.zig:1:1: error: kept as written\n", "src\\lib.zig:1:1: error: kept as written\n" },
        .{ "zig-pkl-gen-0123456789abcdef appears without a path\n", "zig-pkl-gen-0123456789abcdef appears without a path\n" },
    };
    for (cases) |case| {
        const got = try relativize(allocator, case[0], marker);
        defer allocator.free(got);
        try std.testing.expectEqualStrings(case[1], got);
    }
}
