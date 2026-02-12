#!/usr/bin/env bash
set -euo pipefail

# Profile representative GAPBS graph algorithms on a *real* graph dataset file (e.g. *.sg / *.wsg / *.el),
# targeting a big memory footprint (~20–50GiB RSS), then generate store-window heatmaps
# (stores + loads-in-store-window).
#
# Algorithms (default): bfs pr sssp cc
#
# Key idea:
# - Start algorithm (no perf)
# - Wait until VmRSS reaches START_AFTER_RSS_GB
# - Then perf record loads+stores for PERF_STOP_AFTER_SEC
# - Decode points, filter by PID+comm (handles perf -a fallback), and replot store-window heatmaps
#
# Requirements:
# - You provide GRAPH pointing to a real graph file:
#   - BFS/PR/CC: typically use serialized unweighted graph (*.sg)
#   - SSSP: needs weighted input; if given *.sg, we auto-convert to edge list (*.el) once and let GAPBS insert weights
#
# Example:
#   GAPBS_DIR=/path/to/gapbs \
#   GRAPH=benchmark/graphs/twitter.sg \
#   START_AFTER_RSS_GB=20 PERF_STOP_AFTER_SEC=180 SAMPLE_PERIOD=20000 WINDOW_GB=64 \
#     ./run_gapbs_suite_real_graph_bigmem_profile.sh
#
# For big-memory runs, point GRAPH to a larger graph and raise START_AFTER_RSS_GB (20–50).

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

# Provide either:
# - GRAPH_SG: unweighted serialized graph (*.sg) for bfs/pr/cc
# - GRAPH_WSG: weighted serialized graph (*.wsg) for sssp
# Or GRAPH=... as a convenience (will set one of the above based on extension).
GRAPH="${GRAPH:-}"
GRAPH_SG="${GRAPH_SG:-}"
GRAPH_WSG="${GRAPH_WSG:-}"

# Algorithms to run (space-separated): bfs pr sssp cc tc
ALGS="${ALGS:-bfs pr sssp cc}"

# Threads (passed via OpenMP env, if GAPBS build uses it)
THREADS="${THREADS:-$(detect_nproc)}"

# Algorithm iteration knobs
BFS_ITERS="${BFS_ITERS:-64}"
PR_MAX_ITERS="${PR_MAX_ITERS:-1000}"
PR_TOL="${PR_TOL:-1e-4}"
PR_TRIALS="${PR_TRIALS:-20}"
SSSP_TRIALS="${SSSP_TRIALS:-16}"
SSSP_DELTA="${SSSP_DELTA:-1}"
CC_ITERS="${CC_ITERS:-5}"
TC_TRIALS="${TC_TRIALS:-16}"

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
OUT_ROOT="${OUT_ROOT:-$ROOT_DIR/perf_results/gapbs_real_bigmem_${RUN_TAG}_t${THREADS}_rss${START_AFTER_RSS_GB}g}"
mkdir -p "$OUT_ROOT"

test -d "$GAPBS_DIR" || { echo "ERROR: GAPBS_DIR not found: $GAPBS_DIR" >&2; exit 1; }
if [ -n "$GRAPH" ] && [ -z "$GRAPH_SG" ] && [ -z "$GRAPH_WSG" ]; then
  case "$GRAPH" in
    *.sg)  GRAPH_SG="$GRAPH" ;;
    *.wsg) GRAPH_WSG="$GRAPH" ;;
    *) echo "ERROR: GRAPH must end with .sg or .wsg (or set GRAPH_SG/GRAPH_WSG explicitly)" >&2; exit 2 ;;
  esac
fi

if [ -z "$GRAPH_SG" ] && [ -z "$GRAPH_WSG" ]; then
  echo "ERROR: need GRAPH_SG and/or GRAPH_WSG (or GRAPH=...)" >&2
  echo "  bfs/pr/cc require: GRAPH_SG=.../*.sg" >&2
  echo "  sssp requires:     GRAPH_WSG=.../*.wsg" >&2
  exit 2
fi

