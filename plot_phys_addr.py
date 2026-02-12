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
import numpy as np
from matplotlib.colors import LogNorm
from matplotlib.ticker import FuncFormatter


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
    p.add_argument("--xlabel", default="Time (sec)", help="X axis label")
    p.add_argument("--event-filter", default="cpu/mem-loads/pp", help="Only keep matching event")
    p.add_argument("--ylabel", default="Physical address", help="Y axis label")
    p.add_argument("--addr-min", default=None, help="Filter: keep addresses >= this hex (e.g. 0x7000...)")
    p.add_argument("--addr-max", default=None, help="Filter: keep addresses < this hex (e.g. 0x7000...)")
    p.add_argument("--y-offset", action="store_true", help="Plot Y as (addr - addr_min) if addr_min is set")
    p.add_argument(
        "--auto-ylim",
        action="store_true",
        help="Auto-adjust y-axis limits to the dense address region (based on sample percentiles), "
        "clamped within the addr window if provided.",
    )
    p.add_argument(
        "--auto-ylim-lo-pct",
        type=float,
        default=0.1,
        help="Lower percentile for --auto-ylim (default: 0.1).",
    )
    p.add_argument(
        "--auto-ylim-hi-pct",
        type=float,
        default=99.9,
        help="Upper percentile for --auto-ylim (default: 99.9).",
    )
    p.add_argument(
        "--auto-ylim-pad-gb",
        type=float,
        default=0.5,
        help="Padding (GiB) added to auto y-limits (default: 0.5 GiB). GiB = 1024^3.",
    )
    p.add_argument(
        "--ymin",
        default=None,
        help="Optional: force y-axis minimum. In --y-offset mode this is an offset in bytes; otherwise an address. Accepts decimal or hex (0x...).",
    )
    p.add_argument(
        "--ymax",
        default=None,
        help="Optional: force y-axis maximum. In --y-offset mode this is an offset in bytes; otherwise an address. Accepts decimal or hex (0x...).",
    )
    p.add_argument(
        "--ymax-gb",
        type=float,
        default=None,
        help="Convenience: force y-axis to [0, N GiB] in --y-offset mode (GiB = 1024^3). Overrides --ymax/--ymin.",
    )
    p.add_argument(
        "--ymin-gb",
        type=float,
        default=None,
        help="Convenience: force y-axis minimum to N GiB in --y-offset mode (GiB = 1024^3). Can be combined with --ymax/--ymax-gb.",
    )
    p.add_argument(
        "--yspan-gb",
        type=float,
        default=None,
        help="Convenience: force y-axis span to N GiB. Useful with --ymin-gb (e.g. ymin=30, span=30 -> [30,60] GiB). GiB = 1024^3.",
    )
    p.add_argument("--max-points", type=int, default=2_000_000, help="Downsample to at most this many points")
    p.add_argument("--gridsize", type=int, default=500, help="Hexbin grid size (higher = finer)")
    p.add_argument("--dpi", type=int, default=300, help="Output DPI")
    p.add_argument(
        "--figsize",
        default="8,6",
        help='Figure size in inches as "W,H" (default: 8,6)',
    )
    p.add_argument(
        "--color-scale",
        choices=["log", "linear"],
        default="log",
        help="Color scaling for density (default: log)",
    )
    p.add_argument(
        "--plot",
        choices=["hexbin", "scatter"],
        default="hexbin",
        help="Plot type: hexbin (density) or scatter (raw points). Default: hexbin",
    )
    p.add_argument(
        "--alpha",
        type=float,
        default=1.0,
        help="Point/hex transparency (0..1). For scatter, values like 0.02-0.2 help reduce saturation.",
    )
    p.add_argument(
        "--s",
        type=float,
        default=1.0,
        help="Scatter marker size (only for --plot scatter).",
    )
    p.add_argument(
        "--vmax-percentile",
        type=float,
        default=None,
        help="Optional: cap color scale at this percentile of bin counts (e.g. 99.0) to make faint structure visible",
    )
    p.add_argument(
        "--vmax",
        type=float,
        default=None,
        help="Optional: explicit cap for color scale (overrides --vmax-percentile)",
    )
    return p.parse_args()


def _parse_int_auto(s: str) -> int:
    s = s.strip().lower()
    if s.startswith("0x"):
        return int(s, 16)
    return int(s, 10)


