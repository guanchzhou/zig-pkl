# Logging

Pkl sends log messages while it evaluates: the output of `trace()` and warnings such as uses of deprecated members. zig-pkl passes each one to a `Logger`.

```zig
const PrintLogger = struct {
    fn logger(self: *PrintLogger) zig_pkl.Logger {
        return .{ .ptr = self, .vtable = &.{ .log = log } };
    }

    fn log(_: *anyopaque, event: zig_pkl.logger.Event) void {
        const level = if (event.level == 0) "trace" else "warn";
        std.debug.print("[{s}] {s} ({s})\n", .{ level, event.message, event.frame_uri });
    }
};

var print_logger = PrintLogger{};
var options = zig_pkl.Options.restricted();
options.logger = print_logger.logger();
```

An `Event` carries the evaluator id, the level (0 for trace, 1 for warn), the message, and the URI of the frame that logged it. The slices are valid only during the call, so copy what you keep.

## Where messages go

- `Options.logger` receives messages for evaluators created with those options.
- The logger passed to `Manager.init` receives messages for evaluators without their own logger.
- `Logger.noop` drops messages, `logger.Stderr.logger()` writes them through `std.log` with the `pkl` scope, and `logger.Capture` keeps the most recent message for tests.

## Threads

Loggers run on the manager's response thread. A slow logger delays every response on the manager, so hand expensive work to another thread. `Evaluator.close` waits for that evaluator's logger calls to return.

`Options.trace_mode` (Pkl 0.30 and newer) chooses between `.compact` and `.pretty` formatting of `trace()` output.

See [`examples/errors`](../../examples/errors/main.zig).
