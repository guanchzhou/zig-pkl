# zig-pkl

[![CI](https://github.com/guanchzhou/zig-pkl/actions/workflows/ci.yml/badge.svg)](https://github.com/guanchzhou/zig-pkl/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/guanchzhou/zig-pkl)](https://github.com/guanchzhou/zig-pkl/releases/latest)
[![Docs](https://github.com/guanchzhou/zig-pkl/actions/workflows/docs.yml/badge.svg)](https://guanchzhou.github.io/zig-pkl/)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

Zig 0.17 bindings for [Pkl](https://pkl-lang.org/).

The current release is [0.1.1](https://github.com/guanchzhou/zig-pkl/releases/tag/v0.1.1). The module name is `zig_pkl`. The public API may change before 1.0.

## Requirements

- Zig 0.17.0
- Pkl 0.25.3 or newer for evaluation. CI runs the conformance and integration tests against the latest patch release of every minor version from 0.25 to 0.32.
- Pkl 0.32.2 for code generation

## Build

```sh
zig build
zig build test
zig build integration-test   # uses PKL_EXEC or pkl on PATH; skips when absent unless ZIG_PKL_REQUIRE_PKL=1
zig build conformance        # decoded values must match Pkl's own description; needs Pkl
zig build fuzz               # bounded; tune with -Dfuzz-iterations and -Dfuzz-seed
zig build check-links        # relative links in Markdown files
zig build examples           # build and run every program in examples/; needs Pkl
zig build docs               # API reference in zig-out/docs
zig build site               # website in site/.output/public; needs Bun
zig build codegen            # regenerate checked-in bindings; needs Pkl
zig build codegen-test       # generator tests; live parts skip without Pkl unless ZIG_PKL_REQUIRE_PKL=1
zig build bench -Doptimize=ReleaseFast -Dpkl=/path/to/pkl
```

## Code generation

`zig-pkl-gen` generates Zig types, with `decode`, `deinit`, and `load` helpers, from Pkl modules annotated with the `@zig` package in [`codegen/`](codegen):

```sh
zig-pkl-gen --library path/to/zig-pkl --project-dir . -o src/bindings pkl/Service.pkl
```

See [docs/codegen.md](docs/codegen.md) for the type mapping, annotations, and build integration, and [examples/codegen](examples/codegen) for a consumer package.

## Limitations

- On POSIX the server runs in its own process group. Shutdown signals the whole group, including processes left behind after the server exits on its own; a process that moves to another group is out of reach. On Windows only the direct child is terminated. A descendant that still holds the server's pipes can delay shutdown until it exits.
- A timed-out or cancelled request stops waiting on the client side. The server finishes or abandons the work on its own.

## Performance

Same-run comparison with pkl-zig: [docs/benchmarks/comparison.md](docs/benchmarks/comparison.md). The frozen baseline and release gates: [docs/benchmarks/baseline.md](docs/benchmarks/baseline.md).

## Documentation

Guides:

- [Installation](docs/guides/installation.md) and [quick start](docs/guides/quickstart.md)
- [Evaluation](docs/guides/evaluation.md): typed and dynamic values, expressions, module output
- [Projects](docs/guides/projects.md)
- [Security](docs/guides/security.md): allow lists, environment, HTTP
- [Readers](docs/guides/readers.md) and [external readers](docs/guides/external-readers.md)
- [Logging](docs/guides/logging.md)
- [Concurrency](docs/guides/concurrency.md): timeouts and cancellation
- [Errors](docs/guides/errors.md)
- [Memory ownership](docs/guides/ownership.md)
- [Version compatibility](docs/guides/compatibility.md)
- [Migrating from pkl-zig](docs/guides/migration.md)

`zig build docs` writes the API reference to `zig-out/docs`. `zig build site` generates the website from these guides, the examples, the benchmark results, and the API reference into `site/.output/public`; run `bun install` in `site/` first. The Docs workflow publishes it to <https://guanchzhou.github.io/zig-pkl/>.

## Project

- [Contributing](CONTRIBUTING.md)
- [Security](SECURITY.md)
- [Code of conduct](CODE_OF_CONDUCT.md)
- [Changelog](CHANGELOG.md)

## License

Apache-2.0. Copyright 2026 Andrey Maltsev.
