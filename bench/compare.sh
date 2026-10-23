#!/usr/bin/env bash
# Runs the zig-pkl and pkl-zig benchmarks in the same job and applies the
# release gates from docs/benchmarks/baseline.md.
#
# Usage: bench/compare.sh [rounds]
#   ZIG       Zig 0.17.0 executable (default: zig)
#   ZIG_0_16  Zig 0.16.0 executable, required by pkl-zig 6a113ab
#   PKL_EXEC  pkl executable (default: pkl)
#   OUT       output directory (default: zig-out/bench)
#
# Each library runs once unrecorded, then the rounds alternate which library
# goes first. Results land in $OUT as JSON lines plus summary.json and
# summary.md. The exit status is nonzero when a gate fails.
set -euo pipefail

rounds=${1:-7}
root=$(cd "$(dirname "$0")/.." && pwd)
zig=${ZIG:-zig}
zig016=${ZIG_0_16:?set ZIG_0_16 to a Zig 0.16.0 executable}
pkl=${PKL_EXEC:-pkl}
out=${OUT:-$root/zig-out/bench}
fixtures=$root/bench/fixtures

mkdir -p "$out"
: >"$out/zig-pkl.jsonl"
: >"$out/pkl-zig.jsonl"

(cd "$root" && "$zig" build bench -Doptimize=ReleaseFast -Dpkl="$pkl" >/dev/null)
(cd "$root/bench/pkl-zig" && "$zig016" build -Doptimize=ReleaseFast)
ours=$root/zig-out/bin/bench-zig-pkl
base=$root/bench/pkl-zig/zig-out/bin/bench-pkl-zig
"$base" "$fixtures" "$pkl" >/dev/null

for round in $(seq 1 "$rounds"); do
  if ((round % 2)); then
    "$ours" "$fixtures" "$pkl" >>"$out/zig-pkl.jsonl"
    "$base" "$fixtures" "$pkl" >>"$out/pkl-zig.jsonl"
  else
    "$base" "$fixtures" "$pkl" >>"$out/pkl-zig.jsonl"
    "$ours" "$fixtures" "$pkl" >>"$out/zig-pkl.jsonl"
  fi
  echo "round $round of $rounds done" >&2
done

{
  printf '{\n'
  printf '  "zig": "%s",\n' "$("$zig" version)"
  printf '  "zig_0_16": "%s",\n' "$("$zig016" version)"
  printf '  "pkl": "%s",\n' "$("$pkl" --version | head -n 1)"
  printf '  "os": "%s",\n' "$(uname -s)"
  printf '  "arch": "%s",\n' "$(uname -m)"
  printf '  "commit": "%s",\n' "$(git -C "$root" rev-parse HEAD 2>/dev/null || echo unknown)"
  printf '  "rounds": %s\n' "$rounds"
  printf '}\n'
} >"$out/environment.json"

cd "$root"
"$zig" run bench/gates.zig -- "$out/pkl-zig.jsonl" "$out/zig-pkl.jsonl" "$out"
