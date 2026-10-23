//! Pkl message-passing frames, codes 0x20 through 0x32.
//! Nullable properties are omitted. Unknown properties are ignored.

const std = @import("std");
const msgpack = @import("msgpack.zig");

pub const Error = msgpack.Error || error{
    InvalidMessage,
    MissingField,
    Overflow,
    UnknownCode,
};

pub const Code = enum(u8) {
    create_evaluator_request = 0x20,
    create_evaluator_response = 0x21,
    close_evaluator = 0x22,
    evaluate_request = 0x23,
    evaluate_response = 0x24,
    log = 0x25,
    read_resource_request = 0x26,
    read_resource_response = 0x27,
    read_module_request = 0x28,
    read_module_response = 0x29,
    list_resources_request = 0x2a,
    list_resources_response = 0x2b,
    list_modules_request = 0x2c,
    list_modules_response = 0x2d,
    initialize_module_reader_request = 0x2e,
    initialize_module_reader_response = 0x2f,
    initialize_resource_reader_request = 0x30,
    initialize_resource_reader_response = 0x31,
    close_external_process = 0x32,

    pub fn fromInt(value: i64) ?Code {
        if (value < 0x20 or value > 0x32) return null;
        return @fromBackingInt(@intCast(@as(u8, @intCast(value))));
    }
};

pub const ClientModuleReader = struct {
    scheme: []const u8,
    has_hierarchical_uris: bool,
    is_globbable: bool,
    is_local: bool,
};

pub const ClientResourceReader = struct {
    scheme: []const u8,
    has_hierarchical_uris: bool,
    is_globbable: bool,
};

pub const StringPair = struct {
    key: []const u8,
    value: []const u8,
};

pub const ExternalReader = struct {
    scheme: []const u8,
    executable: []const u8,
    arguments: ?[]const []const u8 = null,
    working_dir: ?[]const u8 = null,
};

pub const Checksums = struct {
    sha256: []const u8,
};

pub const RemoteDependency = struct {
    package_uri: []const u8,
    checksums: ?Checksums = null,
};

pub const Project = struct {
    project_file_uri: []const u8,
    package_uri: ?[]const u8 = null,
    dependencies: []const NamedDependency = &.{},
};

pub const NamedDependency = struct {
    name: []const u8,
    dependency: Dependency,
};

pub const Dependency = union(enum) {
    local: Project,
    remote: RemoteDependency,
};

pub const Proxy = struct {
    address: ?[]const u8 = null,
    no_proxy: ?[]const []const u8 = null,
};

pub const HeaderList = struct {
    name: []const u8,
    values: []const []const u8,
};

pub const HeaderRule = struct {
    pattern: []const u8,
    headers: []const HeaderList,
};

pub const Http = struct {
    ca_certificates: ?[]const u8 = null,
    proxy: ?Proxy = null,
    rewrites: ?[]const StringPair = null,
    headers: ?[]const HeaderRule = null,
};

pub const TraceMode = enum {
    compact,
    pretty,

    pub fn wire(self: TraceMode) []const u8 {
        return switch (self) {
            .compact => "COMPACT",
            .pretty => "PRETTY",
        };
    }

    pub fn parse(text: []const u8) ?TraceMode {
        if (std.ascii.eqlIgnoreCase(text, "compact")) return .compact;
        if (std.ascii.eqlIgnoreCase(text, "pretty")) return .pretty;
        return null;
    }
};

pub const PathElement = struct {
    name: []const u8,
    is_directory: bool,
};

pub const CreateEvaluatorRequest = struct {
    request_id: i64,
    allowed_modules: ?[]const []const u8 = null,
    allowed_resources: ?[]const []const u8 = null,
    client_module_readers: ?[]const ClientModuleReader = null,
    client_resource_readers: ?[]const ClientResourceReader = null,
    module_paths: ?[]const []const u8 = null,
    env: ?[]const StringPair = null,
    properties: ?[]const StringPair = null,
    timeout_seconds: ?i64 = null,
    root_dir: ?[]const u8 = null,
    cache_dir: ?[]const u8 = null,
    output_format: ?[]const u8 = null,
    project: ?Project = null,
    http: ?Http = null,
    external_module_readers: ?[]const ExternalReader = null,
    external_resource_readers: ?[]const ExternalReader = null,
    trace_mode: ?TraceMode = null,
};

pub const CreateEvaluatorResponse = struct {
    request_id: i64,
    evaluator_id: ?i64 = null,
    error_message: ?[]const u8 = null,
};

pub const CloseEvaluator = struct {
    evaluator_id: i64,
};

pub const EvaluateRequest = struct {
    request_id: i64,
    evaluator_id: i64,
    module_uri: []const u8,
    module_text: ?[]const u8 = null,
    expression: ?[]const u8 = null,
};

pub const EvaluateResponse = struct {
    request_id: i64,
    evaluator_id: i64,
    result: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
};

pub const LogMessage = struct {
    evaluator_id: i64,
    level: i64,
    message: []const u8,
    frame_uri: []const u8,
};

pub const ReadResourceRequest = struct {
    request_id: i64,
    evaluator_id: i64,
    uri: []const u8,
};

pub const ReadResourceResponse = struct {
    request_id: i64,
    evaluator_id: i64,
    contents: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
};

pub const ReadModuleRequest = struct {
    request_id: i64,
    evaluator_id: i64,
    uri: []const u8,
};

pub const ReadModuleResponse = struct {
    request_id: i64,
    evaluator_id: i64,
    contents: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
};

pub const ListRequest = struct {
    request_id: i64,
    evaluator_id: i64,
    uri: []const u8,
};

pub const ListResponse = struct {
    request_id: i64,
    evaluator_id: i64,
    path_elements: ?[]const PathElement = null,
    error_message: ?[]const u8 = null,
};

pub const InitializeReaderRequest = struct {
    request_id: i64,
    scheme: []const u8,
};

pub const InitializeModuleReaderResponse = struct {
    request_id: i64,
    spec: ?ClientModuleReader = null,
};

pub const InitializeResourceReaderResponse = struct {
    request_id: i64,
    spec: ?ClientResourceReader = null,
};

