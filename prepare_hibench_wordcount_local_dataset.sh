#!/usr/bin/env bash
set -euo pipefail

# Generate a local text dataset for HiBench Spark wordcount.
#
# Output is a directory containing multiple part files, suitable for Spark sc.textFile(<dir>).
# We generate simple ASCII text with spaces/newlines to keep parsing predictable.
#
# Key env vars:
#   OUT_DIR        : output directory (default: data/hibench_datasets/wordcount_text_<GB>g_p<PARTS>)
#   DATASET_GB     : total size on disk (GiB, default 16)
#   PARTS          : number of part files (default: 256)
#   VOCAB_SIZE     : number of distinct words (default: 1000000)
#   WORDS_PER_LINE : words per line (default: 16)
#   TARGET_LINE_BYTES : approximate bytes per line (default: 256)
#
# Notes:
# - This is "just data"; memory footprint is mostly controlled by Spark/JVM settings.
# - Larger VOCAB_SIZE increases distinct keys which can increase shuffle/memory.

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="${DATA_DIR:-$ROOT_DIR/data}"

DATASET_GB="${DATASET_GB:-16}"
PARTS="${PARTS:-256}"
VOCAB_SIZE="${VOCAB_SIZE:-1000000}"
WORDS_PER_LINE="${WORDS_PER_LINE:-16}"
TARGET_LINE_BYTES="${TARGET_LINE_BYTES:-256}"

OUT_DIR="${OUT_DIR:-$DATA_DIR/hibench_datasets/wordcount_text_${DATASET_GB}g_p${PARTS}}"
mkdir -p "$OUT_DIR"

manifest="$OUT_DIR/MANIFEST.txt"
if [ -s "$manifest" ]; then
  echo "$OUT_DIR"
  exit 0
fi

echo "=== generate wordcount dataset ===" >&2
echo "out: $OUT_DIR" >&2
echo "size: ${DATASET_GB} GiB parts=$PARTS vocab=$VOCAB_SIZE words_per_line=$WORDS_PER_LINE line_bytes~$TARGET_LINE_BYTES" >&2

python3 - <<PY
import os
import math
import time

out_dir = "$OUT_DIR"
dataset_gb = float("$DATASET_GB")
parts = int("$PARTS")
vocab = int("$VOCAB_SIZE")
words_per_line = int("$WORDS_PER_LINE")
target_line_bytes = int("$TARGET_LINE_BYTES")

assert parts > 0
assert vocab > 0
assert words_per_line > 0

total_bytes = int(dataset_gb * (1024**3))
bytes_per_part = (total_bytes + parts - 1) // parts

def make_line(seed: int) -> bytes:
    # Deterministic "pseudo-random" words based on seed, with fixed-ish line length.
    # Format: w<8hex> repeated, separated by single spaces, ending with '\n'.
    x = seed & 0xffffffff
    ws = []
    for _ in range(words_per_line):
        # LCG
        x = (1103515245 * x + 12345) & 0x7fffffff
        wid = x % vocab
        ws.append(f"w{wid:08x}")
    line = (" ".join(ws) + "\n").encode("ascii")
    # Pad line to target_line_bytes (keep trailing '\n' at end)
    if len(line) < target_line_bytes:
        pad = target_line_bytes - len(line)
        # Insert padding before newline
        line = line[:-1] + (b" " * (pad - 1)) + b"\n"
    return line

t0 = time.time()
for p in range(parts):
    fn = os.path.join(out_dir, f"part-{p:05d}.txt")
    # Skip existing completed parts
    if os.path.exists(fn) and os.path.getsize(fn) >= bytes_per_part:
        continue
    tmp = fn + ".tmp"
    with open(tmp, "wb", buffering=1024*1024) as f:
        written = 0
        seed = p + 1
        while written < bytes_per_part:
            line = make_line(seed)
            seed += 1
            # Don't overshoot too much at end
            if written + len(line) > bytes_per_part:
                line = line[: max(0, bytes_per_part - written)]
            f.write(line)
            written += len(line)
    os.replace(tmp, fn)

elapsed = time.time() - t0
with open(os.path.join(out_dir, "MANIFEST.txt"), "w", encoding="utf-8") as m:
    m.write(f"dataset_gib={dataset_gb}\\n")
    m.write(f"parts={parts}\\n")
    m.write(f"vocab_size={vocab}\\n")
    m.write(f"words_per_line={words_per_line}\\n")
    m.write(f"target_line_bytes={target_line_bytes}\\n")
    m.write(f"bytes_per_part={bytes_per_part}\\n")
    m.write(f"elapsed_sec={elapsed:.3f}\\n")
print(out_dir)
PY

echo "$OUT_DIR"

