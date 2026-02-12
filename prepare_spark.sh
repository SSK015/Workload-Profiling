#!/usr/bin/env bash
set -euo pipefail

# Download/extract an Apache Spark binary distribution into data/ and print SPARK_HOME.
#
# Defaults are chosen to match HiBench 7.1.x SparkBench build profiles (Spark 3.1 + Scala 2.12).

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="${DATA_DIR:-$ROOT_DIR/data}"
mkdir -p "$DATA_DIR"

SPARK_HOME="${SPARK_HOME:-}"
SPARK_TARBALL_URL="${SPARK_TARBALL_URL:-https://archive.apache.org/dist/spark/spark-3.1.3/spark-3.1.3-bin-hadoop3.2.tgz}"

if [ -n "$SPARK_HOME" ] && [ -x "$SPARK_HOME/bin/spark-submit" ]; then
  echo "$SPARK_HOME"
  exit 0
fi

SPARK_DIST_DIR="${SPARK_DIST_DIR:-$DATA_DIR/spark_dist}"
mkdir -p "$SPARK_DIST_DIR"

tgz="$SPARK_DIST_DIR/$(basename "$SPARK_TARBALL_URL")"
if [ ! -s "$tgz" ]; then
  echo "=== download Spark ===" >&2
  echo "url: $SPARK_TARBALL_URL" >&2
  curl -fL --retry 3 --retry-delay 2 -o "$tgz" "$SPARK_TARBALL_URL"
fi

# Extract into spark_dist/ and normalize to spark_dist/spark
if [ ! -d "$SPARK_DIST_DIR/spark" ]; then
  echo "=== extract Spark ===" >&2
  tmp_dir="$SPARK_DIST_DIR/_extract_tmp"
  rm -rf "$tmp_dir"
  mkdir -p "$tmp_dir"
  tar -xzf "$tgz" -C "$tmp_dir"
  extracted="$(find "$tmp_dir" -maxdepth 1 -mindepth 1 -type d | head -n 1)"
  if [ -z "${extracted:-}" ]; then
    echo "ERROR: failed to find extracted Spark directory under $tmp_dir" >&2
    exit 1
  fi
  mv "$extracted" "$SPARK_DIST_DIR/spark"
  rm -rf "$tmp_dir"
fi

SPARK_HOME="$SPARK_DIST_DIR/spark"
test -x "$SPARK_HOME/bin/spark-submit" || { echo "ERROR: spark-submit not found under $SPARK_HOME" >&2; exit 1; }

echo "$SPARK_HOME"

