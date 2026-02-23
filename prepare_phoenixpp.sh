#!/usr/bin/env bash
set -euo pipefail

# Fetch/build Phoenix++ and print the word_count binary path.
#
# Source repo layout (from https://github.com/kozyraki/phoenix):
#   data/phoenix_src/phoenix++-1.0/...

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="${DATA_DIR:-$ROOT_DIR/data}"
PHOENIX_SRC="${PHOENIX_SRC:-$DATA_DIR/phoenix_src}"
PHOENIXPP_HOME="${PHOENIXPP_HOME:-$PHOENIX_SRC/phoenix++-1.0}"

mkdir -p "$DATA_DIR"

if [ ! -d "$PHOENIX_SRC/.git" ]; then
  echo "=== clone phoenix (contains phoenix++-1.0) ===" >&2
  git clone --depth 1 https://github.com/kozyraki/phoenix.git "$PHOENIX_SRC"
fi

test -f "$PHOENIXPP_HOME/Makefile" || { echo "ERROR: phoenix++ not found at $PHOENIXPP_HOME" >&2; exit 1; }

echo "=== build phoenix++ library + word_count ===" >&2
# Some old distributions assume lib/ exists; on modern filesystems a stale file named "lib"
# can break builds (tests expect lib/libphoenix.a).
if [ -e "$PHOENIXPP_HOME/lib" ] && [ ! -d "$PHOENIXPP_HOME/lib" ]; then
  rm -f "$PHOENIXPP_HOME/lib"
fi
mkdir -p "$PHOENIXPP_HOME/lib"

# Build library first (top-level make can run tests in parallel with lib when -j is used).
make -C "$PHOENIXPP_HOME/src" -j"$(nproc --all)" >/dev/null
make -C "$PHOENIXPP_HOME/tests/word_count" -j"$(nproc --all)" >/dev/null

BIN="$PHOENIXPP_HOME/tests/word_count/word_count"
test -x "$BIN" || { echo "ERROR: word_count binary missing: $BIN" >&2; exit 1; }

echo "$BIN"

