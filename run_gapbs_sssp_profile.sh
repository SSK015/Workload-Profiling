#!/bin/bash

# Optional: load sudo password helper if available (used for sysctl tuning)
SCRIPT_LIB_DIR="${SCRIPT_LIB_DIR:-/mnt/nfs/xiayanwen/research/demos/scripts}"
if [ -f "${SCRIPT_LIB_DIR}/password_lib.sh" ]; then
  # shellcheck disable=SC1090
  source "${SCRIPT_LIB_DIR}/password_lib.sh"
  define_user_password
  export SUDO_PASS="${USER_PASSWORD:-}"
fi

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

# ===== Config (override via env) =====
GAPBS_DIR=${GAPBS_DIR:-"/home/xiayanwen/app-case-studies/memtis/memtis-userspace/bench_dir/gapbs"}
GRAPH=${GRAPH:-"benchmark/graphs/twitter.sg"}

# GAPBS SSSP common flags (see GAPBS src/command_line.h):
#   -f <graph_file>  load serialized graph (*.sg/*.wsg)
#   -n <trials>      perform n trials (default 16); with no -r, each trial picks a new random source
#   -r <node>        fix start vertex (disables per-trial source randomness)
#   -d <delta>       delta parameter for delta-stepping (graph dependent)
#
# Defaults here aim to make "phase / hotness migration" visible:
#   - multiple trials => different sources
#   - enable per-trial step logging (-l) so sssp.log shows bucket progress (optional)
SSSP_ARGS=${SSSP_ARGS:-"-f ${GRAPH} -n16 -d1 -l"}

WARMUP_SEC=${WARMUP_SEC:-5}

# Profile longer + lower sampling rate by default (tune via env)
PERF_DURATION=${PERF_DURATION:-120}
SAMPLE_PERIOD=${SAMPLE_PERIOD:-2000}   # larger => lower samples/sec
PERF_UNTIL_EXIT=${PERF_UNTIL_EXIT:-0}  # 1 => keep sampling until sssp exits (ignores PERF_DURATION)

# Analysis params
MAX_POINTS=${MAX_POINTS:-2000000}
HEATMAP_DPI=${HEATMAP_DPI:-300}
HEATMAP_GRIDSIZE=${HEATMAP_GRIDSIZE:-500}
HEATMAP_FIGSIZE=${HEATMAP_FIGSIZE:-"10,6"}
HEATMAP_COLOR_SCALE=${HEATMAP_COLOR_SCALE:-log}      # log|linear
HEATMAP_VMAX_PCT=${HEATMAP_VMAX_PCT:-""}             # e.g. 99.0 (empty=auto)
PERSIST_TOPK=${PERSIST_TOPK:-2048}
PERSIST_REF_WINDOW=${PERSIST_REF_WINDOW:-2}
PERSIST_BIN_SEC=${PERSIST_BIN_SEC:-10}
ADDR_MODE=${ADDR_MODE:-window}               # dominant | window
WINDOW_GB=${WINDOW_GB:-12}                   # used when ADDR_MODE=window and /proc maps can't find graph mapping
WINDOW_STRATEGY=${WINDOW_STRATEGY:-around}   # best|min|max|around
PLOT_Y_OFFSET=${PLOT_Y_OFFSET:-1}            # 1 => plot addr-min offset (recommended); 0 => absolute virtual addr

OUT_DIR=${OUT_DIR:-"$ROOT_DIR/perf_results/gapbs_sssp"}
TITLE=${TITLE:-"GAPBS SSSP (twitter.sg)"}

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

echo "=== Start GAPBS SSSP ==="
cd "$GAPBS_DIR"

# Fail fast if SSSP isn't built / graph file missing
if [ ! -x "$GAPBS_DIR/sssp" ]; then
  echo "ERROR: GAPBS SSSP binary not found: $GAPBS_DIR/sssp" >&2
  echo "Fix: build GAPBS (from GAPBS_DIR):" >&2
  echo "  cd \"$GAPBS_DIR\" && make sssp" >&2
  exit 1
fi

