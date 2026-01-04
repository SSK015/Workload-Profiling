#!/bin/bash

# Optional: load sudo password helper if available (used for sysctl tuning)
SCRIPT_LIB_DIR="${SCRIPT_LIB_DIR:-/mnt/nfs/xiayanwen/research/demos/scripts}"
if [ -f "${SCRIPT_LIB_DIR}/password_lib.sh" ]; then
  # shellcheck disable=SC1090
  source "${SCRIPT_LIB_DIR}/password_lib.sh"
  define_user_password
  export SUDO_PASS="${USER_PASSWORD:-}"
fi

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

# ===== Config (override via env) =====
GAPBS_DIR=${GAPBS_DIR:-"/home/xiayanwen/app-case-studies/memtis/memtis-userspace/bench_dir/gapbs"}
GRAPH=${GRAPH:-"benchmark/graphs/twitter.sg"}

# GAPBS BFS common flags:
#   -f <graph_file>   load serialized graph (e.g., *.sg)
#   -n <iters>        number of BFS trials/iterations (see GAPBS README)
BFS_ARGS=${BFS_ARGS:-"-f ${GRAPH} -n64"}

WARMUP_SEC=${WARMUP_SEC:-5}
# If 1, wait for "Read Time:" to appear in bfs.log (graph load finished) before perf attaches.
# This is useful to capture only steady-state BFS trials on dataset graphs like twitter.sg.
START_AFTER_READ=${START_AFTER_READ:-0}

# Profile longer + lower sampling rate by default (tune via env)
PERF_DURATION=${PERF_DURATION:-60}
SAMPLE_PERIOD=${SAMPLE_PERIOD:-1000}  # larger => lower samples/sec
PERF_UNTIL_EXIT=${PERF_UNTIL_EXIT:-0} # 1 => keep sampling until bfs exits (ignores PERF_DURATION)

# Analysis params
MAX_POINTS=${MAX_POINTS:-2000000}
HEATMAP_DPI=${HEATMAP_DPI:-300}
HEATMAP_GRIDSIZE=${HEATMAP_GRIDSIZE:-500}
HEATMAP_FIGSIZE=${HEATMAP_FIGSIZE:-"10,6"}
HEATMAP_COLOR_SCALE=${HEATMAP_COLOR_SCALE:-log}      # log|linear
HEATMAP_VMAX_PCT=${HEATMAP_VMAX_PCT:-""}             # e.g. 99.0 (empty=auto)
PERSIST_TOPK=${PERSIST_TOPK:-2048}
PERSIST_REF_WINDOW=${PERSIST_REF_WINDOW:-2}
PERSIST_BIN_SEC=${PERSIST_BIN_SEC:-10}
ADDR_MODE=${ADDR_MODE:-window}        # dominant | window
WINDOW_GB=${WINDOW_GB:-12}            # used when ADDR_MODE=window and /proc maps can't find graph mapping
WINDOW_STRATEGY=${WINDOW_STRATEGY:-around} # best|min|max|around
PLOT_Y_OFFSET=${PLOT_Y_OFFSET:-1}     # 1 => plot addr-min offset (recommended); 0 => absolute virtual addr

OUT_DIR=${OUT_DIR:-"$ROOT_DIR/perf_results/gapbs_bfs"}
TITLE=${TITLE:-"GAPBS BFS (twitter.sg)"}

mkdir -p "$OUT_DIR"

# Resolve perf path (override with PERF_BIN=/path/to/perf)
PERF_BIN="${PERF_BIN:-}"
if [ -z "$PERF_BIN" ]; then
  if command -v perf >/dev/null 2>&1; then
    PERF_BIN="$(command -v perf)"
  elif [ -x /usr/local/bin/perf ]; then
    PERF_BIN="/usr/local/bin/perf"
  elif [ -x /usr/lib/linux-hwe-6.8-tools-6.8.0-90/perf ]; then
    PERF_BIN="/usr/lib/linux-hwe-6.8-tools-6.8.0-90/perf"
  else
    echo "ERROR: perf not found. Install linux-tools/perf or set PERF_BIN=/path/to/perf" >&2
    exit 1
  fi
fi

echo "perf: $PERF_BIN"
echo "out:  $OUT_DIR"

if [ -n "${SUDO_PASS:-}" ]; then
  echo "=== Set perf sysctls (no throttling) ==="
  echo "$SUDO_PASS" | sudo -S sh -c '
    echo 100000000 > /proc/sys/kernel/perf_event_max_sample_rate
    echo 0 > /proc/sys/kernel/perf_cpu_time_max_percent
    echo -1 > /proc/sys/kernel/perf_event_paranoid
  ' 2>/dev/null || true
else
  echo "=== Skip sysctl (no sudo password provided) ==="
fi

echo "=== Start GAPBS BFS ==="
cd "$GAPBS_DIR"

