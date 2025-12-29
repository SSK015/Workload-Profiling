CXX ?= g++
CXXFLAGS ?= -O3 -std=c++17
LDFLAGS ?= -lpthread

bench_target = zipf_bench

all: $(bench_target)

$(bench_target): zipf_bench.cpp
	$(CXX) $(CXXFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f $(bench_target)

distclean: clean
	rm -f perf.data perf_data.data test*.data* *.data

