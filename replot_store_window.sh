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

# Optional: expand the store-derived window by padding (GiB) to avoid clipping
# loads/stores that sit just outside the inferred store window.
PAD_LOW_GB="${PAD_LOW_GB:-0}"
PAD_HIGH_GB="${PAD_HIGH_GB:-0}"
# If AUTO_PAD=1, derive PAD_*_GB from points.txt by scanning for min/max addrs
# near the store window. AUTO_PAD overrides PAD_LOW_GB/PAD_HIGH_GB when needed.
AUTO_PAD="${AUTO_PAD:-0}"
AUTO_PAD_SCAN_LOW_GB="${AUTO_PAD_SCAN_LOW_GB:-64}"
AUTO_PAD_SCAN_HIGH_GB="${AUTO_PAD_SCAN_HIGH_GB:-256}"
AUTO_PAD_SLACK_GB="${AUTO_PAD_SLACK_GB:-1}"
# Optional output tag appended to generated filenames, e.g. OUT_TAG=_pad16g
OUT_TAG="${OUT_TAG:-}"

MAX_POINTS="${MAX_POINTS:-4000000}"
HEATMAP_DPI="${HEATMAP_DPI:-160}"
HEATMAP_GRIDSIZE="${HEATMAP_GRIDSIZE:-120}"
HEATMAP_FIGSIZE="${HEATMAP_FIGSIZE:-10,5}"
HEATMAP_COLOR_SCALE="${HEATMAP_COLOR_SCALE:-log}"
HEATMAP_VMAX_PCT="${HEATMAP_VMAX_PCT:-99.9}"

# Plot title mode:
# - full: include window description suffixes (legacy behavior)
# - simple: strip timestamps from run dir name and use only "(loads)" / "(stores)"
TITLE_MODE="${TITLE_MODE:-full}"

strip_run_tag() {
  # Remove common timestamp suffix patterns from a run directory basename.
  # Examples:
  #   foo_20260208_231610 -> foo
  #   foo_2026-02-08_18-16-09 -> foo
  # Keep other suffixes like _t32, _D, etc.
  local s="$1"
  # Drop trailing date_time patterns and anything after them.
  s="$(sed -E 's/_[0-9]{8}_[0-9]{6}.*$//' <<<"$s")"
  s="$(sed -E 's/_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}.*$//' <<<"$s")"
  echo "$s"
}

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

if [ "$AUTO_PAD" = "1" ]; then
  # Derive padding based on observed user-space addr extents for load/store events.
  read -r PAD_LOW_GB PAD_HIGH_GB < <(
    python3 - <<PY
import math
import sys

points = "$POINTS"
store_min = int("$STORE_MIN", 16)
store_max = int("$STORE_MAX", 16)
scan_low = int(float("$AUTO_PAD_SCAN_LOW_GB") * (1024**3))
scan_high = int(float("$AUTO_PAD_SCAN_HIGH_GB") * (1024**3))
slack_gb = float("$AUTO_PAD_SLACK_GB")

lo = max(0, store_min - scan_low)
hi = store_max + scan_high

min_a = None
max_a = None

def consider(a: int):
    global min_a, max_a
    if a >= 0x8000_0000_0000_0000:
        return
    if a < lo or a >= hi:
        return
    if min_a is None or a < min_a:
        min_a = a
    if max_a is None or a > max_a:
        max_a = a

with open(points, "rb") as f:
    for line in f:
        parts = line.split()
        if len(parts) < 3:
            continue
        ev = parts[-2].rstrip(b":")
        if ev not in (b"cpu/mem-loads/pp", b"cpu/mem-stores/pp"):
            continue
        try:
            a = int(parts[-1], 16)
        except Exception:
            continue
        consider(a)

pad_lo = 0
pad_hi = 0
if min_a is not None and min_a < store_min:
    extra_lo_gb = (store_min - min_a) / (1024**3)
    pad_lo = int(math.ceil(extra_lo_gb + 1e-9 + slack_gb))
if max_a is not None and max_a > store_max:
    extra_hi_gb = (max_a - store_max) / (1024**3)
    pad_hi = int(math.ceil(extra_hi_gb + 1e-9 + slack_gb))

print(pad_lo, pad_hi)
PY
  )
  echo "auto_pad: PAD_LOW_GB=$PAD_LOW_GB PAD_HIGH_GB=$PAD_HIGH_GB (scan_low_gb=$AUTO_PAD_SCAN_LOW_GB scan_high_gb=$AUTO_PAD_SCAN_HIGH_GB slack_gb=$AUTO_PAD_SLACK_GB)"
