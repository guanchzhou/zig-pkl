//! Evaluator settings, restricted defaults, and the builder used to create evaluators.

const std = @import("std");
const message = @import("../protocol/message.zig");
const version = @import("version.zig");
const logger = @import("logger.zig");
const reader = @import("reader.zig");

pub const Project = message.Project;
pub const Http = message.Http;
pub const ExternalReader = message.ExternalReader;
pub const TraceMode = message.TraceMode;
pub const StringPair = message.StringPair;

pub const restricted_modules = [_][]const u8{ "pkl:", "repl:" };
pub const preconfigured_modules = [_][]const u8{
    "pkl:",
    "repl:",
    "file:",
    "modulepath:",
    "package:",
    "projectpackage:",
};
pub const preconfigured_resources = [_][]const u8{
    "pkl:",
    "file:",
    "modulepath:",
    "package:",
    "projectpackage:",
    "env:",
    "prop:",
};

/// Borrowed evaluator configuration. Every referenced slice, reader, logger,
/// project, and HTTP value must outlive evaluator creation. Reader and logger
/// contexts must remain valid until the evaluator is closed.
pub const Options = struct {
    allowed_modules: ?[]const []const u8 = null,
    allowed_resources: ?[]const []const u8 = null,
    module_readers: []const reader.ModuleReader = &.{},
    resource_readers: []const reader.ResourceReader = &.{},
    module_paths: ?[]const []const u8 = null,
    env: ?[]const StringPair = null,
    properties: ?[]const StringPair = null,
    timeout_seconds: ?i64 = null,
    root_dir: ?[]const u8 = null,
    cache_dir: ?[]const u8 = null,
    output_format: ?[]const u8 = null,
    project: ?Project = null,
    http: ?Http = null,
    external_module_readers: ?[]const ExternalReader = null,
    external_resource_readers: ?[]const ExternalReader = null,
    trace_mode: ?TraceMode = null,
    logger: ?logger.Logger = null,

    pub fn restricted() Options {
        return .{
            .allowed_modules = &restricted_modules,
            .allowed_resources = &.{},
            .env = &.{},
            .properties = &.{},
        };
    }

    pub fn preconfigured() Options {
        return .{
            .allowed_modules = &preconfigured_modules,
            .allowed_resources = &preconfigured_resources,
        };
    }

    pub fn validate(self: Options, pkl_version: version.Version) error{UnsupportedVersion}!void {
        if (!pkl_version.atLeast(self.requiredVersion())) return error.UnsupportedVersion;
    }

    /// The oldest Pkl release that supports every option set here.
    pub fn requiredVersion(self: Options) version.Version {
        var required = version.minimum_supported;
        if (self.http) |http| {
            if (http.ca_certificates != null or http.proxy != null) required = newer(required, version.http_settings);
            if (http.rewrites != null) required = newer(required, version.http_rewrites);
            if (http.headers != null) required = newer(required, version.http_headers);
        }
        if (self.external_module_readers != null or self.external_resource_readers != null) {
            required = newer(required, version.external_readers);
        }
        if (self.trace_mode != null) required = newer(required, version.trace_mode);
        return required;
    }

    /// True when some option needs a release newer than the oldest supported one.
    pub fn usesNewerFeatures(self: Options) bool {
        return self.requiredVersion().order(version.minimum_supported) == .gt;
    }

    fn newer(a: version.Version, b: version.Version) version.Version {
        return if (a.atLeast(b)) a else b;
    }
};

