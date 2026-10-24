//! Differential conformance: every module under `tests/conformance/cases`
//! is evaluated twice against the same Pkl executable. Pkl describes the
//! module itself through `tests/conformance/describe.pkl`; zig-pkl decodes the
//! module's pkl-binary result and describes it the same way. Both views must
//! agree.
//!
//! A case whose first line is `// min-pkl: X.Y.Z` is skipped on older Pkl
//! releases.

const std = @import("std");
const zig_pkl = @import("zig_pkl");

const cases_path = "tests/conformance/cases";
const describe_path = "tests/conformance/describe.pkl";

const value = zig_pkl.value;
const Value = value.Value;
const Json = std.json.Value;

test "zig-pkl decodes every conformance module as Pkl describes it" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const executable = try pklExecutable(allocator);
    defer if (executable.owned) allocator.free(executable.path);

    const server_version = zig_pkl.getVersion(allocator, io, executable.path) catch |err| return skipWithoutPkl(err);
    const manager = try zig_pkl.Manager.init(allocator, io, &.{ executable.path, "server" }, zig_pkl.Logger.noop);
    defer manager.deinit();
    var rejected: ?[]u8 = null;
    defer if (rejected) |text| allocator.free(text);
    const evaluator = try manager.createEvaluator(zig_pkl.Options.preconfigured(), &rejected);
    defer evaluator.close();

    const describe_uri = try fileUri(allocator, io, describe_path);
    defer allocator.free(describe_uri);
    const expression = try std.fmt.allocPrint(allocator, "import(\"{s}\").render(module)", .{describe_uri});
    defer allocator.free(expression);

    var names = try caseNames(allocator, io);
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    var checked: usize = 0;
    var failed: usize = 0;
    for (names.items) |name| {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        const path = try std.fs.path.join(scratch, &.{ cases_path, name });
        const source = try std.Io.Dir.cwd().readFileAlloc(io, path, scratch, .limited(1 << 20));
        if (try minimumVersion(source)) |minimum| {
            if (!server_version.atLeast(minimum)) continue;
        }

        const expected_text = try describeWithPkl(scratch, io, executable.path, expression, path);
        var expected = try std.json.parseFromSliceLeaky(Json, scratch, expected_text, .{});

        const case_uri = try fileUri(scratch, io, path);
        var failure: ?[]u8 = null;
        defer if (failure) |text| allocator.free(text);
        var tree = evaluator.evaluate(case_uri, null, null, &failure) catch |err| {
            std.debug.print("{s}: zig-pkl evaluation failed: {t} {s}\n", .{ name, err, failure orelse "" });
            failed += 1;
            continue;
        };
        defer tree.deinit();
        var described: std.Io.Writer.Allocating = .init(scratch);
        var stringify: std.json.Stringify = .{ .writer = &described.writer };
        try describe(&stringify, tree.root);
        var actual = try std.json.parseFromSliceLeaky(Json, scratch, described.written(), .{});

        // The module's own class is named differently by the two views.
        forgetRootClass(&expected);
        forgetRootClass(&actual);
        checked += 1;
        if (!equal(expected, actual)) {
            failed += 1;
            std.debug.print("{s}: decoded value differs from Pkl\n  pkl:     {f}\n  zig-pkl: {f}\n", .{
                name,
                std.json.fmt(expected, .{}),
                std.json.fmt(actual, .{}),
            });
        }
    }
    try std.testing.expect(checked > 0);
    try std.testing.expectEqual(@as(usize, 0), failed);
}

const DescribeError = std.json.Stringify.Error || error{ CaseTooLarge, UnsupportedCase };

