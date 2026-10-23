Rounds: pkl-zig 21, zig-pkl 21. Figures are medians.

| Case | pkl-zig | zig-pkl | Speedup | pkl-zig allocations | zig-pkl allocations |
| --- | ---: | ---: | ---: | ---: | ---: |
| decode_config | 206.2 MiB/s | 677.4 MiB/s | 3.29x | 1962 | 8 |
| decode_mixed | 239.8 MiB/s | 681.5 MiB/s | 2.84x | 1821 | 8 |
| typed_config | 189.4 MiB/s | 526.7 MiB/s | 2.78x | 2284 | 330 |
| cold evaluator | 8.95 ms | 8.77 ms | 1.02x | | |
| warm evaluate | 30.73 us | 25.32 us | 1.21x | | |

| Gate | Requirement | Result | Verdict |
| --- | --- | --- | --- |
| Codec speed | geometric mean at least 1.25x | 2.96x | pass |
| Allocations | at least 25% fewer in every codec case | see table | pass |
| Cold evaluator | at most 5% slower | -2.0% | pass |
| Warm evaluate | at most 5% slower | -17.6% | pass |
