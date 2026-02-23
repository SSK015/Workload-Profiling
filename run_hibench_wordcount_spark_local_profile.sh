#!/usr/bin/env bash
set -euo pipefail

# Run HiBench Spark WordCount on a local text dataset, targeting a peak RSS of 20–50GiB.
#
# How we hit 20–50GiB reliably:
# - Fix driver heap (Xms=Xmx) and use -XX:+AlwaysPreTouch so RSS quickly reaches heap size.
# - Dataset size influences runtime + shuffle, but heap pre-touch makes peak physical memory predictable.
#
# Defaults:
# - DATASET_GB=16 (on disk)
# - DRIVER_HEAP_GB=32 (RSS ~32GiB, within 20–50GiB)
#
# Outputs:
#   perf_results/hibench_wordcount_<tag>_t<threads>_heap<heap>g/
#
# Optional perf/heatmaps:
#   PERF=1 START_AFTER_RSS_GB=20 PERF_STOP_AFTER_SEC=180 ...

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

guess_java_home_11() {
  if [ -d /usr/lib/jvm/java-11-openjdk-amd64 ]; then
    echo /usr/lib/jvm/java-11-openjdk-amd64
    return
  fi
  java_path="$(command -v java || true)"
  if [ -n "$java_path" ]; then
    real="$(readlink -f "$java_path" 2>/dev/null || true)"
    if [ -n "$real" ]; then
      echo "$(cd "$(dirname "$real")/.." && pwd)"
      return
    fi
  fi
  echo ""
}

THREADS="${THREADS:-$(detect_nproc)}"

DATASET_GB="${DATASET_GB:-16}"
PARTS="${PARTS:-256}"
VOCAB_SIZE="${VOCAB_SIZE:-1000000}"
WORDS_PER_LINE="${WORDS_PER_LINE:-16}"
TARGET_LINE_BYTES="${TARGET_LINE_BYTES:-256}"

DRIVER_HEAP_GB="${DRIVER_HEAP_GB:-32}"   # make RSS predictable in 20–50GiB

SPARK_HOME="${SPARK_HOME:-$("$ROOT_DIR/prepare_spark.sh")}"
HIBENCH_JAR="${HIBENCH_JAR:-$("$ROOT_DIR/prepare_hibench_sparkbench.sh")}"

JAVA_HOME="${JAVA_HOME:-$(guess_java_home_11)}"
if [ -z "$JAVA_HOME" ] || [ ! -x "$JAVA_HOME/bin/java" ]; then
  echo "ERROR: JAVA_HOME not set / invalid. Set JAVA_HOME to a JDK." >&2
  exit 1
fi

export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"

RUN_TAG="${RUN_TAG:-$(date +%Y%m%d_%H%M%S)}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/perf_results/hibench_wordcount_${RUN_TAG}_t${THREADS}_heap${DRIVER_HEAP_GB}g}"
mkdir -p "$OUT_DIR"

bench_log="$OUT_DIR/bench.log"
rss_log="$OUT_DIR/rss_log.txt"
rss_summary="$OUT_DIR/rss_summary.txt"
perf_data="$OUT_DIR/perf.data"
raw_points="$OUT_DIR/raw_points.txt"
points="$OUT_DIR/points.txt"

# dataset
DATA_DIR="${DATA_DIR:-$ROOT_DIR/data}"
DATASET_DIR="${DATASET_DIR:-}"
if [ -z "$DATASET_DIR" ]; then
  DATASET_DIR="$DATA_DIR/hibench_datasets/wordcount_text_${DATASET_GB}g_p${PARTS}"
  export DATA_DIR
  chmod +x "$ROOT_DIR/prepare_hibench_wordcount_local_dataset.sh" || true
  OUT_DIR_DATASET="$DATASET_DIR" DATASET_GB="$DATASET_GB" PARTS="$PARTS" VOCAB_SIZE="$VOCAB_SIZE" WORDS_PER_LINE="$WORDS_PER_LINE" TARGET_LINE_BYTES="$TARGET_LINE_BYTES" \
    OUT_DIR="$DATASET_DIR" "$ROOT_DIR/prepare_hibench_wordcount_local_dataset.sh" >/dev/null
fi
test -d "$DATASET_DIR" || { echo "ERROR: DATASET_DIR not found: $DATASET_DIR" >&2; exit 1; }

INPUT_PATH="$DATASET_DIR"
OUTPUT_PATH="$OUT_DIR/output_wordcount"
rm -rf "$OUTPUT_PATH" 2>/dev/null || true

# SparkBench properties used by IOCommon
props_file="$OUT_DIR/sparkbench.properties"
cat >"$props_file" <<EOF
hibench.default.shuffle.parallelism=$THREADS
sparkbench.inputformat=Text
sparkbench.outputformat=Null
EOF
export SPARKBENCH_PROPERTIES_FILES="$props_file"

SPARK_MASTER="${SPARK_MASTER:-local[$THREADS]}"