pub const Message = union(enum) {
    create_evaluator_request: CreateEvaluatorRequest,
    create_evaluator_response: CreateEvaluatorResponse,
    close_evaluator: CloseEvaluator,
    evaluate_request: EvaluateRequest,
    evaluate_response: EvaluateResponse,
    log: LogMessage,
    read_resource_request: ReadResourceRequest,
    read_resource_response: ReadResourceResponse,
    read_module_request: ReadModuleRequest,
    read_module_response: ReadModuleResponse,
    list_resources_request: ListRequest,
    list_resources_response: ListResponse,
    list_modules_request: ListRequest,
    list_modules_response: ListResponse,
    initialize_module_reader_request: InitializeReaderRequest,
    initialize_module_reader_response: InitializeModuleReaderResponse,
    initialize_resource_reader_request: InitializeReaderRequest,
    initialize_resource_reader_response: InitializeResourceReaderResponse,
    close_external_process,

    pub fn code(self: Message) Code {
        return switch (self) {
            .create_evaluator_request => .create_evaluator_request,
            .create_evaluator_response => .create_evaluator_response,
            .close_evaluator => .close_evaluator,
            .evaluate_request => .evaluate_request,
            .evaluate_response => .evaluate_response,
            .log => .log,
            .read_resource_request => .read_resource_request,
            .read_resource_response => .read_resource_response,
            .read_module_request => .read_module_request,
            .read_module_response => .read_module_response,
            .list_resources_request => .list_resources_request,
            .list_resources_response => .list_resources_response,
            .list_modules_request => .list_modules_request,
            .list_modules_response => .list_modules_response,
            .initialize_module_reader_request => .initialize_module_reader_request,
            .initialize_module_reader_response => .initialize_module_reader_response,
            .initialize_resource_reader_request => .initialize_resource_reader_request,
            .initialize_resource_reader_response => .initialize_resource_reader_response,
            .close_external_process => .close_external_process,
        };
    }

    pub fn requestId(self: Message) ?i64 {
        return switch (self) {
            .create_evaluator_request => |body| body.request_id,
            .create_evaluator_response => |body| body.request_id,
            .evaluate_request => |body| body.request_id,
            .evaluate_response => |body| body.request_id,
            .read_resource_request => |body| body.request_id,
            .read_resource_response => |body| body.request_id,
            .read_module_request => |body| body.request_id,
            .read_module_response => |body| body.request_id,
            .list_resources_request, .list_modules_request => |body| body.request_id,
            .list_resources_response, .list_modules_response => |body| body.request_id,
            .initialize_module_reader_request, .initialize_resource_reader_request => |body| body.request_id,
            .initialize_module_reader_response => |body| body.request_id,
            .initialize_resource_reader_response => |body| body.request_id,
            .close_evaluator, .log, .close_external_process => null,
        };
    }

    pub fn evaluatorId(self: Message) ?i64 {
        return switch (self) {
            .close_evaluator => |body| body.evaluator_id,
            .evaluate_request => |body| body.evaluator_id,
            .evaluate_response => |body| body.evaluator_id,
            .log => |body| body.evaluator_id,
            .read_resource_request => |body| body.evaluator_id,
            .read_resource_response => |body| body.evaluator_id,
            .read_module_request => |body| body.evaluator_id,
            .read_module_response => |body| body.evaluator_id,
            .list_resources_request, .list_modules_request => |body| body.evaluator_id,
            .list_resources_response, .list_modules_response => |body| body.evaluator_id,
            else => null,
        };
    }
};

pub const Owned = struct {
    arena: *std.heap.ArenaAllocator,
    message: Message,

    pub fn deinit(self: *Owned) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
        self.* = undefined;
    }
};

const EncodeError = std.Io.Writer.Error || error{ MissingField, LimitExceeded };

pub fn encode(writer: *std.Io.Writer, message: Message) EncodeError!void {
    try msgpack.writeArrayHeader(writer, 2);
    try msgpack.writeInt(writer, @backingInt(message.code()));
    switch (message) {
        .create_evaluator_request => |body| try encodeCreate(writer, body),
        .create_evaluator_response => |body| {
            try beginMap(writer, 1 + present(body.evaluator_id) + present(body.error_message));
            try writeId(writer, "requestId", body.request_id);
            if (body.evaluator_id) |id| try writeId(writer, "evaluatorId", id);
            if (body.error_message) |text| try writeKeyString(writer, "error", text);
        },
        .close_evaluator => |body| {
            try beginMap(writer, 1);
            try writeId(writer, "evaluatorId", body.evaluator_id);
        },
        .evaluate_request => |body| {
            try beginMap(writer, 3 + present(body.module_text) + present(body.expression));
            try writeId(writer, "requestId", body.request_id);
            try writeId(writer, "evaluatorId", body.evaluator_id);
            try writeKeyString(writer, "moduleUri", body.module_uri);
            if (body.module_text) |text| try writeKeyString(writer, "moduleText", text);
            if (body.expression) |text| try writeKeyString(writer, "expr", text);
        },
        .evaluate_response => |body| {
            try beginMap(writer, 2 + present(body.result) + present(body.error_message));
            try writeId(writer, "requestId", body.request_id);
            try writeId(writer, "evaluatorId", body.evaluator_id);
            if (body.result) |bytes| try writeKeyBinary(writer, "result", bytes);
            if (body.error_message) |text| try writeKeyString(writer, "error", text);
        },
        .log => |body| {
            try beginMap(writer, 4);
            try writeId(writer, "evaluatorId", body.evaluator_id);
            try writeId(writer, "level", body.level);
            try writeKeyString(writer, "message", body.message);
            try writeKeyString(writer, "frameUri", body.frame_uri);
        },
        .read_resource_request => |body| try encodeUriRequest(writer, body),
        .read_module_request => |body| try encodeUriRequest(writer, body),
        .list_resources_request, .list_modules_request => |body| try encodeUriRequest(writer, body),
        .read_resource_response => |body| try encodeBytesResponse(writer, body.request_id, body.evaluator_id, body.contents, body.error_message),
        .read_module_response => |body| try encodeTextResponse(writer, body.request_id, body.evaluator_id, body.contents, body.error_message),
        .list_resources_response, .list_modules_response => |body| try encodeListResponse(writer, body),
        .initialize_module_reader_request, .initialize_resource_reader_request => |body| {
            try beginMap(writer, 2);
            try writeId(writer, "requestId", body.request_id);
            try writeKeyString(writer, "scheme", body.scheme);
        },
        .initialize_module_reader_response => |body| {
            try beginMap(writer, 1 + present(body.spec));
            try writeId(writer, "requestId", body.request_id);
            if (body.spec) |spec| {
                try msgpack.writeString(writer, "spec");
                try encodeModuleReader(writer, spec);
            }
        },
        .initialize_resource_reader_response => |body| {
            try beginMap(writer, 1 + present(body.spec));
            try writeId(writer, "requestId", body.request_id);
            if (body.spec) |spec| {
                try msgpack.writeString(writer, "spec");
                try encodeResourceReader(writer, spec);
            }
        },
        .close_external_process => try beginMap(writer, 0),
    }
}

