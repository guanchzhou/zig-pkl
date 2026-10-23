//! Deterministic mutation fuzzing for the message and pkl-binary decoders.
//! Each run mutates a built-in seed corpus for a fixed number of iterations,
//! checks that successful decodes re-encode to stable bytes, and fails on
//! any leak reported by the debug allocator. A failing run is reproduced by
//! rerunning with the same seed and iteration count.

const std = @import("std");
const zig_pkl = @import("zig_pkl");
const config = @import("fuzz_config");

const message = zig_pkl.protocol;
const value = zig_pkl.value;
const msgpack = zig_pkl.msgpack;

const max_input = 4096;
const value_limits = value.Limits{ .max_depth = 32, .max_collection = 4096, .max_bytes = 256 * 1024 };

pub fn main(init: std.process.Init) !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    var leaked = false;
    {
        const gpa = debug.allocator();
        var corpus = try buildCorpus(gpa);
        defer {
            for (corpus.items) |item| gpa.free(item);
            corpus.deinit(gpa);
        }
        var prng = std.Random.DefaultPrng.init(config.seed);
        const random = prng.random();
        var input: [max_input]u8 = undefined;
        var accepted: usize = 0;
        for (0..config.iterations) |_| {
            const len = mutate(random, corpus.items, &input);
            accepted += try fuzzMessage(gpa, input[0..len]);
            accepted += try fuzzValue(gpa, input[0..len]);
            try fuzzDocument(gpa, input[0..len]);
        }
        var stdout_buffer: [256]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
        try stdout.interface.print(
            "fuzz decoders: {d} iterations, seed 0x{x}, {d} corpus inputs, {d} accepted decodes\n",
            .{ config.iterations, config.seed, corpus.items.len, accepted },
        );
        try stdout.interface.flush();
    }
    leaked = debug.deinit() == .leak;
    if (leaked) return error.MemoryLeak;
}

fn fuzzMessage(gpa: std.mem.Allocator, input: []const u8) !usize {
    var owned = message.decodeSlice(gpa, input) catch return 0;
    defer owned.deinit();
    const first = message.encodeAlloc(gpa, owned.message) catch |err| switch (err) {
        error.MissingField, error.LimitExceeded => return 1,
        else => return err,
    };
    defer gpa.free(first);
    var again = try message.decodeSlice(gpa, first);
    defer again.deinit();
    const second = try message.encodeAlloc(gpa, again.message);
    defer gpa.free(second);
    if (!std.mem.eql(u8, first, second)) return error.UnstableMessageEncoding;
    return 1;
}

fn fuzzValue(gpa: std.mem.Allocator, input: []const u8) !usize {
    var tree = value.decodeSlice(gpa, input, value_limits) catch return 0;
    defer tree.deinit();
    const encoded = try value.encodeAlloc(gpa, tree.root);
    defer gpa.free(encoded);
    var again = try value.decodeSlice(gpa, encoded, .{});
    defer again.deinit();
    if (!value.eql(tree.root, again.root)) return error.UnstableValueEncoding;
    return 1;
}

fn fuzzDocument(gpa: std.mem.Allocator, input: []const u8) !void {
    var document = msgpack.decodeSlice(gpa, input, .{ .max_depth = 32, .max_collection = 4096, .max_bytes = 256 * 1024 }) catch return;
    defer document.deinit();
    const encoded = try msgpack.encodeAlloc(gpa, document.root);
    defer gpa.free(encoded);
    if (!std.mem.eql(u8, encoded, input)) {
        var again = try msgpack.decodeSlice(gpa, encoded, .{});
        defer again.deinit();
        if (!msgpack.eql(document.root, again.root)) return error.UnstableDocumentEncoding;
    }
}

fn mutate(random: std.Random, corpus: []const []u8, out: *[max_input]u8) usize {
    const base = corpus[random.uintLessThan(usize, corpus.len)];
    var len: usize = @min(base.len, max_input);
    @memcpy(out[0..len], base[0..len]);
    const rounds = 1 + random.uintLessThan(u8, 6);
    for (0..rounds) |_| {
        switch (random.uintLessThan(u8, 7)) {
            0 => if (len != 0) {
                out[random.uintLessThan(usize, len)] ^= @as(u8, 1) << random.int(u3);
            },
            1 => if (len != 0) {
                const interesting = [_]u8{ 0x00, 0x7f, 0x80, 0xc0, 0xc4, 0xc6, 0xc7, 0xd9, 0xdb, 0xdc, 0xdd, 0xde, 0xdf, 0xff };
                out[random.uintLessThan(usize, len)] = interesting[random.uintLessThan(usize, interesting.len)];
            },
            2 => if (len != 0) {
                len = random.uintLessThan(usize, len + 1);
            },
            3 => if (len < max_input) {
                const at = random.uintLessThan(usize, len + 1);
                std.mem.copyBackwards(u8, out[at + 1 .. len + 1], out[at..len]);
                out[at] = random.int(u8);
                len += 1;
            },
            4 => if (len != 0) {
                const at = random.uintLessThan(usize, len);
                std.mem.copyForwards(u8, out[at .. len - 1], out[at + 1 .. len]);
                len -= 1;
            },
            5 => {
                const other = corpus[random.uintLessThan(usize, corpus.len)];
                if (other.len != 0 and len < max_input) {
                    const start = random.uintLessThan(usize, other.len);
                    const take = @min(other.len - start, max_input - len, 64);
                    @memcpy(out[len .. len + take], other[start .. start + take]);
                    len += take;
                }
            },
            else => if (len >= 4) {
                const at = random.uintLessThan(usize, len - 3);
                std.mem.writeInt(u32, out[at..][0..4], random.int(u32), .big);
            },
        }
    }
    return len;
}

