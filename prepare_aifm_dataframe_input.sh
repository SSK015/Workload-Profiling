#!/usr/bin/env bash
set -euo pipefail

# Prepare the AIFM DataFrame (Fig.7) input on a normal Linux machine.
#
# AIFM artifact script (for CloudLab) downloads ~16GB NYC taxi CSVs and concatenates
# them into all.csv, which yields a max working set of ~31GiB in memory according to
# the paper artifact notes.
#
# This script:
# - downloads the same CSV list into $DATA_DIR
# - builds $CSV_PATH (= $DATA_DIR/all.csv by default) by concatenating and removing headers
#
# It does NOT format/mount raw disks (the artifact uses /dev/sda4).
#
# Example:
#   DATA_DIR=/data/xiayanwen/research/Workload-Profiling/data/aifm_dataframe \
#     ./prepare_aifm_dataframe_input.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

DATA_DIR="${DATA_DIR:-$ROOT_DIR/data/aifm_dataframe}"
CSV_PATH="${CSV_PATH:-$DATA_DIR/all.csv}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"

# Data source:
# - auto: try legacy CSV links first; if forbidden, fall back to parquet+convert
# - csv: force legacy CSV links (may fail with 403 depending on mirror policy)
# - parquet: use current parquet endpoints and convert to CSV
DATA_SOURCE="${DATA_SOURCE:-auto}"

# DuckDB version to use for parquet->CSV conversion.
# Pin to a version that still provides binary wheels for Python 3.8 in many environments.
DUCKDB_VERSION="${DUCKDB_VERSION:-0.9.2}"

mkdir -p "$DATA_DIR"

if [ "$FORCE_REBUILD" != "1" ] && [ -s "$CSV_PATH" ]; then
  echo "=== all.csv exists; skip rebuild (FORCE_REBUILD=1 to rebuild) ==="
  exit 0
fi

# Default months match the AIFM artifact (Fig.7) list.
# To scale the working set (e.g., reach closer to 31GiB RSS on your machine), add months:
#   EXTRA_MONTHS="2016-07 2016-08"
EXTRA_MONTHS="${EXTRA_MONTHS:-}"

MONTHS=(
  2016-01 2016-02 2016-03 2016-04 2016-05 2016-06
  2015-01 2015-02 2015-03
)
if [ -n "$EXTRA_MONTHS" ]; then
  for m in $EXTRA_MONTHS; do
    MONTHS+=( "$m" )
  done
fi

csv_links=()
parquet_links=()
for m in "${MONTHS[@]}"; do
  csv_links+=( "https://s3.amazonaws.com/nyc-tlc/trip+data/yellow_tripdata_${m}.csv" )
  parquet_links+=( "https://d37ci6vzurychx.cloudfront.net/trip-data/yellow_tripdata_${m}.parquet" )
done

head_file="yellow_tripdata_${MONTHS[0]}.csv"

echo "out dir: $DATA_DIR"
echo "all.csv:  $CSV_PATH"

download_one() {
  local url="$1"
  local fname
  fname="$(basename "$url")"
  local dst="$DATA_DIR/$fname"

  if [ -s "$dst" ]; then
    echo "ok:  $dst"
    return 0
  fi

  echo "get: $url"
  if command -v wget >/dev/null 2>&1; then
    wget -q --show-progress -O "$dst.tmp" "$url"
  elif command -v curl >/dev/null 2>&1; then
    curl -L --fail -o "$dst.tmp" "$url"
  else
    echo "ERROR: need wget or curl to download datasets" >&2
    return 1
  fi
  mv -f "$dst.tmp" "$dst"
}

detect_source_auto() {
  # If legacy CSV URL returns 403 (common now), fall back to parquet.
  local test_url="${csv_links[0]}"
  local code="000"
  if command -v curl >/dev/null 2>&1; then
    code="$(curl -s -L -o /dev/null -w '%{http_code}' --max-time 20 "$test_url" || true)"
  else
    # wget doesn't easily give status; just try and see if file is non-empty.
    code="000"
  fi
  if [ "$code" = "200" ]; then
    echo "csv"
  else
    echo "parquet"
  fi
}

if [ "$DATA_SOURCE" = "auto" ]; then
  DATA_SOURCE="$(detect_source_auto)"
fi

echo "source: $DATA_SOURCE"

ensure_duckdb_py() {
  # Ensure we can `import duckdb` in Python.
  # Prefer system python if already has duckdb; otherwise install with pip (user install).
  if python3 -c "import duckdb" >/dev/null 2>&1; then
    echo "python: python3 (duckdb already available)" >&2
    echo "python3"
    return 0
  fi

  echo "=== install duckdb (python module) ===" >&2
  # This environment may not have python3-venv/ensurepip; use system pip instead.
  # Prefer binary wheels to avoid a long source build.
  python3 -m pip -q install --user --only-binary=:all: "duckdb==${DUCKDB_VERSION}" || \
    python3 -m pip -q install --user "duckdb==${DUCKDB_VERSION}"
  python3 -c "import duckdb" >/dev/null 2>&1 || {
    echo "ERROR: failed to install duckdb via pip. Try: python3 -m pip install --user duckdb==${DUCKDB_VERSION}" >&2
    return 1
  }
  echo "python: python3 (duckdb installed)" >&2
  echo "python3"
}

