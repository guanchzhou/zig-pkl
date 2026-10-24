//! Lossless pkl-binary values. Object, map, mapping, list, listing, set, duration,
//! data size, pair, int sequence, regex, class, type alias, function, bytes, and
//! reference identities are preserved. Unknown trailing slots are discarded.
//! `Limits.max_depth` counts nested values; the member, entry, and element
//! wrappers inside a value do not add depth. Every decoded node and slice is
//! charged against `Limits.max_bytes`.

const std = @import("std");
const msgpack = @import("../protocol/msgpack.zig");

pub const Integer = msgpack.Integer;
pub const Limits = msgpack.Limits;

pub const Error = msgpack.Error || error{
    InvalidValue,
    UnknownCode,
};

pub const Code = enum(u8) {
    object = 0x01,
    map = 0x02,
    mapping = 0x03,
    list = 0x04,
    listing = 0x05,
    set = 0x06,
    duration = 0x07,
    data_size = 0x08,
    pair = 0x09,
    int_seq = 0x0a,
    regex = 0x0b,
    class = 0x0c,
    type_alias = 0x0d,
    function = 0x0e,
    bytes = 0x0f,
    property = 0x10,
    entry = 0x11,
    element = 0x12,
    reference = 0x20,

    pub fn fromInt(value: i64) ?Code {
        if (value < 0 or value > std.math.maxInt(u8)) return null;
        return std.enums.fromInt(Code, @as(u8, @intCast(value)));
    }
};

pub const Quantity = struct {
    value: f64,
    unit: []const u8,
};

/// Both fields are empty for values from Pkl before 0.30, which sends class
/// and type alias values without a name.
pub const TypeName = struct {
    name: []const u8,
    module_uri: []const u8,
};

pub const IntSeq = struct {
    start: Integer,
    end: Integer,
    step: Integer,
};

pub const Entry = struct {
    key: *Value,
    value: *Value,
};

pub const Member = union(enum) {
    property: struct { name: []const u8, value: *Value },
    entry: Entry,
    element: struct { index: Integer, value: *Value },
};

pub const Object = struct {
    class_name: []const u8,
    module_uri: []const u8,
    members: []Member,
};

pub const Reference = struct {
    domain: *Value,
    data: *Value,
    path: []*Value,
};

pub const Value = union(enum) {
    nil,
    boolean: bool,
    int: Integer,
    float: f64,
    string: []const u8,
    object: Object,
    map: []Entry,
    mapping: []Entry,
    list: []*Value,
    listing: []*Value,
    set: []*Value,
    duration: Quantity,
    data_size: Quantity,
    pair: struct { first: *Value, second: *Value },
    int_seq: IntSeq,
    regex: []const u8,
    class: TypeName,
    type_alias: TypeName,
    function,
    bytes: []const u8,
    reference: Reference,
};

pub const Tree = struct {
    arena: *std.heap.ArenaAllocator,
    root: *Value,
    bytes_read: usize,

    pub fn deinit(self: *Tree) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
        self.* = undefined;
    }
};

/// Typed view of one `pkl.ref#Access` object stored on a reference path.
pub const ReferenceAccess = struct {
    property: ?[]const u8 = null,
    key: ?*const Value = null,
    has_key: bool = false,
    is_property: bool = false,
    is_subscript: bool = false,

    pub fn parse(value: *const Value) error{TypeMismatch}!ReferenceAccess {
        if (value.* != .object) return error.TypeMismatch;
        var result = ReferenceAccess{};
        var explicit_property: ?bool = null;
        var explicit_subscript: ?bool = null;
        for (value.object.members) |member| {
            switch (member) {
                .property => |property| {
                    if (std.mem.eql(u8, property.name, "property")) {
                        switch (property.value.*) {
                            .nil => result.property = null,
                            .string => |text| result.property = text,
                            else => return error.TypeMismatch,
                        }
                    } else if (std.mem.eql(u8, property.name, "key")) {
                        result.has_key = true;
                        result.key = if (property.value.* == .nil) null else property.value;
                    } else if (std.mem.eql(u8, property.name, "isProperty")) {
                        if (property.value.* != .boolean) return error.TypeMismatch;
                        explicit_property = property.value.boolean;
                    } else if (std.mem.eql(u8, property.name, "isSubscript")) {
                        if (property.value.* != .boolean) return error.TypeMismatch;
                        explicit_subscript = property.value.boolean;
                    }
                },
                else => {},
            }
        }
        result.is_property = explicit_property orelse (result.property != null);
        result.is_subscript = explicit_subscript orelse (result.has_key and result.property == null);
        return result;
    }
};

pub fn isDynamic(value: *const Value) bool {
    return switch (value.*) {
        .object => |object| std.mem.eql(u8, object.class_name, "Dynamic") and
            std.mem.eql(u8, object.module_uri, "pkl:base"),
        else => false,
    };
}

