# Quick start

This page evaluates a Pkl file and reads it into a Zig struct. It assumes the package is installed as described in [Installation](installation.md).

## A Pkl file

```pkl
// config.pkl
name = "inventory"
port = 8080
tags = new Listing { "api"; "internal" }
```

## Read it from Zig

```zig
const std = @import("std");
const zig_pkl = @import("zig_pkl");

const Config = struct {
    name: []const u8,
    port: u16,
    tags: []const []const u8,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // One manager owns one `pkl server` process.
    const manager = try zig_pkl.Manager.init(allocator, io, &.{ "pkl", "server" }, zig_pkl.Logger.noop);
    defer manager.deinit();

    // An evaluator holds the settings modules are evaluated with.
    var rejected: ?[]u8 = null;
    defer if (rejected) |text| allocator.free(text);
    const evaluator = try manager.createEvaluator(zig_pkl.Options.preconfigured(), &rejected);
    defer evaluator.close();

    const module_uri = try zig_pkl.uri.fromFile(allocator, io, "config.pkl");
    defer allocator.free(module_uri);

    var failure: ?[]u8 = null;
    defer if (failure) |text| allocator.free(text);
    const config = evaluator.evaluateInto(Config, allocator, .uri(module_uri), null, &failure) catch |err| {
        if (failure) |text| std.debug.print("{s}\n", .{text});
        return err;
    };
    defer zig_pkl.convert.freeInto(Config, allocator, config);

    std.debug.print("{s} listens on {d}\n", .{ config.name, config.port });
}
```

## What happened

- `Manager.init` started `pkl server`. Keep one manager for the life of the program; starting the server is the slowest step.
- `createEvaluator` sent the evaluator settings. `Options.preconfigured()` allows local files, module paths, and packages. For untrusted input use `Options.restricted()`; see [Security](security.md).
- `uri.fromFile` turned a path into the canonical `file:` URI that Pkl expects.
- `evaluateInto` evaluated the module and copied the result into `Config`. When Pkl reports an error, the call returns `error.EvaluationFailed` and `failure` holds Pkl's message.
- `convert.freeInto` released everything `evaluateInto` allocated.

## Next steps

- [Evaluation](evaluation.md): typed and dynamic values, expressions, and module output.
- [Code generation](../codegen.md): generate the Zig types from the Pkl module instead of writing them.
- [Projects](projects.md): `PklProject` settings and dependencies.
- [Examples](../../examples): ten runnable programs.
