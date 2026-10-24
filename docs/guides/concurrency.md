# Concurrency

A `Manager` owns one `pkl server` process and multiplexes every evaluator over it. Starting the server is the slowest step of an evaluation, so create one manager and share it.

## What is thread-safe

- Any thread may call `createEvaluator`, `evaluate`, and `close` on a shared manager at any time.
- Any thread may evaluate through any evaluator, including several threads through the same evaluator at once. Requests carry ids and their responses are matched independently, so a slow evaluation does not hold up a fast one.
- `Evaluator.close` is idempotent. It waits for the evaluator's reader and logger callbacks, then tells the server.
- `Manager.deinit` must run once, after your threads stop starting requests. It cancels requests still pending and waits for callbacks to finish.

```zig
const shared = try manager.createEvaluator(zig_pkl.Options.restricted(), &rejected);
defer shared.close();

var workers: [4]std.Thread = undefined;
for (&workers, 0..) |*worker, index| {
    worker.* = try std.Thread.spawn(.{}, work, .{ shared, index });
}
for (workers) |worker| worker.join();
```

See [`examples/concurrency`](../../examples/concurrency/main.zig).

## Inside the manager

One response thread reads frames from the server and wakes the request each one answers. Log messages are delivered on that thread. Reader callbacks go to a bounded pool of worker threads that start on demand; see [Readers](readers.md#threads).

## Failure

A broken pipe, a server exit, or a malformed frame is terminal for the manager. Every pending request fails with that error, later requests fail immediately with it, and `Manager.failure()` returns it. Create a new manager to recover. See [Errors](errors.md).
