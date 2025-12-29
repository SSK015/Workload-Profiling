#!/usr/bin/env python3
"""
Infer a dominant virtual-address range from perf script text output.

Reads lines like:
  59156.754553:   cpu/mem-loads/pp:     7f92c90f543c

Outputs:
  <min_hex> <max_hex> <count>

By default:
  - Only uses event == cpu/mem-loads/pp
  - Buckets by 1GB (addr >> 30) and picks the bucket with the most samples
"""

from __future__ import annotations

import argparse
import re
import sys
from collections import Counter


LINE_RE = re.compile(
    r"^\s*(?P<time>[0-9]+(?:\.[0-9]+)?)\s*:?\s+(?P<event>\S+?)\s*:?\s+(?P<addr>[0-9a-fA-F]+)\s*$"
)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--event", default="cpu/mem-loads/pp", help="Only keep matching event")
    p.add_argument("--bucket-bits", type=int, default=30, help="Bucket size as 2^bits (30=1GB)")
    p.add_argument("--mode", choices=["dominant", "window"], default="dominant",
                   help="dominant: pick most-sampled bucket; window: pick best contiguous window of buckets")
    p.add_argument("--window-gb", type=int, default=12,
                   help="If mode=window and bucket-bits=30, pick this many 1GB buckets as the range")
    p.add_argument("--window-strategy", choices=["best", "min", "max", "around"], default="around",
                   help="If mode=window: best=maximize samples; min=lowest-address window; max=highest-address window; around=center around dominant bucket")
    p.add_argument("--min-bucket-samples", type=int, default=1000,
                   help="Ignore buckets with < this many samples when choosing window (filters tiny outliers)")
    p.add_argument("--max-lines", type=int, default=200_000, help="Stop after reading this many matching lines")
    return p.parse_args()


def main() -> int:
    args = parse_args()
    bucket_shift = int(args.bucket_bits)
    max_lines = int(args.max_lines)

    counts: Counter[int] = Counter()
    mins: dict[int, int] = {}
    maxs: dict[int, int] = {}

    n = 0
    for line in sys.stdin:
        m = LINE_RE.match(line)
        if not m:
            continue
        ev = m.group("event").rstrip(":")
        if ev != args.event:
            continue
        a = int(m.group("addr"), 16)
        if a == 0:
            continue
        b = a >> bucket_shift
        counts[b] += 1
        mins[b] = a if b not in mins or a < mins[b] else mins[b]
        maxs[b] = a if b not in maxs or a > maxs[b] else maxs[b]
        n += 1
        if n >= max_lines:
            break

    if not counts:
        return 1

    # Filter out tiny outlier buckets if requested (only affects window selection).
    if args.mode == "window" and args.min_bucket_samples > 0:
        thr = int(args.min_bucket_samples)
        counts = Counter({b: c for b, c in counts.items() if c >= thr})
        mins = {b: mins[b] for b in counts.keys()}
        maxs = {b: maxs[b] for b in counts.keys()}
        if not counts:
            return 1

    if args.mode == "dominant":
        best = counts.most_common(1)[0][0]
        print(hex(mins[best]), hex(maxs[best]), counts[best])
        return 0

    # mode == window
    w = max(1, int(args.window_gb))
    b_min = min(counts.keys())
    b_max = max(counts.keys())
    if args.window_strategy == "min":
        best_s = b_min
        best_sum = sum(counts.get(b, 0) for b in range(best_s, best_s + w))
    elif args.window_strategy == "max":
        best_s = max(b_min, b_max - w + 1)
        best_sum = sum(counts.get(b, 0) for b in range(best_s, best_s + w))
    elif args.window_strategy == "around":
        dom = counts.most_common(1)[0][0]
        best_s = dom - (w // 2)
        best_s = max(b_min, min(best_s, b_max - w + 1))
        best_sum = sum(counts.get(b, 0) for b in range(best_s, best_s + w))
    else:
        # Search best contiguous window [s, s+w)
        best_s = b_min
        best_sum = -1
        # Sliding window over integer bucket indices (missing buckets count as 0)
        current = 0
        # initialize window at b_min
        for b in range(b_min, b_min + w):
            current += counts.get(b, 0)
        best_sum = current
        best_s = b_min
        for s in range(b_min + 1, b_max - w + 2):
            current -= counts.get(s - 1, 0)
            current += counts.get(s + w - 1, 0)
            if current > best_sum:
                best_sum = current
                best_s = s

    start_addr = best_s << bucket_shift
    end_addr_excl = (best_s + w) << bucket_shift
    # Refine min/max using observed samples inside the chosen window
    window_mins = [mins[b] for b in range(best_s, best_s + w) if b in mins]
    window_maxs = [maxs[b] for b in range(best_s, best_s + w) if b in maxs]
    out_min = min(window_mins) if window_mins else start_addr
    out_max = max(window_maxs) if window_maxs else (end_addr_excl - 1)
    print(hex(out_min), hex(out_max), best_sum)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())


