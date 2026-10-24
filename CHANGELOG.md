# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- Repository governance, continuous integration, and the frozen pkl-zig benchmark baseline.
- Code generation: the `zig-pkl-gen` executable, the `zig_pkl.codegen` API, and the `@zig` Pkl annotation package under `codegen/`. Generated bindings cover primitives, optionals, collections, maps, pairs, durations, data sizes, regexes, bytes, integer sequences, classes, inheritance, type aliases, recursive and cross-module types, `local` classes, `pkl:ref` references, and unions as tagged unions or enums. Generation type-checks the bindings before writing, tracks the files it owns in a manifest and never overwrites or deletes other files without `--force`, and evaluates defaults with resource reads denied. Hidden properties, including an override that does not repeat `hidden`, are omitted. A default that references `pkl:platform`, including one reached through an amended module, another module's class, or a local, is omitted so host details are not copied into the bindings. A literal scalar in that module is kept.
- `zig_pkl.convert.Reference` and `zig_pkl.convert.Access` for `pkl:ref` values. Union decoding prefers members of exactly the value's kind, so `Float | Int` and `Int | Float` decode the same way.
- CI installs Pkl 0.32.2 from checksum-pinned release assets and fails, rather than skips, when the live tests cannot run.
- `zig build codegen` and `zig build codegen-test` build steps, and a consumer example in `examples/codegen`.
- `convert` decodes and encodes enums, tagged unions, single-item pointers, `convert.Map`, `convert.Pair`, and `convert.Dynamic`, and honors `pkl_names`, `pkl_class`, and `pkl_subclasses` declarations.
- `value.clone` and `value.cloneInto` deep-copy values.
- Comparative benchmark: `zig build bench` and `bench/compare.sh`, which runs zig-pkl and pkl-zig in the same job and applies the release gates. CI runs it on Linux and publishes the results.
- `zig build conformance` evaluates every module in `tests/conformance/cases` with Pkl twice: Pkl describes the result itself, zig-pkl decodes its pkl-binary form, and both descriptions must match. A case can require a minimum Pkl version with a `// min-pkl:` first line.
- CI runs the conformance and integration tests against Pkl 0.25.3, 0.26.3, 0.27.2, 0.28.2, 0.29.1, 0.30.2, 0.31.1, and 0.32.2, runs the fuzzer and a Markdown link check on every push, and fuzzes longer every week.
- Class and type alias values from Pkl before 0.30, which carry no name or module URI, decode instead of failing with `InvalidValue`, and encode back in the same form.
- Project loading works with Pkl before 0.32. zig-pkl reads `evaluatorSettings` and resolves relative module paths, cache and root directories, external reader working directories, and reader executables that name a path against the project directory, matching what `resolvedEvaluatorSettings` returns on Pkl 0.32.
- Runnable examples in `examples/` for typed and dynamic decoding, expressions, module output, projects, in-process readers, an external reader process, restricted evaluation, concurrency, and error handling. `zig build examples` runs them all and `zig build example-<name>` runs one. CI runs them on every platform and Pkl version.
- `zig build docs` generates the API reference.
- `Evaluator.evaluateInto` evaluates a module or expression and converts the result into a Zig type in one call.
- `createEvaluator` fails with `error.NoAllowedModules` when the options allow no modules, which would make Pkl 0.30 and newer exit.
- Guides in `docs/guides` for installation, evaluation, projects, security, readers, external readers, logging, concurrency, errors, memory ownership, version compatibility, and migration from pkl-zig.
- A Nuxt website in `site/`, built by `zig build site` and published to GitHub Pages, with the guides, the examples, benchmark charts, the version matrix, the changelog, and the API reference under `/api/`.
- `uri.fromFile` returns the `file:` URI of an existing file, and `uri.realFilePath` its canonical path.
- `Manager.init` no longer runs `pkl --version` before starting the server. The version is probed only when evaluator options first use a feature newer than Pkl 0.25.3, and the probe runs while that creation request is in flight; options it does not support close the new evaluator and fail. Shutdown wakes as soon as the server exits, through a pidfd on Linux and a kqueue on macOS, instead of polling. Reader worker threads start when module or resource reader callbacks arrive rather than with the manager. Together these halve the time to start a server, evaluate, and shut down.
