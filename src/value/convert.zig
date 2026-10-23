//! Allocator-owned conversions between pkl-binary values and Zig types.
//! `into` copies out of a value tree. `freeInto` releases that copy.
//!
//! Supported Zig types are `bool`, integers (range checked), floats (from
//! Pkl `Int` or `Float`), `[]const u8` (strings), slices (from `List`,
//! `Listing`, or `Set`), optionals (`null`), single-item pointers (boxed
//! values of recursive types), enums (string literals), tagged unions,
//! `Map`, `Pair`, `Duration`, `DataSize`, `Regex`, `Bytes`, `IntSeq`,
//! `Dynamic`, and structs (objects).
//!
//! Structs, enums, and unions may declare metadata:
//! - `pkl_names`: a struct literal from a Zig field or tag name to the Pkl
//!   property name or string literal, for names that differ.
//! - `pkl_class`: the qualified Pkl class name (`module#Class`, or the
//!   module name for a module class) that a struct represents.
//! - `pkl_subclasses`: qualified names of subclasses that the struct also
//!   accepts.
//!
//! A union member is chosen in this order: a `void` member whose Pkl name
//! equals the string value, a struct whose `pkl_class` is the object's class,
//! a struct whose `pkl_subclasses` lists it, the first member in declaration
//! order whose kind matches exactly (a Pkl `Int` only matches an integer
//! member, a `Float` only a float member), the first member that `matches`
//! the value, and finally a `Dynamic` member.
//!
//! `Reference(D, T)` and `Access` decode `pkl:ref` values into owned copies.

const std = @import("std");
const value = @import("value.zig");

pub const Value = value.Value;
pub const Integer = value.Integer;

pub const Error = error{
    TypeMismatch,
    MissingField,
    Overflow,
    OutOfMemory,
};

pub const Duration = struct {
    value: f64,
    unit: []const u8,
};

pub const DataSize = struct {
    value: f64,
    unit: []const u8,
};

pub const Regex = struct {
    pattern: []u8,
};

pub const Bytes = struct {
    data: []u8,
};

pub const IntSeq = struct {
    start: i64,
    end: i64,
    step: i64,
};

/// Entries of a Pkl `Map` or `Mapping`, in evaluation order.
pub fn Map(comptime K: type, comptime V: type) type {
    return struct {
        entries: []const Entry,

        const Self = @This();

        pub const Entry = struct {
            key: K,
            value: V,
        };

        pub const pkl_kind: Kind = .map;

        /// The value of the first entry whose key equals `key`. String keys
        /// compare by content; other keys use `std.meta.eql`.
        pub fn get(self: Self, key: K) ?V {
            for (self.entries) |entry| {
                if (keyEql(K, entry.key, key)) return entry.value;
            }
            return null;
        }
    };
}

/// A Pkl `Pair`.
pub fn Pair(comptime First: type, comptime Second: type) type {
    return struct {
        first: First,
        second: Second,

        pub const pkl_kind: Kind = .pair;
    };
}

/// An owned deep copy of a value whose type is not known statically, such as
/// Pkl `Any`, `Dynamic`, or `unknown`.
pub const Dynamic = struct {
    tree: value.Tree,

    pub const pkl_kind: Kind = .dynamic;

    pub fn root(self: Dynamic) *const Value {
        return self.tree.root;
    }
};

pub const ReferenceAccess = value.ReferenceAccess;

/// A `pkl:ref` `Reference<D, T>`. `T` is the referent type, kept for
/// reference only. `path` entries and `data()` point into `raw`, which owns a
/// copy of the whole reference.
pub fn Reference(comptime D: type, comptime T: type) type {
    return struct {
        domain: D,
        path: []const ReferenceAccess,
        raw: Dynamic,

        const Self = @This();

        pub const pkl_kind: Kind = .reference;
        pub const Domain = D;
        pub const Referent = T;

        pub fn data(self: Self) *const Value {
            return self.raw.root().reference.data;
        }
    };
}

/// A `pkl:ref` `Access`. `access.key` points into `raw`.
pub const Access = struct {
    access: ReferenceAccess,
    raw: Dynamic,

    pub const pkl_kind: Kind = .access;
};

pub const access_class = "pkl.ref#Access";

pub const Kind = enum { map, pair, dynamic, reference, access };

/// Comptime work per struct field or union member grows with name
/// remapping and nesting, so large generated types need more than the
/// default branch quota.
fn memberQuota(members: usize) u32 {
    return @intCast(2000 + members * 2000);
}

/// The Pkl property name or string literal for member `name` of `T`.
pub fn pklName(comptime T: type, comptime name: []const u8) []const u8 {
    if (@hasDecl(T, "pkl_names") and @hasField(@TypeOf(T.pkl_names), name)) return @field(T.pkl_names, name);
    return name;
}

/// The `pkl_class` of `T`, looking through single-item pointers.
pub fn typeClass(comptime T: type) ?[]const u8 {
    switch (@typeInfo(T)) {
        .pointer => |pointer| if (pointer.size == .one) return typeClass(pointer.child),
        .@"struct" => if (@hasDecl(T, "pkl_class")) return T.pkl_class,
        else => {},
    }
    return null;
}

/// Whether a struct `T` accepts objects of `class_name`. Structs without
/// `pkl_class` accept every class.
pub fn acceptsClass(comptime T: type, class_name: []const u8) bool {
    const class = typeClass(T) orelse return true;
    return std.mem.eql(u8, class, class_name) or inSubclasses(T, class_name);
}

