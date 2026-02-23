#!/usr/bin/env bash
set -euo pipefail

# Extract semantic plain text from the Wikipedia XML dump using WikiExtractor.
# Produces:
#   - extracted text shards under OUT_DIR/extracted/
#   - a single concatenated plain text file OUT_DIR/enwiki-20190201-pages-articles.txt
#
# Why:
# - Phoenix++ word_count works best on natural-language-like text, not raw XML markup.
# - This is "more semantically real" for WordCount access patterns.
#
# Usage:
#   ./prepare_wikipedia_wikiextract_enwiki_20190201.sh
#
# Env vars:
#   THREADS      : number of extraction processes (default: nproc)
#   DATA_DIR     : base data dir (default: ./data/wikipedia_datasets/enwiki_20190201)
#   XML_BZ2      : path to .xml.bz2 (optional; used only for verification)
#   XML_FILE     : path to .xml (default: DATA_DIR/enwiki-20190201-pages-articles.xml)
#   OUT_DIR      : output dir (default: DATA_DIR/wikiextract)
#   FORCE        : if 1, re-run extraction even if outputs exist (default: 0)
#   KEEP_SHARDS  : if 0, delete shard directory after concatenation (default: 1)

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

detect_nproc() {
  if command -v nproc >/dev/null 2>&1; then
    nproc --all
    return
  fi
  getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1
}

THREADS="${THREADS:-$(detect_nproc)}"
DATA_DIR="${DATA_DIR:-$ROOT_DIR/data/wikipedia_datasets/enwiki_20190201}"
XML_BZ2="${XML_BZ2:-$DATA_DIR/enwiki-20190201-pages-articles.xml.bz2}"
XML_FILE="${XML_FILE:-$DATA_DIR/enwiki-20190201-pages-articles.xml}"
OUT_DIR="${OUT_DIR:-$DATA_DIR/wikiextract}"
FORCE="${FORCE:-0}"
KEEP_SHARDS="${KEEP_SHARDS:-1}"

mkdir -p "$OUT_DIR"

echo "=== wikiextract ==="
echo "threads:  $THREADS"
echo "xml:      $XML_FILE"
echo "out_dir:  $OUT_DIR"

test -s "$XML_FILE" || { echo "ERROR: missing XML file: $XML_FILE" >&2; exit 1; }
if [ -f "$XML_BZ2" ]; then
  echo "xml_bz2:  $XML_BZ2 ($(du -h "$XML_BZ2" | awk '{print $1}'))"
fi

# Ensure WikiExtractor is installed (user install; no venv required).
if ! python3 -c 'import wikiextractor' >/dev/null 2>&1; then
  echo "=== installing wikiextractor (python3 -m pip --user) ==="
  python3 -m pip install --user --upgrade wikiextractor
fi

SHARDS_DIR="$OUT_DIR/extracted"
CONCAT_TXT="$OUT_DIR/enwiki-20190201-pages-articles.txt"

if [ "$FORCE" != "1" ] && [ -s "$CONCAT_TXT" ]; then
  echo "Already have: $CONCAT_TXT ($(du -h "$CONCAT_TXT" | awk '{print $1}'))"
  echo "$CONCAT_TXT"
  exit 0
fi

if [ "$FORCE" = "1" ]; then
  rm -rf "$SHARDS_DIR" "$CONCAT_TXT" 2>/dev/null || true
fi

mkdir -p "$SHARDS_DIR"

echo "=== run WikiExtractor ==="
# Notes:
# - We keep output as plain text (default) rather than JSON; Phoenix++ consumes raw text.
# - --no_templates reduces noise from template expansion.
# - --processes parallelizes parsing.
python3 -m wikiextractor.WikiExtractor \
  --processes "$THREADS" \
  --no-templates \
  --output "$SHARDS_DIR" \
  "$XML_FILE"

echo "=== concatenate shards -> single text file ==="
# WikiExtractor writes many files under $SHARDS_DIR/*/*; concatenate in deterministic order.
tmp="$CONCAT_TXT.tmp"
rm -f "$tmp" 2>/dev/null || true
find "$SHARDS_DIR" -type f -print0 | sort -z | xargs -0 cat > "$tmp"
mv -f "$tmp" "$CONCAT_TXT"

echo "wrote: $CONCAT_TXT ($(du -h "$CONCAT_TXT" | awk '{print $1}'))"

if [ "$KEEP_SHARDS" = "0" ]; then
  rm -rf "$SHARDS_DIR"
fi

echo "$CONCAT_TXT"

