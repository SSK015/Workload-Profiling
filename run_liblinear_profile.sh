#!/usr/bin/env bash
set -euo pipefail

# Run liblinear (multicore) and profile PEBS data-address samples with perf.
# This follows the control-flow in tmp/liblinear.sh:
#   1) launch train
#   2) wait for /tmp/liblinear_initialized (after data read)
#   3) start perf recording
#   4) write /tmp/liblinear_thrashed to let training proceed
#
# Outputs go under perf_results/ by default (no need to use global_dirs.sh).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

# Reuse perf auto-detection (event string, -p vs -a) if available
source "$ROOT_DIR/perf_utils.sh" || true

timestamp() { date +"%Y-%m-%d_%H-%M-%S"; }

LIBLINEAR_DIR_DEFAULT="/data/xiayanwen/research/liblinear/liblinear-multicore-2.49"
LIBLINEAR_DIR="${LIBLINEAR_DIR:-$LIBLINEAR_DIR_DEFAULT}"
TRAIN_BIN="${TRAIN_BIN:-$LIBLINEAR_DIR/train}"
DATASET="${DATASET:-$LIBLINEAR_DIR/HIGGS}"

# Liblinear args (from tmp/liblinear.sh)
TRAIN_ARGS_DEFAULT=(-s 6 -m 16 -e 0.000001)
if [ -n "${TRAIN_ARGS:-}" ]; then
  # shellcheck disable=SC2206
  TRAIN_ARGS=(${TRAIN_ARGS})
else
  TRAIN_ARGS=("${TRAIN_ARGS_DEFAULT[@]}")
fi

# Profiling knobs
OUT_DIR="${OUT_DIR:-$ROOT_DIR/perf_results/liblinear_$(timestamp)}"
mkdir -p "$OUT_DIR"
TITLE="${TITLE:-liblinear}"
PERF_BIN="${PERF_BIN:-perf}"
SAMPLE_PERIOD="${SAMPLE_PERIOD:-2000}"
PERF_DURATION="${PERF_DURATION:-60}"
PERF_UNTIL_EXIT="${PERF_UNTIL_EXIT:-1}"
PERF_STOP_AFTER_SEC="${PERF_STOP_AFTER_SEC:-}"
DO_STORE="${DO_STORE:-1}"
PERF_EVENT_LOAD="${PERF_EVENT_LOAD:-cpu/mem-loads/pp}"
PERF_EVENT_STORE="${PERF_EVENT_STORE:-cpu/mem-stores/pp}"
MAX_POINTS="${MAX_POINTS:-4000000}"
HEATMAP_DPI="${HEATMAP_DPI:-160}"
HEATMAP_GRIDSIZE="${HEATMAP_GRIDSIZE:-120}"
HEATMAP_FIGSIZE="${HEATMAP_FIGSIZE:-10,5}"
HEATMAP_COLOR_SCALE="${HEATMAP_COLOR_SCALE:-linear}"
HEATMAP_VMAX_PCT="${HEATMAP_VMAX_PCT:-}"
DO_VIRT="${DO_VIRT:-1}"
DO_PERSIST="${DO_PERSIST:-0}"
WINDOW_GB="${WINDOW_GB:-40}"
WINDOW_STRATEGY="${WINDOW_STRATEGY:-best}"
PLOT_LOAD_IN_STORE_WINDOW="${PLOT_LOAD_IN_STORE_WINDOW:-1}"
PERSIST_REF_START="${PERSIST_REF_START:-0.0}"
PERSIST_REF_WINDOW="${PERSIST_REF_WINDOW:-2.0}"
PERSIST_TOPK="${PERSIST_TOPK:-2048}"
PERSIST_BIN_SEC="${PERSIST_BIN_SEC:-5.0}"

# Optional: delay profiling until RSS reaches a threshold (GiB).
# Useful when you want to sample after the workload has allocated/settled into a large footprint.
START_AFTER_RSS_GB="${START_AFTER_RSS_GB:-}"
START_AFTER_RSS_TIMEOUT_SEC="${START_AFTER_RSS_TIMEOUT_SEC:-3600}"
RSS_POLL_INTERVAL_SEC="${RSS_POLL_INTERVAL_SEC:-0.5}"

# Optional: try to drop caches; requires sudo. Default off.
FLUSH_CACHE="${FLUSH_CACHE:-0}"

