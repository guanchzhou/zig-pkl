//! `pkl server` subprocess transport.
//!
//! `close` stops new sends, closes the child's stdin so the server can exit at
//! end of input, and waits up to `Options.graceful_timeout_ms`, including any
//! time spent waiting for an in-flight `send` to finish. A child that is still
//! running is then terminated. On POSIX the child leads its own process group
//! and termination signals the whole group with TERM, then KILL after
//! `Options.kill_timeout_ms`; after the server exits, gracefully or not, any
//! processes left in its group are terminated the same way, so they cannot
//! hold the pipes open. A descendant that moves itself to another process
//! group is out of reach. On Windows only the direct child process is
//! terminated; descendants it started keep running, and if one of them holds
//! the stdout or stderr pipe open, `receive` and `close` wait until it exits.
//!
//! stdout stays open until `deinit` has observed that no `receive` call is
//! still running, so a reader never sees a closed or reused descriptor.
//! `close` and `send` may be called from any thread concurrently with
//! `receive`; `deinit` must be called once, after other threads stop starting
//! new calls.

const builtin = @import("builtin");
const std = @import("std");
const backend = @import("../backend.zig");
const message = @import("../protocol/message.zig");

pub const Backend = backend.Backend;

const posix_process_groups = switch (builtin.os.tag) {
    .windows, .wasi => false,
    else => true,
};

pub const Options = struct {
    /// Time allowed for the server to exit after stdin closes.
    graceful_timeout_ms: u32 = 2000,
    /// Time allowed between TERM and KILL on POSIX.
    kill_timeout_ms: u32 = 2000,
    /// Bytes of the most recent stderr output kept for diagnostics.
    /// Zero discards stderr.
    stderr_capacity: usize = 16 * 1024,
};

