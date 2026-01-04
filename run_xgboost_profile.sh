#!/bin/bash
#
# Profile the Python XGBoost WSS benchmark using perf PEBS (same pipeline as GAPBS scripts).
#
# Usage example:
#   OUT_DIR=./perf_results/xgb_wss20 PERF_DURATION=60 SAMPLE_PERIOD=1000 HEATMAP_VMAX_PCT=99.0 ./run_xgboost_profile.sh
#

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
BENCH_DIR=${BENCH_DIR:-"/home/xiayanwen/app-case-studies/xgboost_bench"}
PYTHON_BIN=${PYTHON_BIN:-"python3"}
BENCH_ARGS=${BENCH_ARGS:-"--target-gib 20 --n-features 4096 --rounds 10 --tree-method hist --max-bin 64 --touch"}

WARMUP_SEC=${WARMUP_SEC:-5}
PERF_DURATION=${PERF_DURATION:-60}
SAMPLE_PERIOD=${SAMPLE_PERIOD:-1000}
PERF_UNTIL_EXIT=${PERF_UNTIL_EXIT:-1} # for Python workloads, usually better to sample until exit

# Analysis params
MAX_POINTS=${MAX_POINTS:-2000000}
HEATMAP_DPI=${HEATMAP_DPI:-300}
HEATMAP_GRIDSIZE=${HEATMAP_GRIDSIZE:-700}
HEATMAP_FIGSIZE=${HEATMAP_FIGSIZE:-"12,7"}
HEATMAP_COLOR_SCALE=${HEATMAP_COLOR_SCALE:-log}      # log|linear
HEATMAP_VMAX_PCT=${HEATMAP_VMAX_PCT:-99.0}           # cap log scale for very dense runs

PERSIST_TOPK=${PERSIST_TOPK:-2048}
PERSIST_REF_WINDOW=${PERSIST_REF_WINDOW:-2}
PERSIST_BIN_SEC=${PERSIST_BIN_SEC:-10}

# Address window inference (Python has many mappings; use window search)
ADDR_MODE=${ADDR_MODE:-window}
WINDOW_GB=${WINDOW_GB:-12}
WINDOW_STRATEGY=${WINDOW_STRATEGY:-best}
PLOT_Y_OFFSET=${PLOT_Y_OFFSET:-1}
USE_PROC_MAPS=${USE_PROC_MAPS:-1} # 1 => prefer largest anon-rw mapping; 0 => always infer a window from samples (useful for "total process" view)

OUT_DIR=${OUT_DIR:-"$ROOT_DIR/perf_results/xgboost_wss"}
TITLE=${TITLE:-"XGBoost WSS benchmark"}

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

echo "=== Start XGBoost benchmark ==="
cd "$BENCH_DIR"

set +e
$PYTHON_BIN ./xgb_wss_bench.py $BENCH_ARGS >"$OUT_DIR/bench.log" 2>&1 &
BENCH_PID=$!
export BENCH_PID
set -e
echo "bench pid: $BENCH_PID"

cleanup() {
  kill "$BENCH_PID" 2>/dev/null || true
}
trap cleanup INT TERM

sleep "$WARMUP_SEC"
if ! kill -0 "$BENCH_PID" 2>/dev/null; then
  echo "ERROR: benchmark exited before profiling started; see log: $OUT_DIR/bench.log" >&2
  tail -n 80 "$OUT_DIR/bench.log" >&2 || true
  exit 1
fi

echo "=== Determine address filter range ==="
ADDR_MIN=""
ADDR_MAX=""
if [ "$USE_PROC_MAPS" = "1" ]; then
  # For Python + NumPy, the biggest anonymous RW mapping is usually the giant feature matrix (X) allocation.
  MAP_RANGE=$(
    python3 - <<'PY'
import re, os
pid = int(os.environ["BENCH_PID"])
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
    echo "No /proc maps range found; will infer address window from samples."
  fi
else
  echo "USE_PROC_MAPS=0: will infer address window from samples (total-process view)."
fi

echo "=== perf record (PEBS data addr) ==="
PERF_DATA="$OUT_DIR/perf.data"
rm -f "$PERF_DATA" 2>/dev/null || true

if [ "$PERF_UNTIL_EXIT" = "1" ]; then
  echo "Sampling mode: until benchmark exits (PERF_UNTIL_EXIT=1)"
  "$PERF_BIN" record \
    -e '{cpu/mem-loads-aux/,cpu/mem-loads/pp}:S' \
    -c "$SAMPLE_PERIOD" \
    -p "$BENCH_PID" \
    -d \
    --no-buildid --no-buildid-cache \
    -o "$PERF_DATA" \
    -- sleep 9999999 >/dev/null 2>&1 &
  PERF_REC_PID=$!
  wait "$BENCH_PID" 2>/dev/null || true
  kill -INT "$PERF_REC_PID" 2>/dev/null || true
  wait "$PERF_REC_PID" 2>/dev/null || true
else
  echo "Sampling mode: fixed duration ${PERF_DURATION}s"
  "$PERF_BIN" record \
    -e '{cpu/mem-loads-aux/,cpu/mem-loads/pp}:S' \
    -c "$SAMPLE_PERIOD" \
    -p "$BENCH_PID" \
    -d \
    --no-buildid --no-buildid-cache \
    -o "$PERF_DATA" \
    -- sleep "$PERF_DURATION" 2>&1 | tail -n 5
fi

if [ ! -s "$PERF_DATA" ]; then
  echo "ERROR: perf did not produce perf.data (or it is empty): $PERF_DATA" >&2
  echo "See log: $OUT_DIR/bench.log" >&2
  exit 1
fi

echo "=== Extract points (time,event,addr) ==="
cd "$ROOT_DIR"
POINTS_TXT="$OUT_DIR/points.txt"
rm -f "$POINTS_TXT" 2>/dev/null || true
"$PERF_BIN" script -i "$PERF_DATA" -F time,event,addr 2>/dev/null > "$POINTS_TXT"

if [ ! -s "$POINTS_TXT" ]; then
  echo "ERROR: no samples decoded into points file: $POINTS_TXT" >&2
  exit 1
fi

echo "=== Infer address window ==="
if [ -z "$ADDR_MIN" ] || [ -z "$ADDR_MAX" ]; then
  read -r ADDR_MIN ADDR_MAX _CNT < <(
    python3 ./infer_addr_range.py --mode "$ADDR_MODE" --window-gb "$WINDOW_GB" --window-strategy "$WINDOW_STRATEGY" --window-output full --max-lines 200000 < "$POINTS_TXT"
  )
  echo "Inferred addr range: $ADDR_MIN - $ADDR_MAX"
fi

echo "=== Plot heatmap ==="
PLOT_ARGS=(--input "$POINTS_TXT" --output "$OUT_DIR/virt_heatmap.png" --title "$TITLE" --addr-min "$ADDR_MIN" --addr-max "$ADDR_MAX" --max-points "$MAX_POINTS" --dpi "$HEATMAP_DPI" --gridsize "$HEATMAP_GRIDSIZE" --figsize "$HEATMAP_FIGSIZE" --color-scale "$HEATMAP_COLOR_SCALE")
if [ -n "${HEATMAP_VMAX_PCT:-}" ]; then
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
echo "  log:              $OUT_DIR/bench.log"
echo "  perf.data:         $PERF_DATA"
echo "  points:            $POINTS_TXT"
echo "  heatmap:           $OUT_DIR/virt_heatmap.png"
echo "  hot persistence:   $OUT_DIR/hot_persistence.png"


