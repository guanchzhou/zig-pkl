//! Applies the release gates in docs/benchmarks/baseline.md to the output of
//! bench/compare.sh. Every figure is a median over rounds of the same run, and
//! every gate is a ratio between the two libraries from that run.
//!
//! Usage: zig run bench/gates.zig -- <pkl-zig.jsonl> <zig-pkl.jsonl> <output dir>
//! Writes summary.json and summary.md to the output directory, prints the
//! Markdown summary, and exits with status 1 when a gate fails.

const std = @import("std");

const codec_speedup_min = 1.25;
const allocation_reduction_min = 0.25;
const server_slowdown_max = 1.05;
const codec_cases = [_][]const u8{ "decode_config", "decode_mixed", "typed_config" };

const Codec = struct {
    bytes: u64,
    ns: u64,
    allocations: u64,
    requested_bytes: u64,
};

const Run = struct {
    library: []const u8,
    codec_iterations: u64,
    codec: struct {
        decode_config: Codec,
        decode_mixed: Codec,
        typed_config: Codec,
    },
    server: struct {
        cold_ns: u64,
        cold_start_ns: u64 = 0,
        cold_evaluate_ns: u64 = 0,
        cold_close_ns: u64 = 0,
        warm_iterations: u64,
        warm_ns: u64,
    },
};

fn readRuns(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]Run {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20));
    var runs: std.ArrayList(Run) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;
        const run = try std.json.parseFromSliceLeaky(Run, allocator, trimmed, .{ .ignore_unknown_fields = true });
        try runs.append(allocator, run);
    }
    if (runs.items.len == 0) return error.NoRuns;
    return runs.items;
}

fn median(allocator: std.mem.Allocator, values: []const f64) !f64 {
    const sorted = try allocator.dupe(f64, values);
    std.mem.sort(f64, sorted, {}, std.sort.asc(f64));
    const mid = sorted.len / 2;
    return if (sorted.len % 2 == 1) sorted[mid] else (sorted[mid - 1] + sorted[mid]) / 2;
}

fn codecField(run: Run, comptime name: []const u8) Codec {
    return @field(run.codec, name);
}

const Stat = struct {
    ns_per_op: f64,
    mib_per_s: f64,
    allocations_per_op: f64,
    requested_bytes_per_op: f64,
};

fn codecStat(allocator: std.mem.Allocator, runs: []const Run, comptime name: []const u8) !Stat {
    const times = try allocator.alloc(f64, runs.len);
    for (runs, times) |run, *slot| {
        const item = codecField(run, name);
        slot.* = @as(f64, @floatFromInt(item.ns)) / @as(f64, @floatFromInt(run.codec_iterations));
    }
    const first = codecField(runs[0], name);
    const iterations: f64 = @floatFromInt(runs[0].codec_iterations);
    const ns_per_op = try median(allocator, times);
    return .{
        .ns_per_op = ns_per_op,
        .mib_per_s = (@as(f64, @floatFromInt(first.bytes)) / 1048576.0) / (ns_per_op / 1e9),
        .allocations_per_op = @as(f64, @floatFromInt(first.allocations)) / iterations,
        .requested_bytes_per_op = @as(f64, @floatFromInt(first.requested_bytes)) / iterations,
    };
}

const Server = struct { cold_ms: f64, start_ms: f64, evaluate_ms: f64, close_ms: f64, warm_us: f64 };

fn serverStat(allocator: std.mem.Allocator, runs: []const Run) !Server {
    const warm = try allocator.alloc(f64, runs.len);
    for (runs, warm) |run, *w| {
        w.* = @as(f64, @floatFromInt(run.server.warm_ns)) / @as(f64, @floatFromInt(run.server.warm_iterations)) / 1e3;
    }
    return .{
        .cold_ms = try medianMs(allocator, runs, "cold_ns"),
        .start_ms = try medianMs(allocator, runs, "cold_start_ns"),
        .evaluate_ms = try medianMs(allocator, runs, "cold_evaluate_ns"),
        .close_ms = try medianMs(allocator, runs, "cold_close_ns"),
        .warm_us = try median(allocator, warm),
    };
}