pub fn findProperty(value: *const Value, name: []const u8) ?*Value {
    switch (value.*) {
        .object => |object| {
            for (object.members) |member| {
                switch (member) {
                    .property => |property| if (std.mem.eql(u8, property.name, name)) return property.value,
                    else => {},
                }
            }
            return null;
        },
        else => return null,
    }
}

pub fn decodeSlice(allocator: std.mem.Allocator, bytes: []const u8, limits: Limits) Error!Tree {
    var reader = std.Io.Reader.fixed(bytes);
    const tree = try decodeReader(allocator, &reader, limits);
    if (reader.peekByte()) |_| {
        var failed = tree;
        failed.deinit();
        return error.TrailingData;
    } else |err| switch (err) {
        error.EndOfStream => return tree,
        else => {
            var failed = tree;
            failed.deinit();
            return error.ReadFailed;
        },
    }
}

pub fn decodeReader(allocator: std.mem.Allocator, reader: *std.Io.Reader, limits: Limits) Error!Tree {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = .init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    var cursor = msgpack.Decoder{
        .reader = reader,
        .allocator = arena.allocator(),
        .limits = limits,
    };
    const root = try allocValue(&cursor, try readValue(&cursor));
    return .{
        .arena = arena,
        .root = root,
        .bytes_read = cursor.bytes_read,
    };
}

pub fn encode(writer: *std.Io.Writer, value: *const Value) (std.Io.Writer.Error || error{LimitExceeded})!void {
    switch (value.*) {
        .nil => try msgpack.writeNil(writer),
        .boolean => |item| try msgpack.writeBool(writer, item),
        .int => |item| try msgpack.writeInteger(writer, item),
        .float => |item| try msgpack.writeFloat64(writer, item),
        .string => |item| try msgpack.writeString(writer, item),
        .object => |object| {
            try msgpack.writeArrayHeader(writer, 4);
            try writeCode(writer, .object);
            try msgpack.writeString(writer, object.class_name);
            try msgpack.writeString(writer, object.module_uri);
            try msgpack.writeArrayHeader(writer, try asLen(object.members.len));
            for (object.members) |member| try encodeMember(writer, member);
        },
        .map => |entries| try encodeMap(writer, .map, entries),
        .mapping => |entries| try encodeMap(writer, .mapping, entries),
        .list => |items| try encodeSequence(writer, .list, items),
        .listing => |items| try encodeSequence(writer, .listing, items),
        .set => |items| try encodeSequence(writer, .set, items),
        .duration => |quantity| try encodeQuantity(writer, .duration, quantity),
        .data_size => |quantity| try encodeQuantity(writer, .data_size, quantity),
        .pair => |pair| {
            try msgpack.writeArrayHeader(writer, 3);
            try writeCode(writer, .pair);
            try encode(writer, pair.first);
            try encode(writer, pair.second);
        },
        .int_seq => |seq| {
            try msgpack.writeArrayHeader(writer, 4);
            try writeCode(writer, .int_seq);
            try msgpack.writeInteger(writer, seq.start);
            try msgpack.writeInteger(writer, seq.end);
            try msgpack.writeInteger(writer, seq.step);
        },
        .regex => |pattern| {
            try msgpack.writeArrayHeader(writer, 2);
            try writeCode(writer, .regex);
            try msgpack.writeString(writer, pattern);
        },
        .class => |name| try encodeTypeName(writer, .class, name),
        .type_alias => |name| try encodeTypeName(writer, .type_alias, name),
        .function => {
            try msgpack.writeArrayHeader(writer, 1);
            try writeCode(writer, .function);
        },
        .bytes => |payload| {
            try msgpack.writeArrayHeader(writer, 2);
            try writeCode(writer, .bytes);
            try msgpack.writeBinary(writer, payload);
        },
        .reference => |reference| {
            try msgpack.writeArrayHeader(writer, 4);
            try writeCode(writer, .reference);
            try encode(writer, reference.domain);
            try encode(writer, reference.data);
            try msgpack.writeArrayHeader(writer, try asLen(reference.path.len));
            for (reference.path) |access| try encode(writer, access);
        },
    }
}

pub fn encodeAlloc(allocator: std.mem.Allocator, value: *const Value) (std.Io.Writer.Error || error{ LimitExceeded, OutOfMemory })![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try encode(&out.writer, value);
    return out.toOwnedSlice();
}

/// Deep-copies `source` into a new tree whose arena uses `allocator`.
pub fn clone(allocator: std.mem.Allocator, source: *const Value) error{OutOfMemory}!Tree {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = .init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    const root = try cloneInto(arena.allocator(), source);
    return .{ .arena = arena, .root = root, .bytes_read = 0 };
}

