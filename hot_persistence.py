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
    p.add_argument(
        "--plot-backend",
        choices=["auto", "hachimiku", "matplotlib"],
        default="matplotlib",
        help="Plotting backend (default: matplotlib; use 'hachimiku' to opt in)",
    )
    p.add_argument(
        "--hachimiku-dir",
        default="/mnt/nfs/xiayanwen/research/demos/plot/hachimiku",
        help="Path to hachimiku package dir (only used when plot-backend=auto|hachimiku)",
    )

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


def _try_import_hachimiku(hachimiku_dir: str) -> "type | None":
    """
    Best-effort import for the user's plotting library.

    hachimiku_dir is expected to be the package directory (ending with /hachimiku),
    so we add its parent to sys.path.
    """
    try:
        from hachimiku import BarChart  # type: ignore

        return BarChart
    except Exception:
        pass

    # Try adding path dynamically
    try:
        p = Path(hachimiku_dir).resolve()
        parent = str(p.parent)
        if parent not in sys.path:
            sys.path.insert(0, parent)
        from hachimiku import BarChart  # type: ignore

        return BarChart
    except Exception:
        return None


def _render_bar_hachimiku(
    *,
    title: str,
    values: list[float],
    labels: list[str],
    xlabel: str,
    ylabel: str,
    out_path: Path,
    annotation: str | None,
    hachimiku_dir: str,
) -> bool:
    BarChart = _try_import_hachimiku(hachimiku_dir)
    if BarChart is None:
        return False

    # Use hachimiku for style/layout, but save ourselves to enforce white background.
    bar = BarChart(figsize=(10, 3.6))
    fig = bar.create_simple_bar_chart(
        values=values,
        labels=labels,
        title=title,
        xlabel=xlabel,
        ylabel=ylabel,
        show=False,
        show_xticks=True,
        show_legend=False,
        base_fontsize=14,
        tick_fontsize=12,
        title_fontsize=16,
    )

    ax = fig.axes[0] if fig.axes else None
    if ax is not None and annotation:
        ax.text(
            0.01,
            0.02,
            annotation,
            transform=ax.transAxes,
            fontsize=10,
            alpha=0.85,
        )

    out_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_path, bbox_inches="tight", facecolor="white", transparent=False, dpi=300)
    plt.close(fig)
    return True


def _render_bar_matplotlib(
    *,
    title: str,
    values: list[float],
    labels: list[str],
    xlabel: str,
    ylabel: str,
    out_path: Path,
    annotation: str | None,
    dpi: int,
) -> None:
    fig = plt.figure(figsize=(10.0, 3.6), dpi=dpi)
    ax = fig.add_subplot(1, 1, 1)

    xs = list(range(len(values)))
    ax.bar(xs, values, width=0.85, color="#1f77b4")
    ax.set_title(title)
    ax.set_xlabel(xlabel)
    ax.set_ylabel(ylabel)
    ax.set_ylim(0, 100)
    ax.grid(axis="y", alpha=0.25)

    ax.set_xticks(xs)
    ax.set_xticklabels(labels, rotation=0, fontsize=10)

    if annotation:
        ax.text(
            0.01,
            0.02,
            annotation,
            transform=ax.transAxes,
            fontsize=10,
            alpha=0.85,
        )

    fig.tight_layout()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_path, bbox_inches="tight", facecolor="white", transparent=False)
    plt.close(fig)


def _ensure_png_rgb(out_path: Path) -> None:
    """
    Some viewers (and some tooling) can be picky about PNGs with alpha (RGBA).
    If possible, rewrite the output PNG as RGB.
    """
    if out_path.suffix.lower() != ".png":
        return
    try:
        from PIL import Image  # type: ignore

        img = Image.open(out_path)
        if img.mode == "RGBA":
            img = img.convert("RGB")
            img.save(out_path)
    except Exception:
        # Best effort only
        return


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
    bin_labels: list[str] = []
    for i in range(max_idx + 1):
        hot_i = topk_pages(bins.get(i, Counter()), int(args.topk))
        if not hot_i:
            pct = 0.0
        else:
            pct = 100.0 * (len(base_hot & hot_i) / len(base_hot))
        pct_still_hot.append(pct)

        # Label bins (use seconds for short runs, otherwise minutes)
        start_s = ref_end + i * bin_size
        end_s = ref_end + (i + 1) * bin_size
        total_s = ref_end + (max_idx + 1) * bin_size
        if total_s < 5 * 60:
            bin_labels.append(f"{start_s:.0f}-{end_s:.0f}s")
            xlabel = "Time elapsed (seconds)"
        else:
            bin_labels.append(f"{start_s/60.0:.2f}-{end_s/60.0:.2f}m")
            xlabel = "Time elapsed (minutes)"

    annotation = f"baseline=[{ref_start:.2f},{ref_end:.2f})s  TopK={len(base_hot)}  bin={bin_size:.1f}s"
    ylabel = "% of pages still hot"

    use_hachimiku = False
    if args.plot_backend in ("auto", "hachimiku"):
        use_hachimiku = _render_bar_hachimiku(
            title=args.title,
            values=pct_still_hot,
            labels=bin_labels,
            xlabel=xlabel,
            ylabel=ylabel,
            out_path=out_path,
            annotation=annotation,
            hachimiku_dir=args.hachimiku_dir,
        )
        if args.plot_backend == "hachimiku" and not use_hachimiku:
            raise SystemExit(
                f"plot-backend=hachimiku requested but import failed. Set --hachimiku-dir or install it. Tried: {args.hachimiku_dir}"
            )

    if not use_hachimiku:
        _render_bar_matplotlib(
            title=args.title,
            values=pct_still_hot,
            labels=bin_labels,
            xlabel=xlabel,
            ylabel=ylabel,
            out_path=out_path,
            annotation=annotation,
            dpi=int(args.dpi),
        )

    _ensure_png_rgb(out_path)
    print(f"Wrote {out_path} (baseline_hot={len(base_hot)} bins={max_idx + 1})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())


