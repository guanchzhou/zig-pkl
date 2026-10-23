//! Bindings for every generated Pkl module. Regenerate this file instead of editing it.

pub const deps = struct {
    pub const shared = struct {
        pub const units = @import("deps/shared/units.zig");
    };
};
pub const fixture = struct {
    pub const app = @import("fixture/app.zig");
    pub const geometry = @import("fixture/geometry.zig");
    pub const graph = struct {
        pub const a = @import("fixture/graph/a.zig");
        pub const b = @import("fixture/graph/b.zig");
    };
    pub const refs = @import("fixture/refs.zig");
};
