//! Concurrent evaluator manager. One backend connection is shared by every evaluator.
//!
//! A single response thread reads frames from the backend. Reader callbacks
//! requested by the server run on a fixed pool of worker threads fed by a
//! bounded queue; when the queue is full the server receives an error reply.
//! A transport failure or malformed frame is terminal: every pending request
//! fails with that error and every later request fails immediately with it.

const std = @import("std");
const backend = @import("../backend.zig");
const message = @import("../protocol/message.zig");
const msgpack = @import("../protocol/msgpack.zig");
const value = @import("../value/value.zig");
const logger = @import("logger.zig");
const options = @import("options.zig");
const reader = @import("reader.zig");
const source = @import("source.zig");
const subprocess = @import("../backends/subprocess.zig");
const version = @import("version.zig");

pub const Options = options.Options;
pub const Builder = options.Builder;
pub const Version = version.Version;
pub const Source = source.Source;

pub const Cancellation = struct {
    canceled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn cancel(self: *Cancellation) void {
        self.canceled.store(true, .release);
    }

    pub fn isCanceled(self: *const Cancellation) bool {
        return self.canceled.load(.acquire);
    }
};

pub const RequestOptions = struct {
    timeout: std.Io.Timeout = .none,
    cancellation: ?*const Cancellation = null,
};

/// How `Manager.initWithOptions` learns the Pkl version used to validate
/// evaluator options.
pub const VersionCheck = union(enum) {
    /// Run the server command with its final `server` argument replaced by `--version`.
    probe,
    /// Use a version supplied by the caller.
    known: Version,
    /// Skip feature validation.
    unchecked,
};

pub const InitOptions = struct {
    log: logger.Logger = logger.Logger.noop,
    /// Used by `initWithOptions` only.
    version: VersionCheck = .probe,
    /// Used by `initWithOptions` only.
    subprocess: subprocess.Options = .{},
    /// Threads that run module and resource reader callbacks.
    reader_workers: u16 = 4,
    /// Callback requests that may wait for a worker before the server is
    /// told the reader is busy.
    reader_queue_capacity: u16 = 64,
};

