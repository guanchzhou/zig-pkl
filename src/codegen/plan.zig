//! Turns a schema description into Zig source files.
//!
//! Planning is pure and deterministic: the same description and options
//! produce byte-identical files. Every file is canonicalized with the Zig
//! formatter. Problems are collected in `Diagnostics`; planning continues
//! past them so that one run reports as many as it can.
//!
//! Modules are processed in URI order, and subclass unions list their
//! members by qualified class name, so the order in which modules are
//! requested never changes the output. Properties, classes, and union
//! members otherwise keep their Pkl declaration order.
//!
//! Mapping rules:
//! - Each described module becomes one file whose top-level fields are the
//!   module's properties. Classes, type aliases, and synthesized unions and
//!   enums are declarations in that file. Files live in the directory of
//!   the index file.
//! - A property without a declared type is an error, except an override of
//!   an inherited property, which keeps the inherited type and annotations.
//!   An override of a hidden property is omitted with that property.
//! - Properties become `snake_case` fields unless `@zig.Name` says otherwise.
//!   A derived name that collides with a generated member gains a trailing
//!   `_`; any other collision is an error.
//! - Inherited properties are flattened into each subclass. An abstract
//!   class with known concrete subclasses becomes a tagged union of them.
//! - Unions of string literals become enums. Other unions become tagged
//!   unions; `Null` members make the union optional. Members that a value
//!   could match more than one of, such as `Int8|Int`, are an error.
//! - Values that contain their own type by value, directly or through other
//!   declarations, are stored behind `*const` pointers.

const std = @import("std");
const schema = @import("schema.zig");
const names = @import("names.zig");
const output = @import("output.zig");
const Diagnostics = @import("diagnostics.zig").Diagnostics;

const TypeInfo = schema.TypeInfo;
const Allocator = std.mem.Allocator;

pub const PackageMapping = struct {
    /// A module name (`app.config`), a module-name prefix (`app` also maps
    /// `app.config`), or, when it contains `:`, a module URI or URI prefix.
    match: []const u8,
    /// Dotted Zig path. For a prefix match the remainder of the module name
    /// or URI path is appended.
    package: []const u8,
};

pub const Options = struct {
    packages: []const PackageMapping = &.{},
    /// File that exposes every generated module as nested declarations. A
    /// normalized relative `.zig` path; module files are placed in its
    /// directory.
    index_file: []const u8 = "root.zig",
};

pub const File = @import("output.zig").File;

pub const Output = struct {
    arena: *std.heap.ArenaAllocator,
    /// Sorted by path.
    files: []const File,

    pub fn deinit(self: *Output) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
        self.* = undefined;
    }
};

pub const Error = error{ OutOfMemory, InvalidSchema };

pub const header_prefix = "//! Bindings for ";

/// Whether `path` can name the index file.
pub fn isIndexPath(path: []const u8) bool {
    return output.isSafePath(path) and std.mem.endsWith(u8, path, ".zig") and
        !std.mem.eql(u8, std.fs.path.basenamePosix(path), output.manifest_name);
}

pub fn plan(gpa: Allocator, description: schema.Description, options: Options, diagnostics: *Diagnostics) Error!Output {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(gpa);
    errdefer {
        arena.deinit();
        gpa.destroy(arena);
    }
    var planner = Planner{
        .a = arena.allocator(),
        .description = description,
        .options = options,
        .diagnostics = diagnostics,
    };
    const errors_before = diagnostics.errorCount();
    if (!isIndexPath(options.index_file)) {
        try diagnostics.add(null, "index file `{s}` is not a normalized relative `.zig` path", .{options.index_file});
        return error.InvalidSchema;
    }
    const files = try planner.run();
    if (diagnostics.errorCount() != errors_before) return error.InvalidSchema;
    return .{ .arena = arena, .files = files };
}

const DeclId = usize;

const Type = union(enum) {
    bool,
    int: []const u8,
    float,
    string,
    duration,
    data_size,
    regex,
    bytes,
    int_seq,
    dynamic,
    optional: *const Type,
    slice: *const Type,
    map: [2]*const Type,
    pair: [2]*const Type,
    boxed: *const Type,
    decl: DeclId,
    raw: []const u8,
    /// `pkl:ref` `Reference<D, T>`.
    reference: [2]*const Type,
    /// `pkl:ref` `Access`.
    access,
};

const Field = struct {
    name: []const u8,
    pkl_name: []const u8,
    location: []const u8,
    doc: ?[]const u8,
    type: *const Type,
    default: Default,
};

const Default = union(enum) {
    none,
    null,
    /// No Pkl default: `null` when the type is optional, possibly through aliases.
    absent,
    pkl: schema.DefaultInfo,
};

const Variant = struct {
    name: []const u8,
    literal: ?[]const u8,
    type: ?*const Type,
    label: []const u8,
};

const Member = struct {
    name: []const u8,
    literal: []const u8,
};

const Body = union(enum) {
    pending,
    @"struct": struct {
        fields: []const Field,
        pkl_class: []const u8,
        subclasses: []const []const u8,
    },
    @"union": []const Variant,
    @"enum": []const Member,
    alias: *const Type,
};

const Decl = struct {
    module: usize,
    name: []const u8,
    doc: ?[]const u8,
    is_module: bool = false,
    body: Body = .pending,
};

const Resolved = struct {
    type: *const Type,
    default: Default,
};

const ClassState = struct {
    module: usize,
    info: *const schema.ClassInfo,
    decl: DeclId,
    qualified: []const u8,
    superclass: ?usize = null,
    own: ?[]const Resolved = null,
    concrete_descendants: std.ArrayList(usize) = .empty,
};

const PropRef = struct {
    class: usize,
    index: usize,
};

const Module = struct {
    info: *const schema.ModuleInfo,
    segments: []const []const u8,
    /// Path relative to the output directory.
    file: []const u8,
    /// Path relative to the index file's directory.
    indexed: []const u8,
    decl: DeclId,
    module_class: usize,
    classes: std.StringHashMapUnmanaged(usize) = .empty,
    aliases: std.StringHashMapUnmanaged(usize) = .empty,
    alias_decls: std.StringHashMapUnmanaged(DeclId) = .empty,
    taken: std.StringHashMapUnmanaged(void) = .empty,
    order: std.ArrayList(DeclId) = .empty,
    imports: std.AutoArrayHashMapUnmanaged(usize, []const u8) = .empty,
    uses_self: bool = false,
};

const Env = struct {
    params: []const []const u8,
    args: []const TypeInfo,
    parent: ?*const Env,
    args_env: ?*const Env,
};

const Context = struct {
    module: usize,
    base: []const u8,
    location: []const u8,
    env: ?*const Env = null,
};

const file_reserved = [_][]const u8{
    "std", "zig_pkl", "pkl_module", "pkl_class", "pkl_subclasses", "pkl_names", "decode", "deinit", "load",
};
/// Parameter and local names of the generated helpers; declarations may not shadow them.
const helper_locals = [_][]const u8{ "allocator", "root", "self", "evaluator", "source", "failure", "tree" };
const struct_reserved = [_][]const u8{ "pkl_class", "pkl_subclasses", "pkl_names", "decode", "deinit" };
const union_reserved = [_][]const u8{ "pkl_names", "decode", "deinit" };
const enum_reserved = [_][]const u8{"pkl_names"};