pub fn encodeAlloc(allocator: std.mem.Allocator, message: Message) (EncodeError || error{OutOfMemory})![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try encode(&out.writer, message);
    return out.toOwnedSlice();
}

pub fn decodeSlice(allocator: std.mem.Allocator, bytes: []const u8) Error!Owned {
    var reader = std.Io.Reader.fixed(bytes);
    const owned = try decodeReader(allocator, &reader);
    if (reader.peekByte()) |_| {
        var failed = owned;
        failed.deinit();
        return error.TrailingData;
    } else |err| switch (err) {
        error.EndOfStream => return owned,
        else => {
            var failed = owned;
            failed.deinit();
            return error.ReadFailed;
        },
    }
}

pub fn decodeReader(allocator: std.mem.Allocator, reader: *std.Io.Reader) Error!Owned {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = .init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    var cursor = msgpack.Decoder{
        .reader = reader,
        .allocator = arena.allocator(),
        .limits = .{},
    };
    const dom = try cursor.readDom();
    if (dom != .array or dom.array.len != 2) return error.InvalidMessage;
    const code = Code.fromInt(try asI64(&dom.array[0])) orelse return error.UnknownCode;
    if (dom.array[1] != .map) return error.InvalidMessage;
    return .{
        .arena = arena,
        .message = try parse(arena.allocator(), code, dom.array[1].map),
    };
}

fn encodeCreate(writer: *std.Io.Writer, body: CreateEvaluatorRequest) EncodeError!void {
    const fields: u32 = 1 +
        present(body.allowed_modules) +
        present(body.allowed_resources) +
        present(body.client_module_readers) +
        present(body.client_resource_readers) +
        present(body.module_paths) +
        present(body.env) +
        present(body.properties) +
        present(body.timeout_seconds) +
        present(body.root_dir) +
        present(body.cache_dir) +
        present(body.output_format) +
        present(body.project) +
        present(body.http) +
        present(body.external_module_readers) +
        present(body.external_resource_readers) +
        present(body.trace_mode);
    try beginMap(writer, fields);
    try writeId(writer, "requestId", body.request_id);
    if (body.allowed_modules) |values| try writeKeyStrings(writer, "allowedModules", values);
    if (body.allowed_resources) |values| try writeKeyStrings(writer, "allowedResources", values);
    if (body.client_module_readers) |readers| {
        try msgpack.writeString(writer, "clientModuleReaders");
        try msgpack.writeArrayHeader(writer, try asLen(readers.len));
        for (readers) |reader| try encodeModuleReader(writer, reader);
    }
    if (body.client_resource_readers) |readers| {
        try msgpack.writeString(writer, "clientResourceReaders");
        try msgpack.writeArrayHeader(writer, try asLen(readers.len));
        for (readers) |reader| try encodeResourceReader(writer, reader);
    }
    if (body.module_paths) |values| try writeKeyStrings(writer, "modulePaths", values);
    if (body.env) |values| try writeKeyPairs(writer, "env", values);
    if (body.properties) |values| try writeKeyPairs(writer, "properties", values);
    if (body.timeout_seconds) |seconds| try writeId(writer, "timeoutSeconds", seconds);
    if (body.root_dir) |path| try writeKeyString(writer, "rootDir", path);
    if (body.cache_dir) |path| try writeKeyString(writer, "cacheDir", path);
    if (body.output_format) |format| try writeKeyString(writer, "outputFormat", format);
    if (body.project) |project| {
        try msgpack.writeString(writer, "project");
        try encodeProject(writer, project, false);
    }
    if (body.http) |http| {
        try msgpack.writeString(writer, "http");
        try encodeHttp(writer, http);
    }
    if (body.external_module_readers) |readers| try writeExternalMap(writer, "externalModuleReaders", readers);
    if (body.external_resource_readers) |readers| try writeExternalMap(writer, "externalResourceReaders", readers);
    if (body.trace_mode) |mode| try writeKeyString(writer, "traceMode", mode.wire());
}

fn encodeProject(writer: *std.Io.Writer, project: Project, nested: bool) EncodeError!void {
    if (nested) {
        const package_uri = project.package_uri orelse return error.MissingField;
        try beginMap(writer, 4);
        try writeKeyString(writer, "type", "local");
        try writeKeyString(writer, "packageUri", package_uri);
        try writeKeyString(writer, "projectFileUri", project.project_file_uri);
    } else {
        try beginMap(writer, 2 + present(project.package_uri));
        try writeKeyString(writer, "projectFileUri", project.project_file_uri);
        if (project.package_uri) |uri| try writeKeyString(writer, "packageUri", uri);
    }
    try msgpack.writeString(writer, "dependencies");
    try encodeDependencies(writer, project.dependencies);
}

fn encodeDependencies(writer: *std.Io.Writer, dependencies: []const NamedDependency) EncodeError!void {
    try msgpack.writeMapHeader(writer, try asLen(dependencies.len));
    for (dependencies) |dependency| {
        try msgpack.writeString(writer, dependency.name);
        switch (dependency.dependency) {
            .local => |project| try encodeProject(writer, project, true),
            .remote => |remote| {
                try beginMap(writer, 2 + present(remote.checksums));
                try writeKeyString(writer, "type", "remote");
                try writeKeyString(writer, "packageUri", remote.package_uri);
                if (remote.checksums) |checksums| {
                    try msgpack.writeString(writer, "checksums");
                    try beginMap(writer, 1);
                    try writeKeyString(writer, "sha256", checksums.sha256);
                }
            },
        }
    }
}