# Fail fast if BFS isn't built / graph file missing (otherwise perf attaches to a dead PID and you get no plots)
if [ ! -x "$GAPBS_DIR/bfs" ]; then
  echo "ERROR: GAPBS BFS binary not found: $GAPBS_DIR/bfs" >&2
  echo "Fix: build GAPBS (from GAPBS_DIR):" >&2
  echo "  cd \"$GAPBS_DIR\" && make bfs" >&2
  exit 1
fi
if [ ! -f "$GAPBS_DIR/$GRAPH" ]; then
  echo "ERROR: graph file not found: $GAPBS_DIR/$GRAPH" >&2
  echo "Fix: set GRAPH=... to an existing *.sg (or download/build graphs via GAPBS makefiles)." >&2
  exit 1
fi

# Optional: allow the user to control OpenMP threads via env without editing BFS_ARGS
if [ -n "${OMP_NUM_THREADS:-}" ]; then
  export OMP_NUM_THREADS
fi

./bfs $BFS_ARGS >"$OUT_DIR/bfs.log" 2>&1 &
BFS_PID=$!
export BFS_PID
echo "bfs pid: $BFS_PID"

cleanup() {
  # only used on signals; don't kill bfs on normal exit
  kill "$BFS_PID" 2>/dev/null || true
}
trap cleanup INT TERM

if [ "$START_AFTER_READ" = "1" ]; then
  echo "=== Wait for graph read to finish (START_AFTER_READ=1) ==="
  # Wait until bfs prints "Read Time:" (from reader.h), indicating graph load done.
  # Bail out early if bfs exits.
  for _ in $(seq 1 6000); do # ~600s max (0.1s * 6000)
    if ! kill -0 "$BFS_PID" 2>/dev/null; then
      echo "ERROR: bfs exited before profiling started; see log: $OUT_DIR/bfs.log" >&2
      tail -n 120 "$OUT_DIR/bfs.log" >&2 || true
      exit 1
    fi
    if grep -q "Read Time:" "$OUT_DIR/bfs.log" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
else
  sleep "$WARMUP_SEC"
fi

if ! kill -0 "$BFS_PID" 2>/dev/null; then
  echo "ERROR: bfs exited before profiling started; see log: $OUT_DIR/bfs.log" >&2
  tail -n 80 "$OUT_DIR/bfs.log" >&2 || true
  exit 1
fi

echo "=== Snapshot /proc maps (for labeling hot ranges later) ==="
if [ -r "/proc/$BFS_PID/maps" ]; then
  cp "/proc/$BFS_PID/maps" "$OUT_DIR/proc_maps.txt" 2>/dev/null || true
fi
if [ -r "/proc/$BFS_PID/smaps_rollup" ]; then
  cp "/proc/$BFS_PID/smaps_rollup.txt" "$OUT_DIR/smaps_rollup.txt" 2>/dev/null || true
fi

echo "=== Determine address filter range ==="
ADDR_MIN=""
ADDR_MAX=""

# Prefer mapping of the graph file if it's mmapped
MAP_RANGE=$(awk -v g="$(basename "$GRAPH")" '$0 ~ g {print $1; exit}' "/proc/$BFS_PID/maps" 2>/dev/null || true)
if [ -n "$MAP_RANGE" ]; then
  ADDR_MIN="0x${MAP_RANGE%-*}"
  ADDR_MAX="0x${MAP_RANGE#*-}"
  echo "Using graph mapping: $ADDR_MIN - $ADDR_MAX"
else
  # Fallback: biggest anonymous rw mapping (often where graph/arrays live)
  MAP_RANGE=$(
    python3 - <<'PY'
import re, os
pid = int(os.environ["BFS_PID"])
best = ""
best_sz = -1
with open(f"/proc/{pid}/maps", "r", encoding="utf-8", errors="ignore") as f:
    for line in f:
        parts = line.split()
        if len(parts) < 5:
            continue
        addr = parts[0]
        perms = parts[1]
        path = parts[5] if len(parts) >= 6 else ""
        if "r" not in perms or "w" not in perms:
            continue
        if path not in ("", "0"):
            continue
        m = re.match(r"^([0-9a-fA-F]+)-([0-9a-fA-F]+)$", addr)
        if not m:
            continue
        lo = int(m.group(1), 16)
        hi = int(m.group(2), 16)
        sz = hi - lo
        if sz > best_sz:
            best_sz = sz
            best = addr
print(best)
PY
  )
  if [ -n "$MAP_RANGE" ]; then
    ADDR_MIN="0x${MAP_RANGE%-*}"
    ADDR_MAX="0x${MAP_RANGE#*-}"
    echo "Using anon-rw mapping: $ADDR_MIN - $ADDR_MAX"
  else
    echo "No /proc maps range found; will auto-infer dominant bucket from samples."
  fi
fi

