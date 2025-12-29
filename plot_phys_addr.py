#!/usr/bin/env python3
"""
Plot Physical Address vs Time from perf script output.

Input: a text file where each line contains:
  <time_sec> <event_name> <phys_addr_hex>

Example line (from perf script -F time,event,phys_addr):
  1302.847157 cpu/mem-loads/pp 7eb6c026ef00

Output: a PNG similar to a "GUPS" physical address heatmap.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path
import random
import sys

import matplotlib.pyplot as plt


# perf script -F time,event,addr (or phys_addr) often formats like:
#   50858.386645:   cpu/mem-loads/pp:     7fff0cba3bb0
# so we accept optional ':' after time and event.
LINE_RE = re.compile(
    r"^\s*(?P<time>[0-9]+(?:\.[0-9]+)?)\s*:?\s+(?P<event>\S+?)\s*:?\s+(?P<addr>[0-9a-fA-F]+)\s*$"
)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--input", required=True, help="Input file (time event phys_addr)")
    p.add_argument("--output", required=True, help="Output PNG path")
    p.add_argument("--title", default="GUPS", help="Plot title")
    p.add_argument("--event-filter", default="cpu/mem-loads/pp", help="Only keep matching event")
    p.add_argument("--ylabel", default="Physical address", help="Y axis label")
    p.add_argument("--addr-min", default=None, help="Filter: keep addresses >= this hex (e.g. 0x7000...)")
    p.add_argument("--addr-max", default=None, help="Filter: keep addresses < this hex (e.g. 0x7000...)")
    p.add_argument("--y-offset", action="store_true", help="Plot Y as (addr - addr_min) if addr_min is set")
    p.add_argument("--max-points", type=int, default=2_000_000, help="Downsample to at most this many points")
    p.add_argument("--gridsize", type=int, default=300, help="Hexbin grid size (higher = finer)")
    p.add_argument("--dpi", type=int, default=180, help="Output DPI")
    return p.parse_args()


def main() -> int:
    args = parse_args()
    in_path = Path(args.input) if args.input != "-" else None
    out_path = Path(args.output)

    addr_min = int(args.addr_min, 16) if args.addr_min else None
    addr_max = int(args.addr_max, 16) if args.addr_max else None

    times: list[float] = []
    phys: list[int] = []
    n_seen = 0
    t0: float | None = None

    f = sys.stdin if in_path is None else in_path.open("r", encoding="utf-8", errors="ignore")
    with f:
        for line in f:
            m = LINE_RE.match(line)
            if not m:
                continue
            ev = m.group("event").rstrip(":")
            # perf script sometimes aligns with spaces and keeps suffixes.
            if ev != args.event_filter:
                continue
            t = float(m.group("time"))
            if t0 is None:
                t0 = t
            pa = int(m.group("addr"), 16)
            if pa == 0:
                continue
            if addr_min is not None and pa < addr_min:
                continue
            if addr_max is not None and pa >= addr_max:
                continue
            # Normalize time as we read (perf script times are monotonic)
            t_rel = t - t0
            n_seen += 1

            # Stream downsample with reservoir sampling capped at max_points
            if len(times) < args.max_points:
                times.append(t_rel)
                phys.append(pa)
            else:
                j = random.randrange(n_seen)
                if j < args.max_points:
                    times[j] = t_rel
                    phys[j] = pa

    if not times:
        raise SystemExit(f"No samples found for event '{args.event_filter}' in {args.input}")

    # Optionally plot offset addresses for readability
    if args.y_offset and addr_min is not None:
        phys = [p - addr_min for p in phys]

    fig = plt.figure(figsize=(6.2, 4.6), dpi=args.dpi)
    ax = fig.add_subplot(1, 1, 1)

    hb = ax.hexbin(
        times,
        phys,
        gridsize=args.gridsize,
        bins="log",
        mincnt=1,
        cmap="Blues",
    )

    ax.set_title(args.title)
    ax.set_xlabel("Time (sec)")
    ax.set_ylabel(args.ylabel)

    cbar = fig.colorbar(hb, ax=ax)
    cbar.set_label("log10(samples)")

    fig.tight_layout()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    # Save with a solid background for maximum viewer compatibility
    fig.savefig(out_path, bbox_inches="tight", facecolor="white", transparent=False)
    print(f"Wrote {out_path} (points={len(times)})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())


