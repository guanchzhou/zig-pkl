//! pkl-zig side of the comparative benchmark. It mirrors `bench/zig-pkl.zig`
//! case for case: the same fixtures, typed shape, iteration counts, backing
//! allocator, timing method, and output format. pkl-zig is used only through
//! its public API.
//!
//! Usage: bench-pkl-zig <fixtures dir> <pkl executable>
//! Prints one JSON object to standard output.

const std = @import("std");
const pkl = @import("pkl");

const codec_warmup = 200;
const codec_iterations = 2_000;
const warm_warmup = 20;
const warm_iterations = 200;
const expression_module = "value = (1 + 2) * 14";

const Server = struct {
    host: []const u8,
    port: u16,
    enabled: bool,
    tags: []const []const u8,
};

const Config = struct {
    name: []const u8,
    version: i64,
    servers: []const Server,
};

const CountingAllocator = struct {
    child: std.mem.Allocator,
    allocations: usize = 0,
    requested_bytes: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.child.vtable.alloc(self.child.ptr, len, alignment, ret_addr);
        if (result != null) {
            self.allocations += 1;
            self.requested_bytes += len;
        }
        return result;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.vtable.resize(self.child.ptr, memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.child.vtable.remap(self.child.ptr, memory, alignment, new_len, ret_addr);
        if (result) |pointer| {
            if (pointer != memory.ptr) {
                self.allocations += 1;
                self.requested_bytes += new_len;
            }
        }
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.vtable.free(self.child.ptr, memory, alignment, ret_addr);
    }
};

const Result = struct {
    name: []const u8,
    bytes: usize,
    ns: u64,
    allocations: usize,
    requested_bytes: usize,
};

fn decodeDynamic(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var value = try pkl.decode(pkl.Value, allocator, bytes);
    std.mem.doNotOptimizeAway(&value);
    value.deinit(allocator);
}

fn runTyped(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var config = try pkl.decode(Config, allocator, bytes);
    std.mem.doNotOptimizeAway(config.servers.ptr);
    pkl.deinit(Config, allocator, &config);
}

fn checkTyped(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var config = try pkl.decode(Config, allocator, bytes);
    defer pkl.deinit(Config, allocator, &config);
    if (config.servers.len != 64) return error.BadResult;
    if (!std.mem.eql(u8, config.servers[0].host, "node-1.example.test")) return error.BadResult;
    if (config.servers[63].port != 8064) return error.BadResult;
    if (config.servers[2].tags.len != 3) return error.BadResult;
}

fn measure(
    io: std.Io,
    name: []const u8,
    bytes: []const u8,
    comptime run: fn (std.mem.Allocator, []const u8) anyerror!void,
) !Result {
    for (0..codec_warmup) |_| try run(std.heap.smp_allocator, bytes);
    var counter = CountingAllocator{ .child = std.heap.smp_allocator };
    const allocator = counter.allocator();
    const start = std.Io.Clock.awake.now(io);
    for (0..codec_iterations) |_| try run(allocator, bytes);
    const elapsed = start.untilNow(io, .awake).nanoseconds;
    return .{
        .name = name,
        .bytes = bytes.len,
        .ns = @intCast(elapsed),
        .allocations = counter.allocations,
        .requested_bytes = counter.requested_bytes,
    };
}

fn openEvaluator(allocator: std.mem.Allocator, io: std.Io, executable: []const u8) !pkl.Evaluator {
    const argv: []const []const u8 = &.{ executable, "server" };
    const result = try pkl.Evaluator.init(io, allocator, .{ .pkl_argv = argv });
    return switch (result) {
        .evaluator => |evaluator| evaluator,
        .failed => |failed| {
            defer failed.deinit(allocator);
            return error.EvaluatorCreateFailed;
        },
    };
}

fn evaluateOnce(evaluator: *pkl.Evaluator) !void {
    const result = try evaluator.evaluateExpression(i64, pkl.ModuleSource.fromText(expression_module), "value");
    if (result != 42) return error.BadResult;
}

fn coldEvaluator(allocator: std.mem.Allocator, io: std.Io, executable: []const u8) !u64 {
    const start = std.Io.Clock.awake.now(io);
    var evaluator = try openEvaluator(allocator, io, executable);
    try evaluateOnce(&evaluator);
    evaluator.deinit();
    return @intCast(start.untilNow(io, .awake).nanoseconds);
}

fn warmEvaluator(allocator: std.mem.Allocator, io: std.Io, executable: []const u8) !u64 {
    var evaluator = try openEvaluator(allocator, io, executable);
    defer evaluator.deinit();
    for (0..warm_warmup) |_| try evaluateOnce(&evaluator);
    const start = std.Io.Clock.awake.now(io);
    for (0..warm_iterations) |_| try evaluateOnce(&evaluator);
    return @intCast(start.untilNow(io, .awake).nanoseconds);
}

fn readFixture(io: std.Io, allocator: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    const path = try std.fs.path.join(allocator, &.{ dir, name });
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20));
}

pub const std_options: std.Options = .{ .log_level = .err };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.Usage;
    const fixtures = args[1];
    const executable = args[2];

    const config = try readFixture(io, allocator, fixtures, "config.pklbin");
    defer allocator.free(config);
    const mixed = try readFixture(io, allocator, fixtures, "mixed.pklbin");
    defer allocator.free(mixed);

    try checkTyped(allocator, config);
    try decodeDynamic(allocator, mixed);

    const results = [_]Result{
        try measure(io, "decode_config", config, decodeDynamic),
        try measure(io, "decode_mixed", mixed, decodeDynamic),
        try measure(io, "typed_config", config, runTyped),
    };
    const cold_ns = try coldEvaluator(allocator, io, executable);
    const warm_ns = try warmEvaluator(allocator, io, executable);

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const out = &stdout.interface;
    try out.writeAll("{\"library\":\"pkl-zig\",\"codec_iterations\":");
    try out.print("{d},\"codec\":{{", .{codec_iterations});
    for (results, 0..) |result, index| {
        if (index != 0) try out.writeByte(',');
        try out.print(
            "\"{s}\":{{\"bytes\":{d},\"ns\":{d},\"allocations\":{d},\"requested_bytes\":{d}}}",
            .{ result.name, result.bytes, result.ns, result.allocations, result.requested_bytes },
        );
    }
    try out.print(
        "}},\"server\":{{\"cold_ns\":{d},\"warm_iterations\":{d},\"warm_ns\":{d}}}}}\n",
        .{ cold_ns, warm_iterations, warm_ns },
    );
    try out.flush();
}
