#!/usr/bin/env bash
set -euo pipefail

# Profile a HiBench SparkBench workload (Spark local mode) using perf PEBS data-address samples,
# then generate store-window heatmaps.
#
# This runner focuses on a Spark-only workload that does NOT require Hadoop/HDFS:
#   micro/repartition in "in-memory" mode (ScalaInMemRepartition)
#
# What this does:
# - Downloads Spark (if needed)
# - Builds HiBench SparkBench assembly jar (if needed; uses JDK8 for build)
# - Runs a Spark local[*] job that allocates a sizable in-memory dataset and shuffles it
# - RSS-gates perf sampling, decodes points, and plots the 2 heatmaps
#
# Outputs:
#   perf_results/hibench_spark_<workload>_<timestamp>_t<threads>_rss<gate>g/

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
  # Fallback: try to infer from `java` path.
  java_path="$(command -v java || true)"
  if [ -n "$java_path" ]; then
    # e.g. /usr/bin/java -> /etc/alternatives/java -> /usr/lib/jvm/.../bin/java
    real="$(readlink -f "$java_path" 2>/dev/null || true)"
    if [ -n "$real" ]; then
      echo "$(cd "$(dirname "$real")/.." && pwd)"
      return
    fi
  fi
  echo ""
}

THREADS="${THREADS:-$(detect_nproc)}"
WORKLOAD="${WORKLOAD:-micro_inmem_repartition}"

# Spark + HiBench locations
SPARK_HOME="${SPARK_HOME:-$("$ROOT_DIR/prepare_spark.sh")}"
HIBENCH_JAR="${HIBENCH_JAR:-$("$ROOT_DIR/prepare_hibench_sparkbench.sh")}"

JAVA_HOME="${JAVA_HOME:-$(guess_java_home_11)}"
if [ -z "$JAVA_HOME" ] || [ ! -x "$JAVA_HOME/bin/java" ]; then
  echo "ERROR: JAVA_HOME not set / invalid. Set JAVA_HOME to a JDK (not a JRE)." >&2
  exit 1
fi

# Workload size knobs
TARGET_RSS_GB="${TARGET_RSS_GB:-16}"
OVERHEAD_GB="${OVERHEAD_GB:-4}"
START_AFTER_RSS_GB="${START_AFTER_RSS_GB:-8}"
START_AFTER_RSS_TIMEOUT_SEC="${START_AFTER_RSS_TIMEOUT_SEC:-7200}"
RSS_POLL_INTERVAL_SEC="${RSS_POLL_INTERVAL_SEC:-1}"

# ScalaInMemRepartition parameters
CACHE_IN_MEMORY="${CACHE_IN_MEMORY:-true}"
DISABLE_OUTPUT="${DISABLE_OUTPUT:-true}"

# Estimate: bytes per record in the benchmark's payload is 200, but runtime overhead is much larger.
BYTES_PER_RECORD_EST="${BYTES_PER_RECORD_EST:-600}"
NBR_RECORDS="${NBR_RECORDS:-}"
if [ -z "$NBR_RECORDS" ]; then
  NBR_RECORDS="$(python3 - <<PY
import math
target=float("$TARGET_RSS_GB")
over=float("$OVERHEAD_GB")
eff=int("$BYTES_PER_RECORD_EST")
gib=1024**3
goal=max(1.0, target-over)*gib
n=int(goal/eff)
print(max(1_000_000, n))
PY
)"
fi

# Spark knobs (local mode)
SPARK_MASTER="${SPARK_MASTER:-local[$THREADS]}"
SPARK_DRIVER_MEMORY="${SPARK_DRIVER_MEMORY:-${TARGET_RSS_GB}g}"
SPARK_SHUFFLE_PARTITIONS="${SPARK_SHUFFLE_PARTITIONS:-$THREADS}"
SPARK_DEFAULT_PARALLELISM="${SPARK_DEFAULT_PARALLELISM:-$THREADS}"

# perf knobs
PERF_BIN="${PERF_BIN:-perf}"
SAMPLE_PERIOD="${SAMPLE_PERIOD:-20000}"
PERF_STOP_AFTER_SEC="${PERF_STOP_AFTER_SEC:-180}"
PERF_EVENT_LOAD="${PERF_EVENT_LOAD:-cpu/mem-loads/pp}"
PERF_EVENT_STORE="${PERF_EVENT_STORE:-cpu/mem-stores/pp}"

# plotting knobs
WINDOW_GB="${WINDOW_GB:-64}"
DROP_TOP_BUCKETS="${DROP_TOP_BUCKETS:-1}"
AUTO_PAD="${AUTO_PAD:-1}"
AUTO_YLIM="${AUTO_YLIM:-1}"
KILL_AFTER_PERF="${KILL_AFTER_PERF:-1}"