fn inSubclasses(comptime T: type, class_name: []const u8) bool {
    const Target = Unboxed(T);
    if (!@hasDecl(Target, "pkl_subclasses")) return false;
    for (Target.pkl_subclasses) |subclass| {
        if (std.mem.eql(u8, subclass, class_name)) return true;
    }
    return false;
}

fn Unboxed(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| if (pointer.size == .one) Unboxed(pointer.child) else T,
        else => T,
    };
}

fn isKind(comptime T: type, comptime kind: Kind) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "pkl_kind")) return false;
    return T.pkl_kind == kind;
}

fn isPairShape(comptime T: type) bool {
    return @hasField(T, "first") and @hasField(T, "second") and @typeInfo(T).@"struct".field_names.len == 2;
}

fn keyEql(comptime K: type, left: K, right: K) bool {
    switch (@typeInfo(K)) {
        .pointer => |pointer| if (pointer.size == .slice and pointer.child == u8) return std.mem.eql(u8, left, right),
        else => {},
    }
    return std.meta.eql(left, right);
}

/// Whether `tree` has the shape of `T`. Collections are checked element by
/// element and objects by class; struct fields are not inspected.
pub fn matches(comptime T: type, tree: *const Value) bool {
    return matchesKind(T, tree, false);
}

/// Like `matches`, but a float member does not accept a Pkl `Int`.
fn matchesKind(comptime T: type, tree: *const Value, comptime exact: bool) bool {
    const recurse = struct {
        fn at(comptime Child: type, child: *const Value) bool {
            return matchesKind(Child, child, exact);
        }
    }.at;
    switch (@typeInfo(T)) {
        .optional => |optional| return tree.* == .nil or recurse(optional.child, tree),
        .bool => return tree.* == .boolean,
        .int => return tree.* == .int and fitsInt(T, tree.int),
        .float => return tree.* == .float or (!exact and tree.* == .int),
        .@"enum" => return tree.* == .string and enumFromName(T, tree.string) != null,
        .@"union" => |info| {
            @setEvalBranchQuota(comptime memberQuota(info.field_names.len));
            inline for (info.field_names, info.field_types) |name, field_type| {
                if (field_type == void) {
                    if (tree.* == .string and std.mem.eql(u8, tree.string, pklName(T, name))) return true;
                } else if (recurse(field_type, tree)) return true;
            }
            return false;
        },
        .pointer => |pointer| switch (pointer.size) {
            .one => return recurse(pointer.child, tree),
            .slice => {
                if (pointer.child == u8) return tree.* == .string;
                const items = switch (tree.*) {
                    .list, .listing, .set => |items| items,
                    else => return false,
                };
                for (items) |item| {
                    if (!recurse(pointer.child, item)) return false;
                }
                return true;
            },
            else => return false,
        },
        .@"struct" => {
            if (T == Duration) return tree.* == .duration;
            if (T == DataSize) return tree.* == .data_size;
            if (T == Regex) return tree.* == .regex;
            if (T == Bytes) return tree.* == .bytes;
            if (T == IntSeq) return tree.* == .int_seq;
            if (comptime isKind(T, .dynamic)) return true;
            if (comptime isKind(T, .reference)) return tree.* == .reference and recurse(T.Domain, tree.reference.domain);
            if (comptime isKind(T, .access)) return isAccess(tree);
            if (comptime isKind(T, .map)) {
                const entries = switch (tree.*) {
                    .map, .mapping => |entries| entries,
                    else => return false,
                };
                for (entries) |entry| {
                    if (!recurse(@FieldType(T.Entry, "key"), entry.key)) return false;
                    if (!recurse(@FieldType(T.Entry, "value"), entry.value)) return false;
                }
                return true;
            }
            if (comptime isKind(T, .pair)) {
                return tree.* == .pair and
                    recurse(@FieldType(T, "first"), tree.pair.first) and
                    recurse(@FieldType(T, "second"), tree.pair.second);
            }
            if (tree.* != .object) return false;
            return acceptsClass(T, tree.object.class_name);
        },
        else => return false,
    }
}

