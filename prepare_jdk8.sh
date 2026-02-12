#!/usr/bin/env bash
set -euo pipefail

# Download/extract a JDK 8 (Temurin) into data/ and print JAVA8_HOME.
#
# Why: HiBench's build uses an old scala-maven-plugin which often fails on Java 11
# with:
#   scala.reflect.internal.MissingRequirementError: object java.lang.Object in compiler mirror not found
# Using JDK 8 for the build is a reliable workaround; the resulting jars still run
# fine on newer JVMs.

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="${DATA_DIR:-$ROOT_DIR/data}"
mkdir -p "$DATA_DIR"

JAVA8_HOME="${JAVA8_HOME:-}"
if [ -n "$JAVA8_HOME" ] && [ -x "$JAVA8_HOME/bin/java" ]; then
  echo "$JAVA8_HOME"
  exit 0
fi

JDK8_URL="${JDK8_URL:-https://github.com/adoptium/temurin8-binaries/releases/download/jdk8u402-b06/OpenJDK8U-jdk_x64_linux_hotspot_8u402b06.tar.gz}"
JDK8_DIR="${JDK8_DIR:-$DATA_DIR/jdk8}"
mkdir -p "$JDK8_DIR"

tgz="$JDK8_DIR/$(basename "$JDK8_URL")"
if [ ! -s "$tgz" ]; then
  echo "=== download JDK8 (Temurin) ===" >&2
  echo "url: $JDK8_URL" >&2
  curl -fL --retry 3 --retry-delay 2 -o "$tgz" "$JDK8_URL"
fi

if [ ! -d "$JDK8_DIR/jdk" ]; then
  echo "=== extract JDK8 ===" >&2
  tmp_dir="$JDK8_DIR/_extract_tmp"
  rm -rf "$tmp_dir"
  mkdir -p "$tmp_dir"
  tar -xzf "$tgz" -C "$tmp_dir"
  extracted="$(find "$tmp_dir" -maxdepth 1 -mindepth 1 -type d | head -n 1)"
  if [ -z "${extracted:-}" ]; then
    echo "ERROR: failed to find extracted JDK directory under $tmp_dir" >&2
    exit 1
  fi
  mv "$extracted" "$JDK8_DIR/jdk"
  rm -rf "$tmp_dir"
fi

JAVA8_HOME="$JDK8_DIR/jdk"
test -x "$JAVA8_HOME/bin/java" || { echo "ERROR: java not found under $JAVA8_HOME" >&2; exit 1; }

echo "$JAVA8_HOME"