/// Deep-copies `source` with `allocator`, which is usually an arena: a
/// partial copy is not released when allocation fails.
pub fn cloneInto(allocator: std.mem.Allocator, source: *const Value) error{OutOfMemory}!*Value {
    const out = try allocator.create(Value);
    out.* = switch (source.*) {
        .nil, .boolean, .int, .float, .function, .int_seq => source.*,
        .string => |text| .{ .string = try allocator.dupe(u8, text) },
        .regex => |text| .{ .regex = try allocator.dupe(u8, text) },
        .bytes => |data| .{ .bytes = try allocator.dupe(u8, data) },
        .duration => |quantity| .{ .duration = try cloneQuantity(allocator, quantity) },
        .data_size => |quantity| .{ .data_size = try cloneQuantity(allocator, quantity) },
        .class => |name| .{ .class = try cloneTypeName(allocator, name) },
        .type_alias => |name| .{ .type_alias = try cloneTypeName(allocator, name) },
        .list => |items| .{ .list = try cloneSequence(allocator, items) },
        .listing => |items| .{ .listing = try cloneSequence(allocator, items) },
        .set => |items| .{ .set = try cloneSequence(allocator, items) },
        .map => |entries| .{ .map = try cloneEntries(allocator, entries) },
        .mapping => |entries| .{ .mapping = try cloneEntries(allocator, entries) },
        .pair => |pair| .{ .pair = .{
            .first = try cloneInto(allocator, pair.first),
            .second = try cloneInto(allocator, pair.second),
        } },
        .reference => |reference| .{ .reference = .{
            .domain = try cloneInto(allocator, reference.domain),
            .data = try cloneInto(allocator, reference.data),
            .path = try cloneSequence(allocator, reference.path),
        } },
        .object => |object| blk: {
            const members = try allocator.alloc(Member, object.members.len);
            for (object.members, members) |member, *slot| {
                slot.* = switch (member) {
                    .property => |property| .{ .property = .{
                        .name = try allocator.dupe(u8, property.name),
                        .value = try cloneInto(allocator, property.value),
                    } },
                    .entry => |entry| .{ .entry = .{
                        .key = try cloneInto(allocator, entry.key),
                        .value = try cloneInto(allocator, entry.value),
                    } },
                    .element => |element| .{ .element = .{
                        .index = element.index,
                        .value = try cloneInto(allocator, element.value),
                    } },
                };
            }
            break :blk .{ .object = .{
                .class_name = try allocator.dupe(u8, object.class_name),
                .module_uri = try allocator.dupe(u8, object.module_uri),
                .members = members,
            } };
        },
    };
    return out;
}

fn cloneQuantity(allocator: std.mem.Allocator, quantity: Quantity) error{OutOfMemory}!Quantity {
    return .{ .value = quantity.value, .unit = try allocator.dupe(u8, quantity.unit) };
}

fn cloneTypeName(allocator: std.mem.Allocator, name: TypeName) error{OutOfMemory}!TypeName {
    return .{ .name = try allocator.dupe(u8, name.name), .module_uri = try allocator.dupe(u8, name.module_uri) };
}

fn cloneSequence(allocator: std.mem.Allocator, items: []*Value) error{OutOfMemory}![]*Value {
    const out = try allocator.alloc(*Value, items.len);
    for (items, out) |item, *slot| slot.* = try cloneInto(allocator, item);
    return out;
}

fn cloneEntries(allocator: std.mem.Allocator, entries: []Entry) error{OutOfMemory}![]Entry {
    const out = try allocator.alloc(Entry, entries.len);
    for (entries, out) |entry, *slot| slot.* = .{
        .key = try cloneInto(allocator, entry.key),
        .value = try cloneInto(allocator, entry.value),
    };
    return out;
}

pub fn eql(left: *const Value, right: *const Value) bool {
    if (std.meta.activeTag(left.*) != std.meta.activeTag(right.*)) return false;
    return switch (left.*) {
        .nil => true,
        .boolean => |value| value == right.boolean,
        .int => |value| value.eql(right.int),
        .float => |value| @as(u64, @bitCast(value)) == @as(u64, @bitCast(right.float)),
        .string => |value| std.mem.eql(u8, value, right.string),
        .regex => |value| std.mem.eql(u8, value, right.regex),
        .bytes => |value| std.mem.eql(u8, value, right.bytes),
        .function => true,
        .duration => |value| quantityEql(value, right.duration),
        .data_size => |value| quantityEql(value, right.data_size),
        .class => |value| typeNameEql(value, right.class),
        .type_alias => |value| typeNameEql(value, right.type_alias),
        .int_seq => |value| value.start.eql(right.int_seq.start) and value.end.eql(right.int_seq.end) and value.step.eql(right.int_seq.step),
        .pair => |value| eql(value.first, right.pair.first) and eql(value.second, right.pair.second),
        .list => |items| sequenceEql(items, right.list),
        .listing => |items| sequenceEql(items, right.listing),
        .set => |items| sequenceEql(items, right.set),
        .map => |items| entriesEql(items, right.map),
        .mapping => |items| entriesEql(items, right.mapping),
        .object => |object| objectEql(object, right.object),
        .reference => |reference| eql(reference.domain, right.reference.domain) and
            eql(reference.data, right.reference.data) and
            sequenceEql(reference.path, right.reference.path),
    };
}

