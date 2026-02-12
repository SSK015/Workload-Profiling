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
import sys
from collections import Counter


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
    p.add_argument(
        "--window-output",
        choices=["observed", "full"],
        default="observed",
        help=(
            "When mode=window: "
            "observed=return min/max of observed samples within the chosen window (default); "
            "full=return exact window bounds [start, start+window) so the plotted Y span matches WINDOW_GB."
        ),
    )
    p.add_argument("--max-lines", type=int, default=200_000, help="Stop after reading this many matching lines")
    p.add_argument(
        "--keep-kernel",
        action="store_true",
        help="Keep kernel-space virtual addresses (>= 0x8000...). Default is to drop them to avoid huge address spans.",
    )
    p.add_argument(
        "--drop-top-buckets",
        type=int,
        default=0,
        help=(
            "Drop this many highest-address buckets before selecting dominant/window. "
            "Useful to ignore the stack/vdso region when it dominates samples."
        ),
    )
    return p.parse_args()


def main() -> int:
    args = parse_args()
    bucket_shift = int(args.bucket_bits)
    max_lines = int(args.max_lines)
    event_b = args.event.encode("ascii", "ignore")
    drop_kernel = not bool(args.keep_kernel)

    counts: Counter[int] = Counter()
    mins: dict[int, int] = {}
    maxs: dict[int, int] = {}

    n = 0
    # Fast parsing: perf script -F time,event,addr usually splits into:
    #   <time>: <event>: <addr>
    # We only care about event + addr, so avoid regex for speed.
    for line in sys.stdin.buffer:
        parts = line.split()
        if len(parts) < 3:
            continue
        ev = parts[-2].rstrip(b":")
        if ev != event_b:
            continue
        addr_tok = parts[-1]
        if addr_tok == b"0" or addr_tok == b"0x0":
            continue
        try:
            a = int(addr_tok, 16)
        except ValueError:
            continue
        if a == 0:
            continue
        # Filter kernel virtual addresses by default (prevents massive bucket ranges
        # if any kernel sample slips in).
        if drop_kernel and a >= 0x8000_0000_0000_0000:
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

    # Optional: drop highest-address buckets (often stack/vdso/vvar buckets).
    dt = int(getattr(args, "drop_top_buckets", 0) or 0)
    if dt > 0 and len(counts) > dt:
        for b in sorted(counts.keys(), reverse=True)[:dt]:
            counts.pop(b, None)
            mins.pop(b, None)
            maxs.pop(b, None)
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
        # Search best contiguous window [s, s+w) without iterating over the entire
        # [b_min, b_max] span (which can be enormous if there are sparse outliers).
        #
        # Key observation: the window sum only changes when the window boundary
        # crosses a bucket that has samples. So it suffices to consider candidate
        # starts derived from observed buckets.
        keys = sorted(counts.keys())
        cand: set[int] = set()
        for b in keys:
            cand.add(b)
            cand.add(b - w + 1)
        # clamp candidates into feasible range
        lo = b_min
        hi = b_max - w + 1
        if hi < lo:
            lo = hi = b_min
        cands = sorted(s for s in cand if lo <= s <= hi)
        if not cands:
            cands = [max(lo, min(b_min, hi))]

        best_s = cands[0]
        best_sum = -1
        for s in cands:
            # w is small (e.g., 12) so direct dict gets are fast.
            ssum = 0
            for off in range(w):
                ssum += counts.get(s + off, 0)
            if ssum > best_sum:
                best_sum = ssum
                best_s = s

    start_addr = best_s << bucket_shift
    end_addr_excl = (best_s + w) << bucket_shift
    # Refine min/max using observed samples inside the chosen window
    window_mins = [mins[b] for b in range(best_s, best_s + w) if b in mins]
    window_maxs = [maxs[b] for b in range(best_s, best_s + w) if b in maxs]
    if args.window_output == "full":
        # Return exact window bounds so downstream plots have a consistent axis span.
        print(hex(start_addr), hex(end_addr_excl), best_sum)
    else:
        out_min = min(window_mins) if window_mins else start_addr
        out_max = max(window_maxs) if window_maxs else (end_addr_excl - 1)
        print(hex(out_min), hex(out_max), best_sum)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())