export_parquet_to_csv() {
  local py="$1"
  local parquet_path="$2"
  local csv_out="$3"
  "$py" - <<PY
import duckdb
pq = r"$parquet_path"
out = r"$csv_out"

con = duckdb.connect(database=":memory:")
# The current TLC parquet schema (for 2016/2015) does not include longitude/latitude.
# However, the AIFM DataFrame app expects the legacy CSV schema with pickup/dropoff lon/lat.
# We synthesize pseudo lon/lat from (PU/DOLocationID) so the column names and types match
# what the original workload code reads, while keeping the overall data size/shape.
sel = """
VendorID,
tpep_pickup_datetime,
tpep_dropoff_datetime,
passenger_count,
trip_distance,
CAST(((PULocationID % 360) - 180) AS DOUBLE) AS pickup_longitude,
CAST((((PULocationID * 7) % 180) - 90) AS DOUBLE) AS pickup_latitude,
RatecodeID,
store_and_fwd_flag,
CAST(((DOLocationID % 360) - 180) AS DOUBLE) AS dropoff_longitude,
CAST((((DOLocationID * 7) % 180) - 90) AS DOUBLE) AS dropoff_latitude,
payment_type,
fare_amount,
extra,
mta_tax,
tip_amount,
tolls_amount,
improvement_surcharge,
total_amount
""".strip()

sql = f"COPY (SELECT {sel} FROM read_parquet('{pq}')) TO '{out}' (HEADER, DELIMITER ',');"
con.execute(sql)
PY
}

if [ "$DATA_SOURCE" = "csv" ]; then
  echo "=== download NYC taxi CSVs (~16GB total) ==="
  for url in "${csv_links[@]}"; do
    download_one "$url"
  done
elif [ "$DATA_SOURCE" = "parquet" ]; then
  echo "=== download NYC taxi parquet files (will convert to CSV) ==="
  for url in "${parquet_links[@]}"; do
    download_one "$url"
  done

  pybin="$(ensure_duckdb_py)"
  echo "=== convert parquet -> CSV (one file at a time, to build all.csv) ==="
  rm -f "$CSV_PATH" "$CSV_PATH.tmp" 2>/dev/null || true

  first=1
  for url in "${parquet_links[@]}"; do
    pq="$DATA_DIR/$(basename "$url")"
    tmp_csv="$DATA_DIR/$(basename "${pq%.parquet}.csv.tmp")"
    out_csv="$DATA_DIR/$(basename "${pq%.parquet}.csv")"
    rm -f "$tmp_csv" "$out_csv" 2>/dev/null || true
    echo "convert: $(basename "$pq") -> $(basename "$out_csv")"
    export_parquet_to_csv "$pybin" "$pq" "$tmp_csv"
    mv -f "$tmp_csv" "$out_csv"
    if [ "$first" = "1" ]; then
      cat "$out_csv" > "$CSV_PATH.tmp"
      first=0
    else
      tail -n +2 "$out_csv" >> "$CSV_PATH.tmp"
    fi
    rm -f "$out_csv" 2>/dev/null || true
  done

  mv -f "$CSV_PATH.tmp" "$CSV_PATH"
  echo "done: $CSV_PATH"
  exit 0
else
  echo "ERROR: unknown DATA_SOURCE=$DATA_SOURCE (expected auto|csv|parquet)" >&2
  exit 2
fi

if [ "$FORCE_REBUILD" != "1" ] && [ -s "$CSV_PATH" ]; then
  echo "=== all.csv exists; skip rebuild (FORCE_REBUILD=1 to rebuild) ==="
  exit 0
fi

echo "=== build all.csv (concatenate, drop headers) ==="
rm -f "$CSV_PATH" "$CSV_PATH.tmp" 2>/dev/null || true

if [ ! -s "$DATA_DIR/$head_file" ]; then
  echo "ERROR: missing head file: $DATA_DIR/$head_file" >&2
  exit 1
fi

cat "$DATA_DIR/$head_file" > "$CSV_PATH.tmp"

for url in "${csv_links[@]}"; do
  f="$(basename "$url")"
  if [ "$f" = "$head_file" ]; then
    continue
  fi
  if [ ! -s "$DATA_DIR/$f" ]; then
    echo "ERROR: missing file: $DATA_DIR/$f" >&2
    exit 1
  fi
  # Skip header row for all subsequent files.
  tail -n +2 "$DATA_DIR/$f" >> "$CSV_PATH.tmp"
done

mv -f "$CSV_PATH.tmp" "$CSV_PATH"
echo "done: $CSV_PATH"

