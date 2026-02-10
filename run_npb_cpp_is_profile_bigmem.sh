#!/bin/bash
#
# Run NPB-CPP IS (Integer Sort) with OpenMP and profile a big-memory phase (~20-40GiB RSS).
#
# Key idea:
# - Start IS normally (no perf)
# - Wait until VmRSS reaches START_AFTER_RSS_GB (default 20GiB)
# - Then run perf record (loads + stores, data addr) for PERF_STOP_AFTER_SEC seconds
# - Decode points and generate store-window plots
#
# Example:
#   THREADS=32 CLASS=D START_AFTER_RSS_GB=25 PERF_STOP_AFTER_SEC=180 SAMPLE_PERIOD=20000 \
#     ./run_npb_cpp_is_profile_bigmem.sh
#

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

if [ -f "$ROOT_DIR/perf_utils.sh" ]; then
  # shellcheck disable=SC1091
  source "$ROOT_DIR/perf_utils.sh"
fi

# ===== Config (override via env) =====
NPB_CPP_ROOT=${NPB_CPP_ROOT:-"/data/xiayanwen/research/NPB-CPP"}
THREADS=${THREADS:-32}
CLASS=${CLASS:-D}  # IS supports up to D in this NPB-CPP tree; D is the big-memory class.

PERF_BIN="${PERF_BIN:-perf}"
SAMPLE_PERIOD=${SAMPLE_PERIOD:-20000}
PERF_STOP_AFTER_SEC=${PERF_STOP_AFTER_SEC:-300}

DO_STORE=${DO_STORE:-1}
PERF_EVENT_LOAD=${PERF_EVENT_LOAD:-"cpu/mem-loads/pp"}
PERF_EVENT_STORE=${PERF_EVENT_STORE:-"cpu/mem-stores/pp"}

# Delay profiling until RSS reaches this threshold (GiB)
START_AFTER_RSS_GB=${START_AFTER_RSS_GB:-20}
START_AFTER_RSS_TIMEOUT_SEC=${START_AFTER_RSS_TIMEOUT_SEC:-7200}
RSS_POLL_INTERVAL_SEC=${RSS_POLL_INTERVAL_SEC:-1}

RUN_TAG="${RUN_TAG:-$(date +%Y%m%d_%H%M%S)}"
OUT_DIR=${OUT_DIR:-"$ROOT_DIR/perf_results/npb_cpp_is_${CLASS}_${RUN_TAG}_t${THREADS}_rss${START_AFTER_RSS_GB}g"}
TITLE=${TITLE:-"NPB-CPP IS class ${CLASS} (OpenMP, t=${THREADS})"}
mkdir -p "$OUT_DIR"

NPB_OMP_DIR="$NPB_CPP_ROOT/NPB-OMP"
if [ ! -d "$NPB_OMP_DIR" ]; then
  echo "ERROR: NPB-CPP OpenMP directory not found: $NPB_OMP_DIR" >&2
  echo "Fix: git clone https://github.com/GMAP/NPB-CPP to $NPB_CPP_ROOT (or set NPB_CPP_ROOT)." >&2
  exit 1
fi

echo "npb:  $NPB_OMP_DIR"
echo "perf: $PERF_BIN"
echo "out:  $OUT_DIR"
echo "cfg:  IS CLASS=$CLASS THREADS=$THREADS START_AFTER_RSS_GB=$START_AFTER_RSS_GB PERF_STOP_AFTER_SEC=$PERF_STOP_AFTER_SEC SAMPLE_PERIOD=$SAMPLE_PERIOD DO_STORE=$DO_STORE"

echo "=== Build NPB-CPP IS (OpenMP C++) ==="
cd "$NPB_OMP_DIR"
make is "CLASS=${CLASS}"

IS_BIN="$NPB_OMP_DIR/bin/is.${CLASS}"
if [ ! -x "$IS_BIN" ]; then
  echo "ERROR: IS binary not found after build: $IS_BIN" >&2
  exit 1
fi

cd "$ROOT_DIR"

BENCH_LOG="$OUT_DIR/bench.log"
rm -f "$BENCH_LOG" 2>/dev/null || true

echo "=== start IS benchmark (no perf yet) ==="
(
  cd "$NPB_OMP_DIR"
  exec env OMP_NUM_THREADS="$THREADS" OMP_PROC_BIND=close OMP_PLACES=cores "$IS_BIN"
) >"$BENCH_LOG" 2>&1 &
BENCH_PID=$!
echo "BENCH_PID=$BENCH_PID"

