#include <algorithm>
#include <atomic>
#include <chrono>
#include <cinttypes>
#include <cstring>
#include <iostream>
#include <string>
#include <thread>
#include <vector>
#
#include <pthread.h>
#include <sched.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <unistd.h>

namespace {

constexpr size_t kPageSize = 4096;

enum class Op {
  kRead,   // sum += a[i]
  kWrite,  // a[i] = ...
  kCopy,   // b[i] = a[i]
  kTriad,  // a[i] = b[i] + scalar * c[i]
};

enum class Pattern {
  kChunk,      // each thread gets a contiguous chunk [lo, hi)
  kInterleave  // thread t touches i = t, t+T, t+2T, ...
};

struct Config {
  size_t mem_mb = 1024;
  int threads = 1;
  int cpu_start = 0;   // if <0 => don't pin
  int duration_sec = 60;
  int warmup_sec = 0;
  int passes_per_check = 1;     // how often we check the stop flag (in passes)
  size_t phase_pages = 0;       // shift start index by phase_pages each pass (0 => disabled)
  // Visualization knobs (optional):
  // If window_pages > 0: each phase scans only a window inside the per-thread region,
  // then optionally sleeps and/or synchronizes across threads. This makes the scan
  // pattern visible in a time-vs-address heatmap.
  size_t window_pages = 0;      // 0 => scan full assigned range each pass (default)
  size_t step_pages = 0;        // 0 => step == window_pages
  int phase_sleep_us = 0;       // 0 => no sleep between phases
  bool sync_phases = false;     // barrier after each phase
  Op op = Op::kTriad;
  Pattern pattern = Pattern::kChunk;
  bool touch = true;
};

static std::atomic<uint64_t> g_sink{0};

static void pin_to_cpu_if_needed(int cpu) {
  if (cpu < 0) return;
  cpu_set_t set;
  CPU_ZERO(&set);
  CPU_SET(cpu, &set);
  (void)pthread_setaffinity_np(pthread_self(), sizeof(set), &set);
}

static bool parse_flag(const char* arg, const char* name, const char** out_val) {
  const size_t n = std::strlen(name);
  if (std::strncmp(arg, name, n) != 0) return false;
  if (arg[n] == '\0') {
    *out_val = nullptr;
    return true;
  }
  if (arg[n] != '=') return false;
  *out_val = arg + n + 1;
  return true;
}

static void usage(const char* argv0) {
  std::cerr
      << "Usage: " << argv0 << " [options]\n"
      << "\n"
      << "Options:\n"
      << "  --mem-mb=<MB>            Total mapping size in MB (default: 1024)\n"
      << "  --threads=<N>            Number of worker threads (default: 1)\n"
      << "  --duration=<sec>         Run duration in seconds (default: 60)\n"
      << "  --warmup=<sec>           Sleep before starting work (default: 0)\n"
      << "  --cpu-start=<cpu>        Pin threads to cpu-start..cpu-start+N-1 (default: 0)\n"
      << "                           Use --cpu-start=-1 to disable pinning\n"
      << "  --pattern=chunk|interleave   Access pattern (default: chunk)\n"
      << "  --op=read|write|copy|triad   Operation (default: triad)\n"
      << "  --touch=0|1              Touch pages before run to fault-in (default: 1)\n"
      << "  --phase-pages=<P>        Per-pass start offset in pages (default: 0)\n"
      << "                           (0 disables phase shifting)\n"
      << "  --window-pages=<P>       If >0: scan only this many pages per phase (visualize scan)\n"
      << "  --step-pages=<P>         Phase step in pages (default: window-pages)\n"
      << "  --phase-sleep-us=<usec>  Sleep after each phase (default: 0)\n"
      << "  --sync-phases=0|1        Barrier sync after each phase (default: 0)\n"
      << "\n"
      << "Notes:\n"
      << "  - Uses one anonymous mmap region; arrays are laid out back-to-back.\n"
      << "  - Prints: Populating memory (0xAAA - 0xBBB)... for profiling scripts.\n";
}

static bool parse_args(int argc, char** argv, Config* cfg) {
  for (int i = 1; i < argc; i++) {
    const char* a = argv[i];
    const char* v = nullptr;

    if (std::strcmp(a, "--help") == 0 || std::strcmp(a, "-h") == 0) {
      usage(argv[0]);
      return false;
    }
    if (parse_flag(a, "--mem-mb", &v) && v) {
      cfg->mem_mb = std::stoull(v);
      continue;
    }
    if (parse_flag(a, "--threads", &v) && v) {
      cfg->threads = std::max(1, std::stoi(v));
      continue;
    }
    if (parse_flag(a, "--duration", &v) && v) {
      cfg->duration_sec = std::max(1, std::stoi(v));
      continue;
    }
    if (parse_flag(a, "--warmup", &v) && v) {
      cfg->warmup_sec = std::max(0, std::stoi(v));
      continue;
    }
    if (parse_flag(a, "--cpu-start", &v) && v) {
      cfg->cpu_start = std::stoi(v);
      continue;
    }
    if (parse_flag(a, "--touch", &v) && v) {
      cfg->touch = (std::stoi(v) != 0);
      continue;
    }
    if (parse_flag(a, "--phase-pages", &v) && v) {
      cfg->phase_pages = std::stoull(v);
      continue;
    }
    if (parse_flag(a, "--window-pages", &v) && v) {
      cfg->window_pages = std::stoull(v);
      continue;
    }
    if (parse_flag(a, "--step-pages", &v) && v) {
      cfg->step_pages = std::stoull(v);
      continue;
    }
    if (parse_flag(a, "--phase-sleep-us", &v) && v) {
      cfg->phase_sleep_us = std::stoi(v);
      continue;
    }
    if (parse_flag(a, "--sync-phases", &v) && v) {
      cfg->sync_phases = (std::stoi(v) != 0);
      continue;
    }
    if (parse_flag(a, "--pattern", &v) && v) {
      if (std::strcmp(v, "chunk") == 0) cfg->pattern = Pattern::kChunk;
      else if (std::strcmp(v, "interleave") == 0) cfg->pattern = Pattern::kInterleave;
      else {
        std::cerr << "Unknown --pattern: " << v << "\n";
        return false;
      }
      continue;
    }
    if (parse_flag(a, "--op", &v) && v) {
      if (std::strcmp(v, "read") == 0) cfg->op = Op::kRead;
      else if (std::strcmp(v, "write") == 0) cfg->op = Op::kWrite;
      else if (std::strcmp(v, "copy") == 0) cfg->op = Op::kCopy;
      else if (std::strcmp(v, "triad") == 0) cfg->op = Op::kTriad;
      else {
        std::cerr << "Unknown --op: " << v << "\n";
        return false;
      }
      continue;
    }

    std::cerr << "Unknown arg: " << a << "\n";
    usage(argv[0]);
    return false;
  }
  return true;
}

static inline void compiler_fence() {
  asm volatile("" ::: "memory");
}

}  // namespace

