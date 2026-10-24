//! RFC 3986 `file:` URIs for absolute filesystem paths.

const builtin = @import("builtin");
const std = @import("std");

pub const PathStyle = enum {
    posix,
    windows,

    pub const native: PathStyle = if (builtin.os.tag == .windows) .windows else .posix;
};

pub const Error = error{ OutOfMemory, InvalidPath };

/// Converts an absolute path to a `file:` URI. Bytes outside the RFC 3986
/// path character set are percent-encoded, so spaces, `%`, `#`, `?`, and
/// non-ASCII bytes are preserved exactly. Windows drive paths become
/// `file:///C:/...` and UNC paths become `file://host/share/...`.
pub fn fromPath(allocator: std.mem.Allocator, path: []const u8, style: PathStyle) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    switch (style) {
        .posix => {
            if (path.len == 0 or path[0] != '/') return error.InvalidPath;
            try out.appendSlice(allocator, "file://");
            try appendEncodedPath(allocator, &out, path, false);
        },
        .windows => {
            var rest = path;
            if (std.mem.startsWith(u8, rest, "\\\\?\\UNC\\")) {
                rest = rest["\\\\?\\UNC\\".len..];
                try appendUnc(allocator, &out, rest);
            } else if (std.mem.startsWith(u8, rest, "\\\\?\\")) {
                rest = rest["\\\\?\\".len..];
                try appendDrive(allocator, &out, rest);
            } else if (rest.len >= 2 and isSeparator(rest[0]) and isSeparator(rest[1])) {
                try appendUnc(allocator, &out, rest[2..]);
            } else {
                try appendDrive(allocator, &out, rest);
            }
        },
    }
    return out.toOwnedSlice(allocator);
}

/// The canonical absolute path of the existing file at `path`. Relative
/// paths resolve against the current directory and symlinks resolve to
/// their target. The caller owns the result.
pub fn realFilePath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = file.realPath(io, &buffer) catch |err| switch (err) {
        error.OperationUnsupported => {
            if (!std.fs.path.isAbsolute(path)) return err;
            return allocator.dupe(u8, path);
        },
        else => return err,
    };
    return allocator.dupe(u8, buffer[0..length]);
}

/// The `file:` URI of the existing file at `path`, as resolved by
/// `realFilePath`. The caller owns the result.
pub fn fromFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const absolute = try realFilePath(allocator, io, path);
    defer allocator.free(absolute);
    return fromPath(allocator, absolute, .native);
}

/// Resolves a `/`-separated relative path against the directory of `base`,
/// a hierarchical URI such as a `PklProject` file URI. Path bytes are
/// percent-encoded as in `fromPath`.
pub fn sibling(allocator: std.mem.Allocator, base: []const u8, relative: []const u8) Error![]u8 {
    if (relative.len == 0 or relative[0] == '/' or std.mem.indexOfScalar(u8, relative, '\\') != null) {
        return error.InvalidPath;
    }
    const slash = std.mem.lastIndexOfScalar(u8, base, '/') orelse return error.InvalidPath;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, base[0 .. slash + 1]);
    try appendEncodedPath(allocator, &out, relative, false);
    return out.toOwnedSlice(allocator);
}

fn appendDrive(allocator: std.mem.Allocator, out: *std.ArrayList(u8), path: []const u8) Error!void {
    if (path.len < 3 or !std.ascii.isAlphabetic(path[0]) or path[1] != ':' or !isSeparator(path[2])) {
        return error.InvalidPath;
    }
    try out.appendSlice(allocator, "file:///");
    try out.append(allocator, std.ascii.toUpper(path[0]));
    try out.append(allocator, ':');
    try appendEncodedPath(allocator, out, path[2..], true);
}

fn appendUnc(allocator: std.mem.Allocator, out: *std.ArrayList(u8), path: []const u8) Error!void {
    const host_end = std.mem.indexOfAny(u8, path, "\\/") orelse return error.InvalidPath;
    if (host_end == 0) return error.InvalidPath;
    try out.appendSlice(allocator, "file://");
    for (path[0..host_end]) |byte| try appendByte(allocator, out, byte, false);
    try appendEncodedPath(allocator, out, path[host_end..], true);
}

fn appendEncodedPath(allocator: std.mem.Allocator, out: *std.ArrayList(u8), path: []const u8, backslash_separator: bool) Error!void {
    for (path) |byte| {
        if (byte == 0) return error.InvalidPath;
        if (byte == '/' or (backslash_separator and byte == '\\')) {
            try out.append(allocator, '/');
        } else {
            try appendByte(allocator, out, byte, true);
        }
    }
}

fn appendByte(allocator: std.mem.Allocator, out: *std.ArrayList(u8), byte: u8, path_chars: bool) Error!void {
    if (isUnreserved(byte) or isSubDelim(byte) or (path_chars and (byte == ':' or byte == '@'))) {
        try out.append(allocator, byte);
        return;
    }
    const hex = "0123456789ABCDEF";
    try out.appendSlice(allocator, &.{ '%', hex[byte >> 4], hex[byte & 0x0f] });
}

fn isSeparator(byte: u8) bool {
    return byte == '\\' or byte == '/';
}

fn isUnreserved(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~';
}

fn isSubDelim(byte: u8) bool {
    return switch (byte) {
        '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=' => true,
        else => false,
    };
}

fn expectUri(expected: []const u8, path: []const u8, style: PathStyle) !void {
    const actual = try fromPath(std.testing.allocator, path, style);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "posix paths percent-encode reserved and non-ascii bytes" {
    try expectUri("file:///tmp/a%20b/PklProject", "/tmp/a b/PklProject", .posix);
    try expectUri("file:///tmp/100%25/x%23y%3Fz", "/tmp/100%/x#y?z", .posix);
    try expectUri("file:///tmp/caf%C3%A9/a:b@c", "/tmp/café/a:b@c", .posix);
    try std.testing.expectError(error.InvalidPath, fromPath(std.testing.allocator, "relative/path", .posix));
}

test "windows drive, long, and unc paths use file uri shapes" {
    try expectUri("file:///C:/Program%20Files/Pkl/PklProject", "C:\\Program Files\\Pkl\\PklProject", .windows);
    try expectUri("file:///D:/work/a%20b", "d:/work/a b", .windows);
    try expectUri("file:///C:/long/path", "\\\\?\\C:\\long\\path", .windows);
    try expectUri("file://server/share/dir%20x/f.pkl", "\\\\server\\share\\dir x\\f.pkl", .windows);
    try expectUri("file://server/share/f.pkl", "\\\\?\\UNC\\server\\share\\f.pkl", .windows);
    try std.testing.expectError(error.InvalidPath, fromPath(std.testing.allocator, "C:relative", .windows));
    try std.testing.expectError(error.InvalidPath, fromPath(std.testing.allocator, "\\\\\\share", .windows));
}

test "sibling uris resolve beside a project file and encode the relative path" {
    const allocator = std.testing.allocator;
    const resolved = try sibling(allocator, "file:///C:/my%20app/PklProject", "src/main file.pkl");
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings("file:///C:/my%20app/src/main%20file.pkl", resolved);
    try std.testing.expectError(error.InvalidPath, sibling(allocator, "file:///a/PklProject", "/abs.pkl"));
    try std.testing.expectError(error.InvalidPath, sibling(allocator, "file:///a/PklProject", "a\\b.pkl"));
    try std.testing.expectError(error.InvalidPath, sibling(allocator, "file:///a/PklProject", ""));
}
