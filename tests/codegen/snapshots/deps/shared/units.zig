//! Bindings for the Pkl module `shared.units`. Regenerate this file instead of editing it.
//!
//! Units shared between packages.

const std = @import("std");
const zig_pkl = @import("zig_pkl");

/// An amount of money.
pub const Money = struct {
    amount: f64,
    currency: MoneyCurrency = .eur,

    pub const pkl_class = "shared.units#Money";

    pub fn decode(allocator: std.mem.Allocator, root: *const zig_pkl.Value) zig_pkl.convert.Error!@This() {
        return zig_pkl.convert.into(@This(), allocator, root);
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        zig_pkl.convert.freeInto(@This(), allocator, self.*);
        self.* = undefined;
    }
};

pub const Percent = f64;

pub const MoneyCurrency = enum {
    eur,
    usd,

    pub const pkl_names = .{ .eur = "EUR", .usd = "USD" };
};
