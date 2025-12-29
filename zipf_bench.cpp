#include <iostream>
#include <vector>
#include <random>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <unistd.h>
#include <sys/mman.h>
#include <chrono>
#include <thread>
#include <atomic>
#include <pthread.h>
#include <sched.h>

// Page size
const size_t PAGE_SIZE = 4096;

template <bool sorted>
class ZipfianGenerator {
public:
    static constexpr double ZIPFIAN_CONSTANT = 0.99;

    int num_keys_;
    double alpha_;
    double eta_;
    double zipfian_constant_;
    double zetan_; // Calculated dynamically
    std::uniform_real_distribution<double> dis_;

    explicit ZipfianGenerator(int num_keys,
                              double zipfian_constant = ZIPFIAN_CONSTANT)
        : num_keys_(num_keys), dis_(0, 1), zipfian_constant_(zipfian_constant) {
        
        // Calculate Zeta(N) correctly for the given number of keys
        zetan_ = zeta(num_keys);
        
        double zeta2theta = zeta(2);
        alpha_ = 1. / (1. - zipfian_constant);
        eta_ = (1 - std::pow(2. / num_keys_, 1 - zipfian_constant)) /
               (1 - zeta2theta / zetan_);
    }

    template <typename G>
    int nextValue(G& gen) {
        double u = dis_(gen);
        double uz = u * zetan_;

        int ret;
        if (uz < 1.0) {
            ret = 0;
        } else if (uz < 1.0 + std::pow(0.5, zipfian_constant_)) {
            ret = 1;
        } else {
            ret = (int)(num_keys_ * std::pow(eta_ * u - eta_ + 1, alpha_));
        }

        if constexpr (!sorted) {
            ret = fnv1a(ret) % num_keys_;
        }

        return ret;
    }

    template <typename G>
    int operator()(G& g) {
        return nextValue(g);
    }

    double zeta(long n) {
        double sum = 0.0;
        for (long i = 0; i < n; i++) {
            sum += 1 / std::pow(i + 1, zipfian_constant_);
        }
        return sum;
    }

    // FNV hash from https://create.stephan-brumme.com/fnv-hash/
    static const uint32_t PRIME = 0x01000193;  //   16777619
    static const uint32_t SEED = 0x811C9DC5;   // 2166136261

    /// hash a single byte
    inline uint32_t fnv1a(unsigned char oneByte, uint32_t hash = SEED) {
        return (oneByte ^ hash) * PRIME;
    }

    /// hash a 32 bit integer (four bytes)
    inline uint32_t fnv1a(int fourBytes, uint32_t hash = SEED) {
        const unsigned char* ptr = (const unsigned char*)&fourBytes;
        hash = fnv1a(*ptr++, hash);
        hash = fnv1a(*ptr++, hash);
        hash = fnv1a(*ptr++, hash);
        return fnv1a(*ptr, hash);
    }
};

int main(int argc, char* argv[]) {
    size_t mem_size_mb = 1024; // Default 1GB
    double zipf_alpha = 0.99;
    int duration_sec = 60;
    int num_threads = 1;
    int cpu_start = 0;
    
    if (argc > 1) mem_size_mb = std::stoul(argv[1]);
    if (argc > 2) zipf_alpha = std::stod(argv[2]);
    if (argc > 3) duration_sec = std::stoi(argv[3]);
    if (argc > 4) num_threads = std::max(1, std::stoi(argv[4]));
    if (argc > 5) cpu_start = std::max(0, std::stoi(argv[5]));

    size_t num_pages = (mem_size_mb * 1024 * 1024) / PAGE_SIZE;
    size_t total_size = num_pages * PAGE_SIZE;

    std::cout << "Allocating " << mem_size_mb << " MB (" << num_pages << " pages)..." << std::endl;
    std::cout << "Zipfian constant: " << zipf_alpha << std::endl;
    std::cout << "Duration: " << duration_sec << " seconds" << std::endl;
    std::cout << "Threads: " << num_threads << " (cpu_start=" << cpu_start << ")" << std::endl;

    // Use mmap to ensure we get a clean anonymous mapping
    char* memory = (char*)mmap(NULL, total_size, PROT_READ | PROT_WRITE, 
                              MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    
    if (memory == MAP_FAILED) {
        std::cerr << "mmap failed" << std::endl;
        return 1;
    }

    // Touch all pages once to fault them in
    std::cout << "Populating memory (" << (void*)memory << " - " << (void*)(memory + total_size) << ")..." << std::endl;
    for (size_t i = 0; i < num_pages; i++) {
        memory[i * PAGE_SIZE] = 1;
    }

    // Initialize generator
    // Using sorted=false to scatter hot pages (random-looking access pattern)
    // Using sorted=true to group hot pages together at the start
    
    // Hack to support Uniform distribution for testing
    bool use_uniform = (zipf_alpha < 0.01);
    
    ZipfianGenerator<false> zipf(num_pages, use_uniform ? 0.99 : zipf_alpha);
    std::mt19937 gen(std::random_device{}());
    std::uniform_int_distribution<int> uniform_dist(0, num_pages - 1);

    std::cout << "Starting benchmark (PID: " << getpid() << ")..." << std::endl;
    if (use_uniform) std::cout << "Mode: UNIFORM (sanity check)" << std::endl;

    auto start_time = std::chrono::steady_clock::now();
    std::atomic<bool> stop{false};
    std::atomic<uint64_t> accesses_total{0};

    auto pin_to_cpu = [](int cpu) {
        cpu_set_t set;
        CPU_ZERO(&set);
        CPU_SET(cpu, &set);
        (void)pthread_setaffinity_np(pthread_self(), sizeof(set), &set);
    };

    auto worker = [&](int tid) {
        // Pin each thread to a different CPU to scale sampling across cores.
        pin_to_cpu(cpu_start + tid);

        std::mt19937 lgen(std::random_device{}() + tid * 1337);
        ZipfianGenerator<false> lzipf((int)num_pages, use_uniform ? 0.99 : zipf_alpha);
        std::uniform_int_distribution<int> luniform(0, (int)num_pages - 1);

        volatile char val;
        uint64_t local_accesses = 0;

        while (!stop.load(std::memory_order_relaxed)) {
            int page_idx;
            if (use_uniform) {
                page_idx = luniform(lgen);
            } else {
                page_idx = lzipf(lgen);
            }
            if (page_idx >= (int)num_pages) page_idx = page_idx % (int)num_pages;

            char* page_ptr = memory + (size_t)page_idx * PAGE_SIZE;
            for (int j = 0; j < 64; j++) {
                val = page_ptr[j * 64];
            }
            (void)val;
            local_accesses++;
        }
        accesses_total.fetch_add(local_accesses, std::memory_order_relaxed);
    };

    std::vector<std::thread> threads;
    threads.reserve((size_t)num_threads);
    for (int t = 0; t < num_threads; t++) {
        threads.emplace_back(worker, t);
    }

    // Sleep until duration elapses, then stop all workers.
    while (true) {
        auto now = std::chrono::steady_clock::now();
        if (std::chrono::duration_cast<std::chrono::seconds>(now - start_time).count() >= duration_sec) {
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    stop.store(true, std::memory_order_relaxed);
    for (auto& th : threads) th.join();

    std::cout << "Finished. Total accesses: " << accesses_total.load() << std::endl;

    munmap(memory, total_size);
    return 0;
}