def _clamp(v: float, lo: float, hi: float) -> float:
    if v < lo:
        return lo
    if v > hi:
        return hi
    return v


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

    try:
        w_str, h_str = str(args.figsize).split(",", 1)
        fig_w, fig_h = float(w_str), float(h_str)
    except Exception as e:
        raise SystemExit(f"Invalid --figsize '{args.figsize}', expected 'W,H' (e.g. 10,6): {e}")

    fig = plt.figure(figsize=(fig_w, fig_h), dpi=args.dpi)
    ax = fig.add_subplot(1, 1, 1)

    hb = None
    if args.plot == "hexbin":
        hb = ax.hexbin(
            times,
            phys,
            gridsize=args.gridsize,
            mincnt=1,
            cmap="Blues",
            alpha=float(args.alpha),
        )
    else:
        ax.scatter(
            times,
            phys,
            s=float(args.s),
            alpha=float(args.alpha),
            c="#1f77b4",
            linewidths=0,
        )

    ax.set_title(args.title)
    ax.set_xlabel(args.xlabel)
    ax.set_ylabel(args.ylabel)

    # In --y-offset mode we keep data in bytes (so all filtering/limits remain
    # consistent), but we format ticks in GiB to match the default label used by
    # replot_store_window.sh ("Virtual address (GiB offset)").
    if args.y_offset:
        gib = float(1024**3)

        def _fmt_gib(v: float, _pos: int) -> str:
            return f"{v / gib:.2f}"

        ax.yaxis.set_major_formatter(FuncFormatter(_fmt_gib))
        # Hide Matplotlib's scientific offset text (e.g. "1e9") which is confusing
        # when we want explicit GiB labels.
        ax.yaxis.get_offset_text().set_visible(False)

    # If the user provided an address window, default to showing the full span
    # (legacy behavior). If --auto-ylim is set, we will tighten this later while
    # clamping within the same window.
    base_lo = None
    base_hi = None
    if addr_min is not None and addr_max is not None:
        if args.y_offset:
            base_lo, base_hi = 0.0, float(addr_max - addr_min)
        else:
            base_lo, base_hi = float(addr_min), float(addr_max)
        ax.set_ylim(base_lo, base_hi)

    # Optional: automatically tighten y-limits to the dense region, to avoid
    # large empty space when the window is intentionally padded.
    if args.auto_ylim:
        y = np.asarray(phys, dtype=np.float64)
        if y.size:
            lo_pct = float(args.auto_ylim_lo_pct)
            hi_pct = float(args.auto_ylim_hi_pct)
            if not (0.0 <= lo_pct < hi_pct <= 100.0):
                raise SystemExit("--auto-ylim requires 0 <= lo_pct < hi_pct <= 100")
            y_lo = float(np.percentile(y, lo_pct))
            y_hi = float(np.percentile(y, hi_pct))
            pad = float(args.auto_ylim_pad_gb) * (1024.0**3)
            # Ensure a sane span even if percentiles collapse.
            if y_hi <= y_lo:
                y_lo = float(np.min(y))
                y_hi = float(np.max(y))
            y_lo -= pad
            y_hi += pad
            # Clamp within provided window if any; otherwise keep non-negative
            # in offset mode.
            if base_lo is not None and base_hi is not None:
                y_lo = _clamp(y_lo, base_lo, base_hi)
                y_hi = _clamp(y_hi, base_lo, base_hi)
            elif args.y_offset:
                y_lo = max(0.0, y_lo)
            # Avoid zero-height range.
            if y_hi <= y_lo:
                y_hi = y_lo + 1.0
            ax.set_ylim(y_lo, y_hi)

    # Optional: explicit y-limits override address-window bounds
    if args.ymax_gb is not None:
        if not args.y_offset:
            raise SystemExit("--ymax-gb requires --y-offset (it sets an offset range [0, N GiB])")
        ax.set_ylim(0, int(args.ymax_gb * (1024**3)))
    elif args.ymin is not None or args.ymax is not None or args.ymin_gb is not None or args.yspan_gb is not None:
        cur_lo, cur_hi = ax.get_ylim()
        if args.ymin_gb is not None:
            if not args.y_offset:
                raise SystemExit("--ymin-gb requires --y-offset (it sets an offset minimum in GiB)")
            lo = int(args.ymin_gb * (1024**3))
        else:
            lo = _parse_int_auto(args.ymin) if args.ymin is not None else int(cur_lo)
        if args.yspan_gb is not None:
            hi = lo + int(args.yspan_gb * (1024**3))
        else:
            hi = _parse_int_auto(args.ymax) if args.ymax is not None else int(cur_hi)
        ax.set_ylim(lo, hi)

    if hb is not None:
        counts = hb.get_array()
        if counts.size:
            if args.vmax is not None:
                vmax = float(args.vmax)
            elif args.vmax_percentile is not None:
                vmax = float(np.percentile(counts, float(args.vmax_percentile)))
            else:
                vmax = None
        else:
            vmax = None

        if args.color_scale == "log":
            # LogNorm expects positive values; counts are >= 1 due to mincnt=1.
            if vmax is not None and vmax >= 1:
                hb.set_norm(LogNorm(vmin=1, vmax=vmax))
            else:
                hb.set_norm(LogNorm(vmin=1))
            cbar = fig.colorbar(hb, ax=ax)
            cbar.set_label("samples (log scale)")
        else:
            if vmax is not None and vmax > 0:
                hb.set_clim(0, vmax)
            cbar = fig.colorbar(hb, ax=ax)
            cbar.set_label("samples")

    fig.tight_layout()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    # Save with a solid background for maximum viewer compatibility
    fig.savefig(out_path, bbox_inches="tight", facecolor="white", transparent=False)
    print(f"Wrote {out_path} (points={len(times)})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())