/// An evaluator handle owned by its manager. `close` is thread-safe and
/// idempotent; the handle remains allocated, but rejects new work, until
/// `Manager.deinit`. The manager must outlive all calls using this handle.
pub const Evaluator = struct {
    id: i64,
    manager: *Manager,
    module_readers: []const reader.ModuleReader,
    resource_readers: []const reader.ResourceReader,
    log: logger.Logger,
    closed: std.atomic.Value(bool),
    /// Reader and logger callbacks queued or running for this evaluator.
    /// Guarded by the manager mutex.
    callbacks: usize,

    pub fn evaluate(
        self: *Evaluator,
        module_uri: []const u8,
        module_text: ?[]const u8,
        expression: ?[]const u8,
        failure: *?[]u8,
    ) !value.Tree {
        return self.evaluateWithOptions(module_uri, module_text, expression, failure, .{});
    }

    pub fn evaluateWithOptions(
        self: *Evaluator,
        module_uri: []const u8,
        module_text: ?[]const u8,
        expression: ?[]const u8,
        failure: *?[]u8,
        request_options: RequestOptions,
    ) !value.Tree {
        if (self.closed.load(.acquire)) return error.Closed;
        const owner = self.manager;
        const request_id = owner.allocateId();
        const pending = try owner.beginRequest(request_id);
        defer owner.finish(request_id, pending);
        try owner.sendRequest(&.{ .evaluate_request = .{
            .request_id = request_id,
            .evaluator_id = self.id,
            .module_uri = module_uri,
            .module_text = module_text,
            .expression = expression,
        } });
        var response = try owner.wait(pending, request_options);
        defer response.deinit();
        switch (response.message) {
            .evaluate_response => |body| {
                if (body.evaluator_id != self.id) return error.Protocol;
                if (body.error_message) |text| {
                    failure.* = try owner.allocator.dupe(u8, text);
                    return error.EvaluationFailed;
                }
                const bytes = body.result orelse return error.Protocol;
                return value.decodeSlice(owner.allocator, bytes, .{});
            },
            else => return error.Protocol,
        }
    }

    pub fn evaluateSource(
        self: *Evaluator,
        evaluation_source: Source,
        expression: ?[]const u8,
        failure: *?[]u8,
    ) !value.Tree {
        return self.evaluate(
            evaluation_source.module_uri,
            evaluation_source.module_text,
            expression,
            failure,
        );
    }

    /// Stops new reader and logger callbacks, waits for queued and running callbacks of
    /// this evaluator to return, then asks the server to close it. After
    /// `close` returns, the readers, logger, and options it borrowed may be
    /// freed. Must not be called from one of this evaluator's own callbacks.
    pub fn close(self: *Evaluator) void {
        if (self.closed.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;
        const owner = self.manager;
        owner.mutex.lockUncancelable(owner.io);
        _ = owner.evaluators.fetchRemove(self.id);
        while (self.callbacks != 0) owner.cond.waitUncancelable(owner.io, &owner.mutex);
        owner.mutex.unlock(owner.io);
        owner.transport.send(&.{ .close_evaluator = .{ .evaluator_id = self.id } }) catch {};
    }
};

const Job = struct {
    incoming: message.Owned,
    evaluator: *Evaluator,
};

/// Owns the backend, response thread, reader workers, and evaluator handles.
/// `deinit` cancels pending requests and waits for active calls and callbacks.
/// Call it exactly once after application threads stop starting new requests,
/// and never from a logger or reader callback.
pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    transport: backend.Backend,
    subprocess: ?*subprocess.Subprocess,
    log: logger.Logger,
    mutex: std.Io.Mutex,
    cond: std.Io.Condition,
    next_id: i64,
    pending: std.AutoHashMapUnmanaged(i64, *Pending),
    evaluators: std.AutoHashMapUnmanaged(i64, *Evaluator),
    owned_evaluators: std.ArrayList(*Evaluator),
    abandoned_creates: std.AutoHashMapUnmanaged(i64, void),
    creates_in_flight: u32,
    terminal: ?anyerror,
    thread: ?std.Thread,
    stop: std.atomic.Value(bool),
    pkl_version: ?Version,
    workers: []std.Thread,
    jobs: []Job,
    job_head: usize,
    job_len: usize,
    work_cond: std.Io.Condition,
    workers_stop: bool,

    /// Launches `argv` (for example `pkl server`) and probes its version.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, log: logger.Logger) !*Manager {
        return initWithOptions(allocator, io, argv, .{ .log = log });
    }

    pub fn initWithOptions(
        allocator: std.mem.Allocator,
        io: std.Io,
        argv: []const []const u8,
        init_options: InitOptions,
    ) !*Manager {
        if (argv.len == 0) return error.InvalidArguments;
        const detected_version: ?Version = switch (init_options.version) {
            .probe => try version.probeServer(allocator, io, argv),
            .known => |known| known,
            .unchecked => null,
        };
        const child = try subprocess.Subprocess.spawnWithOptions(allocator, io, argv, init_options.subprocess);
        errdefer child.deinit();
        const self = try initWithBackendOptions(allocator, io, child.backend(), init_options);
        self.subprocess = child;
        self.pkl_version = detected_version;
        return self;
    }

    pub fn initWithBackend(allocator: std.mem.Allocator, io: std.Io, transport: backend.Backend, log: logger.Logger) !*Manager {
        return initWithBackendOptions(allocator, io, transport, .{ .log = log });
    }

    pub fn initWithBackendOptions(
        allocator: std.mem.Allocator,
        io: std.Io,
        transport: backend.Backend,
        init_options: InitOptions,
    ) !*Manager {
        if (init_options.reader_workers == 0 or init_options.reader_queue_capacity == 0) return error.InvalidArguments;
        const self = try allocator.create(Manager);
        errdefer allocator.destroy(self);
        const jobs = try allocator.alloc(Job, init_options.reader_queue_capacity);
        errdefer allocator.free(jobs);
        const workers = try allocator.alloc(std.Thread, init_options.reader_workers);
        errdefer allocator.free(workers);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .transport = transport,
            .subprocess = null,
            .log = init_options.log,
            .mutex = .init,
            .cond = .init,
            .next_id = 1,
            .pending = .empty,
            .evaluators = .empty,
            .owned_evaluators = .empty,
            .abandoned_creates = .empty,
            .creates_in_flight = 0,
            .terminal = null,
            .thread = null,
            .stop = std.atomic.Value(bool).init(false),
            .pkl_version = null,
            .workers = workers,
            .jobs = jobs,
            .job_head = 0,
            .job_len = 0,
            .work_cond = .init,
            .workers_stop = false,
        };
        var started: usize = 0;
        errdefer self.stopWorkers(started);
        while (started < workers.len) : (started += 1) {
            workers[started] = try std.Thread.spawn(.{}, workerMain, .{self});
        }
        self.thread = try std.Thread.spawn(.{}, readerMain, .{self});
        return self;
    }

    pub fn deinit(self: *Manager) void {
        self.stop.store(true, .release);
        self.transport.close();
        if (self.thread) |thread| thread.join();
        self.markTerminal(error.Closed);
        self.mutex.lockUncancelable(self.io);
        while (self.pending.count() != 0) self.cond.waitUncancelable(self.io, &self.mutex);
        self.mutex.unlock(self.io);
        self.stopWorkers(self.workers.len);
        self.evaluators.deinit(self.allocator);
        for (self.owned_evaluators.items) |evaluator| self.allocator.destroy(evaluator);
        self.owned_evaluators.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.abandoned_creates.deinit(self.allocator);
        self.allocator.free(self.jobs);
        self.allocator.free(self.workers);
        if (self.subprocess) |child| child.deinit();
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    /// Copies the retained tail of the server's stderr, or null when the
    /// manager does not own a subprocess.
    pub fn serverStderr(self: *Manager, allocator: std.mem.Allocator) error{OutOfMemory}!?[]u8 {
        const child = self.subprocess orelse return null;
        return try child.stderrTail(allocator);
    }

    /// The terminal transport or protocol error, if the connection has failed.
    pub fn failure(self: *Manager) ?anyerror {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.terminal;
    }

    /// On `error.Rejected`, `rejected` owns a message allocated with the manager allocator.
    pub fn createEvaluator(self: *Manager, evaluator_options: Options, rejected: *?[]u8) !*Evaluator {
        return self.createEvaluatorWithOptions(evaluator_options, rejected, .{});
    }

    /// Creates an evaluator with a cancelable client-side request deadline.
    /// When the deadline passes first, a late success response closes the
    /// evaluator that the server created.
    pub fn createEvaluatorWithOptions(
        self: *Manager,
        evaluator_options: Options,
        rejected: *?[]u8,
        request_options: RequestOptions,
    ) !*Evaluator {
        if (self.pkl_version) |pkl_version| try evaluator_options.validate(pkl_version);
        const request_id = self.allocateId();
        const request = try options.toRequest(self.allocator, evaluator_options, request_id);
        defer if (request.client_module_readers) |specs| self.allocator.free(specs);
        defer if (request.client_resource_readers) |specs| self.allocator.free(specs);
        try self.reserveAbandonedSlot();
        defer self.releaseAbandonedSlot();
        const pending = try self.beginRequest(request_id);
        var abandoned = false;
        defer if (!abandoned) self.finish(request_id, pending);
        try self.sendRequest(&.{ .create_evaluator_request = request });
        var response = self.wait(pending, request_options) catch |err| {
            if (err == error.Timeout or err == error.Canceled) {
                abandoned = true;
                self.abandonCreate(request_id, pending);
            }
            return err;
        };
        defer response.deinit();
        switch (response.message) {
            .create_evaluator_response => |body| {
                if (body.error_message) |text| {
                    rejected.* = try self.allocator.dupe(u8, text);
                    return error.Rejected;
                }
                const evaluator_id = body.evaluator_id orelse return error.Protocol;
                errdefer self.transport.send(&.{ .close_evaluator = .{ .evaluator_id = evaluator_id } }) catch {};
                const evaluator = try self.allocator.create(Evaluator);
                errdefer self.allocator.destroy(evaluator);
                evaluator.* = .{
                    .id = evaluator_id,
                    .manager = self,
                    .module_readers = evaluator_options.module_readers,
                    .resource_readers = evaluator_options.resource_readers,
                    .log = evaluator_options.logger orelse self.log,
                    .closed = std.atomic.Value(bool).init(false),
                    .callbacks = 0,
                };
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                try self.owned_evaluators.ensureUnusedCapacity(self.allocator, 1);
                try self.evaluators.put(self.allocator, evaluator_id, evaluator);
                self.owned_evaluators.appendAssumeCapacity(evaluator);
                return evaluator;
            },
            else => return error.Protocol,
        }
    }

    fn allocateId(self: *Manager) i64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    fn beginRequest(self: *Manager, id: i64) !*Pending {
        const pending = try self.allocator.create(Pending);
        errdefer self.allocator.destroy(pending);
        pending.* = .{};
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.terminal) |err| return err;
        if (self.stop.load(.acquire)) return error.Closed;
        try self.pending.put(self.allocator, id, pending);
        return pending;
    }

    fn sendRequest(self: *Manager, payload: *const message.Message) !void {
        self.transport.send(payload) catch |err| {
            switch (err) {
                error.OutOfMemory, error.MissingField, error.LimitExceeded => {},
                else => self.markTerminal(err),
            }
            return err;
        };
    }

    fn finish(self: *Manager, id: i64, pending: *Pending) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        _ = self.pending.fetchRemove(id);
        if (pending.message) |*owned| owned.deinit();
        self.allocator.destroy(pending);
        self.cond.broadcast(self.io);
    }

    fn reserveAbandonedSlot(self: *Manager) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.abandoned_creates.ensureUnusedCapacity(self.allocator, self.creates_in_flight + 1);
        self.creates_in_flight += 1;
    }

    fn releaseAbandonedSlot(self: *Manager) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.creates_in_flight -= 1;
    }

    fn abandonCreate(self: *Manager, id: i64, pending: *Pending) void {
        var late_evaluator: ?i64 = null;
        self.mutex.lockUncancelable(self.io);
        _ = self.pending.fetchRemove(id);
        if (pending.message) |*owned| {
            switch (owned.message) {
                .create_evaluator_response => |body| late_evaluator = body.evaluator_id,
                else => {},
            }
            owned.deinit();
        } else if (self.terminal == null) {
            self.abandoned_creates.putAssumeCapacity(id, {});
        }
        self.allocator.destroy(pending);
        self.cond.broadcast(self.io);
        self.mutex.unlock(self.io);
        if (late_evaluator) |evaluator_id| {
            self.transport.send(&.{ .close_evaluator = .{ .evaluator_id = evaluator_id } }) catch {};
        }
    }

    fn wait(self: *Manager, pending: *Pending, request_options: RequestOptions) !message.Owned {
        const deadline = request_options.timeout.toDeadline(self.io);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (!pending.done and !self.stop.load(.acquire)) {
            if (request_options.cancellation) |cancellation| {
                if (cancellation.isCanceled()) return error.Canceled;
                pending.cond.waitTimeout(
                    self.io,
                    &self.mutex,
                    .{ .duration = durationMilliseconds(10) },
                ) catch |err| switch (err) {
                    error.Timeout => {},
                    error.Canceled => return error.Canceled,
                };
                switch (deadline) {
                    .deadline => |end| if (end.untilNow(self.io).raw.nanoseconds >= 0) return error.Timeout,
                    .none => {},
                    .duration => unreachable,
                }
            } else {
                pending.cond.waitTimeout(self.io, &self.mutex, deadline) catch |err| switch (err) {
                    error.Timeout => return error.Timeout,
                    error.Canceled => return error.Canceled,
                };
            }
        }
        if (pending.err) |err| return err;
        const owned = pending.message orelse return error.Closed;
        pending.message = null;
        return owned;
    }

    /// Records the first terminal error and fails every pending request with it.
    fn markTerminal(self: *Manager, err: anyerror) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.terminal == null) self.terminal = err;
        const terminal = self.terminal.?;
        var pending = self.pending.iterator();
        while (pending.next()) |entry| {
            entry.value_ptr.*.done = true;
            if (entry.value_ptr.*.err == null) entry.value_ptr.*.err = terminal;
            entry.value_ptr.*.cond.broadcast(self.io);
        }
        self.abandoned_creates.clearRetainingCapacity();
        self.cond.broadcast(self.io);
    }

    fn stopWorkers(self: *Manager, started: usize) void {
        self.mutex.lockUncancelable(self.io);
        self.workers_stop = true;
        self.work_cond.broadcast(self.io);
        self.mutex.unlock(self.io);
        for (self.workers[0..started]) |worker| worker.join();
    }
};

