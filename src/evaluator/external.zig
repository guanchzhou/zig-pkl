//! External reader process. Pkl is the server and this process is the client.

const std = @import("std");
const message = @import("../protocol/message.zig");
const reader = @import("reader.zig");

pub const Client = struct {
    module_readers: []const reader.ModuleReader = &.{},
    resource_readers: []const reader.ResourceReader = &.{},

    /// Serves requests until `close_external_process` or end of input at a
    /// frame boundary. End of input inside a frame returns `error.Truncated`.
    /// Complete frames with unknown codes, and messages not addressed to an
    /// external reader, are skipped.
    pub fn run(self: Client, allocator: std.mem.Allocator, input: *std.Io.Reader, output: *std.Io.Writer) !void {
        while (true) {
            _ = input.peekByte() catch |err| switch (err) {
                error.EndOfStream => return,
                error.ReadFailed => return error.ReadFailed,
            };
            var incoming = message.decodeReader(allocator, input) catch |err| switch (err) {
                error.UnknownCode => continue,
                else => return err,
            };
            defer incoming.deinit();
            switch (incoming.message) {
                .close_external_process => return,
                .initialize_module_reader_request => |body| {
                    const spec = findModule(self.module_readers, body.scheme);
                    try message.encode(output, .{ .initialize_module_reader_response = .{
                        .request_id = body.request_id,
                        .spec = spec,
                    } });
                    try output.flush();
                },
                .initialize_resource_reader_request => |body| {
                    const spec = findResource(self.resource_readers, body.scheme);
                    try message.encode(output, .{ .initialize_resource_reader_response = .{
                        .request_id = body.request_id,
                        .spec = spec,
                    } });
                    try output.flush();
                },
                .read_module_request => |body| try readModule(self, allocator, output, body),
                .read_resource_request => |body| try readResource(self, allocator, output, body),
                .list_modules_request => |body| try listModules(self, allocator, output, body),
                .list_resources_request => |body| try listResources(self, allocator, output, body),
                else => {},
            }
        }
    }
};

fn findModule(readers: []const reader.ModuleReader, scheme: []const u8) ?message.ClientModuleReader {
    for (readers) |item| if (std.mem.eql(u8, item.scheme(), scheme)) return item.spec();
    return null;
}

fn findResource(readers: []const reader.ResourceReader, scheme: []const u8) ?message.ClientResourceReader {
    for (readers) |item| if (std.mem.eql(u8, item.scheme(), scheme)) return item.spec();
    return null;
}

fn readModule(self: Client, allocator: std.mem.Allocator, output: *std.Io.Writer, body: message.ReadModuleRequest) !void {
    const scheme = reader.schemeOf(body.uri) orelse {
        try writeModule(output, body, null, "missing scheme");
        return;
    };
    for (self.module_readers) |item| {
        if (!std.mem.eql(u8, item.scheme(), scheme)) continue;
        const contents = item.read(allocator, body.uri) catch |err| {
            try writeModule(output, body, null, @errorName(err));
            return;
        };
        defer allocator.free(contents);
        try writeModule(output, body, contents, null);
        return;
    }
    try writeModule(output, body, null, "no module reader");
}

fn readResource(self: Client, allocator: std.mem.Allocator, output: *std.Io.Writer, body: message.ReadResourceRequest) !void {
    const scheme = reader.schemeOf(body.uri) orelse {
        try writeResource(output, body, null, "missing scheme");
        return;
    };
    for (self.resource_readers) |item| {
        if (!std.mem.eql(u8, item.scheme(), scheme)) continue;
        const contents = item.read(allocator, body.uri) catch |err| {
            try writeResource(output, body, null, @errorName(err));
            return;
        };
        defer allocator.free(contents);
        try writeResource(output, body, contents, null);
        return;
    }
    try writeResource(output, body, null, "no resource reader");
}

fn listModules(self: Client, allocator: std.mem.Allocator, output: *std.Io.Writer, body: message.ListRequest) !void {
    const scheme = reader.schemeOf(body.uri) orelse {
        try writeList(output, true, body, null, "missing scheme");
        return;
    };
    for (self.module_readers) |item| {
        if (!std.mem.eql(u8, item.scheme(), scheme)) continue;
        const elements = item.list(allocator, body.uri) catch |err| {
            try writeList(output, true, body, null, @errorName(err));
            return;
        };
        defer freeElements(allocator, elements);
        try writeList(output, true, body, elements, null);
        return;
    }
    try writeList(output, true, body, null, "no module reader");
}

fn listResources(self: Client, allocator: std.mem.Allocator, output: *std.Io.Writer, body: message.ListRequest) !void {
    const scheme = reader.schemeOf(body.uri) orelse {
        try writeList(output, false, body, null, "missing scheme");
        return;
    };
    for (self.resource_readers) |item| {
        if (!std.mem.eql(u8, item.scheme(), scheme)) continue;
        const elements = item.list(allocator, body.uri) catch |err| {
            try writeList(output, false, body, null, @errorName(err));
            return;
        };
        defer freeElements(allocator, elements);
        try writeList(output, false, body, elements, null);
        return;
    }
    try writeList(output, false, body, null, "no resource reader");
}

fn writeModule(output: *std.Io.Writer, body: message.ReadModuleRequest, contents: ?[]const u8, error_message: ?[]const u8) !void {
    try message.encode(output, .{ .read_module_response = .{
        .request_id = body.request_id,
        .evaluator_id = body.evaluator_id,
        .contents = contents,
        .error_message = error_message,
    } });
    try output.flush();
}

