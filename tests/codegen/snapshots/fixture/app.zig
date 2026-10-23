//! Bindings for the Pkl module `fixture.App`. Regenerate this file instead of editing it.
//!
//! Settings for a fixture service.

const std = @import("std");
const zig_pkl = @import("zig_pkl");
const pkl_deps_shared_units = @import("../deps/shared/units.zig");
const pkl_fixture_geometry = @import("geometry.zig");
const pkl_fixture_graph_a = @import("graph/a.zig");

/// Display name.
name: []const u8 = "service",
enabled: bool = true,
port: Port = 8080,
retries: i8 = -3,
ratio: f64 = 0.25,
big: i64 = 9007199254740993,
grade: []const u8 = "A",
nickname: ?[]const u8 = null,
tags: []const []const u8 = &.{},
ids: []const i64 = &.{},
unique: []const []const u8 = &.{},
labels: zig_pkl.convert.Map([]const u8, []const u8) = .{ .entries = &.{} },
weights: zig_pkl.convert.Map([]const u8, f64) = .{ .entries = &.{} },
limits: zig_pkl.convert.Pair(i64, []const u8),
timeout: zig_pkl.convert.Duration = .{ .value = 30.0, .unit = "s" },
memory: zig_pkl.convert.DataSize = .{ .value = 512.0, .unit = "mb" },
pattern: zig_pkl.convert.Regex,
payload: zig_pkl.convert.Bytes,
range: zig_pkl.convert.IntSeq,
mode: Mode = .slow_start,
value: Value,
choice: ?Choice = null,
shapes: []const pkl_fixture_geometry.Shape = &.{},
tree: pkl_fixture_geometry.Tree,
price: pkl_deps_shared_units.Money,
discount: pkl_deps_shared_units.Percent = 10.0,
graph: pkl_fixture_graph_a,
nested: zig_pkl.convert.Map([]const u8, []const zig_pkl.convert.Pair(i64, bool)) = .{ .entries = &.{} },
named: zig_pkl.convert.Map([]const u8, i64) = .{ .entries = &.{} },
listen_address: []const u8 = "127.0.0.1",
raw: []const u8,
server: ?*const Server = null,
tls: TlsServer,
chain: pkl_fixture_geometry.Link,
endpoint: Endpoint,
floats_first: []const FloatsFirst = &.{},
ints_first: []const IntsFirst = &.{},

pub const pkl_class = "fixture.App";
pub const pkl_names = .{ .listen_address = "address" };

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

pub const Server = struct {
    host: []const u8,
    /// Port to connect to.
    listen_port: Port = 443,

    pub const pkl_class = "fixture.App#Server";
    pub const pkl_subclasses = [_][]const u8{"fixture.App#TlsServer"};
    pub const pkl_names = .{ .listen_port = "port" };

    pub fn decode(allocator: std.mem.Allocator, root: *const zig_pkl.Value) zig_pkl.convert.Error!@This() {
        return zig_pkl.convert.into(@This(), allocator, root);
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        zig_pkl.convert.freeInto(@This(), allocator, self.*);
        self.* = undefined;
    }
};

pub const TlsServer = struct {
    host: []const u8,
    /// Port to connect to.
    listen_port: Port = 8443,
    certificate: []const u8,

    pub const pkl_class = "fixture.App#TlsServer";
    pub const pkl_names = .{ .listen_port = "port" };

    pub fn decode(allocator: std.mem.Allocator, root: *const zig_pkl.Value) zig_pkl.convert.Error!@This() {
        return zig_pkl.convert.into(@This(), allocator, root);
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        zig_pkl.convert.freeInto(@This(), allocator, self.*);
        self.* = undefined;
    }
};

pub const Endpoint = struct {
    url: []const u8,
    weight: i64 = 1,

    pub const pkl_class = "fixture.App#Endpoint";

    pub fn decode(allocator: std.mem.Allocator, root: *const zig_pkl.Value) zig_pkl.convert.Error!@This() {
        return zig_pkl.convert.into(@This(), allocator, root);
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        zig_pkl.convert.freeInto(@This(), allocator, self.*);
        self.* = undefined;
    }
};

pub const Port = u16;

pub const Mode = enum {
    fast,
    slow_start,

    pub const pkl_names = .{ .slow_start = "slow-start" };
};

pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    shape: pkl_fixture_geometry.Shape,

    pub fn decode(allocator: std.mem.Allocator, root: *const zig_pkl.Value) zig_pkl.convert.Error!@This() {
        return zig_pkl.convert.into(@This(), allocator, root);
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        zig_pkl.convert.freeInto(@This(), allocator, self.*);
        self.* = undefined;
    }
};

pub const Choice = union(enum) {
    int: i64,
    boolean: bool,

    pub fn decode(allocator: std.mem.Allocator, root: *const zig_pkl.Value) zig_pkl.convert.Error!@This() {
        return zig_pkl.convert.into(@This(), allocator, root);
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        zig_pkl.convert.freeInto(@This(), allocator, self.*);
        self.* = undefined;
    }
};

pub const FloatsFirst = union(enum) {
    float: f64,
    int: i64,

    pub fn decode(allocator: std.mem.Allocator, root: *const zig_pkl.Value) zig_pkl.convert.Error!@This() {
        return zig_pkl.convert.into(@This(), allocator, root);
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        zig_pkl.convert.freeInto(@This(), allocator, self.*);
        self.* = undefined;
    }
};

pub const IntsFirst = union(enum) {
    int: i64,
    float: f64,

    pub fn decode(allocator: std.mem.Allocator, root: *const zig_pkl.Value) zig_pkl.convert.Error!@This() {
        return zig_pkl.convert.into(@This(), allocator, root);
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        zig_pkl.convert.freeInto(@This(), allocator, self.*);
        self.* = undefined;
    }
};
