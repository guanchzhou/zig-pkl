const std = @import("std");
const schema = @import("schema.zig");
const plan = @import("plan.zig");
const verify = @import("verify.zig");
const Diagnostics = @import("diagnostics.zig").Diagnostics;

const TypeInfo = schema.TypeInfo;

fn base(comptime name: []const u8) TypeInfo {
    return .{ .kind = .class, .module_uri = "pkl:base", .name = name, .args = &.{} };
}

fn baseOf(comptime name: []const u8, comptime args: []const TypeInfo) TypeInfo {
    return .{ .kind = .class, .module_uri = "pkl:base", .name = name, .args = args };
}

fn baseAlias(comptime name: []const u8) TypeInfo {
    return .{ .kind = .alias, .module_uri = "pkl:base", .name = name, .args = &.{} };
}

fn class(comptime uri: []const u8, comptime name: []const u8) TypeInfo {
    return .{ .kind = .class, .module_uri = uri, .name = name, .args = &.{} };
}

fn alias(comptime uri: []const u8, comptime name: []const u8, comptime args: []const TypeInfo) TypeInfo {
    return .{ .kind = .alias, .module_uri = uri, .name = name, .args = args };
}

fn moduleType(comptime uri: []const u8) TypeInfo {
    return .{ .kind = .module_class, .module_uri = uri, .name = null, .args = &.{} };
}

fn literal(comptime text: []const u8) TypeInfo {
    return .{ .kind = .literal, .module_uri = null, .name = text, .args = &.{} };
}

fn unionOf(comptime members: []const TypeInfo) TypeInfo {
    return .{ .kind = .@"union", .module_uri = null, .name = null, .args = members };
}

fn nullable(comptime inner: TypeInfo) TypeInfo {
    return .{ .kind = .nullable, .module_uri = null, .name = null, .args = &.{inner} };
}

fn simple(comptime kind: TypeInfo.Kind) TypeInfo {
    return .{ .kind = kind, .module_uri = null, .name = null, .args = &.{} };
}

fn variable(comptime name: []const u8) TypeInfo {
    return .{ .kind = .variable, .module_uri = null, .name = name, .args = &.{} };
}

fn scalar(comptime kind: schema.DefaultInfo.Kind, comptime text: []const u8) schema.DefaultInfo {
    return .{ .kind = kind, .text = text, .unit = null, .items = &.{} };
}

fn quantity(comptime kind: schema.DefaultInfo.Kind, comptime text: []const u8, comptime unit: []const u8) schema.DefaultInfo {
    return .{ .kind = kind, .text = text, .unit = unit, .items = &.{} };
}

fn items(comptime kind: schema.DefaultInfo.Kind, comptime list: []const schema.DefaultInfo) schema.DefaultInfo {
    return .{ .kind = kind, .text = "", .unit = null, .items = list };
}

const Prop = struct {
    zig_name: ?[]const u8 = null,
    doc: ?[]const u8 = null,
    boxed: bool = false,
    zig_type: ?[]const u8 = null,
    default: ?schema.DefaultInfo = null,
};

fn prop(comptime name: []const u8, comptime info: TypeInfo, comptime extra: Prop) schema.PropertyInfo {
    return .{
        .name = name,
        .zig_name = extra.zig_name,
        .location = "file:///m.pkl:1:" ++ name,
        .doc = extra.doc,
        .type = info,
        .boxed = extra.boxed,
        .zig_type = extra.zig_type,
        .default = extra.default,
    };
}

const ClassOpts = struct {
    zig_name: ?[]const u8 = null,
    doc: ?[]const u8 = null,
    is_abstract: bool = false,
    is_open: bool = false,
    superclass: ?schema.ClassRef = null,
};

fn classInfo(comptime name: []const u8, comptime properties: []const schema.PropertyInfo, comptime extra: ClassOpts) schema.ClassInfo {
    return .{
        .name = name,
        .zig_name = extra.zig_name,
        .location = "file:///m.pkl:class:" ++ name,
        .doc = extra.doc,
        .is_abstract = extra.is_abstract,
        .is_open = extra.is_open,
        .superclass = extra.superclass,
        .properties = properties,
    };
}

fn aliasInfo(comptime name: []const u8, comptime params: []const []const u8, comptime referent: TypeInfo) schema.AliasInfo {
    return .{ .name = name, .zig_name = null, .location = "file:///m.pkl:alias:" ++ name, .doc = null, .params = params, .referent = referent };
}

const ModuleOpts = struct {
    package_name: ?[]const u8 = null,
    doc: ?[]const u8 = null,
    classes: []const schema.ClassInfo = &.{},
    aliases: []const schema.AliasInfo = &.{},
    superclass: ?schema.ClassRef = null,
    zig_name: ?[]const u8 = null,
    foreign_annotations: []const schema.ForeignAnnotation = &.{},
};

fn module(comptime uri: []const u8, comptime name: []const u8, comptime properties: []const schema.PropertyInfo, comptime extra: ModuleOpts) schema.ModuleInfo {
    return .{
        .uri = uri,
        .name = name,
        .package_name = extra.package_name,
        .zig_name = extra.zig_name,
        .location = uri ++ ":1:1",
        .doc = extra.doc,
        .module_class = classInfo("ModuleClass", properties, .{ .superclass = extra.superclass }),
        .classes = extra.classes,
        .aliases = extra.aliases,
        .foreign_annotations = extra.foreign_annotations,
    };
}

const Planned = struct {
    output: ?plan.Output,
    diagnostics: Diagnostics,
    index_file: []const u8,

    fn deinit(self: *Planned) void {
        if (self.output) |*output| output.deinit();
        self.diagnostics.deinit();
    }

    fn file(self: Planned, path: []const u8) []const u8 {
        for (self.output.?.files) |item| {
            if (std.mem.eql(u8, item.path, path)) return item.contents;
        }
        std.debug.panic("no file {s}", .{path});
    }
};

