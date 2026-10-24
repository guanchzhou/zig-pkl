//! Handles evaluation errors, rejected settings, log messages, timeouts, and
//! cancellation.

const std = @import("std");
const zig_pkl = @import("zig_pkl");

/// Prints `trace()` output and warnings that Pkl sends while evaluating.
const PrintLogger = struct {
    fn logger(self: *PrintLogger) zig_pkl.Logger {
        return .{ .ptr = self, .vtable = &.{ .log = log } };
    }

    /// Runs on the manager's response thread, so keep it short. The event
    /// text is only valid during the call.
    fn log(_: *anyopaque, event: zig_pkl.logger.Event) void {
        const level = if (event.level == 0) "trace" else "warn";
        std.debug.print("[{s}] {s} ({s})\n", .{ level, event.message, event.frame_uri });
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const pkl = init.environ_map.get("PKL_EXEC") orelse "pkl";

    var print_logger = PrintLogger{};
    const manager = try zig_pkl.Manager.init(allocator, io, &.{ pkl, "server" }, zig_pkl.Logger.noop);
    defer manager.deinit();

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};

    // Pkl rejects settings it cannot use, and `rejected` holds its reason.
    // Pkl before 0.29 exits on this one instead: the manager then fails
    // every request with `error.Closed`, and the server's stderr says why.
    var rejected: ?[]u8 = null;
    defer if (rejected) |text| allocator.free(text);
    {
        const disposable = try zig_pkl.Manager.init(allocator, io, &.{ pkl, "server" }, zig_pkl.Logger.noop);
        defer disposable.deinit();
        var invalid = zig_pkl.Options.restricted();
        invalid.allowed_modules = &.{"("};
        if (disposable.createEvaluator(invalid, &rejected)) |evaluator| {
            evaluator.close();
        } else |err| switch (err) {
            error.Rejected => try out.print("rejected: {s}\n", .{reason(rejected.?)}),
            error.Closed => {
                const stderr = try disposable.serverStderr(allocator);
                defer if (stderr) |text| allocator.free(text);
                try out.print("server exited: {s}\n", .{reason(stderr orelse "")});
            },
            else => return err,
        }
    }

    var options = zig_pkl.Options.restricted();
    options.logger = print_logger.logger();
    const evaluator = try manager.createEvaluator(options, &rejected);
    defer evaluator.close();

    // `trace` reaches the logger, and the value is still returned.
    var failure: ?[]u8 = null;
    defer if (failure) |text| allocator.free(text);
    var traced = try evaluator.evaluateSource(.text("total = trace(List(1, 2, 3).fold(0, (a, b) -> a + b))"), "total", &failure);
    traced.deinit();

    // A failed evaluation returns `error.EvaluationFailed` and the message.
    if (evaluator.evaluateSource(.text("port: UInt16 = 70000"), "port", &failure)) |result| {
        var tree = result;
        tree.deinit();
    } else |err| switch (err) {
        error.EvaluationFailed => {
            try out.print("evaluation failed: {s}\n", .{reason(failure.?)});
            allocator.free(failure.?);
            failure = null;
        },
        else => return err,
    }

    // A client-side deadline stops waiting; the server finishes on its own.
    const slow = "total = IntSeq(1, 50000000).fold(0, (a, b) -> a + b)";
    if (evaluator.evaluateWithOptions("repl:text", slow, "total", &failure, .{
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(50), .clock = .awake } },
    })) |result| {
        var tree = result;
        tree.deinit();
        try out.writeAll("finished before the deadline\n");
    } else |err| switch (err) {
        error.Timeout => try out.writeAll("timed out after 50 ms\n"),
        else => return err,
    }

    // Another thread can cancel a request in flight.
    var cancellation = zig_pkl.Cancellation{};
    const canceller = try std.Thread.spawn(.{}, cancelSoon, .{ io, &cancellation });
    defer canceller.join();
    if (evaluator.evaluateWithOptions("repl:text", slow, "total", &failure, .{ .cancellation = &cancellation })) |result| {
        var tree = result;
        tree.deinit();
        try out.writeAll("finished before cancellation\n");
    } else |err| switch (err) {
        error.Canceled => try out.writeAll("canceled\n"),
        else => return err,
    }
}

fn cancelSoon(io: std.Io, cancellation: *zig_pkl.Cancellation) void {
    io.sleep(.fromMilliseconds(50), .awake) catch {};
    cancellation.cancel();
}

/// The reason in a Pkl error message, after its `–– Pkl Error ––` banner.
fn reason(text: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " ");
        if (trimmed.len != 0 and std.mem.indexOf(u8, trimmed, "Pkl Error") == null) return trimmed;
    }
    return text;
}