echo "=== liblinear path check ==="
test -x "$TRAIN_BIN" || { echo "ERROR: not executable: $TRAIN_BIN" >&2; exit 1; }
test -f "$DATASET" || { echo "ERROR: dataset not found: $DATASET" >&2; exit 1; }
echo "TRAIN_BIN=$TRAIN_BIN"
echo "DATASET=$DATASET"
echo "OUT_DIR=$OUT_DIR"

if [ "$FLUSH_CACHE" = "1" ]; then
  echo "=== drop caches (requires sudo) ==="
  (echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null) || true
  free || true
  sleep 1
fi

echo "=== cleanup signal files ==="
rm -f /tmp/liblinear_initialized /tmp/liblinear_thrashed 2>/dev/null || true

BENCH_LOG="$OUT_DIR/bench.log"
echo "=== start liblinear ==="
(
  cd "$LIBLINEAR_DIR"
  # Use exec so the background PID ($!) is the actual 'train' PID (important when
  # perf is forced to system-wide sampling and we later filter samples by PID).
  exec "$TRAIN_BIN" "${TRAIN_ARGS[@]}" "$DATASET"
) >"$BENCH_LOG" 2>&1 &
BENCH_PID=$!
echo "BENCH_PID=$BENCH_PID"

echo "=== wait for /tmp/liblinear_initialized (after data read) ==="
for _ in $(seq 1 6000); do # ~600s max
  if ! kill -0 "$BENCH_PID" 2>/dev/null; then
    echo "ERROR: train exited before initialized; see log: $BENCH_LOG" >&2
    tail -n 120 "$BENCH_LOG" >&2 || true
    exit 1
  fi
  if [ -s /tmp/liblinear_initialized ]; then
    break
  fi
  sleep 0.1
done

if [ ! -s /tmp/liblinear_initialized ]; then
  echo "ERROR: timeout waiting for /tmp/liblinear_initialized" >&2
  tail -n 120 "$BENCH_LOG" >&2 || true
  exit 1
fi

echo "=== perf record (PEBS data addr) ==="
PERF_DATA="$OUT_DIR/perf.data"
rm -f "$PERF_DATA" 2>/dev/null || true

# Auto-detect best perf parameters for the current environment
if command -v detect_perf_params >/dev/null 2>&1; then
  detect_perf_params "$BENCH_PID"
else
  PERF_TARGET_FLAGS="-p $BENCH_PID"
fi

EVENT_ARGS=(-e "$PERF_EVENT_LOAD")
if [ "$DO_STORE" = "1" ]; then
  EVENT_ARGS+=(-e "$PERF_EVENT_STORE")
fi

target_rss_kb=""
if [ -n "$START_AFTER_RSS_GB" ]; then
  target_rss_kb=$(python3 - <<PY
gb=float("$START_AFTER_RSS_GB")
print(int(gb*1024*1024))
PY
)
  echo "=== release training; wait for RSS >= ${START_AFTER_RSS_GB} GiB (VmRSS) before profiling ==="
  echo "go" > /tmp/liblinear_thrashed
  t0=$(date +%s)
  while true; do
    if ! kill -0 "$BENCH_PID" 2>/dev/null; then
      echo "ERROR: train exited before reaching RSS threshold; see log: $BENCH_LOG" >&2
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
fi

if [ "$PERF_UNTIL_EXIT" = "1" ] || [ -n "$PERF_STOP_AFTER_SEC" ]; then
  "$PERF_BIN" record \
    "${EVENT_ARGS[@]}" \
    -c "$SAMPLE_PERIOD" \
    $PERF_TARGET_FLAGS \
    -d \
    --no-buildid --no-buildid-cache \
    -o "$PERF_DATA" \
    -- sleep 9999999 >/dev/null 2>&1 &
  PERF_REC_PID=$!
  # If we didn't already release training (START_AFTER_RSS_GB unset), do so now.
  if [ -z "$START_AFTER_RSS_GB" ]; then
    # Let perf spin up, then release training.
    sleep 0.2
    echo "go" > /tmp/liblinear_thrashed
  fi
  if [ -n "$PERF_STOP_AFTER_SEC" ]; then
    # Stop perf after a fixed duration but keep the benchmark running to completion.
    sleep "$PERF_STOP_AFTER_SEC" || true
    kill -INT "$PERF_REC_PID" 2>/dev/null || true
    wait "$PERF_REC_PID" 2>/dev/null || true
    wait "$BENCH_PID" 2>/dev/null || true
  else
  wait "$BENCH_PID" 2>/dev/null || true
  kill -INT "$PERF_REC_PID" 2>/dev/null || true
  wait "$PERF_REC_PID" 2>/dev/null || true
  fi
