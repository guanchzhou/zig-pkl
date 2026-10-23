//! Owned project settings loaded from `PklProject` and `PklProject.deps.json`.
//!
//! Dependency names come from the `dependencies` declared in `PklProject`.
//! The lock file supplies the resolved version and checksums for each
//! dependency, keyed by its canonical `package://host/path@MAJOR` URI. Local
//! dependencies keep their own declared dependencies, resolved through the
//! root lock file, at every nesting level.

const std = @import("std");
const message = @import("../protocol/message.zig");
const value = @import("../value/value.zig");
const options = @import("options.zig");
const manager = @import("manager.zig");
const source = @import("source.zig");
const uri = @import("uri.zig");

pub const lock_file_name = "PklProject.deps.json";
pub const max_lock_bytes = 16 * 1024 * 1024;

pub const Error = error{
    InvalidProject,
    InvalidDependencies,
    MissingDependencyLock,
    UnresolvedDependency,
    MissingField,
    Overflow,
    OutOfMemory,
} || value.Error;

/// Owns every string and slice referenced by `options` and `project`.
/// Both views become invalid after `deinit`.
pub const Owned = struct {
    arena: *std.heap.ArenaAllocator,
    options: options.Options,
    project: message.Project,

    /// The canonical `file:` URI of the loaded `PklProject`. `loadFile`
    /// resolves symlinks and relative paths, so this can differ from the
    /// path the caller passed. Evaluate project modules through `moduleUri`
    /// so the server places them inside this project.
    pub fn projectUri(self: Owned) []const u8 {
        return self.project.project_file_uri;
    }

    /// Returns the URI of `relative`, a `/`-separated path beside the
    /// canonical `PklProject`. The caller owns the result.
    pub fn moduleUri(self: Owned, allocator: std.mem.Allocator, relative: []const u8) uri.Error![]u8 {
        return uri.sibling(allocator, self.projectUri(), relative);
    }

    pub fn deinit(self: *Owned) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
        self.* = undefined;
    }
};

const project_expression = "List(resolvedEvaluatorSettings, dependencies)";

/// Evaluates the project module at `project_uri` and merges its declared
/// dependencies with `lock_json`. A missing lock is valid only when the
/// project declares no dependencies.
pub fn load(
    allocator: std.mem.Allocator,
    evaluator: *manager.Evaluator,
    project_uri: []const u8,
    lock_json: ?[]const u8,
) !Owned {
    var failure: ?[]u8 = null;
    defer if (failure) |text| allocator.free(text);
    var evaluated = try evaluator.evaluateSource(source.Source.uri(project_uri), project_expression, &failure);
    defer evaluated.deinit();
    const parts = switch (evaluated.root.*) {
        .list => |items| items,
        else => return error.InvalidProject,
    };
    if (parts.len != 2) return error.InvalidProject;
    return fromEvaluated(allocator, project_uri, parts[0], parts[1], lock_json);
}

/// Loads a filesystem `PklProject` and its optional sibling lock file.
/// Relative paths resolve against the current working directory and
/// symlinks resolve to their target, then the canonical project URI is
/// percent-encoded for the host platform. See `Owned.projectUri`.
pub fn loadFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    evaluator: *manager.Evaluator,
    project_path: []const u8,
) !Owned {
    const absolute = try absolutePath(allocator, io, project_path);
    defer allocator.free(absolute);
    const directory = std.fs.path.dirname(absolute) orelse return error.InvalidProject;
    const lock_path = try std.fs.path.join(allocator, &.{ directory, lock_file_name });
    defer allocator.free(lock_path);
    const lock_json: ?[]u8 = std.Io.Dir.cwd().readFileAlloc(io, lock_path, allocator, .limited(max_lock_bytes)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (lock_json) |bytes| allocator.free(bytes);
    const project_uri = try uri.fromPath(allocator, absolute, .native);
    defer allocator.free(project_uri);
    return load(allocator, evaluator, project_uri, lock_json);
}

fn absolutePath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = file.realPath(io, &buffer) catch |err| switch (err) {
        error.OperationUnsupported => {
            if (!std.fs.path.isAbsolute(path)) return err;
            return allocator.dupe(u8, path);
        },
        else => return err,
    };
    return allocator.dupe(u8, buffer[0..length]);
}