const Pending = struct {
    cond: std.Io.Condition = .init,
    done: bool = false,
    message: ?message.Owned = null,
    err: ?anyerror = null,
};

fn durationMilliseconds(milliseconds: i64) std.Io.Clock.Duration {
    return .{ .raw = std.Io.Duration.fromMilliseconds(milliseconds), .clock = .awake };
}

fn readerMain(self: *Manager) void {
    while (!self.stop.load(.acquire)) {
        const incoming = self.transport.receive(self.allocator) catch |err| switch (err) {
            error.UnknownCode => continue,
            else => {
                self.markTerminal(if (self.stop.load(.acquire)) error.Closed else err);
                return;
            },
        };
        dispatch(self, incoming);
    }
}

fn dispatch(self: *Manager, incoming: message.Owned) void {
    switch (incoming.message) {
        .create_evaluator_response, .evaluate_response => {
            const request_id = incoming.message.requestId().?;
            complete(self, request_id, incoming);
        },
        .log => |body| {
            self.mutex.lockUncancelable(self.io);
            const evaluator = self.evaluators.get(body.evaluator_id);
            if (evaluator) |item| item.callbacks += 1;
            const log = if (evaluator) |item| item.log else self.log;
            self.mutex.unlock(self.io);
            log.emit(.{
                .evaluator_id = body.evaluator_id,
                .level = body.level,
                .message = body.message,
                .frame_uri = body.frame_uri,
            });
            if (evaluator) |item| {
                self.mutex.lockUncancelable(self.io);
                item.callbacks -= 1;
                self.cond.broadcast(self.io);
                self.mutex.unlock(self.io);
            }
            var copy = incoming;
            copy.deinit();
        },
        .read_module_request, .read_resource_request, .list_modules_request, .list_resources_request => {
            enqueue(self, incoming);
        },
        else => {
            var copy = incoming;
            copy.deinit();
        },
    }
}

