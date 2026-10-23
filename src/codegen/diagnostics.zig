//! Problems reported while generating code. Each carries the Pkl source
//! location it refers to, when one is known. Errors fail generation;
//! warnings are reported and generation continues. Repeated identical
//! diagnostics are recorded once.

const std = @import("std");

pub const Severity = enum { @"error", warning };

pub const Diagnostic = struct {
    severity: Severity = .@"error",
    location: ?[]const u8,
    message: []const u8,
};

pub const Diagnostics = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Diagnostic) = .empty,

    pub fn init(allocator: std.mem.Allocator) Diagnostics {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Diagnostics) void {
        for (self.items.items) |item| {
            if (item.location) |location| self.allocator.free(location);
            self.allocator.free(item.message);
        }
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn add(self: *Diagnostics, location: ?[]const u8, comptime format: []const u8, args: anytype) error{OutOfMemory}!void {
        return self.addSeverity(.@"error", location, format, args);
    }

    pub fn warn(self: *Diagnostics, location: ?[]const u8, comptime format: []const u8, args: anytype) error{OutOfMemory}!void {
        return self.addSeverity(.warning, location, format, args);
    }

    fn addSeverity(self: *Diagnostics, severity: Severity, location: ?[]const u8, comptime format: []const u8, args: anytype) error{OutOfMemory}!void {
        const message = try std.fmt.allocPrint(self.allocator, format, args);
        errdefer self.allocator.free(message);
        for (self.items.items) |item| {
            if (item.severity != severity or !std.mem.eql(u8, item.message, message)) continue;
            if ((item.location == null) != (location == null)) continue;
            if (location != null and !std.mem.eql(u8, item.location.?, location.?)) continue;
            self.allocator.free(message);
            return;
        }
        const owned_location = if (location) |text| try self.allocator.dupe(u8, text) else null;
        errdefer if (owned_location) |text| self.allocator.free(text);
        try self.items.append(self.allocator, .{ .severity = severity, .location = owned_location, .message = message });
    }

    pub fn errorCount(self: Diagnostics) usize {
        var errors: usize = 0;
        for (self.items.items) |item| {
            if (item.severity == .@"error") errors += 1;
        }
        return errors;
    }

    pub fn hasErrors(self: Diagnostics) bool {
        return self.errorCount() != 0;
    }

    /// Whether some message contains `needle`.
    pub fn contains(self: Diagnostics, needle: []const u8) bool {
        for (self.items.items) |item| {
            if (std.mem.indexOf(u8, item.message, needle) != null) return true;
        }
        return false;
    }

    /// Number of messages that contain `needle`.
    pub fn count(self: Diagnostics, needle: []const u8) usize {
        var total: usize = 0;
        for (self.items.items) |item| {
            if (std.mem.indexOf(u8, item.message, needle) != null) total += 1;
        }
        return total;
    }

    /// Writes one `location: severity: message` line per diagnostic.
    pub fn write(self: Diagnostics, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.items.items) |item| {
            if (item.location) |location| try writer.print("{s}: ", .{location});
            try writer.print("{t}: {s}\n", .{ item.severity, item.message });
        }
    }
};

test "diagnostics own their text" {
    var diagnostics = Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    var location_buffer = "file:///a.pkl:1:2".*;
    try diagnostics.add(&location_buffer, "bad `{s}`", .{"x"});
    try diagnostics.add(null, "general", .{});
    try diagnostics.warn(null, "lossy", .{});
    location_buffer[0] = 'X';
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try diagnostics.write(&out.writer);
    try std.testing.expectEqualStrings("file:///a.pkl:1:2: error: bad `x`\nerror: general\nwarning: lossy\n", out.written());
    try std.testing.expect(diagnostics.contains("bad"));
    try std.testing.expectEqual(@as(usize, 2), diagnostics.errorCount());
}

test "identical diagnostics are recorded once" {
    var diagnostics = Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    try diagnostics.add("a:1:1", "same", .{});
    try diagnostics.add("a:1:1", "same", .{});
    try diagnostics.add("a:2:1", "same", .{});
    try diagnostics.add(null, "same", .{});
    try diagnostics.warn("a:1:1", "same", .{});
    try std.testing.expectEqual(@as(usize, 4), diagnostics.items.items.len);
    try std.testing.expectEqual(@as(usize, 3), diagnostics.errorCount());
}
