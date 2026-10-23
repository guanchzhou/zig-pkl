//! Bindings for the Pkl module `fixture.refs`. Regenerate this file instead of editing it.
//!
//! References into a build domain.

const std = @import("std");
const zig_pkl = @import("zig_pkl");

domain: Ci,
step: zig_pkl.convert.Reference(Ci, Step),
run: zig_pkl.convert.Reference(Ci, []const u8),
tag: zig_pkl.convert.Reference(Ci, []const u8),
path: []const zig_pkl.convert.Access,

pub const pkl_class = "fixture.refs";

pub fn decode(allocator: std.mem.Allocator, root: *const zig_pkl.Value) zig_pkl.convert.Error!@This() {
    return zig_pkl.convert.into(@This(), allocator, root);
}

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    zig_pkl.convert.freeInto(@This(), allocator, self.*);
    self.* = undefined;
}

/// Evaluates `source` and decodes the module. On `error.EvaluationFailed`,
/// `failure` owns the Pkl error message, allocated with the manager allocator.
/// Release the result with `deinit`.
pub fn load(allocator: std.mem.Allocator, evaluator: *zig_pkl.Evaluator, source: zig_pkl.Source, failure: *?[]u8) !@This() {
    var tree = try evaluator.evaluateSource(source, null, failure);
    defer tree.deinit();
    return decode(allocator, tree.root);
}

pub const Ci = struct {
    name: []const u8,

    pub const pkl_class = "fixture.refs#Ci";

    pub fn decode(allocator: std.mem.Allocator, root: *const zig_pkl.Value) zig_pkl.convert.Error!@This() {
        return zig_pkl.convert.into(@This(), allocator, root);
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        zig_pkl.convert.freeInto(@This(), allocator, self.*);
        self.* = undefined;
    }
};

pub const Step = struct {
    run: []const u8,
    tags: []const []const u8 = &.{},

    pub const pkl_class = "fixture.refs#Step";

    pub fn decode(allocator: std.mem.Allocator, root: *const zig_pkl.Value) zig_pkl.convert.Error!@This() {
        return zig_pkl.convert.into(@This(), allocator, root);
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        zig_pkl.convert.freeInto(@This(), allocator, self.*);
        self.* = undefined;
    }
};
