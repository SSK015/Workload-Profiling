#!/bin/bash
set -euo pipefail

# Profile GAPBS PageRank (twitter.sg) using PEBS data-address samples via perf,
# then produce:
#   1) virtual-address heatmap (heap/file range filtered when possible)
#   2) hot-page persistence figure

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

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

# GAPBS location (adjust if you keep it elsewhere)
GAPBS_DIR="${GAPBS_DIR:-/home/xiayanwen/app-case-studies/memtis/memtis-userspace/bench_dir/gapbs}"
GRAPH_PATH="${GRAPH_PATH:-$GAPBS_DIR/benchmark/graphs/twitter.sg}"

# PageRank parameters (match your command by default)
PR_ITERS="${PR_ITERS:-1000}"
PR_TOL="${PR_TOL:-1e-4}"
PR_TRIALS="${PR_TRIALS:-20}"

# OpenMP threads for PageRank (this is what scales multi-core sampling)
OMP_THREADS="${OMP_THREADS:-20}"

# perf sampling
SAMPLE_PERIOD="${SAMPLE_PERIOD:-50}"
PERF_DURATION="${PERF_DURATION:-15}"

# behavior
KILL_AFTER="${KILL_AFTER:-1}"   # kill pagerank after profiling window to save time

OUT_DIR="${OUT_DIR:-$ROOT_DIR/perf_results_gapbs}"
mkdir -p "$OUT_DIR"

LOG="$OUT_DIR/pagerank.log"
MAPS="$OUT_DIR/pagerank.maps"
PERF_DATA="$OUT_DIR/perf_pagerank.data"
POINTS="$OUT_DIR/pagerank_points.txt"
HEATMAP="$OUT_DIR/pagerank_virt_heatmap.png"
PERSIST="$OUT_DIR/pagerank_hot_persistence.png"

echo "=== Build gapbs (if needed) ==="
cd "$GAPBS_DIR"
if [ ! -x ./pr ]; then
  make pr
fi

if [ ! -f "$GRAPH_PATH" ]; then
  echo "ERROR: graph not found: $GRAPH_PATH" >&2
  exit 1
fi

echo "=== Launch PageRank ==="
echo "GAPBS_DIR=$GAPBS_DIR"
echo "GRAPH=$GRAPH_PATH"
echo "OMP_NUM_THREADS=$OMP_THREADS"
echo "CMD: ./pr -f benchmark/graphs/twitter.sg -i$PR_ITERS -t$PR_TOL -n$PR_TRIALS"

(
  export OMP_NUM_THREADS="$OMP_THREADS"
  ./pr -f "$GRAPH_PATH" -i"$PR_ITERS" -t"$PR_TOL" -n"$PR_TRIALS"
) >"$LOG" 2>&1 &
PR_PID=$!
echo "pagerank PID: $PR_PID"

cleanup() {
  if [ "$KILL_AFTER" = "1" ]; then
    kill "$PR_PID" 2>/dev/null || true
  fi
  wait "$PR_PID" 2>/dev/null || true
}
trap cleanup EXIT

sleep 1

echo "=== Snapshot /proc/$PR_PID/maps ==="
cat "/proc/$PR_PID/maps" >"$MAPS" 2>/dev/null || true

# Try to find the address range for twitter.sg mapping(s); otherwise pick the largest mapping.
ADDR_MIN=""
ADDR_MAX=""
read -r ADDR_MIN ADDR_MAX < <(python3 - <<'PY' "$MAPS"
import re,sys
path=sys.argv[1]
best=(0,None,None)
tw_min=None
tw_max=None
with open(path,'r',errors='ignore') as f:
    for line in f:
        m=re.match(r'^([0-9a-fA-F]+)-([0-9a-fA-F]+)\\s+\\S+\\s+\\S+\\s+\\S+\\s+\\S+\\s*(.*)$', line.strip())
        if not m:
            continue
        s=int(m.group(1),16); e=int(m.group(2),16)
        tail=m.group(3)
        if 'twitter.sg' in tail:
            if tw_min is None or s < tw_min: tw_min=s
            if tw_max is None or e > tw_max: tw_max=e
        if e-s > best[0]:
            best=(e-s, s, e)
if tw_min is not None and tw_max is not None:
    print(hex(tw_min), hex(tw_max))
elif best[1] is not None:
    print(hex(best[1]), hex(best[2]))
else:
    print('', '')
PY
)

echo "Addr filter: [$ADDR_MIN, $ADDR_MAX)"

echo "=== perf record (PEBS data addr) for ${PERF_DURATION}s ==="
rm -f "$PERF_DATA" "$POINTS" >/dev/null 2>&1 || true

"$PERF_BIN" record \
  -e '{cpu/mem-loads-aux/,cpu/mem-loads/pp}:S' \
  -c "$SAMPLE_PERIOD" \
  -p "$PR_PID" \
  -d \
  --no-buildid --no-buildid-cache \
  -o "$PERF_DATA" \
  -- sleep "$PERF_DURATION"

echo "=== perf script -> points ==="
"$PERF_BIN" script -i "$PERF_DATA" -F time,event,addr >"$POINTS"

echo "=== Plot heatmap (virtual addr) ==="
PLOT_ARGS=(--input "$POINTS" --output "$HEATMAP" --title "GAPBS PageRank (virtual addr)" --ylabel "Virtual address")
if [ -n "$ADDR_MIN" ] && [ -n "$ADDR_MAX" ]; then
  PLOT_ARGS+=(--addr-min "$ADDR_MIN" --addr-max "$ADDR_MAX" --y-offset --ylabel "Virtual address (filtered offset)")
fi
python3 "$ROOT_DIR/plot_phys_addr.py" "${PLOT_ARGS[@]}"

echo "=== Hot-page persistence ==="
HP_ARGS=(--input "$POINTS" --output "$PERSIST" --title "GAPBS PageRank hot-page persistence" --ref-window 2 --topk 1024 --bin 5)
if [ -n "$ADDR_MIN" ] && [ -n "$ADDR_MAX" ]; then
  HP_ARGS+=(--addr-min "$ADDR_MIN" --addr-max "$ADDR_MAX")
fi
python3 "$ROOT_DIR/hot_persistence.py" "${HP_ARGS[@]}"

echo ""
echo "Done:"
echo "  log:      $LOG"
echo "  maps:     $MAPS"
echo "  perf:     $PERF_DATA"
echo "  points:   $POINTS"
echo "  heatmap:  $HEATMAP"
echo "  persist:  $PERSIST"