pub fn into(comptime T: type, allocator: std.mem.Allocator, tree: *const Value) Error!T {
    switch (@typeInfo(T)) {
        .optional => |optional| {
            if (tree.* == .nil) return null;
            return try into(optional.child, allocator, tree);
        },
        .bool => {
            if (tree.* != .boolean) return error.TypeMismatch;
            return tree.boolean;
        },
        .int => return integerTo(T, switch (tree.*) {
            .int => |item| item,
            else => return error.TypeMismatch,
        }),
        .float => switch (tree.*) {
            .float => |item| return @floatCast(item),
            .int => |item| switch (item) {
                .signed => |number| return @floatFromInt(number),
                .unsigned => |number| return @floatFromInt(number),
            },
            else => return error.TypeMismatch,
        },
        .@"enum" => {
            if (tree.* != .string) return error.TypeMismatch;
            return enumFromName(T, tree.string) orelse error.TypeMismatch;
        },
        .@"union" => return intoUnion(T, allocator, tree),
        .pointer => |pointer| {
            if (pointer.size == .one) {
                const child = try allocator.create(pointer.child);
                errdefer allocator.destroy(child);
                child.* = try into(pointer.child, allocator, tree);
                return child;
            }
            if (pointer.size != .slice) @compileError("only slices and single-item pointers can be decoded");
            if (pointer.child == u8) {
                const bytes = switch (tree.*) {
                    .string, .regex => |item| item,
                    .bytes => |item| item,
                    else => return error.TypeMismatch,
                };
                if (comptime pointer.sentinel()) |sentinel| return try allocator.dupeSentinel(u8, bytes, sentinel);
                return try allocator.dupe(u8, bytes);
            }
            const items = switch (tree.*) {
                .list => |list| list,
                .listing => |list| list,
                .set => |list| list,
                else => return error.TypeMismatch,
            };
            const out = try allocator.alloc(pointer.child, items.len);
            var filled: usize = 0;
            errdefer {
                for (out[0..filled]) |item| freeInto(pointer.child, allocator, item);
                allocator.free(out);
            }
            for (items, 0..) |item, index| {
                out[index] = try into(pointer.child, allocator, item);
                filled += 1;
            }
            return out;
        },
        .@"struct" => {
            if (T == Duration) return intoQuantity(Duration, allocator, tree, .duration);
            if (T == DataSize) return intoQuantity(DataSize, allocator, tree, .data_size);
            if (T == Regex) {
                if (tree.* != .regex) return error.TypeMismatch;
                return .{ .pattern = try allocator.dupe(u8, tree.regex) };
            }
            if (T == Bytes) {
                if (tree.* != .bytes) return error.TypeMismatch;
                return .{ .data = try allocator.dupe(u8, tree.bytes) };
            }
            if (T == IntSeq) {
                if (tree.* != .int_seq) return error.TypeMismatch;
                return .{
                    .start = try integerTo(i64, tree.int_seq.start),
                    .end = try integerTo(i64, tree.int_seq.end),
                    .step = try integerTo(i64, tree.int_seq.step),
                };
            }
            if (comptime isKind(T, .map)) return intoMap(T, allocator, tree);
            if (comptime isKind(T, .dynamic)) return .{ .tree = try value.clone(allocator, tree) };
            if (comptime isKind(T, .reference)) return intoReference(T, allocator, tree);
            if (comptime isKind(T, .access)) {
                if (!isAccess(tree)) return error.TypeMismatch;
                var raw = Dynamic{ .tree = try value.clone(allocator, tree) };
                errdefer raw.tree.deinit();
                return .{ .access = try ReferenceAccess.parse(raw.root()), .raw = raw };
            }
            if (comptime isKind(T, .pair)) {
                if (tree.* != .pair) return error.TypeMismatch;
            }
            if (comptime isPairShape(T)) {
                if (tree.* == .pair) {
                    var result: T = undefined;
                    result.first = try into(@FieldType(T, "first"), allocator, tree.pair.first);
                    errdefer freeInto(@FieldType(T, "first"), allocator, result.first);
                    result.second = try into(@FieldType(T, "second"), allocator, tree.pair.second);
                    return result;
                }
            }
            if (tree.* != .object) return error.TypeMismatch;
            return intoObject(T, allocator, tree);
        },
        else => @compileError("unsupported conversion type " ++ @typeName(T)),
    }
}

pub fn freeInto(comptime T: type, allocator: std.mem.Allocator, item: T) void {
    switch (@typeInfo(T)) {
        .optional => if (item) |child| freeInto(@TypeOf(child), allocator, child),
        .pointer => |pointer| switch (pointer.size) {
            .one => {
                freeInto(pointer.child, allocator, item.*);
                allocator.destroy(item);
            },
            .slice => {
                if (pointer.child != u8) {
                    for (item) |child| freeInto(pointer.child, allocator, child);
                }
                allocator.free(item);
            },
            else => {},
        },
        .@"union" => |info| {
            @setEvalBranchQuota(comptime memberQuota(info.field_names.len));
            if (info.tag_type == null) return;
            switch (item) {
                inline else => |payload| freeInto(@TypeOf(payload), allocator, payload),
            }
        },
        .@"struct" => {
            if (comptime isKind(T, .dynamic)) {
                var tree = item.tree;
                tree.deinit();
                return;
            }
            if (comptime isKind(T, .reference)) {
                freeInto(T.Domain, allocator, item.domain);
                allocator.free(item.path);
                freeInto(Dynamic, allocator, item.raw);
                return;
            }
            if (comptime isKind(T, .access)) return freeInto(Dynamic, allocator, item.raw);
            const info = @typeInfo(T).@"struct";
            @setEvalBranchQuota(comptime memberQuota(info.field_names.len));
            inline for (info.field_names, info.field_types) |name, field_type| {
                freeInto(field_type, allocator, @field(item, name));
            }
        },
        else => {},
    }
}

pub fn from(comptime T: type, allocator: std.mem.Allocator, input: T) (Error || value.Error)!value.Tree {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = .init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    const decoded = try fromValue(arena.allocator(), T, input);
    const root = try arena.allocator().create(Value);
    root.* = decoded;
    return .{
        .arena = arena,
        .root = root,
        .bytes_read = 0,
    };
}

fn intoObject(comptime T: type, allocator: std.mem.Allocator, tree: *const Value) Error!T {
    const info = @typeInfo(T).@"struct";
    @setEvalBranchQuota(comptime memberQuota(info.field_names.len));
    var result: T = undefined;
    var seen = std.mem.zeroes([info.field_names.len]bool);
    errdefer inline for (info.field_names, info.field_types, 0..) |name, field_type, index| {
        if (seen[index]) freeInto(field_type, allocator, @field(result, name));
    };
    inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, field_type, attrs, index| {
        if (value.findProperty(tree, comptime pklName(T, name))) |property| {
            @field(result, name) = try into(field_type, allocator, property);
            seen[index] = true;
        } else if (@typeInfo(field_type) == .optional) {
            @field(result, name) = null;
            seen[index] = true;
        } else if (attrs.defaultValue(field_type)) |default| {
            if (ownsMemory(field_type)) return error.MissingField;
            @field(result, name) = default;
            seen[index] = true;
        } else return error.MissingField;
    }
    return result;
}