fn run(modules: []const schema.ModuleInfo, options: plan.Options) !Planned {
    var diagnostics = Diagnostics.init(std.testing.allocator);
    errdefer diagnostics.deinit();
    const description = schema.Description{ .roots = &.{modules[0].uri}, .modules = modules };
    const output = plan.plan(std.testing.allocator, description, options, &diagnostics) catch |err| switch (err) {
        error.InvalidSchema => return .{ .output = null, .diagnostics = diagnostics, .index_file = options.index_file },
        else => return err,
    };
    return .{ .output = output, .diagnostics = diagnostics, .index_file = options.index_file };
}

fn runReversed(modules: []const schema.ModuleInfo, options: plan.Options) !Planned {
    var reversed: [8]schema.ModuleInfo = undefined;
    for (modules, 0..) |item, index| reversed[modules.len - 1 - index] = item;
    return run(reversed[0..modules.len], options);
}

/// Type-checks the planned files with the toolchain that `zig build`
/// provides through the `codegen_test_toolchain` options module.
fn expectCompiles(planned: Planned) !void {
    var diagnostics = Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    typeCheck(planned, &diagnostics) catch |err| {
        for (diagnostics.items.items) |item| std.debug.print("{s}\n", .{item.message});
        return err;
    };
}

fn typeCheck(planned: Planned, diagnostics: *Diagnostics) !void {
    const toolchain = @import("codegen_test_toolchain");
    try verify.check(std.testing.allocator, std.testing.io, .{
        .toolchain = .{ .zig = toolchain.zig, .library_root = toolchain.library_root, .schema = toolchain.schema },
        .scratch_dir = ".zig-cache/tmp",
    }, planned.output.?.files, planned.index_file, diagnostics);
}

fn expectSameFiles(left: Planned, right: Planned) !void {
    try std.testing.expectEqual(left.output.?.files.len, right.output.?.files.len);
    for (left.output.?.files, right.output.?.files) |a, b| {
        try std.testing.expectEqualStrings(a.path, b.path);
        try std.testing.expectEqualStrings(a.contents, b.contents);
    }
}

fn expectWarning(planned: Planned, needle: []const u8) !void {
    for (planned.diagnostics.items.items) |item| {
        if (item.severity == .warning and std.mem.indexOf(u8, item.message, needle) != null) return;
    }
    for (planned.diagnostics.items.items) |item| std.debug.print("diagnostic: {s}\n", .{item.message});
    return error.TestExpectedWarning;
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected to find:\n{s}\nin:\n{s}\n", .{ needle, haystack });
        return error.TestExpectedContains;
    }
}

fn expectDiagnostic(planned: Planned, needle: []const u8) !void {
    try std.testing.expect(planned.output == null);
    if (!planned.diagnostics.contains(needle)) {
        for (planned.diagnostics.items.items) |item| std.debug.print("diagnostic: {s}\n", .{item.message});
        return error.TestExpectedDiagnostic;
    }
}

const app = "file:///app.pkl";

test "a small module renders exactly" {
    const modules = [_]schema.ModuleInfo{
        module(app, "app.config", &.{
            prop("hostName", base("String"), .{ .doc = "Where to listen.", .default = scalar(.string, "localhost") }),
            prop("port", baseAlias("UInt16"), .{ .default = scalar(.int, "8080") }),
            prop("origin", nullable(class(app, "Point")), .{}),
        }, .{
            .package_name = "app.config",
            .doc = "Application settings.",
            .classes = &.{classInfo("Point", &.{
                prop("x", base("Int"), .{}),
                prop("y", base("Float"), .{ .zig_name = "why", .default = scalar(.float, "1.5") }),
            }, .{})},
        }),
    };
    var planned = try run(&modules, .{});
    defer planned.deinit();
    try std.testing.expectEqual(@as(usize, 2), planned.output.?.files.len);
    try std.testing.expectEqualStrings("app/config.zig", planned.output.?.files[0].path);
    try std.testing.expectEqualStrings(
        \\//! Bindings for the Pkl module `app.config`. Regenerate this file instead of editing it.
        \\//!
        \\//! Application settings.
        \\
        \\const std = @import("std");
        \\const zig_pkl = @import("zig_pkl");
        \\
        \\/// Where to listen.
        \\host_name: []const u8 = "localhost",
        \\port: u16 = 8080,
        \\origin: ?Point = null,
        \\
        \\pub const pkl_class = "app.config";
        \\pub const pkl_names = .{ .host_name = "hostName" };
        \\
        \\pub fn decode(allocator: std.mem.Allocator, root: *const zig_pkl.Value) zig_pkl.convert.Error!@This() {
        \\    return zig_pkl.convert.into(@This(), allocator, root);
        \\}
        \\
        \\pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        \\    zig_pkl.convert.freeInto(@This(), allocator, self.*);
        \\    self.* = undefined;
        \\}
        \\
        \\/// Evaluates `source` and decodes the module. On `error.EvaluationFailed`,
        \\/// `failure` owns the Pkl error message, allocated with the manager allocator.
        \\/// Release the result with `deinit`.
        \\pub fn load(allocator: std.mem.Allocator, evaluator: *zig_pkl.Evaluator, source: zig_pkl.Source, failure: *?[]u8) !@This() {
        \\    var tree = try evaluator.evaluateSource(source, null, failure);
        \\    defer tree.deinit();
        \\    return decode(allocator, tree.root);
        \\}
        \\
        \\pub const Point = struct {
        \\    x: i64,
        \\    why: f64 = 1.5,
        \\
        \\    pub const pkl_class = "app.config#Point";
        \\    pub const pkl_names = .{ .why = "y" };
        \\
        \\    pub fn decode(allocator: std.mem.Allocator, root: *const zig_pkl.Value) zig_pkl.convert.Error!@This() {
        \\        return zig_pkl.convert.into(@This(), allocator, root);
        \\    }
        \\
        \\    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        \\        zig_pkl.convert.freeInto(@This(), allocator, self.*);
        \\        self.* = undefined;
        \\    }
        \\};
        \\
    , planned.file("app/config.zig"));
    try std.testing.expectEqualStrings(
        \\//! Bindings for every generated Pkl module. Regenerate this file instead of editing it.
        \\
        \\pub const app = struct {
        \\    pub const config = @import("app/config.zig");
        \\};
        \\
    , planned.file("root.zig"));
    try expectCompiles(planned);
}

