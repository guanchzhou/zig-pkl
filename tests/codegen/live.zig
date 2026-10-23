//! Code generation tests against a real Pkl server. Every test is skipped when
//! neither `PKL_EXEC` nor `pkl` on `PATH` can be started, unless
//! `ZIG_PKL_REQUIRE_PKL=1`, which turns a missing Pkl into a failure.

const std = @import("std");
const zig_pkl = @import("zig_pkl");
const bindings = @import("fixture_bindings");
const codegen = zig_pkl.codegen;

const fixtures = "tests/codegen/fixtures";
const snapshots = "tests/codegen/snapshots";
const fixture_packages = [_]codegen.PackageMapping{.{ .match = "shared", .package = "deps.shared" }};
const fixture_modules = [_][]const u8{ fixtures ++ "/app.pkl", fixtures ++ "/refs.pkl" };
const snapshot_files = 7;

fn testEnv(name: []const u8) !?[]u8 {
    return std.process.Environ.getAlloc(std.testing.environ, std.testing.allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        else => err,
    };
}

fn pklRequired() !bool {
    const flag = try testEnv("ZIG_PKL_REQUIRE_PKL") orelse return false;
    defer std.testing.allocator.free(flag);
    return std.mem.eql(u8, flag, "1");
}

const toolchain = @import("codegen_test_toolchain");
const verify_bindings = codegen.Verify{ .check = .{
    .toolchain = .{ .zig = toolchain.zig, .library_root = toolchain.library_root, .schema = toolchain.schema },
    .scratch_dir = ".zig-cache/tmp",
} };

const Pkl = struct {
    manager: *zig_pkl.Manager,

    fn open() !Pkl {
        const allocator = std.testing.allocator;
        const configured = std.process.Environ.getAlloc(std.testing.environ, allocator, "PKL_EXEC") catch |err| switch (err) {
            error.EnvironmentVariableMissing => null,
            else => return err,
        };
        defer if (configured) |path| allocator.free(path);
        const path = if (configured) |value| (if (value.len == 0) "pkl" else value) else "pkl";
        const manager = zig_pkl.Manager.init(allocator, std.testing.io, &.{ path, "server" }, zig_pkl.Logger.noop) catch |err| switch (err) {
            error.FileNotFound => {
                if (try pklRequired()) {
                    std.debug.print("ZIG_PKL_REQUIRE_PKL=1 but `{s}` cannot be started\n", .{path});
                    return error.PklRequired;
                }
                return error.SkipZigTest;
            },
            else => return err,
        };
        return .{ .manager = manager };
    }

    fn close(self: Pkl) void {
        self.manager.deinit();
    }

    fn options(_: Pkl, base: codegen.Options) codegen.Options {
        var result = base;
        result.verify = verify_bindings;
        return result;
    }

    fn generate(self: Pkl, base: codegen.Options, diagnostics: *codegen.Diagnostics) !codegen.Report {
        return codegen.generate(std.testing.allocator, std.testing.io, self.manager, self.options(base), diagnostics) catch |err| {
            if (err == error.CodegenFailed) {
                var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
                defer buffer.deinit();
                try diagnostics.write(&buffer.writer);
                std.debug.print("{s}", .{buffer.written()});
            }
            return err;
        };
    }
};

fn fixtureOptions(output_dir: []const u8, check: bool) codegen.Options {
    return .{
        .modules = &fixture_modules,
        .output_dir = output_dir,
        .project_dir = fixtures,
        .packages = &fixture_packages,
        .check = check,
        .verify = .skip,
    };
}

fn readFile(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(codegen.output.max_file_bytes));
}

fn expectDiagnosticText(diagnostics: codegen.Diagnostics, needle: []const u8) !void {
    if (diagnostics.contains(needle)) return;
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    try diagnostics.write(&buffer.writer);
    std.debug.print("expected a diagnostic containing `{s}`, got:\n{s}", .{ needle, buffer.written() });
    return error.TestExpectedDiagnostic;
}

const Scratch = struct {
    tmp: std.testing.TmpDir,
    path: []u8,

    fn init(name: []const u8) !Scratch {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
        return .{ .tmp = tmp, .path = path };
    }

    fn deinit(self: *Scratch) void {
        std.testing.allocator.free(self.path);
        self.tmp.cleanup();
    }
};