int main(int argc, char** argv) {
  Config cfg;
  if (!parse_args(argc, argv, &cfg)) {
    return 1;
  }

  const size_t total_bytes = cfg.mem_mb * 1024ULL * 1024ULL;
  const size_t total_pages = (total_bytes + kPageSize - 1) / kPageSize;
  const size_t map_bytes = total_pages * kPageSize;

  // 3 arrays for triad, 2 for copy, 1 for read/write.
  const int n_arrays = (cfg.op == Op::kTriad) ? 3 : (cfg.op == Op::kCopy) ? 2 : 1;
  const size_t elems_total = map_bytes / sizeof(uint64_t);
  const size_t elems_per_array = elems_total / static_cast<size_t>(n_arrays);
  const size_t bytes_used = elems_per_array * sizeof(uint64_t) * static_cast<size_t>(n_arrays);

  std::cout << "stream_bench pid: " << getpid() << "\n";
  std::cout << "Config: mem_mb=" << cfg.mem_mb
            << " threads=" << cfg.threads
            << " duration=" << cfg.duration_sec
            << " cpu_start=" << cfg.cpu_start
            << " pattern=" << (cfg.pattern == Pattern::kChunk ? "chunk" : "interleave")
            << " op=";
  switch (cfg.op) {
    case Op::kRead: std::cout << "read"; break;
    case Op::kWrite: std::cout << "write"; break;
    case Op::kCopy: std::cout << "copy"; break;
    case Op::kTriad: std::cout << "triad"; break;
  }
  std::cout << " touch=" << (cfg.touch ? 1 : 0)
            << " phase_pages=" << cfg.phase_pages
            << " window_pages=" << cfg.window_pages
            << " step_pages=" << cfg.step_pages
            << " phase_sleep_us=" << cfg.phase_sleep_us
            << " sync_phases=" << (cfg.sync_phases ? 1 : 0)
            << " arrays=" << n_arrays
            << "\n";
  std::cout << "Mapping bytes: " << map_bytes << " (" << total_pages << " pages)\n";
  std::cout << "Array elements per array: " << elems_per_array
            << " (bytes_used=" << bytes_used << ")\n";
  std::cout << std::flush;

  void* base = mmap(nullptr, bytes_used, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (base == MAP_FAILED) {
    std::cerr << "mmap failed: " << std::strerror(errno) << "\n";
    return 2;
  }

  auto* raw = reinterpret_cast<uint64_t*>(base);
  uint64_t* a = raw;
  uint64_t* b = (n_arrays >= 2) ? (raw + elems_per_array) : nullptr;
  uint64_t* c = (n_arrays >= 3) ? (raw + 2 * elems_per_array) : nullptr;

  if (cfg.touch) {
    std::cout << "Populating memory (" << base << " - " << (void*)((char*)base + bytes_used) << ")...\n";
    std::cout << std::flush; // important when stdout is redirected to a file
    // Touch one byte per page. Also seed values so ops have real loads.
    volatile uint8_t* p = reinterpret_cast<volatile uint8_t*>(base);
    for (size_t off = 0; off < bytes_used; off += kPageSize) {
      p[off] = 1;
    }
    // Initialize arrays sparsely (cheap) so triad has non-zero inputs.
    for (size_t i = 0; i < elems_per_array; i += 1024) {
      a[i] = static_cast<uint64_t>(i);
      if (b) b[i] = static_cast<uint64_t>(i ^ 0x9e3779b97f4a7c15ULL);
      if (c) c[i] = static_cast<uint64_t>(i + 7);
    }
  } else {
    std::cout << "Populating memory (" << base << " - " << (void*)((char*)base + bytes_used) << ")... (touch disabled)\n";
    std::cout << std::flush;
  }

  // Signal to profiling scripts that the mapping is ready and the hot loop is about to start.
  std::cout << "READY: begin streaming loop\n" << std::flush;

  if (cfg.warmup_sec > 0) {
    std::cout << "Warmup sleep: " << cfg.warmup_sec << " sec\n";
    std::this_thread::sleep_for(std::chrono::seconds(cfg.warmup_sec));
  }

  std::atomic<bool> stop{false};
  const auto t_start = std::chrono::steady_clock::now();
  const auto t_end = t_start + std::chrono::seconds(cfg.duration_sec);
  const uint64_t scalar = 3;

  // Optional phase barrier (C++17: use pthread_barrier_t).
  pthread_barrier_t barrier;
  pthread_barrier_t* barrier_ptr = nullptr;
  if (cfg.sync_phases && cfg.threads > 1) {
    if (pthread_barrier_init(&barrier, nullptr, static_cast<unsigned>(cfg.threads)) == 0) {
      barrier_ptr = &barrier;
    } else {
      std::cerr << "Warning: pthread_barrier_init failed; disabling sync_phases\n";
    }
  }

  const size_t elems_per_page = kPageSize / sizeof(uint64_t);
  const size_t window_elems = (cfg.window_pages > 0) ? (cfg.window_pages * elems_per_page) : 0;
  const size_t eff_step_pages = (cfg.window_pages > 0) ? ((cfg.step_pages > 0) ? cfg.step_pages : cfg.window_pages) : 0;
  const size_t step_elems = (eff_step_pages > 0) ? (eff_step_pages * elems_per_page) : 0;

  auto worker = [&](int tid) {
    pin_to_cpu_if_needed(cfg.cpu_start < 0 ? -1 : (cfg.cpu_start + tid));

    uint64_t local = 0;
    size_t pass = 0;

    // Work on a single array-length (elems_per_array). All ops confined within that.
    const size_t n = elems_per_array;
    const int T = cfg.threads;

    // Chunk assignment
    const size_t chunk = (n + static_cast<size_t>(T) - 1) / static_cast<size_t>(T);
    const size_t chunk_lo0 = std::min(n, static_cast<size_t>(tid) * chunk);
    const size_t chunk_hi0 = std::min(n, chunk_lo0 + chunk);

    while (true) {
      // Phase shift moves the starting index each pass, creating visible diagonals if enabled.
      const size_t phase_shift = (cfg.phase_pages == 0) ? 0 : ((pass * cfg.phase_pages) * elems_per_page) % n;

      if (cfg.pattern == Pattern::kChunk) {
        // Rotate within the thread's chunk by an optional window (for visualization).
        const size_t chunk_len = (chunk_hi0 > chunk_lo0) ? (chunk_hi0 - chunk_lo0) : 0;
        size_t sub_len = chunk_len;
        if (window_elems > 0 && chunk_len > 0) {
          sub_len = std::min(chunk_len, window_elems);
        }
        // Step inside the chunk when windowing is enabled.
        const size_t per_thread_step = (window_elems > 0 && step_elems > 0 && chunk_len > 0) ? (step_elems % chunk_len) : 0;
        const size_t per_thread_phase = (window_elems > 0 && chunk_len > 0) ? ((pass * per_thread_step) % chunk_len) : 0;

        const size_t lo = (chunk_lo0 + per_thread_phase + phase_shift) % n;
        const size_t hi = (chunk_lo0 + per_thread_phase + sub_len + phase_shift) % n;
        if (lo <= hi) {
          // Single interval [lo, hi)
          for (size_t i = lo; i < hi; i++) {
            switch (cfg.op) {
              case Op::kRead: {
                uint64_t v = a[i];
                local += v;
                break;
              }
              case Op::kWrite: {
                uint64_t v = static_cast<uint64_t>(i) + local;
                a[i] = v;
                local += v;
                break;
              }
              case Op::kCopy: {
                uint64_t v = a[i];
                b[i] = v;
                local += v;
                break;
              }
              case Op::kTriad: {
                uint64_t v = b[i] + scalar * c[i];
                a[i] = v;
                local += v;
                break;
              }
            }
          }
        } else {
          // Wrapped intervals [lo, n) + [0, hi)
          for (size_t i = lo; i < n; i++) {
            switch (cfg.op) {
              case Op::kRead: {
                uint64_t v = a[i];
                local += v;
                break;
              }
              case Op::kWrite: {
                uint64_t v = static_cast<uint64_t>(i) + local;
                a[i] = v;
                local += v;
                break;
              }
              case Op::kCopy: {
                uint64_t v = a[i];
                b[i] = v;
                local += v;
                break;
              }
              case Op::kTriad: {
                uint64_t v = b[i] + scalar * c[i];
                a[i] = v;
                local += v;
                break;
              }
            }
          }
          for (size_t i = 0; i < hi; i++) {
            switch (cfg.op) {
              case Op::kRead: {
                uint64_t v = a[i];
                local += v;
                break;
              }
              case Op::kWrite: {
                uint64_t v = static_cast<uint64_t>(i) + local;
                a[i] = v;
                local += v;
                break;
              }
              case Op::kCopy: {
                uint64_t v = a[i];
                b[i] = v;
                local += v;
                break;
              }
              case Op::kTriad: {
                uint64_t v = b[i] + scalar * c[i];
                a[i] = v;
                local += v;
                break;
              }
            }
          }
        }
      } else {
        // Interleaved pattern (stride = threads).
        // Optional: windowed scanning for visualization (shared window across threads).
        size_t base = phase_shift;
        size_t len = n;
        if (window_elems > 0) {
          const size_t w = std::min(n, window_elems);
          const size_t st = (step_elems > 0) ? ((pass * step_elems) % n) : 0;
          base = (st + phase_shift) % n;
          len = w;
        }
        for (size_t off = static_cast<size_t>(tid); off < len; off += static_cast<size_t>(T)) {
          const size_t i = (base + off) % n;
          switch (cfg.op) {
            case Op::kRead: {
              uint64_t v = a[i];
              local += v;
              break;
            }
            case Op::kWrite: {
              uint64_t v = static_cast<uint64_t>(i) + local;
              a[i] = v;
              local += v;
              break;
            }
            case Op::kCopy: {
              uint64_t v = a[i];
              b[i] = v;
              local += v;
              break;
            }
            case Op::kTriad: {
              uint64_t v = b[i] + scalar * c[i];
              a[i] = v;
              local += v;
              break;
            }
          }
        }
      }

      pass++;

      if (barrier_ptr) {
        (void)pthread_barrier_wait(barrier_ptr);
      }
      if (cfg.phase_sleep_us > 0 && window_elems > 0) {
        std::this_thread::sleep_for(std::chrono::microseconds(cfg.phase_sleep_us));
      }

      if ((pass % static_cast<size_t>(std::max(1, cfg.passes_per_check))) == 0) {
        const auto now = std::chrono::steady_clock::now();
        if (now >= t_end) break;
        if (stop.load(std::memory_order_relaxed)) break;
      }
    }

    // Make sure compiler can't drop loops.
    compiler_fence();
    g_sink.fetch_add(local, std::memory_order_relaxed);
  };

  std::vector<std::thread> th;
  th.reserve(static_cast<size_t>(cfg.threads));
  for (int t = 0; t < cfg.threads; t++) {
    th.emplace_back(worker, t);
  }
  for (auto& x : th) x.join();

  const auto t_done = std::chrono::steady_clock::now();
  const double sec = std::chrono::duration<double>(t_done - t_start).count();

  // Rough bytes/touched per full pass (per thread ranges may not cover entire array if chunk rounding).
  // This is informational only.
  std::cout << "Done. elapsed_sec=" << sec << " sink=" << g_sink.load() << "\n";

  if (barrier_ptr) {
    pthread_barrier_destroy(barrier_ptr);
  }
  munmap(base, bytes_used);
  return 0;
}