const Planner = struct {
    a: Allocator,
    description: schema.Description,
    options: Options,
    diagnostics: *Diagnostics,
    modules: std.ArrayList(Module) = .empty,
    by_uri: std.StringHashMapUnmanaged(usize) = .empty,
    decls: std.ArrayList(Decl) = .empty,
    classes: std.ArrayList(ClassState) = .empty,
    scc: []usize = &.{},
    self_loops: []bool = &.{},
    scc_size: []usize = &.{},

    fn fail(self: *Planner, location: ?[]const u8, comptime format: []const u8, args: anytype) error{OutOfMemory}!void {
        try self.diagnostics.add(location, format, args);
    }

    fn run(self: *Planner) Error![]const File {
        try self.collectModules();
        try self.declareNames();
        try self.linkClasses();
        try self.inheritOverrides();
        try self.reserveModuleFields();
        try self.resolveAll();
        try self.computeCycles();
        try self.collectImports();
        return self.render();
    }

    // Modules and packages.

    fn collectModules(self: *Planner) Error!void {
        const sorted = try self.a.alloc(*const schema.ModuleInfo, self.description.modules.len);
        for (self.description.modules, sorted) |*info, *slot| slot.* = info;
        std.mem.sort(*const schema.ModuleInfo, sorted, {}, struct {
            fn less(_: void, left: *const schema.ModuleInfo, right: *const schema.ModuleInfo) bool {
                return std.mem.lessThan(u8, left.uri, right.uri);
            }
        }.less);
        const index_dir = std.fs.path.dirnamePosix(self.options.index_file);
        var files: std.StringHashMapUnmanaged(usize) = .empty;
        for (sorted) |info| {
            if (self.by_uri.contains(info.uri)) continue;
            const segments = try self.packageSegments(info);
            const indexed = try std.fmt.allocPrint(self.a, "{s}.zig", .{try std.mem.join(self.a, "/", segments)});
            const file = if (index_dir) |dir| try std.fmt.allocPrint(self.a, "{s}/{s}", .{ dir, indexed }) else indexed;
            const decl = try self.addDecl(.{ .module = self.modules.items.len, .name = info.name, .doc = info.doc, .is_module = true });
            try self.modules.append(self.a, .{
                .info = info,
                .segments = segments,
                .file = file,
                .indexed = indexed,
                .decl = decl,
                .module_class = 0,
            });
            if (info.zig_name != null) {
                try self.fail(info.location, "`@zig.Name` cannot rename a module; use `@zig.Package` to choose its Zig path", .{});
            }
            for (info.foreign_annotations) |foreign| {
                try self.fail(foreign.location, "this `@zig` annotation comes from `{s}`, not the zig-pkl annotations package; import `@zig/zig.pkl` from the package", .{foreign.module_uri});
            }
            try self.by_uri.put(self.a, info.uri, self.modules.items.len - 1);
            const folded = try foldPath(self.a, file);
            if (files.get(folded)) |other| {
                const other_file = self.modules.items[other].file;
                if (std.mem.eql(u8, other_file, file)) {
                    try self.fail(info.location, "modules `{s}` and `{s}` both map to `{s}`; set `@zig.Package` or a package mapping to separate them", .{
                        self.modules.items[other].info.name, info.name, file,
                    });
                } else {
                    try self.fail(info.location, "modules `{s}` and `{s}` map to `{s}` and `{s}`, which are the same path when case is ignored; set `@zig.Package` or a package mapping to separate them", .{
                        self.modules.items[other].info.name, info.name, other_file, file,
                    });
                }
            } else try files.put(self.a, folded, self.modules.items.len - 1);
            if (std.ascii.eqlIgnoreCase(file, self.options.index_file)) {
                try self.fail(info.location, "module `{s}` maps to `{s}`, the index file", .{ info.name, file });
            }
        }
        for (self.modules.items, 0..) |left, i| {
            for (self.modules.items, 0..) |right, j| {
                if (i == j or left.segments.len >= right.segments.len) continue;
                if (segmentsPrefix(left.segments, right.segments)) {
                    try self.fail(left.info.location, "package `{s}` of module `{s}` is also the namespace of module `{s}`", .{
                        try std.mem.join(self.a, ".", left.segments), left.info.name, right.info.name,
                    });
                }
            }
        }
    }

    fn packageSegments(self: *Planner, info: *const schema.ModuleInfo) Error![]const []const u8 {
        var best: ?PackageMapping = null;
        for (self.options.packages) |mapping| {
            if (!mappingMatches(mapping.match, info)) continue;
            if (best == null or mapping.match.len > best.?.match.len) best = mapping;
        }
        var out: std.ArrayList([]const u8) = .empty;
        if (best) |mapping| {
            try self.explicitSegments(&out, mapping.package, info.location, "package mapping");
            const rest = mappingRest(mapping.match, info);
            var parts = std.mem.tokenizeAny(u8, rest, if (std.mem.indexOfScalar(u8, mapping.match, ':') != null) "/" else ".");
            while (parts.next()) |part| {
                const trimmed = if (std.mem.endsWith(u8, part, ".pkl")) part[0 .. part.len - 4] else part;
                try out.append(self.a, try names.snakeCase(self.a, trimmed));
            }
        } else if (info.package_name) |package| {
            try self.explicitSegments(&out, package, info.location, "`@zig.Package`");
        } else {
            var parts = std.mem.tokenizeScalar(u8, info.name, '.');
            while (parts.next()) |part| try out.append(self.a, try names.snakeCase(self.a, part));
        }
        if (out.items.len == 0) try out.append(self.a, "unnamed");
        return out.toOwnedSlice(self.a);
    }

    fn explicitSegments(self: *Planner, out: *std.ArrayList([]const u8), package: []const u8, location: []const u8, origin: []const u8) Error!void {
        var valid = true;
        var parts = std.mem.splitScalar(u8, package, '.');
        while (parts.next()) |part| {
            if (!names.isIdentifier(part)) {
                valid = false;
                try out.append(self.a, try names.sanitize(self.a, part));
            } else try out.append(self.a, part);
        }
        if (!valid) try self.fail(location, "{s} `{s}` is not a dotted Zig path", .{ origin, package });
    }

    // Names.

    fn declareNames(self: *Planner) Error!void {
        for (self.modules.items, 0..) |*module, module_index| {
            for (file_reserved ++ helper_locals) |name| try module.taken.put(self.a, name, {});
            module.module_class = try self.addClass(module_index, &module.info.module_class, module.decl, module.info.name);
            for (module.info.classes) |*class| {
                const name = try self.declName(module, class.name, class.zig_name, class.location);
                const decl = try self.addDecl(.{ .module = module_index, .name = name, .doc = class.doc });
                try module.order.append(self.a, decl);
                const qualified = try std.fmt.allocPrint(self.a, "{s}#{s}", .{ module.info.name, class.name });
                try module.classes.put(self.a, class.name, try self.addClass(module_index, class, decl, qualified));
            }
            for (module.info.aliases, 0..) |*alias, alias_index| {
                try module.aliases.put(self.a, alias.name, alias_index);
                if (alias.params.len != 0) continue;
                const name = try self.declName(module, alias.name, alias.zig_name, alias.location);
                const decl = try self.addDecl(.{ .module = module_index, .name = name, .doc = alias.doc });
                try module.order.append(self.a, decl);
                try module.alias_decls.put(self.a, alias.name, decl);
            }
        }
    }

    fn declName(self: *Planner, module: *Module, pkl_name: []const u8, zig_name: ?[]const u8, location: []const u8) Error![]const u8 {
        if (zig_name) |explicit| {
            if (!names.isIdentifier(explicit)) {
                try self.fail(location, "`@zig.Name` value `{s}` is not a Zig identifier", .{explicit});
                return self.fresh(module, try names.sanitize(self.a, explicit));
            }
            if (module.taken.contains(explicit)) {
                try self.fail(location, "`@zig.Name` value `{s}` is already used in `{s}`", .{ explicit, module.file });
            }
            try module.taken.put(self.a, explicit, {});
            return explicit;
        }
        var name = try names.sanitize(self.a, pkl_name);
        if (isReserved(&file_reserved, name) or isReserved(&helper_locals, name)) name = try std.fmt.allocPrint(self.a, "{s}_", .{name});
        if (module.taken.contains(name)) {
            try self.fail(location, "`{s}` is already used in `{s}`; rename it with `@zig.Name`", .{ name, module.file });
        }
        try module.taken.put(self.a, name, {});
        return name;
    }

    fn fresh(self: *Planner, module: *Module, base: []const u8) Error![]const u8 {
        var candidate = base;
        var counter: usize = 2;
        while (module.taken.contains(candidate)) : (counter += 1) {
            candidate = try std.fmt.allocPrint(self.a, "{s}{d}", .{ base, counter });
        }
        try module.taken.put(self.a, candidate, {});
        return candidate;
    }

    fn addDecl(self: *Planner, decl: Decl) Error!DeclId {
        try self.decls.append(self.a, decl);
        return self.decls.items.len - 1;
    }

    fn addClass(self: *Planner, module: usize, info: *const schema.ClassInfo, decl: DeclId, qualified: []const u8) Error!usize {
        try self.classes.append(self.a, .{ .module = module, .info = info, .decl = decl, .qualified = qualified });
        return self.classes.items.len - 1;
    }

    // Inheritance.

    fn linkClasses(self: *Planner) Error!void {
        for (self.classes.items) |*class| {
            const reference = class.info.superclass orelse continue;
            const module_index = self.by_uri.get(reference.module_uri) orelse {
                try self.fail(class.info.location, "superclass module `{s}` was not described", .{reference.module_uri});
                continue;
            };
            const module = &self.modules.items[module_index];
            class.superclass = if (reference.name) |name| module.classes.get(name) else module.module_class;
            if (class.superclass == null) {
                try self.fail(class.info.location, "superclass `{s}` was not described", .{reference.name.?});
            }
        }
        for (self.classes.items, 0..) |class, index| {
            if (class.info.is_abstract) continue;
            var step = class.superclass;
            var guard: usize = 0;
            while (step) |ancestor| : (guard += 1) {
                if (guard > self.classes.items.len) break;
                try self.classes.items[ancestor].concrete_descendants.append(self.a, index);
                step = self.classes.items[ancestor].superclass;
            }
        }
    }

    /// Gives each property that overrides an inherited one without declaring
    /// a type the inherited type, and fills in inherited annotations and
    /// documentation the override does not set.
    fn inheritOverrides(self: *Planner) Error!void {
        const done = try self.a.alloc(bool, self.classes.items.len);
        @memset(done, false);
        for (0..self.classes.items.len) |index| try self.inheritInto(index, done, 0);
    }

    fn inheritInto(self: *Planner, class_index: usize, done: []bool, depth: usize) Error!void {
        if (done[class_index] or depth > self.classes.items.len) return;
        done[class_index] = true;
        const parent = self.classes.items[class_index].superclass orelse return;
        try self.inheritInto(parent, done, depth + 1);
        const info = self.classes.items[class_index].info;
        var changed: ?[]schema.PropertyInfo = null;
        for (info.properties, 0..) |property, index| {
            const inherited = self.inheritedProperty(parent, property.name) orelse continue;
            var merged = property;
            if (property.type.kind == .unknown) {
                merged.type = inherited.type;
                merged.boxed = property.boxed or inherited.boxed;
                if (merged.zig_type == null) merged.zig_type = inherited.zig_type;
            }
            if (merged.zig_name == null) merged.zig_name = inherited.zig_name;
            if (merged.doc == null) merged.doc = inherited.doc;
            if (changed == null) changed = try self.a.dupe(schema.PropertyInfo, info.properties);
            changed.?[index] = merged;
        }
        const properties = changed orelse return;
        const copy = try self.a.create(schema.ClassInfo);
        copy.* = info.*;
        copy.properties = properties;
        self.classes.items[class_index].info = copy;
    }

    fn inheritedProperty(self: *Planner, class_index: usize, name: []const u8) ?schema.PropertyInfo {
        var step: ?usize = class_index;
        var guard: usize = 0;
        while (step) |current| : (guard += 1) {
            if (guard > self.classes.items.len) return null;
            for (self.classes.items[current].info.properties) |property| {
                if (std.mem.eql(u8, property.name, name)) return property;
            }
            step = self.classes.items[current].superclass;
        }
        return null;
    }

    fn flatProperties(self: *Planner, class_index: usize) Error![]const PropRef {
        var chain: std.ArrayList(usize) = .empty;
        var step: ?usize = class_index;
        while (step) |current| {
            if (chain.items.len > self.classes.items.len) break;
            try chain.append(self.a, current);
            step = self.classes.items[current].superclass;
        }
        var out: std.ArrayList(PropRef) = .empty;
        var position: std.StringHashMapUnmanaged(usize) = .empty;
        var index = chain.items.len;
        while (index > 0) {
            index -= 1;
            const owner = chain.items[index];
            for (self.classes.items[owner].info.properties, 0..) |property, property_index| {
                const ref = PropRef{ .class = owner, .index = property_index };
                if (position.get(property.name)) |existing| {
                    out.items[existing] = ref;
                } else {
                    try position.put(self.a, property.name, out.items.len);
                    try out.append(self.a, ref);
                }
            }
        }
        return out.toOwnedSlice(self.a);
    }

    // Type resolution.

    fn resolveAll(self: *Planner) Error!void {
        for (self.classes.items, 0..) |_, index| try self.resolveOwn(index);
        for (self.modules.items, 0..) |*module, module_index| {
            for (module.info.aliases) |*alias| {
                const decl = module.alias_decls.get(alias.name) orelse continue;
                try self.resolveAliasDecl(module_index, decl, alias);
            }
        }
        for (self.classes.items, 0..) |class, index| {
            const decl = &self.decls.items[class.decl];
            if (!decl.is_module and class.info.is_abstract and class.concrete_descendants.items.len != 0) {
                decl.body = .{ .@"union" = try self.subclassVariants(class) };
                continue;
            }
            decl.body = .{ .@"struct" = .{
                .fields = try self.containerFields(index),
                .pkl_class = class.qualified,
                .subclasses = try self.subclassNames(class),
            } };
        }
    }

    fn resolveOwn(self: *Planner, class_index: usize) Error!void {
        const class = &self.classes.items[class_index];
        const module_index = class.module;
        const class_name = self.decls.items[class.decl].name;
        const is_module = self.decls.items[class.decl].is_module;
        const own = try self.a.alloc(Resolved, class.info.properties.len);
        for (class.info.properties, own) |*property, *slot| {
            const pascal = try names.pascalCase(self.a, property.name);
            const base = if (is_module) pascal else try std.fmt.allocPrint(self.a, "{s}{s}", .{ class_name, pascal });
            const context = Context{ .module = module_index, .base = base, .location = property.location };
            var resolved: *const Type = undefined;
            if (property.zig_type) |raw| {
                if (try rawTypeProblem(self.a, raw)) |problem| {
                    try self.fail(property.location, "`@zig.Field.type` of `{s}` is not a single Zig type expression: {s}", .{ property.name, problem });
                    resolved = try self.make(.{ .raw = "void" });
                } else {
                    resolved = try self.make(.{ .raw = raw });
                }
            } else {
                resolved = try self.resolve(property.type, context);
                if (property.boxed) resolved = try self.box(resolved);
            }
            slot.* = .{ .type = resolved, .default = defaultOf(property, resolved) };
        }
        self.classes.items[class_index].own = own;
    }

    fn defaultOf(property: *const schema.PropertyInfo, resolved: *const Type) Default {
        if (property.zig_type != null) return .none;
        if (property.boxed) return if (resolved.* == .optional and property.default == null) .null else .none;
        if (property.default) |found| return .{ .pkl = found };
        return .absent;
    }

    fn box(self: *Planner, resolved: *const Type) Error!*const Type {
        return switch (resolved.*) {
            .optional => |inner| self.make(.{ .optional = try self.box(inner) }),
            .boxed => resolved,
            else => self.make(.{ .boxed = resolved }),
        };
    }

    fn derivedFieldName(self: *Planner, property: *const schema.PropertyInfo, is_module: bool) Error![]const u8 {
        if (property.zig_name) |explicit| {
            return if (names.isIdentifier(explicit)) explicit else names.sanitize(self.a, explicit);
        }
        const name = try names.snakeCase(self.a, property.name);
        if (isReserved(&struct_reserved, name) or (is_module and isReserved(&file_reserved, name))) {
            return std.fmt.allocPrint(self.a, "{s}_", .{name});
        }
        return name;
    }

    fn reserveModuleFields(self: *Planner) Error!void {
        for (self.modules.items) |*module| {
            var fields: std.StringHashMapUnmanaged(void) = .empty;
            for (try self.flatProperties(module.module_class)) |ref| {
                const property = &self.classes.items[ref.class].info.properties[ref.index];
                const name = try self.derivedFieldName(property, true);
                if (fields.contains(name) or isReserved(&file_reserved, name) or isReserved(&helper_locals, name)) continue;
                if (module.taken.contains(name)) {
                    try self.fail(property.location, "field `{s}` collides with a declaration in `{s}`; rename it with `@zig.Name`", .{ name, module.file });
                }
                try fields.put(self.a, name, {});
                try module.taken.put(self.a, name, {});
            }
        }
    }

    fn containerFields(self: *Planner, class_index: usize) Error![]const Field {
        const class = self.classes.items[class_index];
        const decl = self.decls.items[class.decl];
        const props = try self.flatProperties(class_index);
        var used: std.StringHashMapUnmanaged([]const u8) = .empty;
        const fields = try self.a.alloc(Field, props.len);
        for (props, fields) |ref, *field| {
            const owner = self.classes.items[ref.class];
            const property = &owner.info.properties[ref.index];
            const resolved = owner.own.?[ref.index];
            const name = try self.derivedFieldName(property, decl.is_module);
            if (property.zig_name) |explicit| {
                if (!names.isIdentifier(explicit)) {
                    try self.fail(property.location, "`@zig.Name` value `{s}` is not a Zig identifier", .{explicit});
                } else if (isReserved(&struct_reserved, explicit) or (decl.is_module and isReserved(&file_reserved, explicit))) {
                    try self.fail(property.location, "`@zig.Name` value `{s}` is reserved for generated declarations", .{explicit});
                }
            }
            if (used.get(name)) |other| {
                try self.fail(property.location, "properties `{s}` and `{s}` both map to field `{s}`; rename one with `@zig.Name`", .{ other, property.name, name });
            } else try used.put(self.a, name, property.name);
            field.* = .{
                .name = name,
                .pkl_name = property.name,
                .location = property.location,
                .doc = property.doc,
                .type = resolved.type,
                .default = resolved.default,
            };
        }
        return fields;
    }

    fn sortedDescendants(self: *Planner, class: ClassState) Error![]const usize {
        const sorted = try self.a.dupe(usize, class.concrete_descendants.items);
        std.mem.sort(usize, sorted, self, struct {
            fn less(planner: *Planner, left: usize, right: usize) bool {
                return std.mem.lessThan(u8, planner.classes.items[left].qualified, planner.classes.items[right].qualified);
            }
        }.less);
        return sorted;
    }

    fn subclassVariants(self: *Planner, class: ClassState) Error![]const Variant {
        var used: std.StringHashMapUnmanaged(void) = .empty;
        const descendants = try self.sortedDescendants(class);
        const variants = try self.a.alloc(Variant, descendants.len);
        for (descendants, variants) |descendant, *variant| {
            const target = self.classes.items[descendant];
            const label = self.decls.items[target.decl].name;
            variant.* = .{
                .name = try self.uniqueMember(&used, try names.snakeCase(self.a, label), &union_reserved),
                .literal = null,
                .type = try self.make(.{ .decl = target.decl }),
                .label = target.qualified,
            };
        }
        return variants;
    }

    fn subclassNames(self: *Planner, class: ClassState) Error![]const []const u8 {
        const descendants = try self.sortedDescendants(class);
        const out = try self.a.alloc([]const u8, descendants.len);
        for (descendants, out) |descendant, *slot| slot.* = self.classes.items[descendant].qualified;
        return out;
    }

    fn resolveAliasDecl(self: *Planner, module_index: usize, decl: DeclId, alias: *const schema.AliasInfo) Error!void {
        const context = Context{ .module = module_index, .base = self.decls.items[decl].name, .location = alias.location };
        if (alias.referent.kind == .@"union" or alias.referent.kind == .literal) {
            const members = if (alias.referent.kind == .literal) @as([]const TypeInfo, &.{alias.referent}) else alias.referent.args;
            const resolved = try self.resolveUnion(members, context, decl);
            if (self.decls.items[decl].body == .pending) self.decls.items[decl].body = .{ .alias = resolved };
            return;
        }
        self.decls.items[decl].body = .{ .alias = try self.resolve(alias.referent, context) };
    }

    fn make(self: *Planner, item: Type) Error!*const Type {
        const out = try self.a.create(Type);
        out.* = item;
        return out;
    }

    fn resolve(self: *Planner, info: TypeInfo, context: Context) Error!*const Type {
        switch (info.kind) {
            .class => {
                const module_uri = info.module_uri orelse "";
                const name = info.name orelse "";
                if (std.mem.eql(u8, module_uri, "pkl:base")) return self.builtinClass(name, info.args, context);
                if (std.mem.eql(u8, module_uri, "pkl:ref")) return self.referenceClass(name, info.args, context);
                const module_index = self.by_uri.get(module_uri) orelse {
                    try self.fail(context.location, "module `{s}` was not described", .{module_uri});
                    return self.make(.dynamic);
                };
                const class_index = self.modules.items[module_index].classes.get(name) orelse {
                    try self.fail(context.location, "class `{s}` was not described", .{name});
                    return self.make(.dynamic);
                };
                return self.make(.{ .decl = self.classes.items[class_index].decl });
            },
            .module_class => {
                const module_index = self.by_uri.get(info.module_uri orelse "") orelse {
                    try self.fail(context.location, "module `{s}` was not described", .{info.module_uri orelse ""});
                    return self.make(.dynamic);
                };
                return self.make(.{ .decl = self.modules.items[module_index].decl });
            },
            .self_module => return self.make(.{ .decl = self.modules.items[context.module].decl }),
            .alias => {
                const module_uri = info.module_uri orelse "";
                const name = info.name orelse "";
                if (std.mem.eql(u8, module_uri, "pkl:base")) return self.builtinAlias(name, context);
                const module_index = self.by_uri.get(module_uri) orelse {
                    try self.fail(context.location, "module `{s}` was not described", .{module_uri});
                    return self.make(.dynamic);
                };
                const module = &self.modules.items[module_index];
                if (module.alias_decls.get(name)) |decl| return self.make(.{ .decl = decl });
                const alias_index = module.aliases.get(name) orelse {
                    try self.fail(context.location, "type alias `{s}` was not described", .{name});
                    return self.make(.dynamic);
                };
                const alias = &module.info.aliases[alias_index];
                const env = try self.a.create(Env);
                env.* = .{ .params = alias.params, .args = info.args, .parent = null, .args_env = context.env };
                var inner = context;
                inner.env = env;
                return self.resolve(alias.referent, inner);
            },
            .nullable => {
                const inner = try self.resolve(if (info.args.len != 0) info.args[0] else unknown_type, context);
                if (inner.* == .optional) return inner;
                return self.make(.{ .optional = inner });
            },
            .@"union" => return self.resolveUnion(info.args, context, null),
            .literal => return self.resolveUnion(&.{info}, context, null),
            .function => {
                try self.fail(context.location, "function types cannot be represented in Zig bindings", .{});
                return self.make(.dynamic);
            },
            .nothing => {
                try self.fail(context.location, "the `nothing` type has no values to decode", .{});
                return self.make(.dynamic);
            },
            .unknown => {
                try self.fail(context.location, "the type of this property is not declared; declare one, using `Any` or `Dynamic` for values of any type", .{});
                return self.make(.dynamic);
            },
            .variable => {
                var step = context.env;
                while (step) |env| : (step = env.parent) {
                    for (env.params, 0..) |param, index| {
                        if (!std.mem.eql(u8, param, info.name orelse "")) continue;
                        var inner = context;
                        inner.env = env.args_env;
                        return self.resolve(if (index < env.args.len) env.args[index] else unknown_type, inner);
                    }
                }
                try self.fail(context.location, "type variable `{s}` is not bound to a type", .{info.name orelse ""});
                return self.make(.dynamic);
            },
        }
    }

    fn builtinClass(self: *Planner, name: []const u8, args: []const TypeInfo, context: Context) Error!*const Type {
        const simple = .{
            .{ "Boolean", @as(Type, .bool) },
            .{ "Int", @as(Type, .{ .int = "i64" }) },
            .{ "Float", @as(Type, .float) },
            .{ "Number", @as(Type, .float) },
            .{ "String", @as(Type, .string) },
            .{ "Duration", @as(Type, .duration) },
            .{ "DataSize", @as(Type, .data_size) },
            .{ "Regex", @as(Type, .regex) },
            .{ "Bytes", @as(Type, .bytes) },
            .{ "IntSeq", @as(Type, .int_seq) },
        };
        inline for (simple) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return self.make(entry[1]);
        }
        const arg = struct {
            fn at(list: []const TypeInfo, index: usize) TypeInfo {
                return if (index < list.len) list[index] else unknown_type;
            }
        }.at;
        if (oneOf(name, &.{ "Listing", "List", "Set", "Collection" })) {
            return self.make(.{ .slice = try self.resolve(arg(args, 0), context) });
        }
        if (oneOf(name, &.{ "Mapping", "Map" })) {
            return self.make(.{ .map = .{ try self.resolve(arg(args, 0), context), try self.resolve(arg(args, 1), context) } });
        }
        if (std.mem.eql(u8, name, "Pair")) {
            return self.make(.{ .pair = .{ try self.resolve(arg(args, 0), context), try self.resolve(arg(args, 1), context) } });
        }
        if (std.mem.eql(u8, name, "Null")) {
            try self.fail(context.location, "`Null` is only valid as part of a nullable type", .{});
            return self.make(.dynamic);
        }
        if (std.mem.startsWith(u8, name, "Function") or std.mem.eql(u8, name, "VarArgs")) {
            try self.fail(context.location, "function types cannot be represented in Zig bindings", .{});
            return self.make(.dynamic);
        }
        if (oneOf(name, &.{ "Class", "TypeAlias" })) {
            try self.fail(context.location, "`{s}` values cannot be represented in Zig bindings", .{name});
            return self.make(.dynamic);
        }
        if (oneOf(name, &.{ "Any", "Dynamic", "Typed", "Object", "Module" })) return self.make(.dynamic);
        try self.fail(context.location, "`pkl:base` class `{s}` is not supported in Zig bindings", .{name});
        return self.make(.dynamic);
    }

    fn referenceClass(self: *Planner, name: []const u8, args: []const TypeInfo, context: Context) Error!*const Type {
        if (std.mem.eql(u8, name, "Reference")) {
            const domain = try self.resolve(if (args.len > 0) args[0] else unknown_type, context);
            const referent = try self.resolve(if (args.len > 1) args[1] else unknown_type, context);
            return self.make(.{ .reference = .{ domain, referent } });
        }
        if (std.mem.eql(u8, name, "Access")) return self.make(.access);
        if (std.mem.eql(u8, name, "Domain")) return self.make(.dynamic);
        try self.fail(context.location, "`pkl:ref` class `{s}` is not supported in Zig bindings", .{name});
        return self.make(.dynamic);
    }

    fn builtinAlias(self: *Planner, name: []const u8, context: Context) Error!*const Type {
        const ints = .{
            .{ "Int8", "i8" },    .{ "Int16", "i16" },  .{ "Int32", "i32" }, .{ "UInt8", "u8" },
            .{ "UInt16", "u16" }, .{ "UInt32", "u32" }, .{ "UInt", "u64" },
        };
        inline for (ints) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return self.make(.{ .int = entry[1] });
        }
        if (oneOf(name, &.{ "Char", "Uri", "DurationUnit", "DataSizeUnit", "Charset" })) return self.make(.string);
        if (std.mem.eql(u8, name, "NonNull")) return self.make(.dynamic);
        if (std.mem.eql(u8, name, "Mixin")) {
            try self.fail(context.location, "function types cannot be represented in Zig bindings", .{});
        } else try self.fail(context.location, "`pkl:base` type alias `{s}` is not supported in Zig bindings", .{name});
        return self.make(.dynamic);
    }

    fn resolveUnion(self: *Planner, members_in: []const TypeInfo, context: Context, target: ?DeclId) Error!*const Type {
        var optional = false;
        var members: std.ArrayList(TypeInfo) = .empty;
        for (members_in) |member| {
            var current = member;
            if (current.kind == .nullable) {
                optional = true;
                current = if (current.args.len != 0) current.args[0] else unknown_type;
            }
            if (current.kind == .class and std.mem.eql(u8, current.module_uri orelse "", "pkl:base") and std.mem.eql(u8, current.name orelse "", "Null")) {
                optional = true;
                continue;
            }
            if (current.kind == .@"union") {
                try members.appendSlice(self.a, current.args);
                continue;
            }
            try members.append(self.a, current);
        }
        if (members.items.len == 0) {
            try self.fail(context.location, "a union of only `Null` has no values to decode", .{});
            return self.make(.dynamic);
        }
        const wrap = struct {
            fn apply(planner: *Planner, is_optional: bool, inner: *const Type) Error!*const Type {
                return if (is_optional and inner.* != .optional) planner.make(.{ .optional = inner }) else inner;
            }
        }.apply;
        if (members.items.len == 1 and members.items[0].kind != .literal) {
            return wrap(self, optional, try self.resolve(members.items[0], context));
        }

        const module = &self.modules.items[context.module];
        const decl = blk: {
            if (target) |existing| {
                if (!optional) break :blk existing;
                const base = try std.fmt.allocPrint(self.a, "{s}Value", .{self.decls.items[existing].name});
                break :blk try self.synthesize(context.module, try self.fresh(module, base));
            }
            break :blk try self.synthesize(context.module, try self.fresh(module, context.base));
        };

        var all_literals = true;
        for (members.items) |member| {
            if (member.kind != .literal) all_literals = false;
        }
        var used: std.StringHashMapUnmanaged(void) = .empty;
        if (all_literals) {
            const out = try self.a.alloc(Member, members.items.len);
            for (members.items, out) |member, *slot| {
                const literal = member.name orelse "";
                slot.* = .{ .name = try self.uniqueMember(&used, try literalName(self.a, literal), &enum_reserved), .literal = literal };
            }
            self.decls.items[decl].body = .{ .@"enum" = out };
        } else {
            const out = try self.a.alloc(Variant, members.items.len);
            var seen: std.StringHashMapUnmanaged([]const u8) = .empty;
            var overlapping: std.StringHashMapUnmanaged([]const u8) = .empty;
            for (members.items, out) |member, *slot| {
                const label = try self.typeLabel(member);
                if (member.kind == .literal) {
                    const literal = member.name orelse "";
                    slot.* = .{ .name = try self.uniqueMember(&used, try literalName(self.a, literal), &union_reserved), .literal = literal, .type = null, .label = label };
                    continue;
                }
                var inner = context;
                inner.base = try std.fmt.allocPrint(self.a, "{s}{s}", .{ self.decls.items[decl].name, try names.pascalCase(self.a, label) });
                const resolved = try self.resolve(member, inner);
                const key = try self.typeKey(resolved, false);
                const overlap_key = try self.typeKey(resolved, true);
                if (seen.get(key)) |other| {
                    try self.fail(context.location, "union members `{s}` and `{s}` decode to the same Zig type; Zig bindings cannot tell them apart", .{ other, label });
                } else if (overlapping.get(overlap_key)) |other| {
                    try self.fail(context.location, "union members `{s}` and `{s}` accept the same values; Zig bindings cannot tell them apart", .{ other, label });
                } else {
                    try seen.put(self.a, key, label);
                    try overlapping.put(self.a, overlap_key, label);
                }
                slot.* = .{ .name = try self.uniqueMember(&used, try names.snakeCase(self.a, label), &union_reserved), .literal = null, .type = resolved, .label = label };
            }
            self.decls.items[decl].body = .{ .@"union" = out };
        }
        const reference = try self.make(.{ .decl = decl });
        if (target) |existing| {
            if (existing != decl) self.decls.items[existing].body = .{ .alias = try self.make(.{ .optional = reference }) };
            return reference;
        }
        return wrap(self, optional, reference);
    }

    fn synthesize(self: *Planner, module_index: usize, name: []const u8) Error!DeclId {
        const decl = try self.addDecl(.{ .module = module_index, .name = name, .doc = null });
        try self.modules.items[module_index].order.append(self.a, decl);
        return decl;
    }

    fn uniqueMember(self: *Planner, used: *std.StringHashMapUnmanaged(void), base_in: []const u8, reserved: []const []const u8) Error![]const u8 {
        const base = if (isReserved(reserved, base_in)) try std.fmt.allocPrint(self.a, "{s}_", .{base_in}) else base_in;
        var candidate = base;
        var counter: usize = 2;
        while (used.contains(candidate)) : (counter += 1) {
            candidate = try std.fmt.allocPrint(self.a, "{s}_{d}", .{ base, counter });
        }
        try used.put(self.a, candidate, {});
        return candidate;
    }

    fn typeLabel(self: *Planner, info: TypeInfo) Error![]const u8 {
        return switch (info.kind) {
            .class, .alias => blk: {
                var out: std.ArrayList(u8) = .empty;
                try out.appendSlice(self.a, info.name orelse "unknown");
                for (info.args) |arg| {
                    try out.append(self.a, '_');
                    try out.appendSlice(self.a, try self.typeLabel(arg));
                }
                break :blk out.toOwnedSlice(self.a);
            },
            .module_class => blk: {
                const module_index = self.by_uri.get(info.module_uri orelse "") orelse break :blk "module";
                const module_name = self.modules.items[module_index].info.name;
                break :blk module_name[if (std.mem.lastIndexOfScalar(u8, module_name, '.')) |dot| dot + 1 else 0..];
            },
            .literal => info.name orelse "",
            .nullable => if (info.args.len != 0) self.typeLabel(info.args[0]) else "unknown",
            .self_module => "module",
            .@"union" => "union",
            .function => "function",
            .nothing => "nothing",
            .unknown => "unknown",
            .variable => info.name orelse "unknown",
        };
    }

    /// Members with equal keys decode to the same Zig type. With `overlap`,
    /// members with equal keys accept some of the same Pkl values.
    fn typeKey(self: *Planner, item: *const Type, overlap: bool) Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(self.a);
        self.writeKey(&out.writer, item, overlap) catch return error.OutOfMemory;
        return out.written();
    }

    fn writeKey(self: *Planner, writer: *std.Io.Writer, item: *const Type, overlap: bool) std.Io.Writer.Error!void {
        switch (item.*) {
            .int => |name| try writer.writeAll(if (overlap) "int" else name),
            .reference => |pair| {
                try writer.writeAll("ref(");
                try self.writeKey(writer, pair[0], overlap);
                try writer.writeByte(')');
            },
            .optional => |inner| {
                try writer.writeByte('?');
                try self.writeKey(writer, inner, overlap);
            },
            .slice => |inner| {
                try writer.writeAll("[]");
                try self.writeKey(writer, inner, overlap);
            },
            .boxed => |inner| {
                try writer.writeByte('*');
                try self.writeKey(writer, inner, overlap);
            },
            .map => |pair| {
                try writer.writeAll("map(");
                try self.writeKey(writer, pair[0], overlap);
                try writer.writeByte(',');
                try self.writeKey(writer, pair[1], overlap);
                try writer.writeByte(')');
            },
            .pair => |pair| {
                try writer.writeAll("pair(");
                try self.writeKey(writer, pair[0], overlap);
                try writer.writeByte(',');
                try self.writeKey(writer, pair[1], overlap);
                try writer.writeByte(')');
            },
            .decl => |decl| {
                const body = self.decls.items[decl].body;
                if (body == .alias) return self.writeKey(writer, body.alias, overlap);
                try writer.print("#{d}", .{decl});
            },
            .raw => |text| try writer.print("raw({s})", .{text}),
            else => try writer.writeAll(@tagName(item.*)),
        }
    }

    // Defaults.

    fn isOptional(self: *Planner, item: *const Type) bool {
        return switch (item.*) {
            .optional => true,
            .decl => |decl| switch (self.decls.items[decl].body) {
                .alias => |inner| self.isOptional(inner),
                else => false,
            },
            else => false,
        };
    }

    /// Zig source for `default` as a value of `item`, or `null` when it has
    /// no faithful Zig representation.
    fn defaultFor(self: *Planner, item: *const Type, default: ?schema.DefaultInfo) Error!?[]const u8 {
        switch (item.*) {
            .optional => |inner| {
                const found = default orelse return "null";
                if (found.kind == .null) return "null";
                return try self.defaultFor(inner, found);
            },
            .decl => |decl| {
                const found = default orelse return null;
                switch (self.decls.items[decl].body) {
                    .alias => |inner| return self.defaultFor(inner, found),
                    .@"enum" => |members| {
                        if (found.kind != .string) return null;
                        for (members) |member| {
                            if (std.mem.eql(u8, member.literal, found.text)) return try std.fmt.allocPrint(self.a, ".{f}", .{names.fmtId(member.name)});
                        }
                        return null;
                    },
                    .@"union" => |variants| {
                        if (found.kind != .string) return null;
                        for (variants) |variant| {
                            const literal = variant.literal orelse continue;
                            if (std.mem.eql(u8, literal, found.text)) return try std.fmt.allocPrint(self.a, ".{f}", .{names.fmtId(variant.name)});
                        }
                        return null;
                    },
                    else => return null,
                }
            },
            else => {},
        }
        const found = default orelse return null;
        switch (item.*) {
            .bool => {
                if (found.kind != .bool) return null;
                if (std.mem.eql(u8, found.text, "true")) return "true";
                if (std.mem.eql(u8, found.text, "false")) return "false";
                return null;
            },
            .int => |name| {
                if (found.kind != .int) return null;
                const number = std.fmt.parseInt(i128, found.text, 10) catch return null;
                if (!intFits(name, number)) return null;
                return try std.fmt.allocPrint(self.a, "{d}", .{number});
            },
            .float => {
                if (found.kind != .int and found.kind != .float) return null;
                return try floatLiteral(self.a, found.text);
            },
            .string => {
                if (found.kind != .string) return null;
                return try std.fmt.allocPrint(self.a, "\"{f}\"", .{std.zig.fmtString(found.text)});
            },
            .duration, .data_size => {
                const expected: schema.DefaultInfo.Kind = if (item.* == .duration) .duration else .data_size;
                if (found.kind != expected) return null;
                const number = try floatLiteral(self.a, found.text) orelse return null;
                return try std.fmt.allocPrint(self.a, ".{{ .value = {s}, .unit = \"{f}\" }}", .{ number, std.zig.fmtString(found.unit orelse return null) });
            },
            .slice => |inner| {
                if (found.kind != .list) return null;
                var out: std.ArrayList(u8) = .empty;
                try out.appendSlice(self.a, "&.{");
                for (found.items, 0..) |element, index| {
                    if (index != 0) try out.appendSlice(self.a, ", ");
                    try out.appendSlice(self.a, try self.defaultFor(inner, element) orelse return null);
                }
                try out.append(self.a, '}');
                return try out.toOwnedSlice(self.a);
            },
            .map => |pair| {
                if (found.kind != .map or found.items.len % 2 != 0) return null;
                var out: std.ArrayList(u8) = .empty;
                try out.appendSlice(self.a, ".{ .entries = &.{");
                var index: usize = 0;
                while (index < found.items.len) : (index += 2) {
                    if (index != 0) try out.appendSlice(self.a, ", ");
                    const key = try self.defaultFor(pair[0], found.items[index]) orelse return null;
                    const entry = try self.defaultFor(pair[1], found.items[index + 1]) orelse return null;
                    try out.print(self.a, ".{{ .key = {s}, .value = {s} }}", .{ key, entry });
                }
                try out.appendSlice(self.a, "} }");
                return try out.toOwnedSlice(self.a);
            },
            else => return null,
        }
    }

    /// Warns that a Pkl default has no Zig counterpart. Object defaults are
    /// expected (every class-typed property has one) and stay silent.
    fn reportDefault(self: *Planner, field: Field, found: schema.DefaultInfo) Error!void {
        if (containsObject(found)) return;
        if (found.kind == .failed) {
            return self.diagnostics.warn(field.location, "default value of `{s}` could not be evaluated during generation; the field has no Zig default", .{field.pkl_name});
        }
        try self.diagnostics.warn(field.location, "default value of `{s}` cannot be represented in its Zig type; the field has no Zig default", .{field.pkl_name});
    }

    // Cycles.

    fn computeCycles(self: *Planner) Error!void {
        const count = self.decls.items.len;
        const edges = try self.a.alloc([]const DeclId, count);
        for (self.decls.items, edges) |decl, *slot| {
            var out: std.ArrayList(DeclId) = .empty;
            switch (decl.body) {
                .@"struct" => |body| for (body.fields) |field| try self.byValue(&out, field.type),
                .@"union" => |variants| for (variants) |variant| {
                    if (variant.type) |item| try self.byValue(&out, item);
                },
                .alias => |item| try self.byValue(&out, item),
                else => {},
            }
            slot.* = try out.toOwnedSlice(self.a);
        }
        self.scc = try self.a.alloc(usize, count);
        var tarjan = Tarjan{
            .a = self.a,
            .edges = edges,
            .index = try self.a.alloc(?usize, count),
            .low = try self.a.alloc(usize, count),
            .on_stack = try self.a.alloc(bool, count),
            .result = self.scc,
        };
        @memset(tarjan.index, null);
        @memset(tarjan.on_stack, false);
        for (0..count) |node| {
            if (tarjan.index[node] == null) try tarjan.visit(node);
        }
        self.self_loops = try self.a.alloc(bool, count);
        for (edges, 0..) |targets, node| {
            self.self_loops[node] = std.mem.indexOfScalar(DeclId, targets, node) != null;
        }
        self.scc_size = try self.a.alloc(usize, count);
        @memset(self.scc_size, 0);
        for (self.scc) |component| self.scc_size[component] += 1;
    }

    /// Declarations stored by value in `item`. Type aliases are transparent.
    fn byValue(self: *Planner, out: *std.ArrayList(DeclId), item: *const Type) Error!void {
        switch (item.*) {
            .decl => |decl| switch (self.decls.items[decl].body) {
                .@"enum" => {},
                .alias => |inner| try self.byValue(out, inner),
                else => try out.append(self.a, decl),
            },
            .reference => |pair| try self.byValue(out, pair[0]),
            .optional => |inner| try self.byValue(out, inner),
            .pair => |pair| {
                try self.byValue(out, pair[0]);
                try self.byValue(out, pair[1]);
            },
            else => {},
        }
    }

    /// Whether a use of a type alias with body `item` inside `owner` must be
    /// written out with pointers instead of by the alias name.
    fn aliasNeedsBox(self: *Planner, owner: DeclId, item: *const Type) bool {
        return switch (item.*) {
            .decl => |id| switch (self.decls.items[id].body) {
                .alias => |inner| self.aliasNeedsBox(owner, inner),
                .@"enum" => false,
                else => self.mustBox(owner, id),
            },
            .optional => |inner| self.aliasNeedsBox(owner, inner),
            .pair => |pair| self.aliasNeedsBox(owner, pair[0]) or self.aliasNeedsBox(owner, pair[1]),
            .reference => |pair| self.aliasNeedsBox(owner, pair[0]),
            else => false,
        };
    }

    fn mustBox(self: *Planner, owner: DeclId, target: DeclId) bool {
        if (self.decls.items[target].body == .@"enum") return false;
        if (self.scc[owner] != self.scc[target]) return false;
        return owner != target or self.self_loops[owner] or self.scc_size[self.scc[owner]] > 1;
    }

    // Imports.

    fn collectImports(self: *Planner) Error!void {
        for (self.modules.items, 0..) |*module, module_index| {
            var referenced: std.AutoArrayHashMapUnmanaged(usize, void) = .empty;
            var decl_ids: std.ArrayList(DeclId) = .empty;
            try decl_ids.append(self.a, module.decl);
            try decl_ids.appendSlice(self.a, module.order.items);
            for (decl_ids.items) |decl| {
                switch (self.decls.items[decl].body) {
                    .@"struct" => |body| for (body.fields) |field| try self.noteRefs(module_index, decl, true, &referenced, field.type),
                    .@"union" => |variants| for (variants) |variant| {
                        if (variant.type) |item| try self.noteRefs(module_index, decl, true, &referenced, item);
                    },
                    .alias => |item| try self.noteRefs(module_index, null, false, &referenced, item),
                    else => {},
                }
            }
            const targets = try self.a.dupe(usize, referenced.keys());
            const sorter = struct {
                fn less(planner: *Planner, left: usize, right: usize) bool {
                    return std.mem.lessThan(u8, planner.modules.items[left].file, planner.modules.items[right].file);
                }
            };
            std.mem.sort(usize, targets, self, sorter.less);
            for (targets) |target| {
                const base = try std.fmt.allocPrint(self.a, "pkl_{s}", .{try std.mem.join(self.a, "_", self.modules.items[target].segments)});
                try module.imports.put(self.a, target, try self.fresh(module, base));
            }
        }
    }

    /// Records the modules that `writeType` refers to for `item`.
    fn noteRefs(self: *Planner, module_index: usize, owner: ?DeclId, by_value: bool, referenced: *std.AutoArrayHashMapUnmanaged(usize, void), item: *const Type) Error!void {
        switch (item.*) {
            .decl => |decl| {
                const target = self.decls.items[decl];
                if (owner != null and by_value and target.body == .alias and self.aliasNeedsBox(owner.?, target.body.alias)) {
                    return self.noteRefs(module_index, owner, true, referenced, target.body.alias);
                }
                if (target.module != module_index) {
                    try referenced.put(self.a, target.module, {});
                } else if (target.is_module) self.modules.items[module_index].uses_self = true;
            },
            .optional => |inner| try self.noteRefs(module_index, owner, by_value, referenced, inner),
            .slice, .boxed => |inner| try self.noteRefs(module_index, owner, false, referenced, inner),
            .map => |pair| {
                try self.noteRefs(module_index, owner, false, referenced, pair[0]);
                try self.noteRefs(module_index, owner, false, referenced, pair[1]);
            },
            .pair => |pair| {
                try self.noteRefs(module_index, owner, by_value, referenced, pair[0]);
                try self.noteRefs(module_index, owner, by_value, referenced, pair[1]);
            },
            .reference => |pair| {
                try self.noteRefs(module_index, owner, by_value, referenced, pair[0]);
                try self.noteRefs(module_index, owner, false, referenced, pair[1]);
            },
            else => {},
        }
    }

    // Rendering.

    fn render(self: *Planner) Error![]const File {
        var files: std.ArrayList(File) = .empty;
        for (self.modules.items, 0..) |_, module_index| {
            const text = try self.renderModule(module_index);
            try files.append(self.a, .{ .path = self.modules.items[module_index].file, .contents = try self.canonical(text, self.modules.items[module_index].file) });
        }
        const index = try self.renderIndex();
        try files.append(self.a, .{ .path = self.options.index_file, .contents = try self.canonical(index, self.options.index_file) });
        const items = try files.toOwnedSlice(self.a);
        std.mem.sort(File, items, {}, struct {
            fn less(_: void, left: File, right: File) bool {
                return std.mem.lessThan(u8, left.path, right.path);
            }
        }.less);
        return items;
    }

    fn canonical(self: *Planner, text: []const u8, path: []const u8) Error![]const u8 {
        const source = try self.a.dupeSentinel(u8, text, 0);
        var tree = try std.zig.Ast.parse(self.a, source, .{});
        if (tree.errors.len != 0) {
            try self.fail(null, "internal error: generated `{s}` does not parse", .{path});
            return text;
        }
        return tree.renderAlloc(self.a);
    }

    fn renderModule(self: *Planner, module_index: usize) Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(self.a);
        self.writeModule(&out.writer, module_index) catch return error.OutOfMemory;
        return out.written();
    }

    fn writeModule(self: *Planner, w: *std.Io.Writer, module_index: usize) (std.Io.Writer.Error || Error)!void {
        const module = &self.modules.items[module_index];
        const decl = self.decls.items[module.decl];
        try w.print(header_prefix ++ "the Pkl module `{f}`. Regenerate this file instead of editing it.\n", .{fmtComment(module.info.name)});
        if (module.info.doc) |doc| {
            try w.writeAll("//!\n");
            try writeDoc(w, "//!", doc);
        }
        try w.writeAll("\nconst std = @import(\"std\");\nconst zig_pkl = @import(\"zig_pkl\");\n");
        for (module.imports.keys(), module.imports.values()) |target, alias| {
            try w.print("const {f} = @import(\"{s}\");\n", .{ names.fmtId(alias), try self.relativeImport(module_index, target) });
        }
        if (module.uses_self) try w.writeAll("const pkl_module = @This();\n");
        const body = decl.body.@"struct";
        if (body.fields.len != 0) {
            try w.writeByte('\n');
            try self.writeFields(w, module_index, module.decl, body.fields);
            try w.writeByte('\n');
            try self.writeStructMeta(w, body.pkl_class, body.subclasses, body.fields);
            try writeHelpers(w);
            try w.writeAll(
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
            );
        }
        for (module.order.items) |id| {
            try w.writeByte('\n');
            try self.writeDecl(w, module_index, id);
        }
    }

    fn writeDecl(self: *Planner, w: *std.Io.Writer, module_index: usize, id: DeclId) (std.Io.Writer.Error || Error)!void {
        const decl = self.decls.items[id];
        if (decl.doc) |doc| try writeDoc(w, "///", doc);
        switch (decl.body) {
            .pending => {},
            .alias => |item| {
                try w.print("pub const {f} = ", .{names.fmtId(decl.name)});
                try self.writeType(w, item, module_index, null, false);
                try w.writeAll(";\n");
            },
            .@"struct" => |body| {
                try w.print("pub const {f} = struct {{\n", .{names.fmtId(decl.name)});
                try self.writeFields(w, module_index, id, body.fields);
                if (body.fields.len != 0) try w.writeByte('\n');
                try self.writeStructMeta(w, body.pkl_class, body.subclasses, body.fields);
                try writeHelpers(w);
                try w.writeAll("};\n");
            },
            .@"union" => |variants| {
                try w.print("pub const {f} = union(enum) {{\n", .{names.fmtId(decl.name)});
                var renamed = false;
                for (variants) |variant| {
                    if (variant.type) |item| {
                        try w.print("{f}: ", .{names.fmtId(variant.name)});
                        try self.writeType(w, item, module_index, id, true);
                        try w.writeAll(",\n");
                    } else {
                        try w.print("{f},\n", .{names.fmtId(variant.name)});
                        if (!std.mem.eql(u8, variant.name, variant.literal.?)) renamed = true;
                    }
                }
                if (renamed) {
                    try w.writeAll("\npub const pkl_names = .{");
                    var separator: []const u8 = " ";
                    for (variants) |variant| {
                        const literal = variant.literal orelse continue;
                        if (std.mem.eql(u8, variant.name, literal)) continue;
                        try w.print("{s}.{f} = \"{f}\"", .{ separator, names.fmtId(variant.name), std.zig.fmtString(literal) });
                        separator = ", ";
                    }
                    try w.writeAll(" };\n");
                }
                try writeHelpers(w);
                try w.writeAll("};\n");
            },
            .@"enum" => |members| {
                try w.print("pub const {f} = enum {{\n", .{names.fmtId(decl.name)});
                var renamed = false;
                for (members) |member| {
                    try w.print("{f},\n", .{names.fmtId(member.name)});
                    if (!std.mem.eql(u8, member.name, member.literal)) renamed = true;
                }
                if (renamed) {
                    try w.writeAll("\npub const pkl_names = .{");
                    var separator: []const u8 = " ";
                    for (members) |member| {
                        if (std.mem.eql(u8, member.name, member.literal)) continue;
                        try w.print("{s}.{f} = \"{f}\"", .{ separator, names.fmtId(member.name), std.zig.fmtString(member.literal) });
                        separator = ", ";
                    }
                    try w.writeAll(" };\n");
                }
                try w.writeAll("};\n");
            },
        }
    }

    fn writeFields(self: *Planner, w: *std.Io.Writer, module_index: usize, owner: DeclId, fields: []const Field) (std.Io.Writer.Error || Error)!void {
        for (fields) |field| {
            if (field.doc) |doc| try writeDoc(w, "///", doc);
            try w.print("{f}: ", .{names.fmtId(field.name)});
            const boxed = self.boxesValue(owner, field.type);
            try self.writeType(w, field.type, module_index, owner, true);
            var text: ?[]const u8 = switch (field.default) {
                .none => null,
                .null => "null",
                .absent => if (self.isOptional(field.type)) "null" else null,
                .pkl => |found| try self.defaultFor(field.type, found),
            };
            if (boxed and text != null and !std.mem.eql(u8, text.?, "null")) text = null;
            if (text) |default| {
                try w.print(" = {s}", .{default});
            } else if (field.default == .pkl) try self.reportDefault(field, field.default.pkl);
            try w.writeAll(",\n");
        }
    }

    /// Whether `writeType` stores the outermost value of `item` behind a
    /// pointer inside `owner`.
    fn boxesValue(self: *Planner, owner: DeclId, item: *const Type) bool {
        return switch (item.*) {
            .decl => |id| switch (self.decls.items[id].body) {
                .alias => |inner| self.aliasNeedsBox(owner, inner) and self.boxesValue(owner, inner),
                .@"enum" => false,
                else => self.mustBox(owner, id),
            },
            .optional => |inner| self.boxesValue(owner, inner),
            else => false,
        };
    }

    fn writeStructMeta(self: *Planner, w: *std.Io.Writer, pkl_class: []const u8, subclasses: []const []const u8, fields: []const Field) std.Io.Writer.Error!void {
        _ = self;
        try w.print("pub const pkl_class = \"{f}\";\n", .{std.zig.fmtString(pkl_class)});
        if (subclasses.len != 0) {
            try w.writeAll("pub const pkl_subclasses = [_][]const u8{");
            for (subclasses, 0..) |name, i| try w.print("{s}\"{f}\"", .{ if (i == 0) " " else ", ", std.zig.fmtString(name) });
            try w.writeAll(" };\n");
        }
        var renamed = false;
        for (fields) |field| {
            if (!std.mem.eql(u8, field.name, field.pkl_name)) renamed = true;
        }
        if (renamed) {
            try w.writeAll("pub const pkl_names = .{");
            var separator: []const u8 = " ";
            for (fields) |field| {
                if (std.mem.eql(u8, field.name, field.pkl_name)) continue;
                try w.print("{s}.{f} = \"{f}\"", .{ separator, names.fmtId(field.name), std.zig.fmtString(field.pkl_name) });
                separator = ", ";
            }
            try w.writeAll(" };\n");
        }
    }

    fn writeType(self: *Planner, w: *std.Io.Writer, item: *const Type, module_index: usize, owner: ?DeclId, by_value: bool) (std.Io.Writer.Error || Error)!void {
        switch (item.*) {
            .bool => try w.writeAll("bool"),
            .int => |name| try w.writeAll(name),
            .float => try w.writeAll("f64"),
            .string => try w.writeAll("[]const u8"),
            .duration => try w.writeAll("zig_pkl.convert.Duration"),
            .data_size => try w.writeAll("zig_pkl.convert.DataSize"),
            .regex => try w.writeAll("zig_pkl.convert.Regex"),
            .bytes => try w.writeAll("zig_pkl.convert.Bytes"),
            .int_seq => try w.writeAll("zig_pkl.convert.IntSeq"),
            .dynamic => try w.writeAll("zig_pkl.convert.Dynamic"),
            .raw => |text| try w.writeAll(text),
            .access => try w.writeAll("zig_pkl.convert.Access"),
            .reference => |pair| {
                try w.writeAll("zig_pkl.convert.Reference(");
                try self.writeType(w, pair[0], module_index, owner, by_value);
                try w.writeAll(", ");
                try self.writeType(w, pair[1], module_index, owner, false);
                try w.writeByte(')');
            },
            .optional => |inner| {
                try w.writeByte('?');
                try self.writeType(w, inner, module_index, owner, by_value);
            },
            .slice => |inner| {
                try w.writeAll("[]const ");
                try self.writeType(w, inner, module_index, owner, false);
            },
            .boxed => |inner| {
                try w.writeAll("*const ");
                try self.writeType(w, inner, module_index, owner, false);
            },
            .map => |pair| {
                try w.writeAll("zig_pkl.convert.Map(");
                try self.writeType(w, pair[0], module_index, owner, false);
                try w.writeAll(", ");
                try self.writeType(w, pair[1], module_index, owner, false);
                try w.writeByte(')');
            },
            .pair => |pair| {
                try w.writeAll("zig_pkl.convert.Pair(");
                try self.writeType(w, pair[0], module_index, owner, by_value);
                try w.writeAll(", ");
                try self.writeType(w, pair[1], module_index, owner, by_value);
                try w.writeByte(')');
            },
            .decl => |id| {
                if (owner) |container| if (by_value) switch (self.decls.items[id].body) {
                    .alias => |inner| if (self.aliasNeedsBox(container, inner)) return self.writeType(w, inner, module_index, owner, true),
                    else => if (self.mustBox(container, id)) try w.writeAll("*const "),
                };
                try self.writeReference(w, id, module_index);
            },
        }
    }

    fn writeReference(self: *Planner, w: *std.Io.Writer, id: DeclId, module_index: usize) std.Io.Writer.Error!void {
        const decl = self.decls.items[id];
        if (decl.module == module_index) {
            if (decl.is_module) return w.writeAll("pkl_module");
            return w.print("{f}", .{names.fmtId(decl.name)});
        }
        const alias = self.modules.items[module_index].imports.get(decl.module).?;
        if (decl.is_module) return w.print("{f}", .{names.fmtId(alias)});
        try w.print("{f}.{f}", .{ names.fmtId(alias), names.fmtId(decl.name) });
    }

    fn relativeImport(self: *Planner, from: usize, to: usize) Error![]const u8 {
        const source_dir = self.modules.items[from].segments;
        const target = self.modules.items[to].segments;
        const from_dirs = source_dir[0 .. source_dir.len - 1];
        var common: usize = 0;
        while (common < from_dirs.len and common < target.len - 1 and std.mem.eql(u8, from_dirs[common], target[common])) common += 1;
        var out: std.ArrayList(u8) = .empty;
        for (from_dirs[common..]) |_| try out.appendSlice(self.a, "../");
        try out.appendSlice(self.a, try std.mem.join(self.a, "/", target[common..]));
        try out.appendSlice(self.a, ".zig");
        return out.toOwnedSlice(self.a);
    }

    fn renderIndex(self: *Planner) Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(self.a);
        const w = &out.writer;
        var root = IndexNode{};
        for (self.modules.items) |module| try root.insert(self.a, module.segments, module.indexed);
        (blk: {
            w.writeAll(header_prefix ++ "every generated Pkl module. Regenerate this file instead of editing it.\n\n") catch |err| break :blk err;
            root.write(w) catch |err| break :blk err;
        }) catch return error.OutOfMemory;
        return out.written();
    }
};

