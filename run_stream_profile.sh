#!/bin/bash
#
# Multi-thread streaming benchmark (linear array sweeps) + perf/PEBS virtual-address heatmap.
#
# Example:
#   OUT_DIR=./perf_results/stream_demo MEM_SIZE_MB=8192 THREADS=32 BENCH_DURATION=60 \
#     PATTERN=chunk OP=triad PERF_UNTIL_EXIT=1 SAMPLE_PERIOD=1000 \
#     ./run_stream_profile.sh
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

# ===== Helpers =====
detect_nproc() {
  if command -v nproc >/dev/null 2>&1; then
    nproc --all
    return
  fi
  getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1
}

detect_mem_total_mb() {
  # /proc/meminfo: MemTotal: <kB>
  awk '/^MemTotal:/ { printf("%d\n", int($2/1024)); exit }' /proc/meminfo 2>/dev/null || echo 0
}

detect_mem_avail_mb() {
  awk '/^MemAvailable:/ { printf("%d\n", int($2/1024)); exit }' /proc/meminfo 2>/dev/null || echo 0
}

# ===== Config (override via env) =====
# Auto defaults:
# - THREADS: all online CPUs
# - MEM_SIZE_MB: ~1/4 of MemTotal capped to a sane range (>=4GB, <=32GB)
# - SAMPLE_PERIOD: larger for more threads to avoid huge perf.data
AUTO_NPROC="$(detect_nproc)"
AUTO_MEM_TOTAL_MB="$(detect_mem_total_mb)"
AUTO_MEM_AVAIL_MB="$(detect_mem_avail_mb)"

THREADS=${THREADS:-$AUTO_NPROC}
# Default CPU pinning:
# - For "just run" mode, do not pin (more portable and avoids surprises on shared machines).
CPU_START=${CPU_START:--1}
PATTERN=${PATTERN:-chunk}       # chunk|interleave
OP=${OP:-triad}                 # read|write|copy|triad
PHASE_PAGES=${PHASE_PAGES:-0}   # 0 disables (optional diagonal structure)
# Visualization knobs (optional; default disabled)
WINDOW_PAGES=${WINDOW_PAGES:-0}
STEP_PAGES=${STEP_PAGES:-0}
PHASE_SLEEP_US=${PHASE_SLEEP_US:-0}
SYNC_PHASES=${SYNC_PHASES:-0}

BENCH_DURATION=${BENCH_DURATION:-60}
WARMUP_SEC=${WARMUP_SEC:-1}
START_AFTER_READY=${START_AFTER_READY:-1} # 1 => wait for "READY: begin streaming loop" before perf attaches

# perf sampling
PERF_DURATION=${PERF_DURATION:-60}
PERF_UNTIL_EXIT=${PERF_UNTIL_EXIT:-1}
# perf event modifiers: S=PEBS, u=user-only (avoid kernel page-fault samples dominating)
PERF_EVENT_MOD=${PERF_EVENT_MOD:-Su}

# Decide MEM_SIZE_MB if not provided.
if [ -z "${MEM_SIZE_MB:-}" ]; then
  # Heuristic: 1/4 of total RAM, clamped to [4096, 32768] MB.
  # If MemTotal is unavailable, fall back to 4096MB.
  if [ "$AUTO_MEM_TOTAL_MB" -gt 0 ]; then
    MEM_SIZE_MB=$(( AUTO_MEM_TOTAL_MB / 4 ))
  else
    MEM_SIZE_MB=4096
  fi
  if [ "$MEM_SIZE_MB" -lt 4096 ]; then MEM_SIZE_MB=4096; fi
  if [ "$MEM_SIZE_MB" -gt 32768 ]; then MEM_SIZE_MB=32768; fi
else
  MEM_SIZE_MB="$MEM_SIZE_MB"
fi

# If available memory is low (e.g., running in a constrained environment), be conservative.
if [ "$AUTO_MEM_AVAIL_MB" -gt 0 ] && [ "$AUTO_MEM_AVAIL_MB" -lt "$((MEM_SIZE_MB + 1024))" ]; then
  # Keep 1GB headroom.
  NEW_MB=$(( AUTO_MEM_AVAIL_MB - 1024 ))
  if [ "$NEW_MB" -ge 1024 ]; then
    MEM_SIZE_MB="$NEW_MB"
  fi