fn enqueue(self: *Manager, incoming: message.Owned) void {
    const evaluator_id = incoming.message.evaluatorId().?;
    self.mutex.lockUncancelable(self.io);
    const evaluator = self.evaluators.get(evaluator_id);
    const refusal: ?[]const u8 = if (evaluator == null)
        "unknown evaluator"
    else if (self.workers_stop)
        "manager is closing"
    else if (self.job_len == self.jobs.len)
        "reader queue is full"
    else
        null;
    if (refusal == null) {
        evaluator.?.callbacks += 1;
        self.jobs[(self.job_head + self.job_len) % self.jobs.len] = .{ .incoming = incoming, .evaluator = evaluator.? };
        self.job_len += 1;
        self.work_cond.signal(self.io);
    }
    self.mutex.unlock(self.io);
    if (refusal) |text| {
        replyText(self, incoming, text);
        var copy = incoming;
        copy.deinit();
    }
}

fn workerMain(self: *Manager) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    while (true) {
        while (self.job_len == 0 and !self.workers_stop) self.work_cond.waitUncancelable(self.io, &self.mutex);
        if (self.job_len == 0) return;
        const job = self.jobs[self.job_head];
        self.job_head = (self.job_head + 1) % self.jobs.len;
        self.job_len -= 1;
        const skip = self.workers_stop;
        self.mutex.unlock(self.io);
        if (skip) {
            var copy = job.incoming;
            copy.deinit();
        } else {
            handleServer(self, job.evaluator, job.incoming);
        }
        self.mutex.lockUncancelable(self.io);
        job.evaluator.callbacks -= 1;
        self.cond.broadcast(self.io);
    }
}

fn complete(self: *Manager, request_id: i64, incoming: message.Owned) void {
    var late_evaluator: ?i64 = null;
    self.mutex.lockUncancelable(self.io);
    if (self.pending.get(request_id)) |pending| {
        pending.message = incoming;
        pending.done = true;
        pending.cond.signal(self.io);
    } else {
        switch (incoming.message) {
            .create_evaluator_response => |body| {
                if (self.abandoned_creates.remove(request_id)) late_evaluator = body.evaluator_id;
            },
            else => {},
        }
        var copy = incoming;
        copy.deinit();
    }
    self.mutex.unlock(self.io);
    if (late_evaluator) |evaluator_id| {
        self.transport.send(&.{ .close_evaluator = .{ .evaluator_id = evaluator_id } }) catch {};
    }
}

fn handleServer(self: *Manager, evaluator: *Evaluator, incoming: message.Owned) void {
    defer {
        var copy = incoming;
        copy.deinit();
    }
    switch (incoming.message) {
        .read_module_request => |body| replyModule(self, evaluator, body),
        .read_resource_request => |body| replyResource(self, evaluator, body),
        .list_modules_request => |body| replyList(self, evaluator, body, true),
        .list_resources_request => |body| replyList(self, evaluator, body, false),
        else => {},
    }
}

fn replyModule(self: *Manager, evaluator: *Evaluator, body: message.ReadModuleRequest) void {
    const scheme = reader.schemeOf(body.uri) orelse {
        sendModule(self, body, null, "missing scheme");
        return;
    };
    for (evaluator.module_readers) |item| {
        if (!std.mem.eql(u8, item.scheme(), scheme)) continue;
        const contents = item.read(self.allocator, body.uri) catch |err| {
            sendModule(self, body, null, @errorName(err));
            return;
        };
        defer self.allocator.free(contents);
        sendModule(self, body, contents, null);
        return;
    }
    sendModule(self, body, null, "no module reader");
}

fn replyResource(self: *Manager, evaluator: *Evaluator, body: message.ReadResourceRequest) void {
    const scheme = reader.schemeOf(body.uri) orelse {
        sendResource(self, body, null, "missing scheme");
        return;
    };
    for (evaluator.resource_readers) |item| {
        if (!std.mem.eql(u8, item.scheme(), scheme)) continue;
        const contents = item.read(self.allocator, body.uri) catch |err| {
            sendResource(self, body, null, @errorName(err));
            return;
        };
        defer self.allocator.free(contents);
        sendResource(self, body, contents, null);
        return;
    }
    sendResource(self, body, null, "no resource reader");
}

fn replyList(self: *Manager, evaluator: *Evaluator, body: message.ListRequest, modules: bool) void {
    const scheme = reader.schemeOf(body.uri) orelse {
        sendList(self, modules, body, null, "missing scheme");
        return;
    };
    if (modules) {
        for (evaluator.module_readers) |item| {
            if (!std.mem.eql(u8, item.scheme(), scheme)) continue;
            const elements = item.list(self.allocator, body.uri) catch |err| {
                sendList(self, true, body, null, @errorName(err));
                return;
            };
            defer freeElements(self.allocator, elements);
            sendList(self, true, body, elements, null);
            return;
        }
    } else {
        for (evaluator.resource_readers) |item| {
            if (!std.mem.eql(u8, item.scheme(), scheme)) continue;
            const elements = item.list(self.allocator, body.uri) catch |err| {
                sendList(self, false, body, null, @errorName(err));
                return;
            };
            defer freeElements(self.allocator, elements);
            sendList(self, false, body, elements, null);
            return;
        }
    }
    sendList(self, modules, body, null, "no reader");
}

fn replyText(self: *Manager, incoming: message.Owned, text: []const u8) void {
    switch (incoming.message) {
        .read_module_request => |body| sendModule(self, body, null, text),
        .read_resource_request => |body| sendResource(self, body, null, text),
        .list_modules_request => |body| sendList(self, true, body, null, text),
        .list_resources_request => |body| sendList(self, false, body, null, text),
        else => {},
    }
}

fn sendModule(self: *Manager, body: message.ReadModuleRequest, contents: ?[]const u8, error_message: ?[]const u8) void {
    self.transport.send(&.{ .read_module_response = .{
        .request_id = body.request_id,
        .evaluator_id = body.evaluator_id,
        .contents = contents,
        .error_message = error_message,
    } }) catch {};
}

