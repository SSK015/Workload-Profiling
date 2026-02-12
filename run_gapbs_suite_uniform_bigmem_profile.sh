#!/usr/bin/env bash
set -euo pipefail

# Profile a few representative GAPBS graph algorithms on a large *uniform synthetic* graph,
# targeting a big memory footprint (~20–50GiB RSS), then generate store-window heatmaps
# (stores + loads-in-store-window).
#
# Representative algorithms:
# - bfs  : frontier-style traversal
# - pr   : iterative, streaming-ish over edges/vertices
# - sssp : irregular, bucketed delta-stepping
# - cc   : label propagation / union-find style
#
# GAPBS uniform generator flags (supported by GAPBS):
#   -u <scale>   graph has 2^scale vertices
#   -k <degree>  average degree
#
# Key idea:
# - Start algorithm (no perf)
# - Wait until VmRSS reaches START_AFTER_RSS_GB
# - Then perf record loads+stores for PERF_STOP_AFTER_SEC
# - Decode points, filter by PID+comm (handles perf -a fallback), and replot store-window heatmaps
#
# Example:
#   GAPBS_DIR=/path/to/gapbs \
#   TARGET_RSS_GB=30 START_AFTER_RSS_GB=25 DEGREE=16 THREADS=32 \
#   PERF_STOP_AFTER_SEC=180 SAMPLE_PERIOD=20000 WINDOW_GB=64 \
#     ./run_gapbs_suite_uniform_bigmem_profile.sh

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

# ===== Config (override via env) =====
# Default to a local GAPBS checkout under this repo (gitignored).
GAPBS_DIR=${GAPBS_DIR:-"$ROOT_DIR/data/gapbs_src"}

# Algorithms to run (space-separated): bfs pr sssp cc
ALGS="${ALGS:-bfs pr sssp cc}"

# Synthetic graph size knobs
TARGET_RSS_GB="${TARGET_RSS_GB:-30}"
OVERHEAD_GB="${OVERHEAD_GB:-4}"   # reserved for per-alg extra arrays + allocator overhead
DEGREE="${DEGREE:-16}"

# If SCALE is not set, infer it from TARGET_RSS_GB/DEGREE using a rough CSR sizing model.
SCALE="${SCALE:-}"

# Threads (passed via OpenMP env, if GAPBS build uses it)
THREADS="${THREADS:-$(detect_nproc)}"

# Algorithm iteration knobs (keep reasonably long so we can sample steady-state)
BFS_ITERS="${BFS_ITERS:-64}"
PR_MAX_ITERS="${PR_MAX_ITERS:-1000}"
PR_TOL="${PR_TOL:-1e-4}"
PR_TRIALS="${PR_TRIALS:-20}"
SSSP_TRIALS="${SSSP_TRIALS:-16}"
SSSP_DELTA="${SSSP_DELTA:-1}"
CC_ITERS="${CC_ITERS:-5}"

# perf sampling
PERF_BIN="${PERF_BIN:-perf}"
SAMPLE_PERIOD="${SAMPLE_PERIOD:-20000}"
PERF_STOP_AFTER_SEC="${PERF_STOP_AFTER_SEC:-180}"
DO_STORE="${DO_STORE:-1}"
PERF_EVENT_LOAD="${PERF_EVENT_LOAD:-cpu/mem-loads/pp}"
PERF_EVENT_STORE="${PERF_EVENT_STORE:-cpu/mem-stores/pp}"

# Delay profiling until RSS reaches this threshold (GiB)
START_AFTER_RSS_GB="${START_AFTER_RSS_GB:-20}"
START_AFTER_RSS_TIMEOUT_SEC="${START_AFTER_RSS_TIMEOUT_SEC:-7200}"
RSS_POLL_INTERVAL_SEC="${RSS_POLL_INTERVAL_SEC:-1}"

# Plotting / window inference
WINDOW_GB="${WINDOW_GB:-64}"
DROP_TOP_BUCKETS="${DROP_TOP_BUCKETS:-1}" # ignore stack-dominated top bucket when inferring store window
AUTO_PAD="${AUTO_PAD:-1}"
TITLE_MODE="${TITLE_MODE:-simple}"
HEATMAP_COLOR_SCALE="${HEATMAP_COLOR_SCALE:-log}"
HEATMAP_VMAX_PCT="${HEATMAP_VMAX_PCT:-99.9}"