RUN_TAG="${RUN_TAG:-$(date +%Y%m%d_%H%M%S)}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/perf_results/hibench_spark_${WORKLOAD}_${RUN_TAG}_t${THREADS}_rss${START_AFTER_RSS_GB}g}"
mkdir -p "$OUT_DIR"

bench_log="$OUT_DIR/bench.log"
perf_data="$OUT_DIR/perf.data"
raw_points="$OUT_DIR/raw_points.txt"
points="$OUT_DIR/points.txt"
rss_log="$OUT_DIR/rss_log.txt"
rss_summary="$OUT_DIR/rss_summary.txt"
props_file="$OUT_DIR/sparkbench.properties"

cat >"$props_file" <<EOF
# Minimal SparkBench properties for IOCommon.getProperty(...)
hibench.default.shuffle.parallelism=$SPARK_SHUFFLE_PARTITIONS
sparkbench.inputformat=Text
sparkbench.outputformat=Text
EOF

rm -f "$bench_log" "$perf_data" "$raw_points" "$points" "$rss_log" "$rss_summary" 2>/dev/null || true

echo "spark:   $SPARK_HOME"
echo "java:    $JAVA_HOME"
echo "hibench: $HIBENCH_JAR"
echo "workload:$WORKLOAD"
echo "out:     $OUT_DIR"
echo "master:  $SPARK_MASTER"
echo "mem:     driver=$SPARK_DRIVER_MEMORY target_rss=$TARGET_RSS_GB gate=${START_AFTER_RSS_GB}GiB"
echo "size:    NBR_RECORDS=$NBR_RECORDS cache=$CACHE_IN_MEMORY disable_output=$DISABLE_OUTPUT bytes_est=$BYTES_PER_RECORD_EST"
echo "perf:    period=$SAMPLE_PERIOD stop_after=${PERF_STOP_AFTER_SEC}s"

export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"

# Tell SparkBench where to read properties
export SPARKBENCH_PROPERTIES_FILES="$props_file"

target_rss_kb=$(python3 - <<PY
gb=float("$START_AFTER_RSS_GB")
print(int(gb*1024*1024))
PY
)

OUTPUT_DUMMY="$OUT_DIR/output_dummy"

args=(
  --class com.intel.hibench.sparkbench.micro.ScalaInMemRepartition
  --master "$SPARK_MASTER"
  --driver-memory "$SPARK_DRIVER_MEMORY"
  --conf "spark.default.parallelism=$SPARK_DEFAULT_PARALLELISM"
  --conf "spark.sql.shuffle.partitions=$SPARK_SHUFFLE_PARTITIONS"
  --conf "spark.ui.enabled=false"
  "$HIBENCH_JAR"
  "$NBR_RECORDS"
  "$OUTPUT_DUMMY"
  "$CACHE_IN_MEMORY"
  "$DISABLE_OUTPUT"
)

echo ""
echo "=== start spark-submit (no perf yet) ==="
echo "cmd: $SPARK_HOME/bin/spark-submit ${args[*]}"
("$SPARK_HOME/bin/spark-submit" "${args[@]}") >"$bench_log" 2>&1 &
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
    echo "ERROR: spark job exited before reaching RSS threshold; see log: $bench_log" >&2
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
comm="$(cat /proc/$pid/comm 2>/dev/null || echo java)"
"$PERF_BIN" script -i "$perf_data" -F comm,pid,time,event,addr 2>/dev/null > "$raw_points"
test -s "$raw_points" || { echo "ERROR: raw_points empty: $raw_points" >&2; exit 1; }
python3 "$ROOT_DIR/filter_perf_script_points.py" --pid "$pid" --comm "$comm" < "$raw_points" > "$points" || true
test -s "$points" || { echo "ERROR: points empty after filtering: $points" >&2; exit 1; }

if [ "$KILL_AFTER_PERF" = "1" ]; then
  echo "=== kill spark after perf (KILL_AFTER_PERF=1) ==="
  kill -TERM "$pid" 2>/dev/null || true
  sleep 2
  kill -KILL "$pid" 2>/dev/null || true
fi

echo "=== wait for spark job to exit ==="
wait "$pid" 2>/dev/null || true
wait "$rss_mon_pid" 2>/dev/null || true

echo "=== plot (store-window) ==="
WINDOW_GB="$WINDOW_GB" AUTO_PAD="$AUTO_PAD" DROP_TOP_BUCKETS="$DROP_TOP_BUCKETS" AUTO_YLIM="$AUTO_YLIM" TITLE_MODE=simple \
  PERF_EVENT_LOAD="$PERF_EVENT_LOAD" PERF_EVENT_STORE="$PERF_EVENT_STORE" \
  "$ROOT_DIR/replot_store_window.sh" "$OUT_DIR" || true

echo ""
echo "Done: hibench_spark ($WORKLOAD)"
echo "  out:   $OUT_DIR"
echo "  rss:   $rss_summary"
echo "  perf:  $perf_data"
echo "  pts:   $points"

