const std = @import("std");
const zig_pkl = @import("zig_pkl");

const project_path = "tests/fixtures/project/PklProject";
const project_suffix = "/tests/fixtures/project";
const reader_suffix = "/tests/fixtures/project/reader";
const paths_project_path = "tests/fixtures/paths/PklProject";
const dependency_app_path = "tests/fixtures/dependencies/app/PklProject";
const dependency_main_path = "tests/fixtures/dependencies/app/main.pkl";

const PklCommand = struct {
    path: []const u8,
    owned: bool,

    fn deinit(self: PklCommand, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.path);
    }
};

fn pklExecutable(allocator: std.mem.Allocator) !PklCommand {
    const configured = std.process.Environ.getAlloc(std.testing.environ, allocator, "PKL_EXEC") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return .{ .path = "pkl", .owned = false },
        else => return err,
    };
    if (configured.len == 0) {
        allocator.free(configured);
        return .{ .path = "pkl", .owned = false };
    }
    return .{ .path = configured, .owned = true };
}

fn openManager(allocator: std.mem.Allocator, io: std.Io) !*zig_pkl.Manager {
    const executable = try pklExecutable(allocator);
    defer executable.deinit(allocator);
    return zig_pkl.Manager.init(allocator, io, &.{ executable.path, "server" }, zig_pkl.Logger.noop);
}

/// A missing Pkl skips the test unless `ZIG_PKL_REQUIRE_PKL=1`.
fn skipWithoutPkl(err: anyerror) anyerror {
    return switch (err) {
        error.FileNotFound => if (pklRequired()) error.PklRequired else error.SkipZigTest,
        else => err,
    };
}

fn pklRequired() bool {
    const flag = std.process.Environ.getAlloc(std.testing.environ, std.testing.allocator, "ZIG_PKL_REQUIRE_PKL") catch return false;
    defer std.testing.allocator.free(flag);
    return std.mem.eql(u8, flag, "1");
}

fn fileUri(allocator: std.mem.Allocator, io: std.Io, relative: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, relative, .{});
    defer file.close(io);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try file.realPath(io, &buffer);
    return zig_pkl.uri.fromPath(allocator, buffer[0..length], .native);
}

fn serverAtLeast(allocator: std.mem.Allocator, io: std.Io, minimum: []const u8) !bool {
    const executable = try pklExecutable(allocator);
    defer executable.deinit(allocator);
    const server = try zig_pkl.getVersion(allocator, io, executable.path);
    return server.atLeast(try zig_pkl.version.Version.parse(minimum));
}