fn medianMs(allocator: std.mem.Allocator, runs: []const Run, comptime field: []const u8) !f64 {
    const values = try allocator.alloc(f64, runs.len);
    for (runs, values) |run, *v| v.* = @as(f64, @floatFromInt(@field(run.server, field))) / 1e6;
    return median(allocator, values);
}

fn sign(ratio: f64) []const u8 {
    return if (ratio >= 1) "+" else "";
}

fn verdict(pass: bool) []const u8 {
    return if (pass) "pass" else "FAIL";
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 4) return error.Usage;
    const base_runs = try readRuns(allocator, io, args[1]);
    const ours_runs = try readRuns(allocator, io, args[2]);

    var base: [codec_cases.len]Stat = undefined;
    var ours: [codec_cases.len]Stat = undefined;
    inline for (codec_cases, 0..) |name, index| {
        base[index] = try codecStat(allocator, base_runs, name);
        ours[index] = try codecStat(allocator, ours_runs, name);
    }
    const base_server = try serverStat(allocator, base_runs);
    const ours_server = try serverStat(allocator, ours_runs);

    var log_sum: f64 = 0;
    var allocations_pass = true;
    for (base, ours) |b, o| {
        log_sum += @log(b.ns_per_op / o.ns_per_op);
        if (o.allocations_per_op > b.allocations_per_op * (1 - allocation_reduction_min)) allocations_pass = false;
    }
    const geomean = @exp(log_sum / @as(f64, codec_cases.len));
    const speed_pass = geomean >= codec_speedup_min;
    const cold_ratio = ours_server.cold_ms / base_server.cold_ms;
    const warm_ratio = ours_server.warm_us / base_server.warm_us;
    const cold_pass = cold_ratio <= server_slowdown_max;
    const warm_pass = warm_ratio <= server_slowdown_max;
    const all_pass = speed_pass and allocations_pass and cold_pass and warm_pass;

    var md: std.Io.Writer.Allocating = .init(allocator);
    const w = &md.writer;
    try w.print("Rounds: pkl-zig {d}, zig-pkl {d}. Figures are medians.\n\n", .{ base_runs.len, ours_runs.len });
    try w.writeAll("| Case | pkl-zig | zig-pkl | Speedup | pkl-zig allocations | zig-pkl allocations |\n");
    try w.writeAll("| --- | ---: | ---: | ---: | ---: | ---: |\n");
    inline for (codec_cases, 0..) |name, index| {
        try w.print("| {s} | {d:.1} MiB/s | {d:.1} MiB/s | {d:.2}x | {d:.0} | {d:.0} |\n", .{
            name,
            base[index].mib_per_s,
            ours[index].mib_per_s,
            base[index].ns_per_op / ours[index].ns_per_op,
            base[index].allocations_per_op,
            ours[index].allocations_per_op,
        });
    }
    try w.print("| cold evaluator | {d:.2} ms | {d:.2} ms | {d:.2}x | | |\n", .{ base_server.cold_ms, ours_server.cold_ms, 1 / cold_ratio });
    try w.print("| warm evaluate | {d:.2} us | {d:.2} us | {d:.2}x | | |\n\n", .{ base_server.warm_us, ours_server.warm_us, 1 / warm_ratio });
    try w.writeAll("| Cold phase | pkl-zig | zig-pkl |\n| --- | ---: | ---: |\n");
    try w.print("| start and create evaluator | {d:.2} ms | {d:.2} ms |\n", .{ base_server.start_ms, ours_server.start_ms });
    try w.print("| evaluate | {d:.2} ms | {d:.2} ms |\n", .{ base_server.evaluate_ms, ours_server.evaluate_ms });
    try w.print("| close and shut down | {d:.2} ms | {d:.2} ms |\n\n", .{ base_server.close_ms, ours_server.close_ms });
    try w.writeAll("| Gate | Requirement | Result | Verdict |\n| --- | --- | --- | --- |\n");
    try w.print("| Codec speed | geometric mean at least {d:.2}x | {d:.2}x | {s} |\n", .{ codec_speedup_min, geomean, verdict(speed_pass) });
    try w.print("| Allocations | at least {d:.0}% fewer in every codec case | see table | {s} |\n", .{ allocation_reduction_min * 100, verdict(allocations_pass) });
    try w.print("| Cold evaluator | at most {d:.0}% slower | {s}{d:.1}% | {s} |\n", .{ (server_slowdown_max - 1) * 100, sign(cold_ratio), (cold_ratio - 1) * 100, verdict(cold_pass) });
    try w.print("| Warm evaluate | at most {d:.0}% slower | {s}{d:.1}% | {s} |\n", .{ (server_slowdown_max - 1) * 100, sign(warm_ratio), (warm_ratio - 1) * 100, verdict(warm_pass) });

    var json: std.Io.Writer.Allocating = .init(allocator);
    const j = &json.writer;
    try j.writeAll("{\n  \"schema_version\": 1,\n  \"codec\": {");
    inline for (codec_cases, 0..) |name, index| {
        if (index != 0) try j.writeAll(",");
        try j.print(
            "\n    \"{s}\": {{\"pkl_zig_mib_s\": {d:.3}, \"zig_pkl_mib_s\": {d:.3}, \"speedup\": {d:.4}, \"pkl_zig_allocations\": {d:.1}, \"zig_pkl_allocations\": {d:.1}, \"pkl_zig_requested_bytes\": {d:.0}, \"zig_pkl_requested_bytes\": {d:.0}}}",
            .{
                name,                                          base[index].mib_per_s,              ours[index].mib_per_s,
                base[index].ns_per_op / ours[index].ns_per_op, base[index].allocations_per_op,     ours[index].allocations_per_op,
                base[index].requested_bytes_per_op,            ours[index].requested_bytes_per_op,
            },
        );
    }
    try j.print(
        "\n  }},\n  \"server\": {{\"pkl_zig_cold_ms\": {d:.4}, \"zig_pkl_cold_ms\": {d:.4}, \"pkl_zig_warm_us\": {d:.4}, \"zig_pkl_warm_us\": {d:.4}}},\n",
        .{ base_server.cold_ms, ours_server.cold_ms, base_server.warm_us, ours_server.warm_us },
    );
    try j.print(
        "  \"cold_phases_ms\": {{\"pkl_zig\": {{\"start\": {d:.4}, \"evaluate\": {d:.4}, \"close\": {d:.4}}}, \"zig_pkl\": {{\"start\": {d:.4}, \"evaluate\": {d:.4}, \"close\": {d:.4}}}}},\n",
        .{ base_server.start_ms, base_server.evaluate_ms, base_server.close_ms, ours_server.start_ms, ours_server.evaluate_ms, ours_server.close_ms },
    );
    try j.print(
        "  \"gates\": {{\"codec_geometric_mean_speedup\": {d:.4}, \"codec_speed\": {}, \"allocations\": {}, \"cold_evaluator\": {}, \"warm_evaluate\": {}, \"all\": {}}},\n  \"rounds\": {{\"pkl_zig\": {d}, \"zig_pkl\": {d}}}\n}}\n",
        .{ geomean, speed_pass, allocations_pass, cold_pass, warm_pass, all_pass, base_runs.len, ours_runs.len },
    );

    var dir = try std.Io.Dir.cwd().openDir(io, args[3], .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "summary.md", .data = md.written() });
    try dir.writeFile(io, .{ .sub_path = "summary.json", .data = json.written() });

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    try stdout.interface.writeAll(md.written());
    try stdout.interface.flush();
    return if (all_pass) 0 else 1;
}