# Resolve graph path (allow absolute GRAPH=...)
GRAPH_ABS="$GRAPH"
if [[ "$GRAPH_ABS" != /* ]]; then
  GRAPH_ABS="$GAPBS_DIR/$GRAPH_ABS"
fi
if [ ! -f "$GRAPH_ABS" ]; then
  echo "ERROR: graph file not found: $GRAPH_ABS" >&2
  echo "Fix: set GRAPH=... to an existing graph file (absolute path or path relative to GAPBS_DIR)." >&2
  exit 1
fi

# SSSP uses WeightedBuilder, which cannot read unweighted serialized graphs (.sg).
# If the user supplies a .sg, convert it once to an edge list (.el); SSSP will then
# auto-insert weights during graph build.
GRAPH_FOR_SSSP="$GRAPH_ABS"
if [[ "$GRAPH_FOR_SSSP" == *.sg ]]; then
  if [ ! -x "$GAPBS_DIR/converter" ]; then
    echo "ERROR: GAPBS converter binary not found: $GAPBS_DIR/converter" >&2
    echo "Fix: build GAPBS (from GAPBS_DIR):" >&2
    echo "  cd \"$GAPBS_DIR\" && make converter" >&2
    exit 1
  fi
  EL_OUT="$OUT_DIR/$(basename "${GRAPH_FOR_SSSP%.sg}").el"
  if [ ! -f "$EL_OUT" ]; then
    echo "=== Converting unweighted .sg -> .el for SSSP (one-time) ==="
    echo "in:  $GRAPH_FOR_SSSP"
    echo "out: $EL_OUT"
    "$GAPBS_DIR/converter" -f "$GRAPH_FOR_SSSP" -e "$EL_OUT" >/dev/null
  else
    echo "=== Using existing converted edge list for SSSP ==="
    echo "  $EL_OUT"
  fi
  GRAPH_FOR_SSSP="$EL_OUT"
fi

# Optional: allow user to control OpenMP threads via env
if [ -n "${OMP_NUM_THREADS:-}" ]; then
  export OMP_NUM_THREADS
fi

# Append -f at the end so it wins if SSSP_ARGS also contains -f
./sssp $SSSP_ARGS -f "$GRAPH_FOR_SSSP" >"$OUT_DIR/sssp.log" 2>&1 &
SSSP_PID=$!
export SSSP_PID
echo "sssp pid: $SSSP_PID"

cleanup() {
  # only used on signals; don't kill sssp on normal exit
  kill "$SSSP_PID" 2>/dev/null || true
}
trap cleanup INT TERM

sleep "$WARMUP_SEC"

if ! kill -0 "$SSSP_PID" 2>/dev/null; then
  echo "ERROR: sssp exited before profiling started; see log: $OUT_DIR/sssp.log" >&2
  tail -n 120 "$OUT_DIR/sssp.log" >&2 || true
  exit 1
fi

echo "=== Determine address filter range ==="
ADDR_MIN=""
ADDR_MAX=""

# Prefer mapping of the graph file if it's mmapped
MAP_RANGE=$(awk -v g="$(basename "$GRAPH_FOR_SSSP")" '$0 ~ g {print $1; exit}' "/proc/$SSSP_PID/maps" 2>/dev/null || true)
if [ -n "$MAP_RANGE" ]; then
  ADDR_MIN="0x${MAP_RANGE%-*}"
  ADDR_MAX="0x${MAP_RANGE#*-}"
  echo "Using graph mapping: $ADDR_MIN - $ADDR_MAX"
else
  # Fallback: biggest anonymous rw mapping (often where dist/frontier/bins live)
  MAP_RANGE=$(
    python3 - <<'PY'
import re, os
pid = int(os.environ["SSSP_PID"])
best = ""
best_sz = -1
with open(f"/proc/{pid}/maps", "r", encoding="utf-8", errors="ignore") as f:
    for line in f:
        parts = line.split()
        if len(parts) < 5:
            continue
        addr = parts[0]
        perms = parts[1]
        path = parts[5] if len(parts) >= 6 else ""
        if "r" not in perms or "w" not in perms:
            continue
        if path not in ("", "0"):
            continue
        m = re.match(r"^([0-9a-fA-F]+)-([0-9a-fA-F]+)$", addr)
        if not m:
            continue
        lo = int(m.group(1), 16)
        hi = int(m.group(2), 16)
        sz = hi - lo
        if sz > best_sz:
            best_sz = sz
            best = addr
print(best)
PY
  )
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
  echo "Sampling mode: until sssp exits (PERF_UNTIL_EXIT=1)"
  "$PERF_BIN" record \
    -e '{cpu/mem-loads-aux/,cpu/mem-loads/pp}:S' \
    -c "$SAMPLE_PERIOD" \
    -p "$SSSP_PID" \
    -d \
    --no-buildid --no-buildid-cache \
    -o "$PERF_DATA" \
    -- sleep 9999999 >/dev/null 2>&1 &
  PERF_REC_PID=$!
  wait "$SSSP_PID" 2>/dev/null || true
  kill -INT "$PERF_REC_PID" 2>/dev/null || true
  wait "$PERF_REC_PID" 2>/dev/null || true
else
  echo "Sampling mode: fixed duration ${PERF_DURATION}s"
  "$PERF_BIN" record \
    -e '{cpu/mem-loads-aux/,cpu/mem-loads/pp}:S' \
    -c "$SAMPLE_PERIOD" \
    -p "$SSSP_PID" \
    -d \
    --no-buildid --no-buildid-cache \
    -o "$PERF_DATA" \
    -- sleep "$PERF_DURATION" 2>&1 | tail -n 5
fi

if [ ! -s "$PERF_DATA" ]; then
  echo "ERROR: perf did not produce perf.data (or it is empty): $PERF_DATA" >&2
  echo "Most common causes:" >&2
  echo "  - sssp exited too quickly" >&2
  echo "  - perf attach failed (permission/paranoid/sysctls)" >&2
  echo "See SSSP log: $OUT_DIR/sssp.log" >&2
  exit 1
fi

echo "=== Extract points (time,event,addr) ==="
cd "$ROOT_DIR"
POINTS_TXT="$OUT_DIR/sssp_points.txt"
rm -f "$POINTS_TXT" 2>/dev/null || true
"$PERF_BIN" script -i "$PERF_DATA" -F time,event,addr 2>/dev/null > "$POINTS_TXT"

if [ ! -s "$POINTS_TXT" ]; then
  echo "ERROR: no samples decoded into points file: $POINTS_TXT" >&2
  echo "Try lowering SAMPLE_PERIOD (higher sampling) or increasing PERF_DURATION / PERF_UNTIL_EXIT=1." >&2
  exit 1
fi

echo "=== Plot heatmap ==="
if [ -z "$ADDR_MIN" ] || [ -z "$ADDR_MAX" ]; then
  read -r ADDR_MIN ADDR_MAX _CNT < <(
    python3 ./infer_addr_range.py --mode "$ADDR_MODE" --window-gb "$WINDOW_GB" --window-strategy "$WINDOW_STRATEGY" --max-lines 200000 < "$POINTS_TXT"
  )
  echo "Inferred addr range ($ADDR_MODE): $ADDR_MIN - $ADDR_MAX"
fi

PLOT_ARGS=(--input "$POINTS_TXT" --output "$OUT_DIR/virt_heatmap.png" --title "$TITLE" --addr-min "$ADDR_MIN" --addr-max "$ADDR_MAX" --max-points "$MAX_POINTS" --dpi "$HEATMAP_DPI" --gridsize "$HEATMAP_GRIDSIZE" --figsize "$HEATMAP_FIGSIZE" --color-scale "$HEATMAP_COLOR_SCALE")
if [ -n "$HEATMAP_VMAX_PCT" ]; then
  PLOT_ARGS+=(--vmax-percentile "$HEATMAP_VMAX_PCT")
fi
if [ "$PLOT_Y_OFFSET" = "1" ]; then
  PLOT_ARGS+=(--y-offset --ylabel "Virtual address (offset)")
else
  PLOT_ARGS+=(--ylabel "Virtual address")
fi
python3 ./plot_phys_addr.py "${PLOT_ARGS[@]}"

echo "=== Plot hot persistence ==="
python3 ./hot_persistence.py \
  --input "$POINTS_TXT" \
  --output "$OUT_DIR/hot_persistence.png" \
  --title "${TITLE} hot persistence" \
  --addr-min "$ADDR_MIN" --addr-max "$ADDR_MAX" \
  --ref-start 0 --ref-window "$PERSIST_REF_WINDOW" \
  --topk "$PERSIST_TOPK" \
  --bin "$PERSIST_BIN_SEC"

echo ""
echo "Done:"
echo "  perf.data:         $PERF_DATA"
echo "  points:            $POINTS_TXT"
echo "  heatmap:           $OUT_DIR/virt_heatmap.png"
echo "  hot persistence:   $OUT_DIR/hot_persistence.png"
echo "  sssp log:          $OUT_DIR/sssp.log"


