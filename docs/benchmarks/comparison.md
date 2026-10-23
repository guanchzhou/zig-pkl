# Same-run comparison with pkl-zig

`bench/compare.sh` builds zig-pkl with Zig 0.17.0 and [pkl-zig](https://github.com/burakssen/pkl-zig) `6a113ab` with Zig 0.16.0, runs both against the same Pkl executable, and applies the release gates in [baseline.md](baseline.md). pkl-zig is used only through its public API.

```sh
ZIG_0_16=/path/to/zig-0.16.0/zig PKL_EXEC=/path/to/pkl bench/compare.sh 21
```

## Method

- Both programs, `bench/zig-pkl.zig` and `bench/pkl-zig/src/main.zig`, run the same cases with the same iteration counts, backing allocator (`std.heap.smp_allocator`), timer, and output format.
- Codec cases decode the pkl-binary fixtures in `bench/fixtures` 2000 times after 200 unmeasured decodes. `decode_config` and `decode_mixed` build each library's dynamic value tree; `typed_config` decodes into the same Zig structs and frees them.
- Allocations count calls that reach the backing allocator, so each arena chunk counts once.
- The cold case starts `pkl server`, creates an evaluator, evaluates `(1 + 2) * 14`, and shuts down. The warm case evaluates the same expression 200 times on a running evaluator after 20 unmeasured evaluations.
- Each library runs once unrecorded, then the rounds alternate which library goes first. Reported figures are medians over the rounds.
- The fixtures are evaluated through `modulepath:` URIs, so their bytes do not depend on the checkout path. `bench/fixtures/*.pkl` regenerate them with `pkl eval --module-path bench/fixtures -f pkl-binary -o bench/fixtures/<name>.pklbin modulepath:/<name>.pkl`.

CI runs the comparison on Linux x86_64 in the `bench` job, writes the summary to the job page, and uploads the raw results.

## Results on macOS arm64

Apple M5, Pkl 0.32.2 native, 21 rounds. Raw data: [results/macos-arm64](results/macos-arm64).

| Case | pkl-zig | zig-pkl | Speedup | pkl-zig allocations | zig-pkl allocations |
| --- | ---: | ---: | ---: | ---: | ---: |
| decode_config | 206.2 MiB/s | 677.4 MiB/s | 3.29x | 1962 | 8 |
| decode_mixed | 239.8 MiB/s | 681.5 MiB/s | 2.84x | 1821 | 8 |
| typed_config | 189.4 MiB/s | 526.7 MiB/s | 2.78x | 2284 | 330 |
| cold evaluator | 8.95 ms | 8.77 ms | 1.02x | | |
| warm evaluate | 30.73 µs | 25.32 µs | 1.21x | | |

| Gate | Requirement | Result | Verdict |
| --- | --- | --- | --- |
| Codec speed | geometric mean at least 1.25x | 2.96x | pass |
| Allocations | at least 25% fewer in every codec case | 86% to 99.6% fewer | pass |
| Cold evaluator | at most 5% slower | 2.0% faster | pass |
| Warm evaluate | at most 5% slower | 17.6% faster | pass |

The cold case is bounded by Pkl server startup, which both libraries pay. zig-pkl also checks the Pkl version with `pkl --version`, which runs while the server starts.
