//! In-process module and resource readers, including filesystem and embed sources.

const std = @import("std");
const message = @import("../protocol/message.zig");

pub const Error = error{
    NotFound,
    PathEscapes,
    InvalidUri,
    OutOfMemory,
} || std.Io.Dir.ReadFileAllocError || std.Io.Dir.Iterator.Error || std.Io.File.OpenError;

pub const PathElement = message.PathElement;

pub const ModuleReader = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        scheme: *const fn (ptr: *anyopaque) []const u8,
        has_hierarchical_uris: *const fn (ptr: *anyopaque) bool,
        is_globbable: *const fn (ptr: *anyopaque) bool,
        is_local: *const fn (ptr: *anyopaque) bool,
        read: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, uri: []const u8) anyerror![]u8,
        list: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, uri: []const u8) anyerror![]PathElement,
    };

    pub fn scheme(self: ModuleReader) []const u8 {
        return self.vtable.scheme(self.ptr);
    }

    pub fn spec(self: ModuleReader) message.ClientModuleReader {
        return .{
            .scheme = self.scheme(),
            .has_hierarchical_uris = self.vtable.has_hierarchical_uris(self.ptr),
            .is_globbable = self.vtable.is_globbable(self.ptr),
            .is_local = self.vtable.is_local(self.ptr),
        };
    }

    pub fn read(self: ModuleReader, allocator: std.mem.Allocator, uri: []const u8) anyerror![]u8 {
        return self.vtable.read(self.ptr, allocator, uri);
    }

    pub fn list(self: ModuleReader, allocator: std.mem.Allocator, uri: []const u8) anyerror![]PathElement {
        return self.vtable.list(self.ptr, allocator, uri);
    }
};

pub const ResourceReader = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        scheme: *const fn (ptr: *anyopaque) []const u8,
        has_hierarchical_uris: *const fn (ptr: *anyopaque) bool,
        is_globbable: *const fn (ptr: *anyopaque) bool,
        read: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, uri: []const u8) anyerror![]u8,
        list: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, uri: []const u8) anyerror![]PathElement,
    };

    pub fn scheme(self: ResourceReader) []const u8 {
        return self.vtable.scheme(self.ptr);
    }

    pub fn spec(self: ResourceReader) message.ClientResourceReader {
        return .{
            .scheme = self.scheme(),
            .has_hierarchical_uris = self.vtable.has_hierarchical_uris(self.ptr),
            .is_globbable = self.vtable.is_globbable(self.ptr),
        };
    }

    pub fn read(self: ResourceReader, allocator: std.mem.Allocator, uri: []const u8) anyerror![]u8 {
        return self.vtable.read(self.ptr, allocator, uri);
    }

    pub fn list(self: ResourceReader, allocator: std.mem.Allocator, uri: []const u8) anyerror![]PathElement {
        return self.vtable.list(self.ptr, allocator, uri);
    }
};

pub const Entry = struct {
    path: []const u8,
    contents: []const u8 = "",
    is_directory: bool = false,
};

