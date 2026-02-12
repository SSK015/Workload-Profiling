#!/usr/bin/env bash
set -euo pipefail

# Run the AIFM paper's DataFrame application in "All in memory" mode (pure Linux),
# targeting ~31GiB max working set as in the AIFM artifact (Fig.7), and profile
# memory data-address samples with perf/PEBS (loads + stores).
#
# Notes:
# - The upstream DataFrame app hardcodes "/mnt/all.csv". To avoid requiring sudo
#   or special mounts, we patch the source (in the cloned artifact repo) to allow
#   overriding via env var AIFM_DF_CSV, while keeping the original default.
# - Input creation (~16GB download) is handled by prepare_aifm_dataframe_input.sh.
#
# Example:
#   SAMPLE_PERIOD=20000 WINDOW_GB=32 AUTO_PAD=1 TITLE_MODE=simple \
#     ./run_aifm_dataframe_linux_profile.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

if [ -f "$ROOT_DIR/perf_utils.sh" ]; then
  # shellcheck disable=SC1091
  source "$ROOT_DIR/perf_utils.sh"
fi

# ===== Config (override via env) =====
AIFM_GIT_URL="${AIFM_GIT_URL:-https://github.com/AIFM-sys/AIFM}"
# Keep 3rd party artifact under data/ (already gitignored)
AIFM_REPO_DIR="${AIFM_REPO_DIR:-$ROOT_DIR/data/aifm_artifact/AIFM}"

DATA_DIR="${DATA_DIR:-$ROOT_DIR/data/aifm_dataframe}"
CSV_PATH="${CSV_PATH:-$DATA_DIR/all.csv}"

PERF_BIN="${PERF_BIN:-perf}"
SAMPLE_PERIOD="${SAMPLE_PERIOD:-20000}"
PERF_EXTRA_ARGS="${PERF_EXTRA_ARGS:-}"

DO_STORE="${DO_STORE:-1}"
PERF_EVENT_LOAD="${PERF_EVENT_LOAD:-cpu/mem-loads/pp}"
PERF_EVENT_STORE="${PERF_EVENT_STORE:-cpu/mem-stores/pp}"

PIN_CPU="${PIN_CPU:-1}"
CPU="${CPU:-1}"

# Optional: stop perf early while letting the program finish (seconds).
# 0 means profile until program exits.
PERF_STOP_AFTER_SEC="${PERF_STOP_AFTER_SEC:-0}"

WINDOW_GB="${WINDOW_GB:-32}"
AUTO_PAD="${AUTO_PAD:-1}"
TITLE_MODE="${TITLE_MODE:-simple}"
HEATMAP_COLOR_SCALE="${HEATMAP_COLOR_SCALE:-log}"
HEATMAP_VMAX_PCT="${HEATMAP_VMAX_PCT:-99.9}"

RUN_TAG="${RUN_TAG:-$(date +%Y%m%d_%H%M%S)}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/perf_results/aifm_dataframe_linux_${RUN_TAG}}"
mkdir -p "$OUT_DIR"

echo "out:   $OUT_DIR"
echo "aifm:  $AIFM_REPO_DIR"
echo "data:  $CSV_PATH"
echo "perf:  $PERF_BIN (period=$SAMPLE_PERIOD, stop_after=$PERF_STOP_AFTER_SEC)"

echo "=== ensure AIFM artifact repo ==="
if [ ! -d "$AIFM_REPO_DIR/.git" ]; then
  mkdir -p "$(dirname "$AIFM_REPO_DIR")"
  git clone --depth 1 "$AIFM_GIT_URL" "$AIFM_REPO_DIR"
fi

DF_SRC="$AIFM_REPO_DIR/aifm/DataFrame/original"
MAIN_CC="$DF_SRC/app/main.cc"

test -d "$DF_SRC" || { echo "ERROR: DataFrame original dir not found: $DF_SRC" >&2; exit 1; }
test -f "$MAIN_CC" || { echo "ERROR: DataFrame main.cc not found: $MAIN_CC" >&2; exit 1; }

