//! Updates an output directory that holds generated files.
//!
//! The directory keeps a manifest, `manifest_name`, with the SHA-256 digest
//! of every file the generator wrote. An existing file is replaced or removed
//! only when the manifest lists it with a digest that matches its current
//! contents. Any other file at a planned path, and any listed file edited
//! since it was written, is a conflict. Conflicts are reported before
//! anything changes, and nothing is written unless `force` is set.

const std = @import("std");
const Diagnostics = @import("diagnostics.zig").Diagnostics;

pub const manifest_name = ".zig-pkl-gen-manifest";
const manifest_header = "zig-pkl-gen manifest 1\n";

pub const max_file_bytes = 64 * 1024 * 1024;

pub const File = struct {
    /// `/`-separated path relative to the output directory.
    path: []const u8,
    contents: []const u8,
};

pub const Mode = struct {
    /// Count out-of-date files without changing the directory.
    check: bool = false,
    /// Replace or remove conflicting files instead of failing.
    force: bool = false,
};

pub const Report = struct {
    written: usize = 0,
    unchanged: usize = 0,
    removed: usize = 0,
    /// In check mode: files that would be written or removed, including the
    /// manifest.
    outdated: usize = 0,
};

pub const Error = error{ CodegenFailed, OutOfMemory };

/// Whether `path` is a normalized relative path: `/`-separated, without
/// empty, `.`, or `..` segments, drive letters, or backslashes.
pub fn isSafePath(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/') return false;
    if (std.mem.indexOfAny(u8, path, "\\:\x00") != null) return false;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    }
    return true;
}

const Digest = [std.crypto.hash.sha2.Sha256.digest_length]u8;

fn digestOf(bytes: []const u8) Digest {
    var out: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return out;
}

const Manifest = struct {
    entries: std.StringArrayHashMapUnmanaged(Digest) = .empty,
    text: ?[]u8 = null,

    fn deinit(self: *Manifest, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
        if (self.text) |text| allocator.free(text);
    }
};

