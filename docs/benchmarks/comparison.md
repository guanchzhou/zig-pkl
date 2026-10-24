# Same-run comparison with pkl-zig

`bench/compare.sh` builds zig-pkl with Zig 0.17.0 and [pkl-zig](https://github.com/burakssen/pkl-zig) `6a113ab` with Zig 0.16.0, runs both against the same Pkl executable, and applies the release gates in [baseline.md](baseline.md). pkl-zig is used only through its public API.

```sh
ZIG_0_16=/path/to/zig-0.16.0/zig PKL_EXEC=/path/to/pkl bench/compare.sh 21
```

## Method

- Both programs, `bench/zig-pkl.zig` and `bench/pkl-zig/src/main.zig`, run the same cases with the same iteration counts, backing allocator (`std.heap.smp_allocator`), timer, and output format.
- Codec cases decode the pkl-binary fixtures in `bench/fixtures` 2000 times after 200 unmeasured decodes. `decode_config` and `decode_mixed` build each library's dynamic value tree; `typed_config` decodes into the same Zig structs and frees them.
- Allocations count calls that reach the backing allocator, so each arena chunk counts once.
- The cold case starts `pkl server`, creates an evaluator, evaluates `(1 + 2) * 14`, and shuts down, 10 times per round after one unmeasured cycle. Each round reports the median cycle and the median of each phase. The warm case evaluates the same expression 200 times on a running evaluator after 20 unmeasured evaluations.
- Each library runs once unrecorded, then the rounds alternate which library goes first. Reported figures are medians over the rounds.
- The fixtures are evaluated through `modulepath:` URIs, so their bytes do not depend on the checkout path. `bench/fixtures/*.pkl` regenerate them with `pkl eval --module-path bench/fixtures -f pkl-binary -o bench/fixtures/<name>.pklbin modulepath:/<name>.pkl`.

CI runs the comparison on Linux x86_64 in the `bench` job, writes the summary to the job page, and uploads the raw results.

## Results on macOS arm64

Apple M5, Pkl 0.32.2 native, 31 rounds. Raw data: [results/macos-arm64](results/macos-arm64).

| Case | pkl-zig | zig-pkl | Speedup | pkl-zig allocations | zig-pkl allocations |
| --- | ---: | ---: | ---: | ---: | ---: |
| decode_config | 206.7 MiB/s | 669.7 MiB/s | 3.24x | 1962 | 8 |
| decode_mixed | 241.0 MiB/s | 554.2 MiB/s | 2.30x | 1821 | 8 |
| typed_config | 190.3 MiB/s | 531.3 MiB/s | 2.79x | 2284 | 330 |
| cold evaluator | 8.41 ms | 7.76 ms | 1.08x | | |
| warm evaluate | 31.42 µs | 25.48 µs | 1.23x | | |

| Cold phase | pkl-zig | zig-pkl |
| --- | ---: | ---: |
| start and create evaluator | 7.34 ms | 6.64 ms |
| evaluate | 0.38 ms | 0.35 ms |
| close and shut down | 0.76 ms | 0.80 ms |

| Gate | Requirement | Result | Verdict |
| --- | --- | --- | --- |
| Codec speed | geometric mean at least 1.25x | 2.75x | pass |
| Allocations | at least 25% fewer in every codec case | 86% to 99.6% fewer | pass |
| Cold evaluator | at most 5% slower | 7.7% faster | pass |
| Warm evaluate | at most 5% slower | 18.9% faster | pass |

Codec throughput on a laptop varies by about 20% between runs; the ratios are measured in the same run.

## Results on Linux x86_64

GitHub-hosted `ubuntu-24.04` runner with 2 vCPUs, Pkl 0.32.2 native, 15 rounds, from the CI `bench` job. Each CI run publishes its own summary and raw data.

| Case | pkl-zig | zig-pkl | Speedup |
| --- | ---: | ---: | ---: |
| decode_config | 110.7 MiB/s | 263.0 MiB/s | 2.38x |
| decode_mixed | 122.8 MiB/s | 215.2 MiB/s | 1.75x |
| typed_config | 102.4 MiB/s | 217.8 MiB/s | 2.13x |
| cold evaluator | 7.67 ms | 7.66 ms | 1.00x |
| warm evaluate | 109.18 µs | 91.17 µs | 1.20x |

| Cold phase | pkl-zig | zig-pkl |
| --- | ---: | ---: |
| start and create evaluator | 5.27 ms | 5.28 ms |
| evaluate | 0.50 ms | 0.48 ms |
| close and shut down | 1.79 ms | 1.88 ms |

## Cold start

The cold case is bounded by work inside Pkl that both libraries pay: starting the server and, after stdin closes, the server's own exit, which takes about 2.1 ms on the Linux runner. The remaining shutdown difference on Linux is the thread that keeps the tail of the server's stderr for error reports; pkl-zig does not capture stderr.

Measured choices, on the Linux runner unless noted:

| Choice | Effect on the cold case |
| --- | --- |
| Run `pkl --version` before starting the server, as pkl-go does | adds a full `pkl --version`, about 5.8 ms on macOS |
| Run `pkl --version` while the server starts | 17% slower than pkl-zig: the second Pkl process competes with the server |
| Run `pkl --version` only for options that need a release newer than 0.25.3 | no cost for other options |
| Start all reader workers with the manager | about 0.18 ms per thread at start and 0.25 ms to join them at shutdown |
| Start reader workers when callbacks arrive | no cost without module or resource readers |
| Poll for server exit every 100 µs | wakes up to 100 µs late; shutdown about 0.1 ms slower on macOS, no measurable difference on Linux |
| Wait on a pidfd (Linux) or kqueue (macOS) | wakes when the server exits; polling remains the fallback |
| Kill the server instead of waiting for it to exit | about 0.6 ms faster on macOS, but external readers and loggers lose their close notification; rejected |
