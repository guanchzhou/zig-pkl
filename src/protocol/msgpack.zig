//! MessagePack codec for the Pkl message-passing and pkl-binary formats.
//! String and binary payloads stay distinct. Integers use the shortest form on write.

const std = @import("std");

pub const Limits = struct {
    max_depth: u32 = 64,
    max_collection: u32 = 1 << 20,
    max_bytes: usize = 64 * 1024 * 1024,

    pub const default: Limits = .{};
};

pub const Error = error{
    Truncated,
    TrailingData,
    Unsupported,
    LimitExceeded,
    TypeMismatch,
    OutOfMemory,
    ReadFailed,
    WriteFailed,
};

pub const Integer = union(enum) {
    signed: i64,
    unsigned: u64,

    pub fn fromSigned(value: i64) Integer {
        return .{ .signed = value };
    }

    pub fn fromUnsigned(value: u64) Integer {
        if (value <= std.math.maxInt(i64)) return .{ .signed = @intCast(value) };
        return .{ .unsigned = value };
    }

    pub fn eql(self: Integer, other: Integer) bool {
        return switch (self) {
            .signed => |lhs| switch (other) {
                .signed => |rhs| lhs == rhs,
                .unsigned => false,
            },
            .unsigned => |lhs| switch (other) {
                .unsigned => |rhs| lhs == rhs,
                .signed => false,
            },
        };
    }

    pub fn asSigned(self: Integer) error{Overflow}!i64 {
        return switch (self) {
            .signed => |value| value,
            .unsigned => error.Overflow,
        };
    }
};

pub const Value = union(enum) {
    nil,
    boolean: bool,
    int: Integer,
    float32: f32,
    float64: f64,
    string: []const u8,
    binary: []const u8,
    array: []Value,
    map: []Entry,

    pub const Entry = struct {
        key: Value,
        value: Value,
    };
};

pub const Document = struct {
    arena: *std.heap.ArenaAllocator,
    root: Value,
    bytes_read: usize,

    pub fn deinit(self: *Document) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
        self.* = undefined;
    }
};

pub const Kind = enum {
    nil,
    boolean,
    int,
    float,
    string,
    binary,
    array,
    map,
    ext,
};

