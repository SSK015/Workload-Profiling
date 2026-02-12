#!/usr/bin/env bash
set -euo pipefail

# Profile a VoltDB "application" (benchmark workload) on Linux using perf PEBS data-address samples,
# then generate store-window heatmaps.
#
# We default to VoltDB's canonical sample application: **Voter**.
# What it does:
# - Simulates a high-throughput OLTP workload where clients cast votes (e.g., phone/SMS voting).
# - Transactions are executed as stored procedures inside VoltDB.
# - Useful as a representative in-memory DB workload: indexing, procedure execution, logging, GC/heap activity.
#
# Requirements:
# - Linux + perf
# - A VoltDB distribution available locally (this repo does not vendor it):
#   - either set VOLTDB_HOME=/abs/path/to/voltdb
#   - or set VOLTDB_TARBALL=/abs/path/to/voltdb-*.tar.gz (will be extracted under data/voltdb_dist/)
#
# Notes / knobs:
# - HEAP_GB sets JVM heap target (best-effort; depends on distribution scripts honoring JAVA_OPTS).
# - START_AFTER_RSS_GB gates perf until server RSS reaches threshold.
# - KILL_AFTER_PERF=1 will stop the server after sampling so we can plot immediately.
#
# Output:
#   perf_results/voltdb_voter_<timestamp>_rss<...>g/

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

PERF_BIN="${PERF_BIN:-perf}"
SAMPLE_PERIOD="${SAMPLE_PERIOD:-20000}"
PERF_STOP_AFTER_SEC="${PERF_STOP_AFTER_SEC:-180}"
START_AFTER_RSS_GB="${START_AFTER_RSS_GB:-8}"
START_AFTER_RSS_TIMEOUT_SEC="${START_AFTER_RSS_TIMEOUT_SEC:-3600}"
RSS_POLL_INTERVAL_SEC="${RSS_POLL_INTERVAL_SEC:-1}"

THREADS="${THREADS:-$(detect_nproc)}"
HEAP_GB="${HEAP_GB:-16}"

WINDOW_GB="${WINDOW_GB:-64}"
DROP_TOP_BUCKETS="${DROP_TOP_BUCKETS:-1}"
AUTO_PAD="${AUTO_PAD:-1}"
AUTO_YLIM="${AUTO_YLIM:-1}"
KILL_AFTER_PERF="${KILL_AFTER_PERF:-1}"

PERF_EVENT_LOAD="${PERF_EVENT_LOAD:-cpu/mem-loads/pp}"
PERF_EVENT_STORE="${PERF_EVENT_STORE:-cpu/mem-stores/pp}"

RUN_TAG="${RUN_TAG:-$(date +%Y%m%d_%H%M%S)}"
OUT_ROOT="${OUT_ROOT:-$ROOT_DIR/perf_results/voltdb_voter_${RUN_TAG}_t${THREADS}_rss${START_AFTER_RSS_GB}g}"
mkdir -p "$OUT_ROOT"

echo "out:   $OUT_ROOT"

if ! command -v java >/dev/null 2>&1; then
  echo "ERROR: java not found in PATH (VoltDB requires a JDK/JRE)" >&2
  exit 2
fi

VOLTDB_HOME="$("$ROOT_DIR/prepare_voltdb.sh")"
echo "voltdb: $VOLTDB_HOME"

VOTER_DIR="${VOTER_DIR:-$VOLTDB_HOME/examples/voter}"
if [ ! -d "$VOTER_DIR" ]; then
  echo "ERROR: VoltDB Voter example not found: $VOTER_DIR" >&2
  echo "Hint: set VOTER_DIR=/abs/path/to/examples/voter for your VoltDB distribution." >&2
  exit 2
fi

# Preflight: ensure this is a *distribution* (compiled jar exists). Source-only checkouts
# won't work because bin/voltdb requires voltdb/voltdb-*.jar.
if ! ls "$VOLTDB_HOME"/voltdb/voltdb-*.jar >/dev/null 2>&1; then
  echo "ERROR: VoltDB compiled jar not found under: $VOLTDB_HOME/voltdb/voltdb-*.jar" >&2
  echo "This usually means VOLTDB_HOME points to a *source checkout* rather than a built distribution." >&2
  echo "Fix options:" >&2
  echo "  - Provide a VoltDB distribution tarball via VOLTDB_TARBALL=... (recommended)" >&2
  echo "  - Or provide a repo that already contains the built distribution artifacts" >&2
  exit 2
fi

echo "voter: $VOTER_DIR"
echo "heap:  HEAP_GB=$HEAP_GB"
echo "perf:  bin=$PERF_BIN period=$SAMPLE_PERIOD stop_after=${PERF_STOP_AFTER_SEC}s"
echo "plot:  WINDOW_GB=$WINDOW_GB AUTO_PAD=$AUTO_PAD DROP_TOP_BUCKETS=$DROP_TOP_BUCKETS AUTO_YLIM=$AUTO_YLIM"

export OMP_NUM_THREADS="$THREADS"  # harmless; some native libs/scripts may read it
export OMP_PROC_BIND="${OMP_PROC_BIND:-close}"
export OMP_PLACES="${OMP_PLACES:-cores}"