fn readValue(cursor: *msgpack.Decoder) Error!Value {
    const kind = try cursor.peekKind();
    switch (kind) {
        .nil => {
            try cursor.readNil();
            return .nil;
        },
        .boolean => return .{ .boolean = try cursor.readBool() },
        .int => return .{ .int = try cursor.readInteger() },
        .float => return .{ .float = try cursor.readFloat() },
        .string => return .{ .string = try cursor.readString() },
        .binary, .map, .ext => return error.TypeMismatch,
        .array => return readContainer(cursor),
    }
}

fn readContainer(cursor: *msgpack.Decoder) Error!Value {
    try cursor.pushDepth();
    defer cursor.popDepth();
    const len = try cursor.readArrayLength();
    if (len == 0) return error.InvalidValue;
    const code = try readCode(cursor);
    switch (code) {
        .object => {
            if (len < 4) return error.InvalidValue;
            const class_name = try cursor.readString();
            const module_uri = try cursor.readString();
            const members = try readMembers(cursor);
            try skipRest(cursor, len - 4);
            return .{ .object = .{
                .class_name = class_name,
                .module_uri = module_uri,
                .members = members,
            } };
        },
        .map, .mapping => {
            if (len < 2) return error.InvalidValue;
            const entries = try readEntries(cursor);
            try skipRest(cursor, len - 2);
            return if (code == .map) .{ .map = entries } else .{ .mapping = entries };
        },
        .list, .listing, .set => {
            if (len < 2) return error.InvalidValue;
            const items = try readSequence(cursor);
            try skipRest(cursor, len - 2);
            return switch (code) {
                .list => .{ .list = items },
                .listing => .{ .listing = items },
                .set => .{ .set = items },
                else => unreachable,
            };
        },
        .duration, .data_size => {
            if (len < 3) return error.InvalidValue;
            const number = try cursor.readFloat();
            const unit = try cursor.readString();
            try skipRest(cursor, len - 3);
            const quantity = Quantity{ .value = number, .unit = unit };
            return if (code == .duration) .{ .duration = quantity } else .{ .data_size = quantity };
        },
        .pair => {
            if (len < 3) return error.InvalidValue;
            const first = try allocValue(cursor, try readValue(cursor));
            const second = try allocValue(cursor, try readValue(cursor));
            try skipRest(cursor, len - 3);
            return .{ .pair = .{ .first = first, .second = second } };
        },
        .int_seq => {
            if (len < 4) return error.InvalidValue;
            const start = try cursor.readInteger();
            const end = try cursor.readInteger();
            const step = try cursor.readInteger();
            try skipRest(cursor, len - 4);
            return .{ .int_seq = .{ .start = start, .end = end, .step = step } };
        },
        .regex => {
            if (len < 2) return error.InvalidValue;
            const pattern = try cursor.readString();
            try skipRest(cursor, len - 2);
            return .{ .regex = pattern };
        },
        .class, .type_alias => {
            const name = if (len >= 2) try cursor.readString() else "";
            const module_uri = if (len >= 3) try cursor.readString() else "";
            try skipRest(cursor, len - @min(len, 3));
            const type_name = TypeName{ .name = name, .module_uri = module_uri };
            return if (code == .class) .{ .class = type_name } else .{ .type_alias = type_name };
        },
        .function => {
            try skipRest(cursor, len - 1);
            return .function;
        },
        .bytes => {
            if (len < 2) return error.InvalidValue;
            const payload = try cursor.readBinary();
            try skipRest(cursor, len - 2);
            return .{ .bytes = payload };
        },
        .reference => {
            if (len < 4) return error.InvalidValue;
            const domain = try allocValue(cursor, try readValue(cursor));
            const data = try allocValue(cursor, try readValue(cursor));
            const path = try readSequence(cursor);
            try skipRest(cursor, len - 4);
            return .{ .reference = .{ .domain = domain, .data = data, .path = path } };
        },
        .property, .entry, .element => return error.InvalidValue,
    }
}

fn readMembers(cursor: *msgpack.Decoder) Error![]Member {
    const len = try cursor.readArrayLength();
    try cursor.reserveCollection(len, @sizeOf(Member), 1);
    const items = try cursor.allocator.alloc(Member, len);
    for (items) |*item| item.* = try readMember(cursor);
    return items;
}