const IndexNode = struct {
    file: ?[]const u8 = null,
    children: std.StringArrayHashMapUnmanaged(*IndexNode) = .empty,

    fn insert(self: *IndexNode, a: Allocator, segments: []const []const u8, file: []const u8) error{OutOfMemory}!void {
        if (segments.len == 0) {
            if (self.file == null) self.file = file;
            return;
        }
        const entry = try self.children.getOrPut(a, segments[0]);
        if (!entry.found_existing) {
            entry.value_ptr.* = try a.create(IndexNode);
            entry.value_ptr.*.* = .{};
        }
        try entry.value_ptr.*.insert(a, segments[1..], file);
    }

    fn write(self: *IndexNode, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const Sort = struct {
            keys: []const []const u8,
            pub fn lessThan(ctx: @This(), left: usize, right: usize) bool {
                return std.mem.lessThan(u8, ctx.keys[left], ctx.keys[right]);
            }
        };
        self.children.sort(Sort{ .keys = self.children.keys() });
        for (self.children.keys(), self.children.values()) |name, child| {
            if (child.file) |file| {
                try w.print("pub const {f} = @import(\"{s}\");\n", .{ names.fmtId(name), file });
            } else {
                try w.print("pub const {f} = struct {{\n", .{names.fmtId(name)});
                try child.write(w);
                try w.writeAll("};\n");
            }
        }
    }
};