fn intoQuantity(comptime T: type, allocator: std.mem.Allocator, tree: *const Value, tag: std.meta.Tag(Value)) Error!T {
    if (std.meta.activeTag(tree.*) != tag) return error.TypeMismatch;
    const quantity = switch (tag) {
        .duration => tree.duration,
        .data_size => tree.data_size,
        else => unreachable,
    };
    return .{
        .value = quantity.value,
        .unit = try allocator.dupe(u8, quantity.unit),
    };
}

fn fromValue(allocator: std.mem.Allocator, comptime T: type, input: T) Error!Value {
    switch (@typeInfo(T)) {
        .optional => |optional| {
            if (input) |child| return fromValue(allocator, optional.child, child);
            return .nil;
        },
        .bool => return .{ .boolean = input },
        .int => {
            if (std.math.cast(i64, input)) |signed| return .{ .int = Integer.fromSigned(signed) };
            return .{ .int = .{ .unsigned = std.math.cast(u64, input) orelse return error.Overflow } };
        },
        .float => return .{ .float = @floatCast(input) },
        .@"enum" => return .{ .string = try allocator.dupe(u8, enumName(T, input)) },
        .@"union" => |info| {
            @setEvalBranchQuota(comptime memberQuota(info.field_names.len));
            if (info.tag_type == null) @compileError("only tagged unions can be encoded");
            switch (input) {
                inline else => |payload, tag| {
                    if (@TypeOf(payload) == void) return .{ .string = try allocator.dupe(u8, pklName(T, @tagName(tag))) };
                    return fromValue(allocator, @TypeOf(payload), payload);
                },
            }
        },
        .pointer => |pointer| {
            if (pointer.size == .one) return fromValue(allocator, pointer.child, input.*);
            if (pointer.size != .slice) @compileError("only slices and single-item pointers can be encoded");
            if (pointer.child == u8) return .{ .string = try allocator.dupe(u8, input) };
            const items = try allocator.alloc(*Value, input.len);
            for (input, 0..) |item, index| {
                items[index] = try store(allocator, try fromValue(allocator, pointer.child, item));
            }
            return .{ .list = items };
        },
        .@"struct" => {
            if (T == Duration) return .{ .duration = .{ .value = input.value, .unit = try allocator.dupe(u8, input.unit) } };
            if (T == DataSize) return .{ .data_size = .{ .value = input.value, .unit = try allocator.dupe(u8, input.unit) } };
            if (T == Regex) return .{ .regex = try allocator.dupe(u8, input.pattern) };
            if (T == Bytes) return .{ .bytes = try allocator.dupe(u8, input.data) };
            if (T == IntSeq) return .{ .int_seq = .{
                .start = Integer.fromSigned(input.start),
                .end = Integer.fromSigned(input.end),
                .step = Integer.fromSigned(input.step),
            } };
            if (comptime isKind(T, .dynamic)) return (try value.cloneInto(allocator, input.root())).*;
            if (comptime isKind(T, .access)) return (try value.cloneInto(allocator, input.raw.root())).*;
            if (comptime isKind(T, .reference)) {
                const original = input.raw.root().reference;
                const path = try allocator.alloc(*Value, original.path.len);
                for (original.path, path) |access, *slot| slot.* = try value.cloneInto(allocator, access);
                return .{ .reference = .{
                    .domain = try store(allocator, try fromValue(allocator, T.Domain, input.domain)),
                    .data = try value.cloneInto(allocator, original.data),
                    .path = path,
                } };
            }
            if (comptime isKind(T, .map)) {
                const entries = try allocator.alloc(value.Entry, input.entries.len);
                for (input.entries, entries) |entry, *slot| {
                    slot.* = .{
                        .key = try store(allocator, try fromValue(allocator, @FieldType(T.Entry, "key"), entry.key)),
                        .value = try store(allocator, try fromValue(allocator, @FieldType(T.Entry, "value"), entry.value)),
                    };
                }
                return .{ .map = entries };
            }
            if (comptime isKind(T, .pair)) return .{ .pair = .{
                .first = try store(allocator, try fromValue(allocator, @FieldType(T, "first"), input.first)),
                .second = try store(allocator, try fromValue(allocator, @FieldType(T, "second"), input.second)),
            } };
            var members: std.ArrayList(value.Member) = .empty;
            const info = @typeInfo(T).@"struct";
            @setEvalBranchQuota(comptime memberQuota(info.field_names.len));
            inline for (info.field_names, info.field_types) |name, field_type| {
                const child = try store(allocator, try fromValue(allocator, field_type, @field(input, name)));
                try members.append(allocator, .{ .property = .{ .name = comptime pklName(T, name), .value = child } });
            }
            const class = comptime typeClass(T);
            return .{ .object = .{
                .class_name = class orelse "Dynamic",
                .module_uri = if (class == null) "pkl:base" else "",
                .members = try members.toOwnedSlice(allocator),
            } };
        },
        else => @compileError("unsupported conversion type " ++ @typeName(T)),
    }
}

