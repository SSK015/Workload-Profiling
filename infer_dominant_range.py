#!/usr/bin/env python3
"""
Infer a "dominant" virtual address range from perf script output.

Reads lines like:
  59156.754553:   cpu/mem-loads/pp:     7f92c90f543c

Groups addresses into 1GB buckets (addr >> 30) and returns:
  <min_hex> <max_hex> <count>

This is useful when the original process is gone and /proc/<pid>/maps is unavailable.
"""

from __future__ import annotations

import argparse
import re
import sys
from collections import Counter


LINE_RE = re.compile(r"([0-9a-fA-F]+)\s*$")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--bucket-bits", type=int, default=30, help="Bucket size as power of two (30 => 1GB)")
    p.add_argument(
        "--user-only",
        action="store_true",
        default=True,
        help="Ignore kernel/sentinel addresses; keep only canonical lower-half user VAs (<0x0000800000000000)",
    )
    return p.parse_args()


def main() -> int:
    args = parse_args()
    shift = int(args.bucket_bits)
    user_max = 0x0000800000000000

    counts: Counter[int] = Counter()
    mins: dict[int, int] = {}
    maxs: dict[int, int] = {}

    for line in sys.stdin:
        m = LINE_RE.search(line)
        if not m:
            continue
        a = int(m.group(1), 16)
        if a == 0:
            continue
        if args.user_only and a >= user_max:
            continue
        b = a >> shift
        counts[b] += 1
        if b not in mins or a < mins[b]:
            mins[b] = a
        if b not in maxs or a > maxs[b]:
            maxs[b] = a

    if not counts:
        return 1

    best, cnt = counts.most_common(1)[0]
    sys.stdout.write(f"{mins[best]:#x} {maxs[best]:#x} {cnt}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())