pub const Decoder = struct {
    reader: *std.Io.Reader,
    allocator: std.mem.Allocator,
    limits: Limits,
    depth: u32 = 0,
    bytes_read: usize = 0,
    allocation_bytes: usize = 0,

    pub fn peekKind(self: *Decoder) Error!Kind {
        const byte = self.reader.peekByte() catch |err| return mapRead(err);
        return kindOf(byte);
    }

    pub fn readDom(self: *Decoder) Error!Value {
        const header = try self.readHeader();
        return switch (header) {
            .nil => .nil,
            .boolean => |value| .{ .boolean = value },
            .int => |value| .{ .int = value },
            .float32 => |value| .{ .float32 = value },
            .float64 => |value| .{ .float64 = value },
            .string => |value| .{ .string = value },
            .binary => |value| .{ .binary = value },
            .array => |len| blk: {
                try self.pushDepth();
                defer self.popDepth();
                try self.reserveCollection(len, @sizeOf(Value), 1);
                const items = try self.allocator.alloc(Value, len);
                for (items) |*item| item.* = try self.readDom();
                break :blk .{ .array = items };
            },
            .map => |len| blk: {
                try self.pushDepth();
                defer self.popDepth();
                try self.reserveCollection(len, @sizeOf(Value.Entry), 2);
                const items = try self.allocator.alloc(Value.Entry, len);
                for (items) |*item| {
                    item.* = .{
                        .key = try self.readDom(),
                        .value = try self.readDom(),
                    };
                }
                break :blk .{ .map = items };
            },
        };
    }

    pub fn skip(self: *Decoder) Error!void {
        const header = try self.readHeader();
        switch (header) {
            .nil, .boolean, .int, .float32, .float64, .string, .binary => {},
            .array => |len| {
                try self.pushDepth();
                defer self.popDepth();
                var index: u32 = 0;
                while (index < len) : (index += 1) try self.skip();
            },
            .map => |len| {
                try self.pushDepth();
                defer self.popDepth();
                var index: u32 = 0;
                while (index < len) : (index += 1) {
                    try self.skip();
                    try self.skip();
                }
            },
        }
    }

    pub fn readArrayLength(self: *Decoder) Error!u32 {
        const header = try self.readHeader();
        return switch (header) {
            .array => |len| len,
            else => error.TypeMismatch,
        };
    }

    pub fn readMapLength(self: *Decoder) Error!u32 {
        const header = try self.readHeader();
        return switch (header) {
            .map => |len| len,
            else => error.TypeMismatch,
        };
    }

    pub fn readString(self: *Decoder) Error![]u8 {
        const header = try self.readHeader();
        return switch (header) {
            .string => |value| value,
            else => error.TypeMismatch,
        };
    }

    pub fn readBinary(self: *Decoder) Error![]u8 {
        const header = try self.readHeader();
        return switch (header) {
            .binary => |value| value,
            else => error.TypeMismatch,
        };
    }

    pub fn readInteger(self: *Decoder) Error!Integer {
        const header = try self.readHeader();
        return switch (header) {
            .int => |value| value,
            else => error.TypeMismatch,
        };
    }

    pub fn readFloat(self: *Decoder) Error!f64 {
        const header = try self.readHeader();
        return switch (header) {
            .float32 => |value| value,
            .float64 => |value| value,
            .int => |value| switch (value) {
                .signed => |signed| @floatFromInt(signed),
                .unsigned => |unsigned| @floatFromInt(unsigned),
            },
            else => error.TypeMismatch,
        };
    }

    pub fn readBool(self: *Decoder) Error!bool {
        const header = try self.readHeader();
        return switch (header) {
            .boolean => |value| value,
            else => error.TypeMismatch,
        };
    }

    pub fn readNil(self: *Decoder) Error!void {
        const header = try self.readHeader();
        if (header != .nil) return error.TypeMismatch;
    }

    const Header = union(enum) {
        nil,
        boolean: bool,
        int: Integer,
        float32: f32,
        float64: f64,
        string: []u8,
        binary: []u8,
        array: u32,
        map: u32,
    };

    fn readHeader(self: *Decoder) Error!Header {
        const byte = try self.takeByte();
        switch (byte) {
            0x00...0x7f => return .{ .int = Integer.fromUnsigned(byte) },
            0xe0...0xff => return .{ .int = .{ .signed = @as(i8, @bitCast(byte)) } },
            0xc0 => return .nil,
            0xc2 => return .{ .boolean = false },
            0xc3 => return .{ .boolean = true },
            0xc4 => return .{ .binary = try self.readCountedBytes(try self.readUnsigned(u8)) },
            0xc5 => return .{ .binary = try self.readCountedBytes(try self.readUnsigned(u16)) },
            0xc6 => return .{ .binary = try self.readCountedBytes(try self.readUnsigned(u32)) },
            0xc7 => {
                const len = try self.readUnsigned(u8);
                try self.discard(1);
                try self.discard(len);
                return error.Unsupported;
            },
            0xc8 => {
                const len = try self.readUnsigned(u16);
                try self.discard(1);
                try self.discard(len);
                return error.Unsupported;
            },
            0xc9 => {
                const len = try self.readUnsigned(u32);
                try self.discard(1);
                try self.discard(len);
                return error.Unsupported;
            },
            0xca => {
                const raw = try self.takeArray(4);
                return .{ .float32 = @bitCast(std.mem.readInt(u32, raw, .big)) };
            },
            0xcb => {
                const raw = try self.takeArray(8);
                return .{ .float64 = @bitCast(std.mem.readInt(u64, raw, .big)) };
            },
            0xcc => return .{ .int = Integer.fromUnsigned(try self.readUnsigned(u8)) },
            0xcd => return .{ .int = Integer.fromUnsigned(try self.readUnsigned(u16)) },
            0xce => return .{ .int = Integer.fromUnsigned(try self.readUnsigned(u32)) },
            0xcf => return .{ .int = Integer.fromUnsigned(try self.readUnsigned(u64)) },
            0xd0 => return .{ .int = .{ .signed = try self.readSigned(i8) } },
            0xd1 => return .{ .int = .{ .signed = try self.readSigned(i16) } },
            0xd2 => return .{ .int = .{ .signed = try self.readSigned(i32) } },
            0xd3 => return .{ .int = .{ .signed = try self.readSigned(i64) } },
            0xd4 => {
                try self.discard(2);
                return error.Unsupported;
            },
            0xd5 => {
                try self.discard(3);
                return error.Unsupported;
            },
            0xd6 => {
                try self.discard(5);
                return error.Unsupported;
            },
            0xd7 => {
                try self.discard(9);
                return error.Unsupported;
            },
            0xd8 => {
                try self.discard(17);
                return error.Unsupported;
            },
            0xd9 => return .{ .string = try self.readCountedBytes(try self.readUnsigned(u8)) },
            0xda => return .{ .string = try self.readCountedBytes(try self.readUnsigned(u16)) },
            0xdb => return .{ .string = try self.readCountedBytes(try self.readUnsigned(u32)) },
            0xdc => return .{ .array = try self.collectionLength(try self.readUnsigned(u16)) },
            0xdd => return .{ .array = try self.collectionLength(try self.readUnsigned(u32)) },
            0xde => return .{ .map = try self.collectionLength(try self.readUnsigned(u16)) },
            0xdf => return .{ .map = try self.collectionLength(try self.readUnsigned(u32)) },
            0x80...0x8f => return .{ .map = try self.collectionLength(byte & 0x0f) },
            0x90...0x9f => return .{ .array = try self.collectionLength(byte & 0x0f) },
            0xa0...0xbf => return .{ .string = try self.readCountedBytes(byte & 0x1f) },
            else => return error.Unsupported,
        }
    }

    fn collectionLength(self: *Decoder, len: u64) Error!u32 {
        if (len > std.math.maxInt(u32) or len > self.limits.max_collection) return error.LimitExceeded;
        return @intCast(len);
    }

    fn readCountedBytes(self: *Decoder, len: u64) Error![]u8 {
        if (len > std.math.maxInt(usize)) return error.LimitExceeded;
        const size: usize = @intCast(len);
        try self.reserveBytes(size);
        const raw = try self.allocator.alloc(u8, size);
        self.reader.readSliceAll(raw) catch |err| return mapRead(err);
        self.bytes_read += size;
        return raw;
    }

    fn readUnsigned(self: *Decoder, comptime T: type) Error!u64 {
        const raw = try self.takeArray(@sizeOf(T));
        return std.mem.readInt(T, raw, .big);
    }

    fn readSigned(self: *Decoder, comptime T: type) Error!i64 {
        const raw = try self.takeArray(@sizeOf(T));
        return std.mem.readInt(T, raw, .big);
    }

    fn takeArray(self: *Decoder, comptime n: usize) Error!*[n]u8 {
        if (n > self.limits.max_bytes -| self.bytes_read) return error.LimitExceeded;
        const raw = self.reader.takeArray(n) catch |err| return mapRead(err);
        self.bytes_read += n;
        return raw;
    }

    fn takeByte(self: *Decoder) Error!u8 {
        if (self.bytes_read >= self.limits.max_bytes) return error.LimitExceeded;
        const byte = self.reader.takeByte() catch |err| return mapRead(err);
        self.bytes_read += 1;
        return byte;
    }

    fn discard(self: *Decoder, len: u64) Error!void {
        if (len > std.math.maxInt(usize)) return error.LimitExceeded;
        const size: usize = @intCast(len);
        if (size > self.limits.max_bytes -| self.bytes_read) return error.LimitExceeded;
        self.reader.discardAll(size) catch |err| return mapRead(err);
        self.bytes_read += size;
    }

    pub fn pushDepth(self: *Decoder) Error!void {
        if (self.depth >= self.limits.max_depth) return error.LimitExceeded;
        self.depth += 1;
    }

    pub fn popDepth(self: *Decoder) void {
        self.depth -= 1;
    }

    pub fn reserveCollection(self: *Decoder, len: u32, comptime element_size: usize, min_wire_bytes: usize) Error!void {
        const count: usize = len;
        const allocation = std.math.mul(usize, count, element_size) catch return error.LimitExceeded;
        const wire = std.math.mul(usize, count, min_wire_bytes) catch return error.LimitExceeded;
        if (wire > self.limits.max_bytes -| self.bytes_read) return error.LimitExceeded;
        if (allocation > self.limits.max_bytes -| self.allocation_bytes) return error.LimitExceeded;
        self.allocation_bytes += allocation;
    }

    /// Charges a decoded node allocation that has no wire bytes of its own.
    pub fn reserveAllocation(self: *Decoder, size: usize) Error!void {
        if (size > self.limits.max_bytes -| self.allocation_bytes) return error.LimitExceeded;
        self.allocation_bytes += size;
    }

    fn reserveBytes(self: *Decoder, size: usize) Error!void {
        if (size > self.limits.max_bytes -| self.bytes_read) return error.LimitExceeded;
        if (size > self.limits.max_bytes -| self.allocation_bytes) return error.LimitExceeded;
        self.allocation_bytes += size;
    }
};

