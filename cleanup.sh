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
  # perf outputs may be root-owned if created via sudo perf record
  sudo rm -f perf.data perf_data.data test*.data* *.data 2>/dev/null || true
fi

if [ "${CLEAN_RESULTS:-0}" = "1" ]; then
  echo "Removing perf_results/ ..."
  rm -rf perf_results
fi

echo "Cleanup complete."



