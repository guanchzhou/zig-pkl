# Benchmark baseline

Frozen comparison point for zig-pkl. The numbers are measurements of [pkl-zig](https://github.com/burakssen/pkl-zig) at `6a113ab90fcf1fe6f504208893aab09e4ea72e1e`. They are not zig-pkl results.

Machine-readable record: [baseline.json](baseline.json).

## Environment

| Item | Value |
| --- | --- |
| Commit | `6a113ab90fcf1fe6f504208893aab09e4ea72e1e` |
| Zig | 0.16.0 |
| Pkl | 0.32.2 |
| Host | macOS arm64 |

## Observations

| Measurement | Result |
| --- | --- |
| Unit tests | 11.24 s |
| Integration tests | 8.47 s |
| Code generation | 6.72 s |
| Original fixture | 9120 bytes |
| Decoder throughput, seven runs | median 180.134 MiB/s (min 178.066, max 182.971) |
| Decoder allocations | 1960 per decode |
| Decoder requested bytes | 201916 per decode |
| Cached cold evaluator | median 7.852625 ms (min 7.642167, max 7.994875) |
| First uncached evaluator observation | 73.4435 ms |
| Warm evaluator | median 31.54625 µs (min 31.07333, max 34.48375) |

Decoder throughput is mebibytes per second. The cached cold median does not include the single uncached observation of 73.4435 ms. Unit, integration, and codegen durations are single recorded observations.

## Release gates

Releases are judged on the same run against this baseline. The absolute timings above are the record of that environment. They are not CI pass or fail thresholds.

| Gate | Requirement |
| --- | --- |
| CPU-bound codec | Geometric mean speed at least 1.25× |
| Allocations | At least 25% fewer per decode than 1960 |
| Server-bound operations | Within 5% |

The codec gate applies to CPU-bound codec and decoder benchmarks. The allocation gate applies to every codec case. The server-bound gate allows zig-pkl to be at most 5% slower than pkl-zig on operations limited by the Pkl server; being faster always passes. zig-pkl must also keep the baseline behavior of this pkl-zig revision.

[comparison.md](comparison.md) describes the same-run benchmark that applies these gates.