fn encodeHttp(writer: *std.Io.Writer, http: Http) EncodeError!void {
    try beginMap(writer, present(http.ca_certificates) + present(http.proxy) + present(http.rewrites) + present(http.headers));
    if (http.ca_certificates) |bytes| try writeKeyBinary(writer, "caCertificates", bytes);
    if (http.proxy) |proxy| {
        try msgpack.writeString(writer, "proxy");
        try beginMap(writer, present(proxy.address) + present(proxy.no_proxy));
        if (proxy.address) |address| try writeKeyString(writer, "address", address);
        if (proxy.no_proxy) |hosts| try writeKeyStrings(writer, "noProxy", hosts);
    }
    if (http.rewrites) |rewrites| try writeKeyPairs(writer, "rewrites", rewrites);
    if (http.headers) |rules| {
        try msgpack.writeString(writer, "headers");
        try msgpack.writeMapHeader(writer, try asLen(rules.len));
        for (rules) |rule| {
            try msgpack.writeString(writer, rule.pattern);
            try msgpack.writeMapHeader(writer, try asLen(rule.headers.len));
            for (rule.headers) |header| {
                try msgpack.writeString(writer, header.name);
                try msgpack.writeArrayHeader(writer, try asLen(header.values.len));
                for (header.values) |value| try msgpack.writeString(writer, value);
            }
        }
    }
}

fn encodeModuleReader(writer: *std.Io.Writer, reader: ClientModuleReader) std.Io.Writer.Error!void {
    try beginMap(writer, 4);
    try writeKeyString(writer, "scheme", reader.scheme);
    try writeKeyBool(writer, "hasHierarchicalUris", reader.has_hierarchical_uris);
    try writeKeyBool(writer, "isLocal", reader.is_local);
    try writeKeyBool(writer, "isGlobbable", reader.is_globbable);
}

fn encodeResourceReader(writer: *std.Io.Writer, reader: ClientResourceReader) std.Io.Writer.Error!void {
    try beginMap(writer, 3);
    try writeKeyString(writer, "scheme", reader.scheme);
    try writeKeyBool(writer, "hasHierarchicalUris", reader.has_hierarchical_uris);
    try writeKeyBool(writer, "isGlobbable", reader.is_globbable);
}

fn encodeUriRequest(writer: *std.Io.Writer, body: anytype) std.Io.Writer.Error!void {
    try beginMap(writer, 3);
    try writeId(writer, "requestId", body.request_id);
    try writeId(writer, "evaluatorId", body.evaluator_id);
    try writeKeyString(writer, "uri", body.uri);
}

fn encodeBytesResponse(
    writer: *std.Io.Writer,
    request_id: i64,
    evaluator_id: i64,
    contents: ?[]const u8,
    error_message: ?[]const u8,
) std.Io.Writer.Error!void {
    try beginMap(writer, 2 + present(contents) + present(error_message));
    try writeId(writer, "requestId", request_id);
    try writeId(writer, "evaluatorId", evaluator_id);
    if (contents) |bytes| try writeKeyBinary(writer, "contents", bytes);
    if (error_message) |text| try writeKeyString(writer, "error", text);
}

fn encodeTextResponse(
    writer: *std.Io.Writer,
    request_id: i64,
    evaluator_id: i64,
    contents: ?[]const u8,
    error_message: ?[]const u8,
) std.Io.Writer.Error!void {
    try beginMap(writer, 2 + present(contents) + present(error_message));
    try writeId(writer, "requestId", request_id);
    try writeId(writer, "evaluatorId", evaluator_id);
    if (contents) |text| try writeKeyString(writer, "contents", text);
    if (error_message) |text| try writeKeyString(writer, "error", text);
}

fn encodeListResponse(writer: *std.Io.Writer, body: ListResponse) EncodeError!void {
    try beginMap(writer, 2 + present(body.path_elements) + present(body.error_message));
    try writeId(writer, "requestId", body.request_id);
    try writeId(writer, "evaluatorId", body.evaluator_id);
    if (body.path_elements) |elements| {
        try msgpack.writeString(writer, "pathElements");
        try msgpack.writeArrayHeader(writer, try asLen(elements.len));
        for (elements) |element| {
            try beginMap(writer, 2);
            try writeKeyString(writer, "name", element.name);
            try writeKeyBool(writer, "isDirectory", element.is_directory);
        }
    }
    if (body.error_message) |text| try writeKeyString(writer, "error", text);
}

fn writeExternalMap(writer: *std.Io.Writer, key: []const u8, readers: []const ExternalReader) EncodeError!void {
    try msgpack.writeString(writer, key);
    try msgpack.writeMapHeader(writer, try asLen(readers.len));
    for (readers) |reader| {
        try msgpack.writeString(writer, reader.scheme);
        try beginMap(writer, 1 + present(reader.arguments) + present(reader.working_dir));
        try writeKeyString(writer, "executable", reader.executable);
        if (reader.arguments) |arguments| try writeKeyStrings(writer, "arguments", arguments);
        if (reader.working_dir) |dir| try writeKeyString(writer, "workingDir", dir);
    }
}

