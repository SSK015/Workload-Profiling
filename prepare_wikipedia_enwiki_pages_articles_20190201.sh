#!/usr/bin/env bash
set -euo pipefail

# Download an older English Wikipedia "pages-articles" dump whose compressed size is ~15GiB.
#
# Source: Internet Archive item "enwiki-20190201"
# File:   enwiki-20190201-pages-articles.xml.bz2  (≈14.75 GiB)
#
# This script:
# - Resolves the final URL via redirects (-L)
# - Reads expected Content-Length via HEAD
# - Downloads with resume (-C -) + retries
# - Verifies the final file size matches Content-Length
#
# Env vars:
#   DATA_DIR   : output dir (default: <repo>/data/wikipedia_datasets/enwiki_20190201)
#   OUT_FILE   : override output file path
#   RETRIES    : curl retries (default: 8)
#   NO_VERIFY  : if "1", skip Content-Length verification
#
# Usage:
#   ./prepare_wikipedia_enwiki_pages_articles_20190201.sh
#

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="${DATA_DIR:-$ROOT_DIR/data/wikipedia_datasets/enwiki_20190201}"
RETRIES="${RETRIES:-8}"
NO_VERIFY="${NO_VERIFY:-0}"

DATE="20190201"
FN="enwiki-${DATE}-pages-articles.xml.bz2"
URL="https://archive.org/download/enwiki-${DATE}/${FN}"

mkdir -p "$DATA_DIR"
OUT_FILE="${OUT_FILE:-$DATA_DIR/$FN}"
PART_FILE="${OUT_FILE}.part"

echo "=== wikipedia dump download ===" >&2
echo "date: $DATE" >&2
echo "url:  $URL" >&2
echo "out:  $OUT_FILE" >&2

expected=""
last_modified=""
if [ "$NO_VERIFY" != "1" ]; then
  # Resolve redirects and capture headers (IA uses redirects to a storage host).
  hdr="$(curl -A 'Mozilla/5.0' -fsSLI -L "$URL" | tr -d '\r')"
  expected="$(awk 'BEGIN{IGNORECASE=1} /^content-length:/ {print $2}' <<<"$hdr" | tail -n 1)"
  last_modified="$(awk 'BEGIN{IGNORECASE=1} /^last-modified:/ {$1=""; sub(/^ /,""); print}' <<<"$hdr" | tail -n 1)"
  if [[ -n "${expected:-}" && "$expected" =~ ^[0-9]+$ ]]; then
    python3 - <<PY >&2
cl=int("$expected")
print(f"expected_bytes={cl}")
print(f"expected_gib={cl/1024**3:.2f}")
PY
  else
    echo "WARN: could not parse Content-Length; proceeding without size verification." >&2
    NO_VERIFY=1
  fi
  if [ -n "${last_modified:-}" ]; then
    echo "last_modified=${last_modified}" >&2
  fi
fi

if [ -s "$OUT_FILE" ]; then
  echo "already exists: $OUT_FILE" >&2
  echo "$OUT_FILE"
  exit 0
fi

touch "$PART_FILE"
echo "=== downloading (resume enabled) ===" >&2
echo "note: this is ~15GiB compressed; download may take a while." >&2

curl -A 'Mozilla/5.0' -fL \
  --retry "$RETRIES" --retry-delay 2 --retry-connrefused \
  --continue-at - \
  --output "$PART_FILE" \
  "$URL"

if [ "$NO_VERIFY" != "1" ] && [ -n "${expected:-}" ]; then
  actual="$(stat -c '%s' "$PART_FILE")"
  if [ "$actual" != "$expected" ]; then
    python3 - <<PY >&2
exp=int("$expected"); act=int("$actual")
print(f"ERROR: size mismatch: expected {exp} bytes ({exp/1024**3:.2f} GiB) but got {act} bytes ({act/1024**3:.2f} GiB)")
PY
    echo "hint: rerun the script; it will resume into: $PART_FILE" >&2
    exit 2
  fi
fi

mv -f "$PART_FILE" "$OUT_FILE"
echo "=== done ===" >&2
ls -lh "$OUT_FILE" >&2 || true
echo "$OUT_FILE"

