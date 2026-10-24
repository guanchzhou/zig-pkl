#!/usr/bin/env bash
# Builds the consumer package in a temporary directory against zig-pkl fetched
# from an archive path or URL, evaluates Pkl through it, and runs the fetched
# zig-pkl-gen. Prints the package hash on the last line.
#
# Usage: tests/consumer/run.sh <archive path or URL> [expected zig-pkl-gen version]
set -euo pipefail

source="$1"
expected_version="${2:-}"
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cp "$here/build.zig" "$here/build.zig.zon" "$here/main.zig" "$work/"
if [[ -e "$source" ]]; then
  source="$(cd "$(dirname "$source")" && pwd)/$(basename "$source")"
fi

cd "$work"
zig fetch --save=zig_pkl "$source" >&2
zig build run >&2
version="$(zig build generator 2>&1)"
printf '%s\n' "$version" >&2
if [[ -n "$expected_version" && "$version" != "zig-pkl-gen $expected_version" ]]; then
  echo "expected zig-pkl-gen $expected_version, got: $version" >&2
  exit 1
fi
sed -n 's/^[[:space:]]*\.hash = "\([^"]*\)".*/\1/p' build.zig.zon