/// From Pkl 0.32 the project module resolves its own settings; zig-pkl's
/// resolution of every release's plain settings must match it exactly.
fn expectPklResolution(evaluator: *zig_pkl.Evaluator, project: zig_pkl.project.Owned) !void {
    const allocator = std.testing.allocator;
    var failure: ?[]u8 = null;
    defer if (failure) |text| allocator.free(text);
    var resolved = try evaluator.evaluateSource(zig_pkl.Source.uri(project.projectUri()), "resolvedEvaluatorSettings", &failure);
    defer resolved.deinit();
    const settings = resolved.root;
    try expectOptionalString(zig_pkl.value.findProperty(settings, "rootDir"), project.options.root_dir);
    try expectOptionalString(zig_pkl.value.findProperty(settings, "moduleCacheDir"), project.options.cache_dir);
    const module_paths = zig_pkl.value.findProperty(settings, "modulePath").?;
    if (module_paths.* == .nil) {
        try std.testing.expectEqual(@as(?[]const []const u8, null), project.options.module_paths);
    } else {
        const items = switch (module_paths.*) {
            .list => |items| items,
            .listing => |items| items,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(items.len, project.options.module_paths.?.len);
        for (items, project.options.module_paths.?) |item, path| try std.testing.expectEqualStrings(item.string, path);
    }
    const readers = zig_pkl.value.findProperty(settings, "externalModuleReaders") orelse return;
    if (readers.* == .nil) return;
    const entries = switch (readers.*) {
        .map => |entries| entries,
        .mapping => |entries| entries,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(entries.len, project.options.external_module_readers.?.len);
    for (entries, project.options.external_module_readers.?) |entry, reader| {
        try expectOptionalString(zig_pkl.value.findProperty(entry.value, "executable"), reader.executable);
        try expectOptionalString(zig_pkl.value.findProperty(entry.value, "workingDir"), reader.working_dir);
    }
}

fn expectOptionalString(actual: ?*const zig_pkl.Value, expected: ?[]const u8) !void {
    if (actual == null or actual.?.* == .nil) return std.testing.expectEqual(@as(?[]const u8, null), expected);
    try std.testing.expectEqualStrings(actual.?.string, expected.?);
}

fn hasPathSuffix(path: []const u8, posix_suffix: []const u8) bool {
    if (std.mem.endsWith(u8, path, posix_suffix)) return true;
    if (path.len < posix_suffix.len) return false;
    for (path[path.len - posix_suffix.len ..], posix_suffix) |actual, expected| {
        if (actual != (if (expected == '/') '\\' else expected)) return false;
    }
    return true;
}

test "getVersion skips when pkl is not installed" {
    const executable = try pklExecutable(std.testing.allocator);
    defer executable.deinit(std.testing.allocator);
    _ = zig_pkl.getVersion(std.testing.allocator, std.testing.io, executable.path) catch |err| return skipWithoutPkl(err);
}

test "evaluate an inline module when pkl is installed" {
    const allocator = std.testing.allocator;
    const manager = openManager(allocator, std.testing.io) catch |err| return skipWithoutPkl(err);
    defer manager.deinit();
    var rejected: ?[]u8 = null;
    defer if (rejected) |text| allocator.free(text);
    const evaluator = try manager.createEvaluator(zig_pkl.Options.preconfigured(), &rejected);
    defer evaluator.close();

    var failure: ?[]u8 = null;
    defer if (failure) |text| allocator.free(text);
    var tree = try evaluator.evaluateSource(zig_pkl.Source.text("name = \"zig-pkl\"\ncount = 2"), "count", &failure);
    defer tree.deinit();
    try std.testing.expect(tree.root.* == .int);
    try std.testing.expect(tree.root.int.eql(.{ .signed = 2 }));
}

test "decode thirty levels of nested objects with default limits" {
    const allocator = std.testing.allocator;
    const levels = 30;
    const manager = openManager(allocator, std.testing.io) catch |err| return skipWithoutPkl(err);
    defer manager.deinit();
    var rejected: ?[]u8 = null;
    defer if (rejected) |text| allocator.free(text);
    const evaluator = try manager.createEvaluator(zig_pkl.Options.preconfigured(), &rejected);
    defer evaluator.close();

    var text: std.Io.Writer.Allocating = .init(allocator);
    defer text.deinit();
    for (0..levels) |_| try text.writer.writeAll("child { ");
    try text.writer.writeAll("leaf = 1 ");
    for (0..levels) |_| try text.writer.writeAll("} ");

    var failure: ?[]u8 = null;
    defer if (failure) |message| allocator.free(message);
    var tree = try evaluator.evaluateSource(zig_pkl.Source.text(text.written()), "child", &failure);
    defer tree.deinit();
    var node = tree.root;
    for (1..levels) |_| node = zig_pkl.value.findProperty(node, "child").?;
    const leaf = zig_pkl.value.findProperty(node, "leaf").?;
    try std.testing.expect(leaf.int.eql(.{ .signed = 1 }));
}

test "an in-process embed reader serves import globs" {
    const allocator = std.testing.allocator;
    const manager = openManager(allocator, std.testing.io) catch |err| return skipWithoutPkl(err);
    defer manager.deinit();
    var embed = zig_pkl.reader.Embed{
        .scheme_name = "mem",
        .entries = &.{
            .{ .path = "/lib/a.pkl", .contents = "name = \"a\"" },
            .{ .path = "/lib/b.pkl", .contents = "name = \"b\"" },
            .{ .path = "/lib/sub dir/c.pkl", .contents = "name = \"c\"" },
            .{ .path = "/other.pkl", .contents = "name = \"other\"" },
        },
    };
    var readers = [_]zig_pkl.ModuleReader{embed.moduleReader()};
    var options = zig_pkl.Options.preconfigured();
    options.allowed_modules = &.{ "repl:", "pkl:", "mem:" };
    options.module_readers = &readers;
    var rejected: ?[]u8 = null;
    defer if (rejected) |text| allocator.free(text);
    const evaluator = try manager.createEvaluator(options, &rejected);
    defer evaluator.close();

    var failure: ?[]u8 = null;
    defer if (failure) |text| allocator.free(text);
    var tree = try evaluator.evaluateSource(zig_pkl.Source.text(
        \\flat = import*("mem:/lib/*.pkl").toMap().values.map((m) -> m.name).sort().join(",")
        \\deep = import*("mem:/lib/**.pkl").keys.toList().sort().join(",")
    ), "List(flat, deep)", &failure);
    defer tree.deinit();
    const items = switch (tree.root.*) {
        .list, .listing => |values| values,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("a,b", items[0].string);
    try std.testing.expectEqualStrings(
        "mem:/lib/a.pkl,mem:/lib/b.pkl,mem:/lib/sub%20dir/c.pkl",
        items[1].string,
    );
}

test "load resolved evaluator settings from PklProject" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const manager = openManager(allocator, io) catch |err| return skipWithoutPkl(err);
    defer manager.deinit();
    // The fixture sets traceMode and an external reader workingDir.
    if (!try serverAtLeast(allocator, io, "0.32.0")) return error.SkipZigTest;
    var rejected: ?[]u8 = null;
    defer if (rejected) |text| allocator.free(text);
    const evaluator = try manager.createEvaluator(zig_pkl.Options.preconfigured(), &rejected);
    defer evaluator.close();

    var project = try zig_pkl.project.loadFile(allocator, io, evaluator, project_path);
    defer project.deinit();
    try std.testing.expectEqual(@as(usize, 0), project.project.dependencies.len);
    try std.testing.expect(hasPathSuffix(project.options.root_dir.?, project_suffix));
    try std.testing.expectEqual(@as(?i64, 2), project.options.timeout_seconds);
    try std.testing.expectEqualStrings("MODE", project.options.env.?[0].key);
    try std.testing.expectEqual(zig_pkl.protocol.TraceMode.pretty, project.options.trace_mode.?);
    try std.testing.expect(hasPathSuffix(project.options.external_module_readers.?[0].executable, reader_suffix));
    try std.testing.expectEqualStrings("http://localhost:8080", project.options.http.?.proxy.?.address.?);
    try std.testing.expectEqualStrings("X-Fixture", project.options.http.?.headers.?[0].headers[0].name);
    try expectPklResolution(evaluator, project);
}

test "relative project paths resolve beside PklProject on every Pkl release" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const manager = openManager(allocator, io) catch |err| return skipWithoutPkl(err);
    defer manager.deinit();
    var rejected: ?[]u8 = null;
    defer if (rejected) |text| allocator.free(text);
    const evaluator = try manager.createEvaluator(zig_pkl.Options.preconfigured(), &rejected);
    defer evaluator.close();

    var project = try zig_pkl.project.loadFile(allocator, io, evaluator, paths_project_path);
    defer project.deinit();
    const module_paths = project.options.module_paths.?;
    try std.testing.expectEqual(@as(usize, 2), module_paths.len);
    try std.testing.expect(hasPathSuffix(module_paths[0], "/tests/fixtures/paths/lib"));
    try std.testing.expect(hasPathSuffix(module_paths[1], "/tests/fixtures/shared/x"));
    try std.testing.expect(hasPathSuffix(project.options.cache_dir.?, "/tests/fixtures/paths/cache"));
    try std.testing.expect(hasPathSuffix(project.options.root_dir.?, "/tests/fixtures"));
    if (try serverAtLeast(allocator, io, "0.32.0")) try expectPklResolution(evaluator, project);
}

test "a project loaded through a symlink evaluates beside its canonical uri" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const manager = openManager(allocator, io) catch |err| return skipWithoutPkl(err);
    defer manager.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var target_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var app_dir = try std.Io.Dir.cwd().openDir(io, "tests/fixtures/dependencies/app", .{});
    const target_len = try app_dir.realPath(io, &target_buffer);
    app_dir.close(io);
    try tmp.dir.symLink(io, target_buffer[0..target_len], "linked app", .{ .is_directory = true });
    const linked = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/linked app/PklProject", .{tmp.sub_path});
    defer allocator.free(linked);

    var rejected: ?[]u8 = null;
    defer if (rejected) |text| allocator.free(text);
    const loader = try manager.createEvaluator(zig_pkl.Options.preconfigured(), &rejected);
    defer loader.close();
    var project = try zig_pkl.project.loadFile(allocator, io, loader, linked);
    defer project.deinit();
    try std.testing.expect(hasPathSuffix(project.projectUri(), "/tests/fixtures/dependencies/app/PklProject"));
    try std.testing.expect(std.mem.indexOf(u8, project.projectUri(), "linked") == null);

    var evaluator_options = project.options;
    evaluator_options.allowed_modules = zig_pkl.Options.preconfigured().allowed_modules;
    evaluator_options.allowed_resources = zig_pkl.Options.preconfigured().allowed_resources;
    const evaluator = try manager.createEvaluator(evaluator_options, &rejected);
    defer evaluator.close();
    const main_uri = try project.moduleUri(allocator, "main.pkl");
    defer allocator.free(main_uri);
    var failure: ?[]u8 = null;
    defer if (failure) |text| allocator.free(text);
    var answer = try evaluator.evaluateSource(zig_pkl.Source.uri(main_uri), "answer", &failure);
    defer answer.deinit();
    try std.testing.expect(answer.root.int.eql(.{ .signed = 42 }));
}