/// Builds owned options from evaluated `resolvedEvaluatorSettings` and
/// `dependencies` values plus optional lock file contents.
pub fn fromEvaluated(
    allocator: std.mem.Allocator,
    project_uri: []const u8,
    settings: *const value.Value,
    dependencies: *const value.Value,
    lock_json: ?[]const u8,
) Error!Owned {
    if (settings.* != .object) return error.InvalidProject;
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = .init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    const owned = arena.allocator();
    const lock = if (lock_json) |bytes| try Lock.parse(owned, bytes) else null;
    const project = message.Project{
        .project_file_uri = try owned.dupe(u8, project_uri),
        .dependencies = try convertDependencies(owned, dependencies, if (lock) |*item| item else null),
    };
    var result = options.Options{
        .allowed_modules = try optionalStrings(owned, settings, "allowedModules"),
        .allowed_resources = try optionalStrings(owned, settings, "allowedResources"),
        .module_paths = try optionalStrings(owned, settings, "modulePath"),
        .env = try optionalPairs(owned, settings, "env"),
        .properties = try optionalPairs(owned, settings, "externalProperties"),
        .timeout_seconds = try optionalTimeout(settings),
        .root_dir = try optionalString(owned, settings, "rootDir"),
        .cache_dir = try optionalString(owned, settings, "moduleCacheDir"),
        .project = project,
        .http = try optionalHttp(owned, settings),
        .external_module_readers = try optionalExternalReaders(owned, settings, "externalModuleReaders"),
        .external_resource_readers = try optionalExternalReaders(owned, settings, "externalResourceReaders"),
    };
    if (value.findProperty(settings, "traceMode")) |trace| {
        if (trace.* != .nil) {
            const text = try stringLike(trace);
            result.trace_mode = message.TraceMode.parse(text) orelse return error.InvalidProject;
        }
    }
    return .{ .arena = arena, .options = result, .project = project };
}

const LockEntry = union(enum) {
    remote: struct { uri: []const u8, sha256: ?[]const u8 },
    local: struct { uri: []const u8 },
};

const Lock = struct {
    entries: std.StringHashMapUnmanaged(LockEntry),

    fn parse(allocator: std.mem.Allocator, bytes: []const u8) Error!Lock {
        const root = std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidDependencies,
        };
        if (root != .object) return error.InvalidDependencies;
        const schema = root.object.get("schemaVersion") orelse return error.MissingField;
        if (schema != .integer or schema.integer != 1) return error.InvalidDependencies;
        const resolved = root.object.get("resolvedDependencies") orelse return error.MissingField;
        if (resolved != .object) return error.InvalidDependencies;
        var lock = Lock{ .entries = .empty };
        try lock.entries.ensureTotalCapacity(allocator, std.math.cast(u32, resolved.object.count()) orelse return error.Overflow);
        var iterator = resolved.object.iterator();
        while (iterator.next()) |entry| {
            const item = entry.value_ptr.*;
            if (item != .object) return error.InvalidDependencies;
            const kind = try jsonString(item.object.get("type") orelse return error.MissingField);
            const resolved_uri = try jsonString(item.object.get("uri") orelse return error.MissingField);
            const parsed: LockEntry = if (std.mem.eql(u8, kind, "remote")) blk: {
                var sha256: ?[]const u8 = null;
                if (item.object.get("checksums")) |checksums| {
                    if (checksums != .object) return error.InvalidDependencies;
                    sha256 = try jsonString(checksums.object.get("sha256") orelse return error.MissingField);
                }
                break :blk .{ .remote = .{ .uri = resolved_uri, .sha256 = sha256 } };
            } else if (std.mem.eql(u8, kind, "local"))
                .{ .local = .{ .uri = resolved_uri } }
            else
                return error.InvalidDependencies;
            lock.entries.putAssumeCapacity(entry.key_ptr.*, parsed);
        }
        return lock;
    }

    fn find(self: *const Lock, allocator: std.mem.Allocator, declared_uri: []const u8) Error!LockEntry {
        const key = try canonicalKey(allocator, declared_uri);
        defer allocator.free(key);
        return self.entries.get(key) orelse error.UnresolvedDependency;
    }
};

