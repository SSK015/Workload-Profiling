#!/usr/bin/env python3
"""
Plot sampled store/load ratio by address-region hotness from perf data.

Definition used in this script:
1) Split address space into N equal-width regions (default: 100).
2) For each region, count load/store samples.
3) Region hotness = total samples (load + store).
4) Sort regions by hotness descending (hot -> cold) for x-axis.
5) y-axis = store/load ratio in each region.

Input supports:
- perf.data (default): decode by running `perf script -F event,addr -i <perf.data>`
- points text file: lines like "<time>: <event>: <addr>" or "<time> <event> <addr>"

Time filtering (--after-seconds / --before-seconds):
  Only supported for points files that carry a timestamp per line.
  --after-seconds 90   -> skip the first 90 s of the recording
  --before-seconds 120 -> stop at 120 s into the recording
  Both can be combined to select a slice in the middle.

Output path:
  --output is optional. When omitted the script derives a name automatically
  from the input path, window file, and time-filter settings, e.g.:
    <input_stem>_store_load_ratio[_win<wf>][_after90s][_before120s].png
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import time
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np


LINE_RE = re.compile(
    r"^\s*(?:(?P<time>[0-9]+(?:\.[0-9]+)?)\s*:?\s+)?(?P<event>\S+?)\s*:?\s+(?P<addr>[0-9a-fA-F]+)\s*$"
)

_PROGRESS_INTERVAL = 10_000_000


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Plot sampled store/load ratio by region hotness (hot -> cold).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    p.add_argument("--input", required=True, help="Input perf.data or decoded points file")
    p.add_argument(
        "--output",
        default=None,
        help=(
            "Output PNG path. If omitted, auto-derived from --input, --window-file, "
            "and time-filter options."
        ),
    )
    p.add_argument(
        "--input-type",
        choices=["auto", "perf-data", "points"],
        default="auto",
        help="Input type detection mode (default: auto)",
    )
    p.add_argument("--perf-bin", default="perf", help="perf binary path (default: perf)")
    p.add_argument("--regions", type=int, default=100, help="Number of address regions (default: 100)")
    p.add_argument(
        "--load-event",
        default="cpu/mem-loads/pp",
        help="Perf event name for load samples",
    )
    p.add_argument(
        "--store-event",
        default="cpu/mem-stores/pp",
        help="Perf event name for store samples",
    )
    p.add_argument(
        "--ratio",
        choices=["store_over_load", "store_fraction"],
        default="store_over_load",
        help=(
            "Y-axis metric: store_over_load=store/(load+eps), "
            "store_fraction=store/(store+load)."
        ),
    )
    p.add_argument(
        "--eps",
        type=float,
        default=1.0,
        help="Smoothing epsilon for store_over_load (default: 1.0)",
    )
    p.add_argument(
        "--min-total",
        type=int,
        default=1,
        help="Only keep regions with total samples >= this value (default: 1)",
    )
    p.add_argument(
        "--max-points",
        type=int,
        default=100,
        help="Max x-axis points to draw after sorting hot->cold (default: 100)",
    )
    p.add_argument(
        "--addr-min",
        default=None,
        help="Optional address lower bound (hex, inclusive), e.g. 0x7fa580000000",
    )
    p.add_argument(
        "--addr-max",
        default=None,
        help="Optional address upper bound (hex, exclusive), e.g. 0x7fb580000000",
    )
    p.add_argument(
        "--window-file",
        default=None,
        help="File containing '<addr_min> <addr_max> ...' (e.g. store_window_64g.txt)",
    )
    p.add_argument("--title", default=None, help="Plot title (auto-generated when omitted)")

    time_grp = p.add_argument_group("time filtering (points files only)")
    time_grp.add_argument(
        "--after-seconds",
        type=float,
        default=None,
        metavar="N",
        help="Discard samples in the first N seconds of the recording",
    )
    time_grp.add_argument(
        "--before-seconds",
        type=float,
        default=None,
        metavar="N",
        help="Discard samples after N seconds into the recording",
    )
    # Legacy alias kept for backward compatibility.
    time_grp.add_argument(
        "--skip-seconds",
        type=float,
        default=None,
        dest="skip_seconds",
        help=argparse.SUPPRESS,
    )
    return p.parse_args()


def detect_input_type(path: Path, mode: str) -> str:
    if mode != "auto":
        return mode
    return "perf-data" if path.suffix == ".data" else "points"


def _parse_hex_addr(s: str) -> int:
    t = s.strip().lower()
    if not t.startswith("0x"):
        raise ValueError(f"Address must start with 0x, got: {s!r}")
    return int(t, 16)


def _resolve_addr_bounds(args: argparse.Namespace) -> tuple[int | None, int | None]:
    lo = _parse_hex_addr(args.addr_min) if args.addr_min else None
    hi = _parse_hex_addr(args.addr_max) if args.addr_max else None
    if args.window_file:
        wf = Path(args.window_file)
        if not wf.exists():
            raise SystemExit(f"--window-file not found: {wf}")
        parts = wf.read_text(encoding="utf-8", errors="ignore").strip().split()
        if len(parts) < 2:
            raise SystemExit(f"--window-file format invalid (need at least 2 hex tokens): {wf}")
        lo = _parse_hex_addr(parts[0])
        hi = _parse_hex_addr(parts[1])
    if lo is not None and hi is not None and hi <= lo:
        raise SystemExit("Address bounds invalid: addr_max must be > addr_min")
    return lo, hi


def _resolve_time_bounds(
    args: argparse.Namespace,
    input_type: str,
    in_path: Path,
) -> tuple[float | None, float | None]:
    """Return (min_time, max_time) absolute timestamps, or None if no filtering."""
    # Honour legacy --skip-seconds as alias for --after-seconds.
    after = args.after_seconds
    if after is None and args.skip_seconds is not None:
        after = args.skip_seconds

    before = args.before_seconds

    if after is None and before is None:
        return None, None

    if input_type != "points":
        raise SystemExit("--after-seconds / --before-seconds are only supported with --input-type points")

    # Find the first timestamp in the file.
    first_t: float | None = None
    with in_path.open("r", encoding="utf-8", errors="ignore") as fh:
        for line in fh:
            m = LINE_RE.match(line)
            if m and m.group("time") is not None:
                try:
                    first_t = float(m.group("time"))
                    break
                except ValueError:
                    pass
    if first_t is None:
        raise SystemExit("Could not read first timestamp from input; is --input-type correct?")

    min_time = (first_t + after) if after is not None else None
    max_time = (first_t + before) if before is not None else None

    parts = []
    if min_time is not None:
        parts.append(f"after {after:.1f}s (t>={min_time:.3f})")
    if max_time is not None:
        parts.append(f"before {before:.1f}s (t<{max_time:.3f})")
    print(f"Time filter: {', '.join(parts)}")
    return min_time, max_time


def iter_event_addr_from_perf_data(perf_bin: str, perf_data: Path):
    cmd = [perf_bin, "script", "-i", str(perf_data), "-F", "event,addr"]
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="ignore",
    )
    assert proc.stdout is not None
    n = 0
    for line in proc.stdout:
        m = LINE_RE.match(line)
        if not m:
            continue
        ev = m.group("event").rstrip(":")
        try:
            addr = int(m.group("addr"), 16)
        except ValueError:
            continue
        if addr == 0:
            continue
        n += 1
        if n % _PROGRESS_INTERVAL == 0:
            print(f"  ... {n // 1_000_000}M lines read", flush=True)
        yield ev, addr
    stderr = ""
    if proc.stderr is not None:
        stderr = proc.stderr.read().strip()
    rc = proc.wait()
    if rc != 0:
        raise RuntimeError(f"`{' '.join(cmd)}` failed with exit={rc}. {stderr}")


def iter_event_addr_from_points(
    path: Path,
    min_time: float | None = None,
    max_time: float | None = None,
):
    filter_time = min_time is not None or max_time is not None
    n = 0
    with path.open("r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            m = LINE_RE.match(line)
            if not m:
                continue
            if filter_time:
                t_str = m.group("time")
                if t_str is None:
                    continue
                try:
                    t = float(t_str)
                except ValueError:
                    continue
                if min_time is not None and t < min_time:
                    continue
                if max_time is not None and t >= max_time:
                    continue
            ev = m.group("event").rstrip(":")
            try:
                addr = int(m.group("addr"), 16)
            except ValueError:
                continue
            if addr == 0:
                continue
            n += 1
            if n % _PROGRESS_INTERVAL == 0:
                print(f"  ... {n // 1_000_000}M samples kept", flush=True)
            yield ev, addr


def _auto_output_path(args: argparse.Namespace, in_path: Path) -> Path:
    stem = in_path.stem
    if args.window_file:
        wf_stem = Path(args.window_file).stem
        stem += f"_win{wf_stem}"
    after = args.after_seconds if args.after_seconds is not None else args.skip_seconds
    if after is not None:
        stem += f"_after{int(after)}s"
    if args.before_seconds is not None:
        stem += f"_before{int(args.before_seconds)}s"
    stem += "_store_load_ratio"
    return in_path.parent / f"{stem}.png"


def _auto_title(args: argparse.Namespace) -> str:
    parts = ["Store/Load Ratio by Region Hotness"]
    after = args.after_seconds if args.after_seconds is not None else args.skip_seconds
    if after is not None or args.before_seconds is not None:
        t_parts = []
        if after is not None:
            t_parts.append(f">{after:.0f}s")
        if args.before_seconds is not None:
            t_parts.append(f"<{args.before_seconds:.0f}s")
        parts.append(f"(t {' & '.join(t_parts)})")
    if args.window_file:
        parts.append(f"[{Path(args.window_file).stem}]")
    return " ".join(parts)


def main() -> int:
    args = parse_args()
    in_path = Path(args.input)
    if not in_path.exists():
        raise SystemExit(f"Input not found: {in_path}")
    if args.regions <= 0:
        raise SystemExit("--regions must be > 0")
    if args.max_points <= 0:
        raise SystemExit("--max-points must be > 0")

    out_path = Path(args.output) if args.output else _auto_output_path(args, in_path)
    title = args.title if args.title else _auto_title(args)

    input_type = detect_input_type(in_path, args.input_type)
    user_lo, user_hi = _resolve_addr_bounds(args)
    min_time, max_time = _resolve_time_bounds(args, input_type, in_path)

    def make_iter():
        if input_type == "perf-data":
            return iter_event_addr_from_perf_data(args.perf_bin, in_path)
        return iter_event_addr_from_points(in_path, min_time=min_time, max_time=max_time)

    load_event = args.load_event
    store_event = args.store_event

    # When the address window is fully specified we can skip the range-detection
    # pass and go directly to binning, saving one full read of the (large) file.
    if user_lo is not None and user_hi is not None:
        addr_min = user_lo
        addr_max = user_hi - 1
        # Still count totals for the summary line.
        load_samples = 0
        store_samples = 0
        regions = args.regions
        span = addr_max - addr_min + 1
        width = (span + regions - 1) // regions
        load_bins = np.zeros(regions, dtype=np.int64)
        store_bins = np.zeros(regions, dtype=np.int64)

        t0 = time.monotonic()
        print("Pass 1/1: binning samples ...", flush=True)
        for ev, addr in make_iter():
            if ev != load_event and ev != store_event:
                continue
            if addr < user_lo or addr >= user_hi:
                continue
            idx = min((addr - addr_min) // width, regions - 1)
            if ev == load_event:
                load_bins[int(idx)] += 1
                load_samples += 1
            else:
                store_bins[int(idx)] += 1
                store_samples += 1
        print(f"  done in {time.monotonic() - t0:.1f}s", flush=True)
    else:
        # Pass 1: detect effective address range.
        addr_min_v = None
        addr_max_v = None
        load_samples = 0
        store_samples = 0

        t0 = time.monotonic()
        print("Pass 1/2: detecting address range ...", flush=True)
        for ev, addr in make_iter():
            if ev != load_event and ev != store_event:
                continue
            if user_lo is not None and addr < user_lo:
                continue
            if user_hi is not None and addr >= user_hi:
                continue
            if ev == load_event:
                load_samples += 1
            else:
                store_samples += 1
            if addr_min_v is None or addr < addr_min_v:
                addr_min_v = addr
            if addr_max_v is None or addr > addr_max_v:
                addr_max_v = addr
        print(f"  done in {time.monotonic() - t0:.1f}s", flush=True)

        if addr_min_v is None or addr_max_v is None:
            raise SystemExit(
                f"No samples found for events load={load_event} store={store_event} "
                "under the chosen address filter"
            )
        addr_min = addr_min_v
        addr_max = addr_max_v

        if addr_max == addr_min:
            regions = 1
            width = 1
        else:
            regions = args.regions
            span = addr_max - addr_min + 1
            width = (span + regions - 1) // regions

        load_bins = np.zeros(regions, dtype=np.int64)
        store_bins = np.zeros(regions, dtype=np.int64)

        t0 = time.monotonic()
        print("Pass 2/2: binning samples ...", flush=True)
        for ev, addr in make_iter():
            if ev != load_event and ev != store_event:
                continue
            if user_lo is not None and addr < user_lo:
                continue
            if user_hi is not None and addr >= user_hi:
                continue
            idx = min((addr - addr_min) // width, regions - 1)
            if ev == load_event:
                load_bins[int(idx)] += 1
            else:
                store_bins[int(idx)] += 1
        print(f"  done in {time.monotonic() - t0:.1f}s", flush=True)

    total_bins = load_bins + store_bins
    valid_idx = np.where(total_bins >= int(args.min_total))[0]
    if valid_idx.size == 0:
        raise SystemExit("No region remains after --min-total filtering")

    order = valid_idx[np.argsort(total_bins[valid_idx])[::-1]]
    order = order[: args.max_points]

    kept_load = load_bins[order]
    kept_store = store_bins[order]
    kept_total = total_bins[order]
    kept_n = int(order.size)

    x = (
        np.array([0.0], dtype=np.float64)
        if kept_n == 1
        else np.linspace(0.0, 100.0, num=kept_n, endpoint=True, dtype=np.float64)
    )
    if args.ratio == "store_over_load":
        y = kept_store.astype(np.float64) / (kept_load.astype(np.float64) + float(args.eps))
        y_label = "Sampled store/load ratio"
    else:
        y = kept_store.astype(np.float64) / kept_total.astype(np.float64)
        y_label = "Sampled store fraction (store/(store+load))"

    subtitle = (
        f"load={load_samples:,}  store={store_samples:,}  "
        f"addr=[0x{addr_min:x}, 0x{addr_max:x}]"
    )

    fig = plt.figure(figsize=(9, 5.2), dpi=220)
    ax = fig.add_subplot(1, 1, 1)
    ax.plot(x, y, marker="o", markersize=3, linewidth=1.2)
    ax.set_title(f"{title}\n{subtitle}", fontsize=10)
    ax.set_xlabel("Address region hotness rank (0=hottest, 100=coldest)")
    ax.set_ylabel(y_label)
    ax.set_xlim(0, 100)
    ax.grid(True, linestyle="--", linewidth=0.5, alpha=0.45)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    fig.tight_layout()
    fig.savefig(out_path, bbox_inches="tight", facecolor="white", transparent=False)

    print(f"\nWrote: {out_path}")
    print(f"input_type={input_type}  regions_kept={kept_n}")
    print(f"load_samples={load_samples:,}  store_samples={store_samples:,}")
    print(f"addr_range=[0x{addr_min:x}, 0x{addr_max:x}]")
    return 0


if __name__ == "__main__":
    sys.exit(main())