pub fn kindOf(byte: u8) Kind {
    return switch (byte) {
        0xc0 => .nil,
        0xc2, 0xc3 => .boolean,
        0xc4, 0xc5, 0xc6 => .binary,
        0xc7, 0xc8, 0xc9, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8 => .ext,
        0xca, 0xcb => .float,
        0xcc, 0xcd, 0xce, 0xcf, 0xd0, 0xd1, 0xd2, 0xd3 => .int,
        0xd9, 0xda, 0xdb => .string,
        0xdc, 0xdd => .array,
        0xde, 0xdf => .map,
        0x00...0x7f, 0xe0...0xff => .int,
        0x80...0x8f => .map,
        0x90...0x9f => .array,
        0xa0...0xbf => .string,
        else => .ext,
    };
}

pub fn mapRead(err: anyerror) Error {
    return switch (err) {
        error.EndOfStream => error.Truncated,
        error.OutOfMemory => error.OutOfMemory,
        else => error.ReadFailed,
    };
}

pub fn decodeSlice(allocator: std.mem.Allocator, bytes: []const u8, limits: Limits) Error!Document {
    var reader = std.Io.Reader.fixed(bytes);
    const document = try decodeReader(allocator, &reader, limits);
    if (reader.peekByte()) |_| {
        var failed = document;
        failed.deinit();
        return error.TrailingData;
    } else |err| switch (err) {
        error.EndOfStream => return document,
        else => {
            var failed = document;
            failed.deinit();
            return error.ReadFailed;
        },
    }
}