echo "=== patch DataFrame main.cc to accept AIFM_DF_CSV (if needed) ==="
python3 - <<PY
from pathlib import Path
import re, sys

p = Path(r"$MAIN_CC")
txt = p.read_text()

if "AIFM_DF_CSV" in txt:
    print("patch: already present")
    sys.exit(0)

# Replace the hardcoded path string with an env-var override expression.
needle = '"/mnt/all.csv"'
if needle not in txt:
    print("patch: ERROR: expected literal /mnt/all.csv not found; upstream changed?", file=sys.stderr)
    sys.exit(1)

txt2 = txt.replace(needle, '(std::getenv("AIFM_DF_CSV") ? std::getenv("AIFM_DF_CSV") : "/mnt/all.csv")')

# Ensure <cstdlib> is available for std::getenv (it already is, but keep safe if upstream changes).
if "#include <cstdlib>" not in txt2:
    # Insert after the first include block line.
    txt2 = txt2.replace('#include <cmath>\\n', '#include <cmath>\\n#include <cstdlib>\\n', 1)

p.write_text(txt2)
print("patch: applied AIFM_DF_CSV override")
PY

echo "=== prepare input (download + build all.csv) ==="
DATA_DIR="$DATA_DIR" CSV_PATH="$CSV_PATH" "$ROOT_DIR/prepare_aifm_dataframe_input.sh"
test -s "$CSV_PATH" || { echo "ERROR: CSV missing/empty: $CSV_PATH" >&2; exit 1; }

echo "=== build DataFrame (original) ==="
BUILD_DIR="${BUILD_DIR:-$DF_SRC/build_linux}"
rm -rf "$BUILD_DIR" 2>/dev/null || true
cmake -S "$DF_SRC" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release ${CMAKE_ARGS:-}
cmake --build "$BUILD_DIR" -j "${BUILD_JOBS:-$(nproc)}" --target main

DF_BIN="$BUILD_DIR/bin/main"
test -x "$DF_BIN" || { echo "ERROR: DataFrame binary not found: $DF_BIN" >&2; exit 1; }

echo "=== snapshot /proc meminfo ==="
cp /proc/meminfo "$OUT_DIR/meminfo.txt" 2>/dev/null || true

BENCH_LOG="$OUT_DIR/bench.log"
PERF_DATA="$OUT_DIR/perf.data"
RAW_POINTS="$OUT_DIR/raw_points.txt"
POINTS="$OUT_DIR/points.txt"
RSS_LOG="$OUT_DIR/rss_log.txt"
RSS_SUMMARY="$OUT_DIR/rss_summary.txt"

rm -f "$BENCH_LOG" "$PERF_DATA" "$RAW_POINTS" "$POINTS" 2>/dev/null || true
rm -f "$RSS_LOG" "$RSS_SUMMARY" 2>/dev/null || true

EVENT_ARGS=(-e "$PERF_EVENT_LOAD")
if [ "$DO_STORE" = "1" ]; then
  EVENT_ARGS+=(-e "$PERF_EVENT_STORE")
fi

CMD=( "$DF_BIN" )
if [ "$PIN_CPU" = "1" ]; then
  CMD=( taskset -c "$CPU" "${CMD[@]}" )
fi

echo "cmd: AIFM_DF_CSV=$CSV_PATH ${CMD[*]}"