target_rss_kb=$(python3 - <<PY
gb=float("$START_AFTER_RSS_GB")
print(int(gb*1024*1024))
PY
)

echo "=== wait for RSS >= ${START_AFTER_RSS_GB} GiB (VmRSS) ==="
t0=$(date +%s)
while true; do
  if ! kill -0 "$BENCH_PID" 2>/dev/null; then
    echo "ERROR: IS exited before reaching RSS threshold; see log: $BENCH_LOG" >&2
    tail -n 120 "$BENCH_LOG" >&2 || true
    exit 1
  fi
  rss_kb=$(awk '/VmRSS:/ {print $2}' "/proc/$BENCH_PID/status" 2>/dev/null || echo 0)
  if [ "${rss_kb:-0}" -ge "$target_rss_kb" ]; then
    echo "RSS reached: VmRSS=${rss_kb} kB (target ${target_rss_kb} kB)"
    break
  fi
  now=$(date +%s)
  if [ $((now - t0)) -ge "$START_AFTER_RSS_TIMEOUT_SEC" ]; then
    echo "Warning: timeout waiting for RSS threshold; VmRSS=${rss_kb} kB < target ${target_rss_kb} kB. Proceeding anyway." >&2
    break
  fi
  sleep "$RSS_POLL_INTERVAL_SEC"
done

echo "=== perf record (loads+stores, data addr) for ${PERF_STOP_AFTER_SEC}s ==="
PERF_DATA="$OUT_DIR/perf.data"
RAW_POINTS="$OUT_DIR/raw_points.txt"
POINTS="$OUT_DIR/points.txt"
rm -f "$PERF_DATA" "$RAW_POINTS" "$POINTS" 2>/dev/null || true

EVENT_ARGS=(-e "$PERF_EVENT_LOAD")
if [ "$DO_STORE" = "1" ]; then
  EVENT_ARGS+=(-e "$PERF_EVENT_STORE")
fi

# Prefer system-wide sampling when the custom nothrottle perf has -p issues.
if command -v detect_perf_params >/dev/null 2>&1; then
  detect_perf_params "$BENCH_PID"
else
  PERF_TARGET_FLAGS="-p $BENCH_PID"
fi

"$PERF_BIN" record \
  "${EVENT_ARGS[@]}" \
  -c "$SAMPLE_PERIOD" \
  $PERF_TARGET_FLAGS \
  -d \
  --no-buildid --no-buildid-cache \
  -o "$PERF_DATA" \
  -- sleep "$PERF_STOP_AFTER_SEC" 2>&1 | tail -n 5

test -s "$PERF_DATA" || { echo "ERROR: perf.data missing/empty: $PERF_DATA" >&2; exit 1; }

echo "=== decode & filter points (pid=$BENCH_PID) ==="
"$PERF_BIN" script -i "$PERF_DATA" -F comm,pid,time,event,addr 2>/dev/null > "$RAW_POINTS"
test -s "$RAW_POINTS" || { echo "ERROR: raw_points empty: $RAW_POINTS" >&2; exit 1; }
python3 "$ROOT_DIR/filter_perf_script_points.py" --pid "$BENCH_PID" < "$RAW_POINTS" > "$POINTS"
test -s "$POINTS" || { echo "ERROR: points empty after filtering: $POINTS" >&2; exit 1; }

echo "=== wait for benchmark to exit ==="
wait "$BENCH_PID" 2>/dev/null || true

echo "=== plot (store-window) ==="
WINDOW_GB="${WINDOW_GB:-64}"
HEATMAP_COLOR_SCALE="${HEATMAP_COLOR_SCALE:-log}"
HEATMAP_VMAX_PCT="${HEATMAP_VMAX_PCT:-99.9}"
WINDOW_GB="$WINDOW_GB" HEATMAP_COLOR_SCALE="$HEATMAP_COLOR_SCALE" HEATMAP_VMAX_PCT="$HEATMAP_VMAX_PCT" \
  PERF_EVENT_LOAD="$PERF_EVENT_LOAD" PERF_EVENT_STORE="$PERF_EVENT_STORE" \
  ./replot_store_window.sh "$OUT_DIR" || true

echo ""
echo "Done:"
echo "  bench log: $BENCH_LOG"
echo "  perf.data: $PERF_DATA"
echo "  points:    $POINTS"
echo "  out:       $OUT_DIR"

