//! Forces semantic analysis of every generated declaration, including the
//! decode, deinit, and load helpers, for the target being built.

const std = @import("std");
const bindings = @import("fixture_bindings");

fn analyze(comptime T: type) void {
    inline for (comptime std.meta.declarations(T)) |name| {
        if (comptime std.mem.startsWith(u8, name, "pkl_") or std.mem.eql(u8, name, "std") or std.mem.eql(u8, name, "zig_pkl")) continue;
        if (@TypeOf(@field(T, name)) == type) {
            switch (@typeInfo(@field(T, name))) {
                .@"struct", .@"union", .@"enum" => analyze(@field(T, name)),
                else => {},
            }
        } else _ = &@field(T, name);
    }
    switch (@typeInfo(T)) {
        .@"struct", .@"union" => _ = @sizeOf(T),
        else => {},
    }
}

test "generated bindings compile" {
    comptime analyze(bindings);
}