fn writeResource(output: *std.Io.Writer, body: message.ReadResourceRequest, contents: ?[]const u8, error_message: ?[]const u8) !void {
    try message.encode(output, .{ .read_resource_response = .{
        .request_id = body.request_id,
        .evaluator_id = body.evaluator_id,
        .contents = contents,
        .error_message = error_message,
    } });
    try output.flush();
}

fn writeList(
    output: *std.Io.Writer,
    modules: bool,
    body: message.ListRequest,
    elements: ?[]const message.PathElement,
    error_message: ?[]const u8,
) !void {
    const response = message.ListResponse{
        .request_id = body.request_id,
        .evaluator_id = body.evaluator_id,
        .path_elements = elements,
        .error_message = error_message,
    };
    try message.encode(output, if (modules)
        .{ .list_modules_response = response }
    else
        .{ .list_resources_response = response });
    try output.flush();
}

fn freeElements(allocator: std.mem.Allocator, elements: []message.PathElement) void {
    for (elements) |element| allocator.free(@constCast(element.name));
    allocator.free(elements);
}

test "external client answers initialize, read, and close" {
    const allocator = std.testing.allocator;
    var embed = reader.Embed{
        .scheme_name = "mem",
        .entries = &.{.{ .path = "/a.pkl", .contents = "foo = 1" }},
    };
    var input: std.Io.Writer.Allocating = .init(allocator);
    defer input.deinit();
    try message.encode(&input.writer, .{ .initialize_module_reader_request = .{ .request_id = 1, .scheme = "mem" } });
    try message.encode(&input.writer, .{ .read_module_request = .{
        .request_id = 2,
        .evaluator_id = 3,
        .uri = "mem:/a.pkl",
    } });
    try message.encode(&input.writer, .close_external_process);
    var reader_in = std.Io.Reader.fixed(input.written());
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const client = Client{ .module_readers = &.{embed.moduleReader()} };
    try client.run(allocator, &reader_in, &output.writer);

    var cursor = std.Io.Reader.fixed(output.written());
    var init_response = try message.decodeReader(allocator, &cursor);
    defer init_response.deinit();
    try std.testing.expect(init_response.message.initialize_module_reader_response.spec.?.is_local);
    var read_response = try message.decodeReader(allocator, &cursor);
    defer read_response.deinit();
    try std.testing.expectEqualStrings("foo = 1", read_response.message.read_module_response.contents.?);
}

test "external client skips unknown and unexpected messages like the manager" {
    const allocator = std.testing.allocator;
    var frames: std.Io.Writer.Allocating = .init(allocator);
    defer frames.deinit();
    try frames.writer.writeAll(&.{ 0x92, 0x7f, 0x80 });
    try message.encode(&frames.writer, .{ .log = .{ .evaluator_id = 1, .level = 0, .message = "x", .frame_uri = "repl:text" } });
    try message.encode(&frames.writer, .{ .initialize_module_reader_request = .{ .request_id = 5, .scheme = "mem" } });
    try message.encode(&frames.writer, .close_external_process);

    var input = std.Io.Reader.fixed(frames.written());
    var sink: std.Io.Writer.Allocating = .init(allocator);
    defer sink.deinit();
    try (Client{}).run(allocator, &input, &sink.writer);
    var response = try message.decodeSlice(allocator, sink.written());
    defer response.deinit();
    try std.testing.expectEqual(@as(i64, 5), response.message.initialize_module_reader_response.request_id);
}

test "external client distinguishes clean end of input from a partial frame" {
    const allocator = std.testing.allocator;
    var empty = std.Io.Reader.fixed("");
    var sink: std.Io.Writer.Allocating = .init(allocator);
    defer sink.deinit();
    try (Client{}).run(allocator, &empty, &sink.writer);

    const frame = try message.encodeAlloc(allocator, .{ .initialize_module_reader_request = .{
        .request_id = 1,
        .scheme = "mem",
    } });
    defer allocator.free(frame);
    var partial = std.Io.Reader.fixed(frame[0 .. frame.len - 2]);
    try std.testing.expectError(error.Truncated, (Client{}).run(allocator, &partial, &sink.writer));
    try std.testing.expectEqual(@as(usize, 0), sink.written().len);
}

test "external client transports module content larger than eight kilobytes" {
    const allocator = std.testing.allocator;
    const contents = try allocator.alloc(u8, 24 * 1024);
    defer allocator.free(contents);
    @memset(contents, 'p');
    var embed = reader.Embed{
        .scheme_name = "mem",
        .entries = &.{.{ .path = "/large.pkl", .contents = contents }},
    };
    var input: std.Io.Writer.Allocating = .init(allocator);
    defer input.deinit();
    try message.encode(&input.writer, .{ .read_module_request = .{
        .request_id = 1,
        .evaluator_id = 2,
        .uri = "mem:/large.pkl",
    } });
    try message.encode(&input.writer, .close_external_process);
    var input_reader = std.Io.Reader.fixed(input.written());
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try (Client{ .module_readers = &.{embed.moduleReader()} }).run(
        allocator,
        &input_reader,
        &output.writer,
    );
    var output_reader = std.Io.Reader.fixed(output.written());
    var response = try message.decodeReader(allocator, &output_reader);
    defer response.deinit();
    try std.testing.expectEqualSlices(u8, contents, response.message.read_module_response.contents.?);
}