else
  # Let perf spin up, then release training.
  "$PERF_BIN" record \
    "${EVENT_ARGS[@]}" \
    -c "$SAMPLE_PERIOD" \
    $PERF_TARGET_FLAGS \
    -d \
    --no-buildid --no-buildid-cache \
    -o "$PERF_DATA" \
    -- sleep "$PERF_DURATION" 2>&1 | tail -n 5
  if [ -z "$START_AFTER_RSS_GB" ]; then
    echo "go" > /tmp/liblinear_thrashed
  fi
  wait "$BENCH_PID" 2>/dev/null || true
fi

if [ ! -s "$PERF_DATA" ]; then
  echo "ERROR: perf did not produce perf.data (or it is empty): $PERF_DATA" >&2
  echo "Hints:" >&2
  echo "  - check /proc/sys/kernel/perf_event_paranoid and perf permissions" >&2
  echo "  - try: sudo sysctl -w kernel.perf_event_paranoid=-1 (if allowed)" >&2
  exit 1
fi

echo "=== extract points (time,event,addr) ==="
RAW_POINTS_TXT="$OUT_DIR/raw_points.txt"
POINTS_TXT="$OUT_DIR/points.txt"
rm -f "$RAW_POINTS_TXT" "$POINTS_TXT" 2>/dev/null || true
# Include comm+pid because we may be recording system-wide (-a); then filter to BENCH_PID.
"$PERF_BIN" script -i "$PERF_DATA" -F comm,pid,time,event,addr 2>/dev/null > "$RAW_POINTS_TXT"
test -s "$RAW_POINTS_TXT" || { echo "ERROR: no samples decoded into raw points file: $RAW_POINTS_TXT" >&2; exit 1; }
python3 "$ROOT_DIR/filter_perf_script_points.py" --pid "$BENCH_PID" --comm train < "$RAW_POINTS_TXT" > "$POINTS_TXT"
test -s "$POINTS_TXT" || { echo "ERROR: no samples for BENCH_PID=$BENCH_PID in points file: $POINTS_TXT" >&2; exit 1; }

ADDR_MIN=""
ADDR_MAX=""
read -r ADDR_MIN ADDR_MAX _CNT < <(
  python3 "$ROOT_DIR/infer_addr_range.py" \
    --event "$PERF_EVENT_LOAD" \
    --mode window --window-gb "$WINDOW_GB" --window-strategy "$WINDOW_STRATEGY" --window-output full \
    --max-lines 200000 < "$POINTS_TXT"
) || true

STORE_ADDR_MIN=""
STORE_ADDR_MAX=""
if [ "$DO_STORE" = "1" ]; then
  read -r STORE_ADDR_MIN STORE_ADDR_MAX _SCNT < <(
    python3 "$ROOT_DIR/infer_addr_range.py" \
      --event "$PERF_EVENT_STORE" \
      --mode window --window-gb "$WINDOW_GB" --window-strategy "$WINDOW_STRATEGY" --window-output full \
      --max-lines 200000 < "$POINTS_TXT"
  ) || true
fi