# JVM options to force RSS ~= heap size (pretouch).
# NOTE: spark-submit forbids specifying -Xmx via java options; it must come from --driver-memory.
# So we set Xmx via --driver-memory and set Xms (initial heap) to the same size here,
# which makes AlwaysPreTouch touch the full heap at startup.
JAVA_OPTS="-Xms${DRIVER_HEAP_GB}g -XX:+AlwaysPreTouch"
JAVA_OPTS="${JAVA_OPTS} ${EXTRA_JAVA_OPTS:-}"

spark_args=(
  --class com.intel.hibench.sparkbench.micro.ScalaWordCount
  --master "$SPARK_MASTER"
  --driver-memory "${DRIVER_HEAP_GB}g"
  --conf "spark.default.parallelism=$THREADS"
  --conf "spark.sql.shuffle.partitions=$THREADS"
  --conf "spark.ui.enabled=false"
  --conf "spark.driver.extraJavaOptions=$JAVA_OPTS"
  --conf "spark.executor.extraJavaOptions=$JAVA_OPTS"
  "$HIBENCH_JAR"
  "$INPUT_PATH"
  "$OUTPUT_PATH"
)

echo "spark:   $SPARK_HOME"
echo "java:    $JAVA_HOME"
echo "hibench: $HIBENCH_JAR"
echo "data:    $INPUT_PATH (dataset_gb=$DATASET_GB parts=$PARTS)"
echo "out:     $OUT_DIR"
echo "master:  $SPARK_MASTER threads=$THREADS"
echo "heap:    ${DRIVER_HEAP_GB}g (Xms=Xmx, AlwaysPreTouch)"

rm -f "$bench_log" "$rss_log" "$rss_summary" "$perf_data" "$raw_points" "$points" 2>/dev/null || true

echo ""
echo "=== start wordcount ==="
echo "cmd: $SPARK_HOME/bin/spark-submit ${spark_args[*]}"

("$SPARK_HOME/bin/spark-submit" "${spark_args[@]}") >"$bench_log" 2>&1 &
pid=$!
echo "pid: $pid"

PERF="${PERF:-0}"
PERF_BIN="${PERF_BIN:-perf}"
SAMPLE_PERIOD="${SAMPLE_PERIOD:-20000}"
PERF_STOP_AFTER_SEC="${PERF_STOP_AFTER_SEC:-180}"
PERF_EVENT_LOAD="${PERF_EVENT_LOAD:-cpu/mem-loads/pp}"
PERF_EVENT_STORE="${PERF_EVENT_STORE:-cpu/mem-stores/pp}"
START_AFTER_RSS_GB="${START_AFTER_RSS_GB:-20}"
START_AFTER_RSS_TIMEOUT_SEC="${START_AFTER_RSS_TIMEOUT_SEC:-7200}"
RSS_POLL_INTERVAL_SEC="${RSS_POLL_INTERVAL_SEC:-1}"
WINDOW_GB="${WINDOW_GB:-64}"
DROP_TOP_BUCKETS="${DROP_TOP_BUCKETS:-1}"
AUTO_PAD="${AUTO_PAD:-1}"
AUTO_YLIM="${AUTO_YLIM:-1}"
KILL_AFTER_PERF="${KILL_AFTER_PERF:-1}"
MIN_BUCKET_SAMPLES="${MIN_BUCKET_SAMPLES:-0}"

collect_descendants() {
  # Print root + descendants (best-effort; tolerates short-lived processes)
  local root_pid="$1"
  local max_depth="${2:-3}"
  local seen=" $root_pid "
  local frontier=("$root_pid")
  local depth=0
  echo "$root_pid"
  while [ "$depth" -lt "$max_depth" ]; do
    local next=()
    for p in "${frontier[@]}"; do
      for c in $(ps -o pid= --ppid "$p" 2>/dev/null || true); do
        if [[ "$seen" != *" $c "* ]]; then
          seen="$seen $c "
          echo "$c"
          next+=("$c")
        fi
      done
    done
    frontier=("${next[@]}")
    depth=$((depth + 1))
  done
}

target_rss_kb=$(python3 - <<PY
gb=float("$START_AFTER_RSS_GB")
print(int(gb*1024*1024))
PY
)

