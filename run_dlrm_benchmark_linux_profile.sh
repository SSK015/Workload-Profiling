#!/usr/bin/env bash
set -euo pipefail

# Profile DLRM (Deep Learning Recommendation Model) on Linux using perf PEBS data-address samples,
# then generate store-window heatmaps.
#
# This uses the canonical reference implementation from:
#   https://github.com/facebookresearch/dlrm
#
# DLRM does:
# - Embedding table lookups (sparse features) + MLPs (dense features)
# - A feature interaction (dot/cat) + top MLP
# - Typical recommender-system workload; memory footprint dominated by embedding tables
#
# Default mode here is synthetic/random data (no dataset download).
#
# Outputs:
#   perf_results/dlrm_random_<timestamp>_t<threads>_rss<gate>g/
#
# Common knobs:
#   - TARGET_RSS_GB=30 OVERHEAD_GB=4 START_AFTER_RSS_GB=20
#   - ARCH_SPARSE_FEATURE_SIZE=64 NUM_TABLES=26
#   - MINI_BATCH_SIZE=2048 NUM_BATCHES=2000 (long enough to sample steady state)
#   - PERF_STOP_AFTER_SEC=180 SAMPLE_PERIOD=20000 WINDOW_GB=64

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

ensure_py_deps() {
  python3 - <<'PY' || return 1
import importlib
mods = ["torch", "numpy", "sklearn", "tensorboard", "mlperf_logging"]
missing = []
for m in mods:
    try:
        importlib.import_module(m)
    except Exception:
        missing.append(m)
if missing:
    raise SystemExit("missing: " + ",".join(missing))
print("deps_ok")
PY
}

install_py_deps() {
  # No venv in this environment; install to user site-packages.
  python3 -m pip install --user -U pip >/dev/null
  # CPU-only torch for py3.8
  python3 -m pip install --user --index-url https://download.pytorch.org/whl/cpu 'torch==2.1.2' --no-cache-dir
  python3 -m pip install --user 'numpy<2' 'scikit-learn<1.4' tqdm future tensorboard mlperf-logging --no-cache-dir
}

DLRM_DIR="${DLRM_DIR:-$ROOT_DIR/data/dlrm_src}"
if [ ! -d "$DLRM_DIR/.git" ]; then
  echo "=== clone DLRM repo ==="
  mkdir -p "$ROOT_DIR/data"
  git clone --depth 1 --branch main https://github.com/facebookresearch/dlrm.git "$DLRM_DIR"
fi

if ! ensure_py_deps >/dev/null 2>&1; then
  echo "=== install python deps (torch cpu + numpy/sklearn/tensorboard/mlperf-logging) ==="
  install_py_deps
fi
ensure_py_deps >/dev/null

THREADS="${THREADS:-$(detect_nproc)}"

TARGET_RSS_GB="${TARGET_RSS_GB:-30}"
OVERHEAD_GB="${OVERHEAD_GB:-4}"
START_AFTER_RSS_GB="${START_AFTER_RSS_GB:-20}"
START_AFTER_RSS_TIMEOUT_SEC="${START_AFTER_RSS_TIMEOUT_SEC:-7200}"
RSS_POLL_INTERVAL_SEC="${RSS_POLL_INTERVAL_SEC:-1}"

ARCH_SPARSE_FEATURE_SIZE="${ARCH_SPARSE_FEATURE_SIZE:-64}"
NUM_TABLES="${NUM_TABLES:-26}"

MINI_BATCH_SIZE="${MINI_BATCH_SIZE:-2048}"
NUM_BATCHES="${NUM_BATCHES:-2000}"

# DLRM knobs
ARCH_MLP_BOT="${ARCH_MLP_BOT:-13-512-256-64}"
ARCH_MLP_TOP="${ARCH_MLP_TOP:-512-256-1}"
INTERACTION_OP="${INTERACTION_OP:-dot}"
INFERENCE_ONLY="${INFERENCE_ONLY:-1}"
NUM_INDICES_PER_LOOKUP="${NUM_INDICES_PER_LOOKUP:-1}"

PERF_BIN="${PERF_BIN:-perf}"
SAMPLE_PERIOD="${SAMPLE_PERIOD:-20000}"
PERF_STOP_AFTER_SEC="${PERF_STOP_AFTER_SEC:-180}"
PERF_EVENT_LOAD="${PERF_EVENT_LOAD:-cpu/mem-loads/pp}"
PERF_EVENT_STORE="${PERF_EVENT_STORE:-cpu/mem-stores/pp}"

