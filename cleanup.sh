#!/bin/bash
# cleanup.sh

set -euo pipefail

# 1. Kill the benchmark if running
echo "Killing workload (zipf_bench/pr)..."
pkill -f zipf_bench 2>/dev/null || true
pkill -f '/pr -f ' 2>/dev/null || true

if [ "${CLEAN_ARTIFACTS:-0}" = "1" ]; then
  echo "Removing local build/perf artifacts (set CLEAN_RESULTS=1 to also delete perf_results/)..."
  rm -f zipf_bench
  rm -f stream_bench
  # perf outputs may be root-owned if created via sudo perf record
  # Use sudo non-interactively; if it fails, leave a hint.
  if ! sudo -n rm -f perf.data perf_data.data test*.data* *.data test.data.old 2>/dev/null; then
    echo "Note: some perf artifacts may be root-owned; remove them with: sudo rm -f perf.data perf_data.data test*.data* *.data test.data.old" >&2
  fi
fi

if [ "${CLEAN_RESULTS:-0}" = "1" ]; then
  echo "Removing perf_results/ ..."
  rm -rf perf_results
  rm -rf perf_results_gapbs
fi

echo "Cleanup complete."