fi

# SAMPLE_PERIOD default depends on threads (bigger period => lower sample rate).
if [ -z "${SAMPLE_PERIOD:-}" ]; then
  if [ "$THREADS" -le 4 ]; then
    SAMPLE_PERIOD=1000
  elif [ "$THREADS" -le 16 ]; then
    SAMPLE_PERIOD=2000
  else
    SAMPLE_PERIOD=4000
  fi
else
  SAMPLE_PERIOD="$SAMPLE_PERIOD"
fi

# Analysis params
MAX_POINTS=${MAX_POINTS:-2000000}
HEATMAP_DPI=${HEATMAP_DPI:-300}
HEATMAP_GRIDSIZE=${HEATMAP_GRIDSIZE:-600}
HEATMAP_FIGSIZE=${HEATMAP_FIGSIZE:-"10,6"}
HEATMAP_COLOR_SCALE=${HEATMAP_COLOR_SCALE:-log}  # log|linear
HEATMAP_VMAX_PCT=${HEATMAP_VMAX_PCT:-""}         # e.g. 99.0
PLOT_Y_OFFSET=${PLOT_Y_OFFSET:-1}

# If we fail to parse the mmap range from logs, fall back to sample-based inference.
ADDR_MODE=${ADDR_MODE:-window}
WINDOW_GB=${WINDOW_GB:-12}
WINDOW_STRATEGY=${WINDOW_STRATEGY:-around}

RUN_TAG="${RUN_TAG:-$(date +%Y%m%d_%H%M%S)}"
OUT_DIR=${OUT_DIR:-"$ROOT_DIR/perf_results/stream_${RUN_TAG}_mem${MEM_SIZE_MB}_t${THREADS}_${PATTERN}_${OP}"}
TITLE=${TITLE:-"stream_bench (${MEM_SIZE_MB}MB, t=${THREADS}, ${PATTERN}, ${OP})"}

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
echo "auto: nproc=$AUTO_NPROC mem_total_mb=$AUTO_MEM_TOTAL_MB mem_avail_mb=$AUTO_MEM_AVAIL_MB"
echo "cfg:  MEM_SIZE_MB=$MEM_SIZE_MB THREADS=$THREADS CPU_START=$CPU_START PATTERN=$PATTERN OP=$OP PHASE_PAGES=$PHASE_PAGES"
echo "viz:  WINDOW_PAGES=$WINDOW_PAGES STEP_PAGES=$STEP_PAGES PHASE_SLEEP_US=$PHASE_SLEEP_US SYNC_PHASES=$SYNC_PHASES"
echo "perf: PERF_UNTIL_EXIT=$PERF_UNTIL_EXIT PERF_DURATION=$PERF_DURATION SAMPLE_PERIOD=$SAMPLE_PERIOD EVENT_MOD=$PERF_EVENT_MOD START_AFTER_READY=$START_AFTER_READY"

echo "=== Build benchmark ==="
make stream_bench >/dev/null

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

echo "=== Start stream_bench ==="
set +e
./stream_bench \
  --mem-mb="$MEM_SIZE_MB" \
  --threads="$THREADS" \
  --duration="$BENCH_DURATION" \
  --warmup=0 \
  --cpu-start="$CPU_START" \
  --pattern="$PATTERN" \
  --op="$OP" \
  --touch=1 \
  --phase-pages="$PHASE_PAGES" \
  --window-pages="$WINDOW_PAGES" \
  --step-pages="$STEP_PAGES" \
  --phase-sleep-us="$PHASE_SLEEP_US" \
  --sync-phases="$SYNC_PHASES" \
  >"$OUT_DIR/bench.log" 2>&1 &
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
  echo "ERROR: stream_bench exited before profiling started; see log: $OUT_DIR/bench.log" >&2
  tail -n 120 "$OUT_DIR/bench.log" >&2 || true
  exit 1
fi