/// `package://example.com/pkg@1.2.3` locks under `package://example.com/pkg@1`.
fn canonicalKey(allocator: std.mem.Allocator, package_uri: []const u8) Error![]u8 {
    const at = std.mem.lastIndexOfScalar(u8, package_uri, '@') orelse return error.InvalidProject;
    const version = package_uri[at + 1 ..];
    const major_end = std.mem.indexOfScalar(u8, version, '.') orelse version.len;
    if (major_end == 0) return error.InvalidProject;
    return std.mem.concat(allocator, u8, &.{ package_uri[0 .. at + 1], version[0..major_end] });
}

/// Lock files record `projectpackage://` URIs; the message API expects `package://`.
fn packageUri(allocator: std.mem.Allocator, locked_uri: []const u8) Error![]const u8 {
    const prefix = "projectpackage://";
    if (std.mem.startsWith(u8, locked_uri, prefix)) {
        return std.mem.concat(allocator, u8, &.{ "package://", locked_uri[prefix.len..] });
    }
    return allocator.dupe(u8, locked_uri);
}

fn convertDependencies(
    allocator: std.mem.Allocator,
    declared: *const value.Value,
    lock: ?*const Lock,
) Error![]const message.NamedDependency {
    const entries = switch (declared.*) {
        .nil => return &.{},
        .map => |entries| entries,
        .mapping => |entries| entries,
        else => return error.InvalidProject,
    };
    if (entries.len == 0) return &.{};
    const resolved = lock orelse return error.MissingDependencyLock;
    const result = try allocator.alloc(message.NamedDependency, entries.len);
    for (entries, result) |entry, *slot| {
        const name = try allocator.dupe(u8, try stringLike(entry.key));
        const dependency = entry.value;
        if (dependency.* != .object) return error.InvalidProject;
        if (value.findProperty(dependency, "projectFileUri")) |project_file| {
            const package = value.findProperty(dependency, "package") orelse return error.InvalidProject;
            if (package.* != .object) return error.InvalidProject;
            const declared_uri = try stringLike(value.findProperty(package, "uri") orelse return error.MissingField);
            switch (try resolved.find(allocator, declared_uri)) {
                .local => {},
                .remote => return error.InvalidDependencies,
            }
            const nested = value.findProperty(dependency, "dependencies") orelse return error.MissingField;
            slot.* = .{ .name = name, .dependency = .{ .local = .{
                .project_file_uri = try allocator.dupe(u8, try stringLike(project_file)),
                .package_uri = try allocator.dupe(u8, declared_uri),
                .dependencies = try convertDependencies(allocator, nested, resolved),
            } } };
        } else {
            const declared_uri = try stringLike(value.findProperty(dependency, "uri") orelse return error.MissingField);
            const locked = switch (try resolved.find(allocator, declared_uri)) {
                .remote => |remote| remote,
                .local => return error.InvalidDependencies,
            };
            const sha256 = locked.sha256 orelse try declaredChecksum(dependency);
            slot.* = .{ .name = name, .dependency = .{ .remote = .{
                .package_uri = try packageUri(allocator, locked.uri),
                .checksums = if (sha256) |digest| .{ .sha256 = try allocator.dupe(u8, digest) } else null,
            } } };
        }
    }
    return result;
}

fn declaredChecksum(dependency: *const value.Value) Error!?[]const u8 {
    const checksums = value.findProperty(dependency, "checksums") orelse return null;
    if (checksums.* == .nil) return null;
    if (checksums.* != .object) return error.InvalidProject;
    const digest = value.findProperty(checksums, "sha256") orelse return null;
    if (digest.* == .nil) return null;
    return try stringLike(digest);
}

fn jsonString(item: std.json.Value) Error![]const u8 {
    if (item != .string) return error.InvalidDependencies;
    return item.string;
}

fn optionalString(allocator: std.mem.Allocator, object: *const value.Value, name: []const u8) Error!?[]const u8 {
    const item = value.findProperty(object, name) orelse return null;
    if (item.* == .nil) return null;
    return try allocator.dupe(u8, try stringLike(item));
}

fn stringLike(item: *const value.Value) Error![]const u8 {
    return switch (item.*) {
        .string => |text| text,
        .object => stringLike(value.findProperty(item, "name") orelse return error.InvalidProject),
        else => return error.InvalidProject,
    };
}

fn optionalStrings(
    allocator: std.mem.Allocator,
    object: *const value.Value,
    name: []const u8,
) Error!?[]const []const u8 {
    const item = value.findProperty(object, name) orelse return null;
    if (item.* == .nil) return null;
    return try stringsFromValue(allocator, item);
}