pub const Subprocess = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    child: std.process.Child,
    /// Process group led by the server, kept after the server is reaped.
    group: ?std.process.Child.Id,
    stdin: ?std.Io.File,
    stdout: std.Io.File,
    stderr: ?std.Io.File,
    stdin_buf: [8192]u8,
    stdout_buf: [8192]u8,
    stdin_writer: std.Io.File.Writer,
    stdout_reader: std.Io.File.Reader,
    send_mutex: std.Io.Mutex,
    close_mutex: std.Io.Mutex,
    closed: std.atomic.Value(bool),
    terminated: bool,
    receivers: std.atomic.Value(u32),
    stderr_thread: ?std.Thread,
    stderr_mutex: std.Io.Mutex,
    stderr_tail: []u8,
    stderr_len: usize,

    pub fn spawn(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !*Subprocess {
        return spawnWithOptions(allocator, io, argv, .{});
    }

    pub fn spawnWithOptions(
        allocator: std.mem.Allocator,
        io: std.Io,
        argv: []const []const u8,
        options: Options,
    ) !*Subprocess {
        const self = try allocator.create(Subprocess);
        errdefer allocator.destroy(self);
        const tail = try allocator.alloc(u8, options.stderr_capacity);
        errdefer allocator.free(tail);
        var child = try std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = if (options.stderr_capacity == 0) .ignore else .pipe,
            .pgid = if (posix_process_groups) 0 else null,
        });
        const stdin = child.stdin.?;
        const stdout = child.stdout.?;
        const stderr = child.stderr;
        child.stdin = null;
        child.stdout = null;
        child.stderr = null;
        self.* = .{
            .allocator = allocator,
            .io = io,
            .options = options,
            .child = child,
            .group = if (posix_process_groups) child.id else null,
            .stdin = stdin,
            .stdout = stdout,
            .stderr = stderr,
            .stdin_buf = undefined,
            .stdout_buf = undefined,
            .stdin_writer = undefined,
            .stdout_reader = undefined,
            .send_mutex = .init,
            .close_mutex = .init,
            .closed = std.atomic.Value(bool).init(false),
            .terminated = false,
            .receivers = std.atomic.Value(u32).init(0),
            .stderr_thread = null,
            .stderr_mutex = .init,
            .stderr_tail = tail,
            .stderr_len = 0,
        };
        self.stdin_writer = .initStreaming(stdin, io, &self.stdin_buf);
        self.stdout_reader = .initStreaming(stdout, io, &self.stdout_buf);
        if (stderr != null) {
            self.stderr_thread = std.Thread.spawn(.{}, stderrMain, .{self}) catch |err| {
                self.close();
                self.closeOutputs();
                return err;
            };
        }
        return self;
    }

    pub fn backend(self: *Subprocess) Backend {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = send,
                .receive = receive,
                .close = closePtr,
            },
        };
    }

    /// Closes stdin without stopping the process, signalling end of input.
    pub fn releaseInput(self: *Subprocess) void {
        self.send_mutex.lockUncancelable(self.io);
        defer self.send_mutex.unlock(self.io);
        self.closeInputLocked();
    }

    /// Stops the server and its process group. Idempotent and thread-safe;
    /// concurrent callers return after shutdown completes.
    pub fn close(self: *Subprocess) void {
        self.close_mutex.lockUncancelable(self.io);
        defer self.close_mutex.unlock(self.io);
        if (self.terminated) return;
        self.closed.store(true, .release);
        const deadline = std.Io.Clock.awake.now(self.io).addDuration(.fromMilliseconds(self.options.graceful_timeout_ms));
        if (self.lockSendBefore(deadline)) {
            self.closeInputLocked();
            self.send_mutex.unlock(self.io);
            if (!self.waitForExit(remainingMilliseconds(self.io, deadline))) self.terminate();
        } else {
            self.terminate();
            self.send_mutex.lockUncancelable(self.io);
            self.closeInputLocked();
            self.send_mutex.unlock(self.io);
        }
        self.terminateGroupRemnants();
        if (self.stderr_thread) |thread| {
            thread.join();
            self.stderr_thread = null;
        }
        self.terminated = true;
    }

    /// Copies the retained tail of the server's stderr output.
    pub fn stderrTail(self: *Subprocess, allocator: std.mem.Allocator) error{OutOfMemory}![]u8 {
        self.stderr_mutex.lockUncancelable(self.io);
        defer self.stderr_mutex.unlock(self.io);
        return allocator.dupe(u8, self.stderr_tail[0..self.stderr_len]);
    }

    pub fn deinit(self: *Subprocess) void {
        self.close();
        while (self.receivers.load(.acquire) != 0) self.io.sleep(.fromMilliseconds(1), .awake) catch {};
        self.closeOutputs();
        const allocator = self.allocator;
        allocator.free(self.stderr_tail);
        allocator.destroy(self);
    }

    fn closeOutputs(self: *Subprocess) void {
        self.stdout.close(self.io);
        if (self.stderr) |file| file.close(self.io);
    }

    fn closeInputLocked(self: *Subprocess) void {
        if (self.stdin) |file| {
            file.close(self.io);
            self.stdin = null;
        }
    }

    /// Waits for an in-flight `send` to release the input. New sends fail
    /// fast because `closed` is already set.
    fn lockSendBefore(self: *Subprocess, deadline: std.Io.Timestamp) bool {
        while (!self.send_mutex.tryLock()) {
            if (deadline.untilNow(self.io, .awake).nanoseconds >= 0) return false;
            self.io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
        return true;
    }

    /// Signals processes the server left in its group. `CONT` probes whether
    /// any member remains without disturbing running processes.
    fn terminateGroupRemnants(self: *Subprocess) void {
        if (comptime !posix_process_groups) return;
        const group = self.group orelse return;
        self.group = null;
        if (group <= 0) return;
        std.posix.kill(-group, .TERM) catch return;
        const deadline = std.Io.Clock.awake.now(self.io).addDuration(.fromMilliseconds(self.options.kill_timeout_ms));
        while (deadline.untilNow(self.io, .awake).nanoseconds < 0) {
            self.io.sleep(.fromMilliseconds(5), .awake) catch {};
            std.posix.kill(-group, .CONT) catch return;
        }
        std.posix.kill(-group, .KILL) catch {};
    }

    fn terminate(self: *Subprocess) void {
        if (self.child.id == null) return;
        if (posix_process_groups) {
            self.signalGroup(.TERM);
            if (self.waitForExit(self.options.kill_timeout_ms)) return;
            self.signalGroup(.KILL);
            _ = self.child.wait(self.io) catch {};
            self.child.id = null;
        } else {
            self.child.kill(self.io);
        }
    }

    fn signalGroup(self: *Subprocess, signal: std.posix.SIG) void {
        const pid = self.child.id orelse return;
        if (pid > 0) std.posix.kill(-pid, signal) catch {};
    }

    fn waitForExit(self: *Subprocess, timeout_ms: u32) bool {
        if (self.child.id == null) return true;
        switch (builtin.os.tag) {
            .windows => {
                const windows = std.os.windows;
                const timeout: windows.LARGE_INTEGER = -@as(i64, timeout_ms) * 10_000;
                const status = windows.ntdll.NtWaitForSingleObject(self.child.id.?, .FALSE, &timeout);
                if (status != windows.NTSTATUS.WAIT_0) return false;
                _ = self.child.wait(self.io) catch {};
                return true;
            },
            .wasi => return false,
            else => {
                // The server usually exits within a few milliseconds of
                // stdin closing, so polling starts fine and backs off.
                const deadline = std.Io.Clock.awake.now(self.io).addDuration(.fromMilliseconds(timeout_ms));
                var pause_us: i64 = 100;
                while (true) {
                    if (self.reapWithoutBlocking()) return true;
                    if (deadline.untilNow(self.io, .awake).nanoseconds >= 0) return false;
                    self.io.sleep(.fromMicroseconds(pause_us), .awake) catch {};
                    pause_us = @min(pause_us * 2, 5_000);
                }
            },
        }
    }

    fn reapWithoutBlocking(self: *Subprocess) bool {
        const pid = self.child.id orelse return true;
        var status: if (builtin.link_libc) c_int else i32 = undefined;
        while (true) {
            const rc = std.posix.system.waitpid(pid, &status, std.posix.W.NOHANG);
            switch (std.posix.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) return false;
                    self.child.id = null;
                    return true;
                },
                .INTR => continue,
                else => {
                    self.child.id = null;
                    return true;
                },
            }
        }
    }

    fn appendStderr(self: *Subprocess, bytes: []const u8) void {
        const capacity = self.stderr_tail.len;
        self.stderr_mutex.lockUncancelable(self.io);
        defer self.stderr_mutex.unlock(self.io);
        if (bytes.len >= capacity) {
            @memcpy(self.stderr_tail, bytes[bytes.len - capacity ..]);
            self.stderr_len = capacity;
            return;
        }
        const overflow = (self.stderr_len + bytes.len) -| capacity;
        if (overflow != 0) {
            std.mem.copyForwards(u8, self.stderr_tail, self.stderr_tail[overflow..self.stderr_len]);
            self.stderr_len -= overflow;
        }
        @memcpy(self.stderr_tail[self.stderr_len..][0..bytes.len], bytes);
        self.stderr_len += bytes.len;
    }
};

