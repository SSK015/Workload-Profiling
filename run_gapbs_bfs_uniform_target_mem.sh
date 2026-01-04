#!/bin/bash
#
# Choose SCALE (2^SCALE vertices) for GAPBS BFS uniform graph to target ~N GiB memory,
# then run `run_gapbs_bfs_uniform_profile.sh`.
#
# Background (GAPBS types in this repo):
# - NodeID = int32
# - CSRGraph stores:
#   - out_index_ as (num_nodes+1) pointers => ~8 * N bytes
#   - out_neighbors_ as int32, and for synthetic graphs GAPBS enables symmetrize => stores both directions => ~2*M int32
#     where M ~= N * DEGREE  (Generator uses num_edges = num_nodes * degree)
#   => graph bytes ~= 8*N + (2*M*4) = 8*N*(DEGREE+1)
#
# BFS also allocates extra arrays (parent, queues, bitmaps), so we subtract a small overhead.
#
# Usage:
#   TARGET_RSS_GB=20 DEGREE=16 ITERS=128 ./run_gapbs_bfs_uniform_target_mem.sh
#

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

TARGET_RSS_GB=${TARGET_RSS_GB:-20}
OVERHEAD_GB=${OVERHEAD_GB:-2} # reserved for BFS parent/queue/bitmaps + runtime overhead
DEGREE=${DEGREE:-16}
ITERS=${ITERS:-128}

# Keep other knobs pass-through
SAMPLE_PERIOD=${SAMPLE_PERIOD:-500}
PERF_UNTIL_EXIT=${PERF_UNTIL_EXIT:-1}
HEATMAP_VMAX_PCT=${HEATMAP_VMAX_PCT:-99.0}

SCALE=$(python3 - <<'PY'
import math
import os
target=float(os.environ.get("TARGET_RSS_GB", "20"))
over=float(os.environ.get("OVERHEAD_GB", "2"))
deg=int(os.environ.get("DEGREE", "16"))
gib=1024**3
goal=max(1.0, target-over) * gib
# graph bytes ~= 8*N*(deg+1)
n=goal / (8.0*(deg+1))
scale=int(math.floor(math.log2(n)))
scale=max(1, scale)
print(scale)
PY
)

echo "Target RSS ~= ${TARGET_RSS_GB}GiB (overhead reserve ${OVERHEAD_GB}GiB)"
echo "Chosen: SCALE=$SCALE (2^$SCALE vertices) DEGREE=$DEGREE ITERS=$ITERS"
echo "You can adjust OVERHEAD_GB up/down if measured RSS is off by a couple GiB."
echo ""

SCALE="$SCALE" DEGREE="$DEGREE" ITERS="$ITERS" \
SAMPLE_PERIOD="$SAMPLE_PERIOD" PERF_UNTIL_EXIT="$PERF_UNTIL_EXIT" HEATMAP_VMAX_PCT="$HEATMAP_VMAX_PCT" \
./run_gapbs_bfs_uniform_profile.sh