# Many VoltDB wrappers honor JAVA_OPTS / VOLTDB_OPTS; we set both to improve portability.
export JAVA_OPTS="${JAVA_OPTS:-"-Xms${HEAP_GB}g -Xmx${HEAP_GB}g"}"
export VOLTDB_OPTS="${VOLTDB_OPTS:-"$JAVA_OPTS"}"

server_log="$OUT_ROOT/server.log"
client_log="$OUT_ROOT/client.log"
perf_data="$OUT_ROOT/perf.data"
raw_points="$OUT_ROOT/raw_points.txt"
points="$OUT_ROOT/points.txt"
rss_log="$OUT_ROOT/rss_log.txt"
rss_summary="$OUT_ROOT/rss_summary.txt"

rm -f "$server_log" "$client_log" "$perf_data" "$raw_points" "$points" "$rss_log" "$rss_summary" 2>/dev/null || true

echo "=== start VoltDB Voter workload ==="
echo "note: we will sample the VoltDB *server* (java) process"

(
  cd "$VOTER_DIR"
  # run.sh uses relative paths (../../bin/voltdb etc), so we must run it from its directory.
  bash ./run.sh server
) >"$server_log" 2>&1 &
server_launcher_pid=$!

find_server_pid() {
  # Prefer a single VoltDB server java process. Patterns vary across versions.
  pgrep -f 'org\\.voltdb\\.VoltDB|voltdb\\.VoltDB' | head -n 1 || true
}

server_pid=""
t0=$(date +%s)
while true; do
  server_pid="$(find_server_pid)"
  if [ -n "$server_pid" ] && kill -0 "$server_pid" 2>/dev/null; then
    break
  fi
  now=$(date +%s)
  if [ $((now - t0)) -ge 120 ]; then
    echo "ERROR: could not find VoltDB server pid after 120s. See: $server_log" >&2
    tail -n 200 "$server_log" >&2 || true
    exit 1
  fi
  sleep 1
done
echo "server_pid: $server_pid"

echo "=== start Voter client load generator ==="
(
  cd "$VOTER_DIR"
  # Generates load against localhost:21212 for ~120s by default; can be adjusted by editing run.sh or overriding it.
  bash ./run.sh async-benchmark
) >"$client_log" 2>&1 &
client_pid=$!

target_rss_kb=$(python3 - <<PY
gb=float("$START_AFTER_RSS_GB")
print(int(gb*1024*1024))
PY
)

# RSS monitor
(
  max_kb=0
  while kill -0 "$server_pid" 2>/dev/null; do
    ts=$(date +%s)
    rss_kb=$(awk '/^VmRSS:/ {print $2}' "/proc/$server_pid/status" 2>/dev/null || echo 0)
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
  if ! kill -0 "$server_pid" 2>/dev/null; then
    echo "ERROR: VoltDB server exited before reaching RSS threshold; see log: $server_log" >&2
    tail -n 200 "$server_log" >&2 || true
    wait "$rss_mon_pid" 2>/dev/null || true
    exit 1
  fi
  rss_kb=$(awk '/^VmRSS:/ {print $2}' "/proc/$server_pid/status" 2>/dev/null || echo 0)
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
  detect_perf_params "$server_pid"
else
  PERF_TARGET_FLAGS="-p $server_pid"
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

echo "=== decode & filter points (pid=$server_pid, comm=java) ==="
"$PERF_BIN" script -i "$perf_data" -F comm,pid,time,event,addr 2>/dev/null > "$raw_points"
test -s "$raw_points" || { echo "ERROR: raw_points empty: $raw_points" >&2; exit 1; }
python3 "$ROOT_DIR/filter_perf_script_points.py" --pid "$server_pid" --comm "java" < "$raw_points" > "$points" || true
test -s "$points" || { echo "ERROR: points empty after filtering: $points (try adjusting --comm)" >&2; exit 1; }

if [ "$KILL_AFTER_PERF" = "1" ]; then
  echo "=== stop VoltDB after perf (KILL_AFTER_PERF=1) ==="
  kill -TERM "$server_pid" 2>/dev/null || true
  sleep 2
  kill -KILL "$server_pid" 2>/dev/null || true
fi

echo "=== wait for client + server launcher to exit ==="
wait "$client_pid" 2>/dev/null || true
wait "$server_launcher_pid" 2>/dev/null || true
wait "$rss_mon_pid" 2>/dev/null || true

echo "=== plot (store-window) ==="
WINDOW_GB="$WINDOW_GB" AUTO_PAD="$AUTO_PAD" DROP_TOP_BUCKETS="$DROP_TOP_BUCKETS" AUTO_YLIM="$AUTO_YLIM" TITLE_MODE=simple \
  PERF_EVENT_LOAD="$PERF_EVENT_LOAD" PERF_EVENT_STORE="$PERF_EVENT_STORE" \
  "$ROOT_DIR/replot_store_window.sh" "$OUT_ROOT" || true

echo ""
echo "Done: voltdb_voter"
echo "  out:   $OUT_ROOT"
echo "  rss:   $rss_summary"
echo "  perf:  $perf_data"
echo "  pts:   $points"

