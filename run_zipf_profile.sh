#!/bin/bash
#
# Zipf/Uniform page-access benchmark (zipf_bench) profiling with perf/PEBS.
# Produces:
#   - virt heatmap (always, unless DO_VIRT=0)
#   - phys heatmap (optional, DO_PHYS=1)
#   - hot persistence (optional, DO_PERSIST=1)
#
# Example:
#   ./run_zipf_profile.sh
#   SKEW=0.0 MEM_SIZE_MB=4096 THREADS=32 ./run_zipf_profile.sh
#   DO_PHYS=1 DO_PERSIST=1 PERF_UNTIL_EXIT=1 SAMPLE_PERIOD=2000 ./run_zipf_profile.sh
#

# Optional: load sudo password helper if available (used for sysctl tuning / phys-data)
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
MEM_SIZE_MB=${MEM_SIZE_MB:-1024}
SKEW=${SKEW:-0.99}                   # 0.99 Zipfian, 0.0 uniform
BENCH_DURATION=${BENCH_DURATION:-120}
THREADS=${THREADS:-1}                # zipf_bench threads
CPU_START=${CPU_START:-0}
WARMUP_SEC=${WARMUP_SEC:-1}

PERF_DURATION=${PERF_DURATION:-30}
SAMPLE_PERIOD=${SAMPLE_PERIOD:-50}
PERF_UNTIL_EXIT=${PERF_UNTIL_EXIT:-0}
PERF_EVENT_MOD=${PERF_EVENT_MOD:-Su} # PEBS + user-only

DO_VIRT=${DO_VIRT:-1}
DO_PHYS=${DO_PHYS:-0}
DO_PERSIST=${DO_PERSIST:-0}

# Plot tuning
MAX_POINTS=${MAX_POINTS:-2000000}
HEATMAP_DPI=${HEATMAP_DPI:-300}
HEATMAP_GRIDSIZE=${HEATMAP_GRIDSIZE:-500}
HEATMAP_FIGSIZE=${HEATMAP_FIGSIZE:-"10,6"}
HEATMAP_COLOR_SCALE=${HEATMAP_COLOR_SCALE:-log}
HEATMAP_VMAX_PCT=${HEATMAP_VMAX_PCT:-""}

# Persistence analysis params
PERSIST_TOPK=${PERSIST_TOPK:-1024}
PERSIST_REF_START=${PERSIST_REF_START:-0}
PERSIST_REF_WINDOW=${PERSIST_REF_WINDOW:-2}
PERSIST_BIN_SEC=${PERSIST_BIN_SEC:-10}

RUN_TAG="${RUN_TAG:-$(date +%Y%m%d_%H%M%S)}"
OUT_DIR=${OUT_DIR:-"$ROOT_DIR/perf_results/zipf_${RUN_TAG}_mem${MEM_SIZE_MB}_skew${SKEW}_t${THREADS}"}
TITLE=${TITLE:-"zipf_bench (mem=${MEM_SIZE_MB}MB, skew=${SKEW}, t=${THREADS})"}

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
echo "cfg:  MEM_SIZE_MB=$MEM_SIZE_MB SKEW=$SKEW BENCH_DURATION=$BENCH_DURATION THREADS=$THREADS CPU_START=$CPU_START"
echo "perf: PERF_UNTIL_EXIT=$PERF_UNTIL_EXIT PERF_DURATION=$PERF_DURATION SAMPLE_PERIOD=$SAMPLE_PERIOD EVENT_MOD=$PERF_EVENT_MOD"
echo "do:   DO_VIRT=$DO_VIRT DO_PHYS=$DO_PHYS DO_PERSIST=$DO_PERSIST"

echo "=== Build benchmark ==="
make zipf_bench >/dev/null

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

echo "=== Start zipf_bench ==="
BENCH_LOG="$OUT_DIR/bench.log"
ZIPF_CMD=(./zipf_bench "$MEM_SIZE_MB" "$SKEW" "$BENCH_DURATION" "$THREADS" "$CPU_START")
if command -v stdbuf >/dev/null 2>&1; then
  ZIPF_CMD=(stdbuf -oL -eL "${ZIPF_CMD[@]}")
fi

set +e
"${ZIPF_CMD[@]}" >"$BENCH_LOG" 2>&1 &
BENCH_PID=$!
export BENCH_PID
set -e
echo "bench pid: $BENCH_PID"

cleanup() {
  kill "$BENCH_PID" 2>/dev/null || true
  wait "$BENCH_PID" 2>/dev/null || true
}
trap cleanup INT TERM

sleep "$WARMUP_SEC"
if ! kill -0 "$BENCH_PID" 2>/dev/null; then
  echo "ERROR: zipf_bench exited before profiling started; see log: $BENCH_LOG" >&2
  tail -n 120 "$BENCH_LOG" >&2 || true
  exit 1
fi

echo "=== Wait for benchmark to start (avoid fault-in noise) ==="
for _ in $(seq 1 6000); do # ~600s max
  if ! kill -0 "$BENCH_PID" 2>/dev/null; then
    echo "ERROR: zipf_bench exited before profiling started; see log: $BENCH_LOG" >&2
    tail -n 160 "$BENCH_LOG" >&2 || true
    exit 1
  fi
  if grep -q "Starting benchmark" "$BENCH_LOG" 2>/dev/null; then
    break
  fi
  sleep 0.1
done

