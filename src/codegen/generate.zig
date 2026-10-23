//! Runs code generation against a Pkl server and writes the planned files.

const std = @import("std");
const schema = @import("schema.zig");
const plan = @import("plan.zig");
const output = @import("output.zig");
const verify = @import("verify.zig");
const Diagnostics = @import("diagnostics.zig").Diagnostics;
const manager = @import("../evaluator/manager.zig");
const options_mod = @import("../evaluator/options.zig");
const project = @import("../evaluator/project.zig");
const reader = @import("../evaluator/reader.zig");
const logger = @import("../evaluator/logger.zig");
const uri = @import("../evaluator/uri.zig");
const message = @import("../protocol/message.zig");

pub const Options = struct {
    /// Module paths or absolute URIs (`file:`, `package:`, `modulepath:`, ...).
    /// Relative paths are resolved against the current directory.
    modules: []const []const u8,
    output_dir: []const u8,
    /// Directory containing the `PklProject` whose dependencies the modules
    /// import through `@name/...` notation.
    project_dir: ?[]const u8 = null,
    packages: []const plan.PackageMapping = &.{},
    index_file: []const u8 = "root.zig",
    /// Count out-of-date files without changing the output directory.
    check: bool = false,
    /// Replace or remove files the generator does not own. See `output`.
    force: bool = false,
    /// Pkl regular expressions for resource URIs (`file:`, `env:HOME`,
    /// `https:`, ...) that may be read while describing the modules. Defaults that read anything else
    /// fail to evaluate, are reported as warnings, and are left out of the
    /// bindings. Environment variables and external properties are hidden
    /// unless `env:` or `prop:` is allowed.
    allowed_resources: []const []const u8 = &.{},
    /// Whether to type-check the bindings with the Zig compiler before
    /// writing them.
    verify: Verify,
};

pub const Verify = union(enum) {
    skip,
    check: verify.Options,
};

pub const Report = output.Report;

/// Starts `pkl_executable server`, generates, and stops the server. A missing
/// executable is reported as `error.FileNotFound`.
pub fn generateWithExecutable(
    allocator: std.mem.Allocator,
    io: std.Io,
    pkl_executable: []const u8,
    options: Options,
    diagnostics: *Diagnostics,
) !Report {
    const pkl = try manager.Manager.init(allocator, io, &.{ pkl_executable, "server" }, logger.Logger.noop);
    defer pkl.deinit();
    return generate(allocator, io, pkl, options, diagnostics);
}

