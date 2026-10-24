# Migrating from pkl-zig

[pkl-zig](https://github.com/burakssen/pkl-zig) and zig-pkl both talk to `pkl server`, so the concepts carry over. The names and ownership rules differ. This page maps the API documented in pkl-zig's README to zig-pkl.

## Toolchain and package

| | pkl-zig | zig-pkl |
| --- | --- | --- |
| Zig | 0.16.0 | 0.17.0 |
| Pkl | 0.32.1 | 0.25.3 and newer; 0.32.2 for code generation |
| Dependency | `pkl_zig`, module `pkl` | `zig_pkl`, module `zig_pkl` |

```zig
const zig_pkl = b.dependency("zig_pkl", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zig_pkl", zig_pkl.module("zig_pkl"));
```

## Evaluators

pkl-zig's `Evaluator.init` starts a server per evaluator unless you use `EvaluatorManager`. In zig-pkl every evaluator belongs to a `Manager`, which owns the server:

| pkl-zig | zig-pkl |
| --- | --- |
| `pkl.Evaluator.init(io, gpa, .{ .pkl_argv = argv, ... })` | `Manager.init(gpa, io, argv, log)`, then `manager.createEvaluator(options, &rejected)` |
| `pkl.EvaluatorManager.init` and `manager.newEvaluator(options)` | `Manager.init` and `manager.createEvaluator(options, &rejected)` |
| `InitResult.failed` with a diagnostic | `error.Rejected`, with the diagnostic in `rejected` |
| `evaluator.deinit()` | `evaluator.close()`; the manager frees it |
| `Evaluator.initPreconfigured(io, gpa, environ_map)` | `Options.preconfigured()`; set `env` and `cache_dir` yourself |
| `EvaluatorOptionsBuilder` and `addModuleReader` | `Builder.restricted(allocator)` or `Builder.preconfigured(allocator)`, then `moduleReaders(&readers)` |
| `ModuleSource.fromText(text)` | `Source.text(text)` |
| `ModuleSource.fromUri(uri)` | `Source.uri(uri)` |

pkl-zig's `initPreconfigured` forwards the process environment and reads `PKL_EXEC`. zig-pkl does neither on its own: pass the server command to `Manager.init`, and copy any environment variables a module needs into `Options.env`. See [Security](security.md).

Calls on one pkl-zig evaluator are serialized. A zig-pkl evaluator accepts concurrent calls from any thread; see [Concurrency](concurrency.md).

## Loading values

| pkl-zig | zig-pkl |
| --- | --- |
| `evaluator.loadFromPath(T, path)` | `evaluator.evaluateInto(T, allocator, .uri(try zig_pkl.uri.fromFile(allocator, io, path)), null, &failure)` |
| `evaluator.evaluateModule(T, source)` | `evaluator.evaluateInto(T, allocator, source, null, &failure)` |
| `evaluator.evaluateExpression` | `evaluator.evaluateInto(T, allocator, source, expression, &failure)` |
| `evaluator.evaluateOutputText(source)` | `evaluator.evaluateSource(source, "output.text", &failure)` |
| `evaluator.evaluateOutputBytes(source)` | `evaluator.evaluateSource(source, "output.bytes", &failure)` |
| `evaluator.evaluateOutputValue(T, source)` | `evaluator.evaluateInto(T, allocator, source, "output.value", &failure)` |
| `evaluator.evaluateOutputFiles(source)` | `evaluator.evaluateSource(source, "output.files.toMap().mapValues((_, f) -> f.text)", &failure)` |
| `pkl.deinit(T, allocator, &value)` | `zig_pkl.convert.freeInto(T, allocator, value)` |
| `pkl.Value` | `zig_pkl.Value` inside a `value.Tree`; free with `tree.deinit()` |

Evaluation errors return `error.EvaluationFailed` with Pkl's message in `failure`. See [Errors](errors.md).

## Readers and logging

Both libraries take module and resource readers with a scheme, `read`, and `list`. In zig-pkl, `read` and `list` return memory allocated with the allocator they receive, and the manager frees it after replying. See [Readers](readers.md). Loggers are set per evaluator through `Options.logger`; see [Logging](logging.md). zig-pkl adds a client for [external readers](external-readers.md).

## Code generation

pkl-zig generates with `pkl run codegen/src/gen.pkl` or `pkl_zig.addCodegen` in `build.zig`. zig-pkl ships the `zig-pkl-gen` executable and its own `@zig` annotation package; generated modules have `decode`, `deinit`, and `load(allocator, evaluator, source, &failure)`. Heterogeneous unions and unions across packages become tagged unions instead of falling back to a dynamic value. See [Code generation](../codegen.md).

## Low-level protocol

pkl-zig's `Transport` corresponds to `zig_pkl.Backend` and `zig_pkl.Subprocess`, with messages in `zig_pkl.protocol` and MessagePack in `zig_pkl.msgpack`. `Manager.initWithBackend` runs the manager over any `Backend`.