fn parse(allocator: std.mem.Allocator, code: Code, map: []const msgpack.Value.Entry) Error!Message {
    return switch (code) {
        .create_evaluator_request => .{ .create_evaluator_request = .{
            .request_id = try requiredI64(map, "requestId"),
            .allowed_modules = try optionalStrings(allocator, map, "allowedModules"),
            .allowed_resources = try optionalStrings(allocator, map, "allowedResources"),
            .client_module_readers = try optionalModuleReaders(allocator, map, "clientModuleReaders"),
            .client_resource_readers = try optionalResourceReaders(allocator, map, "clientResourceReaders"),
            .module_paths = try optionalStrings(allocator, map, "modulePaths"),
            .env = try optionalPairs(allocator, map, "env"),
            .properties = try optionalPairs(allocator, map, "properties"),
            .timeout_seconds = try optionalI64(map, "timeoutSeconds"),
            .root_dir = try optionalString(map, "rootDir"),
            .cache_dir = try optionalString(map, "cacheDir"),
            .output_format = try optionalString(map, "outputFormat"),
            .project = try optionalProject(allocator, map),
            .http = try optionalHttp(allocator, map),
            .external_module_readers = try optionalExternal(allocator, map, "externalModuleReaders"),
            .external_resource_readers = try optionalExternal(allocator, map, "externalResourceReaders"),
            .trace_mode = try optionalTrace(map),
        } },
        .create_evaluator_response => .{ .create_evaluator_response = .{
            .request_id = try requiredI64(map, "requestId"),
            .evaluator_id = try optionalI64(map, "evaluatorId"),
            .error_message = try optionalString(map, "error"),
        } },
        .close_evaluator => .{ .close_evaluator = .{ .evaluator_id = try requiredI64(map, "evaluatorId") } },
        .evaluate_request => .{ .evaluate_request = .{
            .request_id = try requiredI64(map, "requestId"),
            .evaluator_id = try requiredI64(map, "evaluatorId"),
            .module_uri = try requiredString(map, "moduleUri"),
            .module_text = try optionalString(map, "moduleText"),
            .expression = try optionalString(map, "expr"),
        } },
        .evaluate_response => .{ .evaluate_response = .{
            .request_id = try requiredI64(map, "requestId"),
            .evaluator_id = try requiredI64(map, "evaluatorId"),
            .result = try optionalBinary(map, "result"),
            .error_message = try optionalString(map, "error"),
        } },
        .log => .{ .log = .{
            .evaluator_id = try requiredI64(map, "evaluatorId"),
            .level = try requiredI64(map, "level"),
            .message = try requiredString(map, "message"),
            .frame_uri = try requiredString(map, "frameUri"),
        } },
        .read_resource_request => .{ .read_resource_request = try parseUriRequest(ReadResourceRequest, map) },
        .read_module_request => .{ .read_module_request = try parseUriRequest(ReadModuleRequest, map) },
        .list_resources_request => .{ .list_resources_request = try parseListRequest(map) },
        .list_modules_request => .{ .list_modules_request = try parseListRequest(map) },
        .read_resource_response => .{ .read_resource_response = .{
            .request_id = try requiredI64(map, "requestId"),
            .evaluator_id = try requiredI64(map, "evaluatorId"),
            .contents = try optionalBinary(map, "contents"),
            .error_message = try optionalString(map, "error"),
        } },
        .read_module_response => .{ .read_module_response = .{
            .request_id = try requiredI64(map, "requestId"),
            .evaluator_id = try requiredI64(map, "evaluatorId"),
            .contents = try optionalString(map, "contents"),
            .error_message = try optionalString(map, "error"),
        } },
        .list_resources_response => .{ .list_resources_response = try parseListResponse(allocator, map) },
        .list_modules_response => .{ .list_modules_response = try parseListResponse(allocator, map) },
        .initialize_module_reader_request => .{ .initialize_module_reader_request = try parseInitRequest(map) },
        .initialize_resource_reader_request => .{ .initialize_resource_reader_request = try parseInitRequest(map) },
        .initialize_module_reader_response => .{ .initialize_module_reader_response = .{
            .request_id = try requiredI64(map, "requestId"),
            .spec = if (optionalField(map, "spec")) |spec| try parseModuleReader(spec) else null,
        } },
        .initialize_resource_reader_response => .{ .initialize_resource_reader_response = .{
            .request_id = try requiredI64(map, "requestId"),
            .spec = if (optionalField(map, "spec")) |spec| try parseResourceReader(spec) else null,
        } },
        .close_external_process => .close_external_process,
    };
}

fn parseUriRequest(comptime T: type, map: []const msgpack.Value.Entry) Error!T {
    return .{
        .request_id = try requiredI64(map, "requestId"),
        .evaluator_id = try requiredI64(map, "evaluatorId"),
        .uri = try requiredString(map, "uri"),
    };
}

fn parseListRequest(map: []const msgpack.Value.Entry) Error!ListRequest {
    const request = try parseUriRequest(ListRequest, map);
    return .{ .request_id = request.request_id, .evaluator_id = request.evaluator_id, .uri = request.uri };
}

fn parseInitRequest(map: []const msgpack.Value.Entry) Error!InitializeReaderRequest {
    return .{
        .request_id = try requiredI64(map, "requestId"),
        .scheme = try requiredString(map, "scheme"),
    };
}

fn parseListResponse(allocator: std.mem.Allocator, map: []const msgpack.Value.Entry) Error!ListResponse {
    return .{
        .request_id = try requiredI64(map, "requestId"),
        .evaluator_id = try requiredI64(map, "evaluatorId"),
        .path_elements = if (optionalField(map, "pathElements")) |value| try parsePathElements(allocator, value) else null,
        .error_message = try optionalString(map, "error"),
    };
}

fn optionalProject(allocator: std.mem.Allocator, map: []const msgpack.Value.Entry) Error!?Project {
    const value = optionalField(map, "project") orelse return null;
    return try parseProject(allocator, value, false);
}

fn parseProject(allocator: std.mem.Allocator, value: *const msgpack.Value, nested: bool) Error!Project {
    _ = nested;
    if (value.* != .map) return error.TypeMismatch;
    const dependencies = optionalField(value.map, "dependencies") orelse return error.MissingField;
    return .{
        .project_file_uri = try requiredString(value.map, "projectFileUri"),
        .package_uri = try optionalString(value.map, "packageUri"),
        .dependencies = try parseDependencies(allocator, dependencies),
    };
}

fn parseDependencies(allocator: std.mem.Allocator, value: *const msgpack.Value) Error![]const NamedDependency {
    if (value.* != .map) return error.TypeMismatch;
    const out = try allocator.alloc(NamedDependency, value.map.len);
    for (value.map, out) |entry, *slot| {
        if (entry.key != .string or entry.value != .map) return error.TypeMismatch;
        const kind = try requiredString(entry.value.map, "type");
        if (std.mem.eql(u8, kind, "remote")) {
            slot.* = .{
                .name = entry.key.string,
                .dependency = .{ .remote = .{
                    .package_uri = try requiredString(entry.value.map, "packageUri"),
                    .checksums = try parseChecksums(entry.value.map),
                } },
            };
        } else if (std.mem.eql(u8, kind, "local")) {
            slot.* = .{
                .name = entry.key.string,
                .dependency = .{ .local = try parseProject(allocator, &entry.value, true) },
            };
        } else return error.InvalidMessage;
    }
    return out;
}