const Tarjan = struct {
    a: Allocator,
    edges: []const []const DeclId,
    index: []?usize,
    low: []usize,
    on_stack: []bool,
    stack: std.ArrayList(DeclId) = .empty,
    next: usize = 0,
    components: usize = 0,
    result: []usize,

    fn visit(self: *Tarjan, node: DeclId) error{OutOfMemory}!void {
        self.index[node] = self.next;
        self.low[node] = self.next;
        self.next += 1;
        try self.stack.append(self.a, node);
        self.on_stack[node] = true;
        for (self.edges[node]) |target| {
            if (self.index[target] == null) {
                try self.visit(target);
                self.low[node] = @min(self.low[node], self.low[target]);
            } else if (self.on_stack[target]) {
                self.low[node] = @min(self.low[node], self.index[target].?);
            }
        }
        if (self.low[node] == self.index[node].?) {
            while (true) {
                const member = self.stack.pop().?;
                self.on_stack[member] = false;
                self.result[member] = self.components;
                if (member == node) break;
            }
            self.components += 1;
        }
    }
};

const unknown_type = TypeInfo{ .kind = .unknown, .module_uri = null, .name = null, .args = &.{} };

fn writeHelpers(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(
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
    );
}

fn writeDoc(w: *std.Io.Writer, prefix: []const u8, doc: []const u8) std.Io.Writer.Error!void {
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, doc, " \t\r\n"), '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        if (line.len == 0) try w.print("{s}\n", .{prefix}) else try w.print("{s} {f}\n", .{ prefix, fmtComment(line) });
    }
}