pub const Embed = struct {
    scheme_name: []const u8,
    hierarchical: bool = true,
    globbable: bool = true,
    local: bool = true,
    entries: []const Entry,

    pub fn moduleReader(self: *Embed) ModuleReader {
        return .{ .ptr = self, .vtable = &module_vtable };
    }

    pub fn resourceReader(self: *Embed) ResourceReader {
        return .{ .ptr = self, .vtable = &resource_vtable };
    }

    fn schemeOf(ptr: *anyopaque) []const u8 {
        const self: *Embed = @ptrCast(@alignCast(ptr));
        return self.scheme_name;
    }

    fn hierarchicalOf(ptr: *anyopaque) bool {
        const self: *Embed = @ptrCast(@alignCast(ptr));
        return self.hierarchical;
    }

    fn globbableOf(ptr: *anyopaque) bool {
        const self: *Embed = @ptrCast(@alignCast(ptr));
        return self.globbable;
    }

    fn localOf(ptr: *anyopaque) bool {
        const self: *Embed = @ptrCast(@alignCast(ptr));
        return self.local;
    }

    fn readOf(ptr: *anyopaque, allocator: std.mem.Allocator, uri: []const u8) anyerror![]u8 {
        const self: *Embed = @ptrCast(@alignCast(ptr));
        if (!self.hierarchical) {
            const path = uriPath(uri);
            for (self.entries) |entry| {
                if (entry.is_directory) continue;
                if (std.mem.eql(u8, entry.path, path) or std.mem.eql(u8, entry.path, uri)) {
                    return allocator.dupe(u8, entry.contents);
                }
            }
            return error.NotFound;
        }
        const path = try decodedPath(allocator, uri);
        defer allocator.free(path);
        for (self.entries) |entry| {
            if (entry.is_directory) continue;
            if (std.mem.eql(u8, entry.path, path)) return allocator.dupe(u8, entry.contents);
        }
        return error.NotFound;
    }

    fn listOf(ptr: *anyopaque, allocator: std.mem.Allocator, uri: []const u8) anyerror![]PathElement {
        const self: *Embed = @ptrCast(@alignCast(ptr));
        var out: std.ArrayList(PathElement) = .empty;
        errdefer {
            for (out.items) |element| allocator.free(@constCast(element.name));
            out.deinit(allocator);
        }
        if (!self.hierarchical) {
            for (self.entries) |entry| {
                if (entry.is_directory) continue;
                try appendElement(allocator, &out, entry.path, false);
            }
            return out.toOwnedSlice(allocator);
        }
        const base = try decodedPath(allocator, uri);
        defer allocator.free(base);
        for (self.entries) |entry| {
            const name = childName(base, entry.path) orelse continue;
            if (containsName(out.items, name)) continue;
            const rest = restAfter(base, entry.path);
            const directory = entry.is_directory or std.mem.indexOfScalar(u8, rest, '/') != null;
            try appendElement(allocator, &out, name, directory);
        }
        return out.toOwnedSlice(allocator);
    }
};

const module_vtable = ModuleReader.VTable{
    .scheme = Embed.schemeOf,
    .has_hierarchical_uris = Embed.hierarchicalOf,
    .is_globbable = Embed.globbableOf,
    .is_local = Embed.localOf,
    .read = Embed.readOf,
    .list = Embed.listOf,
};

const resource_vtable = ResourceReader.VTable{
    .scheme = Embed.schemeOf,
    .has_hierarchical_uris = Embed.hierarchicalOf,
    .is_globbable = Embed.globbableOf,
    .read = Embed.readOf,
    .list = Embed.listOf,
};

pub const Filesystem = struct {
    io: std.Io,
    /// A trusted directory handle used as the only filesystem namespace.
    /// Open it with iteration enabled when list operations are required. The
    /// caller owns the handle and must keep it open while this reader is used.
    root_dir: std.Io.Dir,
    scheme_name: []const u8 = "file",

    pub fn moduleReader(self: *Filesystem) ModuleReader {
        return .{ .ptr = self, .vtable = &fs_module_vtable };
    }

    pub fn resourceReader(self: *Filesystem) ResourceReader {
        return .{ .ptr = self, .vtable = &fs_resource_vtable };
    }

    fn schemeOf(ptr: *anyopaque) []const u8 {
        const self: *Filesystem = @ptrCast(@alignCast(ptr));
        return self.scheme_name;
    }

    fn readOf(ptr: *anyopaque, allocator: std.mem.Allocator, uri: []const u8) anyerror![]u8 {
        const self: *Filesystem = @ptrCast(@alignCast(ptr));
        const path = try self.resolve(allocator, uri);
        defer allocator.free(path);
        const file = try self.openFile(path);
        defer file.close(self.io);
        var buffer: [8192]u8 = undefined;
        var file_reader = file.readerStreaming(self.io, &buffer);
        return file_reader.interface.allocRemaining(allocator, .limited(64 * 1024 * 1024));
    }

    fn listOf(ptr: *anyopaque, allocator: std.mem.Allocator, uri: []const u8) anyerror![]PathElement {
        const self: *Filesystem = @ptrCast(@alignCast(ptr));
        const path = try self.resolve(allocator, uri);
        defer allocator.free(path);
        var opened = try self.openDir(path, true);
        defer if (opened.owned) opened.dir.close(self.io);
        var iterator = opened.dir.iterate();
        var out: std.ArrayList(PathElement) = .empty;
        errdefer {
            for (out.items) |element| allocator.free(@constCast(element.name));
            out.deinit(allocator);
        }
        while (try iterator.next(self.io)) |entry| {
            if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
            try appendElement(allocator, &out, entry.name, entry.kind == .directory);
        }
        return out.toOwnedSlice(allocator);
    }

    fn resolve(self: *Filesystem, allocator: std.mem.Allocator, uri: []const u8) Error![]u8 {
        _ = self;
        const normalized = try decodedPath(allocator, uri);
        defer allocator.free(normalized);
        return allocator.dupe(u8, normalized[1..]);
    }

    const OpenedDir = struct {
        dir: std.Io.Dir,
        owned: bool,
    };

    fn openDir(self: *Filesystem, relative: []const u8, iterate: bool) !OpenedDir {
        var current = self.root_dir;
        var owned = false;
        errdefer if (owned) current.close(self.io);
        var parts = std.mem.splitScalar(u8, relative, '/');
        while (parts.next()) |part| {
            if (part.len == 0) continue;
            const next = try current.openDir(self.io, part, .{
                .iterate = iterate,
                .follow_symlinks = false,
            });
            if (owned) current.close(self.io);
            current = next;
            owned = true;
        }
        return .{ .dir = current, .owned = owned };
    }

    fn openFile(self: *Filesystem, relative: []const u8) !std.Io.File {
        const slash = std.mem.lastIndexOfScalar(u8, relative, '/');
        const parent_path = if (slash) |index| relative[0..index] else "";
        const name = if (slash) |index| relative[index + 1 ..] else relative;
        if (name.len == 0) return error.InvalidUri;
        var parent = try self.openDir(parent_path, false);
        defer if (parent.owned) parent.dir.close(self.io);
        return parent.dir.openFile(self.io, name, .{
            .follow_symlinks = false,
            .resolve_beneath = true,
        });
    }
};