fn parseChecksums(map: []const msgpack.Value.Entry) Error!?Checksums {
    const value = optionalField(map, "checksums") orelse return null;
    if (value.* != .map) return error.TypeMismatch;
    return .{ .sha256 = try requiredString(value.map, "sha256") };
}

fn optionalHttp(allocator: std.mem.Allocator, map: []const msgpack.Value.Entry) Error!?Http {
    const value = optionalField(map, "http") orelse return null;
    if (value.* != .map) return error.TypeMismatch;
    return .{
        .ca_certificates = try optionalBinary(value.map, "caCertificates"),
        .proxy = try parseProxy(allocator, value.map),
        .rewrites = try optionalPairs(allocator, value.map, "rewrites"),
        .headers = if (optionalField(value.map, "headers")) |headers| try parseHeaders(allocator, headers) else null,
    };
}

fn parseProxy(allocator: std.mem.Allocator, map: []const msgpack.Value.Entry) Error!?Proxy {
    const value = optionalField(map, "proxy") orelse return null;
    if (value.* != .map) return error.TypeMismatch;
    return .{
        .address = try optionalString(value.map, "address"),
        .no_proxy = try optionalStrings(allocator, value.map, "noProxy"),
    };
}

fn parseHeaders(allocator: std.mem.Allocator, value: *const msgpack.Value) Error![]const HeaderRule {
    if (value.* != .map) return error.TypeMismatch;
    const rules = try allocator.alloc(HeaderRule, value.map.len);
    for (value.map, rules) |entry, *rule| {
        if (entry.key != .string or entry.value != .map) return error.TypeMismatch;
        const headers = try allocator.alloc(HeaderList, entry.value.map.len);
        for (entry.value.map, headers) |header, *slot| {
            if (header.key != .string) return error.TypeMismatch;
            slot.* = .{
                .name = header.key.string,
                .values = try stringList(allocator, &header.value),
            };
        }
        rule.* = .{ .pattern = entry.key.string, .headers = headers };
    }
    return rules;
}

fn optionalExternal(allocator: std.mem.Allocator, map: []const msgpack.Value.Entry, name: []const u8) Error!?[]const ExternalReader {
    const value = optionalField(map, name) orelse return null;
    if (value.* != .map) return error.TypeMismatch;
    const out = try allocator.alloc(ExternalReader, value.map.len);
    for (value.map, out) |entry, *slot| {
        if (entry.key != .string or entry.value != .map) return error.TypeMismatch;
        slot.* = .{
            .scheme = entry.key.string,
            .executable = try requiredString(entry.value.map, "executable"),
            .arguments = try optionalStrings(allocator, entry.value.map, "arguments"),
            .working_dir = try optionalString(entry.value.map, "workingDir"),
        };
    }
    return out;
}

fn optionalTrace(map: []const msgpack.Value.Entry) Error!?TraceMode {
    const text = try optionalString(map, "traceMode") orelse return null;
    return TraceMode.parse(text) orelse error.InvalidMessage;
}

fn optionalModuleReaders(allocator: std.mem.Allocator, map: []const msgpack.Value.Entry, name: []const u8) Error!?[]const ClientModuleReader {
    const value = optionalField(map, name) orelse return null;
    if (value.* != .array) return error.TypeMismatch;
    const out = try allocator.alloc(ClientModuleReader, value.array.len);
    for (value.array, out) |item, *slot| slot.* = try parseModuleReader(&item);
    return out;
}

fn optionalResourceReaders(allocator: std.mem.Allocator, map: []const msgpack.Value.Entry, name: []const u8) Error!?[]const ClientResourceReader {
    const value = optionalField(map, name) orelse return null;
    if (value.* != .array) return error.TypeMismatch;
    const out = try allocator.alloc(ClientResourceReader, value.array.len);
    for (value.array, out) |item, *slot| slot.* = try parseResourceReader(&item);
    return out;
}

fn parseModuleReader(value: *const msgpack.Value) Error!ClientModuleReader {
    if (value.* != .map) return error.TypeMismatch;
    return .{
        .scheme = try requiredString(value.map, "scheme"),
        .has_hierarchical_uris = try requiredBool(value.map, "hasHierarchicalUris"),
        .is_globbable = try requiredBool(value.map, "isGlobbable"),
        .is_local = try requiredBool(value.map, "isLocal"),
    };
}

fn parseResourceReader(value: *const msgpack.Value) Error!ClientResourceReader {
    if (value.* != .map) return error.TypeMismatch;
    return .{
        .scheme = try requiredString(value.map, "scheme"),
        .has_hierarchical_uris = try requiredBool(value.map, "hasHierarchicalUris"),
        .is_globbable = try requiredBool(value.map, "isGlobbable"),
    };
}

fn parsePathElements(allocator: std.mem.Allocator, value: *const msgpack.Value) Error![]const PathElement {
    if (value.* != .array) return error.TypeMismatch;
    const out = try allocator.alloc(PathElement, value.array.len);
    for (value.array, out) |item, *slot| {
        if (item != .map) return error.TypeMismatch;
        slot.* = .{
            .name = try requiredString(item.map, "name"),
            .is_directory = try requiredBool(item.map, "isDirectory"),
        };
    }
    return out;
}

fn optionalStrings(allocator: std.mem.Allocator, map: []const msgpack.Value.Entry, name: []const u8) Error!?[]const []const u8 {
    const value = optionalField(map, name) orelse return null;
    return try stringList(allocator, value);
}

fn stringList(allocator: std.mem.Allocator, value: *const msgpack.Value) Error![]const []const u8 {
    if (value.* != .array) return error.TypeMismatch;
    const out = try allocator.alloc([]const u8, value.array.len);
    for (value.array, out) |item, *slot| {
        if (item != .string) return error.TypeMismatch;
        slot.* = item.string;
    }
    return out;
}

