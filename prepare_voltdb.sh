#!/usr/bin/env bash
set -euo pipefail

# Prepare a local VoltDB distribution directory.
#
# This repo does NOT vendor VoltDB itself (licenses/distribution differ across editions).
# You provide either:
#   - VOLTDB_HOME=/abs/path/to/voltdb   (already extracted)
# or:
#   - VOLTDB_TARBALL=/abs/path/to/voltdb-*.tar.gz (or .tgz) (will be extracted under data/voltdb_dist/)
# or:
#   - VOLTDB_GIT_REPO=https://github.com/<user>/<repo>.git (will be cloned under data/voltdb_dist/)
#
# Output:
#   prints VOLTDB_HOME to stdout on success.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

VOLTDB_HOME="${VOLTDB_HOME:-}"
VOLTDB_TARBALL="${VOLTDB_TARBALL:-}"
VOLTDB_GIT_REPO="${VOLTDB_GIT_REPO:-}"
VOLTDB_GIT_REF="${VOLTDB_GIT_REF:-master}"
OUT_BASE="${OUT_BASE:-$ROOT_DIR/data/voltdb_dist}"

if [ -n "$VOLTDB_HOME" ]; then
  if [ ! -x "$VOLTDB_HOME/bin/voltdb" ]; then
    echo "ERROR: VOLTDB_HOME set but bin/voltdb not found/executable: $VOLTDB_HOME" >&2
    exit 2
  fi
  echo "$VOLTDB_HOME"
  exit 0
fi

if [ -z "$VOLTDB_TARBALL" ] && [ -z "$VOLTDB_GIT_REPO" ]; then
  echo "ERROR: need one of:" >&2
  echo "  - VOLTDB_HOME=/abs/path/to/voltdb" >&2
  echo "  - VOLTDB_TARBALL=/abs/path/to/voltdb-*.tar.gz (or .tgz)" >&2
  echo "  - VOLTDB_GIT_REPO=https://github.com/<org-or-user>/<repo>.git" >&2
  exit 2
fi

if [ -n "$VOLTDB_TARBALL" ] && [ ! -f "$VOLTDB_TARBALL" ]; then
  echo "ERROR: VOLTDB_TARBALL not found: $VOLTDB_TARBALL" >&2
  exit 2
fi

mkdir -p "$OUT_BASE"

dst_dir=""
if [ -n "$VOLTDB_TARBALL" ]; then
  name="$(basename "$VOLTDB_TARBALL")"
  dst_dir="$OUT_BASE/${name%.tar.gz}"
  dst_dir="$OUT_BASE/${dst_dir##*/}"
  dst_dir="${dst_dir%.tgz}"
else
  # git checkout destination
  dst_dir="$OUT_BASE/voltdb_git_$(basename "${VOLTDB_GIT_REPO%.git}" | tr -cd '[:alnum:]_-')_${VOLTDB_GIT_REF//[^[:alnum:]_-]/_}"
fi

if [ -x "$dst_dir/bin/voltdb" ]; then
  echo "$dst_dir"
  exit 0
fi

if [ -z "$VOLTDB_TARBALL" ]; then
  echo "=== cloning VoltDB repo ==="
  echo "repo: $VOLTDB_GIT_REPO"
  echo "ref:  $VOLTDB_GIT_REF"
  rm -rf "$dst_dir" 2>/dev/null || true
  git clone --depth 1 --branch "$VOLTDB_GIT_REF" "$VOLTDB_GIT_REPO" "$dst_dir"
  test -x "$dst_dir/bin/voltdb" || { echo "ERROR: cloned but bin/voltdb not found: $dst_dir" >&2; exit 3; }
  echo "$dst_dir"
  exit 0
fi

tmp_dir="$(mktemp -d "$OUT_BASE/.extract.XXXXXX")"
trap 'rm -rf "$tmp_dir" 2>/dev/null || true' RETURN

echo "=== extracting VoltDB tarball ==="
echo "src: $VOLTDB_TARBALL"
echo "dst: $dst_dir"
tar -C "$tmp_dir" -xf "$VOLTDB_TARBALL"

# Usually the tarball contains a single top-level directory.
top="$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1 || true)"
if [ -z "$top" ]; then
  echo "ERROR: unexpected tarball layout (no top-level directory)" >&2
  exit 3
fi

rm -rf "$dst_dir" 2>/dev/null || true
mv "$top" "$dst_dir"
trap - RETURN
rm -rf "$tmp_dir" 2>/dev/null || true

test -x "$dst_dir/bin/voltdb" || { echo "ERROR: extracted but bin/voltdb not found: $dst_dir" >&2; exit 3; }
echo "$dst_dir"

