#!/bin/bash
#
# Auto-tune perf PEBS sample period for the XGBoost benchmark to get "more samples"
# (higher samples/sec), then run the full profiling pipeline (heatmap + hot persistence).
#
# Key knob: perf record -c PERIOD
#   - Smaller PERIOD => MORE samples/sec
#   - Larger PERIOD  => FEWER samples/sec
#
# This script does a short calibration run to estimate samples/sec and compute a period
# that targets TARGET_SPS, then runs the full `run_xgboost_profile.sh`.
#
# Usage:
#   TARGET_SPS=50000 WINDOW_GB=64 USE_PROC_MAPS=0 ./run_xgboost_profile_autosample.sh
#

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

OUT_BASE=${OUT_BASE:-"$ROOT_DIR/perf_results"}

# Calibration knobs
CAL_OUT_DIR=${CAL_OUT_DIR:-"$OUT_BASE/xgb_cal"}
CAL_WARMUP_SEC=${CAL_WARMUP_SEC:-3}
CAL_SEC=${CAL_SEC:-6}
START_PERIOD=${START_PERIOD:-1000}
TARGET_SPS=${TARGET_SPS:-30000} # target cpu/mem-loads/pp samples per second

# Full run knobs (forwarded to run_xgboost_profile.sh)
OUT_DIR=${OUT_DIR:-"$OUT_BASE/xgb_profile_hi_samples"}
MAX_POINTS=${MAX_POINTS:-8000000}
HEATMAP_GRIDSIZE=${HEATMAP_GRIDSIZE:-1200}
HEATMAP_DPI=${HEATMAP_DPI:-350}
HEATMAP_FIGSIZE=${HEATMAP_FIGSIZE:-"12,7"}
HEATMAP_VMAX_PCT=${HEATMAP_VMAX_PCT:-99.0}

echo "=== Calibrate sample rate ==="
mkdir -p "$CAL_OUT_DIR"

# Run a short perf record against the benchmark, just to estimate samples/sec.
# We re-use run_xgboost_profile.sh but force a fixed-duration recording and keep the raw outputs.
CAL_TITLE="XGBoost calib"

set +e
OUT_DIR="$CAL_OUT_DIR" \
TITLE="$CAL_TITLE" \
PERF_UNTIL_EXIT=0 PERF_DURATION="$CAL_SEC" WARMUP_SEC="$CAL_WARMUP_SEC" \
SAMPLE_PERIOD="$START_PERIOD" \
MAX_POINTS=1 \
HEATMAP_GRIDSIZE=10 \
HEATMAP_DPI=10 \
HEATMAP_FIGSIZE="2,2" \
USE_PROC_MAPS=0 \
HEATMAP_VMAX_PCT="" \
./run_xgboost_profile.sh >/dev/null 2>&1
CAL_RC=$?
set -e

if [ "$CAL_RC" != "0" ]; then
  echo "ERROR: calibration run failed (rc=$CAL_RC). Check: $CAL_OUT_DIR/bench.log" >&2
  exit 1
fi

POINTS_TXT="$CAL_OUT_DIR/points.txt"
if [ ! -s "$POINTS_TXT" ]; then
  echo "ERROR: calibration points missing: $POINTS_TXT" >&2
  exit 1
fi

read -r MEAS_SPS MEAS_SAMPLES MEAS_TSPAN < <(
  python3 - <<'PY'
import re
from pathlib import Path
p=Path("'"$POINTS_TXT"'")
line_re=re.compile(r'^\s*(?P<t>[0-9]+(?:\.[0-9]+)?)\s*:?\s+(?P<ev>\S+?)\s*:?\s+(?P<a>[0-9a-fA-F]+)\s*$')
mn=mx=None
n=0
for line in p.open('r',errors='ignore'):
    m=line_re.match(line)
    if not m: continue
    if m.group('ev').rstrip(':')!='cpu/mem-loads/pp': continue
    t=float(m.group('t'))
    mn=t if mn is None or t<mn else mn
    mx=t if mx is None or t>mx else mx
    a=m.group('a')
    if a=='0': continue
    n+=1
tspan=(mx-mn) if (mn is not None and mx is not None) else 0.0
sps=(n/tspan) if tspan>0 else 0.0
print(f\"{sps:.3f} {n} {tspan:.6f}\")
PY
)

if [ "$(python3 - <<PY
print(1 if float("$MEAS_SPS")>0 else 0)
PY
)" != "1" ]; then
  echo "ERROR: calibration produced 0 samples/sec; try lowering START_PERIOD or fixing perf permissions." >&2
  echo "Check: $CAL_OUT_DIR/bench.log" >&2
  exit 1
fi

echo "calibration: start_period=$START_PERIOD  measured_sps=$MEAS_SPS  samples=$MEAS_SAMPLES  tspan=$MEAS_TSPAN"
echo "target_sps:  $TARGET_SPS"

# Compute a new period (inverse proportional): period_new = period * (measured_sps / target_sps)
NEW_PERIOD=$(python3 - <<'PY'
import math
start=int("'"$START_PERIOD"'")
meas=float("'"$MEAS_SPS"'")
target=float("'"$TARGET_SPS"'")
raw=start * (meas/target)
# clamp
period=max(1, int(math.ceil(raw)))
print(period)
PY
)

echo "chosen SAMPLE_PERIOD=$NEW_PERIOD (smaller => more samples/sec)"

echo ""
echo "=== Full profiling run ==="
OUT_DIR="$OUT_DIR" \
SAMPLE_PERIOD="$NEW_PERIOD" \
MAX_POINTS="$MAX_POINTS" \
HEATMAP_GRIDSIZE="$HEATMAP_GRIDSIZE" \
HEATMAP_DPI="$HEATMAP_DPI" \
HEATMAP_FIGSIZE="$HEATMAP_FIGSIZE" \
HEATMAP_VMAX_PCT="$HEATMAP_VMAX_PCT" \
./run_xgboost_profile.sh




