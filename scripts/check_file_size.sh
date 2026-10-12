#!/bin/sh
# File line budget: any single file >1800 lines fails (anti "god file" gate).
# POSIX sh compatible (build.zig invokes it via /bin/sh).
# Usage: scripts/check_file_size.sh [max_lines]   (default 1800)
set -eu

MAX="${1:-1800}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

FILES=$(find "$ROOT/src" -name '*.zig' -type f 2>/dev/null
        [ -f "$ROOT/build.zig" ] && echo "$ROOT/build.zig")

for f in $FILES; do
    lines=$(wc -l < "$f" | tr -d ' ')
    if [ "$lines" -gt "$MAX" ]; then
        echo "TOO BIG: $f ($lines > $MAX lines)"
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "lint-size: FAILED (limit ${MAX} lines/file)"
    exit 1
fi
echo "lint-size: OK (all files <= ${MAX} lines)"