fn expectFailure(pkl: Pkl, module: []const u8, needle: []const u8) !void {
    var scratch = try Scratch.init("out");
    defer scratch.deinit();
    var diagnostics = codegen.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    const result = codegen.generate(std.testing.allocator, std.testing.io, pkl.manager, pkl.options(.{
        .modules = &.{module},
        .output_dir = scratch.path,
        .project_dir = fixtures,
        .verify = .skip,
    }), &diagnostics);
    try std.testing.expectError(error.CodegenFailed, result);
    try expectDiagnosticText(diagnostics, needle);
    try std.testing.expectError(error.FileNotFound, scratch.tmp.dir.statFile(std.testing.io, "out", .{}));
}

test "fixture bindings match the checked-in snapshots" {
    const pkl = try Pkl.open();
    defer pkl.close();
    var diagnostics = codegen.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    const report = try pkl.generate(fixtureOptions(snapshots, true), &diagnostics);
    if (report.outdated != 0) {
        std.debug.print("{d} snapshot file(s) are stale; run `zig build codegen`\n", .{report.outdated});
        return error.TestStaleSnapshots;
    }
    try std.testing.expectEqual(@as(usize, snapshot_files), report.unchanged);
    try std.testing.expect(!diagnostics.hasErrors());
}

test "reversing the module order reproduces the snapshots" {
    const pkl = try Pkl.open();
    defer pkl.close();
    var diagnostics = codegen.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    var options = fixtureOptions(snapshots, true);
    options.modules = &.{ fixtures ++ "/refs.pkl", fixtures ++ "/app.pkl" };
    const report = try pkl.generate(options, &diagnostics);
    try std.testing.expectEqual(codegen.Report{ .unchanged = snapshot_files }, report);
}

test "example bindings are up to date" {
    const pkl = try Pkl.open();
    defer pkl.close();
    var diagnostics = codegen.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    const report = try pkl.generate(.{
        .modules = &.{"examples/codegen/pkl/Service.pkl"},
        .output_dir = "examples/codegen/src/bindings",
        .project_dir = "examples/codegen",
        .check = true,
        .verify = .skip,
    }, &diagnostics);
    if (report.outdated != 0) {
        std.debug.print("{d} example binding file(s) are stale; run `zig build codegen`\n", .{report.outdated});
        return error.TestStaleSnapshots;
    }
}