fn readManifest(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, output_dir: []const u8, mode: Mode, diagnostics: *Diagnostics) !Manifest {
    var manifest = Manifest{};
    errdefer manifest.deinit(allocator);
    manifest.text = dir.readFileAlloc(io, manifest_name, allocator, .limited(max_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => return manifest,
        else => return err,
    };
    const text = manifest.text.?;
    const location = try std.fs.path.join(allocator, &.{ output_dir, manifest_name });
    defer allocator.free(location);
    if (!std.mem.startsWith(u8, text, manifest_header)) {
        if (mode.force) return manifest;
        try diagnostics.add(location, "not a zig-pkl-gen manifest; remove it or pass --force", .{});
        return error.CodegenFailed;
    }
    var lines = std.mem.splitScalar(u8, text[manifest_header.len..], '\n');
    var line_number: usize = 1;
    while (lines.next()) |line| {
        line_number += 1;
        if (line.len == 0) continue;
        const entry = parseLine(line);
        if (entry == null or (try manifest.entries.getOrPut(allocator, entry.?.path)).found_existing) {
            manifest.entries.clearRetainingCapacity();
            if (mode.force) return manifest;
            try diagnostics.add(location, "line {d} is not a valid entry; remove the manifest or pass --force", .{line_number});
            return error.CodegenFailed;
        }
        manifest.entries.getPtr(entry.?.path).?.* = entry.?.digest;
    }
    return manifest;
}

fn parseLine(line: []const u8) ?struct { path: []const u8, digest: Digest } {
    const hex_len = @sizeOf(Digest) * 2;
    if (line.len < hex_len + 2 or line[hex_len] != ' ') return null;
    var digest: Digest = undefined;
    _ = std.fmt.hexToBytes(&digest, line[0..hex_len]) catch return null;
    const path = line[hex_len + 1 ..];
    if (!isSafePath(path)) return null;
    return .{ .path = path, .digest = digest };
}

fn renderManifest(allocator: std.mem.Allocator, files: []const File) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const paths = try allocator.alloc(usize, files.len);
    defer allocator.free(paths);
    for (paths, 0..) |*slot, index| slot.* = index;
    std.mem.sort(usize, paths, files, struct {
        fn less(items: []const File, left: usize, right: usize) bool {
            return std.mem.lessThan(u8, items[left].path, items[right].path);
        }
    }.less);
    out.writer.writeAll(manifest_header) catch return error.OutOfMemory;
    for (paths) |index| {
        const hex = std.fmt.bytesToHex(digestOf(files[index].contents), .lower);
        out.writer.print("{s} {s}\n", .{ &hex, files[index].path }) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn readExisting(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !?[]u8 {
    return dir.readFileAlloc(io, path, allocator, .limited(max_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

/// Brings `output_dir` up to date with `files`, whose paths must satisfy
/// `isSafePath`. Conflicts and an unreadable manifest are reported in
/// `diagnostics` as `error.CodegenFailed`.
pub fn writeFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    output_dir: []const u8,
    files: []const File,
    mode: Mode,
    diagnostics: *Diagnostics,
) !Report {
    var report = Report{};
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, output_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => blk: {
            if (mode.check) {
                report.outdated = files.len + 1;
                return report;
            }
            try cwd.createDirPath(io, output_dir);
            break :blk try cwd.openDir(io, output_dir, .{});
        },
        else => return err,
    };
    defer dir.close(io);

    var manifest = try readManifest(allocator, io, dir, output_dir, mode, diagnostics);
    defer manifest.deinit(allocator);

    var planned: std.StringHashMapUnmanaged(void) = .empty;
    defer planned.deinit(allocator);
    const writes = try allocator.alloc(bool, files.len);
    defer allocator.free(writes);
    var conflicts: usize = 0;
    for (files, writes) |file, *write| {
        std.debug.assert(isSafePath(file.path));
        try planned.put(allocator, file.path, {});
        const existing = try readExisting(allocator, io, dir, file.path);
        defer if (existing) |bytes| allocator.free(bytes);
        write.* = existing == null or !std.mem.eql(u8, existing.?, file.contents);
        if (!write.* or existing == null) continue;
        if (manifest.entries.get(file.path)) |digest| {
            if (std.mem.eql(u8, &digest, &digestOf(existing.?))) continue;
        }
        if (mode.force) continue;
        conflicts += 1;
        try diagnostics.add(file.path, "exists in `{s}` but was not written by the generator, or was edited since; move it away or pass --force", .{output_dir});
    }

    var stale: std.ArrayList([]const u8) = .empty;
    defer stale.deinit(allocator);
    for (manifest.entries.keys(), manifest.entries.values()) |path, digest| {
        if (planned.contains(path)) continue;
        const existing = try readExisting(allocator, io, dir, path) orelse continue;
        defer allocator.free(existing);
        if (!mode.force and !std.mem.eql(u8, &digest, &digestOf(existing))) {
            conflicts += 1;
            try diagnostics.add(path, "is no longer generated but was edited since it was written to `{s}`; delete it or pass --force", .{output_dir});
            continue;
        }
        try stale.append(allocator, path);
    }
    std.mem.sort([]const u8, stale.items, {}, struct {
        fn less(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.less);
    if (conflicts != 0) return error.CodegenFailed;

    const manifest_text = try renderManifest(allocator, files);
    defer allocator.free(manifest_text);
    const manifest_current = manifest.text != null and std.mem.eql(u8, manifest.text.?, manifest_text);

    for (files, writes) |file, write| {
        if (!write) {
            report.unchanged += 1;
        } else if (mode.check) {
            report.outdated += 1;
        } else {
            if (std.fs.path.dirnamePosix(file.path)) |parent| try dir.createDirPath(io, parent);
            try dir.writeFile(io, .{ .sub_path = file.path, .data = file.contents });
            report.written += 1;
        }
    }
    for (stale.items) |path| {
        if (mode.check) {
            report.outdated += 1;
        } else {
            try dir.deleteFile(io, path);
            report.removed += 1;
        }
    }
    if (!manifest_current) {
        if (mode.check) {
            report.outdated += 1;
        } else try dir.writeFile(io, .{ .sub_path = manifest_name, .data = manifest_text });
    }
    return report;
}

const Scratch = struct {
    tmp: std.testing.TmpDir,
    out: []u8,

    fn init(name: []const u8) !Scratch {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const out = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
        return .{ .tmp = tmp, .out = out };
    }

    fn deinit(self: *Scratch) void {
        std.testing.allocator.free(self.out);
        self.tmp.cleanup();
    }

    fn write(self: *Scratch, files: []const File, mode: Mode, diagnostics: *Diagnostics) !Report {
        return writeFiles(std.testing.allocator, std.testing.io, self.out, files, mode, diagnostics);
    }

    fn read(self: *Scratch, path: []const u8) ![]u8 {
        return self.tmp.dir.readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(max_file_bytes));
    }

    fn expectContents(self: *Scratch, path: []const u8, expected: []const u8) !void {
        const actual = try self.read(path);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
    }
};

test "output paths must be normalized and relative" {
    try std.testing.expect(isSafePath("root.zig"));
    try std.testing.expect(isSafePath("nested/dir/root.zig"));
    for ([_][]const u8{ "", "/abs.zig", "../up.zig", "a/../b.zig", "./a.zig", "a//b.zig", "a\\b.zig", "C:/x.zig", "a/", "a/." }) |path| {
        try std.testing.expect(!isSafePath(path));
    }
}

test "owned files are written, kept, and pruned" {
    var scratch = try Scratch.init("out");
    defer scratch.deinit();
    var diagnostics = Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();

    const first = [_]File{
        .{ .path = "a.zig", .contents = "a\n" },
        .{ .path = "nested/b.zig", .contents = "b\n" },
    };
    try std.testing.expectEqual(Report{ .outdated = 3 }, try scratch.write(&first, .{ .check = true }, &diagnostics));
    try std.testing.expectEqual(Report{ .written = 2 }, try scratch.write(&first, .{}, &diagnostics));
    try std.testing.expectEqual(Report{ .unchanged = 2 }, try scratch.write(&first, .{}, &diagnostics));
    try std.testing.expectEqual(Report{ .unchanged = 2 }, try scratch.write(&first, .{ .check = true }, &diagnostics));
    const manifest = try scratch.read("out/" ++ manifest_name);
    defer std.testing.allocator.free(manifest);
    try std.testing.expect(std.mem.startsWith(u8, manifest, manifest_header));
    try std.testing.expect(std.mem.indexOf(u8, manifest, " a.zig\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, " nested/b.zig\n") != null);

    const second = [_]File{.{ .path = "a.zig", .contents = "a changed\n" }};
    try std.testing.expectEqual(Report{ .outdated = 3 }, try scratch.write(&second, .{ .check = true }, &diagnostics));
    try std.testing.expectEqual(Report{ .written = 1, .removed = 1 }, try scratch.write(&second, .{}, &diagnostics));
    try std.testing.expectError(error.FileNotFound, scratch.tmp.dir.statFile(std.testing.io, "out/nested/b.zig", .{}));
    try std.testing.expect(!diagnostics.hasErrors());
}

test "files the generator does not own are never replaced or removed" {
    var scratch = try Scratch.init("out");
    defer scratch.deinit();
    var diagnostics = Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    const io = std.testing.io;

    try scratch.tmp.dir.createDirPath(io, "out");
    try scratch.tmp.dir.writeFile(io, .{ .sub_path = "out/a.zig", .data = "//! Bindings for my own module.\n" });
    try scratch.tmp.dir.writeFile(io, .{ .sub_path = "out/notes.zig", .data = "//! Bindings for the Pkl module `x`. Regenerate this file instead of editing it.\n" });
    const files = [_]File{
        .{ .path = "a.zig", .contents = "generated a\n" },
        .{ .path = "b.zig", .contents = "generated b\n" },
    };
    try std.testing.expectError(error.CodegenFailed, scratch.write(&files, .{}, &diagnostics));
    try std.testing.expectError(error.CodegenFailed, scratch.write(&files, .{ .check = true }, &diagnostics));
    try std.testing.expect(diagnostics.contains("was not written by the generator"));
    try scratch.expectContents("out/a.zig", "//! Bindings for my own module.\n");
    try std.testing.expectError(error.FileNotFound, scratch.tmp.dir.statFile(io, "out/b.zig", .{}));
    try std.testing.expectError(error.FileNotFound, scratch.tmp.dir.statFile(io, "out/" ++ manifest_name, .{}));

    try std.testing.expectEqual(Report{ .written = 2 }, try scratch.write(&files, .{ .force = true }, &diagnostics));
    try scratch.expectContents("out/a.zig", "generated a\n");

    try scratch.tmp.dir.writeFile(io, .{ .sub_path = "out/a.zig", .data = "generated a\nhand edit\n" });
    try scratch.tmp.dir.writeFile(io, .{ .sub_path = "out/b.zig", .data = "generated b\nhand edit\n" });
    diagnostics.deinit();
    diagnostics = Diagnostics.init(std.testing.allocator);
    const fewer = [_]File{.{ .path = "a.zig", .contents = "generated a v2\n" }};
    try std.testing.expectError(error.CodegenFailed, scratch.write(&fewer, .{}, &diagnostics));
    try std.testing.expect(diagnostics.contains("or was edited since"));
    try std.testing.expect(diagnostics.contains("is no longer generated but was edited"));
    try scratch.expectContents("out/a.zig", "generated a\nhand edit\n");
    try scratch.expectContents("out/b.zig", "generated b\nhand edit\n");
    try scratch.expectContents("out/notes.zig", "//! Bindings for the Pkl module `x`. Regenerate this file instead of editing it.\n");

    try std.testing.expectEqual(Report{ .written = 1, .removed = 1 }, try scratch.write(&fewer, .{ .force = true }, &diagnostics));
    try scratch.expectContents("out/notes.zig", "//! Bindings for the Pkl module `x`. Regenerate this file instead of editing it.\n");
}

test "manifest entries cannot reach outside the output directory" {
    var scratch = try Scratch.init("out");
    defer scratch.deinit();
    var diagnostics = Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    const io = std.testing.io;

    try scratch.tmp.dir.createDirPath(io, "out");
    try scratch.tmp.dir.writeFile(io, .{ .sub_path = "outside.zig", .data = "keep\n" });
    const hex = std.fmt.bytesToHex(digestOf("keep\n"), .lower);
    const forged = manifest_header ++ hex ++ " ../outside.zig\n";
    try scratch.tmp.dir.writeFile(io, .{ .sub_path = "out/" ++ manifest_name, .data = forged });
    const files = [_]File{.{ .path = "a.zig", .contents = "a\n" }};
    try std.testing.expectError(error.CodegenFailed, scratch.write(&files, .{}, &diagnostics));
    try std.testing.expect(diagnostics.contains("is not a valid entry"));
    try scratch.expectContents("outside.zig", "keep\n");

    try scratch.tmp.dir.writeFile(io, .{ .sub_path = "out/" ++ manifest_name, .data = "something else\n" });
    try std.testing.expectError(error.CodegenFailed, scratch.write(&files, .{}, &diagnostics));
    try std.testing.expect(diagnostics.contains("not a zig-pkl-gen manifest"));

    try std.testing.expectEqual(Report{ .written = 1 }, try scratch.write(&files, .{ .force = true }, &diagnostics));
    try scratch.expectContents("outside.zig", "keep\n");
}