# If 1, terminate the benchmark process right after perf sampling + point decoding,
# so we can plot immediately without waiting for all trials to finish.
KILL_AFTER_PERF="${KILL_AFTER_PERF:-0}"

RUN_TAG="${RUN_TAG:-$(date +%Y%m%d_%H%M%S)}"
OUT_ROOT="${OUT_ROOT:-$ROOT_DIR/perf_results/gapbs_uniform_bigmem_${RUN_TAG}_s${SCALE:-auto}_k${DEGREE}_t${THREADS}_rss${START_AFTER_RSS_GB}g}"
mkdir -p "$OUT_ROOT"

if [ -z "$SCALE" ]; then
  SCALE="$(python3 - <<PY
import math, os
target=float(os.environ.get("TARGET_RSS_GB","30"))
over=float(os.environ.get("OVERHEAD_GB","4"))
deg=int(os.environ.get("DEGREE","16"))
gib=1024**3
goal=max(1.0, target-over) * gib
# Rough graph bytes ~= 8*N*(deg+1) (same model as run_gapbs_bfs_uniform_target_mem.sh)
n=goal / (8.0*(deg+1))
scale=int(math.floor(math.log2(max(2.0,n))))
print(max(1, scale))
PY
  )"
fi

echo "gapbs: $GAPBS_DIR"
echo "algs:  $ALGS"
echo "graph: uniform (-u $SCALE -k $DEGREE)"
echo "mem:   TARGET_RSS_GB=$TARGET_RSS_GB OVERHEAD_GB=$OVERHEAD_GB START_AFTER_RSS_GB=$START_AFTER_RSS_GB"
echo "perf:  bin=$PERF_BIN period=$SAMPLE_PERIOD stop_after=${PERF_STOP_AFTER_SEC}s loads=$PERF_EVENT_LOAD stores=$PERF_EVENT_STORE"
echo "plot:  WINDOW_GB=$WINDOW_GB AUTO_PAD=$AUTO_PAD DROP_TOP_BUCKETS=$DROP_TOP_BUCKETS"
echo "out:   $OUT_ROOT"

test -d "$GAPBS_DIR" || { echo "ERROR: GAPBS_DIR not found: $GAPBS_DIR" >&2; exit 1; }

export OMP_NUM_THREADS="$THREADS"
export OMP_PROC_BIND="${OMP_PROC_BIND:-close}"
export OMP_PLACES="${OMP_PLACES:-cores}"

target_rss_kb=$(python3 - <<PY
gb=float("$START_AFTER_RSS_GB")
print(int(gb*1024*1024))
PY
)

