//! Allocator-owned conversions between pkl-binary values and Zig types.
//! `into` copies out of a value tree. `freeInto` releases that copy.

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
    unit: []u8,
};

pub const DataSize = struct {
    value: f64,
    unit: []u8,
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
        .pointer => |pointer| {
            if (pointer.size != .slice) @compileError("only slices can be decoded");
            if (pointer.child == u8) {
                const bytes = switch (tree.*) {
                    .string, .regex => |item| item,
                    .bytes => |item| item,
                    else => return error.TypeMismatch,
                };
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
            if (tree.* == .pair and @hasField(T, "first") and @hasField(T, "second") and @typeInfo(T).@"struct".field_names.len == 2) {
                var result: T = undefined;
                result.first = try into(@FieldType(T, "first"), allocator, tree.pair.first);
                errdefer freeInto(@FieldType(T, "first"), allocator, result.first);
                result.second = try into(@FieldType(T, "second"), allocator, tree.pair.second);
                return result;
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
            .slice => {
                if (pointer.child == u8) {
                    if (pointer.attrs.@"const") allocator.free(@constCast(item)) else allocator.free(item);
                    return;
                }
                for (item) |child| freeInto(pointer.child, allocator, child);
                allocator.free(item);
            },
            else => {},
        },
        .@"struct" => {
            const info = @typeInfo(T).@"struct";
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
    var result: T = undefined;
    var seen = std.mem.zeroes([info.field_names.len]bool);
    errdefer inline for (info.field_names, info.field_types, 0..) |name, field_type, index| {
        if (seen[index]) freeInto(field_type, allocator, @field(result, name));
    };
    inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, field_type, attrs, index| {
        if (value.findProperty(tree, name)) |property| {
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
        .int => return .{ .int = Integer.fromSigned(std.math.cast(i64, input) orelse return error.Overflow) },
        .float => return .{ .float = @floatCast(input) },
        .pointer => |pointer| {
            if (pointer.size != .slice) @compileError("only slices can be encoded");
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
            var members: std.ArrayList(value.Member) = .empty;
            const info = @typeInfo(T).@"struct";
            inline for (info.field_names, info.field_types) |name, field_type| {
                const child = try store(allocator, try fromValue(allocator, field_type, @field(input, name)));
                try members.append(allocator, .{ .property = .{ .name = name, .value = child } });
            }
            return .{ .object = .{
                .class_name = "Dynamic",
                .module_uri = "pkl:base",
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

fn ownsMemory(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => true,
        .optional => |optional| ownsMemory(optional.child),
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
