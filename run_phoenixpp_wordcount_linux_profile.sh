#!/usr/bin/env bash
set -euo pipefail

# Profile Phoenix++ word_count (C++ MapReduce) and generate store-window heatmaps.
#
# This integrates with the existing pipeline:
#   RSS gate -> perf record -> perf script -> filter points -> replot_store_window.sh
#
# Key env vars:
#   THREADS               : MR_NUMTHREADS (default: nproc)
#   DATASET_GB            : input file size (GiB) if generating (default: 8)
#   INPUT_FILE            : use existing input file (skip generation)
#   PHX_BALLAST_GB        : optional extra touched memory to reach 20–50GiB RSS (default: 0)
#
# perf vars (same as others):
#   START_AFTER_RSS_GB, PERF_STOP_AFTER_SEC, SAMPLE_PERIOD, WINDOW_GB,
#   DROP_TOP_BUCKETS, AUTO_PAD, AUTO_YLIM, KILL_AFTER_PERF

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

if [ -f "$ROOT_DIR/perf_utils.sh" ]; then
  # shellcheck disable=SC1091
  source "$ROOT_DIR/perf_utils.sh"
fi

detect_nproc() {
  if command -v nproc >/dev/null 2>&1; then
    nproc --all
    return
  fi
  getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1
}

THREADS="${THREADS:-$(detect_nproc)}"
DATASET_GB="${DATASET_GB:-8}"
PHX_BALLAST_GB="${PHX_BALLAST_GB:-0}"
VOCAB_SIZE="${VOCAB_SIZE:-2000000}"
WORDS_PER_LINE="${WORDS_PER_LINE:-16}"
TARGET_LINE_BYTES="${TARGET_LINE_BYTES:-256}"

PERF_BIN="${PERF_BIN:-perf}"
SAMPLE_PERIOD="${SAMPLE_PERIOD:-20000}"
PERF_STOP_AFTER_SEC="${PERF_STOP_AFTER_SEC:-180}"
PERF_EVENT_LOAD="${PERF_EVENT_LOAD:-cpu/mem-loads/pp}"
PERF_EVENT_STORE="${PERF_EVENT_STORE:-cpu/mem-stores/pp}"

START_AFTER_RSS_GB="${START_AFTER_RSS_GB:-20}"
START_AFTER_RSS_TIMEOUT_SEC="${START_AFTER_RSS_TIMEOUT_SEC:-7200}"
RSS_POLL_INTERVAL_SEC="${RSS_POLL_INTERVAL_SEC:-1}"

WINDOW_GB="${WINDOW_GB:-64}"
DROP_TOP_BUCKETS="${DROP_TOP_BUCKETS:-1}"
AUTO_PAD="${AUTO_PAD:-1}"
AUTO_YLIM="${AUTO_YLIM:-1}"
KILL_AFTER_PERF="${KILL_AFTER_PERF:-1}"
MIN_BUCKET_SAMPLES="${MIN_BUCKET_SAMPLES:-0}"

RUN_TAG="${RUN_TAG:-$(date +%Y%m%d_%H%M%S)}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/perf_results/phoenixpp_wordcount_${RUN_TAG}_t${THREADS}_rss${START_AFTER_RSS_GB}g}"
mkdir -p "$OUT_DIR"

bench_log="$OUT_DIR/bench.log"
perf_data="$OUT_DIR/perf.data"
raw_points="$OUT_DIR/raw_points.txt"
points="$OUT_DIR/points.txt"
rss_log="$OUT_DIR/rss_log.txt"
rss_summary="$OUT_DIR/rss_summary.txt"

chmod +x "$ROOT_DIR/prepare_phoenixpp.sh" "$ROOT_DIR/prepare_phoenixpp_wordcount_input_file.sh" || true
BIN="$("$ROOT_DIR/prepare_phoenixpp.sh")"

INPUT_FILE="${INPUT_FILE:-}"
if [ -z "$INPUT_FILE" ]; then
  INPUT_FILE="$("$ROOT_DIR/prepare_phoenixpp_wordcount_input_file.sh" \
    DATASET_GB="$DATASET_GB" \
    VOCAB_SIZE="$VOCAB_SIZE" \
    WORDS_PER_LINE="$WORDS_PER_LINE" \
    TARGET_LINE_BYTES="$TARGET_LINE_BYTES" \
    2>/dev/null)"
fi
test -s "$INPUT_FILE" || { echo "ERROR: input file missing/empty: $INPUT_FILE" >&2; exit 1; }

export MR_NUMTHREADS="$THREADS"
export PHX_BALLAST_GB

target_rss_kb=$(python3 - <<PY
gb=float("$START_AFTER_RSS_GB")
print(int(gb*1024*1024))
PY
)

rm -f "$bench_log" "$perf_data" "$raw_points" "$points" "$rss_log" "$rss_summary" 2>/dev/null || true