fn readMember(cursor: *msgpack.Decoder) Error!Member {
    const len = try cursor.readArrayLength();
    if (len < 1) return error.InvalidValue;
    const code = try readCode(cursor);
    switch (code) {
        .property => {
            if (len < 3) return error.InvalidValue;
            const name = try cursor.readString();
            const property_value = try allocValue(cursor, try readValue(cursor));
            try skipRest(cursor, len - 3);
            return .{ .property = .{ .name = name, .value = property_value } };
        },
        .entry => {
            if (len < 3) return error.InvalidValue;
            const key = try allocValue(cursor, try readValue(cursor));
            const entry_value = try allocValue(cursor, try readValue(cursor));
            try skipRest(cursor, len - 3);
            return .{ .entry = .{ .key = key, .value = entry_value } };
        },
        .element => {
            if (len < 3) return error.InvalidValue;
            const index = try cursor.readInteger();
            const element_value = try allocValue(cursor, try readValue(cursor));
            try skipRest(cursor, len - 3);
            return .{ .element = .{ .index = index, .value = element_value } };
        },
        else => return error.InvalidValue,
    }
}

fn readEntries(cursor: *msgpack.Decoder) Error![]Entry {
    const len = try cursor.readMapLength();
    try cursor.reserveCollection(len, @sizeOf(Entry), 2);
    const items = try cursor.allocator.alloc(Entry, len);
    for (items) |*item| {
        item.* = .{
            .key = try allocValue(cursor, try readValue(cursor)),
            .value = try allocValue(cursor, try readValue(cursor)),
        };
    }
    return items;
}

fn readSequence(cursor: *msgpack.Decoder) Error![]*Value {
    const len = try cursor.readArrayLength();
    try cursor.reserveCollection(len, @sizeOf(*Value), 1);
    const items = try cursor.allocator.alloc(*Value, len);
    for (items) |*item| item.* = try allocValue(cursor, try readValue(cursor));
    return items;
}

fn readCode(cursor: *msgpack.Decoder) Error!Code {
    const value = try cursor.readInteger();
    const signed = value.asSigned() catch return error.UnknownCode;
    return Code.fromInt(signed) orelse error.UnknownCode;
}

fn skipRest(cursor: *msgpack.Decoder, count: u32) Error!void {
    var index: u32 = 0;
    while (index < count) : (index += 1) try cursor.skip();
}

fn allocValue(cursor: *msgpack.Decoder, value: Value) Error!*Value {
    try cursor.reserveAllocation(@sizeOf(Value));
    const ptr = try cursor.allocator.create(Value);
    ptr.* = value;
    return ptr;
}

fn writeCode(writer: *std.Io.Writer, code: Code) std.Io.Writer.Error!void {
    try msgpack.writeInt(writer, @backingInt(code));
}

fn asLen(len: usize) error{LimitExceeded}!u32 {
    if (len > std.math.maxInt(u32)) return error.LimitExceeded;
    return @intCast(len);
}

fn encodeMember(writer: *std.Io.Writer, member: Member) (std.Io.Writer.Error || error{LimitExceeded})!void {
    switch (member) {
        .property => |property| {
            try msgpack.writeArrayHeader(writer, 3);
            try writeCode(writer, .property);
            try msgpack.writeString(writer, property.name);
            try encode(writer, property.value);
        },
        .entry => |entry| {
            try msgpack.writeArrayHeader(writer, 3);
            try writeCode(writer, .entry);
            try encode(writer, entry.key);
            try encode(writer, entry.value);
        },
        .element => |element| {
            try msgpack.writeArrayHeader(writer, 3);
            try writeCode(writer, .element);
            try msgpack.writeInteger(writer, element.index);
            try encode(writer, element.value);
        },
    }
}

fn encodeMap(writer: *std.Io.Writer, code: Code, entries: []Entry) (std.Io.Writer.Error || error{LimitExceeded})!void {
    try msgpack.writeArrayHeader(writer, 2);
    try writeCode(writer, code);
    try msgpack.writeMapHeader(writer, try asLen(entries.len));
    for (entries) |entry| {
        try encode(writer, entry.key);
        try encode(writer, entry.value);
    }
}

fn encodeSequence(writer: *std.Io.Writer, code: Code, items: []*Value) (std.Io.Writer.Error || error{LimitExceeded})!void {
    try msgpack.writeArrayHeader(writer, 2);
    try writeCode(writer, code);
    try msgpack.writeArrayHeader(writer, try asLen(items.len));
    for (items) |item| try encode(writer, item);
}

fn encodeQuantity(writer: *std.Io.Writer, code: Code, quantity: Quantity) std.Io.Writer.Error!void {
    try msgpack.writeArrayHeader(writer, 3);
    try writeCode(writer, code);
    try msgpack.writeFloat64(writer, quantity.value);
    try msgpack.writeString(writer, quantity.unit);
}

fn encodeTypeName(writer: *std.Io.Writer, code: Code, name: TypeName) std.Io.Writer.Error!void {
    if (name.name.len == 0 and name.module_uri.len == 0) {
        try msgpack.writeArrayHeader(writer, 1);
        return writeCode(writer, code);
    }
    try msgpack.writeArrayHeader(writer, 3);
    try writeCode(writer, code);
    try msgpack.writeString(writer, name.name);
    try msgpack.writeString(writer, name.module_uri);
}

