Rounds: pkl-zig 31, zig-pkl 31. Figures are medians.

| Case | pkl-zig | zig-pkl | Speedup | pkl-zig allocations | zig-pkl allocations |
| --- | ---: | ---: | ---: | ---: | ---: |
| decode_config | 206.7 MiB/s | 669.7 MiB/s | 3.24x | 1962 | 8 |
| decode_mixed | 241.0 MiB/s | 554.2 MiB/s | 2.30x | 1821 | 8 |
| typed_config | 190.3 MiB/s | 531.3 MiB/s | 2.79x | 2284 | 330 |
| cold evaluator | 8.41 ms | 7.76 ms | 1.08x | | |
| warm evaluate | 31.42 us | 25.48 us | 1.23x | | |

| Cold phase | pkl-zig | zig-pkl |
| --- | ---: | ---: |
| start and create evaluator | 7.34 ms | 6.64 ms |
| evaluate | 0.38 ms | 0.35 ms |
| close and shut down | 0.76 ms | 0.80 ms |

| Gate | Requirement | Result | Verdict |
| --- | --- | --- | --- |
| Codec speed | geometric mean at least 1.25x | 2.75x | pass |
| Allocations | at least 25% fewer in every codec case | see table | pass |
| Cold evaluator | at most 5% slower | -7.7% | pass |
| Warm evaluate | at most 5% slower | -18.9% | pass |