if [ "$START_AFTER_READY" = "1" ]; then
  echo "=== Wait for streaming loop to begin (START_AFTER_READY=1) ==="
  # Wait until stream_bench prints READY after mmap+touch complete.
  for _ in $(seq 1 6000); do # ~600s max (0.1s * 6000)
    if ! kill -0 "$BENCH_PID" 2>/dev/null; then
      echo "ERROR: stream_bench exited before profiling started; see log: $OUT_DIR/bench.log" >&2
      tail -n 160 "$OUT_DIR/bench.log" >&2 || true
      exit 1
    fi
    if grep -q "READY: begin streaming loop" "$OUT_DIR/bench.log" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
fi

echo "=== Snapshot /proc maps ==="
if [ -r "/proc/$BENCH_PID/maps" ]; then
  cp "/proc/$BENCH_PID/maps" "$OUT_DIR/proc_maps.txt" 2>/dev/null || true
fi
if [ -r "/proc/$BENCH_PID/smaps_rollup" ]; then
  cp "/proc/$BENCH_PID/smaps_rollup" "$OUT_DIR/smaps_rollup.txt" 2>/dev/null || true
fi

echo "=== Determine address filter range (from bench log) ==="
ADDR_MIN=""
ADDR_MAX=""
for _ in $(seq 1 50); do
  ADDR_MIN=$(perl -ne 'if (/Populating memory \((0x[0-9a-fA-F]+) - (0x[0-9a-fA-F]+)\)/) { print $1; exit }' "$OUT_DIR/bench.log" || true)
  ADDR_MAX=$(perl -ne 'if (/Populating memory \((0x[0-9a-fA-F]+) - (0x[0-9a-fA-F]+)\)/) { print $2; exit }' "$OUT_DIR/bench.log" || true)
  if [ -n "$ADDR_MIN" ] && [ -n "$ADDR_MAX" ]; then
    break
  fi
  sleep 0.05
done
if [ -n "$ADDR_MIN" ] && [ -n "$ADDR_MAX" ]; then
  echo "Using mmap range: $ADDR_MIN - $ADDR_MAX"
else
  echo "Warning: could not parse mmap range from bench.log; will infer from samples."
fi

echo "=== perf record (PEBS data addr) ==="
PERF_DATA="$OUT_DIR/perf.data"
rm -f "$PERF_DATA" 2>/dev/null || true

if [ "$PERF_UNTIL_EXIT" = "1" ]; then
  echo "Sampling mode: until benchmark exits (PERF_UNTIL_EXIT=1)"
  "$PERF_BIN" record \
    -e "{cpu/mem-loads-aux/,cpu/mem-loads/pp}:${PERF_EVENT_MOD}" \
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
    -e "{cpu/mem-loads-aux/,cpu/mem-loads/pp}:${PERF_EVENT_MOD}" \
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
POINTS_TXT="$OUT_DIR/points.txt"
rm -f "$POINTS_TXT" 2>/dev/null || true
"$PERF_BIN" script -i "$PERF_DATA" -F time,event,addr 2>/dev/null > "$POINTS_TXT"

if [ ! -s "$POINTS_TXT" ]; then
  echo "ERROR: no samples decoded into points file: $POINTS_TXT" >&2
  echo "Try lowering SAMPLE_PERIOD or increasing BENCH_DURATION / PERF_UNTIL_EXIT=1." >&2
  exit 1
fi

echo "=== Infer address window (if needed) ==="
if [ -z "$ADDR_MIN" ] || [ -z "$ADDR_MAX" ]; then
  read -r ADDR_MIN ADDR_MAX _CNT < <(
    python3 ./infer_addr_range.py --mode "$ADDR_MODE" --window-gb "$WINDOW_GB" --window-strategy "$WINDOW_STRATEGY" --window-output full --max-lines 200000 < "$POINTS_TXT"
  )
  echo "Inferred addr range: $ADDR_MIN - $ADDR_MAX"
fi

echo "=== Plot heatmap ==="
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

echo ""
echo "Done:"
echo "  log:      $OUT_DIR/bench.log"
echo "  perf.data: $PERF_DATA"
echo "  points:   $POINTS_TXT"
echo "  heatmap:  $OUT_DIR/virt_heatmap.png"


