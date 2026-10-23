//! Transport contract used by the evaluator manager.
//! A backend sends and receives one framed message at a time.

const std = @import("std");
const message = @import("protocol/message.zig");

pub const Message = message.Message;
pub const Owned = message.Owned;

pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send: *const fn (ptr: *anyopaque, payload: *const Message) anyerror!void,
        receive: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!Owned,
        close: *const fn (ptr: *anyopaque) void,
    };

    pub fn send(self: Backend, payload: *const Message) anyerror!void {
        return self.vtable.send(self.ptr, payload);
    }

    pub fn receive(self: Backend, allocator: std.mem.Allocator) anyerror!Owned {
        return self.vtable.receive(self.ptr, allocator);
    }

    pub fn close(self: Backend) void {
        self.vtable.close(self.ptr);
    }
};
