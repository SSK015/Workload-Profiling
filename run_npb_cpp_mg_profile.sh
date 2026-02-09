#!/bin/bash
#
# Profile NPB-CPP MG (C++ OpenMP port) with perf/PEBS and produce a virtual-address heatmap.
#
# Repo: https://github.com/GMAP/NPB-CPP
#
# Example:
#   THREADS=32 SAMPLE_PERIOD=4000 ./run_npb_cpp_mg_profile.sh
#

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

# ===== Config (override via env) =====
NPB_CPP_ROOT=${NPB_CPP_ROOT:-"/data/xiayanwen/research/NPB-CPP"}
THREADS=${THREADS:-32}
CLASS=${CLASS:-D}

PERF_EVENT=${PERF_EVENT:-"cpu/mem-loads/pp"}
DO_STORE=${DO_STORE:-1}
PERF_EVENT_LOAD=${PERF_EVENT_LOAD:-"cpu/mem-loads/pp"}
PERF_EVENT_STORE=${PERF_EVENT_STORE:-"cpu/mem-stores/pp"}
SAMPLE_PERIOD=${SAMPLE_PERIOD:-4000}
PERF_EXTRA_ARGS=${PERF_EXTRA_ARGS:-"--all-user"}

RUN_TAG="${RUN_TAG:-$(date +%Y%m%d_%H%M%S)}"
OUT_DIR=${OUT_DIR:-"$ROOT_DIR/perf_results/npb_cpp_mg_${CLASS}_${RUN_TAG}_t${THREADS}"}
TITLE=${TITLE:-"NPB-CPP MG class ${CLASS} (OpenMP, t=${THREADS})"}
mkdir -p "$OUT_DIR"

# Resolve perf path (override with PERF_BIN=/path/to/perf)
PERF_BIN="${PERF_BIN:-}"
if [ -z "$PERF_BIN" ]; then
  if command -v perf >/dev/null 2>&1; then
    PERF_BIN="$(command -v perf)"
  elif [ -x /usr/local/bin/perf ]; then
    PERF_BIN="/usr/local/bin/perf"
  else
    echo "ERROR: perf not found. Install linux-tools/perf or set PERF_BIN=/path/to/perf" >&2
    exit 1
  fi
fi

NPB_OMP_DIR="$NPB_CPP_ROOT/NPB-OMP"
if [ ! -d "$NPB_OMP_DIR" ]; then
  echo "ERROR: NPB-CPP OpenMP directory not found: $NPB_OMP_DIR" >&2
  echo "Fix: git clone https://github.com/GMAP/NPB-CPP to $NPB_CPP_ROOT (or set NPB_CPP_ROOT)." >&2
  exit 1
fi

echo "npb:  $NPB_OMP_DIR"
echo "perf: $PERF_BIN"
echo "out:  $OUT_DIR"
echo "cfg:  CLASS=$CLASS THREADS=$THREADS SAMPLE_PERIOD=$SAMPLE_PERIOD EVENT=$PERF_EVENT PERF_EXTRA_ARGS='$PERF_EXTRA_ARGS'"

echo "=== Build NPB-CPP MG (OpenMP C++) ==="
cd "$NPB_OMP_DIR"
make mg "CLASS=${CLASS}"

MG_BIN="$NPB_OMP_DIR/bin/mg.${CLASS}"
if [ ! -x "$MG_BIN" ]; then
  echo "ERROR: MG binary not found after build: $MG_BIN" >&2
  exit 1
fi

echo "=== perf record (PEBS data addr) ==="
cd "$ROOT_DIR"
PERF_DATA="$OUT_DIR/perf.data"
rm -f "$PERF_DATA" 2>/dev/null || true

BENCH_LOG="$OUT_DIR/bench.log"
EVENT_ARGS=(-e "${PERF_EVENT:-$PERF_EVENT_LOAD}")
if [ "$DO_STORE" = "1" ]; then
  # Add store sampling in the same run so we can infer a store-window later.
  EVENT_ARGS=(-e "$PERF_EVENT_LOAD" -e "$PERF_EVENT_STORE")
fi
set +e
"$PERF_BIN" record \
  "${EVENT_ARGS[@]}" \
  -c "$SAMPLE_PERIOD" \
  $PERF_EXTRA_ARGS \
  -d \
  --no-buildid --no-buildid-cache \
  -o "$PERF_DATA" \
  -- env OMP_NUM_THREADS="$THREADS" OMP_PROC_BIND=close OMP_PLACES=cores "$MG_BIN" \
  >"$BENCH_LOG" 2>&1
RET=$?
set -e

if [ "$RET" -ne 0 ]; then
  echo "ERROR: MG run failed (exit=$RET); see log: $BENCH_LOG" >&2
  tail -n 120 "$BENCH_LOG" >&2 || true
  exit "$RET"
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

echo "=== Plot heatmaps (store-window) ==="
# If store samples are present, generate store-window plots for store + loads-in-store-window.
WINDOW_GB="${WINDOW_GB:-64}"
HEATMAP_COLOR_SCALE="${HEATMAP_COLOR_SCALE:-log}"
HEATMAP_VMAX_PCT="${HEATMAP_VMAX_PCT:-99.9}"
if [ "$DO_STORE" = "1" ]; then
  WINDOW_GB="$WINDOW_GB" HEATMAP_COLOR_SCALE="$HEATMAP_COLOR_SCALE" HEATMAP_VMAX_PCT="$HEATMAP_VMAX_PCT" \
    PERF_EVENT_LOAD="$PERF_EVENT_LOAD" PERF_EVENT_STORE="$PERF_EVENT_STORE" \
    ./replot_store_window.sh "$OUT_DIR" || true
else
  # Fall back to a load-derived window.
  read -r ADDR_MIN ADDR_MAX _CNT < <(
    python3 ./infer_addr_range.py --event "${PERF_EVENT:-$PERF_EVENT_LOAD}" --mode window --window-gb 8 --window-strategy best --window-output full --max-lines 200000 < "$POINTS_TXT"
  )
  python3 ./plot_phys_addr.py \
    --input "$POINTS_TXT" \
    --output "$OUT_DIR/virt_heatmap_load.png" \
    --title "$TITLE (loads)" \
    --xlabel "Wall time (sec)" \
    --event-filter "${PERF_EVENT:-$PERF_EVENT_LOAD}" \
    --addr-min "$ADDR_MIN" --addr-max "$ADDR_MAX" \
    --max-points 2000000 \
    --dpi 220 --gridsize 900 \
    --color-scale log \
    --y-offset --ylabel "Virtual address (offset)"
fi

echo ""
echo "Done:"
echo "  log:      $BENCH_LOG"
echo "  perf.data: $PERF_DATA"
echo "  points:   $POINTS_TXT"
echo "  out:      $OUT_DIR"



