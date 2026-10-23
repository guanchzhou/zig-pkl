# Contributing

Contributions are reviewed against this document and the [code of conduct](CODE_OF_CONDUCT.md).

## Setup

- Zig 0.17.0
- Pkl 0.32.2 when a change exercises evaluation or code generation

```sh
zig fmt --check .
zig build
zig build test
```

Format Zig sources with `zig fmt` before review.

Changes to the generator or to `codegen/` need `zig build codegen-test` with Pkl installed. When generated output changes on purpose, run `zig build codegen` and commit the updated `tests/codegen/snapshots` and `examples/codegen/src/bindings`, including their `.zig-pkl-gen-manifest` files, together with the change. Set `ZIG_PKL_REQUIRE_PKL=1` to make missing Pkl a test failure instead of a skip.

## Changes

Keep each change focused. Update `CHANGELOG.md` under `Unreleased` when behavior visible to users changes.

Performance work is compared on the same run with `bench/compare.sh`, as described in [docs/benchmarks/comparison.md](docs/benchmarks/comparison.md), against the gates in [docs/benchmarks/baseline.md](docs/benchmarks/baseline.md). Absolute timings from that record are not release thresholds.

Sign your commits. Release tags are signed by the maintainer; see [SECURITY.md](SECURITY.md).

## Review

`main` requires signed commits and passing CI and Security checks. Actions tokens stay read-only except for documentation deployment and release publication.

Report security issues privately, as described in [SECURITY.md](SECURITY.md).