pub fn decodeReader(allocator: std.mem.Allocator, reader: *std.Io.Reader, limits: Limits) Error!Document {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = .init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    var cursor = Decoder{
        .reader = reader,
        .allocator = arena.allocator(),
        .limits = limits,
    };
    const root = try cursor.readDom();
    return .{
        .arena = arena,
        .root = root,
        .bytes_read = cursor.bytes_read,
    };
}

pub fn writeNil(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeByte(0xc0);
}

pub fn writeBool(writer: *std.Io.Writer, value: bool) std.Io.Writer.Error!void {
    try writer.writeByte(if (value) 0xc3 else 0xc2);
}

pub fn writeInt(writer: *std.Io.Writer, value: i64) std.Io.Writer.Error!void {
    if (value >= 0) return writeUint(writer, @intCast(value));
    if (value >= -32) return writer.writeByte(@bitCast(@as(i8, @intCast(value))));
    if (value >= std.math.minInt(i8)) return writeSigned(writer, i8, @intCast(value), 0xd0);
    if (value >= std.math.minInt(i16)) return writeSigned(writer, i16, @intCast(value), 0xd1);
    if (value >= std.math.minInt(i32)) return writeSigned(writer, i32, @intCast(value), 0xd2);
    return writeSigned(writer, i64, value, 0xd3);
}

pub fn writeUint(writer: *std.Io.Writer, value: u64) std.Io.Writer.Error!void {
    if (value <= 0x7f) return writer.writeByte(@intCast(value));
    if (value <= 0xff) return writeUnsigned(writer, u8, @intCast(value), 0xcc);
    if (value <= 0xffff) return writeUnsigned(writer, u16, @intCast(value), 0xcd);
    if (value <= 0xffffffff) return writeUnsigned(writer, u32, @intCast(value), 0xce);
    return writeUnsigned(writer, u64, value, 0xcf);
}

