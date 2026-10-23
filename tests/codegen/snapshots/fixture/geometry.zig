//! Bindings for the Pkl module `fixture.geometry`. Regenerate this file instead of editing it.
//!
//! Shapes and trees.

const std = @import("std");
const zig_pkl = @import("zig_pkl");

pub const Shape = union(enum) {
    circle: Circle,
    square: Square,

    pub fn decode(allocator: std.mem.Allocator, root: *const zig_pkl.Value) zig_pkl.convert.Error!@This() {
        return zig_pkl.convert.into(@This(), allocator, root);
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        zig_pkl.convert.freeInto(@This(), allocator, self.*);
        self.* = undefined;
    }
};

pub const Circle = struct {
    label: ?[]const u8 = null,
    radius: f64,

    pub const pkl_class = "fixture.geometry#Circle";

    pub fn decode(allocator: std.mem.Allocator, root: *const zig_pkl.Value) zig_pkl.convert.Error!@This() {
        return zig_pkl.convert.into(@This(), allocator, root);
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        zig_pkl.convert.freeInto(@This(), allocator, self.*);
        self.* = undefined;
    }
};

pub const Square = struct {
    label: ?[]const u8 = null,
    side: f64,

    pub const pkl_class = "fixture.geometry#Square";

    pub fn decode(allocator: std.mem.Allocator, root: *const zig_pkl.Value) zig_pkl.convert.Error!@This() {
        return zig_pkl.convert.into(@This(), allocator, root);
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        zig_pkl.convert.freeInto(@This(), allocator, self.*);
        self.* = undefined;
    }
};

/// A tree that contains itself by value through [left] and by reference
/// through [children].
pub const Tree = struct {
    value: i64,
    children: []const Tree = &.{},
    left: ?*const Tree = null,

    pub const pkl_class = "fixture.geometry#Tree";

    pub fn decode(allocator: std.mem.Allocator, root: *const zig_pkl.Value) zig_pkl.convert.Error!@This() {
        return zig_pkl.convert.into(@This(), allocator, root);
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        zig_pkl.convert.freeInto(@This(), allocator, self.*);
        self.* = undefined;
    }
};

/// A list whose links refer to each other through a nullable alias.
pub const Link = struct {
    id: i64,
    next: ?*const Link = null,

    pub const pkl_class = "fixture.geometry#Link";

    pub fn decode(allocator: std.mem.Allocator, root: *const zig_pkl.Value) zig_pkl.convert.Error!@This() {
        return zig_pkl.convert.into(@This(), allocator, root);
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        zig_pkl.convert.freeInto(@This(), allocator, self.*);
        self.* = undefined;
    }
};

pub const MaybeLink = ?Link;