# RSS monitor (track the max-RSS java descendant; spark-submit itself is a java process too)
(
  max_kb=0
  max_pid="$pid"
  while kill -0 "$pid" 2>/dev/null; do
    ts=$(date +%s)
    best_pid=""
    best_rss_kb=0
    while read -r p; do
      [ -d "/proc/$p" ] || continue
      comm=$(cat "/proc/$p/comm" 2>/dev/null || true)
      [ "$comm" = "java" ] || continue
      r=$(awk '/^VmRSS:/ {print $2}' "/proc/$p/status" 2>/dev/null || echo 0)
      if [ "${r:-0}" -gt "$best_rss_kb" ]; then
        best_rss_kb="$r"
        best_pid="$p"
      fi
    done < <(collect_descendants "$pid" 4)
    if [ -z "$best_pid" ]; then
      best_pid="$pid"
      best_rss_kb=$(awk '/^VmRSS:/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo 0)
    fi
    if [ "${best_rss_kb:-0}" -gt "$max_kb" ]; then
      max_kb="$best_rss_kb"
      max_pid="$best_pid"
    fi
    echo "$ts $best_pid $best_rss_kb" >> "$rss_log"
    sleep 1
  done
  echo "max_rss_kb=$max_kb" > "$rss_summary"
  echo "max_rss_pid=$max_pid" >> "$rss_summary"
  python3 - <<PY >> "$rss_summary"
kb=$max_kb
print(f"max_rss_gib={kb/1024/1024:.3f}")
PY
) >/dev/null 2>&1 &
rss_mon_pid=$!

perf_target_pid=""
if [ "$PERF" = "1" ]; then
  echo "=== PERF=1: wait for RSS >= ${START_AFTER_RSS_GB} GiB then sample perf for ${PERF_STOP_AFTER_SEC}s ==="
  t0=$(date +%s)
  while true; do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "ERROR: spark-submit exited before RSS gate; see log: $bench_log" >&2
      tail -n 120 "$bench_log" >&2 || true
      wait "$rss_mon_pid" 2>/dev/null || true
      exit 1
    fi
    best_pid=""
    best_rss_kb=0
    while read -r p; do
      [ -d "/proc/$p" ] || continue
      comm=$(cat "/proc/$p/comm" 2>/dev/null || true)
      [ "$comm" = "java" ] || continue
      r=$(awk '/^VmRSS:/ {print $2}' "/proc/$p/status" 2>/dev/null || echo 0)
      if [ "${r:-0}" -gt "$best_rss_kb" ]; then
        best_rss_kb="$r"
        best_pid="$p"
      fi
    done < <(collect_descendants "$pid" 4)
    if [ "${best_rss_kb:-0}" -ge "$target_rss_kb" ]; then
      perf_target_pid="$best_pid"
      echo "RSS reached: pid=$perf_target_pid VmRSS=${best_rss_kb} kB (target ${target_rss_kb} kB)"
      break
    fi
    now=$(date +%s)
    if [ $((now - t0)) -ge "$START_AFTER_RSS_TIMEOUT_SEC" ]; then
      echo "Warning: timeout waiting for RSS gate; proceeding with current pid=$best_pid VmRSS=${best_rss_kb} kB" >&2
      perf_target_pid="$best_pid"
      break
    fi
    sleep "$RSS_POLL_INTERVAL_SEC"
  done

  if [ -z "${perf_target_pid:-}" ]; then
    echo "ERROR: could not find a java pid to profile under spark-submit pid=$pid" >&2
    exit 1
  fi

  if command -v detect_perf_params >/dev/null 2>&1; then
    detect_perf_params "$perf_target_pid"
  else
    PERF_TARGET_FLAGS="-p $perf_target_pid"
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

  comm="$(cat "/proc/$perf_target_pid/comm" 2>/dev/null || echo java)"
  "$PERF_BIN" script -i "$perf_data" -F comm,pid,time,event,addr 2>/dev/null > "$raw_points"
  test -s "$raw_points" || { echo "ERROR: raw_points empty: $raw_points" >&2; exit 1; }
  python3 "$ROOT_DIR/filter_perf_script_points.py" --pid "$perf_target_pid" --comm "$comm" < "$raw_points" > "$points" || true
  test -s "$points" || { echo "ERROR: points empty after filtering: $points" >&2; exit 1; }

  if [ "$KILL_AFTER_PERF" = "1" ]; then
    echo "=== kill wordcount after perf (KILL_AFTER_PERF=1) ==="
    kill -TERM "$pid" 2>/dev/null || true
    sleep 2
    kill -KILL "$pid" 2>/dev/null || true
  fi
fi

wait "$pid" || true
wait "$rss_mon_pid" 2>/dev/null || true

echo ""
echo "Done: hibench wordcount"
echo "  out: $OUT_DIR"
echo "  rss: $rss_summary"
echo "  log: $bench_log"

if [ "$PERF" = "1" ]; then
  echo "=== plot (store-window) ==="
  WINDOW_GB="$WINDOW_GB" AUTO_PAD="$AUTO_PAD" DROP_TOP_BUCKETS="$DROP_TOP_BUCKETS" AUTO_YLIM="$AUTO_YLIM" TITLE_MODE=simple \
    MIN_BUCKET_SAMPLES="$MIN_BUCKET_SAMPLES" \
    PERF_EVENT_LOAD="$PERF_EVENT_LOAD" PERF_EVENT_STORE="$PERF_EVENT_STORE" \
    "$ROOT_DIR/replot_store_window.sh" "$OUT_DIR" || true
  echo "  pts: $points"
fi

exit 0

