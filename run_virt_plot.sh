#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

echo -n "请输入 sudo 密码: "
read -s SUDO_PASS
echo ""

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

# ===== Config (edit as needed) =====
MEM_SIZE_MB=${MEM_SIZE_MB:-1024}
# Default to Zipfian 0.99 (set SKEW=0.0 for Uniform)
SKEW=${SKEW:-0.99}
BENCH_DURATION=${BENCH_DURATION:-120}
SAMPLING_CORES=${SAMPLING_CORES:-1}
CPU_START=${CPU_START:-0}

PERF_DURATION=${PERF_DURATION:-30}
SAMPLE_PERIOD=${SAMPLE_PERIOD:-50}
PERF_UNTIL_EXIT=${PERF_UNTIL_EXIT:-0}  # 1 => keep sampling until zipf_bench exits (ignores PERF_DURATION)

OUT_DIR=${OUT_DIR:-"./perf_results"}
TITLE=${TITLE:-"GUPS"}

PERF_DATA="$OUT_DIR/perf_virt.data"
PERF_TXT="$OUT_DIR/virt_points.txt"
OUT_PNG="$OUT_DIR/virt_heatmap.png"
BENCH_LOG="$OUT_DIR/bench.log"

mkdir -p "$OUT_DIR"

echo "=== Build benchmark (if needed) ==="
make >/dev/null

echo "=== Set perf sysctls (no throttling) ==="
echo "$SUDO_PASS" | sudo -S sh -c '
  echo 100000000 > /proc/sys/kernel/perf_event_max_sample_rate
  echo 0 > /proc/sys/kernel/perf_cpu_time_max_percent
  echo -1 > /proc/sys/kernel/perf_event_paranoid
' 2>/dev/null

echo "=== Start benchmark ==="
ZIPF_CMD=(./zipf_bench "$MEM_SIZE_MB" "$SKEW" "$BENCH_DURATION" "$SAMPLING_CORES" "$CPU_START")
# Make sure early lines (heap range) appear in bench.log quickly
if command -v stdbuf >/dev/null 2>&1; then
  ZIPF_CMD=(stdbuf -oL -eL "${ZIPF_CMD[@]}")
fi
"${ZIPF_CMD[@]}" >"$BENCH_LOG" 2>&1 &
BENCH_PID=$!
echo "Benchmark PID: $BENCH_PID"

cleanup() {
  kill "$BENCH_PID" 2>/dev/null || true
  wait "$BENCH_PID" 2>/dev/null || true
}
trap cleanup EXIT

sleep 1

echo "=== Detect heap mapping range (from benchmark log) ==="
# zipf_bench prints: Populating memory (0xAAA - 0xBBB)...
# Use perl for robust extraction across shells.
HEAP_START=""
HEAP_END=""
for _ in $(seq 1 50); do
  HEAP_START=$(perl -ne 'if (/Populating memory \((0x[0-9a-fA-F]+) - (0x[0-9a-fA-F]+)\)/) { print $1; exit }' "$BENCH_LOG" || true)
  HEAP_END=$(perl -ne 'if (/Populating memory \((0x[0-9a-fA-F]+) - (0x[0-9a-fA-F]+)\)/) { print $2; exit }' "$BENCH_LOG" || true)
  if [ -n "$HEAP_START" ] && [ -n "$HEAP_END" ]; then
    break
  fi
  sleep 0.1
done
if [ -n "$HEAP_START" ] && [ -n "$HEAP_END" ]; then
  echo "Heap range: $HEAP_START - $HEAP_END"
else
  echo "Warning: could not detect heap range from $BENCH_LOG; plotting all addresses."
  echo "bench.log head:"
  head -n 8 "$BENCH_LOG" | sed 's/^/  /'
  HEAP_START=""
  HEAP_END=""
fi

echo "=== perf record (data addr) ==="
echo "$SUDO_PASS" | sudo -S rm -f "$PERF_DATA" "$PERF_TXT" >/dev/null 2>&1 || true

# NOTE:
#  -d records data addresses for PEBS (PERF_SAMPLE_ADDR)
if [ "$PERF_UNTIL_EXIT" = "1" ]; then
  echo "Sampling mode: until zipf_bench exits (PERF_UNTIL_EXIT=1)"
  echo "$SUDO_PASS" | sudo -S "$PERF_BIN" record \
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
  echo "$SUDO_PASS" | sudo -S "$PERF_BIN" record \
    -e '{cpu/mem-loads-aux/,cpu/mem-loads/pp}:S' \
    -c "$SAMPLE_PERIOD" \
    -p "$BENCH_PID" \
    -d \
    --no-buildid --no-buildid-cache \
    -o "$PERF_DATA" \
    -- sleep "$PERF_DURATION" >/dev/null 2>&1 || true
fi

echo "=== Extract points (time,event,addr) ==="
echo "$SUDO_PASS" | sudo -S "$PERF_BIN" script -i "$PERF_DATA" -F time,event,addr 2>/dev/null > "$PERF_TXT"

echo "=== Plot ==="
PLOT_ARGS=(--input "$PERF_TXT" --output "$OUT_PNG" --title "$TITLE" --ylabel "Virtual address")
if [ -n "$HEAP_START" ] && [ -n "$HEAP_END" ]; then
  # Only plot the mmap'd heap region so Uniform looks like "most pages touched"
  PLOT_ARGS+=(--addr-min "$HEAP_START" --addr-max "$HEAP_END" --y-offset)
  PLOT_ARGS+=(--ylabel "Virtual address (heap offset)")
fi
python3 ./plot_phys_addr.py "${PLOT_ARGS[@]}"

echo ""
echo "Done."
echo "  perf.data: $PERF_DATA"
echo "  points:    $PERF_TXT"
echo "  figure:    $OUT_PNG"
echo "  bench log: $BENCH_LOG"


