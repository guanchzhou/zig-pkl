//! Identifier conversions for generated Zig code.

const std = @import("std");

/// Whether `text` is usable as a Zig identifier once keywords and primitive
/// names are escaped with `@""` syntax.
pub fn isIdentifier(text: []const u8) bool {
    if (text.len == 0 or std.mem.eql(u8, text, "_")) return false;
    for (text, 0..) |byte, index| switch (byte) {
        'a'...'z', 'A'...'Z', '_' => {},
        '0'...'9' => if (index == 0) return false,
        else => return false,
    };
    return true;
}

/// `fooBar`, `FooBar`, `foo-bar`, and `HTTPServer` become `foo_bar`,
/// `foo_bar`, `foo_bar`, and `http_server`. Leading digits gain a `_` prefix.
pub fn snakeCase(allocator: std.mem.Allocator, name: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var pending_separator = false;
    for (name, 0..) |byte, index| {
        if (!std.ascii.isAlphanumeric(byte)) {
            if (byte == '_' and out.items.len == 0 and index == 0) {
                try out.append(allocator, '_');
                continue;
            }
            pending_separator = out.items.len != 0;
            continue;
        }
        if (std.ascii.isUpper(byte) and index > 0 and out.items.len != 0) {
            const previous = name[index - 1];
            const next_lower = index + 1 < name.len and std.ascii.isLower(name[index + 1]);
            if (std.ascii.isLower(previous) or std.ascii.isDigit(previous) or (std.ascii.isUpper(previous) and next_lower)) {
                pending_separator = true;
            }
        }
        if (pending_separator and out.items.len != 0 and out.items[out.items.len - 1] != '_') {
            try out.append(allocator, '_');
        }
        pending_separator = false;
        try out.append(allocator, std.ascii.toLower(byte));
    }
    if (out.items.len == 0 or (out.items.len == 1 and out.items[0] == '_')) {
        out.clearRetainingCapacity();
        try out.appendSlice(allocator, "unnamed");
    }
    if (std.ascii.isDigit(out.items[0])) try out.insert(allocator, 0, '_');
    return out.toOwnedSlice(allocator);
}

/// `fooBar`, `foo_bar`, and `foo-bar` become `FooBar`.
pub fn pascalCase(allocator: std.mem.Allocator, name: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var upper_next = true;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte)) {
            upper_next = true;
            continue;
        }
        try out.append(allocator, if (upper_next) std.ascii.toUpper(byte) else byte);
        upper_next = false;
    }
    if (out.items.len == 0) try out.appendSlice(allocator, "Unnamed");
    if (std.ascii.isDigit(out.items[0])) try out.insert(allocator, 0, '_');
    return out.toOwnedSlice(allocator);
}

/// Replaces bytes that cannot appear in an identifier with `_` and prefixes
/// a leading digit with `_`.
pub fn sanitize(allocator: std.mem.Allocator, name: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (name) |byte| try out.append(allocator, if (std.ascii.isAlphanumeric(byte) or byte == '_') byte else '_');
    if (out.items.len == 0 or std.mem.eql(u8, out.items, "_")) {
        out.clearRetainingCapacity();
        try out.appendSlice(allocator, "unnamed");
    }
    if (std.ascii.isDigit(out.items[0])) try out.insert(allocator, 0, '_');
    return out.toOwnedSlice(allocator);
}

/// Formats an identifier, escaping keywords and primitive type names.
pub fn fmtId(name: []const u8) std.zig.FormatId {
    return std.zig.fmtId(name);
}

test "snake case splits words and acronyms" {
    const cases = [_][2][]const u8{
        .{ "fooBar", "foo_bar" },
        .{ "FooBar", "foo_bar" },
        .{ "foo_bar", "foo_bar" },
        .{ "foo-bar", "foo_bar" },
        .{ "HTTPServer", "http_server" },
        .{ "serverURL", "server_url" },
        .{ "ipv4Address", "ipv4_address" },
        .{ "x", "x" },
        .{ "2fa", "_2fa" },
        .{ "_private", "_private" },
        .{ "a  b", "a_b" },
        .{ "", "unnamed" },
        .{ "-", "unnamed" },
    };
    for (cases) |case| {
        const got = try snakeCase(std.testing.allocator, case[0]);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings(case[1], got);
    }
}

test "pascal case joins words" {
    const cases = [_][2][]const u8{
        .{ "fooBar", "FooBar" },
        .{ "foo_bar", "FooBar" },
        .{ "foo-bar", "FooBar" },
        .{ "x", "X" },
        .{ "9lives", "_9lives" },
        .{ "", "Unnamed" },
    };
    for (cases) |case| {
        const got = try pascalCase(std.testing.allocator, case[0]);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings(case[1], got);
    }
}

test "identifiers reject empty, underscore, and punctuation" {
    try std.testing.expect(isIdentifier("type"));
    try std.testing.expect(isIdentifier("_x9"));
    try std.testing.expect(!isIdentifier(""));
    try std.testing.expect(!isIdentifier("_"));
    try std.testing.expect(!isIdentifier("9x"));
    try std.testing.expect(!isIdentifier("a-b"));
    try std.testing.expectFmt("@\"type\"", "{f}", .{fmtId("type")});
    try std.testing.expectFmt("@\"u8\"", "{f}", .{fmtId("u8")});
    try std.testing.expectFmt("port", "{f}", .{fmtId("port")});
}

test "sanitize keeps identifier bytes" {
    const got = try sanitize(std.testing.allocator, "my-config.v2");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("my_config_v2", got);
}
