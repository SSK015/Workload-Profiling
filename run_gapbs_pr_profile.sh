#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

echo -n "请输入 sudo 密码(可直接回车跳过sysctl设置): "
read -s SUDO_PASS || true
echo ""

# ===== Config (override via env) =====
GAPBS_DIR=${GAPBS_DIR:-"/home/xiayanwen/app-case-studies/memtis/memtis-userspace/bench_dir/gapbs"}
GRAPH=${GRAPH:-"benchmark/graphs/twitter.sg"}

# Default command you gave
PR_ARGS=${PR_ARGS:-"-f ${GRAPH} -i1000 -t1e-4 -n20"}

WARMUP_SEC=${WARMUP_SEC:-5}

# Profile longer + lower sampling rate by default
PERF_DURATION=${PERF_DURATION:-60}
SAMPLE_PERIOD=${SAMPLE_PERIOD:-2000}  # larger => lower samples/sec
PERF_UNTIL_EXIT=${PERF_UNTIL_EXIT:-0}  # 1 => keep sampling until pr exits (ignores PERF_DURATION)

# Analysis params
MAX_POINTS=${MAX_POINTS:-2000000}
PERSIST_TOPK=${PERSIST_TOPK:-2048}
PERSIST_REF_WINDOW=${PERSIST_REF_WINDOW:-2}
PERSIST_BIN_SEC=${PERSIST_BIN_SEC:-10}
ADDR_MODE=${ADDR_MODE:-window}   # dominant | window
WINDOW_GB=${WINDOW_GB:-12}       # used when ADDR_MODE=window and /proc maps can't find graph mapping
WINDOW_STRATEGY=${WINDOW_STRATEGY:-around} # best|min|max|around (around = center around dominant; avoids low-address outliers)
PLOT_Y_OFFSET=${PLOT_Y_OFFSET:-1} # 1 => plot addr-min offset (recommended); 0 => absolute virtual addr

OUT_DIR=${OUT_DIR:-"/home/xiayanwen/app-case-studies/memtis_ebpf_example/perf_results/gapbs_pr_long"}
TITLE=${TITLE:-"GAPBS PageRank (twitter.sg)"}

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

echo "=== Start GAPBS PageRank ==="
cd "$GAPBS_DIR"
./pr $PR_ARGS >"$OUT_DIR/pr.log" 2>&1 &
PR_PID=$!
echo "pr pid: $PR_PID"

cleanup() {
  # only used on signals; don't kill PR on normal exit
  kill "$PR_PID" 2>/dev/null || true
}
trap cleanup INT TERM

sleep "$WARMUP_SEC"

echo "=== Determine address filter range ==="
ADDR_MIN=""
ADDR_MAX=""

# Prefer mapping of the graph file if it's mmapped
MAP_RANGE=$(awk -v g="$(basename "$GRAPH")" '$0 ~ g {print $1; exit}' "/proc/$PR_PID/maps" 2>/dev/null || true)
if [ -n "$MAP_RANGE" ]; then
  ADDR_MIN="0x${MAP_RANGE%-*}"
  ADDR_MAX="0x${MAP_RANGE#*-}"
  echo "Using graph mapping: $ADDR_MIN - $ADDR_MAX"
else
  # Fallback: biggest anonymous rw mapping (often where graph/arrays live)
  MAP_RANGE=$(awk 'BEGIN{max=0;best=""} {split($1,a,"-"); start=strtonum("0x"a[1]); end=strtonum("0x"a[2]); sz=end-start; path=$6; perms=$2; if ((path=="" || path=="0") && perms ~ /rw/ && sz>max) {max=sz; best=$1}} END{print best}' "/proc/'"$PR_PID"'/maps" 2>/dev/null || true)
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
  echo "Sampling mode: until pr exits (PERF_UNTIL_EXIT=1)"
  "$PERF_BIN" record \
    -e '{cpu/mem-loads-aux/,cpu/mem-loads/pp}:S' \
    -c "$SAMPLE_PERIOD" \
    -p "$PR_PID" \
    -d \
    --no-buildid --no-buildid-cache \
    -o "$PERF_DATA" \
    -- sleep 9999999 >/dev/null 2>&1 &
  PERF_REC_PID=$!
  # Wait for pr to finish, then stop perf cleanly so it flushes perf.data
  wait "$PR_PID" 2>/dev/null || true
  kill -INT "$PERF_REC_PID" 2>/dev/null || true
  wait "$PERF_REC_PID" 2>/dev/null || true
else
  echo "Sampling mode: fixed duration ${PERF_DURATION}s"
  "$PERF_BIN" record \
    -e '{cpu/mem-loads-aux/,cpu/mem-loads/pp}:S' \
    -c "$SAMPLE_PERIOD" \
    -p "$PR_PID" \
    -d \
    --no-buildid --no-buildid-cache \
    -o "$PERF_DATA" \
    -- sleep "$PERF_DURATION" 2>&1 | tail -n 5 || true
fi

echo "=== Plot heatmap (streaming) ==="
cd /home/xiayanwen/app-case-studies/memtis_ebpf_example

if [ -z "$ADDR_MIN" ] || [ -z "$ADDR_MAX" ]; then
  # Infer dominant 1GB bucket from first 200k samples
  read -r ADDR_MIN ADDR_MAX _CNT < <(
    "$PERF_BIN" script -i "$PERF_DATA" -F time,event,addr 2>/dev/null | \
      python3 ./infer_addr_range.py --mode "$ADDR_MODE" --window-gb "$WINDOW_GB" --window-strategy "$WINDOW_STRATEGY" --max-lines 200000
  )
  echo "Inferred addr range ($ADDR_MODE): $ADDR_MIN - $ADDR_MAX"
fi

PLOT_ARGS=(--input - --output "$OUT_DIR/virt_heatmap.png" --title "$TITLE" --addr-min "$ADDR_MIN" --addr-max "$ADDR_MAX" --max-points "$MAX_POINTS")
if [ "$PLOT_Y_OFFSET" = "1" ]; then
  PLOT_ARGS+=(--y-offset --ylabel "Virtual address (offset)")
else
  PLOT_ARGS+=(--ylabel "Virtual address")
fi
"$PERF_BIN" script -i "$PERF_DATA" -F time,event,addr 2>/dev/null | python3 ./plot_phys_addr.py "${PLOT_ARGS[@]}"

echo "=== Plot hot persistence (streaming) ==="
"$PERF_BIN" script -i "$PERF_DATA" -F time,event,addr 2>/dev/null | \
  python3 ./hot_persistence.py \
    --input - \
    --output "$OUT_DIR/hot_persistence.png" \
    --title "${TITLE} hot persistence" \
    --addr-min "$ADDR_MIN" --addr-max "$ADDR_MAX" \
    --ref-start 0 --ref-window "$PERSIST_REF_WINDOW" \
    --topk "$PERSIST_TOPK" \
    --bin "$PERSIST_BIN_SEC"

echo ""
echo "Done:"
echo "  perf.data:         $PERF_DATA"
echo "  heatmap:           $OUT_DIR/virt_heatmap.png"
echo "  hot persistence:   $OUT_DIR/hot_persistence.png"
echo "  pr log:            $OUT_DIR/pr.log"