const fs_module_vtable = ModuleReader.VTable{
    .scheme = Filesystem.schemeOf,
    .has_hierarchical_uris = struct {
        fn yes(_: *anyopaque) bool {
            return true;
        }
    }.yes,
    .is_globbable = struct {
        fn yes(_: *anyopaque) bool {
            return true;
        }
    }.yes,
    .is_local = struct {
        fn yes(_: *anyopaque) bool {
            return true;
        }
    }.yes,
    .read = Filesystem.readOf,
    .list = Filesystem.listOf,
};

const fs_resource_vtable = ResourceReader.VTable{
    .scheme = Filesystem.schemeOf,
    .has_hierarchical_uris = struct {
        fn yes(_: *anyopaque) bool {
            return true;
        }
    }.yes,
    .is_globbable = struct {
        fn yes(_: *anyopaque) bool {
            return true;
        }
    }.yes,
    .read = Filesystem.readOf,
    .list = Filesystem.listOf,
};

fn appendElement(allocator: std.mem.Allocator, out: *std.ArrayList(PathElement), name: []const u8, is_directory: bool) !void {
    const copy = try allocator.dupe(u8, name);
    out.append(allocator, .{ .name = copy, .is_directory = is_directory }) catch |err| {
        allocator.free(copy);
        return err;
    };
}

pub fn schemeOf(uri: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, uri, ':') orelse return null;
    if (colon == 0) return null;
    return uri[0..colon];
}

pub fn uriPath(uri: []const u8) []const u8 {
    const colon = std.mem.indexOfScalar(u8, uri, ':') orelse return uri;
    var path = uri[colon + 1 ..];
    if (std.mem.startsWith(u8, path, "//")) {
        path = path[2..];
        if (std.mem.indexOfScalar(u8, path, '/')) |index| path = path[index..];
    }
    return path;
}

