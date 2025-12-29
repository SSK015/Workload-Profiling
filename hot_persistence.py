#!/usr/bin/env python3
"""
Hot-page persistence plot (like "still hot after Δt").

Input: perf script output with fields time,event,addr, e.g.:
  50858.386645:   cpu/mem-loads/pp:     7a6c1a8214c0

Method:
  - Define a baseline window [ref_start, ref_start+ref_window)
  - Find Top-K hottest pages in that window (by sample count)
  - For later time bins, compute Top-K pages per bin and measure
      %still_hot = |baseline_hot ∩ bin_hot| / |baseline_hot| * 100

Outputs a bar chart.
"""

from __future__ import annotations

import argparse
import re
from collections import Counter
from pathlib import Path
import sys

import matplotlib.pyplot as plt


LINE_RE = re.compile(
    r"^\s*(?P<time>[0-9]+(?:\.[0-9]+)?)\s*:?\s+(?P<event>\S+?)\s*:?\s+(?P<addr>[0-9a-fA-F]+)\s*$"
)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--input", required=True, help="perf script txt (time,event,addr)")
    p.add_argument("--output", required=True, help="Output PNG path")
    p.add_argument("--title", default="Hot-page persistence", help="Figure title")
    p.add_argument("--event-filter", default="cpu/mem-loads/pp", help="Keep only this perf event")

    p.add_argument("--addr-min", default=None, help="Filter: keep addresses >= this hex (e.g. 0x7000...)")
    p.add_argument("--addr-max", default=None, help="Filter: keep addresses < this hex (e.g. 0x7000...)")

    p.add_argument("--page-size", type=int, default=4096, help="Page size for bucketing")

    p.add_argument("--ref-start", type=float, default=0.0, help="Baseline window start (sec, relative)")
    p.add_argument("--ref-window", type=float, default=1.0, help="Baseline window duration (sec)")
    p.add_argument("--topk", type=int, default=1024, help="Define 'hot' as Top-K pages")

    p.add_argument("--bin", type=float, default=5.0, help="Bin size (sec) after baseline")
    p.add_argument("--max-time", type=float, default=None, help="Only consider samples up to this time (sec, relative)")

    p.add_argument("--dpi", type=int, default=180, help="Output DPI")
    return p.parse_args()


def topk_pages(counter: Counter[int], k: int) -> set[int]:
    if not counter:
        return set()
    # Counter.most_common is efficient enough for our K
    return {p for p, _ in counter.most_common(k)}


def main() -> int:
    args = parse_args()
    in_path = Path(args.input) if args.input != "-" else None
    out_path = Path(args.output)

    addr_min = int(args.addr_min, 16) if args.addr_min else None
    addr_max = int(args.addr_max, 16) if args.addr_max else None

    ref_start = float(args.ref_start)
    ref_end = ref_start + float(args.ref_window)
    if ref_end <= ref_start:
        raise SystemExit("--ref-window must be > 0")

    bin_size = float(args.bin)
    if bin_size <= 0:
        raise SystemExit("--bin must be > 0")

    baseline = Counter[int]()
    bins: dict[int, Counter[int]] = {}

    page_mask = ~(args.page_size - 1)

    t0: float | None = None
    t_last: float | None = None

    f = sys.stdin if in_path is None else in_path.open("r", encoding="utf-8", errors="ignore")
    with f:
        for line in f:
            m = LINE_RE.match(line)
            if not m:
                continue
            ev = m.group("event").rstrip(":")
            if ev != args.event_filter:
                continue
            t_abs = float(m.group("time"))
            a = int(m.group("addr"), 16)
            if a == 0:
                continue
            if addr_min is not None and a < addr_min:
                continue
            if addr_max is not None and a >= addr_max:
                continue

            if t0 is None:
                t0 = t_abs
            t_last = t_abs

            t = t_abs - t0
            if t < 0:
                continue
            if args.max_time is not None and t > float(args.max_time):
                continue

            page = (a & page_mask)
            if ref_start <= t < ref_end:
                baseline[page] += 1
            elif t >= ref_end:
                idx = int((t - ref_end) // bin_size)
                bins.setdefault(idx, Counter())[page] += 1

    if t0 is None or t_last is None:
        raise SystemExit(f"No samples found for event '{args.event_filter}' in {args.input}")

    base_hot = topk_pages(baseline, int(args.topk))
    if not base_hot:
        raise SystemExit("Baseline window has no samples; increase --ref-window or adjust filtering.")

    max_idx = max(bins.keys(), default=-1)
    if max_idx < 0:
        raise SystemExit("No samples found after baseline window; increase --max-time/recording duration.")

    pct_still_hot: list[float] = []
    xs_min: list[float] = []
    for i in range(max_idx + 1):
        hot_i = topk_pages(bins.get(i, Counter()), int(args.topk))
        if not hot_i:
            pct = 0.0
        else:
            pct = 100.0 * (len(base_hot & hot_i) / len(base_hot))
        pct_still_hot.append(pct)
        xs_min.append((ref_end + i * bin_size) / 60.0)

    fig = plt.figure(figsize=(7.2, 3.4), dpi=args.dpi)
    ax = fig.add_subplot(1, 1, 1)

    ax.bar(xs_min, pct_still_hot, width=(bin_size / 60.0) * 0.9, align="edge")
    ax.set_title(args.title)
    ax.set_xlabel("Time elapsed (minutes)")
    ax.set_ylabel("% of pages still hot")
    ax.set_ylim(0, 100)
    ax.grid(axis="y", alpha=0.25)

    # Annotate baseline definition
    ax.text(
        0.01,
        0.02,
        f"baseline=[{ref_start:.2f},{ref_end:.2f})s  TopK={len(base_hot)}  bin={bin_size:.1f}s",
        transform=ax.transAxes,
        fontsize=9,
        alpha=0.85,
    )

    fig.tight_layout()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    # Save with a solid background for maximum viewer compatibility
    fig.savefig(out_path, bbox_inches="tight", facecolor="white", transparent=False)
    print(f"Wrote {out_path} (baseline_hot={len(base_hot)} bins={max_idx + 1})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())