/// Formats text for a single comment line. Zig rejects control characters
/// in comments, and a line break would end the comment.
fn fmtComment(text: []const u8) std.fmt.Alt([]const u8, writeComment) {
    return .{ .data = text };
}

fn writeComment(text: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    for (text) |byte| try w.writeByte(if (byte < 0x20 or byte == 0x7f) '?' else byte);
}

/// Why `text` cannot be written verbatim as a field type, or `null` when it
/// is exactly one type expression without comments, declarations, or blocks.
fn rawTypeProblem(a: Allocator, text: []const u8) error{OutOfMemory}!?[]const u8 {
    const prefix = "const T = ";
    const source = try std.mem.concatWithSentinel(a, u8, &.{ prefix, text, ";" }, 0);
    var tree = try std.zig.Ast.parse(a, source, .{});
    defer tree.deinit(a);
    if (tree.errors.len != 0) return "it does not parse";
    const decls = tree.rootDecls();
    if (decls.len != 1) return "it does not parse as one expression";
    const var_decl = tree.fullVarDecl(decls[0]) orelse return "it does not parse as one expression";
    const init = var_decl.ast.init_node.unwrap() orelse return "it does not parse as one expression";
    const semicolon: std.zig.Ast.TokenIndex = @intCast(tree.tokens.len - 2);
    if (tree.firstToken(init) != 3 or tree.lastToken(init) + 1 != semicolon) return "it does not parse as one expression";
    var token: std.zig.Ast.TokenIndex = 2;
    while (token < semicolon) : (token += 1) {
        switch (tree.tokenTag(token)) {
            .doc_comment, .container_doc_comment => return "it contains a comment",
            else => {},
        }
        const end = tree.tokenStart(token) + tree.tokenSlice(token).len;
        const gap = source[end..tree.tokenStart(token + 1)];
        if (std.mem.trim(u8, gap, " \t\r\n").len != 0) return "it contains a comment";
    }
    for (1..tree.nodes.len) |index| {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(index));
        if (node == decls[0]) continue;
        switch (tree.nodeTag(node)) {
            .identifier,
            .field_access,
            .optional_type,
            .array_type,
            .array_type_sentinel,
            .ptr_type_aligned,
            .ptr_type_sentinel,
            .ptr_type,
            .ptr_type_bit_range,
            .error_union,
            .merge_error_sets,
            .error_set_decl,
            .anyframe_type,
            .fn_proto_simple,
            .fn_proto_multi,
            .fn_proto_one,
            .fn_proto,
            .call_one,
            .call_one_comma,
            .call,
            .call_comma,
            .builtin_call_two,
            .builtin_call_two_comma,
            .builtin_call,
            .builtin_call_comma,
            .grouped_expression,
            .number_literal,
            .char_literal,
            .string_literal,
            .enum_literal,
            .container_decl,
            .container_decl_trailing,
            .container_decl_two,
            .container_decl_two_trailing,
            .container_decl_arg,
            .container_decl_arg_trailing,
            .tagged_union,
            .tagged_union_trailing,
            .tagged_union_two,
            .tagged_union_two_trailing,
            .tagged_union_enum_tag,
            .tagged_union_enum_tag_trailing,
            .container_field_init,
            .container_field_align,
            .container_field,
            => {},
            else => return "it contains declarations, blocks, or expressions that are not types",
        }
    }
    return null;
}