echo "=== perf record (PEBS data addr) ==="
PERF_DATA="$OUT_DIR/perf.data"
rm -f "$PERF_DATA" 2>/dev/null || true

if [ "$PERF_UNTIL_EXIT" = "1" ]; then
  echo "Sampling mode: until bfs exits (PERF_UNTIL_EXIT=1)"
  "$PERF_BIN" record \
    -e '{cpu/mem-loads-aux/,cpu/mem-loads/pp}:S' \
    -c "$SAMPLE_PERIOD" \
    -p "$BFS_PID" \
    -d \
    --no-buildid --no-buildid-cache \
    -o "$PERF_DATA" \
    -- sleep 9999999 >/dev/null 2>&1 &
  PERF_REC_PID=$!
  wait "$BFS_PID" 2>/dev/null || true
  kill -INT "$PERF_REC_PID" 2>/dev/null || true
  wait "$PERF_REC_PID" 2>/dev/null || true
else
  echo "Sampling mode: fixed duration ${PERF_DURATION}s"
  "$PERF_BIN" record \
    -e '{cpu/mem-loads-aux/,cpu/mem-loads/pp}:S' \
    -c "$SAMPLE_PERIOD" \
    -p "$BFS_PID" \
    -d \
    --no-buildid --no-buildid-cache \
    -o "$PERF_DATA" \
    -- sleep "$PERF_DURATION" 2>&1 | tail -n 5
fi

if [ ! -s "$PERF_DATA" ]; then
  echo "ERROR: perf did not produce perf.data (or it is empty): $PERF_DATA" >&2
  echo "Most common causes:" >&2
  echo "  - bfs exited too quickly" >&2
  echo "  - perf attach failed (permission/paranoid/sysctls)" >&2
  echo "See BFS log: $OUT_DIR/bfs.log" >&2
  exit 1
fi

echo "=== Extract points (time,event,addr) ==="
cd "$ROOT_DIR"
POINTS_TXT="$OUT_DIR/bfs_points.txt"
rm -f "$POINTS_TXT" 2>/dev/null || true
"$PERF_BIN" script -i "$PERF_DATA" -F time,event,addr 2>/dev/null > "$POINTS_TXT"

if [ ! -s "$POINTS_TXT" ]; then
  echo "ERROR: no samples decoded into points file: $POINTS_TXT" >&2
  echo "Try lowering SAMPLE_PERIOD (higher sampling) or increasing PERF_DURATION / PERF_UNTIL_EXIT=1." >&2
  exit 1
fi

echo "=== Plot heatmap ==="
if [ -z "$ADDR_MIN" ] || [ -z "$ADDR_MAX" ]; then
  read -r ADDR_MIN ADDR_MAX _CNT < <(
    python3 ./infer_addr_range.py --mode "$ADDR_MODE" --window-gb "$WINDOW_GB" --window-strategy "$WINDOW_STRATEGY" --max-lines 200000 < "$POINTS_TXT"
  )
  echo "Inferred addr range ($ADDR_MODE): $ADDR_MIN - $ADDR_MAX"
fi

PLOT_ARGS=(--input "$POINTS_TXT" --output "$OUT_DIR/virt_heatmap.png" --title "$TITLE" --addr-min "$ADDR_MIN" --addr-max "$ADDR_MAX" --max-points "$MAX_POINTS" --dpi "$HEATMAP_DPI" --gridsize "$HEATMAP_GRIDSIZE" --figsize "$HEATMAP_FIGSIZE" --color-scale "$HEATMAP_COLOR_SCALE")
if [ -n "$HEATMAP_VMAX_PCT" ]; then
  PLOT_ARGS+=(--vmax-percentile "$HEATMAP_VMAX_PCT")
fi
if [ "$PLOT_Y_OFFSET" = "1" ]; then
  PLOT_ARGS+=(--y-offset --ylabel "Virtual address (offset)")
else
  PLOT_ARGS+=(--ylabel "Virtual address")
fi
python3 ./plot_phys_addr.py "${PLOT_ARGS[@]}"

echo "=== Plot hot persistence ==="
python3 ./hot_persistence.py \
  --input "$POINTS_TXT" \
  --output "$OUT_DIR/hot_persistence.png" \
  --title "${TITLE} hot persistence" \
  --addr-min "$ADDR_MIN" --addr-max "$ADDR_MAX" \
  --ref-start 0 --ref-window "$PERSIST_REF_WINDOW" \
  --topk "$PERSIST_TOPK" \
  --bin "$PERSIST_BIN_SEC"

echo ""
echo "Done:"
echo "  perf.data:         $PERF_DATA"
echo "  points:            $POINTS_TXT"
echo "  heatmap:           $OUT_DIR/virt_heatmap.png"
echo "  hot persistence:   $OUT_DIR/hot_persistence.png"
echo "  bfs log:           $OUT_DIR/bfs.log"