fn sendResource(self: *Manager, body: message.ReadResourceRequest, contents: ?[]const u8, error_message: ?[]const u8) void {
    self.transport.send(&.{ .read_resource_response = .{
        .request_id = body.request_id,
        .evaluator_id = body.evaluator_id,
        .contents = contents,
        .error_message = error_message,
    } }) catch {};
}

fn sendList(
    self: *Manager,
    modules: bool,
    body: message.ListRequest,
    elements: ?[]const message.PathElement,
    error_message: ?[]const u8,
) void {
    const response = message.ListResponse{
        .request_id = body.request_id,
        .evaluator_id = body.evaluator_id,
        .path_elements = elements,
        .error_message = error_message,
    };
    self.transport.send(if (modules)
        &.{ .list_modules_response = response }
    else
        &.{ .list_resources_response = response }) catch {};
}

fn freeElements(allocator: std.mem.Allocator, elements: []message.PathElement) void {
    for (elements) |element| allocator.free(@constCast(element.name));
    allocator.free(elements);
}

const Script = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    incoming: std.ArrayList([]u8) = .empty,
    outgoing: std.ArrayList([]u8) = .empty,
    closed: bool = false,
    failed: ?anyerror = null,

    fn transport(self: *Script) backend.Backend {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = send,
                .receive = receive,
                .close = closeScript,
            },
        };
    }

    fn deinit(self: *Script) void {
        for (self.incoming.items) |item| self.allocator.free(item);
        for (self.outgoing.items) |item| self.allocator.free(item);
        self.incoming.deinit(self.allocator);
        self.outgoing.deinit(self.allocator);
    }

    fn push(self: *Script, payload: message.Message) !void {
        try self.pushRaw(try message.encodeAlloc(self.allocator, payload));
    }

    fn pushRaw(self: *Script, bytes: []u8) !void {
        errdefer self.allocator.free(bytes);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.incoming.append(self.allocator, bytes);
        self.cond.broadcast(self.io);
    }

    fn takeOutgoing(self: *Script) ![]u8 {
        const deadline = (std.Io.Timeout{ .duration = durationMilliseconds(5000) }).toDeadline(self.io);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.outgoing.items.len == 0 and !self.closed) {
            self.cond.waitTimeout(self.io, &self.mutex, deadline) catch |err| switch (err) {
                error.Timeout, error.Canceled => return error.Timeout,
            };
        }
        if (self.outgoing.items.len == 0) return error.Closed;
        return self.outgoing.orderedRemove(0);
    }

    fn takeMessage(self: *Script) !message.Owned {
        const bytes = try self.takeOutgoing();
        defer self.allocator.free(bytes);
        return message.decodeSlice(self.allocator, bytes);
    }
};

fn send(ptr: *anyopaque, payload: *const message.Message) anyerror!void {
    const self: *Script = @ptrCast(@alignCast(ptr));
    const bytes = try message.encodeAlloc(self.allocator, payload.*);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (self.closed) {
        self.allocator.free(bytes);
        return error.Closed;
    }
    try self.outgoing.append(self.allocator, bytes);
    self.cond.broadcast(self.io);
}

fn receive(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!message.Owned {
    const self: *Script = @ptrCast(@alignCast(ptr));
    self.mutex.lockUncancelable(self.io);
    while (self.incoming.items.len == 0 and !self.closed) self.cond.waitUncancelable(self.io, &self.mutex);
    if (self.incoming.items.len == 0) {
        self.mutex.unlock(self.io);
        return error.Closed;
    }
    const bytes = self.incoming.orderedRemove(0);
    self.mutex.unlock(self.io);
    defer self.allocator.free(bytes);
    return message.decodeSlice(allocator, bytes);
}

fn closeScript(ptr: *anyopaque) void {
    const self: *Script = @ptrCast(@alignCast(ptr));
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.closed = true;
    self.cond.broadcast(self.io);
}

fn drive(script: *Script) void {
    driveInner(script) catch |err| {
        script.failed = err;
        closeScript(script);
    };
}

fn driveInner(script: *Script) !void {
    var create_message = try script.takeMessage();
    defer create_message.deinit();
    const create_id = create_message.message.requestId() orelse return error.Protocol;
    try script.push(.{ .create_evaluator_response = .{ .request_id = create_id, .evaluator_id = 7 } });

    var evaluate_message = try script.takeMessage();
    defer evaluate_message.deinit();
    const evaluate_id = evaluate_message.message.requestId() orelse return error.Protocol;
    try std.testing.expectEqualStrings(
        "custom:/entry.pkl",
        evaluate_message.message.evaluate_request.module_uri,
    );
    try script.push(.{ .read_module_request = .{
        .request_id = -5,
        .evaluator_id = 7,
        .uri = "mem:/root.pkl",
    } });
    var read_message = try script.takeMessage();
    defer read_message.deinit();
    try std.testing.expectEqualStrings("name = 1\n", read_message.message.read_module_response.contents.?);

    try script.push(.{ .log = .{
        .evaluator_id = 7,
        .level = 1,
        .message = "warned",
        .frame_uri = "mem:/root.pkl",
    } });
    var number = value.Value{ .int = value.Integer.fromSigned(1) };
    const encoded = try value.encodeAlloc(script.allocator, &number);
    defer script.allocator.free(encoded);
    try script.push(.{ .evaluate_response = .{
        .request_id = evaluate_id,
        .evaluator_id = 7,
        .result = encoded,
    } });
}

test "manager multiplexes evaluators, readers, and logs" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var script = Script{ .allocator = allocator, .io = io };
    defer script.deinit();
    const manager = try Manager.initWithBackend(allocator, io, script.transport(), logger.Logger.noop);
    defer manager.deinit();
    const thread = try std.Thread.spawn(.{}, drive, .{&script});
    defer thread.join();

    var embed = reader.Embed{
        .scheme_name = "mem",
        .entries = &.{.{ .path = "/root.pkl", .contents = "name = 1\n" }},
    };
    var capture = logger.Capture{};
    var readers = [_]reader.ModuleReader{embed.moduleReader()};
    var rejected: ?[]u8 = null;
    const evaluator = try manager.createEvaluator(.{
        .allowed_modules = &.{"mem:"},
        .output_format = "pkl-binary",
        .module_readers = &readers,
        .logger = capture.logger(),
    }, &rejected);
    var failure: ?[]u8 = null;
    defer if (failure) |text| allocator.free(text);
    var tree = try evaluator.evaluate("custom:/entry.pkl", "name = 1", "name", &failure);
    defer tree.deinit();
    try std.testing.expect(tree.root.int.eql(value.Integer.fromSigned(1)));
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqual(@as(i64, 1), capture.last_level);
    evaluator.close();
    manager.mutex.lockUncancelable(io);
    const removed = !manager.evaluators.contains(evaluator.id);
    manager.mutex.unlock(io);
    try std.testing.expect(removed);
    var closed_failure: ?[]u8 = null;
    try std.testing.expectError(
        error.Closed,
        evaluator.evaluate("custom:/still-valid-handle", null, null, &closed_failure),
    );
    evaluator.close();
    try std.testing.expect(script.failed == null);
}