test "planning is deterministic" {
    const modules = [_]schema.ModuleInfo{
        module(app, "app", &.{
            prop("mode", unionOf(&.{ literal("fast"), literal("slow-start") }), .{ .default = scalar(.string, "slow-start") }),
            prop("value", unionOf(&.{ base("String"), base("Int"), class(app, "Point") }), .{}),
        }, .{ .classes = &.{classInfo("Point", &.{prop("x", base("Int"), .{})}, .{})} }),
    };
    var first = try run(&modules, .{});
    defer first.deinit();
    var second = try run(&modules, .{});
    defer second.deinit();
    try expectSameFiles(first, second);
    try expectCompiles(first);
}

test "literal unions become enums and mixed unions become tagged unions" {
    const modules = [_]schema.ModuleInfo{
        module(app, "app", &.{
            prop("mode", unionOf(&.{ literal("fast"), literal("slow-start") }), .{ .default = scalar(.string, "slow-start") }),
            prop("value", unionOf(&.{ literal("auto"), base("String"), baseAlias("UInt8"), class(app, "Point"), baseOf("Listing", &.{base("String")}) }), .{ .default = scalar(.string, "auto") }),
            prop("maybe", unionOf(&.{ base("Int"), base("Boolean"), base("Null") }), .{}),
        }, .{ .classes = &.{classInfo("Point", &.{prop("x", base("Int"), .{})}, .{})} }),
    };
    var planned = try run(&modules, .{});
    defer planned.deinit();
    const text = planned.file("app.zig");
    try expectContains(text, "mode: Mode = .slow_start,");
    try expectContains(text, "value: Value = .auto,");
    try expectContains(text, "maybe: ?Maybe = null,");
    try expectContains(text,
        \\pub const Mode = enum {
        \\    fast,
        \\    slow_start,
        \\
        \\    pub const pkl_names = .{ .slow_start = "slow-start" };
        \\};
    );
    try expectContains(text,
        \\pub const Value = union(enum) {
        \\    auto,
        \\    string: []const u8,
        \\    u_int8: u8,
        \\    point: Point,
        \\    listing_string: []const []const u8,
        \\
    );
    try expectContains(text,
        \\pub const Maybe = union(enum) {
        \\    int: i64,
        \\    boolean: bool,
    );
    try expectCompiles(planned);
}

test "every builtin maps to its typed core representation" {
    const modules = [_]schema.ModuleInfo{
        module(app, "app", &.{
            prop("a", base("Boolean"), .{ .default = scalar(.bool, "true") }),
            prop("b", baseAlias("Int8"), .{}),
            prop("c", baseAlias("UInt"), .{}),
            prop("d", base("Number"), .{ .default = scalar(.int, "2") }),
            prop("e", base("Duration"), .{}),
            prop("f", base("DataSize"), .{}),
            prop("g", base("Regex"), .{}),
            prop("h", base("Bytes"), .{}),
            prop("i", base("IntSeq"), .{}),
            prop("j", baseOf("Set", &.{base("String")}), .{}),
            prop("k", baseOf("Mapping", &.{ base("String"), baseAlias("Int32") }), .{}),
            prop("l", baseOf("Map", &.{ base("Int"), base("Float") }), .{}),
            prop("m", baseOf("Pair", &.{ base("String"), base("Int") }), .{}),
            prop("n", base("Any"), .{}),
            prop("o", base("Dynamic"), .{}),
            prop("p", baseOf("Listing", &.{base("Typed")}), .{}),
            prop("q", baseAlias("Char"), .{}),
            prop("r", base("Float"), .{ .default = scalar(.float, "NaN") }),
            prop("s", base("Float"), .{ .default = scalar(.float, "-Infinity") }),
            prop("t", baseAlias("UInt8"), .{ .default = scalar(.int, "300") }),
            prop("u", base("String"), .{ .zig_type = "[:0]const u8" }),
            prop("v", baseOf("List", &.{base("Int")}), .{}),
        }, .{}),
    };
    var planned = try run(&modules, .{});
    defer planned.deinit();
    const text = planned.file("app.zig");
    const expected = [_][]const u8{
        "a: bool = true,",
        "b: i8,",
        "c: u64,",
        "d: f64 = 2.0,",
        "e: zig_pkl.convert.Duration,",
        "f: zig_pkl.convert.DataSize,",
        "g: zig_pkl.convert.Regex,",
        "h: zig_pkl.convert.Bytes,",
        "i: zig_pkl.convert.IntSeq,",
        "j: []const []const u8,",
        "k: zig_pkl.convert.Map([]const u8, i32),",
        "l: zig_pkl.convert.Map(i64, f64),",
        "m: zig_pkl.convert.Pair([]const u8, i64),",
        "n: zig_pkl.convert.Dynamic,",
        "o: zig_pkl.convert.Dynamic,",
        "p: []const zig_pkl.convert.Dynamic,",
        "q: []const u8,",
        "r: f64 = std.math.nan(f64),",
        "s: f64 = -std.math.inf(f64),",
        "t: u8,",
        "u: [:0]const u8,",
        "v: []const i64,",
    };
    for (expected) |line| try expectContains(text, line);
    try expectWarning(planned, "default value of `t` cannot be represented");
    try expectCompiles(planned);
}

test "recursive and mutually recursive types are boxed only where needed" {
    const modules = [_]schema.ModuleInfo{
        module(app, "app", &.{
            prop("root", class(app, "Node"), .{}),
            prop("parent", nullable(moduleType(app)), .{}),
        }, .{ .classes = &.{
            classInfo("Node", &.{
                prop("next", nullable(class(app, "Node")), .{}),
                prop("children", baseOf("Listing", &.{class(app, "Node")}), .{}),
                prop("byName", baseOf("Mapping", &.{ base("String"), class(app, "Node") }), .{}),
                prop("other", nullable(class(app, "Other")), .{}),
                prop("plain", class(app, "Leaf"), .{}),
            }, .{}),
            classInfo("Other", &.{prop("back", baseOf("Pair", &.{ class(app, "Node"), base("Int") }), .{})}, .{}),
            classInfo("Leaf", &.{prop("id", base("Int"), .{})}, .{}),
            classInfo("Boxed", &.{prop("leaf", nullable(class(app, "Leaf")), .{ .boxed = true })}, .{}),
        } }),
    };
    var planned = try run(&modules, .{});
    defer planned.deinit();
    const text = planned.file("app.zig");
    try expectContains(text, "const pkl_module = @This();");
    try expectContains(text, "root: Node,");
    try expectContains(text, "parent: ?*const pkl_module = null,");
    try expectContains(text, "next: ?*const Node = null,");
    try expectContains(text, "children: []const Node,");
    try expectContains(text, "by_name: zig_pkl.convert.Map([]const u8, Node),");
    try expectContains(text, "other: ?*const Other = null,");
    try expectContains(text, "plain: Leaf,");
    try expectContains(text, "back: zig_pkl.convert.Pair(*const Node, i64),");
    try expectContains(text, "leaf: ?*const Leaf = null,");
    try expectCompiles(planned);
}

test "inheritance flattens fields and abstract classes become unions" {
    const modules = [_]schema.ModuleInfo{
        module(app, "app", &.{
            prop("pets", baseOf("Listing", &.{class(app, "Animal")}), .{}),
            prop("dog", class(app, "Dog"), .{}),
        }, .{ .classes = &.{
            classInfo("Animal", &.{
                prop("name", base("String"), .{}),
                prop("sound", unionOf(&.{ literal("loud"), literal("quiet") }), .{}),
            }, .{ .is_abstract = true }),
            classInfo("Dog", &.{prop("barks", base("Boolean"), .{ .default = scalar(.bool, "true") })}, .{ .is_open = true, .superclass = .{ .module_uri = app, .name = "Animal" } }),
            classInfo("Puppy", &.{prop("name", baseAlias("Char"), .{})}, .{ .superclass = .{ .module_uri = app, .name = "Dog" } }),
            classInfo("Cat", &.{}, .{ .superclass = .{ .module_uri = app, .name = "Animal" } }),
        } }),
    };
    var planned = try run(&modules, .{});
    defer planned.deinit();
    const text = planned.file("app.zig");
    try expectContains(text,
        \\pub const Animal = union(enum) {
        \\    cat: Cat,
        \\    dog: Dog,
        \\    puppy: Puppy,
    );
    try expectContains(text,
        \\pub const Dog = struct {
        \\    name: []const u8,
        \\    sound: AnimalSound,
        \\    barks: bool = true,
        \\
        \\    pub const pkl_class = "app#Dog";
        \\    pub const pkl_subclasses = [_][]const u8{"app#Puppy"};
    );
    try expectContains(text,
        \\pub const Puppy = struct {
        \\    name: []const u8,
        \\    sound: AnimalSound,
        \\    barks: bool = true,
    );
    try expectContains(text, "pub const AnimalSound = enum {");
    try expectCompiles(planned);
}

test "type aliases, generic aliases, and cross-module references" {
    const lib = "file:///lib/shapes.pkl";
    const modules = [_]schema.ModuleInfo{
        module(app, "app", &.{
            prop("port", alias(app, "Port", &.{}), .{ .default = scalar(.int, "80") }),
            prop("names", alias(app, "Named", &.{baseAlias("UInt8")}), .{}),
            prop("shape", class(lib, "Shape"), .{}),
            prop("kind", alias(lib, "Kind", &.{}), .{ .default = scalar(.string, "round") }),
            prop("lib", moduleType(lib), .{}),
            prop("level", alias(app, "Level", &.{}), .{}),
        }, .{ .aliases = &.{
            aliasInfo("Port", &.{}, baseAlias("UInt16")),
            aliasInfo("Named", &.{"T"}, baseOf("Mapping", &.{ base("String"), variable("T") })),
            aliasInfo("Level", &.{}, unionOf(&.{ literal("low"), literal("high"), base("Null") })),
        } }),
        module(lib, "lib.shapes", &.{prop("count", base("Int"), .{})}, .{
            .classes = &.{classInfo("Shape", &.{prop("back", nullable(moduleType(app)), .{})}, .{})},
            .aliases = &.{aliasInfo("Kind", &.{}, unionOf(&.{ literal("round"), literal("square") }))},
        }),
    };
    var planned = try run(&modules, .{});
    defer planned.deinit();
    const text = planned.file("app.zig");
    try expectContains(text, "const pkl_lib_shapes = @import(\"lib/shapes.zig\");");
    try expectContains(text, "port: Port = 80,");
    try expectContains(text, "names: zig_pkl.convert.Map([]const u8, u8),");
    try expectContains(text, "shape: *const pkl_lib_shapes.Shape,");
    try expectContains(text, "kind: pkl_lib_shapes.Kind = .round,");
    try expectContains(text, "lib: pkl_lib_shapes,");
    try expectContains(text, "level: Level = null,");
    try expectContains(text, "pub const Port = u16;");
    try expectContains(text, "pub const Level = ?LevelValue;");
    try expectContains(text, "pub const LevelValue = enum {");
    const lib_text = planned.file("lib/shapes.zig");
    try expectContains(lib_text, "const pkl_app = @import(\"../app.zig\");");
    try expectContains(lib_text, "back: ?*const pkl_app = null,");
    try expectContains(planned.file("root.zig"),
        \\pub const app = @import("app.zig");
        \\pub const lib = struct {
        \\    pub const shapes = @import("lib/shapes.zig");
        \\};
    );
    try expectCompiles(planned);
}

test "package mappings and annotations choose file paths" {
    const dep = "package://example.com/dep@1.0.0#/nested/value.pkl";
    const modules = [_]schema.ModuleInfo{
        module(app, "com.example.app", &.{prop("x", class(dep, "Thing"), .{})}, .{}),
        module(dep, "value", &.{}, .{ .classes = &.{classInfo("Thing", &.{}, .{})} }),
        module("file:///other.pkl", "other", &.{}, .{ .package_name = "custom.place" }),
    };
    var planned = try run(&modules, .{ .packages = &.{
        .{ .match = "com.example", .package = "example" },
        .{ .match = "package://example.com/dep@1.0.0#/", .package = "deps.dep" },
    } });
    defer planned.deinit();
    const files = planned.output.?.files;
    try std.testing.expectEqualStrings("custom/place.zig", files[0].path);
    try std.testing.expectEqualStrings("deps/dep/nested/value.zig", files[1].path);
    try std.testing.expectEqualStrings("example/app.zig", files[2].path);
    try std.testing.expectEqualStrings("root.zig", files[3].path);
    try expectContains(planned.file("example/app.zig"), "const pkl_deps_dep_nested_value = @import(\"../deps/dep/nested/value.zig\");");
    try expectCompiles(planned);
}

test "keywords, primitives, and reserved members are escaped or suffixed" {
    const modules = [_]schema.ModuleInfo{
        module(app, "app", &.{
            prop("type", base("String"), .{}),
            prop("u8", base("Int"), .{}),
            prop("load", base("Int"), .{}),
            prop("decode", base("Int"), .{}),
        }, .{ .classes = &.{
            classInfo("error", &.{ prop("pkl_class", base("Int"), .{}), prop("fn", base("Int"), .{}) }, .{}),
            classInfo("source", &.{}, .{}),
        } }),
    };
    var planned = try run(&modules, .{});
    defer planned.deinit();
    const text = planned.file("app.zig");
    try expectContains(text, "type: []const u8,");
    try expectContains(text, "u8: i64,");
    try expectContains(text, "load_: i64,");
    try expectContains(text, "decode_: i64,");
    try expectContains(text, "pub const @\"error\" = struct {");
    try expectContains(text, "pkl_class_: i64,");
    try expectContains(text, "@\"fn\": i64,");
    try expectContains(text, "pub const source_ = struct {");
    try expectContains(text, ".load_ = \"load\"");
    try expectCompiles(planned);
}

test "derived name collisions are reported" {
    const modules = [_]schema.ModuleInfo{
        module(app, "app", &.{
            prop("fooBar", base("Int"), .{}),
            prop("foo_bar", base("Int"), .{}),
        }, .{}),
    };
    var planned = try run(&modules, .{});
    defer planned.deinit();
    try expectDiagnostic(planned, "properties `fooBar` and `foo_bar` both map to field `foo_bar`");
}

test "explicit name collisions and invalid names are reported" {
    const modules = [_]schema.ModuleInfo{
        module(app, "app", &.{
            prop("a", base("Int"), .{ .zig_name = "same" }),
            prop("b", base("Int"), .{ .zig_name = "same" }),
            prop("c", base("Int"), .{ .zig_name = "not-valid" }),
            prop("d", base("Int"), .{ .zig_name = "deinit" }),
        }, .{ .classes = &.{
            classInfo("One", &.{}, .{ .zig_name = "Dup" }),
            classInfo("Two", &.{}, .{ .zig_name = "Dup" }),
        } }),
    };
    var planned = try run(&modules, .{});
    defer planned.deinit();
    try expectDiagnostic(planned, "properties `a` and `b` both map to field `same`");
    try expectDiagnostic(planned, "`@zig.Name` value `not-valid` is not a Zig identifier");
    try expectDiagnostic(planned, "`@zig.Name` value `deinit` is reserved");
    try expectDiagnostic(planned, "`@zig.Name` value `Dup` is already used");
}

test "synthesized names avoid declared names" {
    const modules = [_]schema.ModuleInfo{
        module(app, "app", &.{
            prop("mode", unionOf(&.{ literal("a"), literal("b") }), .{}),
        }, .{ .classes = &.{classInfo("Mode", &.{}, .{})} }),
    };
    var planned = try run(&modules, .{});
    defer planned.deinit();
    const text = planned.file("app.zig");
    try expectContains(text, "mode: Mode2,");
    try expectContains(text, "pub const Mode2 = enum {");
    try expectContains(text, "pub const Mode = struct {");
    try expectCompiles(planned);
}

test "literal member collisions get numeric suffixes" {
    const modules = [_]schema.ModuleInfo{
        module(app, "app", &.{
            prop("style", unionOf(&.{ literal("a-b"), literal("a_b"), literal(""), literal("pkl_names") }), .{}),
        }, .{}),
    };
    var planned = try run(&modules, .{});
    defer planned.deinit();
    try expectContains(planned.file("app.zig"),
        \\pub const Style = enum {
        \\    a_b,
        \\    a_b_2,
        \\    empty,
        \\    pkl_names_,
        \\
        \\    pub const pkl_names = .{ .a_b = "a-b", .a_b_2 = "a_b", .empty = "", .pkl_names_ = "pkl_names" };
        \\};
    );
    try expectCompiles(planned);
}

test "unsupported and ambiguous types are reported" {
    const modules = [_]schema.ModuleInfo{
        module(app, "app", &.{
            prop("f", simple(.function), .{}),
            prop("n", simple(.nothing), .{}),
            prop("c", base("Class"), .{}),
            prop("z", base("Null"), .{}),
            prop("u", unionOf(&.{ baseOf("List", &.{base("String")}), baseOf("Listing", &.{base("String")}) }), .{}),
            prop("g", base("Function1"), .{}),
        }, .{}),
    };
    var planned = try run(&modules, .{});
    defer planned.deinit();
    try expectDiagnostic(planned, "function types cannot be represented");
    try expectDiagnostic(planned, "the `nothing` type has no values");
    try expectDiagnostic(planned, "`Class` values cannot be represented");
    try expectDiagnostic(planned, "`Null` is only valid as part of a nullable type");
    try expectDiagnostic(planned, "union members `List_String` and `Listing_String` decode to the same Zig type");
}

test "file and namespace collisions are reported" {
    const modules = [_]schema.ModuleInfo{
        module("file:///a/config.pkl", "config", &.{}, .{}),
        module("file:///b/config.pkl", "config", &.{}, .{}),
        module("file:///app.pkl", "app", &.{}, .{}),
        module("file:///app/sub.pkl", "app.sub", &.{}, .{}),
        module("file:///bad.pkl", "bad", &.{}, .{ .package_name = "not valid" }),
        module("file:///root.pkl", "root", &.{}, .{}),
    };
    var planned = try run(&modules, .{});
    defer planned.deinit();
    try expectDiagnostic(planned, "modules `config` and `config` both map to `config.zig`");
    try expectDiagnostic(planned, "package `app` of module `app` is also the namespace of module `app.sub`");
    try expectDiagnostic(planned, "`@zig.Package` `not valid` is not a dotted Zig path");
    try expectDiagnostic(planned, "maps to `root.zig`, the index file");
}

test "package paths that differ only by case collide" {
    const modules = [_]schema.ModuleInfo{
        module("file:///App.pkl", "App", &.{}, .{ .package_name = "App" }),
        module("file:///app.pkl", "app", &.{}, .{}),
    };
    var planned = try run(&modules, .{});
    defer planned.deinit();
    try expectDiagnostic(planned, "which are the same path when case is ignored");
    try std.testing.expect(planned.output == null);
}

test "modules that extend others inherit their fields" {
    const parent = "file:///parent.pkl";
    const modules = [_]schema.ModuleInfo{
        module(app, "child", &.{prop("extra", base("Int"), .{})}, .{ .superclass = .{ .module_uri = parent, .name = null } }),
        module(parent, "parent", &.{prop("shared", base("String"), .{})}, .{}),
    };
    var planned = try run(&modules, .{});
    defer planned.deinit();
    try expectContains(planned.file("child.zig"),
        \\shared: []const u8,
        \\extra: i64,
        \\
        \\pub const pkl_class = "child";
    );
    try expectContains(planned.file("parent.zig"), "pub const pkl_subclasses = [_][]const u8{\"child\"};");
    try expectCompiles(planned);
}

test "untyped overrides keep the inherited type, name, and metadata" {
    const modules = [_]schema.ModuleInfo{
        module(app, "app", &.{prop("server", class(app, "TlsServer"), .{})}, .{ .classes = &.{
            classInfo("Server", &.{
                prop("host", base("String"), .{ .doc = "Host name." }),
                prop("port", baseAlias("UInt16"), .{ .zig_name = "listen_port", .default = scalar(.int, "443") }),
                prop("next", nullable(class(app, "Server")), .{ .boxed = true }),
            }, .{ .is_open = true }),
            classInfo("TlsServer", &.{
                prop("port", simple(.unknown), .{ .default = scalar(.int, "8443") }),
                prop("next", simple(.unknown), .{}),
                prop("certificate", base("String"), .{}),
            }, .{ .superclass = .{ .module_uri = app, .name = "Server" } }),
        } }),
    };
    var planned = try run(&modules, .{});
    defer planned.deinit();
    try expectContains(planned.file("app.zig"),
        \\pub const TlsServer = struct {
        \\    /// Host name.
        \\    host: []const u8,
        \\    listen_port: u16 = 8443,
        \\    next: ?*const Server = null,
        \\    certificate: []const u8,
        \\
        \\    pub const pkl_class = "app#TlsServer";
        \\    pub const pkl_names = .{ .listen_port = "port" };
    );
    try expectCompiles(planned);
}

test "nullable aliases inside cycles are boxed without changing their default" {
    const modules = [_]schema.ModuleInfo{
        module(app, "app", &.{
            prop("head", alias(app, "MaybeNode", &.{}), .{}),
            prop("list", class(app, "Node"), .{}),
        }, .{
            .classes = &.{
                classInfo("Node", &.{
                    prop("value", base("Int"), .{}),
                    prop("next", alias(app, "MaybeNode", &.{}), .{}),
                    prop("pair", alias(app, "Both", &.{}), .{}),
                }, .{}),
            },
            .aliases = &.{
                aliasInfo("MaybeNode", &.{}, nullable(class(app, "Node"))),
                aliasInfo("Both", &.{}, baseOf("Pair", &.{ alias(app, "MaybeNode", &.{}), base("Int") })),
            },
        }),
    };
    var planned = try run(&modules, .{});
    defer planned.deinit();
    const text = planned.file("app.zig");
    try expectContains(text, "head: MaybeNode = null,");
    try expectContains(text, "list: Node,");
    try expectContains(text, "next: ?*const Node = null,");
    try expectContains(text, "pair: zig_pkl.convert.Pair(?*const Node, i64),");
    try expectContains(text, "pub const MaybeNode = ?Node;");
    try expectCompiles(planned);
}

test "module argument order does not change the output" {
    const lib = "file:///lib.pkl";
    const modules = [_]schema.ModuleInfo{
        module(app, "app", &.{prop("animal", class(lib, "Animal"), .{})}, .{ .classes = &.{
            classInfo("Zebra", &.{}, .{ .superclass = .{ .module_uri = lib, .name = "Animal" } }),
            classInfo("Ant", &.{}, .{ .superclass = .{ .module_uri = lib, .name = "Animal" } }),
        } }),
        module(lib, "lib", &.{}, .{ .classes = &.{
            classInfo("Animal", &.{prop("name", base("String"), .{})}, .{ .is_abstract = true }),
            classInfo("Bee", &.{}, .{ .superclass = .{ .module_uri = lib, .name = "Animal" } }),
        } }),
    };
    var forward = try run(&modules, .{});
    defer forward.deinit();
    var backward = try runReversed(&modules, .{});
    defer backward.deinit();
    try expectSameFiles(forward, backward);
    try expectContains(forward.file("lib.zig"),
        \\pub const Animal = union(enum) {
        \\    ant: pkl_app.Ant,
        \\    zebra: pkl_app.Zebra,
        \\    bee: Bee,
    );
    try expectCompiles(forward);
}

test "undeclared, unbound, and unsupported types are reported" {
    const modules = [_]schema.ModuleInfo{
        module(app, "app", &.{
            prop("anything", simple(.unknown), .{}),
            prop("items", baseOf("Listing", &.{simple(.unknown)}), .{}),
            prop("free", variable("T"), .{}),
            prop("resource", base("Resource"), .{}),
            prop("comparable", baseAlias("Comparable"), .{}),
            prop("explicit", base("Any"), .{}),
        }, .{
            .zig_name = "App",
            .foreign_annotations = &.{.{ .location = "file:///app.pkl:3:1", .module_uri = "file:///zig.pkl" }},
        }),
    };
    var planned = try run(&modules, .{});
    defer planned.deinit();
    try expectDiagnostic(planned, "the type of this property is not declared");
    try expectDiagnostic(planned, "type variable `T` is not bound");
    try expectDiagnostic(planned, "`pkl:base` class `Resource` is not supported");
    try expectDiagnostic(planned, "`pkl:base` type alias `Comparable` is not supported");
    try expectDiagnostic(planned, "`@zig.Name` cannot rename a module");
    try expectDiagnostic(planned, "comes from `file:///zig.pkl`, not the zig-pkl annotations package");
    try std.testing.expectEqual(@as(usize, 2), planned.diagnostics.count("the type of this property is not declared"));
}

test "references map to typed core references" {
    const modules = [_]schema.ModuleInfo{
        module(app, "app", &.{
            prop("target", .{ .kind = .class, .module_uri = "pkl:ref", .name = "Reference", .args = &.{ class(app, "Ci"), class(app, "Step") } }, .{}),
            prop("path", baseOf("List", &.{.{ .kind = .class, .module_uri = "pkl:ref", .name = "Access", .args = &.{} }}), .{}),
            prop("domain", .{ .kind = .class, .module_uri = "pkl:ref", .name = "Domain", .args = &.{} }, .{}),
        }, .{ .classes = &.{
            classInfo("Ci", &.{prop("name", base("String"), .{})}, .{}),
            classInfo("Step", &.{prop("run", base("String"), .{})}, .{}),
        } }),
    };
    var planned = try run(&modules, .{});
    defer planned.deinit();
    const text = planned.file("app.zig");
    try expectContains(text, "target: zig_pkl.convert.Reference(Ci, Step),");
    try expectContains(text, "path: []const zig_pkl.convert.Access,");
    try expectContains(text, "domain: zig_pkl.convert.Dynamic,");
    try expectCompiles(planned);
}

test "representable defaults are emitted and the rest are reported" {
    const modules = [_]schema.ModuleInfo{
        module(app, "app", &.{
            prop("timeout", base("Duration"), .{ .default = quantity(.duration, "1.5", "min") }),
            prop("memory", base("DataSize"), .{ .default = quantity(.data_size, "512", "mb") }),
            prop("tags", baseOf("Listing", &.{base("String")}), .{ .default = items(.list, &.{ scalar(.string, "a"), scalar(.string, "b") }) }),
            prop("none", baseOf("Listing", &.{base("Int")}), .{ .default = items(.list, &.{}) }),
            prop("ratios", baseOf("List", &.{base("Float")}), .{ .default = items(.list, &.{scalar(.int, "1")}) }),
            prop("ports", baseOf("Mapping", &.{ base("String"), baseAlias("UInt16") }), .{ .default = items(.map, &.{ scalar(.string, "http"), scalar(.int, "80") }) }),
            prop("empty", baseOf("Mapping", &.{ base("String"), base("Int") }), .{ .default = items(.map, &.{}) }),
            prop("modes", baseOf("Listing", &.{unionOf(&.{ literal("a"), literal("b-c") })}), .{ .default = items(.list, &.{scalar(.string, "b-c")}) }),
            prop("maybe", nullable(baseOf("List", &.{base("String")})), .{ .default = items(.list, &.{scalar(.string, "x")}) }),
            prop("holes", baseOf("List", &.{nullable(base("Int"))}), .{ .default = items(.list, &.{ scalar(.null, ""), scalar(.int, "2") }) }),
            prop("pattern", base("Regex"), .{ .default = scalar(.other, "") }),
            prop("secret", base("String"), .{ .default = scalar(.failed, "") }),
            prop("point", class(app, "Point"), .{ .default = scalar(.object, "") }),
        }, .{ .classes = &.{classInfo("Point", &.{}, .{})} }),
    };
    var planned = try run(&modules, .{});
    defer planned.deinit();
    const text = planned.file("app.zig");
    try expectContains(text, "timeout: zig_pkl.convert.Duration = .{ .value = 1.5, .unit = \"min\" },");
    try expectContains(text, "memory: zig_pkl.convert.DataSize = .{ .value = 512.0, .unit = \"mb\" },");
    try expectContains(text, "tags: []const []const u8 = &.{ \"a\", \"b\" },");
    try expectContains(text, "none: []const i64 = &.{},");
    try expectContains(text, "ratios: []const f64 = &.{1.0},");
    try expectContains(text, "ports: zig_pkl.convert.Map([]const u8, u16) = .{ .entries = &.{.{ .key = \"http\", .value = 80 }} },");
    try expectContains(text, "empty: zig_pkl.convert.Map([]const u8, i64) = .{ .entries = &.{} },");
    try expectContains(text, "modes: []const Modes = &.{.b_c},");
    try expectContains(text, "maybe: ?[]const []const u8 = &.{\"x\"},");
    try expectContains(text, "holes: []const ?i64 = &.{ null, 2 },");
    try expectContains(text, "pattern: zig_pkl.convert.Regex,");
    try expectContains(text, "secret: []const u8,");
    try expectContains(text, "point: Point,");
    try expectWarning(planned, "default value of `pattern` cannot be represented");
    try expectWarning(planned, "default value of `secret` could not be evaluated");
    try std.testing.expect(!planned.diagnostics.contains("`point`"));
    try expectCompiles(planned);
}

test "overlapping union members are rejected and distinct numbers are kept" {
    const modules = [_]schema.ModuleInfo{
        module(app, "app", &.{
            prop("widths", unionOf(&.{ baseAlias("Int8"), base("Int") }), .{}),
            prop("numbers", unionOf(&.{ base("Float"), base("Number") }), .{}),
            prop("texts", unionOf(&.{ base("String"), baseAlias("Char") }), .{}),
        }, .{}),
    };
    var planned = try run(&modules, .{});
    defer planned.deinit();
    try expectDiagnostic(planned, "union members `Int8` and `Int` accept the same values");
    try expectDiagnostic(planned, "union members `Float` and `Number` decode to the same Zig type");
    try expectDiagnostic(planned, "union members `String` and `Char` decode to the same Zig type");

    const numeric = [_]schema.ModuleInfo{
        module(app, "app", &.{
            prop("a", unionOf(&.{ base("Float"), base("Int") }), .{}),
            prop("b", unionOf(&.{ base("Int"), base("Float") }), .{}),
        }, .{}),
    };
    var accepted = try run(&numeric, .{});
    defer accepted.deinit();
    try expectContains(accepted.file("app.zig"), "pub const A = union(enum) {\n    float: f64,\n    int: i64,");
    try expectContains(accepted.file("app.zig"), "pub const B = union(enum) {\n    int: i64,\n    float: f64,");
    try expectCompiles(accepted);
}

test "nested index files import modules relative to their directory" {
    const modules = [_]schema.ModuleInfo{
        module(app, "app.config", &.{prop("x", base("Int"), .{})}, .{}),
    };
    var planned = try run(&modules, .{ .index_file = "gen/all.zig" });
    defer planned.deinit();
    try std.testing.expectEqualStrings("gen/all.zig", planned.output.?.files[0].path);
    try std.testing.expectEqualStrings("gen/app/config.zig", planned.output.?.files[1].path);
    try expectContains(planned.file("gen/all.zig"), "pub const config = @import(\"app/config.zig\");");
    try expectCompiles(planned);

    for ([_][]const u8{ "../all.zig", "/all.zig", "all.txt", "a/../all.zig", "a\\all.zig", "" }) |index_file| {
        var rejected = try run(&modules, .{ .index_file = index_file });
        defer rejected.deinit();
        try expectDiagnostic(rejected, "is not a normalized relative `.zig` path");
    }
}

test "an invalid package path is reported once" {
    const modules = [_]schema.ModuleInfo{
        module(app, "app", &.{}, .{ .package_name = "not valid.also bad.x" }),
    };
    var planned = try run(&modules, .{});
    defer planned.deinit();
    try std.testing.expectEqual(@as(usize, 1), planned.diagnostics.count("is not a dotted Zig path"));
}

test "the type check rejects bindings that do not compile" {
    const modules = [_]schema.ModuleInfo{
        module(app, "app.config", &.{prop("port", base("Int"), .{ .zig_type = "NoSuchType" })}, .{}),
    };
    var planned = try run(&modules, .{});
    defer planned.deinit();
    var diagnostics = Diagnostics.init(std.testing.allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(error.CodegenFailed, typeCheck(planned, &diagnostics));
    try std.testing.expect(diagnostics.contains("do not type-check"));
    try std.testing.expect(diagnostics.contains("app/config.zig:"));
    try std.testing.expect(diagnostics.contains("NoSuchType"));
    try std.testing.expect(!diagnostics.contains(".zig-cache/tmp"));
}