fn store(allocator: std.mem.Allocator, item: Value) Error!*Value {
    const ptr = try allocator.create(Value);
    ptr.* = item;
    return ptr;
}

fn integerTo(comptime T: type, integer: Integer) Error!T {
    switch (integer) {
        .signed => |number| {
            if (number < std.math.minInt(T) or number > std.math.maxInt(T)) return error.Overflow;
            return @intCast(number);
        },
        .unsigned => |number| {
            if (number > std.math.maxInt(T)) return error.Overflow;
            return @intCast(number);
        },
    }
}

fn intoUnion(comptime T: type, allocator: std.mem.Allocator, tree: *const Value) Error!T {
    const info = @typeInfo(T).@"union";
    @setEvalBranchQuota(comptime memberQuota(info.field_names.len));
    if (info.tag_type == null) @compileError("only tagged unions can be decoded");
    if (tree.* == .string) {
        inline for (info.field_names, info.field_types) |name, field_type| {
            if (field_type == void and std.mem.eql(u8, tree.string, pklName(T, name))) return @unionInit(T, name, {});
        }
    }
    if (tree.* == .object) {
        const class_name = tree.object.class_name;
        inline for (info.field_names, info.field_types) |name, field_type| {
            if (comptime typeClass(field_type)) |class| {
                if (std.mem.eql(u8, class, class_name)) return @unionInit(T, name, try into(field_type, allocator, tree));
            }
        }
        inline for (info.field_names, info.field_types) |name, field_type| {
            if (comptime typeClass(field_type) != null) {
                if (inSubclasses(field_type, class_name)) return @unionInit(T, name, try into(field_type, allocator, tree));
            }
        }
    }
    inline for (.{ true, false }) |exact| {
        inline for (info.field_names, info.field_types) |name, field_type| {
            if (comptime field_type != void and !isKind(Unboxed(field_type), .dynamic)) {
                if (matchesKind(field_type, tree, exact)) return @unionInit(T, name, try into(field_type, allocator, tree));
            }
        }
    }
    inline for (info.field_names, info.field_types) |name, field_type| {
        if (comptime isKind(Unboxed(field_type), .dynamic)) return @unionInit(T, name, try into(field_type, allocator, tree));
    }
    return error.TypeMismatch;
}

fn isAccess(tree: *const Value) bool {
    return tree.* == .object and std.mem.eql(u8, tree.object.class_name, access_class);
}

fn intoReference(comptime T: type, allocator: std.mem.Allocator, tree: *const Value) Error!T {
    if (tree.* != .reference) return error.TypeMismatch;
    var raw = Dynamic{ .tree = try value.clone(allocator, tree) };
    errdefer raw.tree.deinit();
    const copy = raw.root().reference;
    const path = try allocator.alloc(ReferenceAccess, copy.path.len);
    errdefer allocator.free(path);
    for (copy.path, path) |access, *slot| slot.* = try ReferenceAccess.parse(access);
    return .{ .domain = try into(T.Domain, allocator, copy.domain), .path = path, .raw = raw };
}

fn intoMap(comptime T: type, allocator: std.mem.Allocator, tree: *const Value) Error!T {
    const entries = switch (tree.*) {
        .map, .mapping => |entries| entries,
        else => return error.TypeMismatch,
    };
    const Key = @FieldType(T.Entry, "key");
    const Item = @FieldType(T.Entry, "value");
    const out = try allocator.alloc(T.Entry, entries.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |entry| freeInto(T.Entry, allocator, entry);
        allocator.free(out);
    }
    for (entries, out) |entry, *slot| {
        const key = try into(Key, allocator, entry.key);
        errdefer freeInto(Key, allocator, key);
        slot.* = .{ .key = key, .value = try into(Item, allocator, entry.value) };
        filled += 1;
    }
    return .{ .entries = out };
}

fn enumFromName(comptime T: type, text: []const u8) ?T {
    @setEvalBranchQuota(comptime memberQuota(@typeInfo(T).@"enum".field_names.len));
    inline for (@typeInfo(T).@"enum".field_names) |name| {
        if (std.mem.eql(u8, pklName(T, name), text)) return @field(T, name);
    }
    return null;
}

fn enumName(comptime T: type, item: T) []const u8 {
    switch (item) {
        inline else => |tag| return comptime pklName(T, @tagName(tag)),
    }
}

fn fitsInt(comptime T: type, integer: Integer) bool {
    _ = integerTo(T, integer) catch return false;
    return true;
}

fn ownsMemory(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => true,
        .optional => |optional| ownsMemory(optional.child),
        .@"union" => {
            inline for (@typeInfo(T).@"union".field_types) |field_type| {
                if (ownsMemory(field_type)) return true;
            }
            return false;
        },
        .@"struct" => {
            inline for (@typeInfo(T).@"struct".field_types) |field_type| {
                if (ownsMemory(field_type)) return true;
            }
            return false;
        },
        else => false,
    };
}

