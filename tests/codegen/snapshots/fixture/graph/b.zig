//! Bindings for the Pkl module `fixture.graph.b`. Regenerate this file instead of editing it.

const std = @import("std");
const zig_pkl = @import("zig_pkl");
const pkl_fixture_graph_a = @import("a.zig");

name: []const u8 = "b",
peer: ?*const pkl_fixture_graph_a = null,

pub const pkl_class = "fixture.graph.b";

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

pub const Node = struct {
    edges: []const pkl_fixture_graph_a.Node = &.{},
    previous: ?*const pkl_fixture_graph_a.Node = null,

    pub const pkl_class = "fixture.graph.b#Node";

    pub fn decode(allocator: std.mem.Allocator, root: *const zig_pkl.Value) zig_pkl.convert.Error!@This() {
        return zig_pkl.convert.into(@This(), allocator, root);
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        zig_pkl.convert.freeInto(@This(), allocator, self.*);
        self.* = undefined;
    }
};
