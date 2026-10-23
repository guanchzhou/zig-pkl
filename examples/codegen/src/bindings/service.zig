//! Bindings for the Pkl module `example.Service`. Regenerate this file instead of editing it.
//!
//! Configuration for an HTTP service.

const std = @import("std");
const zig_pkl = @import("zig_pkl");

/// Address to listen on.
host: []const u8 = "127.0.0.1",
listen_port: u16 = 8080,
/// Time allowed for a request before it is canceled.
timeout: zig_pkl.convert.Duration = .{ .value = 5.0, .unit = "s" },
max_body: zig_pkl.convert.DataSize = .{ .value = 1.0, .unit = "mib" },
log_level: LogLevel = .info,
routes: []const Route = &.{},
backends: zig_pkl.convert.Map([]const u8, Backend) = .{ .entries = &.{} },
tls: ?Tls = null,

pub const pkl_class = "example.Service";
pub const pkl_names = .{ .listen_port = "port", .max_body = "maxBody", .log_level = "logLevel" };

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

pub const Route = struct {
    path: []const u8,
    /// Key into [backends].
    backend: []const u8,
    methods: []const Method = &.{.get},

    pub const pkl_class = "example.Service#Route";

    pub fn decode(allocator: std.mem.Allocator, root: *const zig_pkl.Value) zig_pkl.convert.Error!@This() {
        return zig_pkl.convert.into(@This(), allocator, root);
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        zig_pkl.convert.freeInto(@This(), allocator, self.*);
        self.* = undefined;
    }
};

pub const Backend = union(enum) {
    http_backend: HttpBackend,
    static_backend: StaticBackend,

    pub fn decode(allocator: std.mem.Allocator, root: *const zig_pkl.Value) zig_pkl.convert.Error!@This() {
        return zig_pkl.convert.into(@This(), allocator, root);
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        zig_pkl.convert.freeInto(@This(), allocator, self.*);
        self.* = undefined;
    }
};

pub const HttpBackend = struct {
    weight: i64 = 1,
    url: []const u8,

    pub const pkl_class = "example.Service#HttpBackend";

    pub fn decode(allocator: std.mem.Allocator, root: *const zig_pkl.Value) zig_pkl.convert.Error!@This() {
        return zig_pkl.convert.into(@This(), allocator, root);
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        zig_pkl.convert.freeInto(@This(), allocator, self.*);
        self.* = undefined;
    }
};

pub const StaticBackend = struct {
    weight: i64 = 1,
    directory: []const u8,

    pub const pkl_class = "example.Service#StaticBackend";

    pub fn decode(allocator: std.mem.Allocator, root: *const zig_pkl.Value) zig_pkl.convert.Error!@This() {
        return zig_pkl.convert.into(@This(), allocator, root);
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        zig_pkl.convert.freeInto(@This(), allocator, self.*);
        self.* = undefined;
    }
};

pub const Tls = struct {
    certificate: []const u8,
    key: []const u8,

    pub const pkl_class = "example.Service#Tls";

    pub fn decode(allocator: std.mem.Allocator, root: *const zig_pkl.Value) zig_pkl.convert.Error!@This() {
        return zig_pkl.convert.into(@This(), allocator, root);
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        zig_pkl.convert.freeInto(@This(), allocator, self.*);
        self.* = undefined;
    }
};

pub const Method = enum {
    get,
    post,
    put,
    delete,

    pub const pkl_names = .{ .get = "GET", .post = "POST", .put = "PUT", .delete = "DELETE" };
};

pub const LogLevel = enum {
    debug,
    info,
    warn,
};
