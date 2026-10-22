# zig-pkl

[![CI](https://github.com/guanchzhou/zig-pkl/actions/workflows/ci.yml/badge.svg)](https://github.com/guanchzhou/zig-pkl/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

Zig 0.17 bindings for [Pkl](https://pkl-lang.org/).

This package is unreleased (`0.0.0`). The module name is `zig_pkl`. The public API is not stable.

## Requirements

- Zig 0.17.0
- Pkl 0.32.2, the supported language version

## Build

```sh
zig build
zig build test
```

## Baseline

Measured comparison data and frozen release gates: [docs/benchmarks/baseline.md](docs/benchmarks/baseline.md).

## Documentation

When `site/` is present, the Docs workflow publishes it to <https://guanchzhou.github.io/zig-pkl/>.

## Project

- [Contributing](CONTRIBUTING.md)
- [Security](SECURITY.md)
- [Code of conduct](CODE_OF_CONDUCT.md)
- [Changelog](CHANGELOG.md)

## License

Apache-2.0. Copyright 2026 Andrey Maltsev.