fn stringsFromValue(allocator: std.mem.Allocator, item: *const value.Value) Error![]const []const u8 {
    const source_items = switch (item.*) {
        .list => |items| items,
        .listing => |items| items,
        .set => |items| items,
        else => return error.InvalidProject,
    };
    const result = try allocator.alloc([]const u8, source_items.len);
    for (source_items, result) |source_item, *destination| {
        destination.* = try allocator.dupe(u8, try stringLike(source_item));
    }
    return result;
}

fn optionalPairs(
    allocator: std.mem.Allocator,
    object: *const value.Value,
    name: []const u8,
) Error!?[]const message.StringPair {
    const item = value.findProperty(object, name) orelse return null;
    if (item.* == .nil) return null;
    const entries = switch (item.*) {
        .map => |entries| entries,
        .mapping => |entries| entries,
        else => return error.InvalidProject,
    };
    const result = try allocator.alloc(message.StringPair, entries.len);
    for (entries, result) |entry, *destination| {
        destination.* = .{
            .key = try allocator.dupe(u8, try stringLike(entry.key)),
            .value = try allocator.dupe(u8, try stringLike(entry.value)),
        };
    }
    return result;
}

fn optionalTimeout(settings: *const value.Value) Error!?i64 {
    const item = value.findProperty(settings, "timeout") orelse return null;
    if (item.* == .nil) return null;
    if (item.* != .duration or !std.mem.eql(u8, item.duration.unit, "s")) return error.InvalidProject;
    const seconds = item.duration.value;
    if (!std.math.isFinite(seconds) or @floor(seconds) != seconds) return error.InvalidProject;
    if (seconds < 0 or seconds > @as(f64, @floatFromInt(std.math.maxInt(i64)))) return error.Overflow;
    return @intFromFloat(seconds);
}

fn optionalExternalReaders(
    allocator: std.mem.Allocator,
    settings: *const value.Value,
    name: []const u8,
) Error!?[]const message.ExternalReader {
    const item = value.findProperty(settings, name) orelse return null;
    if (item.* == .nil) return null;
    const entries = switch (item.*) {
        .map => |entries| entries,
        .mapping => |entries| entries,
        else => return error.InvalidProject,
    };
    const readers = try allocator.alloc(message.ExternalReader, entries.len);
    for (entries, readers) |entry, *destination| {
        if (entry.value.* != .object) return error.InvalidProject;
        destination.* = .{
            .scheme = try allocator.dupe(u8, try stringLike(entry.key)),
            .executable = (try optionalString(allocator, entry.value, "executable")) orelse return error.MissingField,
            .arguments = try optionalStrings(allocator, entry.value, "arguments"),
            .working_dir = try optionalString(allocator, entry.value, "workingDir"),
        };
    }
    return readers;
}

fn optionalHttp(allocator: std.mem.Allocator, settings: *const value.Value) Error!?message.Http {
    const item = value.findProperty(settings, "http") orelse return null;
    if (item.* == .nil) return null;
    if (item.* != .object) return error.InvalidProject;
    var result = message.Http{};
    if (value.findProperty(item, "proxy")) |proxy| {
        if (proxy.* != .nil) {
            if (proxy.* != .object) return error.InvalidProject;
            result.proxy = .{
                .address = try optionalString(allocator, proxy, "address"),
                .no_proxy = try optionalStrings(allocator, proxy, "noProxy"),
            };
        }
    }
    result.rewrites = try optionalPairs(allocator, item, "rewrites");
    result.headers = try optionalHeaders(allocator, item);
    return result;
}

fn optionalHeaders(allocator: std.mem.Allocator, http: *const value.Value) Error!?[]const message.HeaderRule {
    const item = value.findProperty(http, "headers") orelse return null;
    if (item.* == .nil) return null;
    const rules = switch (item.*) {
        .map => |entries| entries,
        .mapping => |entries| entries,
        else => return error.InvalidProject,
    };
    const result = try allocator.alloc(message.HeaderRule, rules.len);
    for (rules, result) |rule, *destination| {
        const headers = switch (rule.value.*) {
            .map => |entries| entries,
            .mapping => |entries| entries,
            else => return error.InvalidProject,
        };
        const lists = try allocator.alloc(message.HeaderList, headers.len);
        for (headers, lists) |header, *list| {
            list.name = try allocator.dupe(u8, try stringLike(header.key));
            list.values = switch (header.value.*) {
                .string => blk: {
                    const one = try allocator.alloc([]const u8, 1);
                    one[0] = try allocator.dupe(u8, header.value.string);
                    break :blk one;
                },
                .list, .listing, .set => try stringsFromValue(allocator, header.value),
                else => return error.InvalidProject,
            };
        }
        destination.* = .{
            .pattern = try allocator.dupe(u8, try stringLike(rule.key)),
            .headers = lists,
        };
    }
    return result;
}