WINDOW_GB="${WINDOW_GB:-64}"
DROP_TOP_BUCKETS="${DROP_TOP_BUCKETS:-1}"
AUTO_PAD="${AUTO_PAD:-1}"
AUTO_YLIM="${AUTO_YLIM:-1}"
KILL_AFTER_PERF="${KILL_AFTER_PERF:-1}"

RUN_TAG="${RUN_TAG:-$(date +%Y%m%d_%H%M%S)}"
OUT_ROOT="${OUT_ROOT:-$ROOT_DIR/perf_results/dlrm_random_${RUN_TAG}_t${THREADS}_rss${START_AFTER_RSS_GB}g}"
mkdir -p "$OUT_ROOT"

bench_log="$OUT_ROOT/bench.log"
perf_data="$OUT_ROOT/perf.data"
raw_points="$OUT_ROOT/raw_points.txt"
points="$OUT_ROOT/points.txt"
rss_log="$OUT_ROOT/rss_log.txt"
rss_summary="$OUT_ROOT/rss_summary.txt"

rm -f "$bench_log" "$perf_data" "$raw_points" "$points" "$rss_log" "$rss_summary" 2>/dev/null || true

# Compute a per-table embedding row count to roughly hit TARGET_RSS_GB.
# Embedding memory ~= sum_i (n_i * D * bytes) where D=ARCH_SPARSE_FEATURE_SIZE, bytes=4 (fp32).
# We'll use equal-sized tables for simplicity.
ARCH_EMBEDDING_SIZE="$(python3 - <<PY
import math
target=float("$TARGET_RSS_GB")
over=float("$OVERHEAD_GB")
tables=int("$NUM_TABLES")
d=int("$ARCH_SPARSE_FEATURE_SIZE")
gib=1024**3
goal=max(1.0, target-over)*gib
bytes_per_row=d*4
n=int(goal/(tables*bytes_per_row))
n=max(1000, n)
print("-".join([str(n)]*tables))
PY
)"

DATA_SIZE="$(( MINI_BATCH_SIZE * NUM_BATCHES ))"

echo "dlrm:  $DLRM_DIR"
echo "out:   $OUT_ROOT"
echo "cpu:   THREADS=$THREADS (OMP_NUM_THREADS)"
echo "data:  generation=random data_size=$DATA_SIZE mini_batch=$MINI_BATCH_SIZE num_batches=$NUM_BATCHES"
echo "arch:  tables=$NUM_TABLES emb_dim=$ARCH_SPARSE_FEATURE_SIZE rows/table~$(cut -d- -f1 <<<\"$ARCH_EMBEDDING_SIZE\") interaction=$INTERACTION_OP"
echo "mem:   TARGET_RSS_GB=$TARGET_RSS_GB OVERHEAD_GB=$OVERHEAD_GB gate_start=${START_AFTER_RSS_GB}GiB"
echo "perf:  bin=$PERF_BIN period=$SAMPLE_PERIOD stop_after=${PERF_STOP_AFTER_SEC}s"
echo "plot:  WINDOW_GB=$WINDOW_GB AUTO_PAD=$AUTO_PAD DROP_TOP_BUCKETS=$DROP_TOP_BUCKETS AUTO_YLIM=$AUTO_YLIM"

export OMP_NUM_THREADS="$THREADS"
export OMP_PROC_BIND="${OMP_PROC_BIND:-close}"
export OMP_PLACES="${OMP_PLACES:-cores}"

target_rss_kb=$(python3 - <<PY
gb=float("$START_AFTER_RSS_GB")
print(int(gb*1024*1024))
PY
)

args=(
  "--data-generation=random"
  "--data-size=$DATA_SIZE"
  "--num-batches=$NUM_BATCHES"
  "--mini-batch-size=$MINI_BATCH_SIZE"
  "--arch-sparse-feature-size=$ARCH_SPARSE_FEATURE_SIZE"
  "--arch-embedding-size=$ARCH_EMBEDDING_SIZE"
  "--arch-mlp-bot=$ARCH_MLP_BOT"
  "--arch-mlp-top=$ARCH_MLP_TOP"
  "--arch-interaction-op=$INTERACTION_OP"
  "--num-indices-per-lookup=$NUM_INDICES_PER_LOOKUP"
  "--print-time"
)
if [ "$INFERENCE_ONLY" = "1" ]; then
  args+=( "--inference-only" )
