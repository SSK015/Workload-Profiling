## memtis_ebpf_example

This directory contains a **Zipf/Uniform page-access benchmark** plus a **perf/PEBS** workflow to collect **data-address samples** and analyze page hotness.

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

### Workflow A: Virtual-address heatmap (heap only)

Runs `zipf_bench`, records **data virtual addresses** (`addr`) with PEBS, and draws a heatmap (time vs heap-offset).

```bash
./run_virt_plot.sh
```

- **Output**: `perf_results/virt_heatmap.png`
- **Key knobs (env)**:
  - `SKEW=0.99` (Zipfian) or `SKEW=0.0` (Uniform)
  - `MEM_SIZE_MB=1024`
  - `SAMPLING_CORES=1` (run `zipf_bench` with N threads pinned to N CPUs)
  - `CPU_START=0` (pin threads to `CPU_START..CPU_START+SAMPLING_CORES-1`)
  - `PERF_DURATION=30` (record this many seconds)
  - `PERF_UNTIL_EXIT=1` (optional: record until the workload exits; ignores `PERF_DURATION`)
  - `SAMPLE_PERIOD=50` (smaller => higher sample rate)
  - `PERF_BIN=/usr/local/bin/perf` (optional override)

### Workflow B: Physical-address heatmap

Same idea, but records **physical addresses** (`phys_addr`) using `--phys-data`.

```bash
./run_phys_plot.sh
```

- **Output**: `perf_results/phys_heatmap.png`

### Workflow C: “Still hot after Δt” (hot-page persistence)

Produces a bar chart like your example:
pick **baseline hot pages** in an early time window, then measure how many of those pages remain in **Top‑K** for later time bins.

```bash
./run_hot_persistence.sh
```

- **Output**: `perf_results/hot_persistence.png`
- **Key knobs (env)**:
  - `BENCH_DURATION=600` (run long enough to see minutes-scale behavior)
  - `PERF_DURATION=120` (or `PERF_UNTIL_EXIT=1`)
  - `REF_START=0.0` and `REF_WINDOW=2.0` (baseline window in seconds)
  - `TOPK=1024`
  - `BIN_SEC=10.0` (time bin size)
  - `SAMPLING_CORES=1`, `CPU_START=0` (same meaning as above)

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


