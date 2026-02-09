#!/usr/bin/env python3
"""
Rescale perf "points" time axis from wall-clock time to a target span (e.g. user/CPU time).

Input format (from: perf script -F time,event,addr):
  50858.386645:   cpu/mem-loads/pp:     7fff0cba3bb0

Output keeps the same 3-field format (time event addr), but replaces time with:
  t' = (t - t_min) * (target_span / (t_max - t_min))

This is useful when the workload is multi-threaded and you want the x-axis to represent
"user time" (summed across threads) rather than elapsed wall time.
"""

from __future__ import annotations

import argparse
import sys


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--input", required=True, help="Input points file (time,event,addr)")
    p.add_argument("--output", required=True, help="Output points file with rescaled time")
    p.add_argument(
        "--event",
        default="cpu/mem-loads/pp",
        help="Only use matching event lines to compute time span (default: cpu/mem-loads/pp).",
    )
    p.add_argument(
        "--target-span",
        type=float,
        required=True,
        help="Target span in seconds for the output time axis (e.g., user time total).",
    )
    return p.parse_args()


def _try_parse(line: bytes) -> tuple[float | None, bytes | None, bytes | None, bytes | None]:
    """
    Returns (time, event, addr, prefix) where:
      - time: float seconds (None if parse fails)
      - event: b'cpu/mem-loads/pp' without trailing ':'
      - addr: hex bytes token (no 0x)
      - prefix: original indentation bytes before time token (for stable formatting)
    """
    # Typical tokens: [time:, event:, addr]
    # Note: some lines have leading spaces; preserve them.
    stripped = line.lstrip(b" ")
    prefix = line[: len(line) - len(stripped)]
    parts = stripped.split()
    if len(parts) < 3:
        return None, None, None, prefix
    try:
        t = float(parts[0].rstrip(b":"))
    except Exception:
        return None, None, None, prefix
    ev = parts[-2].rstrip(b":")
    addr = parts[-1].strip()
    return t, ev, addr, prefix


def main() -> int:
    args = parse_args()
    event_b = args.event.encode("ascii", "ignore")

    t_min: float | None = None
    t_max: float | None = None

    # Pass 1: find t_min/t_max over matching event
    with open(args.input, "rb") as f:
        for line in f:
            t, ev, _addr, _prefix = _try_parse(line)
            if t is None or ev is None:
                continue
            if ev != event_b:
                continue
            t_min = t if t_min is None or t < t_min else t_min
            t_max = t if t_max is None or t > t_max else t_max

    if t_min is None or t_max is None or t_max <= t_min:
        raise SystemExit(f"Could not infer a valid time span from {args.input} for event={args.event}")

    wall_span = t_max - t_min
    scale = float(args.target_span) / wall_span
    sys.stderr.write(f"[rescale] wall_span={wall_span:.6f}s target_span={args.target_span:.6f}s scale={scale:.6f}\\n")

    # Pass 2: write rescaled output
    with open(args.input, "rb") as fin, open(args.output, "wb") as fout:
        for line in fin:
            t, ev, addr, prefix = _try_parse(line)
            if t is None or ev is None or addr is None:
                fout.write(line)
                continue
            # Keep original event formatting (with trailing ':' like perf script) for compatibility
            t2 = (t - t_min) * scale
            # Emit like: "<t>: <event>: <addr>\n"
            fout.write(prefix)
            fout.write(f"{t2:.6f}:  ".encode("ascii"))
            fout.write(ev)
            fout.write(b":\t")
            fout.write(addr)
            if not line.endswith(b"\n"):
                fout.write(b"\n")
            else:
                fout.write(b"\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

