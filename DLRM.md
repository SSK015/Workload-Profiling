## DLRM benchmark (DLRM: Deep Learning Recommendation Model)

### What it is
DLRM is a recommender-system benchmark model with:
- **Large embedding tables** (sparse features) + **MLPs** (dense features)
- A **feature interaction** (dot/cat)

The memory footprint is dominated by the embedding table weights, so it’s useful for big-memory access profiling.

### How we run it in this repo
We use the reference implementation from `facebookresearch/dlrm` (`dlrm_s_pytorch.py`) in **random/synthetic** mode (no dataset download):
- `--data-generation=random`
- `--arch-embedding-size` controls the number of rows per embedding table
- `--arch-sparse-feature-size` controls embedding dimension

### One-shot profiling (Linux)
This repo includes a runner that:
- Ensures Python deps are installed (CPU PyTorch + numpy/sklearn/tensorboard/mlperf-logging)
- Starts DLRM, RSS-gates `perf record`, decodes points, and generates the 2 heatmaps

Run:

```bash
./run_dlrm_benchmark_linux_profile.sh
```

### Key knobs
- **Memory scaling** (embedding tables dominate):
  - `TARGET_RSS_GB=30 OVERHEAD_GB=4`
  - `NUM_TABLES=26 ARCH_SPARSE_FEATURE_SIZE=64`
- **RSS gate**:
  - `START_AFTER_RSS_GB=20`
- **Benchmark duration**:
  - `MINI_BATCH_SIZE=2048 NUM_BATCHES=2000`
- **perf sampling**:
  - `PERF_STOP_AFTER_SEC=180 SAMPLE_PERIOD=20000`

### Outputs
Under `perf_results/dlrm_random_*`:
- `perf.data`
- `points.txt`
- `virt_heatmap_store_storewin.png`
- `virt_heatmap_load_in_storewin.png`

