//! Pkl version parsing and the feature gates used by evaluator options.

const std = @import("std");

pub const Error = error{
    InvalidVersion,
    CommandFailed,
    FileNotFound,
} || std.process.RunError || std.mem.Allocator.Error;

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,

    pub fn order(self: Version, other: Version) std.math.Order {
        if (self.major != other.major) return std.math.order(self.major, other.major);
        if (self.minor != other.minor) return std.math.order(self.minor, other.minor);
        return std.math.order(self.patch, other.patch);
    }

    pub fn atLeast(self: Version, other: Version) bool {
        return self.order(other) != .lt;
    }

    pub fn parse(text: []const u8) error{InvalidVersion}!Version {
        const start = std.mem.indexOfAny(u8, text, "0123456789") orelse return error.InvalidVersion;
        var rest = text[start..];
        const major = try takeComponent(&rest);
        if (rest.len == 0 or rest[0] != '.') return error.InvalidVersion;
        rest = rest[1..];
        const minor = try takeComponent(&rest);
        if (rest.len == 0 or rest[0] != '.') return error.InvalidVersion;
        rest = rest[1..];
        const patch = try takeComponent(&rest);
        return .{ .major = major, .minor = minor, .patch = patch };
    }
};

pub const http_settings = Version{ .major = 0, .minor = 26, .patch = 0 };
pub const external_readers = Version{ .major = 0, .minor = 27, .patch = 0 };
pub const http_rewrites = Version{ .major = 0, .minor = 29, .patch = 0 };
pub const trace_mode = Version{ .major = 0, .minor = 30, .patch = 0 };
pub const http_headers = Version{ .major = 0, .minor = 32, .patch = 0 };
pub const minimum_supported = Version{ .major = 0, .minor = 25, .patch = 3 };
pub const supported = Version{ .major = 0, .minor = 32, .patch = 2 };

/// Runs `executable --version`.
pub fn query(allocator: std.mem.Allocator, io: std.Io, executable: []const u8) Error!Version {
    return queryArgv(allocator, io, &.{ executable, "--version" });
}

/// Runs `argv` and parses the first version number it prints.
pub fn queryArgv(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) Error!Version {
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(512),
        .stderr_limit = .limited(512),
    }) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!result.term.success()) return error.CommandFailed;
    return Version.parse(result.stdout);
}

/// Derives the version command from a server command line by replacing the
/// last `server` argument, and everything after it, with `--version`. This
/// keeps wrappers such as `env pkl server` or `java -jar pkl.jar server`
/// working. The caller owns the returned slice; its strings stay borrowed.
pub fn versionArgv(allocator: std.mem.Allocator, server_argv: []const []const u8) error{ OutOfMemory, UnknownServerCommand }![]const []const u8 {
    var index = server_argv.len;
    while (index > 0) {
        index -= 1;
        if (std.mem.eql(u8, server_argv[index], "server")) {
            if (index == 0) return error.UnknownServerCommand;
            const argv = try allocator.alloc([]const u8, index + 1);
            @memcpy(argv[0..index], server_argv[0..index]);
            argv[index] = "--version";
            return argv;
        }
    }
    return error.UnknownServerCommand;
}

/// Probes the version of the Pkl distribution that `server_argv` launches.
pub fn probeServer(allocator: std.mem.Allocator, io: std.Io, server_argv: []const []const u8) (Error || error{UnknownServerCommand})!Version {
    const argv = try versionArgv(allocator, server_argv);
    defer allocator.free(argv);
    return queryArgv(allocator, io, argv);
}

fn takeComponent(rest: *[]const u8) error{InvalidVersion}!u32 {
    var index: usize = 0;
    while (index < rest.len and std.ascii.isDigit(rest.*[index])) index += 1;
    if (index == 0) return error.InvalidVersion;
    const value = std.fmt.parseInt(u32, rest.*[0..index], 10) catch return error.InvalidVersion;
    rest.* = rest.*[index..];
    return value;
}

test "version order and text parsing" {
    const parsed = try Version.parse("Pkl 0.32.2 (macOS, native)\n");
    try std.testing.expect(parsed.atLeast(supported));
    try std.testing.expect(parsed.atLeast(http_headers));
    try std.testing.expect(!http_settings.atLeast(external_readers));
    try std.testing.expect(minimum_supported.atLeast(.{ .major = 0, .minor = 25, .patch = 3 }));
    try std.testing.expectEqual(Version{ .major = 0, .minor = 26, .patch = 1 }, try Version.parse("0.26.1"));
    try std.testing.expectError(error.InvalidVersion, Version.parse("pkl"));
}

test "version command follows wrapper prefixes of the server command" {
    const allocator = std.testing.allocator;
    const wrapped = try versionArgv(allocator, &.{ "/usr/bin/env", "pkl", "server" });
    defer allocator.free(wrapped);
    try std.testing.expectEqual(@as(usize, 3), wrapped.len);
    try std.testing.expectEqualStrings("/usr/bin/env", wrapped[0]);
    try std.testing.expectEqualStrings("pkl", wrapped[1]);
    try std.testing.expectEqualStrings("--version", wrapped[2]);

    const jar = try versionArgv(allocator, &.{ "java", "-jar", "pkl.jar", "server", "--extra" });
    defer allocator.free(jar);
    try std.testing.expectEqualStrings("pkl.jar", jar[2]);
    try std.testing.expectEqualStrings("--version", jar[3]);
    try std.testing.expectEqual(@as(usize, 4), jar.len);

    try std.testing.expectError(error.UnknownServerCommand, versionArgv(allocator, &.{"my-pkl-wrapper"}));
    try std.testing.expectError(error.UnknownServerCommand, versionArgv(allocator, &.{"server"}));
}

test "probing runs the wrapper with the version argument" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const probed = probeServer(std.testing.allocator, std.testing.io, &.{
        "/bin/sh",
        "-c",
        "if [ \"$1\" = --version ]; then echo 'Pkl 0.29.1 (wrapper)'; else exit 3; fi",
        "sh",
        "server",
    }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    try std.testing.expectEqual(Version{ .major = 0, .minor = 29, .patch = 1 }, probed);
}