run_one() {
  local alg="$1"
  local out_dir="$OUT_ROOT/$alg"
  mkdir -p "$out_dir"

  local bin="$GAPBS_DIR/$alg"
  if [ ! -x "$bin" ]; then
    echo "=== build GAPBS $alg ==="
    (cd "$GAPBS_DIR" && make "$alg")
  fi
  test -x "$bin" || { echo "ERROR: GAPBS binary not found: $bin" >&2; return 1; }

  local args=()
  case "$alg" in
    bfs)  args=( -u "$SCALE" -k "$DEGREE" -n "$BFS_ITERS" ) ;;
    pr)   args=( -u "$SCALE" -k "$DEGREE" -i "$PR_MAX_ITERS" -t "$PR_TOL" -n "$PR_TRIALS" ) ;;
    sssp) args=( -u "$SCALE" -k "$DEGREE" -n "$SSSP_TRIALS" -d "$SSSP_DELTA" -l ) ;;
    cc)   args=( -u "$SCALE" -k "$DEGREE" -n "$CC_ITERS" ) ;;
    *)
      echo "ERROR: unknown alg: $alg (supported: bfs pr sssp cc)" >&2
      return 2
      ;;
  esac

  local bench_log="$out_dir/bench.log"
  local perf_data="$out_dir/perf.data"
  local raw_points="$out_dir/raw_points.txt"
  local points="$out_dir/points.txt"
  local rss_log="$out_dir/rss_log.txt"
  local rss_summary="$out_dir/rss_summary.txt"

  rm -f "$bench_log" "$perf_data" "$raw_points" "$points" "$rss_log" "$rss_summary" 2>/dev/null || true

  echo ""
  echo "=== start $alg (no perf yet) ==="
  echo "cmd: $bin ${args[*]}"
  (cd "$GAPBS_DIR"; exec "$bin" "${args[@]}") >"$bench_log" 2>&1 &
  local pid=$!
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
  local rss_mon_pid=$!

  echo "=== wait for RSS >= ${START_AFTER_RSS_GB} GiB (VmRSS) ==="
  local t0
  t0=$(date +%s)
  while true; do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "ERROR: $alg exited before reaching RSS threshold; see log: $bench_log" >&2
      tail -n 120 "$bench_log" >&2 || true
      wait "$rss_mon_pid" 2>/dev/null || true
      return 1
    fi
    local rss_kb
    rss_kb=$(awk '/VmRSS:/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo 0)
    if [ "${rss_kb:-0}" -ge "$target_rss_kb" ]; then
      echo "RSS reached: VmRSS=${rss_kb} kB (target ${target_rss_kb} kB)"
      break
    fi
    local now
    now=$(date +%s)
    if [ $((now - t0)) -ge "$START_AFTER_RSS_TIMEOUT_SEC" ]; then
      echo "Warning: timeout waiting for RSS threshold; VmRSS=${rss_kb} kB < target ${target_rss_kb} kB. Proceeding anyway." >&2
      break
    fi
    sleep "$RSS_POLL_INTERVAL_SEC"
  done

  echo "=== perf record (loads+stores, data addr) for ${PERF_STOP_AFTER_SEC}s ==="
  local event_args=( -e "$PERF_EVENT_LOAD" )
  if [ "$DO_STORE" = "1" ]; then
    event_args+=( -e "$PERF_EVENT_STORE" )
  fi

  if command -v detect_perf_params >/dev/null 2>&1; then
    detect_perf_params "$pid"
  else
    PERF_TARGET_FLAGS="-p $pid"
  fi

  "$PERF_BIN" record \
    "${event_args[@]}" \
    -c "$SAMPLE_PERIOD" \
    $PERF_TARGET_FLAGS \
    -d \
    --no-buildid --no-buildid-cache \
    -o "$perf_data" \
    -- sleep "$PERF_STOP_AFTER_SEC" 2>&1 | tail -n 5

  test -s "$perf_data" || { echo "ERROR: perf.data missing/empty: $perf_data" >&2; return 1; }

  echo "=== decode & filter points (pid=$pid, comm=$alg) ==="
  "$PERF_BIN" script -i "$perf_data" -F comm,pid,time,event,addr 2>/dev/null > "$raw_points"
  test -s "$raw_points" || { echo "ERROR: raw_points empty: $raw_points" >&2; return 1; }
  python3 "$ROOT_DIR/filter_perf_script_points.py" --pid "$pid" --comm "$alg" < "$raw_points" > "$points"
  test -s "$points" || { echo "ERROR: points empty after filtering: $points" >&2; return 1; }

  if [ "$KILL_AFTER_PERF" = "1" ]; then
    echo "=== kill $alg after perf (KILL_AFTER_PERF=1) ==="
    kill -TERM "$pid" 2>/dev/null || true
    sleep 2
    kill -KILL "$pid" 2>/dev/null || true
  fi

  echo "=== wait for $alg to exit ==="
  wait "$pid" 2>/dev/null || true
  wait "$rss_mon_pid" 2>/dev/null || true

  echo "=== plot (store-window) ==="
  WINDOW_GB="$WINDOW_GB" AUTO_PAD="$AUTO_PAD" TITLE_MODE="$TITLE_MODE" DROP_TOP_BUCKETS="$DROP_TOP_BUCKETS" \
    HEATMAP_COLOR_SCALE="$HEATMAP_COLOR_SCALE" HEATMAP_VMAX_PCT="$HEATMAP_VMAX_PCT" \
    PERF_EVENT_LOAD="$PERF_EVENT_LOAD" PERF_EVENT_STORE="$PERF_EVENT_STORE" \
    "$ROOT_DIR/replot_store_window.sh" "$out_dir" || true

  echo "Done: $alg"
  echo "  out:   $out_dir"
  echo "  rss:   $rss_summary"
  echo "  perf:  $perf_data"
  echo "  pts:   $points"
}

for alg in $ALGS; do
  run_one "$alg"
done

echo ""
echo "Suite done: $OUT_ROOT"

