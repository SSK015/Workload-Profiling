#!/usr/bin/env bash
set -euo pipefail

# Replot heatmaps using a store-derived address window.
#
# For a given OUT_DIR containing points.txt (time,event,addr),
# this script will:
#   1) infer a WINDOW_GB contiguous window from store samples (cpu/mem-stores/pp)
#   2) plot store heatmap over that window
#   3) plot load heatmap over the same window (loads-in-store-window)
#
# If the points file has no store samples, it will print a warning and skip.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

OUT_DIR="${1:-}"
if [ -z "$OUT_DIR" ]; then
  echo "Usage: $0 /abs/path/to/perf_results/<run_dir>" >&2
  exit 2
fi

POINTS="$OUT_DIR/points.txt"
test -s "$POINTS" || { echo "ERROR: missing points file: $POINTS" >&2; exit 1; }

WINDOW_GB="${WINDOW_GB:-64}"
WINDOW_STRATEGY="${WINDOW_STRATEGY:-best}"
PERF_EVENT_LOAD="${PERF_EVENT_LOAD:-cpu/mem-loads/pp}"
PERF_EVENT_STORE="${PERF_EVENT_STORE:-cpu/mem-stores/pp}"

MAX_POINTS="${MAX_POINTS:-4000000}"
HEATMAP_DPI="${HEATMAP_DPI:-160}"
HEATMAP_GRIDSIZE="${HEATMAP_GRIDSIZE:-120}"
HEATMAP_FIGSIZE="${HEATMAP_FIGSIZE:-10,5}"
HEATMAP_COLOR_SCALE="${HEATMAP_COLOR_SCALE:-log}"
HEATMAP_VMAX_PCT="${HEATMAP_VMAX_PCT:-99.9}"

STORE_WIN="$OUT_DIR/store_window_${WINDOW_GB}g.txt"
LOAD_WIN="$OUT_DIR/load_window_${WINDOW_GB}g.txt"

set +e
python3 "$ROOT_DIR/infer_addr_range.py" \
  --event "$PERF_EVENT_STORE" \
  --mode window --window-gb "$WINDOW_GB" --window-strategy "$WINDOW_STRATEGY" --window-output full \
  --max-lines 200000 < "$POINTS" > "$STORE_WIN"
rc=$?
set -e
if [ $rc -ne 0 ] || ! test -s "$STORE_WIN"; then
  echo "WARN: no store samples found (event=$PERF_EVENT_STORE) in $POINTS; skipping $OUT_DIR" >&2
  rm -f "$STORE_WIN" 2>/dev/null || true
  exit 0
fi

python3 "$ROOT_DIR/infer_addr_range.py" \
  --event "$PERF_EVENT_LOAD" \
  --mode window --window-gb "$WINDOW_GB" --window-strategy "$WINDOW_STRATEGY" --window-output full \
  --max-lines 200000 < "$POINTS" > "$LOAD_WIN" || true

read -r STORE_MIN STORE_MAX _SCNT < "$STORE_WIN"

echo "store_window: $STORE_MIN .. $STORE_MAX (WINDOW_GB=$WINDOW_GB)"

STORE_PNG="$OUT_DIR/virt_heatmap_store_storewin.png"
LOAD_PNG="$OUT_DIR/virt_heatmap_load_in_storewin.png"

PLOT_ARGS_COMMON=(--input "$POINTS" --xlabel "Wall time (sec)" --addr-min "$STORE_MIN" --addr-max "$STORE_MAX" --y-offset --ymax-gb "$WINDOW_GB" --max-points "$MAX_POINTS" --dpi "$HEATMAP_DPI" --gridsize "$HEATMAP_GRIDSIZE" --figsize "$HEATMAP_FIGSIZE" --color-scale "$HEATMAP_COLOR_SCALE" --ylabel "Virtual address (GiB offset)")
if [ -n "$HEATMAP_VMAX_PCT" ]; then
  PLOT_ARGS_COMMON+=(--vmax-percentile "$HEATMAP_VMAX_PCT")
fi

python3 "$ROOT_DIR/plot_phys_addr.py" \
  "${PLOT_ARGS_COMMON[@]}" \
  --event-filter "$PERF_EVENT_STORE" \
  --output "$STORE_PNG" \
  --title "$(basename "$OUT_DIR") (stores, store-window)"

python3 "$ROOT_DIR/plot_phys_addr.py" \
  "${PLOT_ARGS_COMMON[@]}" \
  --event-filter "$PERF_EVENT_LOAD" \
  --output "$LOAD_PNG" \
  --title "$(basename "$OUT_DIR") (loads, in store-window)"

echo "Wrote:"
echo "  $STORE_PNG"
echo "  $LOAD_PNG"