test "typed objects, lists, durations, and bytes round-trip without leaks" {
    const allocator = std.testing.allocator;
    const Config = struct {
        name: []u8,
        port: u16,
        enabled: ?bool = null,
        retries: i32 = 3,
    };
    const input = Config{
        .name = @constCast("api"),
        .port = 8080,
        .enabled = true,
        .retries = 3,
    };
    var tree = try from(Config, allocator, input);
    defer tree.deinit();
    const decoded = try into(Config, allocator, tree.root);
    defer freeInto(Config, allocator, decoded);
    try std.testing.expectEqualStrings("api", decoded.name);
    try std.testing.expectEqual(@as(u16, 8080), decoded.port);
    try std.testing.expectEqual(true, decoded.enabled.?);

    const duration = Duration{ .value = 1.5, .unit = @constCast("min") };
    var duration_tree = try from(Duration, allocator, duration);
    defer duration_tree.deinit();
    const duration_out = try into(Duration, allocator, duration_tree.root);
    defer freeInto(Duration, allocator, duration_out);
    try std.testing.expectEqualStrings("min", duration_out.unit);

    const bytes = Bytes{ .data = @constCast("\x00\xff") };
    var bytes_tree = try from(Bytes, allocator, bytes);
    defer bytes_tree.deinit();
    try std.testing.expect(bytes_tree.root.* == .bytes);
    const bytes_out = try into(Bytes, allocator, bytes_tree.root);
    defer freeInto(Bytes, allocator, bytes_out);
    try std.testing.expectEqualSlices(u8, "\x00\xff", bytes_out.data);

    const numbers = [_]i64{ 1, 2, 3 };
    var list_tree = try from([]const i64, allocator, &numbers);
    defer list_tree.deinit();
    const list_out = try into([]i64, allocator, list_tree.root);
    defer freeInto([]i64, allocator, list_out);
    try std.testing.expectEqualSlices(i64, &numbers, list_out);
}

const TestRegion = enum {
    us_east,
    eu,

    pub const pkl_names = .{ .us_east = "us-east" };
};

const TestShape = union(enum) {
    auto,
    size: u16,
    label: []const u8,
    point: TestPoint,
    dynamic: Dynamic,

    pub const pkl_names = .{ .auto = "auto" };
};

const TestPoint = struct {
    x: i64,
    y_axis: i64 = 0,

    pub const pkl_class = "test#Point";
    pub const pkl_names = .{ .y_axis = "yAxis" };
};

const TestNode = struct {
    label: []const u8,
    next: ?*const TestNode,
    children: []const TestNode,
};

const TestAnimal = union(enum) {
    dog: TestDog,
    puppy: TestPuppy,
};

const TestDog = struct {
    name: []const u8,

    pub const pkl_class = "test#Dog";
    pub const pkl_subclasses = [_][]const u8{"test#Puppy"};
};

const TestPuppy = struct {
    name: []const u8,
    age: i64,

    pub const pkl_class = "test#Puppy";
};

fn testObject(allocator: std.mem.Allocator, class_name: []const u8, names: []const []const u8, values: []const Value) !*Value {
    const members = try allocator.alloc(value.Member, names.len);
    for (names, values, members) |name, item, *member| {
        const child = try allocator.create(Value);
        child.* = item;
        member.* = .{ .property = .{ .name = name, .value = child } };
    }
    const result = try allocator.create(Value);
    result.* = .{ .object = .{ .class_name = class_name, .module_uri = "file:///test.pkl", .members = members } };
    return result;
}

test "enums decode through their pkl names" {
    const allocator = std.testing.allocator;
    var region = Value{ .string = "us-east" };
    try std.testing.expectEqual(TestRegion.us_east, try into(TestRegion, allocator, &region));
    var plain = Value{ .string = "eu" };
    try std.testing.expectEqual(TestRegion.eu, try into(TestRegion, allocator, &plain));
    var unknown = Value{ .string = "us_east" };
    try std.testing.expectError(error.TypeMismatch, into(TestRegion, allocator, &unknown));

    var tree = try from(TestRegion, allocator, .us_east);
    defer tree.deinit();
    try std.testing.expectEqualStrings("us-east", tree.root.string);
}

test "tagged unions pick the first matching member" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const allocator = std.testing.allocator;

    var auto = Value{ .string = "auto" };
    try std.testing.expect(try into(TestShape, allocator, &auto) == .auto);

    var number = Value{ .int = Integer.fromSigned(80) };
    try std.testing.expectEqual(@as(u16, 80), (try into(TestShape, allocator, &number)).size);

    var too_big = Value{ .int = Integer.fromSigned(70_000) };
    const fallback = try into(TestShape, allocator, &too_big);
    defer freeInto(TestShape, allocator, fallback);
    try std.testing.expect(fallback.dynamic.root().int.eql(Integer.fromSigned(70_000)));
    try std.testing.expectError(error.TypeMismatch, into(TestAnimal, allocator, &too_big));

    var text = Value{ .string = "wide" };
    const label = try into(TestShape, allocator, &text);
    defer freeInto(TestShape, allocator, label);
    try std.testing.expectEqualStrings("wide", label.label);

    const point = try testObject(arena, "test#Point", &.{ "x", "yAxis" }, &.{
        .{ .int = Integer.fromSigned(1) },
        .{ .int = Integer.fromSigned(2) },
    });
    const decoded_point = try into(TestShape, allocator, point);
    try std.testing.expectEqual(@as(i64, 2), decoded_point.point.y_axis);

    const other = try testObject(arena, "test#Other", &.{"x"}, &.{.{ .int = Integer.fromSigned(1) }});
    var dynamic = try into(TestShape, allocator, other);
    defer freeInto(TestShape, allocator, dynamic);
    try std.testing.expectEqualStrings("test#Other", dynamic.dynamic.root().object.class_name);

    var flag = Value{ .boolean = true };
    const flagged = try into(TestShape, allocator, &flag);
    defer freeInto(TestShape, allocator, flagged);
    try std.testing.expect(flagged.dynamic.root().boolean);
}