fn optionalPairs(allocator: std.mem.Allocator, map: []const msgpack.Value.Entry, name: []const u8) Error!?[]const StringPair {
    const value = optionalField(map, name) orelse return null;
    if (value.* != .map) return error.TypeMismatch;
    const out = try allocator.alloc(StringPair, value.map.len);
    for (value.map, out) |entry, *slot| {
        if (entry.key != .string or entry.value != .string) return error.TypeMismatch;
        slot.* = .{ .key = entry.key.string, .value = entry.value.string };
    }
    return out;
}

fn optionalField(map: []const msgpack.Value.Entry, name: []const u8) ?*const msgpack.Value {
    for (map) |*entry| {
        if (entry.key == .string and std.mem.eql(u8, entry.key.string, name)) {
            if (entry.value == .nil) return null;
            return &entry.value;
        }
    }
    return null;
}

fn requiredString(map: []const msgpack.Value.Entry, name: []const u8) Error![]const u8 {
    return (try optionalString(map, name)) orelse error.MissingField;
}

fn optionalString(map: []const msgpack.Value.Entry, name: []const u8) Error!?[]const u8 {
    const value = optionalField(map, name) orelse return null;
    if (value.* != .string) return error.TypeMismatch;
    return value.string;
}

fn optionalBinary(map: []const msgpack.Value.Entry, name: []const u8) Error!?[]const u8 {
    const value = optionalField(map, name) orelse return null;
    if (value.* != .binary) return error.TypeMismatch;
    return value.binary;
}

fn requiredI64(map: []const msgpack.Value.Entry, name: []const u8) Error!i64 {
    return (try optionalI64(map, name)) orelse error.MissingField;
}

fn optionalI64(map: []const msgpack.Value.Entry, name: []const u8) Error!?i64 {
    const value = optionalField(map, name) orelse return null;
    return try asI64(value);
}

fn requiredBool(map: []const msgpack.Value.Entry, name: []const u8) Error!bool {
    const value = optionalField(map, name) orelse return error.MissingField;
    if (value.* != .boolean) return error.TypeMismatch;
    return value.boolean;
}

fn asI64(value: *const msgpack.Value) Error!i64 {
    if (value.* != .int) return error.TypeMismatch;
    return value.int.asSigned() catch error.Overflow;
}

fn present(value: anytype) u32 {
    return if (value != null) 1 else 0;
}

fn asLen(len: usize) error{LimitExceeded}!u32 {
    if (len > std.math.maxInt(u32)) return error.LimitExceeded;
    return @intCast(len);
}

fn beginMap(writer: *std.Io.Writer, len: u32) std.Io.Writer.Error!void {
    try msgpack.writeMapHeader(writer, len);
}

fn writeId(writer: *std.Io.Writer, key: []const u8, value: i64) std.Io.Writer.Error!void {
    try msgpack.writeString(writer, key);
    try msgpack.writeInt(writer, value);
}

fn writeKeyString(writer: *std.Io.Writer, key: []const u8, value: []const u8) std.Io.Writer.Error!void {
    try msgpack.writeString(writer, key);
    try msgpack.writeString(writer, value);
}

fn writeKeyBool(writer: *std.Io.Writer, key: []const u8, value: bool) std.Io.Writer.Error!void {
    try msgpack.writeString(writer, key);
    try msgpack.writeBool(writer, value);
}

fn writeKeyBinary(writer: *std.Io.Writer, key: []const u8, value: []const u8) std.Io.Writer.Error!void {
    try msgpack.writeString(writer, key);
    try msgpack.writeBinary(writer, value);
}

fn writeKeyStrings(writer: *std.Io.Writer, key: []const u8, values: []const []const u8) EncodeError!void {
    try msgpack.writeString(writer, key);
    try msgpack.writeArrayHeader(writer, try asLen(values.len));
    for (values) |value| try msgpack.writeString(writer, value);
}

fn writeKeyPairs(writer: *std.Io.Writer, key: []const u8, values: []const StringPair) EncodeError!void {
    try msgpack.writeString(writer, key);
    try msgpack.writeMapHeader(writer, try asLen(values.len));
    for (values) |value| try writeKeyString(writer, value.key, value.value);
}

fn roundtrip(message: Message) !void {
    const allocator = std.testing.allocator;
    const encoded = try encodeAlloc(allocator, message);
    defer allocator.free(encoded);
    var owned = try decodeSlice(allocator, encoded);
    defer owned.deinit();
    const again = try encodeAlloc(allocator, owned.message);
    defer allocator.free(again);
    try std.testing.expectEqualSlices(u8, encoded, again);
}

