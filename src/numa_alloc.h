// Copyright (c) 2015, The Regents of the University of California (Regents)
// See LICENSE.txt for license details

#ifndef NUMA_ALLOC_H_
#define NUMA_ALLOC_H_

// NUMA-aware allocator for persistent CSR graph arrays.
//
// Compile with -DGAPBS_NUMA and link with -lnuma to enable.
// Set GAPBS_REMOTE_NODE=<n> at runtime to place graph on NUMA node n.
//
// Lifecycle:
//   GraphAlloc  — mmap with default policy (local, fast graph build).
//   GraphUnpin  — mbind(MPOL_BIND | MPOL_MF_MOVE) physically migrates pages
//                 to the remote node, then mbind(MPOL_DEFAULT) releases the
//                 binding.  Called once at workload start (BenchmarkKernel).
//                 Pages now sit on remote and are eligible for migration back
//                 to local by DAMON / TPP / Nomad / Ripple.
//                 MPOL_MF_MOVE is a memory operation and works regardless of
//                 whether the target node has online CPUs.
//   GraphFree   — munmap (paired with mmap).
//
// Without -DGAPBS_NUMA or without GAPBS_REMOTE_NODE, all three are no-ops
// that fall back to new[] / delete[] so every call site is always correct.

#ifdef GAPBS_NUMA

#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <numa.h>
#include <numaif.h>

// Returns the target NUMA node from $GAPBS_REMOTE_NODE, or -1 if unset/invalid.
// Prints a one-time banner on first call when a valid node is configured.
static int GraphNumaNode() {
  static int node = []() -> int {
    const char* v = std::getenv("GAPBS_REMOTE_NODE");
    if (!v) return -1;
    if (numa_available() < 0) {
      std::fprintf(stderr, "NUMA: libnuma unavailable, GAPBS_REMOTE_NODE ignored\n");
      return -1;
    }
    int n = std::atoi(v);
    if (n < 0 || n >= numa_num_configured_nodes()) {
      std::fprintf(stderr, "NUMA: node %d out of range (0..%d), ignoring\n",
                   n, numa_num_configured_nodes() - 1);
      return -1;
    }
    std::printf("NUMA remote node:    %d\n", n);
    return n;
  }();
  return node;
}

// Allocate count elements of T via mmap with default NUMA policy.
// Pages are placed locally (fast build); GraphUnpin physically moves them to
// the remote node before the trial loop via MPOL_MF_MOVE.
// mmap (not new[]) is required so that mbind in GraphUnpin is page-aligned.
template <typename T>
T* GraphAlloc(size_t count) {
  size_t size = count * sizeof(T);
  void* p = mmap(nullptr, size, PROT_READ | PROT_WRITE,
                 MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
  if (p == MAP_FAILED) {
    std::fprintf(stderr, "GraphAlloc: mmap(%zu bytes) failed\n", size);
    std::exit(1);
  }
  if (GraphNumaNode() >= 0)
    std::printf("NUMA alloc:          %.1f MB (will move to node %d at unpin)\n",
                size / (1024.0 * 1024.0), GraphNumaNode());
  return static_cast<T*>(p);
}

// Release a GraphAlloc region.
template <typename T>
void GraphFree(T* ptr, size_t count) {
  if (ptr)
    munmap(static_cast<void*>(ptr), count * sizeof(T));
}

// Move pages to the remote node then release binding so the tier system can
// migrate them back to local.  Uses MPOL_MF_MOVE so placement is physical and
// independent of CPU affinity or whether the target node has online CPUs.
// Called once per array at workload start via CSRGraph::UnpinArrays().
template <typename T>
void GraphUnpin(T* ptr, size_t count) {
  if (!ptr || GraphNumaNode() < 0) return;
  size_t size = count * sizeof(T);
  void* p = static_cast<void*>(ptr);
  int node = GraphNumaNode();

  struct bitmask* mask = numa_bitmask_alloc(numa_num_possible_nodes());
  numa_bitmask_setbit(mask, (unsigned int)node);
  int ret = mbind(p, size, MPOL_BIND, mask->maskp, mask->size + 1, MPOL_MF_MOVE);
  numa_bitmask_free(mask);
  if (ret != 0)
    std::perror("GraphUnpin: mbind(MPOL_BIND|MPOL_MF_MOVE) — pages may be partially remote");

  mbind(p, size, MPOL_DEFAULT, nullptr, 0, 0);
  std::printf("NUMA move+unpin:     %.1f MB -> node %d\n",
              size / (1024.0 * 1024.0), node);
}

// Reset the process-level NUMA memory policy to local allocation.
// Called after all per-array unpins so that working arrays allocated during
// the trial loop (scores, queues, etc.) land on the local node, not remote.
// This undoes any --membind set by numactl on the command line.
static inline void GraphResetPolicy() {
  if (GraphNumaNode() < 0) return;
  numa_set_localalloc();
  std::printf("NUMA policy:         reset to local\n");
}

// Drop the kernel page cache so the trial starts with cold memory.
// Requires the process to have write access to /proc/sys/vm/drop_caches
// (typically via sudo or CAP_SYS_ADMIN).
static inline void GraphDropCaches() {
  if (GraphNumaNode() < 0) return;
  sync();
  int fd = open("/proc/sys/vm/drop_caches", O_WRONLY);
  if (fd < 0) {
    std::perror("GraphDropCaches: open /proc/sys/vm/drop_caches (needs root)");
    return;
  }
  if (write(fd, "3\n", 2) < 0)
    std::perror("GraphDropCaches: write");
  close(fd);
  std::printf("NUMA drop caches:    done\n");
}

#else  // !GAPBS_NUMA ---------------------------------------------------

static inline int GraphNumaNode() { return -1; }

template <typename T> T*   GraphAlloc(size_t count)   { return new T[count]; }
template <typename T> void GraphFree(T* ptr, size_t)  { delete[] ptr; }
template <typename T> void GraphUnpin(T*, size_t)     {}
static inline void         GraphResetPolicy()         {}
static inline void         GraphDropCaches()          {}

#endif  // GAPBS_NUMA

#endif  // NUMA_ALLOC_H_
