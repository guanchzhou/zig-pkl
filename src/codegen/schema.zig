//! Reflection data produced by `codegen/Schema.pkl` and the request that
//! evaluates it.

const std = @import("std");
const convert = @import("../value/convert.zig");
const value = @import("../value/value.zig");
const manager = @import("../evaluator/manager.zig");

/// Module URI scheme under which the generator serves `Schema.pkl`.
pub const scheme = "zig-pkl-codegen";
pub const schema_uri = scheme ++ ":/Schema.pkl";
pub const source = @embedFile("zig_pkl_codegen_schema");

pub const TypeInfo = struct {
    kind: Kind,
    module_uri: ?[]const u8,
    name: ?[]const u8,
    args: []const TypeInfo,

    pub const Kind = enum {
        class,
        module_class,
        alias,
        self_module,
        nullable,
        @"union",
        literal,
        function,
        unknown,
        nothing,
        variable,
    };
};

/// A property's default value. Scalars carry `text`; durations and data
/// sizes carry `text` (the number) and `unit`; lists carry `items`; maps
/// carry alternating keys and values in `items`. `object` is an object
/// value, `other` a value of another type, and `failed` a default that could
/// not be evaluated, for example because it reads a resource.
pub const DefaultInfo = struct {
    kind: Kind,
    text: []const u8,
    unit: ?[]const u8,
    items: []const DefaultInfo,

    pub const Kind = enum { bool, int, float, string, null, duration, data_size, list, map, object, other, failed };
};

pub const PropertyInfo = struct {
    name: []const u8,
    zig_name: ?[]const u8,
    location: []const u8,
    doc: ?[]const u8,
    type: TypeInfo,
    boxed: bool,
    zig_type: ?[]const u8,
    default: ?DefaultInfo,
};

pub const ClassRef = struct {
    module_uri: []const u8,
    /// `null` for a module class.
    name: ?[]const u8,
};

pub const ClassInfo = struct {
    name: []const u8,
    zig_name: ?[]const u8,
    location: []const u8,
    doc: ?[]const u8,
    is_abstract: bool,
    is_open: bool,
    superclass: ?ClassRef,
    properties: []const PropertyInfo,
};

pub const AliasInfo = struct {
    name: []const u8,
    zig_name: ?[]const u8,
    location: []const u8,
    doc: ?[]const u8,
    params: []const []const u8,
    referent: TypeInfo,
};

/// An annotation named like a zig-pkl annotation whose module is not the
/// zig-pkl annotations package.
pub const ForeignAnnotation = struct {
    location: []const u8,
    module_uri: []const u8,
};

pub const ModuleInfo = struct {
    uri: []const u8,
    name: []const u8,
    package_name: ?[]const u8,
    zig_name: ?[]const u8,
    location: []const u8,
    doc: ?[]const u8,
    module_class: ClassInfo,
    /// Declared classes, then local classes that the module's types refer to.
    classes: []const ClassInfo,
    aliases: []const AliasInfo,
    foreign_annotations: []const ForeignAnnotation,
};

pub const Description = struct {
    /// URIs of the modules that declare the classes of the requested targets.
    roots: []const []const u8,
    modules: []const ModuleInfo,
};

/// A description and the arena that owns it.
pub const Owned = struct {
    arena: *std.heap.ArenaAllocator,
    description: Description,

    pub fn deinit(self: *Owned) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
        self.* = undefined;
    }
};

/// Copies a description out of an evaluated `Description` object.
pub fn decode(allocator: std.mem.Allocator, root: *const value.Value) convert.Error!Owned {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = .init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    const description = try convert.into(Description, arena.allocator(), root);
    return .{ .arena = arena, .description = description };
}

/// Pkl module text that describes `module_uris`. Evaluate it with the
/// expression `result`.
pub fn script(allocator: std.mem.Allocator, module_uris: []const []const u8) error{OutOfMemory}![]u8 {
    return scriptCall(allocator, module_uris, "describe");
}

fn scriptCall(allocator: std.mem.Allocator, module_uris: []const []const u8, function: []const u8) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    writeScript(writer, module_uris, function) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn writeScript(writer: *std.Io.Writer, module_uris: []const []const u8, function: []const u8) std.Io.Writer.Error!void {
    try writer.writeAll("import \"" ++ schema_uri ++ "\" as zig_pkl_schema\n");
    for (module_uris, 0..) |uri, index| {
        try writer.print("import \"{f}\" as zig_pkl_target{d}\n", .{ pklString(uri), index });
    }
    try writer.print("result = zig_pkl_schema.{s}(List(", .{function});
    for (module_uris, 0..) |_, index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.print("zig_pkl_target{d}", .{index});
    }
    try writer.writeAll("))\n");
}

fn pklString(text: []const u8) std.fmt.Alt([]const u8, writePklString) {
    return .{ .data = text };
}

fn writePklString(text: []const u8, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    for (text) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => try writer.writeByte(byte),
    };
}

/// Evaluates the description of `module_uris`. The evaluator must serve
/// `scheme` with `source` and allow `pkl:`, `scheme:`, and the target
/// schemes. On `error.EvaluationFailed`, `failure` owns the Pkl error text,
/// allocated with the manager allocator.
pub fn describe(
    allocator: std.mem.Allocator,
    evaluator: *manager.Evaluator,
    module_uris: []const []const u8,
    failure: *?[]u8,
) !Owned {
    const text = try script(allocator, module_uris);
    defer allocator.free(text);
    var tree = try evaluator.evaluate("repl:text", text, "result", failure);
    defer tree.deinit();
    return decode(allocator, tree.root);
}

/// URIs of every module [describe] would emit, allocated with `allocator`.
/// The caller frees each string and the list. On `error.EvaluationFailed`,
/// `failure` owns the Pkl error text.
pub fn describedUris(
    allocator: std.mem.Allocator,
    evaluator: *manager.Evaluator,
    module_uris: []const []const u8,
    failure: *?[]u8,
) ![][]u8 {
    const text = try scriptCall(allocator, module_uris, "describedUris");
    defer allocator.free(text);
    var tree = try evaluator.evaluate("repl:text", text, "result", failure);
    defer tree.deinit();
    const items = switch (tree.root.*) {
        .list, .listing => |nodes| nodes,
        else => return error.InvalidDescription,
    };
    const out = try allocator.alloc([]u8, items.len);
    errdefer allocator.free(out);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |item| allocator.free(item);
    }
    for (items) |node| {
        if (node.* != .string) return error.InvalidDescription;
        out[filled] = try allocator.dupe(u8, node.string);
        filled += 1;
    }
    return out;
}

test "the description script imports every target once" {
    const text = try script(std.testing.allocator, &.{ "file:///a.pkl", "file:///odd \"name\".pkl" });
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        \\import "zig-pkl-codegen:/Schema.pkl" as zig_pkl_schema
        \\import "file:///a.pkl" as zig_pkl_target0
        \\import "file:///odd \"name\".pkl" as zig_pkl_target1
        \\result = zig_pkl_schema.describe(List(zig_pkl_target0, zig_pkl_target1))
        \\
    , text);
}

test "the embedded schema declares describe" {
    try std.testing.expect(std.mem.indexOf(u8, source, "function describe(") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "function describedUris(") != null);
}