fn quantityEql(left: Quantity, right: Quantity) bool {
    return @as(u64, @bitCast(left.value)) == @as(u64, @bitCast(right.value)) and std.mem.eql(u8, left.unit, right.unit);
}

fn typeNameEql(left: TypeName, right: TypeName) bool {
    return std.mem.eql(u8, left.name, right.name) and std.mem.eql(u8, left.module_uri, right.module_uri);
}

fn sequenceEql(left: []*Value, right: []*Value) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (!eql(a, b)) return false;
    return true;
}

fn entriesEql(left: []Entry, right: []Entry) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (!eql(a.key, b.key) or !eql(a.value, b.value)) return false;
    return true;
}

fn objectEql(left: Object, right: Object) bool {
    if (!std.mem.eql(u8, left.class_name, right.class_name)) return false;
    if (!std.mem.eql(u8, left.module_uri, right.module_uri)) return false;
    if (left.members.len != right.members.len) return false;
    for (left.members, right.members) |a, b| {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        switch (a) {
            .property => |property| {
                if (!std.mem.eql(u8, property.name, b.property.name) or !eql(property.value, b.property.value)) return false;
            },
            .entry => |entry| {
                if (!eql(entry.key, b.entry.key) or !eql(entry.value, b.entry.value)) return false;
            },
            .element => |element| {
                if (!element.index.eql(b.element.index) or !eql(element.value, b.element.value)) return false;
            },
        }
    }
    return true;
}

fn roundtrip(value: *const Value) !void {
    const allocator = std.testing.allocator;
    const encoded = try encodeAlloc(allocator, value);
    defer allocator.free(encoded);
    var tree = try decodeSlice(allocator, encoded, .{});
    defer tree.deinit();
    try std.testing.expect(eql(value, tree.root));
}

test "primitives and every container identity round-trip" {
    var one = Value{ .int = Integer.fromSigned(1) };
    var nil_value: Value = .nil;
    var two = Value{ .int = Integer.fromSigned(2) };
    var text = Value{ .string = "bird" };
    var flag = Value{ .boolean = true };
    var items = [_]*Value{ &one, &text };
    var list = Value{ .list = &items };
    var listing = Value{ .listing = &items };
    var set = Value{ .set = items[0..1] };
    var entries = [_]Entry{
        .{ .key = &text, .value = &one },
        .{ .key = &one, .value = &flag },
    };
    var map = Value{ .map = &entries };
    var mapping = Value{ .mapping = entries[0..1] };
    var pair = Value{ .pair = .{ .first = &one, .second = &text } };
    var duration = Value{ .duration = .{ .value = 1.5, .unit = "min" } };
    var data_size = Value{ .data_size = .{ .value = 4, .unit = "kib" } };
    var int_seq = Value{ .int_seq = .{
        .start = Integer.fromSigned(0),
        .end = Integer.fromSigned(10),
        .step = Integer.fromSigned(2),
    } };
    var regex = Value{ .regex = "a+" };
    var class = Value{ .class = .{ .name = "base#Int", .module_uri = "pkl:base" } };
    var type_alias = Value{ .type_alias = .{ .name = "mod#Alias", .module_uri = "file:///mod.pkl" } };
    var function: Value = .function;
    var bytes = Value{ .bytes = "\x00\xff" };
    var name = Value{ .string = "name" };
    var members = [_]Member{
        .{ .property = .{ .name = "count", .value = &one } },
        .{ .entry = .{ .key = &text, .value = &two } },
        .{ .element = .{ .index = Integer.fromSigned(0), .value = &flag } },
    };
    var object = Value{ .object = .{
        .class_name = "Dynamic",
        .module_uri = "pkl:base",
        .members = &members,
    } };
    var property_access = Value{ .object = .{
        .class_name = "ref#Access",
        .module_uri = "pkl:ref",
        .members = undefined,
    } };
    var property_members = [_]Member{
        .{ .property = .{ .name = "property", .value = &name } },
        .{ .property = .{ .name = "key", .value = &nil_value } },
    };
    property_access.object.members = &property_members;
    var subscript_key = Value{ .int = Integer.fromSigned(3) };
    var subscript_members = [_]Member{
        .{ .property = .{ .name = "property", .value = &nil_value } },
        .{ .property = .{ .name = "key", .value = &subscript_key } },
    };
    var subscript_access = Value{ .object = .{
        .class_name = "ref#Access",
        .module_uri = "pkl:ref",
        .members = &subscript_members,
    } };
    var path = [_]*Value{ &property_access, &subscript_access };
    var reference = Value{ .reference = .{ .domain = &object, .data = &text, .path = &path } };

    try roundtrip(&one);
    try roundtrip(&text);
    try roundtrip(&flag);
    try roundtrip(&nil_value);
    var negative_zero: Value = .{ .float = -0.0 };
    try roundtrip(&negative_zero);
    try roundtrip(&list);
    try roundtrip(&listing);
    try roundtrip(&set);
    try roundtrip(&map);
    try roundtrip(&mapping);
    try roundtrip(&pair);
    try roundtrip(&duration);
    try roundtrip(&data_size);
    try roundtrip(&int_seq);
    try roundtrip(&regex);
    try roundtrip(&class);
    try roundtrip(&type_alias);
    try roundtrip(&function);
    try roundtrip(&bytes);
    try roundtrip(&object);
    try roundtrip(&reference);

    for ([_]*const Value{ &list, &map, &pair, &duration, &int_seq, &class, &bytes, &object, &reference }) |original| {
        var copy = try clone(std.testing.allocator, original);
        defer copy.deinit();
        try std.testing.expect(eql(original, copy.root));
    }

    try std.testing.expect(isDynamic(&object));
    try std.testing.expect(!eql(&list, &listing));
    try std.testing.expect(!eql(&map, &mapping));
    try std.testing.expect(!eql(&class, &type_alias));
    const property = try ReferenceAccess.parse(&property_access);
    try std.testing.expect(property.is_property);
    try std.testing.expectEqualStrings("name", property.property.?);
    const subscript = try ReferenceAccess.parse(&subscript_access);
    try std.testing.expect(subscript.is_subscript);
    try std.testing.expect(subscript.has_key);
    try std.testing.expect(subscript.key.?.int.eql(Integer.fromSigned(3)));
}

