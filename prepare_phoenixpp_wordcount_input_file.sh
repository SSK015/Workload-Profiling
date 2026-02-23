#!/usr/bin/env bash
set -euo pipefail

# Generate a *single* local text file for Phoenix++ word_count.
#
# Env vars:
#   OUT_FILE       : output filename (default: data/phoenixpp_datasets/wordcount_<GB>g.txt)
#   DATASET_GB     : file size in GiB (default: 8)
#   VOCAB_SIZE     : number of distinct words (default: 2000000)
#   WORDS_PER_LINE : words per line (default: 16)
#   TARGET_LINE_BYTES : approximate bytes per line (default: 256)

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="${DATA_DIR:-$ROOT_DIR/data}"

DATASET_GB="${DATASET_GB:-8}"
VOCAB_SIZE="${VOCAB_SIZE:-2000000}"
WORDS_PER_LINE="${WORDS_PER_LINE:-16}"
TARGET_LINE_BYTES="${TARGET_LINE_BYTES:-256}"

OUT_FILE="${OUT_FILE:-$DATA_DIR/phoenixpp_datasets/wordcount_${DATASET_GB}g.txt}"
mkdir -p "$(dirname "$OUT_FILE")"

manifest="${OUT_FILE}.manifest"
if [ -s "$OUT_FILE" ] && [ -s "$manifest" ]; then
  echo "$OUT_FILE"
  exit 0
fi

echo "=== generate Phoenix++ wordcount input file ===" >&2
echo "out: $OUT_FILE" >&2
echo "size: ${DATASET_GB} GiB vocab=$VOCAB_SIZE words_per_line=$WORDS_PER_LINE line_bytes~$TARGET_LINE_BYTES" >&2

python3 - <<PY
import os, time

out_file = "$OUT_FILE"
dataset_gb = float("$DATASET_GB")
vocab = int("$VOCAB_SIZE")
words_per_line = int("$WORDS_PER_LINE")
target_line_bytes = int("$TARGET_LINE_BYTES")

total_bytes = int(dataset_gb * (1024**3))

def make_line(seed: int) -> bytes:
    x = seed & 0xffffffff
    ws = []
    for _ in range(words_per_line):
        x = (1103515245 * x + 12345) & 0x7fffffff
        wid = x % vocab
        ws.append(f"w{wid:08x}")
    line = (" ".join(ws) + "\n").encode("ascii")
    if len(line) < target_line_bytes:
        pad = target_line_bytes - len(line)
        line = line[:-1] + (b" " * (pad - 1)) + b"\n"
    return line

t0=time.time()
tmp = out_file + ".tmp"
with open(tmp, "wb", buffering=1024*1024) as f:
    written = 0
    seed = 1
    while written < total_bytes:
        line = make_line(seed)
        seed += 1
        if written + len(line) > total_bytes:
            line = line[: max(0, total_bytes - written)]
        f.write(line)
        written += len(line)
os.replace(tmp, out_file)

elapsed=time.time()-t0
with open(out_file + ".manifest","w",encoding="utf-8") as m:
    m.write(f"dataset_gib={dataset_gb}\\n")
    m.write(f"vocab_size={vocab}\\n")
    m.write(f"words_per_line={words_per_line}\\n")
    m.write(f"target_line_bytes={target_line_bytes}\\n")
    m.write(f"elapsed_sec={elapsed:.3f}\\n")
PY

echo "$OUT_FILE"