const TestValues = struct {
    pkl: value.Value = .{ .string = "pkl:" },
    repl: value.Value = .{ .string = "repl:" },
    allowed_items: [2]*value.Value = undefined,
    allowed: value.Value = undefined,
    timeout: value.Value = .{ .duration = .{ .value = 2, .unit = "s" } },
    root: value.Value = .{ .string = "/tmp/project" },
    key: value.Value = .{ .string = "MODE" },
    val: value.Value = .{ .string = "test" },
    env_entries: [1]value.Entry = undefined,
    env: value.Value = undefined,
    members: [4]value.Member = undefined,
    settings: value.Value = undefined,

    fn init(self: *TestValues) void {
        self.allowed_items = .{ &self.pkl, &self.repl };
        self.allowed = .{ .set = &self.allowed_items };
        self.env_entries = .{.{ .key = &self.key, .value = &self.val }};
        self.env = .{ .mapping = &self.env_entries };
        self.members = .{
            .{ .property = .{ .name = "allowedModules", .value = &self.allowed } },
            .{ .property = .{ .name = "timeout", .value = &self.timeout } },
            .{ .property = .{ .name = "rootDir", .value = &self.root } },
            .{ .property = .{ .name = "env", .value = &self.env } },
        };
        self.settings = .{ .object = .{
            .class_name = "EvaluatorSettings",
            .module_uri = "pkl:EvaluatorSettings",
            .members = &self.members,
        } };
    }
};

fn testObject(members: []value.Member) value.Value {
    return .{ .object = .{ .class_name = "Dynamic", .module_uri = "pkl:base", .members = members } };
}

