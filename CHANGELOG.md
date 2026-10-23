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
