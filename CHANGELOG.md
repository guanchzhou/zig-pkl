# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-10-24

First release. It needs Zig 0.17.0 and Pkl 0.25.3 or newer; code generation needs Pkl 0.32.2.

### Evaluation

- `Manager` runs one `pkl server` process and shares it between evaluators on any thread. `Evaluator.evaluateWithOptions` takes a timeout and a `Cancellation`.
- `Options` covers the evaluator settings of the Message Passing API: module and resource allow lists, environment variables and properties, module paths, root and cache directories, timeouts, output format, HTTP proxy, certificates, rewrites, and headers, external readers, trace mode, and projects. `Options.restricted()` and `Options.preconfigured()` are starting points, and `Builder` adds readers.
- `createEvaluator` refuses settings the running Pkl release does not support with `error.UnsupportedVersion`, and options without allowed modules with `error.NoAllowedModules`. The server version is probed only when options need a release newer than 0.25.3.
- `Evaluator.evaluateSource` returns a `value.Tree`; `Evaluator.evaluateInto` converts the result into a Zig type. `convert` maps Pkl values to structs, tagged unions, enums, optionals, slices, pointers, and the `convert.Map`, `convert.Pair`, `convert.Duration`, `convert.DataSize`, `convert.Regex`, `convert.Bytes`, `convert.IntSeq`, `convert.Reference`, and `convert.Dynamic` types, with `pkl_names`, `pkl_class`, and `pkl_subclasses` declarations.
- Module and resource readers implemented as Zig callbacks, including glob listing, and `ExternalClient` for running a program as an external reader that Pkl starts.
- Per-evaluator loggers for `trace()` output and warnings.
- `project.load` reads `PklProject` settings and dependencies. Relative paths resolve against the project directory on every supported release, matching what `resolvedEvaluatorSettings` returns on Pkl 0.32.
- pkl-binary decoding and encoding with `value.decodeSlice`, `value.decodeReader`, `value.encode`, and `value.clone`, including values from Pkl releases before 0.30 that carry no class name.
- `uri.fromFile` returns the `file:` URI of an existing file.

### Code generation

- `zig-pkl-gen` and the `zig_pkl.codegen` API write Zig types for Pkl modules: primitives, optionals, collections, maps, pairs, durations, data sizes, regexes, bytes, integer sequences, classes and inheritance, type aliases, recursive and cross-module types, `local` classes, `pkl:ref` references, and unions as tagged unions or enums, including unions of unrelated types.
- Generation type-checks the bindings before writing them, records the files it owns in a manifest, and does not overwrite or delete other files without `--force`. `--check` reports stale bindings.
- Defaults are evaluated with resource reads denied. Hidden properties are omitted, and so are defaults that depend on `pkl:platform`.
- The `@zig` annotations are published as the Pkl package `package://pkg.pkl-lang.org/github.com/guanchzhou/zig-pkl/zig@0.1.0`.

### Verification

- CI runs the unit, integration, conformance, and code generation tests and every example on Linux x86_64 and aarch64, macOS aarch64, and Windows x86_64, and the conformance and integration tests and the examples against Pkl 0.25.3, 0.26.3, 0.27.2, 0.28.2, 0.29.1, 0.30.2, 0.31.1, and 0.32.2.
- `zig build conformance` compares each decoded value with Pkl's own description of it. `zig build fuzz` runs on every push, and longer every week.
- `bench/compare.sh` runs zig-pkl and pkl-zig in the same job. On an Apple M5 with Pkl 0.32.2, zig-pkl decodes pkl-binary 2.75 times faster (geometric mean of three cases) with 86% to 99.6% fewer allocations, is 7.7% faster to start a server, evaluate, and shut down, and 18.9% faster per evaluation on a running evaluator.

### Documentation

- Guides for installation, evaluation, projects, security, readers, external readers, logging, concurrency, errors, memory ownership, version compatibility, and migration from pkl-zig.
- Ten runnable examples in `examples/`, run by `zig build examples`, and a code generation consumer in `examples/codegen`.
- The website at <https://guanchzhou.github.io/zig-pkl/>, built by `zig build site`, with the API reference under `/api/`.

[Unreleased]: https://github.com/guanchzhou/zig-pkl/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/guanchzhou/zig-pkl/releases/tag/v0.1.0
