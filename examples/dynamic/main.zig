//! Walks an evaluated value without declaring Zig types for it.

const std = @import("std");
const zig_pkl = @import("zig_pkl");
const Value = zig_pkl.Value;

const module_text =
    \\name = "edge"
    \\ports = List(80, 443)
    \\weights = Map("a", 0.25, "b", 0.75)
    \\owner {
    \\  team = "platform"
    \\  oncall = null
    \\}
    \\servers {
    \\  "one"
    \\  "two"
    \\}
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const pkl = init.environ_map.get("PKL_EXEC") orelse "pkl";

    const manager = try zig_pkl.Manager.init(allocator, io, &.{ pkl, "server" }, zig_pkl.Logger.noop);
    defer manager.deinit();
    var rejected: ?[]u8 = null;
    defer if (rejected) |text| allocator.free(text);
    const evaluator = try manager.createEvaluator(zig_pkl.Options.restricted(), &rejected);
    defer evaluator.close();

    var failure: ?[]u8 = null;
    defer if (failure) |text| allocator.free(text);
    var tree = try evaluator.evaluateSource(.text(module_text), null, &failure);
    defer tree.deinit();

    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    const out = &stdout.interface;

    // Look up one property directly.
    const name = zig_pkl.value.findProperty(tree.root, "name").?;
    try out.print("name is {s}\n", .{name.string});

    try describe(out, tree.root, 0);
    try out.flush();
}

fn describe(out: *std.Io.Writer, value: *const Value, depth: usize) !void {
    switch (value.*) {
        .nil => try out.writeAll("null\n"),
        .boolean => |b| try out.print("{}\n", .{b}),
        .int => |i| switch (i) {
            inline else => |n| try out.print("{d}\n", .{n}),
        },
        .float => |f| try out.print("{d}\n", .{f}),
        .string => |s| try out.print("\"{s}\"\n", .{s}),
        .list, .listing, .set => |items| {
            try out.print("{t} of {d}\n", .{ value.*, items.len });
            for (items) |item| {
                try indent(out, depth + 1);
                try describe(out, item, depth + 1);
            }
        },
        .map, .mapping => |entries| {
            try out.print("{t} of {d}\n", .{ value.*, entries.len });
            for (entries) |entry| {
                try indent(out, depth + 1);
                try out.print("{s} => ", .{entry.key.string});
                try describe(out, entry.value, depth + 1);
            }
        },
        .object => |object| {
            try out.print("{s} object\n", .{object.class_name});
            for (object.members) |member| {
                try indent(out, depth + 1);
                switch (member) {
                    .property => |property| {
                        try out.print("{s}: ", .{property.name});
                        try describe(out, property.value, depth + 1);
                    },
                    .entry => |entry| {
                        try out.writeAll("[entry] ");
                        try describe(out, entry.value, depth + 1);
                    },
                    .element => |element| {
                        switch (element.index) {
                            inline else => |n| try out.print("[{d}] ", .{n}),
                        }
                        try describe(out, element.value, depth + 1);
                    },
                }
            }
        },
        else => try out.print("{t}\n", .{value.*}),
    }
}

fn indent(out: *std.Io.Writer, depth: usize) !void {
    for (0..depth) |_| try out.writeAll("  ");
}