/// Describes `options.modules` with a sandboxed evaluator created on `pkl`,
/// plans the bindings, type-checks them unless `options.verify` is `.skip`,
/// and updates `options.output_dir`.
pub fn generate(
    allocator: std.mem.Allocator,
    io: std.Io,
    pkl: *manager.Manager,
    options: Options,
    diagnostics: *Diagnostics,
) !Report {
    if (options.modules.len == 0) {
        try diagnostics.add(null, "no modules to generate", .{});
        return error.CodegenFailed;
    }
    var uris: std.ArrayList([]u8) = .empty;
    defer {
        for (uris.items) |item| allocator.free(item);
        uris.deinit(allocator);
    }
    for (options.modules) |module| {
        const resolved = moduleUri(allocator, io, module) catch |err| {
            try diagnostics.add(null, "cannot open module `{s}`: {t}", .{ module, err });
            return error.CodegenFailed;
        };
        try uris.append(allocator, resolved);
    }

    var embed = reader.Embed{
        .scheme_name = schema.scheme,
        .entries = &.{.{ .path = "/Schema.pkl", .contents = schema.source }},
    };
    const readers = [_]reader.ModuleReader{embed.moduleReader()};
    const allowed = options_mod.preconfigured_modules ++ [_][]const u8{schema.scheme ++ ":"};
    var resource_patterns: std.ArrayList([]const u8) = .empty;
    defer {
        const owned_start = @min(options.allowed_resources.len, resource_patterns.items.len);
        for (resource_patterns.items[owned_start..]) |pattern| allocator.free(pattern);
        resource_patterns.deinit(allocator);
    }
    try resource_patterns.appendSlice(allocator, options.allowed_resources);
    // The description reads each described module's source to see whether a
    // default mentions pkl:platform. Each pattern is anchored to that URI.
    for (uris.items) |module_uri| try appendOwned(allocator, &resource_patterns, try exactUriPattern(allocator, module_uri));

    var rejected: ?[]u8 = null;
    defer if (rejected) |text| pkl.allocator.free(text);
    var loaded: ?project.Owned = null;
    defer if (loaded) |*owned| owned.deinit();
    var evaluator_options = options_mod.Options.preconfigured();
    if (options.project_dir) |dir| {
        const project_path = try std.fs.path.join(allocator, &.{ dir, "PklProject" });
        defer allocator.free(project_path);
        const loader = pkl.createEvaluator(options_mod.Options.preconfigured(), &rejected) catch |err| {
            try reportRejected(diagnostics, err, rejected);
            return error.CodegenFailed;
        };
        defer loader.close();
        loaded = project.loadFile(allocator, io, loader, project_path) catch |err| {
            try diagnostics.add(project_path, "cannot load the project: {t}", .{err});
            return error.CodegenFailed;
        };
        evaluator_options = loaded.?.options;
    }
    sandbox(&evaluator_options, resource_patterns.items);
    evaluator_options.allowed_modules = &allowed;
    evaluator_options.module_readers = &readers;
    const listing = pkl.createEvaluator(evaluator_options, &rejected) catch |err| {
        try reportRejected(diagnostics, err, rejected);
        return error.CodegenFailed;
    };
    var failure: ?[]u8 = null;
    defer if (failure) |text| pkl.allocator.free(text);
    const described_uris = schema.describedUris(allocator, listing, @ptrCast(uris.items), &failure) catch |err| {
        listing.close();
        if (failure) |text| {
            try diagnostics.add(null, "Pkl evaluation failed:\n{s}", .{std.mem.trimEnd(u8, text, "\n")});
        } else try diagnostics.add(null, "cannot list the modules: {t}", .{err});
        return error.CodegenFailed;
    };
    listing.close();
    defer {
        for (described_uris) |item| allocator.free(item);
        allocator.free(described_uris);
    }
    const dependencies: []const message.NamedDependency = if (evaluator_options.project) |item| item.dependencies else &.{};
    for (described_uris) |module_uri| {
        if (!containsUri(uris.items, module_uri)) {
            try appendOwned(allocator, &resource_patterns, try exactUriPattern(allocator, module_uri));
        }
        // Pkl checks a read of a local dependency module against its
        // resolved file as well, so allow exactly that file too.
        if (try localDependencyFile(allocator, dependencies, module_uri)) |path_pattern| {
            try appendOwned(allocator, &resource_patterns, path_pattern);
        }
    }
    sandbox(&evaluator_options, resource_patterns.items);
    const evaluator = pkl.createEvaluator(evaluator_options, &rejected) catch |err| {
        try reportRejected(diagnostics, err, rejected);
        return error.CodegenFailed;
    };
    defer evaluator.close();

    var described = schema.describe(allocator, evaluator, @ptrCast(uris.items), &failure) catch |err| {
        if (failure) |text| {
            try diagnostics.add(null, "Pkl evaluation failed:\n{s}", .{std.mem.trimEnd(u8, text, "\n")});
        } else try diagnostics.add(null, "cannot describe the modules: {t}", .{err});
        return error.CodegenFailed;
    };
    defer described.deinit();

    var planned = plan.plan(allocator, described.description, .{
        .packages = options.packages,
        .index_file = options.index_file,
    }, diagnostics) catch |err| switch (err) {
        error.InvalidSchema => return error.CodegenFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer planned.deinit();
    switch (options.verify) {
        .skip => {},
        .check => |settings| verify.check(allocator, io, settings, planned.files, options.index_file, diagnostics) catch |err| switch (err) {
            error.CodegenFailed, error.OutOfMemory => |e| return e,
            else => {
                try diagnostics.add(settings.scratch_dir, "cannot stage the bindings for type-checking: {t}", .{err});
                return error.CodegenFailed;
            },
        },
    }
    return output.writeFiles(allocator, io, options.output_dir, planned.files, .{ .check = options.check, .force = options.force }, diagnostics) catch |err| switch (err) {
        error.CodegenFailed, error.OutOfMemory => |e| return e,
        else => {
            try diagnostics.add(options.output_dir, "cannot update the output directory: {t}", .{err});
            return error.CodegenFailed;
        },
    };
}

/// For `projectpackage://host/name@version#/path.pkl` of a local dependency,
/// an anchored pattern for that module's file beside the dependency's
/// `PklProject`. Accepts `file:/` and `file:///` spellings. Null for other
/// URIs.
fn localDependencyFile(
    allocator: std.mem.Allocator,
    dependencies: []const message.NamedDependency,
    module_uri: []const u8,
) error{OutOfMemory}!?[]u8 {
    const prefix = "projectpackage://";
    if (!std.mem.startsWith(u8, module_uri, prefix)) return null;
    const hash = std.mem.indexOfScalar(u8, module_uri, '#') orelse return null;
    const package = module_uri[prefix.len..hash];
    const fragment = module_uri[hash + 1 ..];
    if (fragment.len == 0 or fragment[0] != '/') return null;
    const project_file = findLocal(dependencies, package) orelse return null;
    const file_prefix = "file://";
    if (!std.mem.startsWith(u8, project_file, file_prefix)) return null;
    const slash = std.mem.lastIndexOfScalar(u8, project_file, '/') orelse return null;
    const directory = project_file[file_prefix.len..slash];
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "^file:(?://)?");
    try appendEscaped(allocator, &out, directory);
    try appendEscaped(allocator, &out, fragment);
    try out.append(allocator, '$');
    return try out.toOwnedSlice(allocator);
}