test "extra slots are discarded and unknown codes fail" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    try msgpack.writeArrayHeader(writer, 4);
    try msgpack.writeInt(writer, 0x07);
    try msgpack.writeFloat64(writer, 1.5);
    try msgpack.writeString(writer, "min");
    try msgpack.writeString(writer, "future");
    var tree = try decodeSlice(allocator, out.written(), .{});
    defer tree.deinit();
    try std.testing.expect(tree.root.* == .duration);
    try std.testing.expectEqual(@as(f64, 1.5), tree.root.duration.value);
    try std.testing.expectEqualStrings("min", tree.root.duration.unit);

    var unknown: std.Io.Writer.Allocating = .init(allocator);
    defer unknown.deinit();
    try msgpack.writeArrayHeader(&unknown.writer, 1);
    try msgpack.writeInt(&unknown.writer, 0x63);
    try std.testing.expectError(error.UnknownCode, decodeSlice(allocator, unknown.written(), .{}));
    try std.testing.expectError(error.LimitExceeded, decodeSlice(allocator, out.written(), .{ .max_depth = 0 }));
}

test "legacy class and type alias values decode without module uri" {
    const allocator = std.testing.allocator;
    var class_bytes: std.Io.Writer.Allocating = .init(allocator);
    defer class_bytes.deinit();
    try msgpack.writeArrayHeader(&class_bytes.writer, 2);
    try msgpack.writeInt(&class_bytes.writer, @backingInt(Code.class));
    try msgpack.writeString(&class_bytes.writer, "legacy#Type");
    var class_tree = try decodeSlice(allocator, class_bytes.written(), .{});
    defer class_tree.deinit();
    try std.testing.expectEqualStrings("legacy#Type", class_tree.root.class.name);
    try std.testing.expectEqualStrings("", class_tree.root.class.module_uri);

    var alias_bytes: std.Io.Writer.Allocating = .init(allocator);
    defer alias_bytes.deinit();
    try msgpack.writeArrayHeader(&alias_bytes.writer, 2);
    try msgpack.writeInt(&alias_bytes.writer, @backingInt(Code.type_alias));
    try msgpack.writeString(&alias_bytes.writer, "legacy#Alias");
    var alias_tree = try decodeSlice(allocator, alias_bytes.written(), .{});
    defer alias_tree.deinit();
    try std.testing.expectEqualStrings("legacy#Alias", alias_tree.root.type_alias.name);
    try std.testing.expectEqualStrings("", alias_tree.root.type_alias.module_uri);
}

