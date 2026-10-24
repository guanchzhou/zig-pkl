# Errors

zig-pkl reports failures as Zig errors. When Pkl explains a failure, the explanation is returned through an out parameter that the caller frees.

## Evaluation failures

```zig
var failure: ?[]u8 = null;
defer if (failure) |text| allocator.free(text);
var tree = evaluator.evaluateSource(source, null, &failure) catch |err| switch (err) {
    error.EvaluationFailed => {
        std.debug.print("{s}\n", .{failure.?});
        return err;
    },
    else => return err,
};
```

`error.EvaluationFailed` means Pkl evaluated the request and reported an error: a type constraint, a missing property, a denied import, a `throw`. `failure` then holds Pkl's full message, allocated with the manager's allocator. The message starts with a `–– Pkl Error ––` banner, then the reason, then the source location.

Reuse one `failure` variable across calls only if you free it between them; each failing call overwrites it.

## Rejected evaluators

```zig
var rejected: ?[]u8 = null;
defer if (rejected) |text| allocator.free(text);
const evaluator = manager.createEvaluator(options, &rejected) catch |err| switch (err) {
    error.Rejected => return reportRejected(rejected.?),
    else => return err,
};
```

Pkl rejects settings it cannot use, such as an allow list entry that is not a valid regular expression. Before Pkl 0.29 that particular mistake makes the server exit instead, which surfaces as `error.Closed`.

Other errors from `createEvaluator`:

| Error | Meaning |
| --- | --- |
| `error.NoAllowedModules` | `allowed_modules` is null or empty; see [Security](security.md) |
| `error.UnsupportedVersion` | the options use a feature the server's Pkl release lacks; see [Version compatibility](compatibility.md) |

## Timeouts and cancellation

`evaluateWithOptions` and `createEvaluatorWithOptions` accept a client-side deadline and a cancellation flag:

```zig
var tree = try evaluator.evaluateWithOptions("repl:text", text, null, &failure, .{
    .timeout = .{ .duration = .{ .raw = .fromMilliseconds(250), .clock = .awake } },
});

var cancellation = zig_pkl.Cancellation{};
// another thread: cancellation.cancel();
var other = try evaluator.evaluateWithOptions(uri, null, null, &failure, .{ .cancellation = &cancellation });
```

They return `error.Timeout` and `error.Canceled`. The client stops waiting, but the server keeps evaluating until it finishes; its late answer is discarded. To bound the server's own work, set `Options.timeout_seconds`, which Pkl enforces and reports as `error.EvaluationFailed`.

## Connection failures

| Error | Meaning |
| --- | --- |
| `error.FileNotFound` | `Manager.init` could not start the server command |
| `error.Closed` | the server exited, its pipes closed, or the manager is shutting down |
| `error.Protocol` | the server sent a response that does not fit the request |
| `error.InvalidMessage`, `error.UnknownCode`, `error.LimitExceeded` | a frame could not be decoded within the limits |

These are terminal for the manager: pending and later requests fail with the same error, and `Manager.failure()` returns it. `Manager.serverStderr(allocator)` returns the last part of the server's standard error, which usually says why it exited.

## Decoding

`convert.into` and `evaluateInto` return `error.TypeMismatch` when a value does not fit the Zig type, `error.MissingField` when a struct field without a default has no matching property, and `error.Overflow` when an integer does not fit.

[`examples/errors`](../../examples/errors/main.zig) shows each case against a live server.