fn findLocal(dependencies: []const message.NamedDependency, package: []const u8) ?[]const u8 {
    for (dependencies) |named| switch (named.dependency) {
        .local => |local| {
            if (local.package_uri) |declared| {
                const scheme = "package://";
                if (std.mem.startsWith(u8, declared, scheme) and std.mem.eql(u8, declared[scheme.len..], package)) {
                    return local.project_file_uri;
                }
            }
            if (findLocal(local.dependencies, package)) |found| return found;
        },
        .remote => {},
    };
    return null;
}

fn appendEscaped(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) error{OutOfMemory}!void {
    for (text) |byte| {
        if (std.mem.indexOfScalar(u8, ".^$|*+?()[]{}\\", byte) != null) try out.append(allocator, '\\');
        try out.append(allocator, byte);
    }
}

test "a local dependency module maps to its file" {
    const leaf = [_]message.NamedDependency{.{ .name = "leaf", .dependency = .{ .local = .{
        .project_file_uri = "file:///work/leaf/PklProject",
        .package_uri = "package://example.com/leaf@2.0.0",
    } } }};
    const dependencies = [_]message.NamedDependency{.{ .name = "dep", .dependency = .{ .local = .{
        .project_file_uri = "file:///work/dep.v1/PklProject",
        .package_uri = "package://example.com/dep@1.0.0",
        .dependencies = &leaf,
    } } }};
    const allocator = std.testing.allocator;
    const dep = (try localDependencyFile(allocator, &dependencies, "projectpackage://example.com/dep@1.0.0#/sub/x.pkl")).?;
    defer allocator.free(dep);
    try std.testing.expectEqualStrings("^file:(?://)?/work/dep\\.v1/sub/x\\.pkl$", dep);
    const nested = (try localDependencyFile(allocator, &dependencies, "projectpackage://example.com/leaf@2.0.0#/y.pkl")).?;
    defer allocator.free(nested);
    try std.testing.expectEqualStrings("^file:(?://)?/work/leaf/y\\.pkl$", nested);
    try std.testing.expect(try localDependencyFile(allocator, &dependencies, "package://example.com/dep@1.0.0#/x.pkl") == null);
    try std.testing.expect(try localDependencyFile(allocator, &dependencies, "projectpackage://example.com/other@1.0.0#/x.pkl") == null);
}