fi

pad_lo_bytes=$(python3 - <<PY
print(int(float("$PAD_LOW_GB")*(1024**3)))
PY
)
pad_hi_bytes=$(python3 - <<PY
print(int(float("$PAD_HIGH_GB")*(1024**3)))
PY
)

STORE_MIN_PAD=$(python3 - <<PY
mn=int("$STORE_MIN",16)
print(hex(max(0, mn-int("$pad_lo_bytes"))))
PY
)
STORE_MAX_PAD=$(python3 - <<PY
mx=int("$STORE_MAX",16)
print(hex(mx+int("$pad_hi_bytes")))
PY
)

SPAN_GB=$(python3 - <<PY
mn=int("$STORE_MIN_PAD",16)
mx=int("$STORE_MAX_PAD",16)
print((mx-mn)/(1024**3))
PY
)

echo "store_window: $STORE_MIN .. $STORE_MAX (WINDOW_GB=$WINDOW_GB)"
if [ "$PAD_LOW_GB" != "0" ] || [ "$PAD_HIGH_GB" != "0" ]; then
  echo "padded_window: $STORE_MIN_PAD .. $STORE_MAX_PAD (span_gb=$SPAN_GB, pad_low_gb=$PAD_LOW_GB pad_high_gb=$PAD_HIGH_GB)"
fi

STORE_PNG="$OUT_DIR/virt_heatmap_store_storewin${OUT_TAG}.png"
LOAD_PNG="$OUT_DIR/virt_heatmap_load_in_storewin${OUT_TAG}.png"

BASE_TITLE="$(basename "$OUT_DIR")"
if [ "$TITLE_MODE" = "simple" ]; then
  BASE_TITLE="$(strip_run_tag "$BASE_TITLE")"
  STORE_TITLE="${BASE_TITLE} (stores)"
  LOAD_TITLE="${BASE_TITLE} (loads)"
else
  STORE_TITLE="${BASE_TITLE} (stores, store-window)"
  LOAD_TITLE="${BASE_TITLE} (loads, in store-window)"
fi

PLOT_ARGS_COMMON=(--input "$POINTS" --xlabel "Wall time (sec)" --addr-min "$STORE_MIN_PAD" --addr-max "$STORE_MAX_PAD" --y-offset --ymax-gb "$SPAN_GB" --max-points "$MAX_POINTS" --dpi "$HEATMAP_DPI" --gridsize "$HEATMAP_GRIDSIZE" --figsize "$HEATMAP_FIGSIZE" --color-scale "$HEATMAP_COLOR_SCALE" --ylabel "Virtual address (GiB offset)")
if [ -n "$HEATMAP_VMAX_PCT" ]; then
  PLOT_ARGS_COMMON+=(--vmax-percentile "$HEATMAP_VMAX_PCT")
fi

python3 "$ROOT_DIR/plot_phys_addr.py" \
  "${PLOT_ARGS_COMMON[@]}" \
  --event-filter "$PERF_EVENT_STORE" \
  --output "$STORE_PNG" \
  --title "$STORE_TITLE"

python3 "$ROOT_DIR/plot_phys_addr.py" \
  "${PLOT_ARGS_COMMON[@]}" \
  --event-filter "$PERF_EVENT_LOAD" \
  --output "$LOAD_PNG" \
  --title "$LOAD_TITLE"

echo "Wrote:"
echo "  $STORE_PNG"
echo "  $LOAD_PNG"