test "declared dependency names merge with lock data and keep nested local dependencies" {
    const allocator = std.testing.allocator;
    var values = TestValues{};
    values.init();

    var leaf_package_uri = value.Value{ .string = "package://example.com/leaf@2.3.4" };
    var leaf_package_members = [_]value.Member{.{ .property = .{ .name = "uri", .value = &leaf_package_uri } }};
    var leaf_package = testObject(&leaf_package_members);
    var leaf_file = value.Value{ .string = "file:///work/leaf/PklProject" };
    var leaf_dependencies = value.Value{ .mapping = &.{} };
    var leaf_members = [_]value.Member{
        .{ .property = .{ .name = "package", .value = &leaf_package } },
        .{ .property = .{ .name = "dependencies", .value = &leaf_dependencies } },
        .{ .property = .{ .name = "projectFileUri", .value = &leaf_file } },
    };
    var leaf = testObject(&leaf_members);
    var inner_name = value.Value{ .string = "inner" };
    var dep_entries = [_]value.Entry{.{ .key = &inner_name, .value = &leaf }};
    var dep_dependencies = value.Value{ .mapping = &dep_entries };

    var dep_package_uri = value.Value{ .string = "package://example.com/dep@1.0.0" };
    var dep_package_members = [_]value.Member{.{ .property = .{ .name = "uri", .value = &dep_package_uri } }};
    var dep_package = testObject(&dep_package_members);
    var dep_file = value.Value{ .string = "file:///work/dep/PklProject" };
    var dep_members = [_]value.Member{
        .{ .property = .{ .name = "package", .value = &dep_package } },
        .{ .property = .{ .name = "dependencies", .value = &dep_dependencies } },
        .{ .property = .{ .name = "projectFileUri", .value = &dep_file } },
    };
    var dep = testObject(&dep_members);

    var birds_uri = value.Value{ .string = "package://example.com/birds@0.5.0" };
    var birds_members = [_]value.Member{.{ .property = .{ .name = "uri", .value = &birds_uri } }};
    var birds = testObject(&birds_members);

    var local_name = value.Value{ .string = "fixture_dep" };
    var remote_name = value.Value{ .string = "birds" };
    var root_entries = [_]value.Entry{
        .{ .key = &local_name, .value = &dep },
        .{ .key = &remote_name, .value = &birds },
    };
    var root_dependencies = value.Value{ .mapping = &root_entries };

    const lock =
        \\{"schemaVersion":1,"resolvedDependencies":{
        \\"package://example.com/dep@1":{"type":"local","uri":"projectpackage://example.com/dep@1.0.0","path":"../dep"},
        \\"package://example.com/leaf@2":{"type":"local","uri":"projectpackage://example.com/leaf@2.3.4","path":"../leaf"},
        \\"package://example.com/birds@0":{"type":"remote","uri":"projectpackage://example.com/birds@0.6.1","checksums":{"sha256":"abc"}}}}
    ;
    var owned = try fromEvaluated(allocator, "file:///work/app/PklProject", &values.settings, &root_dependencies, lock);
    defer owned.deinit();
    try std.testing.expectEqualStrings("pkl:", owned.options.allowed_modules.?[0]);
    try std.testing.expectEqual(@as(?i64, 2), owned.options.timeout_seconds);
    try std.testing.expectEqualStrings("MODE", owned.options.env.?[0].key);

    const dependencies = owned.project.dependencies;
    try std.testing.expectEqual(@as(usize, 2), dependencies.len);
    try std.testing.expectEqualStrings("fixture_dep", dependencies[0].name);
    const local = dependencies[0].dependency.local;
    try std.testing.expectEqualStrings("file:///work/dep/PklProject", local.project_file_uri);
    try std.testing.expectEqualStrings("package://example.com/dep@1.0.0", local.package_uri.?);
    try std.testing.expectEqual(@as(usize, 1), local.dependencies.len);
    try std.testing.expectEqualStrings("inner", local.dependencies[0].name);
    try std.testing.expectEqualStrings("file:///work/leaf/PklProject", local.dependencies[0].dependency.local.project_file_uri);

    try std.testing.expectEqualStrings("birds", dependencies[1].name);
    const remote = dependencies[1].dependency.remote;
    try std.testing.expectEqualStrings("package://example.com/birds@0.6.1", remote.package_uri);
    try std.testing.expectEqualStrings("abc", remote.checksums.?.sha256);

    const encoded = try message.encodeAlloc(allocator, .{ .create_evaluator_request = .{
        .request_id = 1,
        .project = owned.project,
    } });
    defer allocator.free(encoded);
    var decoded = try message.decodeSlice(allocator, encoded);
    defer decoded.deinit();
    const wire = decoded.message.create_evaluator_request.project.?;
    try std.testing.expectEqualStrings("inner", wire.dependencies[0].dependency.local.dependencies[0].name);
}

test "lock file is optional only without declared dependencies" {
    const allocator = std.testing.allocator;
    var values = TestValues{};
    values.init();
    var none = value.Value{ .mapping = &.{} };
    var owned = try fromEvaluated(allocator, "file:///work/app/PklProject", &values.settings, &none, null);
    owned.deinit();

    var uri_value = value.Value{ .string = "package://example.com/birds@0.5.0" };
    var members = [_]value.Member{.{ .property = .{ .name = "uri", .value = &uri_value } }};
    var remote = testObject(&members);
    var name = value.Value{ .string = "birds" };
    var entries = [_]value.Entry{.{ .key = &name, .value = &remote }};
    var declared = value.Value{ .mapping = &entries };
    try std.testing.expectError(
        error.MissingDependencyLock,
        fromEvaluated(allocator, "file:///work/app/PklProject", &values.settings, &declared, null),
    );
    try std.testing.expectError(
        error.UnresolvedDependency,
        fromEvaluated(allocator, "file:///work/app/PklProject", &values.settings, &declared,
            \\{"schemaVersion":1,"resolvedDependencies":{}}
        ),
    );
}

test "canonical lock keys keep only the major version" {
    const allocator = std.testing.allocator;
    const key = try canonicalKey(allocator, "package://example.com/a/b@12.3.4");
    defer allocator.free(key);
    try std.testing.expectEqualStrings("package://example.com/a/b@12", key);
    try std.testing.expectError(error.InvalidProject, canonicalKey(allocator, "package://example.com/a"));
}