fn describe(s: *std.json.Stringify, v: *const Value) DescribeError!void {
    switch (v.*) {
        .nil => try s.write(null),
        .boolean => |b| try s.write(b),
        .string => |text| try s.write(text),
        .int => |integer| try tagged(s, "int", switch (integer) {
            .signed => |n| @as(i128, n),
            .unsigned => |n| @as(i128, n),
        }),
        .float => |f| {
            try s.beginObject();
            try s.objectField("float");
            if (std.math.isNan(f)) {
                try s.write("NaN");
            } else if (std.math.isInf(f)) {
                try s.write(if (f > 0) "Infinity" else "-Infinity");
            } else {
                try s.write(f);
            }
            try s.endObject();
        },
        .duration => |q| try quantity(s, "duration", q),
        .data_size => |q| try quantity(s, "dataSize", q),
        .pair => |p| {
            try s.beginObject();
            try s.objectField("pair");
            try s.beginArray();
            try describe(s, p.first);
            try describe(s, p.second);
            try s.endArray();
            try s.endObject();
        },
        .list => |items| try sequence(s, "list", items),
        .set => |items| try sequence(s, "set", items),
        .listing => |items| try sequence(s, "listing", items),
        .map => |entries| try entryList(s, "map", entries),
        .mapping => |entries| try entryList(s, "mapping", entries),
        .int_seq => |seq| {
            try s.beginObject();
            try s.objectField("intSeq");
            try s.beginArray();
            for ([_]value.Integer{ seq.start, seq.end, seq.step }) |integer| switch (integer) {
                .signed => |n| try s.write(n),
                .unsigned => |n| try s.write(n),
            };
            try s.endArray();
            try s.endObject();
        },
        .regex => |pattern| try tagged(s, "regex", pattern),
        .class => |name| try tagged(s, "class", simpleName(name.name)),
        .type_alias => |name| try tagged(s, "typeAlias", simpleName(name.name)),
        .function => try tagged(s, "function", true),
        .bytes => |bytes| {
            var buffer: [4096]u8 = undefined;
            const encoder = std.base64.standard.Encoder;
            if (encoder.calcSize(bytes.len) > buffer.len) return error.CaseTooLarge;
            try tagged(s, "bytes", encoder.encode(&buffer, bytes));
        },
        .object => |object| {
            try s.beginObject();
            try s.objectField("object");
            try s.beginObject();
            try s.objectField("class");
            try s.write(simpleName(object.class_name));
            try s.objectField("members");
            try s.beginArray();
            for (object.members) |member| switch (member) {
                .property => |property| {
                    try s.beginArray();
                    try s.write(property.name);
                    try describe(s, property.value);
                    try s.endArray();
                },
                .entry => |entry| {
                    try s.beginArray();
                    try describe(s, entry.key);
                    try describe(s, entry.value);
                    try s.endArray();
                },
                .element => {},
            };
            try s.endArray();
            try s.objectField("elements");
            try s.beginArray();
            for (object.members) |member| switch (member) {
                .element => |element| try describe(s, element.value),
                else => {},
            };
            try s.endArray();
            try s.endObject();
            try s.endObject();
        },
        .reference => return error.UnsupportedCase,
    }
}

fn tagged(s: *std.json.Stringify, tag: []const u8, payload: anytype) !void {
    try s.beginObject();
    try s.objectField(tag);
    try s.write(payload);
    try s.endObject();
}

fn quantity(s: *std.json.Stringify, tag: []const u8, q: value.Quantity) !void {
    try s.beginObject();
    try s.objectField(tag);
    try s.beginArray();
    try s.write(q.value);
    try s.write(q.unit);
    try s.endArray();
    try s.endObject();
}

fn sequence(s: *std.json.Stringify, tag: []const u8, items: []const *Value) DescribeError!void {
    try s.beginObject();
    try s.objectField(tag);
    try s.beginArray();
    for (items) |item| try describe(s, item);
    try s.endArray();
    try s.endObject();
}

fn entryList(s: *std.json.Stringify, tag: []const u8, entries: []const value.Entry) DescribeError!void {
    try s.beginObject();
    try s.objectField(tag);
    try s.beginArray();
    for (entries) |entry| {
        try s.beginArray();
        try describe(s, entry.key);
        try describe(s, entry.value);
        try s.endArray();
    }
    try s.endArray();
    try s.endObject();
}