/// Appends `item`, which the list then owns, or frees it when the append fails.
fn appendOwned(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), item: []u8) error{OutOfMemory}!void {
    list.append(allocator, item) catch |err| {
        allocator.free(item);
        return err;
    };
}

fn containsUri(haystack: []const []u8, module_uri: []const u8) bool {
    for (haystack) |item| if (std.mem.eql(u8, item, module_uri)) return true;
    return false;
}

fn exactUriPattern(allocator: std.mem.Allocator, module_uri: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '^');
    for (module_uri) |byte| {
        if (std.mem.indexOfScalar(u8, ".^$|*+?()[]{}\\", byte) != null) try out.append(allocator, '\\');
        try out.append(allocator, byte);
    }
    try out.append(allocator, '$');
    return out.toOwnedSlice(allocator);
}

/// Restricts what describing the modules can observe: only the allowed
/// resources, no resource readers, and no environment variables or external
/// properties unless their schemes are allowed.
fn sandbox(options: *options_mod.Options, allowed_resources: []const []const u8) void {
    options.allowed_resources = allowed_resources;
    options.resource_readers = &.{};
    options.external_resource_readers = null;
    if (!allowsScheme(allowed_resources, "env:")) options.env = &.{};
    if (!allowsScheme(allowed_resources, "prop:")) options.properties = &.{};
}

fn allowsScheme(patterns: []const []const u8, scheme: []const u8) bool {
    for (patterns) |pattern| {
        const unanchored = if (std.mem.startsWith(u8, pattern, "^")) pattern[1..] else pattern;
        if (std.mem.startsWith(u8, unanchored, scheme)) return true;
    }
    return false;
}

fn reportRejected(diagnostics: *Diagnostics, err: anyerror, rejected: ?[]u8) error{OutOfMemory}!void {
    if (rejected) |text| {
        try diagnostics.add(null, "the Pkl server rejected the evaluator: {s}", .{text});
    } else try diagnostics.add(null, "cannot create an evaluator: {t}", .{err});
}

/// `text` when it already names a URI scheme, otherwise the `file:` URI of
/// the real path of `text`.
pub fn moduleUri(allocator: std.mem.Allocator, io: std.Io, text: []const u8) ![]u8 {
    if (hasScheme(text)) return allocator.dupe(u8, text);
    var file = try std.Io.Dir.cwd().openFile(io, text, .{});
    defer file.close(io);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try file.realPath(io, &buffer);
    return uri.fromPath(allocator, buffer[0..length], .native);
}

fn hasScheme(text: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return false;
    if (colon < 2) return false;
    if (!std.ascii.isAlphabetic(text[0])) return false;
    for (text[1..colon]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '+' and byte != '-' and byte != '.') return false;
    }
    return true;
}

test "scheme detection leaves paths and drive letters alone" {
    try std.testing.expect(hasScheme("file:///a.pkl"));
    try std.testing.expect(hasScheme("package://example.com/x@1#/a.pkl"));
    try std.testing.expect(hasScheme("modulepath:/a.pkl"));
    try std.testing.expect(!hasScheme("C:\\a.pkl"));
    try std.testing.expect(!hasScheme("config/app.pkl"));
    try std.testing.expect(!hasScheme("./a:b.pkl"));
}

test "the sandbox hides resources, environment, and properties by default" {
    var options = options_mod.Options.preconfigured();
    sandbox(&options, &.{});
    try std.testing.expectEqual(@as(usize, 0), options.allowed_resources.?.len);
    try std.testing.expectEqual(@as(usize, 0), options.env.?.len);
    try std.testing.expectEqual(@as(usize, 0), options.properties.?.len);

    var opened = options_mod.Options.preconfigured();
    sandbox(&opened, &.{ "env:", "file:" });
    try std.testing.expectEqual(@as(usize, 2), opened.allowed_resources.?.len);
    try std.testing.expect(opened.env == null);
    try std.testing.expectEqual(@as(usize, 0), opened.properties.?.len);

    var anchored = options_mod.Options.preconfigured();
    sandbox(&anchored, &.{"^prop:"});
    try std.testing.expect(anchored.properties == null);
    try std.testing.expectEqual(@as(usize, 0), anchored.env.?.len);
}