const WaitTest = struct {
    manager: *Manager,
    pending: *Pending,
    started: *std.atomic.Value(u32),
    result: ?i64 = null,
    err: ?anyerror = null,

    fn run(self: *WaitTest) void {
        _ = self.started.fetchAdd(1, .release);
        var owned = self.manager.wait(self.pending, .{}) catch |err| {
            self.err = err;
            return;
        };
        defer owned.deinit();
        self.result = owned.message.create_evaluator_response.evaluator_id;
    }
};

test "responses wake only their matching pending request" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var script = Script{ .allocator = allocator, .io = io };
    defer script.deinit();
    const manager = try Manager.initWithBackend(allocator, io, script.transport(), logger.Logger.noop);
    defer manager.deinit();

    const first = try manager.beginRequest(101);
    defer manager.finish(101, first);
    const second = try manager.beginRequest(202);
    defer manager.finish(202, second);

    var started = std.atomic.Value(u32).init(0);
    var first_wait = WaitTest{ .manager = manager, .pending = first, .started = &started };
    var second_wait = WaitTest{ .manager = manager, .pending = second, .started = &started };
    const first_thread = try std.Thread.spawn(.{}, WaitTest.run, .{&first_wait});
    const second_thread = try std.Thread.spawn(.{}, WaitTest.run, .{&second_wait});
    while (started.load(.acquire) != 2) std.Thread.yield() catch {};
    try std.Io.Timeout.sleep(.{ .duration = durationMilliseconds(10) }, io);

    try script.push(.{ .create_evaluator_response = .{ .request_id = 202, .evaluator_id = 22 } });
    try script.push(.{ .create_evaluator_response = .{ .request_id = 101, .evaluator_id = 11 } });
    first_thread.join();
    second_thread.join();
    try std.testing.expect(first_wait.err == null);
    try std.testing.expect(second_wait.err == null);
    try std.testing.expectEqual(@as(?i64, 11), first_wait.result);
    try std.testing.expectEqual(@as(?i64, 22), second_wait.result);
}

test "pending requests support timeout and cancellation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var script = Script{ .allocator = allocator, .io = io };
    defer script.deinit();
    const manager = try Manager.initWithBackend(allocator, io, script.transport(), logger.Logger.noop);
    defer manager.deinit();
    var pending = Pending{};
    try std.testing.expectError(error.Timeout, manager.wait(&pending, .{
        .timeout = .{ .duration = durationMilliseconds(5) },
    }));
    var cancellation = Cancellation{};
    cancellation.cancel();
    try std.testing.expectError(error.Canceled, manager.wait(&pending, .{ .cancellation = &cancellation }));
}

test "pending registration releases its allocation when the map cannot grow" {
    const io = std.testing.io;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var script = Script{ .allocator = std.testing.allocator, .io = io };
    defer script.deinit();
    const manager = try Manager.initWithBackend(failing.allocator(), io, script.transport(), logger.Logger.noop);
    defer manager.deinit();
    failing.fail_index = failing.alloc_index + 1;
    try std.testing.expectError(error.OutOfMemory, manager.beginRequest(1));
    failing.fail_index = std.math.maxInt(usize);
}

test "unknown frames are skipped and malformed frames fail the connection" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var script = Script{ .allocator = allocator, .io = io };
    defer script.deinit();
    const manager = try Manager.initWithBackend(allocator, io, script.transport(), logger.Logger.noop);
    defer manager.deinit();

    var unknown: std.Io.Writer.Allocating = .init(allocator);
    errdefer unknown.deinit();
    try msgpack.writeArrayHeader(&unknown.writer, 2);
    try msgpack.writeInt(&unknown.writer, 0x7f);
    try msgpack.writeMapHeader(&unknown.writer, 1);
    try msgpack.writeString(&unknown.writer, "future");
    try msgpack.writeBool(&unknown.writer, true);
    try script.pushRaw(try unknown.toOwnedSlice());

    const first = try manager.beginRequest(5);
    defer manager.finish(5, first);
    try script.push(.{ .create_evaluator_response = .{ .request_id = 5, .evaluator_id = 50 } });
    var answered = try manager.wait(first, .{ .timeout = .{ .duration = durationMilliseconds(2000) } });
    answered.deinit();
    try std.testing.expect(manager.failure() == null);

    const second = try manager.beginRequest(6);
    defer manager.finish(6, second);
    const malformed = try allocator.dupe(u8, &.{ 0x92, 0x21, 0xc0 });
    try script.pushRaw(malformed);
    try std.testing.expectError(error.InvalidMessage, manager.wait(second, .{
        .timeout = .{ .duration = durationMilliseconds(2000) },
    }));
    try std.testing.expectEqual(@as(?anyerror, error.InvalidMessage), manager.failure());
    var rejected: ?[]u8 = null;
    try std.testing.expectError(error.InvalidMessage, manager.createEvaluator(.{}, &rejected));
}

