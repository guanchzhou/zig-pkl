//! Shares one Pkl server between threads.
//!
//! One `Manager` owns the server process. Evaluators are cheap handles on
//! it, and any thread may evaluate through any evaluator concurrently.

const std = @import("std");
const zig_pkl = @import("zig_pkl");

const module_text =
    \\function fib(n: Int): Int = if (n < 2) n else fib(n - 1) + fib(n - 2)
;

const threads = 4;
const per_thread = 8;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const pkl = init.environ_map.get("PKL_EXEC") orelse "pkl";

    const manager = try zig_pkl.Manager.init(allocator, io, &.{ pkl, "server" }, zig_pkl.Logger.noop);
    defer manager.deinit();
    var rejected: ?[]u8 = null;
    defer if (rejected) |text| allocator.free(text);
    const shared = try manager.createEvaluator(zig_pkl.Options.restricted(), &rejected);
    defer shared.close();

    var results: [threads][per_thread]i64 = undefined;
    var failures = std.atomic.Value(usize).init(0);
    var workers: [threads]std.Thread = undefined;
    for (&workers, 0..) |*worker, index| {
        worker.* = try std.Thread.spawn(.{}, work, .{ shared, index, &results[index], &failures });
    }
    for (workers) |worker| worker.join();

    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    const out = &stdout.interface;
    for (results, 0..) |row, index| {
        try out.print("thread {d}:", .{index});
        for (row) |number| try out.print(" {d}", .{number});
        try out.writeAll("\n");
    }
    try out.print("{d} evaluations failed\n", .{failures.load(.monotonic)});
    try out.flush();
    if (failures.load(.monotonic) != 0) return error.EvaluationFailed;
}

fn work(evaluator: *zig_pkl.Evaluator, index: usize, row: *[per_thread]i64, failures: *std.atomic.Value(usize)) void {
    for (row, 0..) |*slot, step| {
        const n = index * per_thread + step;
        var expression_buffer: [32]u8 = undefined;
        const expression = std.fmt.bufPrint(&expression_buffer, "fib({d})", .{n}) catch unreachable;
        var failure: ?[]u8 = null;
        defer if (failure) |text| evaluator.manager.allocator.free(text);
        var tree = evaluator.evaluateSource(.text(module_text), expression, &failure) catch {
            _ = failures.fetchAdd(1, .monotonic);
            slot.* = -1;
            continue;
        };
        defer tree.deinit();
        slot.* = tree.root.int.signed;
    }
}
