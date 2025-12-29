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
SKEW=${SKEW:-0.99}
BENCH_DURATION=${BENCH_DURATION:-120}
SAMPLING_CORES=${SAMPLING_CORES:-1}
CPU_START=${CPU_START:-0}

PERF_DURATION=${PERF_DURATION:-30}
SAMPLE_PERIOD=${SAMPLE_PERIOD:-50}
PERF_UNTIL_EXIT=${PERF_UNTIL_EXIT:-0}  # 1 => keep sampling until zipf_bench exits (ignores PERF_DURATION)

OUT_DIR=${OUT_DIR:-"./perf_results"}
TITLE=${TITLE:-"GUPS"}

PERF_DATA="$OUT_DIR/perf_phys.data"
PERF_TXT="$OUT_DIR/phys_points.txt"
OUT_PNG="$OUT_DIR/phys_heatmap.png"

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
./zipf_bench "$MEM_SIZE_MB" "$SKEW" "$BENCH_DURATION" "$SAMPLING_CORES" "$CPU_START" &
BENCH_PID=$!
echo "Benchmark PID: $BENCH_PID"

cleanup() {
  kill "$BENCH_PID" 2>/dev/null || true
  wait "$BENCH_PID" 2>/dev/null || true
}
trap cleanup EXIT

sleep 3

echo "=== perf record (data addr + phys addr) ==="
echo "$SUDO_PASS" | sudo -S rm -f "$PERF_DATA" "$PERF_TXT" >/dev/null 2>&1 || true

# NOTE:
#  -d records data addresses for PEBS
# --phys-data records physical addresses (PERF_SAMPLE_PHYS_ADDR)
if [ "$PERF_UNTIL_EXIT" = "1" ]; then
  echo "Sampling mode: until zipf_bench exits (PERF_UNTIL_EXIT=1)"
  echo "$SUDO_PASS" | sudo -S "$PERF_BIN" record \
    -e '{cpu/mem-loads-aux/,cpu/mem-loads/pp}:S' \
    -c "$SAMPLE_PERIOD" \
    -p "$BENCH_PID" \
    -d --phys-data \
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
    -d --phys-data \
    --no-buildid --no-buildid-cache \
    -o "$PERF_DATA" \
    -- sleep "$PERF_DURATION" >/dev/null 2>&1 || true
fi

echo "=== Extract points (time,event,phys_addr) ==="
echo "$SUDO_PASS" | sudo -S "$PERF_BIN" script -i "$PERF_DATA" -F time,event,phys_addr 2>/dev/null > "$PERF_TXT"

echo "=== Plot ==="
python3 ./plot_phys_addr.py --input "$PERF_TXT" --output "$OUT_PNG" --title "$TITLE"

echo ""
echo "Done."
echo "  perf.data: $PERF_DATA"
echo "  points:    $PERF_TXT"
echo "  figure:    $OUT_PNG"