test "server exit fails later requests immediately with the terminal error" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const child = subprocess.Subprocess.spawn(allocator, io, &.{ "/bin/sh", "-c", "exit 0" }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    const manager = Manager.initWithBackend(allocator, io, child.backend(), logger.Logger.noop) catch |err| {
        child.deinit();
        return err;
    };
    manager.subprocess = child;
    defer manager.deinit();
    while (manager.failure() == null) try std.Io.Timeout.sleep(.{ .duration = durationMilliseconds(5) }, io);
    try std.testing.expectEqual(@as(?anyerror, error.Closed), manager.failure());
    var rejected: ?[]u8 = null;
    const started = std.Io.Clock.awake.now(io);
    try std.testing.expectError(error.Closed, manager.createEvaluatorWithOptions(.{}, &rejected, .{
        .timeout = .{ .duration = durationMilliseconds(5000) },
    }));
    try std.testing.expect(started.untilNow(io, .awake).toMilliseconds() < 1000);
}

fn driveLateCreate(script: *Script) void {
    driveLateCreateInner(script) catch |err| {
        script.failed = err;
        closeScript(script);
    };
}

fn driveLateCreateInner(script: *Script) !void {
    var create = try script.takeMessage();
    defer create.deinit();
    try std.Io.Timeout.sleep(.{ .duration = durationMilliseconds(100) }, script.io);
    try script.push(.{ .create_evaluator_response = .{
        .request_id = create.message.requestId().?,
        .evaluator_id = 77,
    } });
    var close = try script.takeMessage();
    defer close.deinit();
    try std.testing.expectEqual(@as(i64, 77), close.message.close_evaluator.evaluator_id);
}

test "a create response that arrives after its timeout closes the server evaluator" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var script = Script{ .allocator = allocator, .io = io };
    defer script.deinit();
    const manager = try Manager.initWithBackend(allocator, io, script.transport(), logger.Logger.noop);
    defer manager.deinit();
    const driver = try std.Thread.spawn(.{}, driveLateCreate, .{&script});
    var rejected: ?[]u8 = null;
    try std.testing.expectError(error.Timeout, manager.createEvaluatorWithOptions(.{}, &rejected, .{
        .timeout = .{ .duration = durationMilliseconds(10) },
    }));
    driver.join();
    try std.testing.expect(script.failed == null);
}

const BlockingReader = struct {
    released: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    entered: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn moduleReader(self: *BlockingReader) reader.ModuleReader {
        return .{ .ptr = self, .vtable = &.{
            .scheme = scheme,
            .has_hierarchical_uris = yes,
            .is_globbable = yes,
            .is_local = yes,
            .read = read,
            .list = list,
        } };
    }

    fn scheme(_: *anyopaque) []const u8 {
        return "slow";
    }

    fn yes(_: *anyopaque) bool {
        return true;
    }

    fn read(ptr: *anyopaque, allocator: std.mem.Allocator, _: []const u8) anyerror![]u8 {
        const self: *BlockingReader = @ptrCast(@alignCast(ptr));
        _ = self.entered.fetchAdd(1, .acq_rel);
        while (!self.released.load(.acquire)) std.Thread.yield() catch {};
        self.finished.store(true, .release);
        return allocator.dupe(u8, "ready = true");
    }

    fn list(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8) anyerror![]message.PathElement {
        return allocator.alloc(message.PathElement, 0);
    }
};

fn driveSlowReader(script: *Script) void {
    driveSlowReaderInner(script) catch |err| {
        script.failed = err;
        closeScript(script);
    };
}

fn driveSlowReaderInner(script: *Script) !void {
    const allocator = script.allocator;
    var create = try script.takeMessage();
    defer create.deinit();
    try script.push(.{ .create_evaluator_response = .{
        .request_id = create.message.requestId().?,
        .evaluator_id = 9,
    } });

    var evaluate = try script.takeMessage();
    defer evaluate.deinit();
    try script.push(.{ .read_module_request = .{
        .request_id = -1,
        .evaluator_id = 9,
        .uri = "slow:/module.pkl",
    } });
    var result_value = value.Value{ .boolean = true };
    const result = try value.encodeAlloc(allocator, &result_value);
    defer allocator.free(result);
    try script.push(.{ .evaluate_response = .{
        .request_id = evaluate.message.requestId().?,
        .evaluator_id = 9,
        .result = result,
    } });
    while (true) {
        var read_response = try script.takeMessage();
        switch (read_response.message) {
            .read_module_response => |response| {
                const correct = std.mem.eql(u8, "ready = true", response.contents.?);
                read_response.deinit();
                try std.testing.expect(correct);
                return;
            },
            .close_evaluator => read_response.deinit(),
            else => {
                read_response.deinit();
                return error.Protocol;
            },
        }
    }
}

test "slow reader callbacks do not block evaluation responses" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var script = Script{ .allocator = allocator, .io = io };
    defer script.deinit();
    const manager = try Manager.initWithBackend(allocator, io, script.transport(), logger.Logger.noop);
    defer manager.deinit();
    const driver = try std.Thread.spawn(.{}, driveSlowReader, .{&script});
    var blocking = BlockingReader{};
    var readers = [_]reader.ModuleReader{blocking.moduleReader()};
    var rejected: ?[]u8 = null;
    const evaluator = try manager.createEvaluator(.{
        .module_readers = &readers,
        .allowed_modules = &.{"slow:"},
    }, &rejected);
    defer {
        blocking.released.store(true, .release);
        driver.join();
        evaluator.close();
    }
    var failure: ?[]u8 = null;
    defer if (failure) |text| allocator.free(text);
    var result = evaluator.evaluateWithOptions(
        "repl:text",
        "import \"slow:/module.pkl\"",
        "true",
        &failure,
        .{ .timeout = .{ .duration = durationMilliseconds(500) } },
    ) catch |err| {
        blocking.released.store(true, .release);
        return err;
    };
    defer result.deinit();
    blocking.released.store(true, .release);
    try std.testing.expect(result.root.boolean);
}

fn awaitChange(io: std.Io, comptime T: type, flag: *const std.atomic.Value(T), initial: T) !void {
    const deadline = std.Io.Clock.awake.now(io).addDuration(.fromSeconds(5));
    while (flag.load(.acquire) == initial) {
        if (deadline.untilNow(io, .awake).nanoseconds >= 0) return error.Timeout;
        std.Thread.yield() catch {};
    }
}

const CloseProbe = struct {
    evaluator: *Evaluator,
    returned: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *CloseProbe) void {
        self.evaluator.close();
        self.returned.store(true, .release);
    }
};

