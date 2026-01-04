#!/bin/bash
#
# Produce a *visibly sequential* scan pattern in the virt heatmap.
#
# This is NOT for peak bandwidth. It intentionally scans in phases (small moving windows)
# with optional sleeps/barriers so the "brush" movement shows up clearly in time-vs-address.
#
set -euo pipefail

cd "$(dirname "$0")"

# A conservative default that should show a clear moving band:
# - 1 thread (avoid multi-thread overlap in the heatmap)
# - windowed scan so only a small region is hot at a time
# - small sleep so time axis has structure
export THREADS=${THREADS:-1}
export CPU_START=${CPU_START:--1}
export PATTERN=${PATTERN:-chunk}
# Use a single-array op by default so the heatmap shows one moving band.
export OP=${OP:-read}

# 4GB total region is plenty to show movement without huge fault-in time.
export MEM_SIZE_MB=${MEM_SIZE_MB:-4096}
export BENCH_DURATION=${BENCH_DURATION:-60}

# Window/step in pages:
# - 4096 pages = 16MB, and 200ms sleep => ~5 phases/sec.
# - For a 4GB array, a full sweep is 256 phases (~51s), so a 60s run shows a clear diagonal.
export WINDOW_PAGES=${WINDOW_PAGES:-4096}
export STEP_PAGES=${STEP_PAGES:-4096}
export PHASE_SLEEP_US=${PHASE_SLEEP_US:-200000}
export SYNC_PHASES=${SYNC_PHASES:-0}

# perf: denser sampling helps reveal stripes
export SAMPLE_PERIOD=${SAMPLE_PERIOD:-1000}
export PERF_UNTIL_EXIT=${PERF_UNTIL_EXIT:-1}

# Output
export OUT_DIR=${OUT_DIR:-"./perf_results/stream_scan_demo"}
export TITLE=${TITLE:-"stream_bench scan demo (${MEM_SIZE_MB}MB, op=${OP}, window=${WINDOW_PAGES} pages)"}

exec ./run_stream_profile.sh