fi

echo ""
echo "=== start dlrm (no perf yet) ==="
echo "cmd: python3 $DLRM_DIR/dlrm_s_pytorch.py ${args[*]}"
(cd "$DLRM_DIR"; exec python3 -u dlrm_s_pytorch.py "${args[@]}") >"$bench_log" 2>&1 &
pid=$!
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
rss_mon_pid=$!

echo "=== wait for RSS >= ${START_AFTER_RSS_GB} GiB (VmRSS) ==="
t0=$(date +%s)
while true; do
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "ERROR: dlrm exited before reaching RSS threshold; see log: $bench_log" >&2
    tail -n 200 "$bench_log" >&2 || true
    wait "$rss_mon_pid" 2>/dev/null || true
    exit 1
  fi
  rss_kb=$(awk '/^VmRSS:/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo 0)
  if [ "${rss_kb:-0}" -ge "$target_rss_kb" ]; then
    echo "RSS reached: VmRSS=${rss_kb} kB (target ${target_rss_kb} kB)"
    break
  fi
  now=$(date +%s)
  if [ $((now - t0)) -ge "$START_AFTER_RSS_TIMEOUT_SEC" ]; then
    echo "Warning: timeout waiting for RSS threshold; VmRSS=${rss_kb} kB < target ${target_rss_kb} kB. Proceeding anyway." >&2
    break
  fi
  sleep "$RSS_POLL_INTERVAL_SEC"
done

echo "=== perf record (loads+stores, data addr) for ${PERF_STOP_AFTER_SEC}s ==="
if command -v detect_perf_params >/dev/null 2>&1; then
  detect_perf_params "$pid"
else
  PERF_TARGET_FLAGS="-p $pid"
fi

"$PERF_BIN" record \
  -e "$PERF_EVENT_LOAD" -e "$PERF_EVENT_STORE" \
  -c "$SAMPLE_PERIOD" \
  $PERF_TARGET_FLAGS \
  -d \
  --no-buildid --no-buildid-cache \
  -o "$perf_data" \
  -- sleep "$PERF_STOP_AFTER_SEC" 2>&1 | tail -n 5

test -s "$perf_data" || { echo "ERROR: perf.data missing/empty: $perf_data" >&2; exit 1; }

echo "=== decode & filter points (pid=$pid) ==="
comm="$(cat /proc/$pid/comm 2>/dev/null || echo python3)"
"$PERF_BIN" script -i "$perf_data" -F comm,pid,time,event,addr 2>/dev/null > "$raw_points"
test -s "$raw_points" || { echo "ERROR: raw_points empty: $raw_points" >&2; exit 1; }
python3 "$ROOT_DIR/filter_perf_script_points.py" --pid "$pid" --comm "$comm" < "$raw_points" > "$points" || true
test -s "$points" || { echo "ERROR: points empty after filtering: $points" >&2; exit 1; }

if [ "$KILL_AFTER_PERF" = "1" ]; then
  echo "=== kill dlrm after perf (KILL_AFTER_PERF=1) ==="
  kill -TERM "$pid" 2>/dev/null || true
  sleep 2
  kill -KILL "$pid" 2>/dev/null || true
fi

echo "=== wait for dlrm to exit ==="
wait "$pid" 2>/dev/null || true
wait "$rss_mon_pid" 2>/dev/null || true

echo "=== plot (store-window) ==="
WINDOW_GB="$WINDOW_GB" AUTO_PAD="$AUTO_PAD" DROP_TOP_BUCKETS="$DROP_TOP_BUCKETS" AUTO_YLIM="$AUTO_YLIM" TITLE_MODE=simple \
  PERF_EVENT_LOAD="$PERF_EVENT_LOAD" PERF_EVENT_STORE="$PERF_EVENT_STORE" \
  "$ROOT_DIR/replot_store_window.sh" "$OUT_ROOT" || true

echo ""
echo "Done: dlrm_random"
echo "  out:   $OUT_ROOT"
echo "  rss:   $rss_summary"
echo "  perf:  $perf_data"
echo "  pts:   $points"