test "generation is deterministic and regeneration is incremental" {
    const pkl = try Pkl.open();
    defer pkl.close();
    const io = std.testing.io;
    var scratch = try Scratch.init("out");
    defer scratch.deinit();
    var diagnostics = codegen.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();

    try std.testing.expectEqual(codegen.Report{ .written = snapshot_files }, try pkl.generate(fixtureOptions(scratch.path, false), &diagnostics));
    try std.testing.expectEqual(codegen.Report{ .unchanged = snapshot_files }, try pkl.generate(fixtureOptions(scratch.path, false), &diagnostics));

    try scratch.tmp.dir.writeFile(io, .{ .sub_path = "out/handwritten.zig", .data = "//! Bindings for something written by hand.\n" });
    var only_app = fixtureOptions(scratch.path, false);
    only_app.modules = &.{fixtures ++ "/app.pkl"};
    var only_app_check = only_app;
    only_app_check.check = true;
    try std.testing.expectEqual(codegen.Report{ .unchanged = snapshot_files - 2, .outdated = 3 }, try pkl.generate(only_app_check, &diagnostics));
    try std.testing.expectEqual(codegen.Report{ .written = 1, .unchanged = snapshot_files - 2, .removed = 1 }, try pkl.generate(only_app, &diagnostics));
    try std.testing.expectError(error.FileNotFound, scratch.tmp.dir.statFile(io, "out/fixture/refs.zig", .{}));
    _ = try scratch.tmp.dir.statFile(io, "out/handwritten.zig", .{});

    const generated = try scratch.tmp.dir.readFileAlloc(io, "out/fixture/app.zig", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(generated);
    const snapshot = try readFile(snapshots ++ "/fixture/app.zig");
    defer std.testing.allocator.free(snapshot);
    try std.testing.expectEqualStrings(snapshot, generated);
}

test "hand-edited and handwritten files block generation until forced" {
    const pkl = try Pkl.open();
    defer pkl.close();
    const io = std.testing.io;
    var scratch = try Scratch.init("out");
    defer scratch.deinit();
    var diagnostics = codegen.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();

    try scratch.tmp.dir.createDirPath(io, "out/fixture");
    try scratch.tmp.dir.writeFile(io, .{ .sub_path = "out/fixture/refs.zig", .data = "pub const mine = true;\n" });
    try std.testing.expectError(error.CodegenFailed, codegen.generate(std.testing.allocator, io, pkl.manager, pkl.options(fixtureOptions(scratch.path, false)), &diagnostics));
    try expectDiagnosticText(diagnostics, "was not written by the generator");
    try std.testing.expectEqualStrings("fixture/refs.zig", diagnostics.items.items[diagnostics.items.items.len - 1].location.?);
    try std.testing.expectError(error.FileNotFound, scratch.tmp.dir.statFile(io, "out/fixture/app.zig", .{}));
    const kept = try scratch.tmp.dir.readFileAlloc(io, "out/fixture/refs.zig", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(kept);
    try std.testing.expectEqualStrings("pub const mine = true;\n", kept);

    var forced = fixtureOptions(scratch.path, false);
    forced.force = true;
    try std.testing.expectEqual(codegen.Report{ .written = snapshot_files }, try pkl.generate(forced, &diagnostics));

    try scratch.tmp.dir.writeFile(io, .{ .sub_path = "out/fixture/app.zig", .data = "edited by hand\n" });
    diagnostics.deinit();
    diagnostics = codegen.Diagnostics.init(std.testing.allocator);
    var check = fixtureOptions(scratch.path, true);
    try std.testing.expectError(error.CodegenFailed, codegen.generate(std.testing.allocator, io, pkl.manager, pkl.options(check), &diagnostics));
    try expectDiagnosticText(diagnostics, "or was edited since");
    check.check = false;
    try std.testing.expectError(error.CodegenFailed, codegen.generate(std.testing.allocator, io, pkl.manager, pkl.options(check), &diagnostics));
    const edited = try scratch.tmp.dir.readFileAlloc(io, "out/fixture/app.zig", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(edited);
    try std.testing.expectEqualStrings("edited by hand\n", edited);
}

test "a nested index file keeps every module beside it" {
    const pkl = try Pkl.open();
    defer pkl.close();
    const io = std.testing.io;
    var scratch = try Scratch.init("out");
    defer scratch.deinit();
    var diagnostics = codegen.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    var options = fixtureOptions(scratch.path, false);
    options.index_file = "gen/bindings.zig";
    _ = try pkl.generate(options, &diagnostics);
    _ = try scratch.tmp.dir.statFile(io, "out/gen/fixture/app.zig", .{});
    const index = try scratch.tmp.dir.readFileAlloc(io, "out/gen/bindings.zig", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(index);
    try std.testing.expect(std.mem.indexOf(u8, index, "@import(\"fixture/app.zig\")") != null);

    for ([_][]const u8{ "../escape.zig", "/tmp/escape.zig", "index.txt" }) |index_file| {
        var rejected = codegen.Diagnostics.init(std.testing.allocator);
        defer rejected.deinit();
        options.index_file = index_file;
        try std.testing.expectError(error.CodegenFailed, codegen.generate(std.testing.allocator, io, pkl.manager, pkl.options(options), &rejected));
        try expectDiagnosticText(rejected, "is not a normalized relative `.zig` path");
    }
}

test "defaults that read resources are not copied into the bindings" {
    const pkl = try Pkl.open();
    defer pkl.close();
    const io = std.testing.io;
    var scratch = try Scratch.init("out");
    defer scratch.deinit();
    var diagnostics = codegen.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    const options = codegen.Options{
        .modules = &.{fixtures ++ "/leak.pkl"},
        .output_dir = scratch.path,
        .verify = .skip,
    };
    _ = try pkl.generate(options, &diagnostics);
    try expectDiagnosticText(diagnostics, "default value of `token` could not be evaluated");
    try expectDiagnosticText(diagnostics, "default value of `home` could not be evaluated");
    const text = try scratch.tmp.dir.readFileAlloc(io, "out/fixture/leak.zig", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "zig-pkl-leak-canary") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "token: []const u8,") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "home: []const u8,") != null);
    try expectDiagnosticText(diagnostics, "default value of `property` could not be evaluated");
    try std.testing.expect(std.mem.indexOf(u8, text, "property: ?[]const u8,") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "safe: []const u8 = \"public\",") != null);
    if (try testEnv("HOME")) |home| {
        defer std.testing.allocator.free(home);
        try std.testing.expect(std.mem.indexOf(u8, text, home) == null);
    }

    var allowed = options;
    allowed.allowed_resources = &.{"file:"};
    allowed.force = true;
    _ = try pkl.generate(allowed, &diagnostics);
    const opened = try scratch.tmp.dir.readFileAlloc(io, "out/fixture/leak.zig", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(opened);
    try std.testing.expect(std.mem.indexOf(u8, opened, "token: []const u8 = \"zig-pkl-leak-canary-7f3a\\n\",") != null);
}

test "an untyped override of a hidden property is omitted" {
    const pkl = try Pkl.open();
    defer pkl.close();
    const io = std.testing.io;
    var scratch = try Scratch.init("out");
    defer scratch.deinit();
    var diagnostics = codegen.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    _ = try pkl.generate(.{
        .modules = &.{fixtures ++ "/hidden.pkl"},
        .output_dir = scratch.path,
        .verify = .skip,
    }, &diagnostics);
    try std.testing.expect(!diagnostics.hasErrors());
    const text = try scratch.tmp.dir.readFileAlloc(io, "out/fixture/concealed.zig", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "name: []const u8 = \"n\",") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "pub const Child = struct {") != null);
}

