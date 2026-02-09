#!/bin/bash
#
# Profile NPB MG (OpenMP version) with perf/PEBS and produce a virtual-address heatmap.
#
# Notes:
# - We use the NPB OpenMP implementation (NPB3.4-OMP) so we can run "1 process + many OpenMP threads".
# - For MG class D, the benchmark is large; compile with -mcmodel=medium to avoid large-data issues.
#
# Example:
#   THREADS=32 SAMPLE_PERIOD=2000 ./run_npb_mg_profile.sh
#

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

# ===== Config (override via env) =====
NPB_ROOT=${NPB_ROOT:-"/data/xiayanwen/research/NPB/NPB3.4/NPB3.4-OMP"}
CLASS=${CLASS:-D}
THREADS=${THREADS:-32}

PERF_EVENT=${PERF_EVENT:-"cpu/mem-loads/pp"}
DO_STORE=${DO_STORE:-1}
PERF_EVENT_LOAD=${PERF_EVENT_LOAD:-"cpu/mem-loads/pp"}
PERF_EVENT_STORE=${PERF_EVENT_STORE:-"cpu/mem-stores/pp"}
SAMPLE_PERIOD=${SAMPLE_PERIOD:-2000}
PERF_EXTRA_ARGS=${PERF_EXTRA_ARGS:-"--all-user"}   # perf modifier alternative: --all-user

# Output
RUN_TAG="${RUN_TAG:-$(date +%Y%m%d_%H%M%S)}"
OUT_DIR=${OUT_DIR:-"$ROOT_DIR/perf_results/npb_mg_${CLASS}_${RUN_TAG}_t${THREADS}"}
TITLE=${TITLE:-"NPB MG class ${CLASS} (OpenMP, t=${THREADS})"}
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

echo "npb:  $NPB_ROOT"
echo "perf: $PERF_BIN"
echo "out:  $OUT_DIR"
echo "cfg:  CLASS=$CLASS THREADS=$THREADS SAMPLE_PERIOD=$SAMPLE_PERIOD EVENT=$PERF_EVENT PERF_EXTRA_ARGS='$PERF_EXTRA_ARGS'"

if [ ! -d "$NPB_ROOT" ]; then
  echo "ERROR: NPB root not found: $NPB_ROOT" >&2
  echo "Fix: set NPB_ROOT=/path/to/NPB3.4/NPB3.4-OMP (see /data/xiayanwen/research/NPB)." >&2
  exit 1
fi

echo "=== Build NPB MG (OpenMP) ==="
cd "$NPB_ROOT"

mkdir -p bin

# Create config/make.def if missing.
if [ ! -f config/make.def ]; then
  cp -f config/make.def.template config/make.def
fi

# Ensure Fortran compiler and flags are suitable for class D.
# We overwrite key fields idempotently.
sed -i 's/^F77\\s*=.*/F77 = gfortran/' config/make.def
sed -i 's/^FLINK\\s*=.*/FLINK = gfortran/' config/make.def
sed -i 's/^FFLAGS\\s*=.*/FFLAGS = -O3 -fopenmp -funroll-loops -Wno-argument-mismatch -mcmodel=medium/' config/make.def
sed -i 's/^FLINKFLAGS\\s*=.*/FLINKFLAGS = -O3 -fopenmp -mcmodel=medium/' config/make.def

# Build only MG.
make -C MG clean >/dev/null 2>&1 || true
make mg "CLASS=${CLASS}"

MG_BIN="$NPB_ROOT/bin/mg.${CLASS}.x"
if [ ! -x "$MG_BIN" ]; then
  echo "ERROR: MG binary not found after build: $MG_BIN" >&2
  exit 1
fi

echo "=== perf record (PEBS data addr) ==="
cd "$ROOT_DIR"
PERF_DATA="$OUT_DIR/perf.data"
rm -f "$PERF_DATA" 2>/dev/null || true

# Run benchmark under perf (avoid -p attach issues; scope to this command).
BENCH_LOG="$OUT_DIR/bench.log"
EVENT_ARGS=(-e "${PERF_EVENT:-$PERF_EVENT_LOAD}")
if [ "$DO_STORE" = "1" ]; then
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
  tail -n 80 "$BENCH_LOG" >&2 || true
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
WINDOW_GB="${WINDOW_GB:-64}"
HEATMAP_COLOR_SCALE="${HEATMAP_COLOR_SCALE:-log}"
HEATMAP_VMAX_PCT="${HEATMAP_VMAX_PCT:-99.9}"
if [ "$DO_STORE" = "1" ]; then
  WINDOW_GB="$WINDOW_GB" HEATMAP_COLOR_SCALE="$HEATMAP_COLOR_SCALE" HEATMAP_VMAX_PCT="$HEATMAP_VMAX_PCT" \
    PERF_EVENT_LOAD="$PERF_EVENT_LOAD" PERF_EVENT_STORE="$PERF_EVENT_STORE" \
    ./replot_store_window.sh "$OUT_DIR" || true
else
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
    --dpi 220 --gridsize 800 \
    --color-scale log \
    --y-offset --ylabel "Virtual address (offset)"
fi

echo ""
echo "Done:"
echo "  log:      $BENCH_LOG"
echo "  perf.data: $PERF_DATA"
echo "  points:   $POINTS_TXT"
echo "  out:      $OUT_DIR"


