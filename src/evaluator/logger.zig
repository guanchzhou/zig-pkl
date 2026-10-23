//! Evaluator log events delivered by message code 0x25.

const std = @import("std");

pub const Event = struct {
    evaluator_id: i64,
    level: i64,
    message: []const u8,
    frame_uri: []const u8,
};

/// Logger callbacks receive borrowed event slices that are valid only for the
/// duration of `log`. Implementations that retain text must copy it.
pub const Logger = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        log: *const fn (ptr: *anyopaque, event: Event) void,
    };

    pub fn emit(self: Logger, event: Event) void {
        self.vtable.log(self.ptr, event);
    }

    pub const noop: Logger = .{
        .ptr = undefined,
        .vtable = &.{ .log = noopLog },
    };
};

fn noopLog(_: *anyopaque, _: Event) void {}

pub const Stderr = struct {
    pub fn logger() Logger {
        return .{
            .ptr = undefined,
            .vtable = &.{ .log = log },
        };
    }

    fn log(_: *anyopaque, event: Event) void {
        const scoped = std.log.scoped(.pkl);
        if (event.level == 0) {
            scoped.debug("{s}: {s}", .{ event.frame_uri, event.message });
        } else {
            scoped.warn("{s}: {s}", .{ event.frame_uri, event.message });
        }
    }
};

/// A thread-safe test and diagnostic logger that retains its latest message in
/// internal storage, truncated to 1024 bytes.
pub const Capture = struct {
    lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    count: usize = 0,
    last_level: i64 = 0,
    last_message: []const u8 = "",
    message_buffer: [1024]u8 = undefined,

    pub fn logger(self: *Capture) Logger {
        return .{
            .ptr = self,
            .vtable = &.{ .log = log },
        };
    }

    fn log(ptr: *anyopaque, event: Event) void {
        const self: *Capture = @ptrCast(@alignCast(ptr));
        self.acquire();
        defer self.release();
        self.count += 1;
        self.last_level = event.level;
        const len = @min(event.message.len, self.message_buffer.len);
        @memcpy(self.message_buffer[0..len], event.message[0..len]);
        self.last_message = self.message_buffer[0..len];
    }

    fn acquire(self: *Capture) void {
        while (self.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.Thread.yield() catch {};
        }
    }

    fn release(self: *Capture) void {
        self.lock.store(false, .release);
    }
};

test "capture logger records trace events" {
    var capture = Capture{};
    capture.logger().emit(.{
        .evaluator_id = 1,
        .level = 0,
        .message = "hello",
        .frame_uri = "repl:test",
    });
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqualStrings("hello", capture.last_message);
}

test "capture logger serializes concurrent writers and owns message bytes" {
    var capture = Capture{};
    const Worker = struct {
        fn run(target: *Capture) void {
            var buffer = "thread".*;
            target.logger().emit(.{
                .evaluator_id = 1,
                .level = 2,
                .message = &buffer,
                .frame_uri = "repl:text",
            });
            @memset(&buffer, 'x');
        }
    };
    var threads: [8]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Worker.run, .{&capture});
    for (threads) |thread| thread.join();
    try std.testing.expectEqual(@as(usize, threads.len), capture.count);
    try std.testing.expectEqualStrings("thread", capture.last_message);
}
