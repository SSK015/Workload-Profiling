#!/usr/bin/env bash
set -euo pipefail

# Download and prepare the SNAP com-friendster dataset for GAPBS:
# - download com-friendster.ungraph.txt.gz (~8.7GiB)
# - convert to:
#   - com-friendster.sg  (unweighted serialized graph) for bfs/pr/cc
#   - com-friendster.wsg (weighted serialized graph) for sssp
#   - com-friendster.bidir_directed_inv.sg (directed serialized graph that stores
#       BOTH out+in CSR, for higher-memory runs of algorithms like PR)
#
# You can skip one of the outputs to save time:
#   BUILD_SG=1 BUILD_WSG=0 ./prepare_gapbs_com_friendster.sh   # PR/BFS/CC only
#   BUILD_SG=0 BUILD_WSG=1 ./prepare_gapbs_com_friendster.sh   # SSSP only
#
# We avoid materializing the huge decompressed text file by streaming through a FIFO:
#   pigz -dc file.gz > fifo
#   converter -f fifo -s -b out.sg
#
# Example:
#   ./prepare_gapbs_com_friendster.sh
#
# Outputs:
#   data/gapbs_datasets/com_friendster/com-friendster.sg
#   data/gapbs_datasets/com_friendster/com-friendster.wsg

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

GAPBS_DIR="${GAPBS_DIR:-$ROOT_DIR/data/gapbs_src}"
DATA_DIR="${DATA_DIR:-$ROOT_DIR/data/gapbs_datasets/com_friendster}"
URL="${URL:-https://snap.stanford.edu/data/bigdata/communities/com-friendster.ungraph.txt.gz}"
# Optional: reuse a pre-downloaded archive (avoid re-downloading 9GB).
# Default points to a shared cache location in this repo.
RAW_GZ="${RAW_GZ:-$ROOT_DIR/data/gapbs_datasets/com-friendster.ungraph.txt.gz}"

mkdir -p "$DATA_DIR"
test -x "$GAPBS_DIR/converter" || {
  echo "ERROR: GAPBS converter not found/executable: $GAPBS_DIR/converter" >&2
  echo "Fix: build it via: (cd $GAPBS_DIR && make converter)" >&2
  exit 1
}

GZ="$DATA_DIR/com-friendster.ungraph.txt.gz"
SG="$DATA_DIR/com-friendster.sg"
SG_BIDIR_DIRECTED_INV="$DATA_DIR/com-friendster.bidir_directed_inv.sg"
WSG="$DATA_DIR/com-friendster.wsg"
WSG_BIDIR_DIRECTED_INV="$DATA_DIR/com-friendster.bidir_directed_inv.wsg"

BUILD_SG="${BUILD_SG:-1}"
BUILD_WSG="${BUILD_WSG:-1}"
BUILD_SG_BIDIR_DIRECTED_INV="${BUILD_SG_BIDIR_DIRECTED_INV:-0}"
BUILD_WSG_BIDIR_DIRECTED_INV="${BUILD_WSG_BIDIR_DIRECTED_INV:-0}"

echo "gapbs: $GAPBS_DIR"
echo "data:  $DATA_DIR"

if [ -f "$RAW_GZ" ]; then
  # If we have a cached archive, prefer it. If a partial download exists in DATA_DIR,
  # overwrite it by linking to the cached file.
  raw_sz=$(stat -c%s "$RAW_GZ" 2>/dev/null || echo 0)
  gz_sz=$(stat -c%s "$GZ" 2>/dev/null || echo 0)
  if [ "$raw_sz" -gt 0 ] && [ "$raw_sz" -gt "$gz_sz" ]; then
    echo "=== reuse cached archive ==="
    echo "src: $RAW_GZ ($raw_sz bytes)"
    echo "dst: $GZ ($gz_sz bytes)"
    rm -f "$GZ" 2>/dev/null || true
    ln -sf "$RAW_GZ" "$GZ" 2>/dev/null || cp -f "$RAW_GZ" "$GZ"
  fi
