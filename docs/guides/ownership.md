# Ownership

zig-pkl allocates only through allocators you pass in, and every allocation has one owner that frees it.

| Value | Owner | Release |
| --- | --- | --- |
| `*Manager` from `Manager.init` | caller | `manager.deinit()` |
| `*Evaluator` from `createEvaluator` | the manager | `evaluator.close()`; memory is freed by `Manager.deinit` |
| `value.Tree` from `evaluate*` | caller | `tree.deinit()` |
| result of `evaluateInto` or `convert.into` | caller | `convert.freeInto(T, allocator, value)` with the same allocator |
| `failure` and `rejected` messages | caller | free with the manager's allocator |
| `project.Owned` from `project.load*` | caller | `project.deinit()` |
| strings from `uri.fromFile`, `uri.fromPath`, `Owned.moduleUri` | caller | free with the allocator passed in |
| generated types from `zig-pkl-gen` | caller | `value.deinit(allocator)` |

## Trees

A `Tree` keeps every node and string in one arena. `tree.deinit()` frees all of it at once, and every `*Value` and slice taken from the tree becomes invalid. Use `value.clone` to keep part of a tree, or convert it into owned Zig values with `convert.into`.

## Borrowed options

`Options` borrows everything it points to: allow lists, environment pairs, readers, loggers, the project. They must outlive `createEvaluator`. Readers and loggers, and the contexts behind them, must also outlive the evaluator, because the server calls back into them until `close` returns.

`Builder` owns only the allow list patterns it builds. Keep it alive until the evaluators created from `builder.options` are created; keep the readers alive until those evaluators are closed.

`project.Owned` owns every string in its `options` and `project`, so it must outlive the evaluators created from them.

## Allocators

The manager allocates requests, responses, and messages with the allocator given to `Manager.init`, from several threads. Pass a thread-safe allocator such as `std.heap.smp_allocator` or the `init.gpa` of `std.process.Init`.

`evaluateInto` and `convert.into` use the allocator you pass to them and can use any allocator, including an arena that you free in one step.