test "class members prefer the exact class before subclasses" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const allocator = std.testing.allocator;

    const puppy = try testObject(arena, "test#Puppy", &.{ "name", "age" }, &.{
        .{ .string = "rex" },
        .{ .int = Integer.fromSigned(1) },
    });
    const decoded = try into(TestAnimal, allocator, puppy);
    defer freeInto(TestAnimal, allocator, decoded);
    try std.testing.expectEqual(@as(i64, 1), decoded.puppy.age);

    const dog = try testObject(arena, "test#Dog", &.{"name"}, &.{.{ .string = "ace" }});
    const decoded_dog = try into(TestAnimal, allocator, dog);
    defer freeInto(TestAnimal, allocator, decoded_dog);
    try std.testing.expectEqualStrings("ace", decoded_dog.dog.name);

    const cat = try testObject(arena, "test#Cat", &.{"name"}, &.{.{ .string = "tom" }});
    try std.testing.expectError(error.TypeMismatch, into(TestAnimal, allocator, cat));

    try std.testing.expectEqualStrings("test#Dog", typeClass(TestDog).?);
    try std.testing.expect(acceptsClass(TestDog, "test#Puppy"));
    try std.testing.expect(!acceptsClass(TestPuppy, "test#Dog"));
}

test "struct fields map to pkl property names" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const point = try testObject(arena_state.allocator(), "test#Point", &.{ "x", "yAxis" }, &.{
        .{ .int = Integer.fromSigned(4) },
        .{ .int = Integer.fromSigned(5) },
    });
    const decoded = try into(TestPoint, std.testing.allocator, point);
    try std.testing.expectEqual(@as(i64, 5), decoded.y_axis);

    var tree = try from(TestPoint, std.testing.allocator, decoded);
    defer tree.deinit();
    try std.testing.expectEqualStrings("test#Point", tree.root.object.class_name);
    try std.testing.expect(value.findProperty(tree.root, "yAxis") != null);
    try std.testing.expect(value.findProperty(tree.root, "y_axis") == null);
}

test "recursive structs decode through boxed pointers and slices" {
    const allocator = std.testing.allocator;
    const leaf = TestNode{ .label = "leaf", .next = null, .children = &.{} };
    const middle = TestNode{ .label = "middle", .next = &leaf, .children = &.{leaf} };
    const root = TestNode{ .label = "root", .next = &middle, .children = &.{ middle, leaf } };
    var tree = try from(TestNode, allocator, root);
    defer tree.deinit();
    const decoded = try into(TestNode, allocator, tree.root);
    defer freeInto(TestNode, allocator, decoded);
    try std.testing.expectEqualStrings("leaf", decoded.next.?.next.?.label);
    try std.testing.expect(decoded.next.?.next.?.next == null);
    try std.testing.expectEqualStrings("leaf", decoded.children[0].children[0].label);
    try std.testing.checkAllAllocationFailures(allocator, DecodeAndFree(TestNode).run, .{tree.root});
}

test "maps keep entry order and pairs decode both sides" {
    const allocator = std.testing.allocator;
    const Ports = Map([]const u8, u16);
    const entries = [_]Ports.Entry{
        .{ .key = "http", .value = 80 },
        .{ .key = "https", .value = 443 },
    };
    var tree = try from(Ports, allocator, .{ .entries = &entries });
    defer tree.deinit();
    try std.testing.expect(tree.root.* == .map);
    const map_entries = tree.root.map;
    tree.root.* = .{ .mapping = map_entries };
    const decoded = try into(Ports, allocator, tree.root);
    defer freeInto(Ports, allocator, decoded);
    try std.testing.expectEqual(@as(usize, 2), decoded.entries.len);
    try std.testing.expectEqualStrings("http", decoded.entries[0].key);
    try std.testing.expectEqual(@as(?u16, 443), decoded.get("https"));
    try std.testing.expectEqual(@as(?u16, null), decoded.get("ftp"));
    try std.testing.checkAllAllocationFailures(allocator, DecodeAndFree(Ports).run, .{tree.root});

    const Named = Pair([]const u8, i64);
    var pair_tree = try from(Named, allocator, .{ .first = "n", .second = 3 });
    defer pair_tree.deinit();
    const pair = try into(Named, allocator, pair_tree.root);
    defer freeInto(Named, allocator, pair);
    try std.testing.expectEqualStrings("n", pair.first);
    try std.testing.expectEqual(@as(i64, 3), pair.second);
}

test "dynamic values own a deep copy" {
    const allocator = std.testing.allocator;
    var one = Value{ .int = Integer.fromSigned(1) };
    var text = Value{ .string = "x" };
    var items = [_]*Value{ &one, &text };
    var list = Value{ .listing = &items };
    const copy = try into(Dynamic, allocator, &list);
    text.string = "changed";
    defer freeInto(Dynamic, allocator, copy);
    try std.testing.expectEqualStrings("x", copy.root().listing[1].string);
    try std.testing.checkAllAllocationFailures(allocator, DecodeAndFree(Dynamic).run, .{&list});

    var tree = try from(Dynamic, allocator, copy);
    defer tree.deinit();
    try std.testing.expect(value.eql(copy.root(), tree.root));
}