test "import a named local dependency with its own nested dependency" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const manager = openManager(allocator, io) catch |err| return skipWithoutPkl(err);
    defer manager.deinit();
    var rejected: ?[]u8 = null;
    defer if (rejected) |text| allocator.free(text);
    const loader = try manager.createEvaluator(zig_pkl.Options.preconfigured(), &rejected);
    defer loader.close();

    var project = try zig_pkl.project.loadFile(allocator, io, loader, dependency_app_path);
    defer project.deinit();
    const dependencies = project.project.dependencies;
    try std.testing.expectEqual(@as(usize, 1), dependencies.len);
    try std.testing.expectEqualStrings("fixture_dep", dependencies[0].name);
    const local = dependencies[0].dependency.local;
    try std.testing.expectEqualStrings("package://example.com/dep@1.0.0", local.package_uri.?);
    try std.testing.expect(std.mem.endsWith(u8, local.project_file_uri, "/tests/fixtures/dependencies/dep/PklProject"));
    try std.testing.expectEqual(@as(usize, 1), local.dependencies.len);
    try std.testing.expectEqualStrings("inner", local.dependencies[0].name);

    var evaluator_options = project.options;
    evaluator_options.allowed_modules = zig_pkl.Options.preconfigured().allowed_modules;
    evaluator_options.allowed_resources = zig_pkl.Options.preconfigured().allowed_resources;
    const evaluator = try manager.createEvaluator(evaluator_options, &rejected);
    defer evaluator.close();

    const main_uri = try fileUri(allocator, io, dependency_main_path);
    defer allocator.free(main_uri);
    var failure: ?[]u8 = null;
    defer if (failure) |text| allocator.free(text);
    var answer = try evaluator.evaluateSource(zig_pkl.Source.uri(main_uri), "answer", &failure);
    defer answer.deinit();
    try std.testing.expect(answer.root.int.eql(.{ .signed = 42 }));
    var nested = try evaluator.evaluateSource(zig_pkl.Source.uri(main_uri), "nested", &failure);
    defer nested.deinit();
    try std.testing.expectEqualStrings("leaf", nested.root.string);
}