fn remainingMilliseconds(io: std.Io, deadline: std.Io.Timestamp) u32 {
    const left = -deadline.untilNow(io, .awake).toMilliseconds();
    return @intCast(std.math.clamp(left, 0, std.math.maxInt(u32)));
}

fn stderrMain(self: *Subprocess) void {
    var buffer: [1024]u8 = undefined;
    var file_reader = std.Io.File.Reader.initStreaming(self.stderr.?, self.io, &buffer);
    const input = &file_reader.interface;
    while (true) {
        const chunk = input.peekGreedy(1) catch return;
        self.appendStderr(chunk);
        input.toss(chunk.len);
    }
}

fn send(ptr: *anyopaque, payload: *const message.Message) anyerror!void {
    const self: *Subprocess = @ptrCast(@alignCast(ptr));
    const bytes = try message.encodeAlloc(self.allocator, payload.*);
    defer self.allocator.free(bytes);
    self.send_mutex.lockUncancelable(self.io);
    defer self.send_mutex.unlock(self.io);
    if (self.closed.load(.acquire) or self.stdin == null) return error.Closed;
    self.stdin_writer.interface.writeAll(bytes) catch return error.Closed;
    self.stdin_writer.interface.flush() catch return error.Closed;
}

fn receive(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!message.Owned {
    const self: *Subprocess = @ptrCast(@alignCast(ptr));
    _ = self.receivers.fetchAdd(1, .acq_rel);
    defer _ = self.receivers.fetchSub(1, .release);
    if (self.closed.load(.acquire)) return error.Closed;
    const input = &self.stdout_reader.interface;
    _ = input.peekByte() catch return error.Closed;
    return message.decodeReader(allocator, input) catch |err| switch (err) {
        error.ReadFailed => error.Closed,
        else => |other| other,
    };
}

fn closePtr(ptr: *anyopaque) void {
    const self: *Subprocess = @ptrCast(@alignCast(ptr));
    self.close();
}

fn spawnForTest(argv: []const []const u8, options: Options) !*Subprocess {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    return Subprocess.spawnWithOptions(std.testing.allocator, std.testing.io, argv, options) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
}

fn sleepMilliseconds(milliseconds: i64) void {
    std.testing.io.sleep(.fromMilliseconds(milliseconds), .awake) catch {};
}

test "subprocess echoes one framed message through cat" {
    const allocator = std.testing.allocator;
    const child = try spawnForTest(&.{"/bin/cat"}, .{});
    defer child.deinit();
    const transport = child.backend();
    try transport.send(&.{ .close_evaluator = .{ .evaluator_id = 42 } });
    child.releaseInput();
    var owned = try transport.receive(allocator);
    defer owned.deinit();
    try std.testing.expectEqual(@as(i64, 42), owned.message.close_evaluator.evaluator_id);
}

test "subprocess receives payloads larger than its transport buffer" {
    const allocator = std.testing.allocator;
    const payload = try allocator.alloc(u8, 24 * 1024);
    defer allocator.free(payload);
    @memset(payload, 0xa5);
    const child = try spawnForTest(&.{"/bin/cat"}, .{});
    defer child.deinit();
    const transport = child.backend();
    try transport.send(&.{ .evaluate_response = .{
        .request_id = 1,
        .evaluator_id = 2,
        .result = payload,
    } });
    child.releaseInput();
    var owned = try transport.receive(allocator);
    defer owned.deinit();
    try std.testing.expectEqualSlices(u8, payload, owned.message.evaluate_response.result.?);
}

const ReceiveProbe = struct {
    transport: Backend,
    err: ?anyerror = null,
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *ReceiveProbe) void {
        self.started.store(true, .release);
        var owned = self.transport.receive(std.testing.allocator) catch |err| {
            self.err = err;
            return;
        };
        owned.deinit();
    }

    fn waitStarted(self: *ReceiveProbe) void {
        while (!self.started.load(.acquire)) std.Thread.yield() catch {};
        sleepMilliseconds(20);
    }
};