test "pkl:platform defaults are not copied into the bindings" {
    const pkl = try Pkl.open();
    defer pkl.close();
    const io = std.testing.io;
    var scratch = try Scratch.init("out");
    defer scratch.deinit();
    var diagnostics = codegen.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    _ = try pkl.generate(.{
        .modules = &.{fixtures ++ "/platform.pkl"},
        .output_dir = scratch.path,
        .verify = .skip,
    }, &diagnostics);
    try expectDiagnosticText(diagnostics, "default value of `os` could not be evaluated");
    try expectDiagnosticText(diagnostics, "default value of `hostOs` could not be evaluated");
    try expectDiagnosticText(diagnostics, "default value of `arch` could not be evaluated");
    const text = try scratch.tmp.dir.readFileAlloc(io, "out/fixture/platform.zig", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "macOS") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "aarch64") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "os: []const u8,") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "host_os: []const u8,") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "arch: []const u8,") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "label: []const u8 = \"stable\",") != null);
}

test "platform defaults stay out of amended modules, other modules, and locals" {
    const pkl = try Pkl.open();
    defer pkl.close();
    const io = std.testing.io;
    var scratch = try Scratch.init("out");
    defer scratch.deinit();
    var diagnostics = codegen.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    _ = try pkl.generate(.{
        .modules = &.{
            fixtures ++ "/host/amend.pkl",
            fixtures ++ "/host/use.pkl",
            fixtures ++ "/host/local.pkl",
        },
        .output_dir = scratch.path,
        .verify = .skip,
    }, &diagnostics);
    try std.testing.expect(!diagnostics.hasErrors());
    try expectDiagnosticText(diagnostics, "default value of `os` could not be evaluated");
    try expectDiagnosticText(diagnostics, "default value of `viaOther` could not be evaluated");
    const files = [_][]const u8{
        "out/fixture/hostbase.zig",
        "out/fixture/hosttypes.zig",
        "out/fixture/hostlocal.zig",
    };
    for (files) |path| {
        const text = try scratch.tmp.dir.readFileAlloc(io, path, std.testing.allocator, .unlimited);
        defer std.testing.allocator.free(text);
        for ([_][]const u8{ "macOS", "Linux", "Windows", "aarch64", "x86_64" }) |host| {
            try std.testing.expect(std.mem.indexOf(u8, text, host) == null);
        }
        try std.testing.expect(std.mem.indexOf(u8, text, "label: []const u8 = \"stable\",") != null);
    }
    const base = try scratch.tmp.dir.readFileAlloc(io, "out/fixture/hostbase.zig", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(base);
    try std.testing.expect(std.mem.indexOf(u8, base, "os: []const u8,") != null);
    const local = try scratch.tmp.dir.readFileAlloc(io, "out/fixture/hostlocal.zig", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(local);
    try std.testing.expect(std.mem.indexOf(u8, local, "os: []const u8,") != null);
    try std.testing.expect(std.mem.indexOf(u8, local, "via_other: []const u8,") != null);
}

test "platform defaults stay out of local dependencies and escaped imports" {
    const pkl = try Pkl.open();
    defer pkl.close();
    const io = std.testing.io;
    var scratch = try Scratch.init("out");
    defer scratch.deinit();
    var diagnostics = codegen.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    _ = try pkl.generate(.{
        .modules = &.{ fixtures ++ "/host/dep.pkl", fixtures ++ "/host/escaped.pkl" },
        .output_dir = scratch.path,
        .project_dir = fixtures,
        .verify = .skip,
    }, &diagnostics);
    try std.testing.expect(!diagnostics.hasErrors());
    try expectDiagnosticText(diagnostics, "default value of `arch` could not be evaluated");
    const cases = [_]struct { path: []const u8, literal: []const u8 }{
        .{ .path = "out/shared/host.zig", .literal = "label: []const u8 = \"dependency\"," },
        .{ .path = "out/fixture/hostescaped.zig", .literal = "label: []const u8 = \"stable\"," },
    };
    for (cases) |case| {
        const text = try scratch.tmp.dir.readFileAlloc(io, case.path, std.testing.allocator, .unlimited);
        defer std.testing.allocator.free(text);
        try std.testing.expect(std.mem.indexOf(u8, text, "arch: []const u8,") != null);
        for ([_][]const u8{ "aarch64", "x86_64", "arm64", "amd64", "macOS", "Linux", "Windows" }) |host| {
            try std.testing.expect(std.mem.indexOf(u8, text, host) == null);
        }
        try std.testing.expect(std.mem.indexOf(u8, text, case.literal) != null);
    }
    const escaped = try scratch.tmp.dir.readFileAlloc(io, "out/fixture/hostescaped.zig", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(escaped);
    try std.testing.expect(std.mem.indexOf(u8, escaped, "via_local: []const u8,") != null);
    try std.testing.expect(std.mem.indexOf(u8, escaped, "split: []const u8,") != null);
}

test "URI package mappings place dependency modules" {
    const pkl = try Pkl.open();
    defer pkl.close();
    const io = std.testing.io;
    var scratch = try Scratch.init("out");
    defer scratch.deinit();
    var diagnostics = codegen.Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    var options = fixtureOptions(scratch.path, false);
    options.packages = &.{
        .{ .match = "projectpackage://example.com/shared@1.0.0#/", .package = "vendor.shared" },
        .{ .match = "fixture.graph", .package = "cycles" },
    };
    options.index_file = "bindings.zig";
    _ = try pkl.generate(options, &diagnostics);
    _ = try scratch.tmp.dir.statFile(io, "out/vendor/shared/units.zig", .{});
    _ = try scratch.tmp.dir.statFile(io, "out/cycles/a.zig", .{});
    _ = try scratch.tmp.dir.statFile(io, "out/bindings.zig", .{});
    const app = try scratch.tmp.dir.readFileAlloc(io, "out/fixture/app.zig", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(app);
    try std.testing.expect(std.mem.indexOf(u8, app, "@import(\"../vendor/shared/units.zig\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, app, "@import(\"../cycles/a.zig\")") != null);
}

test "invalid modules are reported without writing output" {
    const pkl = try Pkl.open();
    defer pkl.close();
    try expectFailure(pkl, fixtures ++ "/invalid/collision.pkl", "properties `fooBar` and `foo_bar` both map to field `foo_bar`");
    try expectFailure(pkl, fixtures ++ "/invalid/unsupported.pkl", "function types cannot be represented");
    try expectFailure(pkl, fixtures ++ "/invalid/ambiguous.pkl", "decode to the same Zig type");
    try expectFailure(pkl, fixtures ++ "/invalid/declaration_clash.pkl", "field `server` collides with a declaration");
    try expectFailure(pkl, fixtures ++ "/invalid/bad_name.pkl", "Type constraint");
    try expectFailure(pkl, fixtures ++ "/invalid/missing.pkl", "cannot open module");
    try expectFailure(pkl, fixtures ++ "/invalid/untyped.pkl", "the type of this property is not declared");
    try expectFailure(pkl, fixtures ++ "/invalid/foreign.pkl", "not the zig-pkl annotations package");
    try expectFailure(pkl, fixtures ++ "/invalid/module_name.pkl", "`@zig.Name` cannot rename a module");
}

test "generated loaders decode an evaluated configuration" {
    const pkl = try Pkl.open();
    defer pkl.close();
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var rejected: ?[]u8 = null;
    defer if (rejected) |text| pkl.manager.allocator.free(text);
    const loader = try pkl.manager.createEvaluator(zig_pkl.Options.preconfigured(), &rejected);
    defer loader.close();
    var project = try zig_pkl.project.loadFile(allocator, io, loader, fixtures ++ "/PklProject");
    defer project.deinit();
    var evaluator_options = project.options;
    evaluator_options.allowed_modules = zig_pkl.Options.preconfigured().allowed_modules;
    evaluator_options.allowed_resources = zig_pkl.Options.preconfigured().allowed_resources;
    const evaluator = try pkl.manager.createEvaluator(evaluator_options, &rejected);
    defer evaluator.close();

    const config_uri = try codegen.generator.moduleUri(allocator, io, fixtures ++ "/config.pkl");
    defer allocator.free(config_uri);
    var failure: ?[]u8 = null;
    defer if (failure) |text| pkl.manager.allocator.free(text);
    const App = bindings.fixture.app;
    var app = App.load(allocator, evaluator, .uri(config_uri), &failure) catch |err| {
        if (failure) |text| std.debug.print("{s}\n", .{text});
        return err;
    };
    defer app.deinit(allocator);

    try std.testing.expectEqualStrings("service", app.name);
    try std.testing.expectEqual(@as(u16, 8080), app.port);
    try std.testing.expectEqual(@as(i8, -3), app.retries);
    try std.testing.expectEqual(@as(i64, 9007199254740993), app.big);
    try std.testing.expectEqualStrings("svc", app.nickname.?);
    try std.testing.expectEqual(@as(usize, 2), app.tags.len);
    try std.testing.expectEqualSlices(i64, &.{ 1, 2, 3 }, app.ids);
    try std.testing.expectEqual(@as(usize, 2), app.unique.len);
    try std.testing.expectEqualStrings("core", app.labels.get("team").?);
    try std.testing.expectEqual(@as(f64, 0.5), app.weights.get("cpu").?);
    try std.testing.expectEqual(@as(i64, 10), app.limits.first);
    try std.testing.expectEqualStrings("requests", app.limits.second);
    try std.testing.expectEqual(@as(f64, 30), app.timeout.value);
    try std.testing.expectEqualStrings("s", app.timeout.unit);
    try std.testing.expectEqualStrings("mb", app.memory.unit);
    try std.testing.expectEqualStrings("\\d+", app.pattern.pattern);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 255 }, app.payload.data);
    try std.testing.expectEqual(zig_pkl.convert.IntSeq{ .start = 0, .end = 10, .step = 5 }, app.range);
    try std.testing.expectEqual(App.Mode.slow_start, app.mode);
    try std.testing.expectEqual(@as(f64, 2.0), app.value.shape.circle.radius);
    try std.testing.expectEqual(true, app.choice.?.boolean);
    try std.testing.expectEqual(@as(f64, 3.0), app.shapes[0].square.side);
    try std.testing.expectEqualStrings("box", app.shapes[0].square.label.?);
    try std.testing.expectEqual(@as(f64, 1.0), app.shapes[1].circle.radius);
    try std.testing.expectEqual(@as(i64, 2), app.tree.children[0].value);
    try std.testing.expectEqual(@as(i64, 3), app.tree.left.?.value);
    try std.testing.expect(app.tree.left.?.left == null);
    try std.testing.expectEqual(@as(f64, 9.5), app.price.amount);
    try std.testing.expectEqual(bindings.deps.shared.units.MoneyCurrency.eur, app.price.currency);
    try std.testing.expectEqualStrings("a", app.graph.name);
    try std.testing.expectEqualStrings("b", app.graph.peer.?.name);
    try std.testing.expect(app.graph.peer.?.peer == null);
    try std.testing.expectEqual(true, app.nested.get("pairs").?[0].second);
    try std.testing.expectEqual(@as(i64, 1), app.named.get("one").?);
    try std.testing.expectEqualStrings("127.0.0.1", app.listen_address);
    try std.testing.expectEqualStrings("verbatim", app.raw);
    try std.testing.expectEqualStrings("example.com", app.server.?.host);
    try std.testing.expectEqual(@as(u16, 8443), app.server.?.listen_port);
    try std.testing.expectEqualStrings("secure.example.com", app.tls.host);
    try std.testing.expectEqual(@as(u16, 8443), app.tls.listen_port);
    try std.testing.expectEqual(@as(u16, 8443), (App.TlsServer{ .host = "", .certificate = "" }).listen_port);
    try std.testing.expectEqual(@as(i64, 1), app.chain.id);
    try std.testing.expectEqual(@as(i64, 2), app.chain.next.?.id);
    try std.testing.expect(app.chain.next.?.next == null);
    try std.testing.expectEqualStrings("https://api.example.com", app.endpoint.url);
    try std.testing.expectEqual(@as(i64, 1), app.endpoint.weight);
    try std.testing.expectEqual(@as(i64, 1), app.floats_first[0].int);
    try std.testing.expectEqual(@as(f64, 1.5), app.floats_first[1].float);
    try std.testing.expectEqual(@as(i64, 1), app.ints_first[0].int);
    try std.testing.expectEqual(@as(f64, 1.5), app.ints_first[1].float);
}

test "generated references decode a typed domain and access path" {
    const pkl = try Pkl.open();
    defer pkl.close();
    const allocator = std.testing.allocator;
    var rejected: ?[]u8 = null;
    defer if (rejected) |text| pkl.manager.allocator.free(text);
    const evaluator = try pkl.manager.createEvaluator(zig_pkl.Options.preconfigured(), &rejected);
    defer evaluator.close();
    const refs_uri = try codegen.generator.moduleUri(allocator, std.testing.io, fixtures ++ "/refs.pkl");
    defer allocator.free(refs_uri);
    var failure: ?[]u8 = null;
    defer if (failure) |text| pkl.manager.allocator.free(text);
    var refs = bindings.fixture.refs.load(allocator, evaluator, .uri(refs_uri), &failure) catch |err| {
        if (failure) |text| std.debug.print("{s}\n", .{text});
        return err;
    };
    defer refs.deinit(allocator);

    try std.testing.expectEqualStrings("ci", refs.step.domain.name);
    try std.testing.expectEqualStrings("build", refs.step.data().string);
    try std.testing.expectEqual(@as(usize, 0), refs.step.path.len);
    try std.testing.expectEqual(@as(usize, 1), refs.run.path.len);
    try std.testing.expectEqualStrings("run", refs.run.path[0].property.?);
    try std.testing.expectEqual(@as(usize, 2), refs.tag.path.len);
    try std.testing.expectEqualStrings("tags", refs.tag.path[0].property.?);
    try std.testing.expect(refs.tag.path[1].is_subscript);
    const key = refs.tag.path[1].key.?.int;
    try std.testing.expect(key.eql(@TypeOf(key).fromSigned(1)));
    try std.testing.expectEqual(@as(usize, 2), refs.path.len);
    try std.testing.expect(refs.path[1].access.is_subscript);
    try std.testing.expect(@TypeOf(refs.step).Referent == bindings.fixture.refs.Step);
}

test "decoding fails cleanly when a value does not match the bindings" {
    const pkl = try Pkl.open();
    defer pkl.close();
    var rejected: ?[]u8 = null;
    defer if (rejected) |text| pkl.manager.allocator.free(text);
    const evaluator = try pkl.manager.createEvaluator(zig_pkl.Options.preconfigured(), &rejected);
    defer evaluator.close();
    var failure: ?[]u8 = null;
    defer if (failure) |text| pkl.manager.allocator.free(text);
    const Node = bindings.fixture.graph.a;
    try std.testing.expectError(
        error.TypeMismatch,
        Node.load(std.testing.allocator, evaluator, .text("name = 42\npeer = null"), &failure),
    );
}
