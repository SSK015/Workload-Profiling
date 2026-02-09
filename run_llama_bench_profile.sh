#!/bin/bash
#
# Profile llama.cpp's llama-bench with perf/PEBS data-address samples (loads + stores),
# then generate store-window heatmaps (stores + loads-in-store-window).
#
# This script is meant to re-run the workload that produced perf_results/llama7b_f32_dense/.
#
# Example:
#   LLAMA_DIR=/data/xiayanwen/research/llama.cpp \
#   MODEL=./models/llama2_7b_chat_from_llama2c_f32.gguf \
#   THREADS=32 PROMPT=256 GEN=256 REPS=1 \
#   SAMPLE_PERIOD=20000 PERF_STOP_AFTER_SEC=60 \
#   ./run_llama_bench_profile.sh
#

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

# ===== Config (override via env) =====
LLAMA_DIR="${LLAMA_DIR:-/data/xiayanwen/research/llama.cpp}"
LLAMA_BIN="${LLAMA_BIN:-$LLAMA_DIR/build/bin/llama-bench}"

MODEL="${MODEL:-$LLAMA_DIR/models/llama2_7b_chat_from_llama2c_f32.gguf}"
THREADS="${THREADS:-32}"
PROMPT="${PROMPT:-256}"
GEN="${GEN:-256}"
REPS="${REPS:-1}"

PERF_BIN="${PERF_BIN:-perf}"
SAMPLE_PERIOD="${SAMPLE_PERIOD:-20000}"
PERF_EXTRA_ARGS="${PERF_EXTRA_ARGS:-}"
PERF_STOP_AFTER_SEC="${PERF_STOP_AFTER_SEC:-60}"

PERF_EVENT_LOAD="${PERF_EVENT_LOAD:-cpu/mem-loads/pp}"
PERF_EVENT_STORE="${PERF_EVENT_STORE:-cpu/mem-stores/pp}"

RUN_TAG="${RUN_TAG:-$(date +%Y%m%d_%H%M%S)}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/perf_results/llama7b_f32_dense_${RUN_TAG}}"
TITLE="${TITLE:-llama-bench f32 dense (t=${THREADS})}"
mkdir -p "$OUT_DIR"

WINDOW_GB="${WINDOW_GB:-64}"
HEATMAP_COLOR_SCALE="${HEATMAP_COLOR_SCALE:-log}"
HEATMAP_VMAX_PCT="${HEATMAP_VMAX_PCT:-99.9}"

echo "llama: $LLAMA_BIN"
echo "model: $MODEL"
echo "perf:  $PERF_BIN"
echo "out:   $OUT_DIR"

test -x "$LLAMA_BIN" || { echo "ERROR: llama-bench not found/executable: $LLAMA_BIN" >&2; exit 1; }
test -f "$MODEL" || { echo "ERROR: model not found: $MODEL" >&2; exit 1; }

CMD=( "$LLAMA_BIN" -m "$MODEL" -t "$THREADS" -p "$PROMPT" -n "$GEN" -r "$REPS" )
echo "cmd: ${CMD[*]}"

PERF_DATA="$OUT_DIR/perf.data"
BENCH_LOG="$OUT_DIR/bench.log"
rm -f "$PERF_DATA" "$BENCH_LOG" 2>/dev/null || true

echo "=== perf record (loads+stores, data addr) ==="
set +e
"$PERF_BIN" record \
  -e "$PERF_EVENT_LOAD" \
  -e "$PERF_EVENT_STORE" \
  -c "$SAMPLE_PERIOD" \
  -d \
  $PERF_EXTRA_ARGS \
  --no-buildid --no-buildid-cache \
  -o "$PERF_DATA" \
  -- "${CMD[@]}" \
  >"$BENCH_LOG" 2>&1
RET=$?
set -e

if [ "$RET" -ne 0 ]; then
  echo "ERROR: llama-bench run failed (exit=$RET); see log: $BENCH_LOG" >&2
  tail -n 120 "$BENCH_LOG" >&2 || true
  exit "$RET"
fi

test -s "$PERF_DATA" || { echo "ERROR: perf.data missing/empty: $PERF_DATA" >&2; exit 1; }

echo "=== Extract points (time,event,addr) ==="
POINTS_TXT="$OUT_DIR/points.txt"
rm -f "$POINTS_TXT" 2>/dev/null || true
"$PERF_BIN" script -i "$PERF_DATA" -F time,event,addr 2>/dev/null > "$POINTS_TXT"
test -s "$POINTS_TXT" || { echo "ERROR: points.txt missing/empty: $POINTS_TXT" >&2; exit 1; }

echo "=== Plot heatmaps (store-window) ==="
WINDOW_GB="$WINDOW_GB" HEATMAP_COLOR_SCALE="$HEATMAP_COLOR_SCALE" HEATMAP_VMAX_PCT="$HEATMAP_VMAX_PCT" \
  PERF_EVENT_LOAD="$PERF_EVENT_LOAD" PERF_EVENT_STORE="$PERF_EVENT_STORE" \
  ./replot_store_window.sh "$OUT_DIR"

echo ""
echo "Done:"
echo "  log:      $BENCH_LOG"
echo "  perf.data: $PERF_DATA"
echo "  points:   $POINTS_TXT"
echo "  out:      $OUT_DIR"