fi

if [ ! -f "$GZ" ]; then
  echo "=== download com-friendster (.txt.gz) ==="
  wget -c -O "$GZ" "$URL"
else
  echo "=== dataset already downloaded ==="
fi

ls -lh "$GZ"

decompress_cmd() {
  if command -v pigz >/dev/null 2>&1; then
    echo "pigz -dc \"$GZ\""
  else
    echo "gzip -dc \"$GZ\""
  fi
}

convert_stream() {
  local out="$1"
  local weighted="$2" # 0/1
  local sym="-s"
  local in_place=""
  local fifo
  # GAPBS reader dispatches by filename suffix; ensure FIFO ends with .el
  fifo="$(mktemp -u "$DATA_DIR/friendster_fifo_${weighted}.XXXXXX.el")"
  mkfifo "$fifo"
  trap 'rm -f "$fifo" 2>/dev/null || true' RETURN

  echo "=== convert -> $(basename "$out") (weighted=$weighted) ==="
  # Start decompressor in background writing to FIFO.
  # SNAP edge lists include comment lines starting with '#', which GAPBS .el reader does NOT skip.
  # Filter them out (and keep only the first two columns).
  (
    eval "$(decompress_cmd)" | awk 'NF>=2 && $1 !~ /^#/ {print $1, $2}'
  ) > "$fifo" &
  local dec_pid=$!

  set +e
  if [ "$weighted" = "1" ]; then
    "$GAPBS_DIR/converter" -f "$fifo" $sym $in_place -w -b "$out"
  else
    "$GAPBS_DIR/converter" -f "$fifo" $sym $in_place -b "$out"
  fi
  local rc=$?
  set -e

  kill "$dec_pid" 2>/dev/null || true
  wait "$dec_pid" 2>/dev/null || true
  rm -f "$fifo" 2>/dev/null || true
  trap - RETURN

  if [ "$rc" -ne 0 ]; then
    echo "ERROR: converter failed (rc=$rc) for output: $out" >&2
    exit "$rc"
  fi
}

convert_stream_bidir_directed_inv_sg() {
  local out="$1"
  local fifo
  # GAPBS reader dispatches by filename suffix; ensure FIFO ends with .el
  fifo="$(mktemp -u "$DATA_DIR/friendster_fifo_bidir_directed_inv.XXXXXX.el")"
  mkfifo "$fifo"
  trap 'rm -f "$fifo" 2>/dev/null || true' RETURN

  echo "=== convert -> $(basename "$out") (mode=bidir_directed_inv) ==="
  echo "note: this builds a DIRECTED .sg (no -s), so writer stores BOTH out+in CSR"
  echo "note: we duplicate each edge (u v) and (v u) in the input stream to preserve undirected semantics"

  (
    # Filter SNAP comment lines and output BOTH directions for each edge.
    # Keep only the first two columns in case there are trailing tokens.
    eval "$(decompress_cmd)" | awk 'NF>=2 && $1 !~ /^#/ {print $1, $2; print $2, $1}'
  ) > "$fifo" &
  local dec_pid=$!

  # Use in-place building (-m) to reduce peak memory during construction.
  set +e
  "$GAPBS_DIR/converter" -f "$fifo" -m -b "$out"
  local rc=$?
  set -e

  kill "$dec_pid" 2>/dev/null || true
  wait "$dec_pid" 2>/dev/null || true
  rm -f "$fifo" 2>/dev/null || true
  trap - RETURN

  if [ "$rc" -ne 0 ]; then
    echo "ERROR: converter failed (rc=$rc) for output: $out" >&2
    exit "$rc"
  fi
}