test "unions free the active member when a later field fails" {
    const allocator = std.testing.allocator;
    const Holder = struct { shape: TestShape, count: u8 };
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const holder = try testObject(arena_state.allocator(), "test#Holder", &.{ "shape", "count" }, &.{
        .{ .string = "label" },
        .{ .int = Integer.fromSigned(300) },
    });
    try std.testing.expectError(error.Overflow, into(Holder, allocator, holder));
}

fn DecodeAndFree(comptime T: type) type {
    return struct {
        fn run(allocator: std.mem.Allocator, tree: *const Value) !void {
            const decoded = try into(T, allocator, tree);
            freeInto(T, allocator, decoded);
        }
    };
}

test "numeric unions tell integers from floats in either member order" {
    const allocator = std.testing.allocator;
    const FloatFirst = union(enum) { float: f64, int: i64 };
    const IntFirst = union(enum) { int: i64, float: f64 };
    var whole = Value{ .int = Integer.fromSigned(3) };
    var fraction = Value{ .float = 2.5 };
    inline for (.{ FloatFirst, IntFirst }) |Number| {
        const decoded_whole = try into(Number, allocator, &whole);
        try std.testing.expect(decoded_whole == .int);
        try std.testing.expectEqual(@as(i64, 3), decoded_whole.int);
        const decoded_fraction = try into(Number, allocator, &fraction);
        try std.testing.expect(decoded_fraction == .float);
        try std.testing.expectEqual(@as(f64, 2.5), decoded_fraction.float);
    }
    const FloatOrText = union(enum) { float: f64, text: []const u8 };
    try std.testing.expectEqual(@as(f64, 3), (try into(FloatOrText, allocator, &whole)).float);

    const Lists = union(enum) { floats: []const f64, ints: []const i64 };
    var one = Value{ .int = Integer.fromSigned(1) };
    var items = [_]*Value{&one};
    var list = Value{ .list = &items };
    const decoded_list = try into(Lists, allocator, &list);
    defer freeInto(Lists, allocator, decoded_list);
    try std.testing.expect(decoded_list == .ints);
}

test "string literal members take priority over string members" {
    const allocator = std.testing.allocator;
    const Choice = union(enum) { text: []const u8, auto };
    var auto = Value{ .string = "auto" };
    try std.testing.expect(try into(Choice, allocator, &auto) == .auto);
    var other = Value{ .string = "fixed" };
    const decoded = try into(Choice, allocator, &other);
    defer freeInto(Choice, allocator, decoded);
    try std.testing.expectEqualStrings("fixed", decoded.text);
}

test "sentinel-terminated strings decode and round-trip" {
    const allocator = std.testing.allocator;
    var text = Value{ .string = "zero" };
    const decoded = try into([:0]const u8, allocator, &text);
    defer freeInto([:0]const u8, allocator, decoded);
    try std.testing.expectEqualStrings("zero", decoded);
    try std.testing.expectEqual(@as(u8, 0), decoded.ptr[decoded.len]);
    var tree = try from([:0]const u8, allocator, decoded);
    defer tree.deinit();
    try std.testing.expectEqualStrings("zero", tree.root.string);
    try std.testing.checkAllAllocationFailures(allocator, DecodeAndFree([:0]const u8).run, .{&text});
}

const TestDomain = struct {
    name: []const u8,

    pub const pkl_class = "test#Domain";
};

test "references decode a typed domain and an owned access path" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const domain = try testObject(arena, "test#Domain", &.{"name"}, &.{.{ .string = "ci" }});
    var data = Value{ .string = "outputs" };
    const by_property = try testObject(arena, "pkl.ref#Access", &.{ "property", "key" }, &.{ .{ .string = "file" }, .nil });
    const by_key = try testObject(arena, "pkl.ref#Access", &.{ "property", "key" }, &.{ .nil, .{ .int = Integer.fromSigned(2) } });
    var path = [_]*Value{ by_property, by_key };
    var reference = Value{ .reference = .{ .domain = domain, .data = &data, .path = &path } };

    const Ref = Reference(TestDomain, []const u8);
    try std.testing.expect(matches(Ref, &reference));
    const decoded = try into(Ref, allocator, &reference);
    defer freeInto(Ref, allocator, decoded);
    data.string = "changed";
    try std.testing.expectEqualStrings("ci", decoded.domain.name);
    try std.testing.expectEqualStrings("outputs", decoded.data().string);
    try std.testing.expectEqual(@as(usize, 2), decoded.path.len);
    try std.testing.expect(decoded.path[0].is_property);
    try std.testing.expectEqualStrings("file", decoded.path[0].property.?);
    try std.testing.expect(decoded.path[1].is_subscript);
    try std.testing.expect(decoded.path[1].key.?.int.eql(Integer.fromSigned(2)));
    try std.testing.checkAllAllocationFailures(allocator, DecodeAndFree(Ref).run, .{&reference});

    var tree = try from(Ref, allocator, decoded);
    defer tree.deinit();
    try std.testing.expect(tree.root.* == .reference);
    try std.testing.expectEqualStrings("ci", value.findProperty(tree.root.reference.domain, "name").?.string);
    try std.testing.expectEqual(@as(usize, 2), tree.root.reference.path.len);

    const access = try into(Access, allocator, by_key);
    defer freeInto(Access, allocator, access);
    try std.testing.expect(access.access.is_subscript);
    var text = Value{ .string = "x" };
    try std.testing.expectError(error.TypeMismatch, into(Ref, allocator, &text));
    try std.testing.expectError(error.TypeMismatch, into(Access, allocator, domain));
}