test "close synchronizes concurrent send and receive" {
    const child = try spawnForTest(&.{ "/bin/sh", "-c", "cat >/dev/null" }, .{});
    defer child.deinit();
    const Sender = struct {
        transport: Backend,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            while (true) {
                self.transport.send(&.{ .close_evaluator = .{ .evaluator_id = 1 } }) catch |err| {
                    self.err = err;
                    return;
                };
            }
        }
    };
    var receiver = ReceiveProbe{ .transport = child.backend() };
    var sender = Sender{ .transport = child.backend() };
    const receive_thread = try std.Thread.spawn(.{}, ReceiveProbe.run, .{&receiver});
    const send_thread = try std.Thread.spawn(.{}, Sender.run, .{&sender});
    receiver.waitStarted();
    child.close();
    receive_thread.join();
    send_thread.join();
    try std.testing.expectEqual(error.Closed, receiver.err.?);
    try std.testing.expectEqual(error.Closed, sender.err.?);
    try std.testing.expectError(error.Closed, child.backend().send(&.{ .close_evaluator = .{ .evaluator_id = 2 } }));
}

test "deinit waits for a blocked receive before releasing descriptors" {
    const child = try spawnForTest(&.{ "/bin/sh", "-c", "cat >/dev/null" }, .{});
    var receiver = ReceiveProbe{ .transport = child.backend() };
    const thread = try std.Thread.spawn(.{}, ReceiveProbe.run, .{&receiver});
    receiver.waitStarted();
    child.deinit();
    thread.join();
    try std.testing.expectEqual(error.Closed, receiver.err.?);
}