if [ "$PERF_STOP_AFTER_SEC" != "0" ]; then
  echo "=== start DataFrame (no perf yet), then record for ${PERF_STOP_AFTER_SEC}s ==="
  (
    exec env AIFM_DF_CSV="$CSV_PATH" "${CMD[@]}"
  ) >"$BENCH_LOG" 2>&1 &
  BENCH_PID=$!
  echo "BENCH_PID=$BENCH_PID"

  # Track RSS over time while the process runs (to validate ~31GiB working set).
  (
    max_kb=0
    while kill -0 "$BENCH_PID" 2>/dev/null; do
      ts=$(date +%s)
      rss_kb=$(awk '/^VmRSS:/ {print $2}' "/proc/$BENCH_PID/status" 2>/dev/null || echo 0)
      if [ "${rss_kb:-0}" -gt "$max_kb" ]; then
        max_kb="$rss_kb"
      fi
      echo "$ts $rss_kb" >> "$RSS_LOG"
      sleep 1
    done
    echo "max_rss_kb=$max_kb" > "$RSS_SUMMARY"
    python3 - <<PY >> "$RSS_SUMMARY"
kb=$max_kb
print(f"max_rss_gib={kb/1024/1024:.3f}")
PY
  ) >/dev/null 2>&1 &
  RSS_MON_PID=$!

  # Prefer system-wide sampling when nothrottle perf has -p issues.
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
    $PERF_EXTRA_ARGS \
    --no-buildid --no-buildid-cache \
    -o "$PERF_DATA" \
    -- sleep "$PERF_STOP_AFTER_SEC" 2>&1 | tail -n 5

  echo "=== wait for DataFrame to exit ==="
  wait "$BENCH_PID" 2>/dev/null || true
  # Let RSS monitor flush summary.
  wait "${RSS_MON_PID:-0}" 2>/dev/null || true

  echo "=== decode & filter points (pid=$BENCH_PID, comm=main) ==="
  "$PERF_BIN" script -i "$PERF_DATA" -F comm,pid,time,event,addr 2>/dev/null > "$RAW_POINTS"
  test -s "$RAW_POINTS" || { echo "ERROR: raw_points empty: $RAW_POINTS" >&2; exit 1; }
  python3 "$ROOT_DIR/filter_perf_script_points.py" --pid "$BENCH_PID" --comm main < "$RAW_POINTS" > "$POINTS"
  test -s "$POINTS" || { echo "ERROR: points empty after filtering: $POINTS" >&2; exit 1; }
else
  echo "=== perf record (until program exits) ==="
  set +e
  "$PERF_BIN" record \
    "${EVENT_ARGS[@]}" \
    -c "$SAMPLE_PERIOD" \
    -d \
    $PERF_EXTRA_ARGS \
    --no-buildid --no-buildid-cache \
    -o "$PERF_DATA" \
    -- env AIFM_DF_CSV="$CSV_PATH" "${CMD[@]}" \
    >"$BENCH_LOG" 2>&1
  RET=$?
  set -e
  if [ "$RET" -ne 0 ]; then
    echo "ERROR: DataFrame run failed (exit=$RET); see log: $BENCH_LOG" >&2
    tail -n 160 "$BENCH_LOG" >&2 || true
    exit "$RET"
  fi
fi

test -s "$PERF_DATA" || { echo "ERROR: perf.data missing/empty: $PERF_DATA" >&2; exit 1; }

if [ "$PERF_STOP_AFTER_SEC" = "0" ]; then
  echo "=== extract points (time,event,addr) ==="
  "$PERF_BIN" script -i "$PERF_DATA" -F time,event,addr 2>/dev/null > "$POINTS"
  test -s "$POINTS" || { echo "ERROR: points.txt missing/empty: $POINTS" >&2; exit 1; }
fi

echo "=== plot (store-window; AUTO_PAD=$AUTO_PAD; WINDOW_GB=$WINDOW_GB) ==="
WINDOW_GB="$WINDOW_GB" AUTO_PAD="$AUTO_PAD" TITLE_MODE="$TITLE_MODE" \
  HEATMAP_COLOR_SCALE="$HEATMAP_COLOR_SCALE" HEATMAP_VMAX_PCT="$HEATMAP_VMAX_PCT" \
  PERF_EVENT_LOAD="$PERF_EVENT_LOAD" PERF_EVENT_STORE="$PERF_EVENT_STORE" \
  "$ROOT_DIR/replot_store_window.sh" "$OUT_DIR" || true

echo ""
echo "Done:"
echo "  bench log: $BENCH_LOG"
echo "  perf.data: $PERF_DATA"
echo "  points:    $POINTS"
if [ -s "$RSS_SUMMARY" ]; then
  echo "  rss:       $RSS_SUMMARY"
fi
echo "  out:       $OUT_DIR"