echo "=== Detect heap mapping range (from benchmark log) ==="
HEAP_START=""
HEAP_END=""
for _ in $(seq 1 50); do
  HEAP_START=$(perl -ne 'if (/Populating memory \\((0x[0-9a-fA-F]+) - (0x[0-9a-fA-F]+)\\)/) { print $1; exit }' "$BENCH_LOG" || true)
  HEAP_END=$(perl -ne 'if (/Populating memory \\((0x[0-9a-fA-F]+) - (0x[0-9a-fA-F]+)\\)/) { print $2; exit }' "$BENCH_LOG" || true)
  if [ -n "$HEAP_START" ] && [ -n "$HEAP_END" ]; then
    break
  fi
  sleep 0.05
done
if [ -n "$HEAP_START" ] && [ -n "$HEAP_END" ]; then
  echo "Heap range: $HEAP_START - $HEAP_END"
else
  echo "Warning: could not parse heap range; will infer from samples when needed."
fi

echo "=== perf record (PEBS data addr) ==="
PERF_DATA="$OUT_DIR/perf.data"
rm -f "$PERF_DATA" 2>/dev/null || true

if [ "$PERF_UNTIL_EXIT" = "1" ]; then
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
  exit 1
fi

echo "=== Extract points (time,event,addr) ==="
POINTS_TXT="$OUT_DIR/points.txt"
rm -f "$POINTS_TXT" 2>/dev/null || true
"$PERF_BIN" script -i "$PERF_DATA" -F time,event,addr 2>/dev/null > "$POINTS_TXT"

if [ ! -s "$POINTS_TXT" ]; then
  echo "ERROR: no samples decoded into points file: $POINTS_TXT" >&2
  exit 1
fi

if [ "$DO_VIRT" = "1" ]; then
  echo "=== Plot virt heatmap ==="
  ADDR_MIN="$HEAP_START"
  ADDR_MAX="$HEAP_END"
  if [ -z "$ADDR_MIN" ] || [ -z "$ADDR_MAX" ]; then
    read -r ADDR_MIN ADDR_MAX _CNT < <(
      python3 ./infer_addr_range.py --mode window --window-gb 1 --window-strategy best --window-output full --max-lines 200000 < "$POINTS_TXT"
    )
  fi
  PLOT_ARGS=(--input "$POINTS_TXT" --output "$OUT_DIR/virt_heatmap.png" --title "$TITLE" --addr-min "$ADDR_MIN" --addr-max "$ADDR_MAX" --max-points "$MAX_POINTS" --dpi "$HEATMAP_DPI" --gridsize "$HEATMAP_GRIDSIZE" --figsize "$HEATMAP_FIGSIZE" --color-scale "$HEATMAP_COLOR_SCALE")
  if [ -n "$HEATMAP_VMAX_PCT" ]; then
    PLOT_ARGS+=(--vmax-percentile "$HEATMAP_VMAX_PCT")
  fi
  PLOT_ARGS+=(--y-offset --ylabel "Virtual address (heap offset)")
  python3 ./plot_phys_addr.py "${PLOT_ARGS[@]}"
fi

if [ "$DO_PHYS" = "1" ]; then
  echo "=== perf record (phys addr) ==="
  PERF_PHYS="$OUT_DIR/perf_phys.data"
  rm -f "$PERF_PHYS" 2>/dev/null || true
  # phys-data often requires privileges; use sudo when SUDO_PASS is available.
  if [ -n "${SUDO_PASS:-}" ]; then
    PERF_RUN=(sudo -S "$PERF_BIN")
    echo "$SUDO_PASS" | sudo -S true >/dev/null 2>&1 || true
  else
    PERF_RUN=("$PERF_BIN")
  fi
  "${PERF_RUN[@]}" record \
    -e "{cpu/mem-loads-aux/,cpu/mem-loads/pp}:${PERF_EVENT_MOD}" \
    -c "$SAMPLE_PERIOD" \
    -p "$BENCH_PID" \
    -d --phys-data \
    --no-buildid --no-buildid-cache \
    -o "$PERF_PHYS" \
    -- sleep "$PERF_DURATION" 2>&1 | tail -n 5

  PHYS_TXT="$OUT_DIR/phys_points.txt"
  "${PERF_RUN[@]}" script -i "$PERF_PHYS" -F time,event,phys_addr 2>/dev/null > "$PHYS_TXT" || true
  if [ -s "$PHYS_TXT" ]; then
    python3 ./plot_phys_addr.py --input "$PHYS_TXT" --output "$OUT_DIR/phys_heatmap.png" --title "$TITLE (phys)" --ylabel "Physical address"
  else
    echo "Warning: phys points empty; likely missing privilege/capability for --phys-data."
  fi
fi

if [ "$DO_PERSIST" = "1" ]; then
  echo "=== Hot persistence ==="
  ADDR_MIN="$HEAP_START"
  ADDR_MAX="$HEAP_END"
  if [ -z "$ADDR_MIN" ] || [ -z "$ADDR_MAX" ]; then
    read -r ADDR_MIN ADDR_MAX _CNT < <(
      python3 ./infer_addr_range.py --mode window --window-gb 1 --window-strategy best --window-output full --max-lines 200000 < "$POINTS_TXT"
    )
  fi
  python3 ./hot_persistence.py \
    --input "$POINTS_TXT" \
    --output "$OUT_DIR/hot_persistence.png" \
    --title "${TITLE} hot persistence" \
    --addr-min "$ADDR_MIN" --addr-max "$ADDR_MAX" \
    --ref-start "$PERSIST_REF_START" --ref-window "$PERSIST_REF_WINDOW" \
    --topk "$PERSIST_TOPK" \
    --bin "$PERSIST_BIN_SEC"
fi

echo ""
echo "Done:"
echo "  log:      $BENCH_LOG"
echo "  perf.data: $PERF_DATA"
echo "  points:   $POINTS_TXT"
echo "  out:      $OUT_DIR"