pub fn writeInteger(writer: *std.Io.Writer, value: Integer) std.Io.Writer.Error!void {
    switch (value) {
        .signed => |signed| try writeInt(writer, signed),
        .unsigned => |unsigned| try writeUint(writer, unsigned),
    }
}

pub fn writeFloat32(writer: *std.Io.Writer, value: f32) std.Io.Writer.Error!void {
    try writer.writeByte(0xca);
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, @bitCast(value), .big);
    try writer.writeAll(&buf);
}

pub fn writeFloat64(writer: *std.Io.Writer, value: f64) std.Io.Writer.Error!void {
    try writer.writeByte(0xcb);
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, @bitCast(value), .big);
    try writer.writeAll(&buf);
}

pub fn writeString(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    try writeLength(writer, value.len, 31, 0xa0, 0xd9, 0xda, 0xdb);
    try writer.writeAll(value);
}

pub fn writeBinary(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    if (value.len > std.math.maxInt(u32)) return error.WriteFailed;
    if (value.len <= 0xff) {
        try writer.writeByte(0xc4);
        try writer.writeByte(@intCast(value.len));
    } else if (value.len <= 0xffff) {
        try writer.writeByte(0xc5);
        try writeBe(writer, u16, @intCast(value.len));
    } else {
        try writer.writeByte(0xc6);
        try writeBe(writer, u32, @intCast(value.len));
    }
    try writer.writeAll(value);
}

pub fn writeArrayHeader(writer: *std.Io.Writer, len: u32) std.Io.Writer.Error!void {
    try writeLength(writer, len, 15, 0x90, null, 0xdc, 0xdd);
}

pub fn writeMapHeader(writer: *std.Io.Writer, len: u32) std.Io.Writer.Error!void {
    try writeLength(writer, len, 15, 0x80, null, 0xde, 0xdf);
}

fn writeLength(
    writer: *std.Io.Writer,
    len: usize,
    fix_max: usize,
    fix_base: u8,
    len8: ?u8,
    len16: u8,
    len32: u8,
) std.Io.Writer.Error!void {
    if (len > std.math.maxInt(u32)) return error.WriteFailed;
    if (len <= fix_max) return writer.writeByte(fix_base | @as(u8, @intCast(len)));
    if (len8) |marker| {
        if (len <= 0xff) {
            try writer.writeByte(marker);
            return writer.writeByte(@intCast(len));
        }
    }
    if (len <= 0xffff) {
        try writer.writeByte(len16);
        return writeBe(writer, u16, @intCast(len));
    }
    try writer.writeByte(len32);
    return writeBe(writer, u32, @intCast(len));
}

fn writeUnsigned(writer: *std.Io.Writer, comptime T: type, value: T, marker: u8) std.Io.Writer.Error!void {
    try writer.writeByte(marker);
    try writeBe(writer, T, value);
}

fn writeSigned(writer: *std.Io.Writer, comptime T: type, value: T, marker: u8) std.Io.Writer.Error!void {
    try writer.writeByte(marker);
    try writeBe(writer, T, value);
}

fn writeBe(writer: *std.Io.Writer, comptime T: type, value: T) std.Io.Writer.Error!void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, value, .big);
    try writer.writeAll(&buf);
}

pub fn encode(writer: *std.Io.Writer, value: Value) std.Io.Writer.Error!void {
    switch (value) {
        .nil => try writeNil(writer),
        .boolean => |item| try writeBool(writer, item),
        .int => |item| try writeInteger(writer, item),
        .float32 => |item| try writeFloat32(writer, item),
        .float64 => |item| try writeFloat64(writer, item),
        .string => |item| try writeString(writer, item),
        .binary => |item| try writeBinary(writer, item),
        .array => |items| {
            if (items.len > std.math.maxInt(u32)) return error.WriteFailed;
            try writeArrayHeader(writer, @intCast(items.len));
            for (items) |item| try encode(writer, item);
        },
        .map => |items| {
            if (items.len > std.math.maxInt(u32)) return error.WriteFailed;
            try writeMapHeader(writer, @intCast(items.len));
            for (items) |item| {
                try encode(writer, item.key);
                try encode(writer, item.value);
            }
        },
    }
}