resolve_path() {
  local p="$1"
  if [[ "$p" = /* ]]; then
    echo "$p"
  else
    echo "$GAPBS_DIR/$p"
  fi
}

GRAPH_SG_ABS=""
GRAPH_WSG_ABS=""
if [ -n "$GRAPH_SG" ]; then
  GRAPH_SG_ABS="$(resolve_path "$GRAPH_SG")"
  test -f "$GRAPH_SG_ABS" || { echo "ERROR: GRAPH_SG not found: $GRAPH_SG_ABS" >&2; exit 1; }
fi
if [ -n "$GRAPH_WSG" ]; then
  GRAPH_WSG_ABS="$(resolve_path "$GRAPH_WSG")"
  test -f "$GRAPH_WSG_ABS" || { echo "ERROR: GRAPH_WSG not found: $GRAPH_WSG_ABS" >&2; exit 1; }
fi

export OMP_NUM_THREADS="$THREADS"
export OMP_PROC_BIND="${OMP_PROC_BIND:-close}"
export OMP_PLACES="${OMP_PLACES:-cores}"

target_rss_kb=$(python3 - <<PY
gb=float("$START_AFTER_RSS_GB")
print(int(gb*1024*1024))
PY
)

echo "gapbs: $GAPBS_DIR"
echo "graph_sg:  ${GRAPH_SG_ABS:-<none>}"
echo "graph_wsg: ${GRAPH_WSG_ABS:-<none>}"
echo "algs:  $ALGS"
echo "perf:  bin=$PERF_BIN period=$SAMPLE_PERIOD stop_after=${PERF_STOP_AFTER_SEC}s"
echo "plot:  WINDOW_GB=$WINDOW_GB AUTO_PAD=$AUTO_PAD DROP_TOP_BUCKETS=$DROP_TOP_BUCKETS"
echo "out:   $OUT_ROOT"

convert_sg_to_el_for_sssp() {
  local sg="$1"
  local out_dir="$2"
  local el_out="$out_dir/$(basename "${sg%.sg}").el"
  if [ -f "$el_out" ]; then
    echo "$el_out"
    return 0
  fi
  if [ ! -x "$GAPBS_DIR/converter" ]; then
    echo "ERROR: GAPBS converter binary not found: $GAPBS_DIR/converter" >&2
    echo "Fix: cd \"$GAPBS_DIR\" && make converter" >&2
    return 1
  fi
  echo "=== Converting .sg -> .el for SSSP (one-time) ==="
  echo "in:  $sg"
  echo "out: $el_out"
  "$GAPBS_DIR/converter" -f "$sg" -e "$el_out" >/dev/null
  echo "$el_out"
}

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

  local graph_for_alg=""
  if [ "$alg" = "sssp" ]; then
    if [ -z "$GRAPH_WSG_ABS" ]; then
      echo "ERROR: sssp requires GRAPH_WSG (a *.wsg weighted serialized graph). Provide GRAPH_WSG=... or set GRAPH=/path/to/*.wsg" >&2
      return 2
    fi
    graph_for_alg="$GRAPH_WSG_ABS"
  else
    if [ -z "$GRAPH_SG_ABS" ]; then
      echo "ERROR: $alg requires GRAPH_SG (a *.sg). Provide GRAPH_SG=... or set GRAPH=/path/to/*.sg" >&2
      return 2
    fi
    graph_for_alg="$GRAPH_SG_ABS"
  fi

  local args=()
  case "$alg" in
    bfs)  args=( -f "$graph_for_alg" -n "$BFS_ITERS" ) ;;
    pr)   args=( -f "$graph_for_alg" -i "$PR_MAX_ITERS" -t "$PR_TOL" -n "$PR_TRIALS" ) ;;
    sssp) args=( -f "$graph_for_alg" -n "$SSSP_TRIALS" -d "$SSSP_DELTA" -l ) ;;
    cc)   args=( -f "$graph_for_alg" -n "$CC_ITERS" ) ;;
    tc)   args=( -f "$graph_for_alg" -n "$TC_TRIALS" ) ;;
    *)
      echo "ERROR: unknown alg: $alg (supported: bfs pr sssp cc tc)" >&2
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