test "evaluator close waits for its in-flight reader callbacks" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var script = Script{ .allocator = allocator, .io = io };
    defer script.deinit();
    const manager = try Manager.initWithBackend(allocator, io, script.transport(), logger.Logger.noop);
    defer manager.deinit();

    var blocking = BlockingReader{};
    var readers = [_]reader.ModuleReader{blocking.moduleReader()};
    const created = try std.Thread.spawn(.{}, struct {
        fn run(s: *Script) void {
            var create = s.takeMessage() catch return;
            defer create.deinit();
            s.push(.{ .create_evaluator_response = .{
                .request_id = create.message.requestId().?,
                .evaluator_id = 3,
            } }) catch {};
        }
    }.run, .{&script});
    var rejected: ?[]u8 = null;
    const evaluator = try manager.createEvaluator(.{ .module_readers = &readers }, &rejected);
    created.join();

    defer blocking.released.store(true, .release);
    try script.push(.{ .read_module_request = .{ .request_id = -9, .evaluator_id = 3, .uri = "slow:/a.pkl" } });
    try awaitChange(io, u32, &blocking.entered, 0);
    var probe = CloseProbe{ .evaluator = evaluator };
    const closer = try std.Thread.spawn(.{}, CloseProbe.run, .{&probe});
    var joined = false;
    defer if (!joined) {
        blocking.released.store(true, .release);
        closer.join();
    };
    try std.Io.Timeout.sleep(.{ .duration = durationMilliseconds(50) }, io);
    try std.testing.expect(!probe.returned.load(.acquire));
    blocking.released.store(true, .release);
    closer.join();
    joined = true;
    try std.testing.expect(blocking.finished.load(.acquire));
    try std.testing.expect(probe.returned.load(.acquire));

    var response = try script.takeMessage();
    defer response.deinit();
    try std.testing.expectEqualStrings("ready = true", response.message.read_module_response.contents.?);
    var close = try script.takeMessage();
    defer close.deinit();
    try std.testing.expectEqual(@as(i64, 3), close.message.close_evaluator.evaluator_id);
}

const SleepingLogger = struct {
    entered: std.atomic.Value(bool) = .init(false),
    released: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(bool) = .init(false),

    fn asLogger(self: *SleepingLogger) logger.Logger {
        return .{ .ptr = self, .vtable = &.{ .log = log } };
    }

    fn log(ptr: *anyopaque, _: logger.Event) void {
        const self: *SleepingLogger = @ptrCast(@alignCast(ptr));
        self.entered.store(true, .release);
        while (!self.released.load(.acquire)) std.Thread.yield() catch {};
        self.finished.store(true, .release);
    }
};

test "evaluator close waits for its in-flight logger callbacks" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var script = Script{ .allocator = allocator, .io = io };
    defer script.deinit();
    const manager = try Manager.initWithBackend(allocator, io, script.transport(), logger.Logger.noop);
    defer manager.deinit();

    var sleeping = SleepingLogger{};
    const created = try std.Thread.spawn(.{}, struct {
        fn run(s: *Script) void {
            var create = s.takeMessage() catch return;
            defer create.deinit();
            s.push(.{ .create_evaluator_response = .{
                .request_id = create.message.requestId().?,
                .evaluator_id = 4,
            } }) catch {};
        }
    }.run, .{&script});
    var rejected: ?[]u8 = null;
    const evaluator = try manager.createEvaluator(.{ .logger = sleeping.asLogger() }, &rejected);
    created.join();

    defer sleeping.released.store(true, .release);
    try script.push(.{ .log = .{ .evaluator_id = 4, .level = 1, .message = "slow", .frame_uri = "repl:text" } });
    try awaitChange(io, bool, &sleeping.entered, false);
    var probe = CloseProbe{ .evaluator = evaluator };
    const closer = try std.Thread.spawn(.{}, CloseProbe.run, .{&probe});
    var joined = false;
    defer if (!joined) {
        sleeping.released.store(true, .release);
        closer.join();
    };
    try std.Io.Timeout.sleep(.{ .duration = durationMilliseconds(50) }, io);
    try std.testing.expect(!probe.returned.load(.acquire));
    sleeping.released.store(true, .release);
    closer.join();
    joined = true;
    try std.testing.expect(sleeping.finished.load(.acquire));

    var close = try script.takeMessage();
    defer close.deinit();
    try std.testing.expectEqual(@as(i64, 4), close.message.close_evaluator.evaluator_id);
}

test "reader callbacks run on a bounded pool and overflow is refused" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var script = Script{ .allocator = allocator, .io = io };
    defer script.deinit();
    const manager = try Manager.initWithBackendOptions(allocator, io, script.transport(), .{
        .reader_workers = 1,
        .reader_queue_capacity = 1,
    });
    defer manager.deinit();
    var blocking = BlockingReader{};
    var readers = [_]reader.ModuleReader{blocking.moduleReader()};
    const created = try std.Thread.spawn(.{}, struct {
        fn run(s: *Script) void {
            var create = s.takeMessage() catch return;
            defer create.deinit();
            s.push(.{ .create_evaluator_response = .{
                .request_id = create.message.requestId().?,
                .evaluator_id = 4,
            } }) catch {};
        }
    }.run, .{&script});
    var rejected: ?[]u8 = null;
    const evaluator = try manager.createEvaluator(.{ .module_readers = &readers }, &rejected);
    created.join();
    defer evaluator.close();
    defer blocking.released.store(true, .release);

    try script.push(.{ .read_module_request = .{ .request_id = -1, .evaluator_id = 4, .uri = "slow:/1.pkl" } });
    try awaitChange(io, u32, &blocking.entered, 0);
    try script.push(.{ .read_module_request = .{ .request_id = -2, .evaluator_id = 4, .uri = "slow:/2.pkl" } });
    try script.push(.{ .read_module_request = .{ .request_id = -3, .evaluator_id = 4, .uri = "slow:/3.pkl" } });
    var refused = try script.takeMessage();
    defer refused.deinit();
    try std.testing.expectEqual(@as(i64, -3), refused.message.read_module_response.request_id);
    try std.testing.expectEqualStrings("reader queue is full", refused.message.read_module_response.error_message.?);
    try std.testing.expectEqual(@as(u32, 1), blocking.entered.load(.acquire));
}