fn buildCorpus(gpa: std.mem.Allocator) !std.ArrayList([]u8) {
    var corpus: std.ArrayList([]u8) = .empty;
    errdefer {
        for (corpus.items) |item| gpa.free(item);
        corpus.deinit(gpa);
    }
    const leaf = [_]message.NamedDependency{.{
        .name = "leaf",
        .dependency = .{ .remote = .{ .package_uri = "package://example.com/leaf@1.0.0", .checksums = .{ .sha256 = "00" } } },
    }};
    const dependencies = [_]message.NamedDependency{.{
        .name = "dep",
        .dependency = .{ .local = .{
            .project_file_uri = "file:///dep/PklProject",
            .package_uri = "package://example.com/dep@1.0.0",
            .dependencies = &leaf,
        } },
    }};
    const messages = [_]message.Message{
        .{ .create_evaluator_request = .{
            .request_id = 1,
            .allowed_modules = &.{ "pkl:", "repl:" },
            .allowed_resources = &.{},
            .client_module_readers = &.{.{ .scheme = "mem", .has_hierarchical_uris = true, .is_globbable = false, .is_local = true }},
            .env = &.{.{ .key = "A", .value = "B" }},
            .timeout_seconds = 5,
            .project = .{ .project_file_uri = "file:///app/PklProject", .dependencies = &dependencies },
            .http = .{ .proxy = .{ .address = "http://proxy", .no_proxy = &.{"localhost"} }, .rewrites = &.{.{ .key = "a", .value = "b" }} },
            .trace_mode = .pretty,
        } },
        .{ .create_evaluator_response = .{ .request_id = 1, .evaluator_id = 2 } },
        .{ .close_evaluator = .{ .evaluator_id = 2 } },
        .{ .evaluate_request = .{ .request_id = 3, .evaluator_id = 2, .module_uri = "repl:text", .module_text = "a = 1", .expression = "a" } },
        .{ .evaluate_response = .{ .request_id = 3, .evaluator_id = 2, .result = "\x01" } },
        .{ .log = .{ .evaluator_id = 2, .level = 1, .message = "warn", .frame_uri = "repl:text" } },
        .{ .read_module_request = .{ .request_id = -1, .evaluator_id = 2, .uri = "mem:/a.pkl" } },
        .{ .read_resource_response = .{ .request_id = -2, .evaluator_id = 2, .contents = "bytes" } },
        .{ .list_modules_response = .{ .request_id = -3, .evaluator_id = 2, .path_elements = &.{.{ .name = "a.pkl", .is_directory = false }} } },
        .{ .initialize_module_reader_response = .{ .request_id = 4, .spec = .{ .scheme = "x", .has_hierarchical_uris = false, .is_globbable = false, .is_local = false } } },
        .close_external_process,
    };
    for (messages) |item| try appendOwned(gpa, &corpus, try message.encodeAlloc(gpa, item));

    var one = value.Value{ .int = value.Integer.fromSigned(1) };
    var text = value.Value{ .string = "bird" };
    var items = [_]*value.Value{ &one, &text };
    var entries = [_]value.Entry{.{ .key = &text, .value = &one }};
    var members = [_]value.Member{
        .{ .property = .{ .name = "n", .value = &one } },
        .{ .entry = .{ .key = &text, .value = &one } },
        .{ .element = .{ .index = value.Integer.fromSigned(0), .value = &text } },
    };
    var values = [_]value.Value{
        .{ .object = .{ .class_name = "Dynamic", .module_uri = "pkl:base", .members = &members } },
        .{ .map = &entries },
        .{ .mapping = &entries },
        .{ .list = &items },
        .{ .listing = &items },
        .{ .set = &items },
        .{ .duration = .{ .value = 1.5, .unit = "min" } },
        .{ .data_size = .{ .value = 4, .unit = "kib" } },
        .{ .pair = .{ .first = &one, .second = &text } },
        .{ .int_seq = .{ .start = value.Integer.fromSigned(0), .end = value.Integer.fromSigned(9), .step = value.Integer.fromSigned(3) } },
        .{ .regex = "a+" },
        .{ .class = .{ .name = "base#Int", .module_uri = "pkl:base" } },
        .{ .type_alias = .{ .name = "m#A", .module_uri = "file:///m.pkl" } },
        .function,
        .{ .bytes = "\x00\xff" },
        .{ .reference = .{ .domain = &one, .data = &text, .path = &items } },
    };
    for (&values) |*item| try appendOwned(gpa, &corpus, try value.encodeAlloc(gpa, item));
    return corpus;
}

fn appendOwned(gpa: std.mem.Allocator, corpus: *std.ArrayList([]u8), bytes: []u8) !void {
    corpus.append(gpa, bytes) catch |err| {
        gpa.free(bytes);
        return err;
    };
}