pub fn encodeAlloc(allocator: std.mem.Allocator, value: Value) (std.Io.Writer.Error || error{OutOfMemory})![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try encode(&out.writer, value);
    return out.toOwnedSlice();
}

pub fn eql(left: Value, right: Value) bool {
    return switch (left) {
        .nil => right == .nil,
        .boolean => |value| right == .boolean and right.boolean == value,
        .int => |value| right == .int and value.eql(right.int),
        .float32 => |value| right == .float32 and @as(u32, @bitCast(value)) == @as(u32, @bitCast(right.float32)),
        .float64 => |value| right == .float64 and @as(u64, @bitCast(value)) == @as(u64, @bitCast(right.float64)),
        .string => |value| right == .string and std.mem.eql(u8, value, right.string),
        .binary => |value| right == .binary and std.mem.eql(u8, value, right.binary),
        .array => |items| blk: {
            if (right != .array or items.len != right.array.len) break :blk false;
            for (items, right.array) |a, b| if (!eql(a, b)) break :blk false;
            break :blk true;
        },
        .map => |items| blk: {
            if (right != .map or items.len != right.map.len) break :blk false;
            for (items, right.map) |a, b| {
                if (!eql(a.key, b.key) or !eql(a.value, b.value)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn roundtrip(bytes: []const u8) !void {
    const allocator = std.testing.allocator;
    var document = try decodeSlice(allocator, bytes, .{});
    defer document.deinit();
    const encoded = try encodeAlloc(allocator, document.root);
    defer allocator.free(encoded);
    var again = try decodeSlice(allocator, encoded, .{});
    defer again.deinit();
    try std.testing.expect(eql(document.root, again.root));
}

test "scalars use the shortest integer and distinct string and binary forms" {
    const allocator = std.testing.allocator;
    const one = try encodeAlloc(allocator, .{ .int = Integer.fromSigned(1) });
    defer allocator.free(one);
    try std.testing.expectEqualSlices(u8, &.{0x01}, one);

    const negative = try encodeAlloc(allocator, .{ .int = Integer.fromSigned(-1) });
    defer allocator.free(negative);
    try std.testing.expectEqualSlices(u8, &.{0xff}, negative);

    const wide = try encodeAlloc(allocator, .{ .int = Integer.fromSigned(128) });
    defer allocator.free(wide);
    try std.testing.expectEqualSlices(u8, &.{ 0xcc, 0x80 }, wide);

    const text = try encodeAlloc(allocator, .{ .string = "hi" });
    defer allocator.free(text);
    try std.testing.expectEqualSlices(u8, &.{ 0xa2, 'h', 'i' }, text);

    const binary = try encodeAlloc(allocator, .{ .binary = "hi" });
    defer allocator.free(binary);
    try std.testing.expectEqualSlices(u8, &.{ 0xc4, 2, 'h', 'i' }, binary);

    var text_doc = try decodeSlice(allocator, text, .{});
    defer text_doc.deinit();
    var bin_doc = try decodeSlice(allocator, binary, .{});
    defer bin_doc.deinit();
    try std.testing.expect(text_doc.root == .string);
    try std.testing.expect(bin_doc.root == .binary);
    try std.testing.expect(!eql(text_doc.root, bin_doc.root));
}

test "integer boundaries and floats round-trip" {
    try roundtrip(&.{0xc0});
    try roundtrip(&.{0xc2});
    try roundtrip(&.{0xc3});
    try roundtrip(&.{0x00});
    try roundtrip(&.{0x7f});
    try roundtrip(&.{ 0xcc, 0xff });
    try roundtrip(&.{ 0xcd, 0xff, 0xff });
    try roundtrip(&.{ 0xce, 0xff, 0xff, 0xff, 0xff });
    try roundtrip(&.{ 0xcf, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff });
    try roundtrip(&.{0xe0});
    try roundtrip(&.{ 0xd0, 0x80 });
    try roundtrip(&.{ 0xd1, 0x80, 0x00 });
    try roundtrip(&.{ 0xd2, 0x80, 0x00, 0x00, 0x00 });
    try roundtrip(&.{ 0xd3, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 });

    const allocator = std.testing.allocator;
    const f32_bytes = try encodeAlloc(allocator, .{ .float32 = -1.5 });
    defer allocator.free(f32_bytes);
    try std.testing.expectEqual(@as(u8, 0xca), f32_bytes[0]);
    var f32_doc = try decodeSlice(allocator, f32_bytes, .{});
    defer f32_doc.deinit();
    try std.testing.expect(f32_doc.root == .float32);

    const f64_bytes = try encodeAlloc(allocator, .{ .float64 = -1.5 });
    defer allocator.free(f64_bytes);
    try std.testing.expectEqual(@as(u8, 0xcb), f64_bytes[0]);
    var f64_doc = try decodeSlice(allocator, f64_bytes, .{});
    defer f64_doc.deinit();
    try std.testing.expect(f64_doc.root == .float64);
}

test "containers preserve order and reject bombs, trailing bytes, and ext" {
    const allocator = std.testing.allocator;
    var list = [_]Value{
        .nil,
        .{ .boolean = true },
        .{ .string = "a" },
    };
    var entries = [_]Value.Entry{
        .{ .key = .{ .int = Integer.fromSigned(2) }, .value = .{ .boolean = false } },
        .{ .key = .{ .string = "k" }, .value = .{ .array = list[0..1] } },
    };
    const encoded = try encodeAlloc(allocator, .{ .map = &entries });
    defer allocator.free(encoded);
    var document = try decodeSlice(allocator, encoded, .{});
    defer document.deinit();
    try std.testing.expectEqual(@as(usize, 2), document.root.map.len);
    try std.testing.expect(document.root.map[0].key.int.eql(Integer.fromSigned(2)));
    try std.testing.expect(document.root.map[1].value == .array);

    try std.testing.expectError(error.TrailingData, decodeSlice(allocator, &.{ 0xc0, 0x00 }, .{}));
    try std.testing.expectError(error.Truncated, decodeSlice(allocator, &.{0xa5}, .{}));
    try std.testing.expectError(error.Unsupported, decodeSlice(allocator, &.{ 0xd4, 0x00, 0x00 }, .{}));
    try std.testing.expectError(error.LimitExceeded, decodeSlice(allocator, &.{ 0x91, 0x91, 0xc0 }, .{ .max_depth = 1 }));
    try std.testing.expectError(error.LimitExceeded, decodeSlice(allocator, &.{ 0x91, 0xc0 }, .{ .max_collection = 0 }));
}

test "streaming decode accepts payloads larger than the reader buffer" {
    const allocator = std.testing.allocator;
    const payload = try allocator.alloc(u8, 24 * 1024);
    defer allocator.free(payload);
    @memset(payload, 0x5a);

    const encoded = try encodeAlloc(allocator, .{ .binary = payload });
    defer allocator.free(encoded);
    var source = std.Io.Reader.fixed(encoded);
    var document = try decodeReader(allocator, &source, .{});
    defer document.deinit();
    try std.testing.expectEqualSlices(u8, payload, document.root.binary);
}

test "advertised collection allocations are bounded by max bytes" {
    const huge_array = [_]u8{ 0xdd, 0x00, 0x10, 0x00, 0x00 };
    try std.testing.expectError(error.LimitExceeded, decodeSlice(
        std.testing.allocator,
        &huge_array,
        .{ .max_collection = std.math.maxInt(u32), .max_bytes = 1024 },
    ));
    const huge_map = [_]u8{ 0xdf, 0x00, 0x08, 0x00, 0x00 };
    try std.testing.expectError(error.LimitExceeded, decodeSlice(
        std.testing.allocator,
        &huge_map,
        .{ .max_collection = std.math.maxInt(u32), .max_bytes = 1024 },
    ));
}

fn decodeOnly(allocator: std.mem.Allocator) !void {
    var document = try decodeSlice(allocator, &.{ 0x81, 0xa1, 'k', 0xa1, 'v' }, .{});
    document.deinit();
}

test "messagepack decode frees partial allocations on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, decodeOnly, .{});
}
