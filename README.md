## Workload-Profiling (perf/PEBS address sampling)

This directory contains multiple **workload runners** plus a **perf/PEBS** workflow to collect **data-address samples** (`addr` / optionally `phys_addr`) and generate heatmaps / persistence plots.

### Prerequisites

- **Kernel**: you already booted the `*-generic-nothrottle` kernel (or otherwise disabled perf throttling).
- **Tools**:
  - Build: `g++`, `make`
  - Runtime: `perf` (set `PERF_BIN=/path/to/perf` if it’s not on `$PATH`)
  - Plot: `python3` with `matplotlib`

### Build

From this directory:

```bash
make
```

### How to generate profiling results (per workload)

All runners write results under `perf_results/<workload>_<timestamp>/` (this directory is **git-ignored**, so historical runs are kept locally and won't be committed).

- **Zipf/Uniform synthetic benchmark**:

```bash
./run_zipf_profile.sh
```

- **Streaming benchmark**:

```bash
./run_stream_profile.sh
```

- **Liblinear (HIGGS / webspam, with stores)**:

```bash
DATASET=/data/xiayanwen/research/liblinear/liblinear-multicore-2.49/webspam_wc_normalized_trigram.svm \
TRAIN_ARGS='-s 6 -m 80 -e 0.000001' \
START_AFTER_RSS_GB=40 PERF_STOP_AFTER_SEC=300 WINDOW_GB=64 \
./run_liblinear_profile.sh
```

- **NPB MG (Fortran OpenMP)**:

```bash
THREADS=32 CLASS=D DO_STORE=1 WINDOW_GB=64 ./run_npb_mg_profile.sh
```

- **NPB-CPP MG (C++ OpenMP)**:

```bash
THREADS=32 CLASS=D DO_STORE=1 WINDOW_GB=64 ./run_npb_cpp_mg_profile.sh
```

- **GAPBS (PR/BFS/SSSP)**:

```bash
./run_gapbs_pr_profile.sh
./run_gapbs_bfs_profile.sh
./run_gapbs_sssp_profile.sh
```

- **GAPBS suite (uniform synthetic graph, big memory ~20–50GiB RSS, loads+stores + store-window plots)**:

This runs a few representative algorithms (default: `bfs pr sssp cc`) on a GAPBS-generated **uniform** graph sized to hit a target RSS, waits until RSS crosses a threshold, then samples and plots.

```bash
GAPBS_DIR=/home/xiayanwen/app-case-studies/memtis/memtis-userspace/bench_dir/gapbs \
TARGET_RSS_GB=30 START_AFTER_RSS_GB=25 DEGREE=16 THREADS=32 \
PERF_STOP_AFTER_SEC=180 SAMPLE_PERIOD=20000 WINDOW_GB=64 \
  ./run_gapbs_suite_uniform_bigmem_profile.sh
```

Outputs go under `perf_results/gapbs_uniform_bigmem_*/<alg>/` and include:
- `points.txt`
- `rss_summary.txt`
- `virt_heatmap_store_storewin.png`
- `virt_heatmap_load_in_storewin.png`

- **GAPBS suite (real dataset graph file, big memory ~20–50GiB RSS, loads+stores + store-window plots)**:

Point `GRAPH_SG` (for `bfs/pr/cc`) and `GRAPH_WSG` (for `sssp`) to real graph files you already have, then the script will run the same representative algorithms and sample after the RSS threshold.

```bash
GRAPH_SG=/abs/path/to/your/big_graph.sg \
GRAPH_WSG=/abs/path/to/your/big_graph.wsg \
START_AFTER_RSS_GB=30 PERF_STOP_AFTER_SEC=180 SAMPLE_PERIOD=20000 WINDOW_GB=64 \
  ./run_gapbs_suite_real_graph_bigmem_profile.sh
```

Outputs go under `perf_results/gapbs_real_bigmem_*/<alg>/`.

- **Dataset helper: SNAP com-friendster**:

This repo includes a helper that downloads SNAP `com-friendster` and converts it to both formats:
- `com-friendster.sg` (for `bfs/pr/cc`)
- `com-friendster.wsg` (for `sssp`)

```bash
./prepare_gapbs_com_friendster.sh
```


- **XGBoost**:

```bash
./run_xgboost_profile.sh
```

- **llama.cpp `llama-bench` (loads + stores, store-window plots)**:

```bash
LLAMA_DIR=/data/xiayanwen/research/llama.cpp \
MODEL=/data/xiayanwen/research/llama.cpp/models/llama2_7b_chat_from_llama2c_f32.gguf \
THREADS=32 PROMPT=256 GEN=256 REPS=1 \
WINDOW_GB=64 ./run_llama_bench_profile.sh
```

- **AIFM DataFrame (pure Linux “All in memory”, ~31GiB working set)**:

One-time input prep (downloads ~16GB NYC taxi CSVs, builds `all.csv`):

```bash
DATA_DIR=/data/xiayanwen/research/Workload-Profiling/data/aifm_dataframe \
  ./prepare_aifm_dataframe_input.sh
```

Note: the original AIFM artifact uses legacy CSV URLs that may now return HTTP 403. This repo’s input prep script falls back to the current TLC **parquet** endpoints and converts them into a legacy-shaped CSV; since the parquet schema no longer includes longitude/latitude, it **synthesizes** `pickup_*`/`dropoff_*` lon/lat from location IDs so the original `DataFrame/original/app/main.cc` workload can run unchanged.

If your peak RSS is below the ~31GiB target, you can scale the dataset by adding more months during input prep, e.g.:

```bash
EXTRA_MONTHS="2016-07" FORCE_REBUILD=1 ./prepare_aifm_dataframe_input.sh
```

Run + profile (loads+stores) + plot store-window heatmaps:

```bash
SAMPLE_PERIOD=20000 WINDOW_GB=32 AUTO_PAD=1 TITLE_MODE=simple \
  ./run_aifm_dataframe_linux_profile.sh
```

Common knobs across runners:
- `SAMPLE_PERIOD`: smaller => higher sampling rate (bigger `perf.data`)
- `PERF_STOP_AFTER_SEC`: sample only the first N seconds (when supported)
- `WINDOW_GB`: window size used for plotting

### Workflow A: Virtual-address heatmap (heap only)

Runs `zipf_bench`, records **data virtual addresses** (`addr`) with PEBS, and draws a heatmap (time vs heap-offset).

```bash
./run_zipf_profile.sh
```

- **Output**: `perf_results/zipf_*/virt_heatmap.png`
- **Key knobs (env)**:
  - `SKEW=0.99` (Zipfian) or `SKEW=0.0` (Uniform)
  - `MEM_SIZE_MB=1024`
  - `THREADS=1` (run `zipf_bench` with N threads pinned to N CPUs)
  - `CPU_START=0` (pin threads to `CPU_START..CPU_START+THREADS-1`)
  - `PERF_DURATION=30` (record this many seconds)
  - `PERF_UNTIL_EXIT=1` (optional: record until the workload exits; ignores `PERF_DURATION`)
  - `SAMPLE_PERIOD=50` (smaller => higher sample rate)
  - `PERF_BIN=/usr/local/bin/perf` (optional override)

### Workflow D: Streaming benchmark heatmap (linear array sweeps)

Runs `stream_bench` (a multi-thread “pure streaming” workload that repeatedly sweeps large arrays), records PEBS **data virtual addresses** (`addr`), and draws a heatmap.

```bash
./run_stream_profile.sh
```

Common knobs:

- `MEM_SIZE_MB=4096` (total mapping size)
- `THREADS=32`, `CPU_START=0`
- `PATTERN=chunk|interleave` (how threads partition the array)
- `OP=read|write|copy|triad` (STREAM-like kernels)
- `PHASE_PAGES=0` (set >0 to shift start offset each pass; can produce diagonal structure)
- `BENCH_DURATION=60`, `PERF_UNTIL_EXIT=1`, `SAMPLE_PERIOD=1000`

Why the heatmap can look “noisy” even for sequential streaming:

- With many threads, the workload is **sequential per-thread**, but **concurrent across the full address range**. A time-vs-address plot aggregates all threads, so you often see a “filled” rectangle rather than a single diagonal.
- If the array sweep is fast relative to sampling/time binning, you get **aliasing** (samples look scattered).

If you want to *visually* see the “brush” moving across the array, use the scan demo:

```bash
./run_stream_scan_demo.sh
```

This demo intentionally scans in **phases** (small moving window + sleep), so the heatmap shows a clear sequential pattern. It is not a peak-bandwidth configuration.

### Workflow B: Physical-address heatmap

Same idea, but records **physical addresses** (`phys_addr`) using `--phys-data`.

```bash
DO_PHYS=1 ./run_zipf_profile.sh
```

- **Output**: `perf_results/zipf_*/phys_heatmap.png`

### Workflow C: “Still hot after Δt” (hot-page persistence)

Produces a bar chart like your example:
pick **baseline hot pages** in an early time window, then measure how many of those pages remain in **Top‑K** for later time bins.

```bash
DO_PERSIST=1 ./run_zipf_profile.sh
```

- **Output**: `perf_results/zipf_*/hot_persistence.png`
- **Key knobs (env)**:
  - `BENCH_DURATION=600` (run long enough to see minutes-scale behavior)
  - `PERF_DURATION=120` (or `PERF_UNTIL_EXIT=1`)
  - `REF_START=0.0` and `REF_WINDOW=2.0` (baseline window in seconds)
  - `TOPK=1024`
  - `BIN_SEC=10.0` (time bin size)
  - `THREADS=1`, `CPU_START=0` (same meaning as above)

Plot styling:

- By default, `hot_persistence.py` uses **matplotlib**.
- To opt-in to your `hachimiku` plotting library:
  - `python3 hot_persistence.py ... --plot-backend hachimiku --hachimiku-dir /mnt/nfs/xiayanwen/research/demos/plot/hachimiku`

### GAPBS PageRank (twitter.sg) end-to-end profiling

If you have GAPBS available at `memtis/memtis-userspace/bench_dir/gapbs`, you can do an end-to-end run (start `pr`, record PEBS addr samples, generate both plots):

```bash
./run_gapbs_pr_profile.sh
```

Useful knobs:

- `PERF_DURATION=60` and `SAMPLE_PERIOD=500` (lower sampling rate -> smaller `perf.data`)
- `TOPK=2048`, `BIN_SEC=5`
- `GAPBS_DIR=...`, `GRAPH=...`, `PR_ARGS="..."` to change workload
- If the graph is not mmapped (no `/proc/<pid>/maps` entry), the script auto-infers a dominant address range from samples.

### Cleanup

Kill running profiler/benchmark:

```bash
./cleanup.sh
```

### Liblinear profiling (loads + stores, store-window plots)

This repo includes a liblinear runner that follows the `liblinear_initialized` / `liblinear_thrashed` gating used by the modified `train` binary, and records **both**:
- `cpu/mem-loads/pp`
- `cpu/mem-stores/pp`

Runner:
- `./run_liblinear_profile.sh`

Useful knobs:
- `DATASET=/path/to/dataset` (e.g. `.../webspam_wc_normalized_trigram.svm`)
- `TRAIN_ARGS='-s 6 -m 80 -e 0.000001'`
- `DO_STORE=1` (default on)
- `PERF_STOP_AFTER_SEC=300` (sample only the first N seconds; benchmark continues)
- `START_AFTER_RSS_GB=40` (start sampling only after RSS reaches N GiB)
- `WINDOW_GB=64` (window size for plots)

Outputs:
- `virt_heatmap_load.png` (load-derived window)
- `virt_heatmap_store.png` (store-derived window, when stores are enabled)
- `virt_heatmap_load_in_store_window.png` (loads plotted in the store-derived window)

### Store-window replotting (reusable)

If a run directory has `points.txt` with store samples, you can regenerate comparable plots via:
- `./replot_store_window.sh /abs/path/to/perf_results/<run_dir>`

This produces:
- `virt_heatmap_store_storewin.png`
- `virt_heatmap_load_in_storewin.png`

Also remove local artifacts (binaries, `*.data`, etc):

```bash
CLEAN_ARTIFACTS=1 ./cleanup.sh
```

Note: some old `perf*.data` / `test*.data` files may be **root-owned** (created by `sudo perf record`), so removal requires sudo (the script will prompt).

Remove everything including `perf_results/`:

```bash
CLEAN_ARTIFACTS=1 CLEAN_RESULTS=1 ./cleanup.sh
```

### GAPBS PageRank profiling (twitter.sg)

If you want to profile GAPBS PageRank directly (instead of `zipf_bench`), use:

```bash
./run_gapbs_pr_profile.sh
```

- **Longer or lower-rate sampling**:

```bash
PERF_DURATION=300 SAMPLE_PERIOD=2000 ./run_gapbs_pr_profile.sh
```

- **Sample until PageRank exits**:

```bash
PERF_UNTIL_EXIT=1 SAMPLE_PERIOD=2000 ./run_gapbs_pr_profile.sh
```

- **Plot a wider (e.g. 12GB) contiguous address range** (instead of a single hottest 1GB bucket):

```bash
ADDR_MODE=window WINDOW_GB=12 ./run_gapbs_pr_profile.sh
```

By default the 12GB window is picked **around the dominant region** (`WINDOW_STRATEGY=around`) to avoid tiny outliers. If you want strictly lowest-address window (address-ordered):

```bash
ADDR_MODE=window WINDOW_GB=12 WINDOW_STRATEGY=min ./run_gapbs_pr_profile.sh
```

If you want the 12GB window with the most samples instead:

```bash
ADDR_MODE=window WINDOW_GB=12 WINDOW_STRATEGY=best ./run_gapbs_pr_profile.sh
```

To plot absolute virtual addresses (not offset):

```bash
PLOT_Y_OFFSET=0 ADDR_MODE=window WINDOW_GB=12 ./run_gapbs_pr_profile.sh
```

### GAPBS BFS (twitter.sg) end-to-end profiling

Run BFS, record PEBS data-address samples, and generate both plots:

```bash
./run_gapbs_bfs_profile.sh
```

Common knobs:

- `GRAPH=benchmark/graphs/twitter.sg` and `BFS_ARGS="-f ${GRAPH} -n64"` (override workload)
- `OMP_NUM_THREADS=32` (control OpenMP threads)
- `PERF_DURATION=60`, `SAMPLE_PERIOD=2000`, or `PERF_UNTIL_EXIT=1`
- Address range selection for plotting: `ADDR_MODE=window WINDOW_GB=12 WINDOW_STRATEGY=best`


### GAPBS SSSP (twitter.sg) end-to-end profiling

Run SSSP (delta-stepping), record PEBS data-address samples, and generate both plots:

```bash
./run_gapbs_sssp_profile.sh
```

Common knobs:

- `GRAPH=benchmark/graphs/twitter.sg`
- `SSSP_ARGS="-f ${GRAPH} -n16 -d1 -l"`
  - `-n`: number of trials (**each trial picks a new random source** unless you force `-r`)
  - `-r <node>`: fix the source (disables per-trial source randomness)
  - `-d <delta>`: delta-stepping bucket width (graph-dependent)
  - `-l`: enable per-trial step logging (useful to correlate phases with the heatmap time axis)
- `OMP_NUM_THREADS=32`
- `PERF_DURATION=120`, `SAMPLE_PERIOD=2000`, or `PERF_UNTIL_EXIT=1`
- Address range selection for plotting: `ADDR_MODE=window WINDOW_GB=12 WINDOW_STRATEGY=best`

Note: `sssp` requires a **weighted** graph. If you pass an unweighted serialized `.sg` (like `twitter.sg`), the script will automatically convert it once to an edge list (`.el`) under `perf_results/gapbs_sssp/` and let GAPBS insert weights during graph build.


## VoltDB profiling (Voter sample application)

**What is it?**
- **VoltDB** is an in-memory OLTP (transactional) relational database.
- The **Voter** sample application simulates a phone/SMS voting workload: many clients issue short stored-procedure transactions (“cast vote”, “contestant lookup”, etc.).
- It’s a good representative “DB application” workload: indexing, procedure execution, logging, heap allocation/GC, and lots of memory traffic.

**How to run (Linux only):**

This repo does not vendor VoltDB. Provide a VoltDB distribution locally:

- If you already extracted it:

```bash
VOLTDB_HOME=/abs/path/to/voltdb ./run_voltdb_voter_linux_profile.sh
```

- If you have a tarball:

```bash
VOLTDB_TARBALL=/abs/path/to/voltdb-*.tar.gz ./run_voltdb_voter_linux_profile.sh
```

Common knobs:
- `HEAP_GB=16` (JVM heap target; best-effort)
- `THREADS=32`
- `START_AFTER_RSS_GB=8` (RSS gate before starting perf sampling)
- `PERF_STOP_AFTER_SEC=180` and `SAMPLE_PERIOD=20000`Outputs are written under `perf_results/voltdb_voter_*` and include `perf.data`, `points.txt`, and the two store/load heatmaps.