fn literalName(a: Allocator, literal: []const u8) error{OutOfMemory}![]const u8 {
    if (literal.len == 0) return "empty";
    return names.snakeCase(a, literal);
}

fn isReserved(reserved: []const []const u8, name: []const u8) bool {
    for (reserved) |item| {
        if (std.mem.eql(u8, item, name)) return true;
    }
    return false;
}

fn oneOf(name: []const u8, options: []const []const u8) bool {
    return isReserved(options, name);
}

fn foldPath(allocator: Allocator, path: []const u8) error{OutOfMemory}![]const u8 {
    const copy = try allocator.alloc(u8, path.len);
    for (path, copy) |byte, *slot| slot.* = std.ascii.toLower(byte);
    return copy;
}

fn segmentsPrefix(prefix: []const []const u8, full: []const []const u8) bool {
    for (prefix, full[0..prefix.len]) |left, right| {
        if (!std.mem.eql(u8, left, right)) return false;
    }
    return true;
}

fn mappingMatches(match: []const u8, info: *const schema.ModuleInfo) bool {
    if (std.mem.indexOfScalar(u8, match, ':') != null) return std.mem.startsWith(u8, info.uri, match);
    if (std.mem.eql(u8, info.name, match)) return true;
    return std.mem.startsWith(u8, info.name, match) and info.name.len > match.len and info.name[match.len] == '.';
}