/// Owns only automatically constructed allow patterns. All other option values
/// remain borrowed. Call `deinit` after the last evaluator creation that uses
/// `options`.
pub const Builder = struct {
    allocator: std.mem.Allocator,
    options: Options,
    owned_allowed_modules: std.ArrayList([]u8) = .empty,
    owned_allowed_resources: std.ArrayList([]u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{ .allocator = allocator, .options = .{} };
    }

    pub fn restricted(allocator: std.mem.Allocator) error{OutOfMemory}!Builder {
        var builder = init(allocator);
        errdefer builder.deinit();
        try builder.copyPatterns(&builder.owned_allowed_modules, &restricted_modules);
        builder.options.allowed_modules = builder.owned_allowed_modules.items;
        builder.options.allowed_resources = builder.owned_allowed_resources.items;
        builder.options.env = &.{};
        builder.options.properties = &.{};
        return builder;
    }

    pub fn preconfigured(allocator: std.mem.Allocator) error{OutOfMemory}!Builder {
        var builder = init(allocator);
        errdefer builder.deinit();
        try builder.copyPatterns(&builder.owned_allowed_modules, &preconfigured_modules);
        try builder.copyPatterns(&builder.owned_allowed_resources, &preconfigured_resources);
        builder.refreshPatterns();
        return builder;
    }

    /// Releases builder-owned allow patterns. Options borrowed from the builder
    /// remain valid only until this function is called.
    pub fn deinit(self: *Builder) void {
        for (self.owned_allowed_modules.items) |pattern| self.allocator.free(pattern);
        for (self.owned_allowed_resources.items) |pattern| self.allocator.free(pattern);
        self.owned_allowed_modules.deinit(self.allocator);
        self.owned_allowed_resources.deinit(self.allocator);
    }

    pub fn timeoutSeconds(self: *Builder, seconds: i64) *Builder {
        self.options.timeout_seconds = seconds;
        return self;
    }

    pub fn rootDir(self: *Builder, path: []const u8) *Builder {
        self.options.root_dir = path;
        return self;
    }

    pub fn cacheDir(self: *Builder, path: []const u8) *Builder {
        self.options.cache_dir = path;
        return self;
    }

    pub fn outputFormat(self: *Builder, format: []const u8) *Builder {
        self.options.output_format = format;
        return self;
    }

    pub fn project(self: *Builder, value: Project) *Builder {
        self.options.project = value;
        return self;
    }

    pub fn http(self: *Builder, value: Http) *Builder {
        self.options.http = value;
        return self;
    }

    pub fn traceMode(self: *Builder, mode: TraceMode) *Builder {
        self.options.trace_mode = mode;
        return self;
    }

    pub fn moduleReaders(self: *Builder, readers: []const reader.ModuleReader) error{OutOfMemory}!*Builder {
        self.options.module_readers = readers;
        for (readers) |item| try self.addScheme(&self.owned_allowed_modules, item.scheme());
        self.refreshPatterns();
        return self;
    }

    pub fn resourceReaders(self: *Builder, readers: []const reader.ResourceReader) error{OutOfMemory}!*Builder {
        self.options.resource_readers = readers;
        for (readers) |item| try self.addScheme(&self.owned_allowed_resources, item.scheme());
        self.refreshPatterns();
        return self;
    }

    pub fn externalModuleReaders(self: *Builder, readers: []const ExternalReader) *Builder {
        self.options.external_module_readers = readers;
        return self;
    }

    pub fn externalResourceReaders(self: *Builder, readers: []const ExternalReader) *Builder {
        self.options.external_resource_readers = readers;
        return self;
    }

    pub fn withLogger(self: *Builder, log: logger.Logger) *Builder {
        self.options.logger = log;
        return self;
    }

    fn refreshPatterns(self: *Builder) void {
        self.options.allowed_modules = self.owned_allowed_modules.items;
        self.options.allowed_resources = self.owned_allowed_resources.items;
    }

    fn copyPatterns(self: *Builder, destination: *std.ArrayList([]u8), patterns: []const []const u8) error{OutOfMemory}!void {
        for (patterns) |pattern| {
            const copy = try self.allocator.dupe(u8, pattern);
            destination.append(self.allocator, copy) catch |err| {
                self.allocator.free(copy);
                return err;
            };
        }
    }

    fn addScheme(self: *Builder, destination: *std.ArrayList([]u8), scheme: []const u8) error{OutOfMemory}!void {
        for (destination.items) |pattern| {
            if (pattern.len == scheme.len + 1 and
                std.mem.eql(u8, pattern[0..scheme.len], scheme) and
                pattern[scheme.len] == ':') return;
        }
        const pattern = try std.fmt.allocPrint(self.allocator, "{s}:", .{scheme});
        destination.append(self.allocator, pattern) catch |err| {
            self.allocator.free(pattern);
            return err;
        };
    }
};

