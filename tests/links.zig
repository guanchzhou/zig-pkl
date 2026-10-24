//! Every relative link in the repository's Markdown files must name a file
//! or directory that exists. External links are not fetched.

const std = @import("std");

const skipped_directories = [_][]const u8{ ".git", ".zig-cache", "zig-out", "zig-pkg", "node_modules", ".nuxt", ".output" };

test "relative markdown links point at existing paths" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var root = try std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    defer root.close(io);
    var walker = try root.walkSelectively(allocator);
    defer walker.deinit();

    var checked: usize = 0;
    var broken: usize = 0;
    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                for (skipped_directories) |name| {
                    if (std.mem.eql(u8, entry.basename, name)) break;
                } else try walker.enter(io, entry);
            },
            .file => if (std.mem.endsWith(u8, entry.basename, ".md")) {
                var arena: std.heap.ArenaAllocator = .init(allocator);
                defer arena.deinit();
                const scratch = arena.allocator();
                const path = try scratch.dupe(u8, entry.path);
                const text = try root.readFileAlloc(io, path, scratch, .limited(4 << 20));
                var links: std.ArrayList([]const u8) = .empty;
                try collectLinks(scratch, text, &links);
                for (links.items) |target| {
                    checked += 1;
                    const resolved = if (target[0] == '/')
                        target[1..]
                    else
                        try std.fs.path.join(scratch, &.{ std.fs.path.dirname(path) orelse ".", target });
                    root.access(io, resolved, .{}) catch {
                        broken += 1;
                        std.debug.print("{s}: broken link {s}\n", .{ path, target });
                    };
                }
            },
            else => {},
        }
    }
    try std.testing.expect(checked > 0);
    try std.testing.expectEqual(@as(usize, 0), broken);
}

/// Appends the local path of every inline `[text](target)` and reference
/// `[label]: target` link outside code, without any `#fragment` or `?query`.
fn collectLinks(allocator: std.mem.Allocator, text: []const u8, links: *std.ArrayList([]const u8)) !void {
    var fenced = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "```")) {
            fenced = !fenced;
            continue;
        }
        if (fenced) continue;
        const prose = try withoutCodeSpans(allocator, line);
        if (referenceTarget(prose)) |target| try appendLocal(allocator, links, target);
        var rest = prose;
        while (std.mem.indexOf(u8, rest, "](")) |start| {
            rest = rest[start + 2 ..];
            const end = std.mem.indexOfScalar(u8, rest, ')') orelse break;
            try appendLocal(allocator, links, rest[0..end]);
            rest = rest[end + 1 ..];
        }
    }
}

fn withoutCodeSpans(allocator: std.mem.Allocator, line: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var in_code = false;
    for (line) |c| {
        if (c == '`') {
            in_code = !in_code;
        } else if (!in_code) {
            try out.append(allocator, c);
        }
    }
    return out.items;
}

fn referenceTarget(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "[")) return null;
    const close = std.mem.indexOf(u8, line, "]:") orelse return null;
    return std.mem.trim(u8, line[close + 2 ..], " \t");
}

fn appendLocal(allocator: std.mem.Allocator, links: *std.ArrayList([]const u8), raw: []const u8) !void {
    var target = std.mem.trim(u8, raw, " \t");
    if (std.mem.indexOfAny(u8, target, " \t")) |space| target = target[0..space];
    target = std.mem.trim(u8, target, "<>");
    if (std.mem.indexOfAny(u8, target, "#?")) |end| target = target[0..end];
    if (target.len == 0 or std.mem.indexOf(u8, target, "://") != null or std.mem.startsWith(u8, target, "mailto:")) return;
    try links.append(allocator, target);
}

test "link collection ignores code, fragments, and external targets" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var links: std.ArrayList([]const u8) = .empty;
    try collectLinks(arena.allocator(),
        \\See [guide](docs/guide.md#start) and [site](https://example.com).
        \\`[not](a-link.md)` [mail](mailto:a@b.c) [top](#intro)
        \\```
        \\[fenced](ignored.md)
        \\```
        \\[ref]: ../LICENSE "License"
    , &links);
    try std.testing.expectEqual(@as(usize, 2), links.items.len);
    try std.testing.expectEqualStrings("docs/guide.md", links.items[0]);
    try std.testing.expectEqualStrings("../LICENSE", links.items[1]);
}
