#!/usr/bin/env python3
"""
Filter `perf script` text output by PID (and optionally comm), and emit a compact
`time event addr` format compatible with plot_phys_addr.py and infer_addr_range.py.

Expected input line format (from: perf script -F comm,pid,time,event,addr):
  <comm> <pid> <time>: <event>: <addr>

Example:
  train 226012 2584553.881776: cpu/mem-stores/pp: 7fa4c0...
"""

from __future__ import annotations

import argparse
import sys


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--pid", type=int, required=True, help="Keep only this PID")
    p.add_argument("--comm", default=None, help="Optional: also require this comm name (exact match)")
    return p.parse_args()


def main() -> int:
    args = parse_args()
    pid_s = str(args.pid)
    comm_req = args.comm

    out = sys.stdout.buffer
    for raw in sys.stdin.buffer:
        # Fast split, tolerate extra spaces.
        parts = raw.split()
        if len(parts) < 5:
            continue
        comm = parts[0].decode("utf-8", "ignore")
        pid = parts[1].decode("utf-8", "ignore")
        if pid != pid_s:
            continue
        if comm_req is not None and comm != comm_req:
            continue

        # parts[2] is "<time>:" ; parts[3] is "<event>:" ; parts[4] is "<addr>"
        t = parts[2].rstrip(b":")
        ev = parts[3].rstrip(b":")
        addr = parts[4]

        # Emit as: "<time>: <event>: <addr>\n" (matches plot_phys_addr.py LINE_RE)
        out.write(t)
        out.write(b": ")
        out.write(ev)
        out.write(b": ")
        out.write(addr)
        out.write(b"\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