fn mappingRest(match: []const u8, info: *const schema.ModuleInfo) []const u8 {
    if (std.mem.indexOfScalar(u8, match, ':') != null) return info.uri[match.len..];
    if (info.name.len == match.len) return "";
    return info.name[match.len + 1 ..];
}

fn intFits(name: []const u8, number: i128) bool {
    const ranges = .{
        .{ "i8", i8 }, .{ "i16", i16 }, .{ "i32", i32 }, .{ "i64", i64 },
        .{ "u8", u8 }, .{ "u16", u16 }, .{ "u32", u32 }, .{ "u64", u64 },
    };
    inline for (ranges) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return number >= std.math.minInt(entry[1]) and number <= std.math.maxInt(entry[1]);
    }
    return false;
}

fn floatLiteral(a: Allocator, text: []const u8) error{OutOfMemory}!?[]const u8 {
    const number = std.fmt.parseFloat(f64, text) catch return null;
    if (std.math.isNan(number)) return "std.math.nan(f64)";
    if (std.math.isInf(number)) return if (number > 0) "std.math.inf(f64)" else "-std.math.inf(f64)";
    if (number == 0 and std.math.signbit(number)) return "-0.0";
    const magnitude = @abs(number);
    if (magnitude != 0 and (magnitude >= 1e16 or magnitude < 1e-6)) return try std.fmt.allocPrint(a, "{e}", .{number});
    const text_out = try std.fmt.allocPrint(a, "{d}", .{number});
    if (std.mem.indexOfAny(u8, text_out, ".e") != null) return text_out;
    return try std.fmt.allocPrint(a, "{s}.0", .{text_out});
}

fn containsObject(found: schema.DefaultInfo) bool {
    if (found.kind == .object) return true;
    for (found.items) |item| {
        if (containsObject(item)) return true;
    }
    return false;
}