echo "phoenixpp_bin: $BIN"
echo "input:  $INPUT_FILE ($(du -h "$INPUT_FILE" | awk '{print $1}'))"
echo "threads: MR_NUMTHREADS=$MR_NUMTHREADS"
echo "ballast: PHX_BALLAST_GB=$PHX_BALLAST_GB"
echo "data_gen: DATASET_GB=$DATASET_GB VOCAB_SIZE=$VOCAB_SIZE WORDS_PER_LINE=$WORDS_PER_LINE TARGET_LINE_BYTES=$TARGET_LINE_BYTES"
echo "perf:  bin=$PERF_BIN period=$SAMPLE_PERIOD stop_after=${PERF_STOP_AFTER_SEC}s"
echo "plot:  WINDOW_GB=$WINDOW_GB AUTO_PAD=$AUTO_PAD DROP_TOP_BUCKETS=$DROP_TOP_BUCKETS AUTO_YLIM=$AUTO_YLIM"
echo "out:   $OUT_DIR"

echo ""
echo "=== start phoenix++ word_count (no perf yet) ==="
(exec "$BIN" "$INPUT_FILE" 10) >"$bench_log" 2>&1 &
pid=$!
echo "pid: $pid"

# RSS monitor
(
  max_kb=0
  while kill -0 "$pid" 2>/dev/null; do
    ts=$(date +%s)
    rss_kb=$(awk '/^VmRSS:/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo 0)
    if [ "${rss_kb:-0}" -gt "$max_kb" ]; then max_kb="$rss_kb"; fi
    echo "$ts $rss_kb" >> "$rss_log"
    sleep 1
  done
  echo "max_rss_kb=$max_kb" > "$rss_summary"
  python3 - <<PY >> "$rss_summary"
kb=$max_kb
print(f"max_rss_gib={kb/1024/1024:.3f}")
PY
) >/dev/null 2>&1 &
rss_mon_pid=$!

echo "=== wait for RSS >= ${START_AFTER_RSS_GB} GiB (VmRSS) ==="
t0=$(date +%s)
while true; do
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "ERROR: phoenix++ word_count exited before reaching RSS threshold; see log: $bench_log" >&2
    tail -n 120 "$bench_log" >&2 || true
    wait "$rss_mon_pid" 2>/dev/null || true
    exit 1
  fi
  rss_kb=$(awk '/^VmRSS:/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo 0)
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
if command -v detect_perf_params >/dev/null 2>&1; then
  detect_perf_params "$pid"
else
  PERF_TARGET_FLAGS="-p $pid"
fi

"$PERF_BIN" record \
  -e "$PERF_EVENT_LOAD" -e "$PERF_EVENT_STORE" \
  -c "$SAMPLE_PERIOD" \
  $PERF_TARGET_FLAGS \
  -d \
  --no-buildid --no-buildid-cache \
  -o "$perf_data" \
  -- sleep "$PERF_STOP_AFTER_SEC" 2>&1 | tail -n 5

test -s "$perf_data" || { echo "ERROR: perf.data missing/empty: $perf_data" >&2; exit 1; }

comm="$(cat /proc/$pid/comm 2>/dev/null || echo word_count)"
"$PERF_BIN" script -i "$perf_data" -F comm,pid,time,event,addr 2>/dev/null > "$raw_points"
test -s "$raw_points" || { echo "ERROR: raw_points empty: $raw_points" >&2; exit 1; }
python3 "$ROOT_DIR/filter_perf_script_points.py" --pid "$pid" --comm "$comm" < "$raw_points" > "$points" || true
test -s "$points" || { echo "ERROR: points empty after filtering: $points" >&2; exit 1; }

if [ "$KILL_AFTER_PERF" = "1" ]; then
  echo "=== kill word_count after perf (KILL_AFTER_PERF=1) ==="
  kill -TERM "$pid" 2>/dev/null || true
fi

echo "=== wait for word_count to exit ==="
wait "$pid" 2>/dev/null || true
wait "$rss_mon_pid" 2>/dev/null || true

echo "=== plot (store-window) ==="
WINDOW_GB="$WINDOW_GB" AUTO_PAD="$AUTO_PAD" DROP_TOP_BUCKETS="$DROP_TOP_BUCKETS" AUTO_YLIM="$AUTO_YLIM" TITLE_MODE=simple \
  MIN_BUCKET_SAMPLES="$MIN_BUCKET_SAMPLES" \
  PERF_EVENT_LOAD="$PERF_EVENT_LOAD" PERF_EVENT_STORE="$PERF_EVENT_STORE" \
  "$ROOT_DIR/replot_store_window.sh" "$OUT_DIR" || true

echo ""
echo "Done: phoenix++ word_count"
echo "  out: $OUT_DIR"
echo "  rss: $rss_summary"
echo "  perf: $perf_data"
echo "  pts: $points"