/// Returns the normalized absolute path of a hierarchical URI with percent
/// escapes decoded. Query strings, fragments, backslashes, NUL, malformed
/// escapes, and escapes that decode to `/`, a backslash, or NUL are
/// rejected with `error.InvalidUri`; `..` segments that would leave the root
/// fail with `error.PathEscapes`. A trailing slash is removed.
pub fn decodedPath(allocator: std.mem.Allocator, uri: []const u8) Error![]u8 {
    const raw = uriPath(uri);
    if (std.mem.indexOfAny(u8, raw, "?#\\\x00") != null) return error.InvalidUri;
    const decoded = try allocator.alloc(u8, raw.len);
    defer allocator.free(decoded);
    var len: usize = 0;
    var index: usize = 0;
    while (index < raw.len) : (index += 1) {
        var byte = raw[index];
        if (byte == '%') {
            if (index + 2 >= raw.len) return error.InvalidUri;
            const high = std.fmt.charToDigit(raw[index + 1], 16) catch return error.InvalidUri;
            const low = std.fmt.charToDigit(raw[index + 2], 16) catch return error.InvalidUri;
            byte = high * 16 + low;
            if (byte == '/' or byte == '\\' or byte == 0) return error.InvalidUri;
            index += 2;
        }
        decoded[len] = byte;
        len += 1;
    }
    return normalize(allocator, decoded[0..len]);
}

pub fn normalize(allocator: std.mem.Allocator, path: []const u8) Error![]u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len == 0) return error.PathEscapes;
            _ = parts.pop();
            continue;
        }
        try parts.append(allocator, part);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '/');
    for (parts.items, 0..) |part, index| {
        if (index != 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, part);
    }
    return out.toOwnedSlice(allocator);
}

fn childName(base: []const u8, path: []const u8) ?[]const u8 {
    const rest = restAfter(base, path);
    if (rest.len == 0) return null;
    if (std.mem.indexOfScalar(u8, rest, '/')) |index| {
        if (index == 0) return null;
        return rest[0..index];
    }
    return rest;
}

fn restAfter(base: []const u8, path: []const u8) []const u8 {
    if (std.mem.eql(u8, base, "/") or base.len == 0) {
        var rest = path;
        if (rest.len > 0 and rest[0] == '/') rest = rest[1..];
        return rest;
    }
    if (!std.mem.startsWith(u8, path, base)) return "";
    if (path.len > base.len and path[base.len] != '/') return "";
    var rest = path[base.len..];
    if (rest.len > 0 and rest[0] == '/') rest = rest[1..];
    return rest;
}

fn containsName(elements: []const PathElement, name: []const u8) bool {
    for (elements) |element| if (std.mem.eql(u8, element.name, name)) return true;
    return false;
}

test "embed readers and path normalization" {
    const allocator = std.testing.allocator;
    var embed = Embed{
        .scheme_name = "mem",
        .entries = &.{
            .{ .path = "/dir", .is_directory = true },
            .{ .path = "/dir/mod.pkl", .contents = "foo = 1" },
            .{ .path = "/root.pkl", .contents = "bar = 2" },
        },
    };
    const text = try embed.moduleReader().read(allocator, "mem:/dir/mod.pkl");
    defer allocator.free(text);
    try std.testing.expectEqualStrings("foo = 1", text);
    const listed = try embed.moduleReader().list(allocator, "mem:/");
    defer {
        for (listed) |element| allocator.free(@constCast(element.name));
        allocator.free(listed);
    }
    try std.testing.expectEqual(@as(usize, 2), listed.len);

    const normalized = try normalize(allocator, "/work/../work/./file.pkl");
    defer allocator.free(normalized);
    try std.testing.expectEqualStrings("/work/file.pkl", normalized);
    try std.testing.expectError(error.PathEscapes, normalize(allocator, "/../secret"));
    try std.testing.expectEqualStrings("file", schemeOf("file:///tmp/a.pkl").?);
    try std.testing.expectEqualStrings("/tmp/a.pkl", uriPath("file:///tmp/a.pkl"));
    var filesystem = Filesystem{ .io = std.testing.io, .root_dir = std.Io.Dir.cwd() };
    try std.testing.expectError(error.InvalidUri, filesystem.resolve(allocator, "file:/dir%2fsecret"));
    try std.testing.expectError(error.InvalidUri, filesystem.resolve(allocator, "file:/dir\\secret"));

    const nested = try embed.moduleReader().list(allocator, "mem:/dir");
    defer {
        for (nested) |element| allocator.free(@constCast(element.name));
        allocator.free(nested);
    }
    try std.testing.expectEqual(@as(usize, 1), nested.len);
    try std.testing.expectEqualStrings("mod.pkl", nested[0].name);

    var boundary = Embed{
        .scheme_name = "mem",
        .entries = &.{.{ .path = "/directory/not-a-child.pkl", .contents = "" }},
    };
    const boundary_list = try boundary.moduleReader().list(allocator, "mem:/dir");
    defer allocator.free(boundary_list);
    try std.testing.expectEqual(@as(usize, 0), boundary_list.len);
}