convert_stream_bidir_directed_inv_wsg() {
  local out="$1"
  local fifo
  # GAPBS reader dispatches by filename suffix; ensure FIFO ends with .el
  fifo="$(mktemp -u "$DATA_DIR/friendster_fifo_bidir_directed_inv_w.XXXXXX.el")"
  mkfifo "$fifo"
  trap 'rm -f "$fifo" 2>/dev/null || true' RETURN

  echo "=== convert -> $(basename "$out") (mode=bidir_directed_inv, weighted) ==="
  echo "note: this builds a DIRECTED .wsg (no -s), so writer stores BOTH out+in CSR"
  echo "note: we duplicate each edge (u v) and (v u) in the input stream to preserve undirected semantics"

  (
    # Filter SNAP comment lines and output BOTH directions for each edge.
    # Keep only the first two columns in case there are trailing tokens.
    eval "$(decompress_cmd)" | awk 'NF>=2 && $1 !~ /^#/ {print $1, $2; print $2, $1}'
  ) > "$fifo" &
  local dec_pid=$!

  # NOTE: GAPBS converter does NOT support in-place building (-m) for weighted graphs.
  # So this may have a higher peak memory usage during construction than .sg.
  set +e
  "$GAPBS_DIR/converter" -f "$fifo" -w -b "$out"
  local rc=$?
  set -e

  kill "$dec_pid" 2>/dev/null || true
  wait "$dec_pid" 2>/dev/null || true
  rm -f "$fifo" 2>/dev/null || true
  trap - RETURN

  if [ "$rc" -ne 0 ]; then
    echo "ERROR: converter failed (rc=$rc) for output: $out" >&2
    exit "$rc"
  fi
}

if [ "$BUILD_SG" = "1" ] && [ ! -s "$SG" ]; then
  convert_stream "$SG" 0
else
  if [ "$BUILD_SG" = "1" ]; then
    echo "=== exists: $(basename "$SG") ==="
  else
    echo "=== skip: $(basename "$SG") (BUILD_SG=0) ==="
  fi
fi

if [ "$BUILD_SG_BIDIR_DIRECTED_INV" = "1" ] && [ ! -s "$SG_BIDIR_DIRECTED_INV" ]; then
  convert_stream_bidir_directed_inv_sg "$SG_BIDIR_DIRECTED_INV"
else
  if [ "$BUILD_SG_BIDIR_DIRECTED_INV" = "1" ]; then
    echo "=== exists: $(basename "$SG_BIDIR_DIRECTED_INV") ==="
  else
    echo "=== skip: $(basename "$SG_BIDIR_DIRECTED_INV") (BUILD_SG_BIDIR_DIRECTED_INV=0) ==="
  fi
fi

if [ "$BUILD_WSG_BIDIR_DIRECTED_INV" = "1" ] && [ ! -s "$WSG_BIDIR_DIRECTED_INV" ]; then
  convert_stream_bidir_directed_inv_wsg "$WSG_BIDIR_DIRECTED_INV"
else
  if [ "$BUILD_WSG_BIDIR_DIRECTED_INV" = "1" ]; then
    echo "=== exists: $(basename "$WSG_BIDIR_DIRECTED_INV") ==="
  else
    echo "=== skip: $(basename "$WSG_BIDIR_DIRECTED_INV") (BUILD_WSG_BIDIR_DIRECTED_INV=0) ==="
  fi
fi

if [ "$BUILD_WSG" = "1" ] && [ ! -s "$WSG" ]; then
  convert_stream "$WSG" 1
else
  if [ "$BUILD_WSG" = "1" ]; then
    echo "=== exists: $(basename "$WSG") ==="
  else
    echo "=== skip: $(basename "$WSG") (BUILD_WSG=0) ==="
  fi
fi

echo ""
echo "Done:"
if [ "$BUILD_SG" = "1" ]; then echo "  sg:  $SG"; fi
if [ "$BUILD_SG_BIDIR_DIRECTED_INV" = "1" ]; then echo "  sg(bidir_directed_inv): $SG_BIDIR_DIRECTED_INV"; fi
if [ "$BUILD_WSG_BIDIR_DIRECTED_INV" = "1" ]; then echo "  wsg(bidir_directed_inv): $WSG_BIDIR_DIRECTED_INV"; fi
if [ "$BUILD_WSG" = "1" ]; then echo "  wsg: $WSG"; fi