test "class and type alias values from Pkl before 0.30 decode without a name" {
    const allocator = std.testing.allocator;
    for ([_]Code{ .class, .type_alias }) |code| {
        const bytes = [_]u8{ 0x91, @backingInt(code) };
        var tree = try decodeSlice(allocator, &bytes, .{});
        defer tree.deinit();
        const name = switch (tree.root.*) {
            .class => |name| name,
            .type_alias => |name| name,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqualStrings("", name.name);
        try std.testing.expectEqualStrings("", name.module_uri);
        const encoded = try encodeAlloc(allocator, tree.root);
        defer allocator.free(encoded);
        try std.testing.expectEqualSlices(u8, &bytes, encoded);
    }
}

test "reference access distinguishes a nil subscript key" {
    var nil_value: Value = .nil;
    var members = [_]Member{
        .{ .property = .{ .name = "property", .value = &nil_value } },
        .{ .property = .{ .name = "key", .value = &nil_value } },
    };
    var access = Value{ .object = .{
        .class_name = "ref#Access",
        .module_uri = "pkl:ref",
        .members = &members,
    } };
    const parsed = try ReferenceAccess.parse(&access);
    try std.testing.expect(parsed.has_key);
    try std.testing.expect(parsed.key == null);
    try std.testing.expect(parsed.is_subscript);
}

test "value collection allocations are bounded before allocation" {
    const bytes = [_]u8{
        0x92, 0x04,
        0xdd, 0x00,
        0x10, 0x00,
        0x00,
    };
    try std.testing.expectError(error.LimitExceeded, decodeSlice(
        std.testing.allocator,
        &bytes,
        .{ .max_collection = std.math.maxInt(u32), .max_bytes = 1024 },
    ));
}

const PeakAllocator = struct {
    child: std.mem.Allocator,
    live: usize = 0,
    peak: usize = 0,

    fn allocator(self: *PeakAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn note(self: *PeakAllocator, added: usize, removed: usize) void {
        self.live = self.live + added - removed;
        self.peak = @max(self.peak, self.live);
    }

    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *PeakAllocator = @ptrCast(@alignCast(ptr));
        const result = self.child.rawAlloc(len, alignment, ret) orelse return null;
        self.note(len, 0);
        return result;
    }

    fn resize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) bool {
        const self: *PeakAllocator = @ptrCast(@alignCast(ptr));
        if (!self.child.rawResize(memory, alignment, new_len, ret)) return false;
        self.note(new_len, memory.len);
        return true;
    }

    fn remap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) ?[*]u8 {
        const self: *PeakAllocator = @ptrCast(@alignCast(ptr));
        const result = self.child.rawRemap(memory, alignment, new_len, ret) orelse return null;
        self.note(new_len, memory.len);
        return result;
    }

    fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *PeakAllocator = @ptrCast(@alignCast(ptr));
        self.child.rawFree(memory, alignment, ret);
        self.note(0, memory.len);
    }
};

test "compact element lists charge every node against max bytes" {
    const count = 50_000;
    const max_bytes = 1024 * 1024;
    const encoded = try std.testing.allocator.alloc(u8, 7 + count);
    defer std.testing.allocator.free(encoded);
    encoded[0..7].* = .{ 0x92, 0x04, 0xdd, 0x00, 0x00, 0xc3, 0x50 };
    @memset(encoded[7..], 0xc0);

    var peak = PeakAllocator{ .child = std.testing.allocator };
    try std.testing.expectError(error.LimitExceeded, decodeSlice(peak.allocator(), encoded, .{ .max_bytes = max_bytes }));
    try std.testing.expectEqual(@as(usize, 0), peak.live);
    try std.testing.expect(peak.peak <= 2 * max_bytes);

    var tree = try decodeSlice(std.testing.allocator, encoded, .{});
    defer tree.deinit();
    try std.testing.expectEqual(@as(usize, count), tree.root.list.len);
}

fn nestedObjects(allocator: std.mem.Allocator, levels: usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (0..levels) |_| {
        try msgpack.writeArrayHeader(&out.writer, 4);
        try msgpack.writeInt(&out.writer, @backingInt(Code.object));
        try msgpack.writeString(&out.writer, "Dynamic");
        try msgpack.writeString(&out.writer, "pkl:base");
        try msgpack.writeArrayHeader(&out.writer, 1);
        try msgpack.writeArrayHeader(&out.writer, 3);
        try msgpack.writeInt(&out.writer, @backingInt(Code.property));
        try msgpack.writeString(&out.writer, "child");
    }
    try msgpack.writeNil(&out.writer);
    return out.toOwnedSlice();
}

test "depth limits count semantic nesting rather than wire arrays" {
    const allocator = std.testing.allocator;
    const deep = try nestedObjects(allocator, 60);
    defer allocator.free(deep);
    var tree = try decodeSlice(allocator, deep, .{});
    defer tree.deinit();
    var cursor = tree.root;
    var levels: usize = 0;
    while (cursor.* == .object) : (levels += 1) cursor = findProperty(cursor, "child").?;
    try std.testing.expectEqual(@as(usize, 60), levels);

    const too_deep = try nestedObjects(allocator, 65);
    defer allocator.free(too_deep);
    try std.testing.expectError(error.LimitExceeded, decodeSlice(allocator, too_deep, .{}));
}

fn decodeObject(allocator: std.mem.Allocator, encoded: []const u8) !void {
    var tree = try decodeSlice(allocator, encoded, .{});
    tree.deinit();
}

test "value decode releases memory when allocation fails" {
    var number = Value{ .int = Integer.fromSigned(8) };
    var members = [_]Member{
        .{ .property = .{ .name = "n", .value = &number } },
    };
    var object = Value{ .object = .{
        .class_name = "Dynamic",
        .module_uri = "pkl:base",
        .members = &members,
    } };
    const encoded = try encodeAlloc(std.testing.allocator, &object);
    defer std.testing.allocator.free(encoded);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, decodeObject, .{encoded});
}