/// `module#Class` and `pkl.base#Dynamic` become `Class` and `Dynamic`.
fn simpleName(qualified: []const u8) []const u8 {
    const start = if (std.mem.lastIndexOfAny(u8, qualified, "#.")) |index| index + 1 else 0;
    return qualified[start..];
}

fn forgetRootClass(root: *Json) void {
    if (root.* != .object) return;
    const object = root.object.getPtr("object") orelse return;
    if (object.* != .object) return;
    if (object.object.getPtr("class")) |class| class.* = .null;
}

/// Numbers compare by value, so a duration of `5` equals one of `5.0`; the
/// `int` and `float` tags keep integer and float scalars apart. Object
/// members compare as an unordered collection.
fn equal(left: Json, right: Json) bool {
    if (number(left)) |l| {
        const r = number(right) orelse return false;
        return l.eql(r);
    }
    switch (left) {
        .null => return right == .null,
        .bool => |b| return right == .bool and right.bool == b,
        .string => |text| return right == .string and std.mem.eql(u8, text, right.string),
        .array => |items| {
            if (right != .array or right.array.items.len != items.items.len) return false;
            for (items.items, right.array.items) |l, r| if (!equal(l, r)) return false;
            return true;
        },
        .object => |map| {
            if (right != .object or right.object.count() != map.count()) return false;
            var it = map.iterator();
            while (it.next()) |entry| {
                const other = right.object.get(entry.key_ptr.*) orelse return false;
                const matches = if (std.mem.eql(u8, entry.key_ptr.*, "members"))
                    sameMembers(entry.value_ptr.*, other)
                else
                    equal(entry.value_ptr.*, other);
                if (!matches) return false;
            }
            return true;
        },
        else => unreachable,
    }
}

fn sameMembers(left: Json, right: Json) bool {
    if (left != .array or right != .array) return equal(left, right);
    const l = left.array.items;
    const r = right.array.items;
    if (l.len != r.len) return false;
    outer: for (l) |member| {
        for (r) |candidate| if (equal(member, candidate)) continue :outer;
        return false;
    }
    return true;
}

const Number = union(enum) {
    integer: i128,
    float: f64,

    fn eql(self: Number, other: Number) bool {
        if (self == .integer and other == .integer) return self.integer == other.integer;
        return self.toFloat() == other.toFloat();
    }

    fn toFloat(self: Number) f64 {
        return switch (self) {
            .integer => |n| @floatFromInt(n),
            .float => |f| f,
        };
    }
};

fn number(v: Json) ?Number {
    return switch (v) {
        .integer => |n| .{ .integer = n },
        .float => |f| .{ .float = f },
        .number_string => |text| if (std.fmt.parseInt(i128, text, 10)) |n|
            .{ .integer = n }
        else |_| if (std.fmt.parseFloat(f64, text)) |f| .{ .float = f } else |_| null,
        else => null,
    };
}

fn minimumVersion(source: []const u8) !?zig_pkl.version.Version {
    const prefix = "// min-pkl: ";
    if (!std.mem.startsWith(u8, source, prefix)) return null;
    const line_end = std.mem.indexOfScalar(u8, source, '\n') orelse source.len;
    return try zig_pkl.version.Version.parse(std.mem.trim(u8, source[prefix.len..line_end], " \r"));
}

fn describeWithPkl(allocator: std.mem.Allocator, io: std.Io, executable: []const u8, expression: []const u8, path: []const u8) ![]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ executable, "eval", "--expression", expression, path },
    });
    switch (result.term) {
        .exited => |code| if (code == 0) return result.stdout,
        else => {},
    }
    std.debug.print("pkl eval {s} failed:\n{s}\n", .{ path, result.stderr });
    return error.PklFailed;
}

fn caseNames(allocator: std.mem.Allocator, io: std.Io) !std.ArrayList([]u8) {
    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    var dir = try std.Io.Dir.cwd().openDir(io, cases_path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".pkl")) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    std.mem.sortUnstable([]u8, names.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return names;
}

const PklCommand = struct { path: []const u8, owned: bool };

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

/// A missing Pkl skips the suite unless `ZIG_PKL_REQUIRE_PKL=1`.
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