test "shutdown escalates to the whole process group after the graceful wait" {
    const child = try spawnForTest(
        &.{ "/bin/sh", "-c", "trap '' TERM; sleep 30; echo late" },
        .{ .graceful_timeout_ms = 50, .kill_timeout_ms = 100 },
    );
    var receiver = ReceiveProbe{ .transport = child.backend() };
    const thread = try std.Thread.spawn(.{}, ReceiveProbe.run, .{&receiver});
    receiver.waitStarted();
    const started = std.Io.Clock.awake.now(std.testing.io);
    child.deinit();
    thread.join();
    const elapsed = started.untilNow(std.testing.io, .awake);
    try std.testing.expectEqual(error.Closed, receiver.err.?);
    try std.testing.expect(elapsed.toMilliseconds() < 5000);
}

test "close keeps the graceful exit path while a send is in flight" {
    const child = try spawnForTest(
        &.{ "/bin/sh", "-c", "read x; echo graceful-exit 1>&2" },
        .{ .graceful_timeout_ms = 5000, .kill_timeout_ms = 500 },
    );
    defer child.deinit();
    child.send_mutex.lockUncancelable(std.testing.io);
    var locked = true;
    defer if (locked) child.send_mutex.unlock(std.testing.io);
    const closer = try std.Thread.spawn(.{}, Subprocess.close, .{child});
    sleepMilliseconds(50);
    locked = false;
    child.send_mutex.unlock(std.testing.io);
    closer.join();
    const tail = try child.stderrTail(std.testing.allocator);
    defer std.testing.allocator.free(tail);
    try std.testing.expectEqualStrings("graceful-exit\n", tail);
}

test "processes left in the group are terminated after a graceful server exit" {
    const child = try spawnForTest(
        &.{ "/bin/sh", "-c", "sleep 30 & read x; exit 0" },
        .{ .graceful_timeout_ms = 2000, .kill_timeout_ms = 500 },
    );
    var receiver = ReceiveProbe{ .transport = child.backend() };
    const thread = try std.Thread.spawn(.{}, ReceiveProbe.run, .{&receiver});
    receiver.waitStarted();
    const started = std.Io.Clock.awake.now(std.testing.io);
    child.deinit();
    thread.join();
    const elapsed = started.untilNow(std.testing.io, .awake);
    try std.testing.expectEqual(error.Closed, receiver.err.?);
    try std.testing.expect(elapsed.toMilliseconds() < 5000);
}

test "send after the server exits fails without a partial frame" {
    const child = try spawnForTest(&.{ "/bin/sh", "-c", "exit 0" }, .{});
    defer child.deinit();
    sleepMilliseconds(100);
    const transport = child.backend();
    const large = try std.testing.allocator.alloc(u8, 256 * 1024);
    defer std.testing.allocator.free(large);
    @memset(large, 'x');
    try std.testing.expectError(error.Closed, transport.send(&.{ .evaluate_request = .{
        .request_id = 1,
        .evaluator_id = 1,
        .module_uri = "repl:text",
        .module_text = large,
    } }));
    try std.testing.expectError(error.Closed, transport.receive(std.testing.allocator));
}

test "stderr keeps a bounded tail of server diagnostics" {
    const child = try spawnForTest(
        &.{ "/bin/sh", "-c", "i=0; while [ $i -lt 200 ]; do echo line-$i 1>&2; i=$((i+1)); done; echo final-line 1>&2" },
        .{ .stderr_capacity = 64 },
    );
    defer child.deinit();
    child.close();
    const tail = try child.stderrTail(std.testing.allocator);
    defer std.testing.allocator.free(tail);
    try std.testing.expect(tail.len <= 64);
    try std.testing.expect(std.mem.endsWith(u8, tail, "final-line\n"));
}