pub fn moduleSpecs(allocator: std.mem.Allocator, readers: []const reader.ModuleReader) error{OutOfMemory}![]message.ClientModuleReader {
    const out = try allocator.alloc(message.ClientModuleReader, readers.len);
    for (readers, out) |item, *slot| slot.* = item.spec();
    return out;
}

pub fn resourceSpecs(allocator: std.mem.Allocator, readers: []const reader.ResourceReader) error{OutOfMemory}![]message.ClientResourceReader {
    const out = try allocator.alloc(message.ClientResourceReader, readers.len);
    for (readers, out) |item, *slot| slot.* = item.spec();
    return out;
}

pub fn toRequest(allocator: std.mem.Allocator, options: Options, request_id: i64) error{OutOfMemory}!message.CreateEvaluatorRequest {
    const module_readers = if (options.module_readers.len == 0) null else try moduleSpecs(allocator, options.module_readers);
    errdefer if (module_readers) |specs| allocator.free(specs);
    const resource_readers = if (options.resource_readers.len == 0) null else try resourceSpecs(allocator, options.resource_readers);
    return .{
        .request_id = request_id,
        .allowed_modules = options.allowed_modules,
        .allowed_resources = options.allowed_resources,
        .client_module_readers = module_readers,
        .client_resource_readers = resource_readers,
        .module_paths = options.module_paths,
        .env = options.env,
        .properties = options.properties,
        .timeout_seconds = options.timeout_seconds,
        .root_dir = options.root_dir,
        .cache_dir = options.cache_dir,
        .output_format = options.output_format,
        .project = options.project,
        .http = options.http,
        .external_module_readers = options.external_module_readers,
        .external_resource_readers = options.external_resource_readers,
        .trace_mode = options.trace_mode,
    };
}

fn allocateRequest(allocator: std.mem.Allocator, module_reader: reader.ModuleReader, resource_reader: reader.ResourceReader) !void {
    const request = try toRequest(allocator, .{
        .module_readers = &.{module_reader},
        .resource_readers = &.{resource_reader},
    }, 1);
    allocator.free(request.client_module_readers.?);
    allocator.free(request.client_resource_readers.?);
}

test "restricted defaults deny resources and older pkl rejects http headers" {
    const restricted = Options.restricted();
    try std.testing.expectEqual(@as(usize, 0), restricted.allowed_resources.?.len);
    try std.testing.expect(restricted.output_format == null);
    const with_headers = Options{ .http = .{ .headers = &.{} } };
    try std.testing.expectError(error.UnsupportedVersion, with_headers.validate(.{ .major = 0, .minor = 31, .patch = 0 }));
    try with_headers.validate(.{ .major = 0, .minor = 32, .patch = 0 });
    try Options.restricted().validate(version.http_settings);
    try std.testing.expectError(error.UnsupportedVersion, Options.restricted().validate(.{ .major = 0, .minor = 25, .patch = 2 }));
    const with_rewrites = Options{ .http = .{ .rewrites = &.{} } };
    try std.testing.expectError(error.UnsupportedVersion, with_rewrites.validate(.{ .major = 0, .minor = 28, .patch = 9 }));
    try with_rewrites.validate(version.http_rewrites);
    const with_proxy = Options{ .http = .{ .proxy = .{ .address = "http://proxy" } } };
    try with_proxy.validate(.{ .major = 0, .minor = 26, .patch = 0 });

    try std.testing.expect(!Options.preconfigured().usesNewerFeatures());
    try std.testing.expect(with_proxy.usesNewerFeatures());
    const combined = Options{ .http = .{ .proxy = .{ .address = "http://proxy" } }, .trace_mode = .compact };
    try std.testing.expectEqual(version.trace_mode, combined.requiredVersion());

    var embed = reader.Embed{ .scheme_name = "mem", .entries = &.{} };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocateRequest, .{
        embed.moduleReader(),
        embed.resourceReader(),
    });

    var builder = Builder.init(std.testing.allocator);
    defer builder.deinit();
    _ = try builder.moduleReaders(&.{embed.moduleReader()});
    _ = try builder.resourceReaders(&.{embed.resourceReader()});
    try std.testing.expectEqualStrings("mem:", builder.options.allowed_modules.?[0]);
    try std.testing.expectEqualStrings("mem:", builder.options.allowed_resources.?[0]);
}