if [ "$DO_VIRT" = "1" ] && [ -n "$ADDR_MIN" ] && [ -n "$ADDR_MAX" ]; then
  echo "=== plot virt heatmap (loads) ==="
  PLOT_ARGS=(--input "$POINTS_TXT" --output "$OUT_DIR/virt_heatmap_load.png" --title "$TITLE (loads)" --xlabel "Wall time (sec)" --event-filter "$PERF_EVENT_LOAD" --addr-min "$ADDR_MIN" --addr-max "$ADDR_MAX" --y-offset --ymax-gb "$WINDOW_GB" --max-points "$MAX_POINTS" --dpi "$HEATMAP_DPI" --gridsize "$HEATMAP_GRIDSIZE" --figsize "$HEATMAP_FIGSIZE" --color-scale "$HEATMAP_COLOR_SCALE")
  if [ -n "$HEATMAP_VMAX_PCT" ]; then
    PLOT_ARGS+=(--vmax-percentile "$HEATMAP_VMAX_PCT")
  fi
  PLOT_ARGS+=(--ylabel "Virtual address (offset from window start)")
  python3 "$ROOT_DIR/plot_phys_addr.py" "${PLOT_ARGS[@]}" || true

  if [ "$DO_STORE" = "1" ]; then
    echo "=== plot virt heatmap (stores) ==="
    # Note: store hot regions can differ from load hot regions. Prefer a store-derived window when available.
    if [ -n "$STORE_ADDR_MIN" ] && [ -n "$STORE_ADDR_MAX" ]; then
      S_MIN="$STORE_ADDR_MIN"
      S_MAX="$STORE_ADDR_MAX"
    else
      S_MIN="$ADDR_MIN"
      S_MAX="$ADDR_MAX"
    fi
    PLOT_ARGS=(--input "$POINTS_TXT" --output "$OUT_DIR/virt_heatmap_store.png" --title "$TITLE (stores)" --xlabel "Wall time (sec)" --event-filter "$PERF_EVENT_STORE" --addr-min "$S_MIN" --addr-max "$S_MAX" --y-offset --ymax-gb "$WINDOW_GB" --max-points "$MAX_POINTS" --dpi "$HEATMAP_DPI" --gridsize "$HEATMAP_GRIDSIZE" --figsize "$HEATMAP_FIGSIZE" --color-scale "$HEATMAP_COLOR_SCALE")
    if [ -n "$HEATMAP_VMAX_PCT" ]; then
      PLOT_ARGS+=(--vmax-percentile "$HEATMAP_VMAX_PCT")
    fi
    PLOT_ARGS+=(--ylabel "Virtual address (offset from window start)")
    python3 "$ROOT_DIR/plot_phys_addr.py" "${PLOT_ARGS[@]}" || true

    if [ "$PLOT_LOAD_IN_STORE_WINDOW" = "1" ] && [ -n "$STORE_ADDR_MIN" ] && [ -n "$STORE_ADDR_MAX" ]; then
      echo "=== plot virt heatmap (loads, window from stores) ==="
      PLOT_ARGS=(--input "$POINTS_TXT" --output "$OUT_DIR/virt_heatmap_load_in_store_window.png" --title "$TITLE (loads, window from stores)" --xlabel "Wall time (sec)" --event-filter "$PERF_EVENT_LOAD" --addr-min "$STORE_ADDR_MIN" --addr-max "$STORE_ADDR_MAX" --y-offset --ymax-gb "$WINDOW_GB" --max-points "$MAX_POINTS" --dpi "$HEATMAP_DPI" --gridsize "$HEATMAP_GRIDSIZE" --figsize "$HEATMAP_FIGSIZE" --color-scale "$HEATMAP_COLOR_SCALE")
      if [ -n "$HEATMAP_VMAX_PCT" ]; then
        PLOT_ARGS+=(--vmax-percentile "$HEATMAP_VMAX_PCT")
      fi
      PLOT_ARGS+=(--ylabel "Virtual address (offset from window start)")
      python3 "$ROOT_DIR/plot_phys_addr.py" "${PLOT_ARGS[@]}" || true
    fi
  fi
else
  echo "=== skip plotting (DO_VIRT=$DO_VIRT, ADDR_MIN=$ADDR_MIN, ADDR_MAX=$ADDR_MAX) ==="
fi

if [ "$DO_PERSIST" = "1" ] && [ -n "$ADDR_MIN" ] && [ -n "$ADDR_MAX" ]; then
  echo "=== hot persistence ==="
  python3 "$ROOT_DIR/hot_persistence.py" \
    --input "$POINTS_TXT" \
    --output "$OUT_DIR/hot_persistence.png" \
    --title "${TITLE} hot persistence" \
    --addr-min "$ADDR_MIN" --addr-max "$ADDR_MAX" \
    --ref-start "$PERSIST_REF_START" --ref-window "$PERSIST_REF_WINDOW" \
    --topk "$PERSIST_TOPK" \
    --bin "$PERSIST_BIN_SEC" || true
fi

echo ""
echo "Done:"
echo "  log:      $BENCH_LOG"
echo "  perf.data: $PERF_DATA"
echo "  points:   $POINTS_TXT"
if [ "$DO_VIRT" = "1" ]; then
  echo "  heatmap(load):  $OUT_DIR/virt_heatmap_load.png"
  if [ "$DO_STORE" = "1" ]; then
    echo "  heatmap(store): $OUT_DIR/virt_heatmap_store.png"
  fi
fi
echo "  out:      $OUT_DIR"