test "every message code round-trips and keeps string and binary distinct" {
    try roundtrip(.{ .create_evaluator_response = .{ .request_id = 7, .evaluator_id = -4 } });
    try roundtrip(.{ .close_evaluator = .{ .evaluator_id = 3 } });
    try roundtrip(.{ .evaluate_request = .{
        .request_id = 1,
        .evaluator_id = 2,
        .module_uri = "repl:test",
        .module_text = "foo = 1",
        .expression = "foo",
    } });
    try roundtrip(.{ .evaluate_response = .{
        .request_id = 1,
        .evaluator_id = 2,
        .result = "\x01",
    } });
    try roundtrip(.{ .log = .{
        .evaluator_id = 2,
        .level = 0,
        .message = "trace",
        .frame_uri = "repl:test",
    } });
    try roundtrip(.{ .read_resource_request = .{ .request_id = 4, .evaluator_id = 2, .uri = "file:///a" } });
    try roundtrip(.{ .read_resource_response = .{
        .request_id = 4,
        .evaluator_id = 2,
        .contents = "hi",
    } });
    try roundtrip(.{ .read_module_request = .{ .request_id = 5, .evaluator_id = 2, .uri = "custom:a.pkl" } });
    try roundtrip(.{ .read_module_response = .{
        .request_id = 5,
        .evaluator_id = 2,
        .contents = "foo = 1",
    } });
    try roundtrip(.{ .list_resources_request = .{ .request_id = 6, .evaluator_id = 2, .uri = "custom:/" } });
    try roundtrip(.{ .list_resources_response = .{
        .request_id = 6,
        .evaluator_id = 2,
        .path_elements = &.{ .{ .name = "a", .is_directory = false }, .{ .name = "dir", .is_directory = true } },
    } });
    try roundtrip(.{ .list_modules_request = .{ .request_id = 8, .evaluator_id = 2, .uri = "custom:/" } });
    try roundtrip(.{ .list_modules_response = .{ .request_id = 8, .evaluator_id = 2, .error_message = "nope" } });
    try roundtrip(.{ .initialize_module_reader_request = .{ .request_id = 9, .scheme = "custom" } });
    try roundtrip(.{ .initialize_module_reader_response = .{
        .request_id = 9,
        .spec = .{
            .scheme = "custom",
            .has_hierarchical_uris = true,
            .is_globbable = true,
            .is_local = true,
        },
    } });
    try roundtrip(.{ .initialize_resource_reader_request = .{ .request_id = 10, .scheme = "env" } });
    try roundtrip(.{ .initialize_resource_reader_response = .{ .request_id = 10, .spec = null } });
    try roundtrip(.close_external_process);

    const allocator = std.testing.allocator;
    const modules = [_][]const u8{ "pkl:", "repl:" };
    const resources = [_][]const u8{};
    const env = [_]StringPair{.{ .key = "A", .value = "B" }};
    const rewrites = [_]StringPair{.{ .key = "https://example.com/", .value = "https://mirror.example/" }};
    const header_values = [_][]const u8{"token"};
    const headers = [_]HeaderList{.{ .name = "Authorization", .values = &header_values }};
    const rules = [_]HeaderRule{.{ .pattern = "https://example.com/**", .headers = &headers }};
    const arguments = [_][]const u8{"--serve"};
    const readers = [_]ExternalReader{.{
        .scheme = "secret",
        .executable = "/bin/reader",
        .arguments = &arguments,
    }};
    const leaf = [_]NamedDependency{.{
        .name = "leaf",
        .dependency = .{ .remote = .{ .package_uri = "package://example.com/leaf@2.0.0" } },
    }};
    const nested = [_]NamedDependency{ .{
        .name = "pkg",
        .dependency = .{ .remote = .{
            .package_uri = "package://example.com/pkg@1.0.0",
            .checksums = .{ .sha256 = "abc" },
        } },
    }, .{
        .name = "local",
        .dependency = .{ .local = .{
            .project_file_uri = "file:///dep/PklProject",
            .package_uri = "package://example.com/local@0.1.0",
            .dependencies = &leaf,
        } },
    } };
    const full = Message{ .create_evaluator_request = .{
        .request_id = 11,
        .allowed_modules = &modules,
        .allowed_resources = &resources,
        .client_module_readers = &.{.{
            .scheme = "custom",
            .has_hierarchical_uris = true,
            .is_globbable = false,
            .is_local = true,
        }},
        .client_resource_readers = &.{.{
            .scheme = "res",
            .has_hierarchical_uris = false,
            .is_globbable = false,
        }},
        .module_paths = &.{"/opt/modules"},
        .env = &env,
        .properties = &env,
        .timeout_seconds = 5,
        .root_dir = "/work",
        .cache_dir = "/cache",
        .output_format = "pkl-binary",
        .project = .{
            .project_file_uri = "file:///work/PklProject",
            .package_uri = "package://example.com/app@1",
            .dependencies = &nested,
        },
        .http = .{
            .ca_certificates = "pem",
            .proxy = .{ .address = "http://proxy:5080", .no_proxy = &.{"localhost"} },
            .rewrites = &rewrites,
            .headers = &rules,
        },
        .external_module_readers = &readers,
        .external_resource_readers = &readers,
        .trace_mode = .pretty,
    } };
    try roundtrip(full);
    const full_bytes = try encodeAlloc(allocator, full);
    defer allocator.free(full_bytes);
    var full_decoded = try decodeSlice(allocator, full_bytes);
    defer full_decoded.deinit();
    const local = full_decoded.message.create_evaluator_request.project.?.dependencies[1];
    try std.testing.expectEqualStrings("local", local.name);
    try std.testing.expectEqualStrings("file:///dep/PklProject", local.dependency.local.project_file_uri);
    try std.testing.expectEqualStrings("package://example.com/local@0.1.0", local.dependency.local.package_uri.?);
    try std.testing.expectEqualStrings("leaf", local.dependency.local.dependencies[0].name);

    const encoded = try encodeAlloc(allocator, .{ .create_evaluator_request = .{
        .request_id = 1,
        .allowed_resources = &.{},
    } });
    defer allocator.free(encoded);
    var owned = try decodeSlice(allocator, encoded);
    defer owned.deinit();
    try std.testing.expectEqual(@as(usize, 0), owned.message.create_evaluator_request.allowed_resources.?.len);

    var extra: std.Io.Writer.Allocating = .init(allocator);
    defer extra.deinit();
    try msgpack.writeArrayHeader(&extra.writer, 2);
    try msgpack.writeInt(&extra.writer, 0x21);
    try msgpack.writeMapHeader(&extra.writer, 3);
    try writeId(&extra.writer, "requestId", 1);
    try writeId(&extra.writer, "evaluatorId", 9);
    try writeKeyString(&extra.writer, "futureField", "ignored");
    var decoded = try decodeSlice(allocator, extra.written());
    defer decoded.deinit();
    try std.testing.expectEqual(@as(i64, 9), decoded.message.create_evaluator_response.evaluator_id.?);

    var text_result: std.Io.Writer.Allocating = .init(allocator);
    defer text_result.deinit();
    try msgpack.writeArrayHeader(&text_result.writer, 2);
    try msgpack.writeInt(&text_result.writer, 0x24);
    try msgpack.writeMapHeader(&text_result.writer, 3);
    try writeId(&text_result.writer, "requestId", 1);
    try writeId(&text_result.writer, "evaluatorId", 2);
    try writeKeyString(&text_result.writer, "result", "nope");
    try std.testing.expectError(error.TypeMismatch, decodeSlice(allocator, text_result.written()));
}

fn decodeClose(allocator: std.mem.Allocator, encoded: []const u8) !void {
    var owned = try decodeSlice(allocator, encoded);
    owned.deinit();
}

test "message decode releases memory when allocation fails" {
    const encoded = try encodeAlloc(std.testing.allocator, .{ .close_evaluator = .{ .evaluator_id = 1 } });
    defer std.testing.allocator.free(encoded);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, decodeClose, .{encoded});
}