fn freeElements(allocator: std.mem.Allocator, elements: []PathElement) void {
    for (elements) |element| allocator.free(@constCast(element.name));
    allocator.free(elements);
}

test "embed lists directory uris with and without a trailing slash" {
    const allocator = std.testing.allocator;
    var embed = Embed{
        .scheme_name = "mem",
        .entries = &.{
            .{ .path = "/lib/a.pkl", .contents = "a = 1" },
            .{ .path = "/lib/b.pkl", .contents = "b = 2" },
            .{ .path = "/lib/sub/", .is_directory = true },
            .{ .path = "/lib/sub/c.pkl", .contents = "c = 3" },
            .{ .path = "/other.pkl", .contents = "" },
        },
    };
    for ([_][]const u8{ "mem:/lib", "mem:/lib/", "mem:///lib/", "mem:/lib/./" }) |uri| {
        const listed = try embed.moduleReader().list(allocator, uri);
        defer freeElements(allocator, listed);
        try std.testing.expectEqual(@as(usize, 3), listed.len);
        try std.testing.expectEqualStrings("a.pkl", listed[0].name);
        try std.testing.expectEqualStrings("b.pkl", listed[1].name);
        try std.testing.expectEqualStrings("sub", listed[2].name);
        try std.testing.expect(listed[2].is_directory);
    }
    const sub = try embed.resourceReader().list(allocator, "mem:/lib/sub/");
    defer freeElements(allocator, sub);
    try std.testing.expectEqual(@as(usize, 1), sub.len);
    try std.testing.expectEqualStrings("c.pkl", sub[0].name);
}

test "reader uri paths are percent-decoded and confined" {
    const allocator = std.testing.allocator;
    var embed = Embed{
        .scheme_name = "mem",
        .entries = &.{.{ .path = "/my dir/café.pkl", .contents = "x = 1" }},
    };
    const text = try embed.moduleReader().read(allocator, "mem:/my%20dir/caf%C3%A9.pkl");
    defer allocator.free(text);
    try std.testing.expectEqualStrings("x = 1", text);
    const listed = try embed.moduleReader().list(allocator, "mem:/my%20dir/");
    defer freeElements(allocator, listed);
    try std.testing.expectEqualStrings("café.pkl", listed[0].name);
    try std.testing.expectError(error.InvalidUri, embed.moduleReader().read(allocator, "mem:/my%2Fdir"));
    try std.testing.expectError(error.PathEscapes, embed.moduleReader().read(allocator, "mem:/%2E%2E/secret"));

    var filesystem = Filesystem{ .io = std.testing.io, .root_dir = std.Io.Dir.cwd() };
    const decoded = try filesystem.resolve(allocator, "file:///a%20b/caf%C3%A9.pkl");
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("a b/café.pkl", decoded);
    for ([_][]const u8{ "file:/a%2fb", "file:/a%5Cb", "file:/a%00", "file:/a%zz", "file:/a%2", "file:/a?q", "file:/a#f" }) |uri| {
        try std.testing.expectError(error.InvalidUri, filesystem.resolve(allocator, uri));
    }
    try std.testing.expectError(error.PathEscapes, filesystem.resolve(allocator, "file:/a/%2e%2e/%2e%2e/etc"));
}

test "filesystem reader reads and lists percent-encoded names" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "my dir");
    try tmp.dir.writeFile(io, .{ .sub_path = "my dir/café.pkl", .data = "y = 2" });
    var filesystem = Filesystem{ .io = io, .root_dir = tmp.dir };
    const text = try filesystem.moduleReader().read(allocator, "file:///my%20dir/caf%C3%A9.pkl");
    defer allocator.free(text);
    try std.testing.expectEqualStrings("y = 2", text);
    const listed = try filesystem.moduleReader().list(allocator, "file:///my%20dir/");
    defer freeElements(allocator, listed);
    try std.testing.expectEqual(@as(usize, 1), listed.len);
    try std.testing.expectEqualStrings("café.pkl", listed[0].name);
}
