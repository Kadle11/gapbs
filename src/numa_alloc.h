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
//   GraphAlloc  — mmap + mbind(MPOL_BIND, remote_node)
//                 Pages are fault-in'd on the remote node during graph build.
//   GraphUnpin  — mbind(MPOL_DEFAULT) on the same region.
//                 Called once at workload start (BenchmarkKernel).
//                 Existing remote pages stay in place but are now eligible for
//                 migration by DAMON / TPP / Nomad / Ripple.
//   GraphFree   — munmap (paired with mmap).
//
// Without -DGAPBS_NUMA or without GAPBS_REMOTE_NODE, all three are no-ops
// that fall back to new[] / delete[] so every call site is always correct.

#ifdef GAPBS_NUMA

#include <cstdio>
#include <cstdlib>
#include <sys/mman.h>
#include <numa.h>
#include <numaif.h>

// Returns the target NUMA node from $GAPBS_REMOTE_NODE, or -1 if unset/invalid.
static int GraphNumaNode() {
  static int node = []() -> int {
    const char* v = std::getenv("GAPBS_REMOTE_NODE");
    if (!v) return -1;
    if (numa_available() < 0) return -1;
    int n = std::atoi(v);
    if (n < 0 || n >= numa_num_configured_nodes()) return -1;
    return n;
  }();
  return node;
}

// Allocate count elements of T via mmap, bound to the remote NUMA node.
// mmap (not new[]) is required so that mbind operates on page-aligned ranges.
template <typename T>
T* GraphAlloc(size_t count) {
  size_t size = count * sizeof(T);
  void* p = mmap(nullptr, size, PROT_READ | PROT_WRITE,
                 MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
  if (p == MAP_FAILED) {
    std::fprintf(stderr, "GraphAlloc: mmap(%zu bytes) failed\n", size);
    std::exit(1);
  }
  int node = GraphNumaNode();
  if (node >= 0) {
    struct bitmask* mask = numa_bitmask_alloc(numa_num_possible_nodes());
    numa_bitmask_setbit(mask, (unsigned int)node);
    if (mbind(p, size, MPOL_BIND, mask->maskp, mask->size + 1, 0) != 0) {
      std::perror("GraphAlloc: mbind(MPOL_BIND)");
      std::exit(1);
    }
    numa_bitmask_free(mask);
  }
  return static_cast<T*>(p);
}

// Release a GraphAlloc region.
template <typename T>
void GraphFree(T* ptr, size_t count) {
  if (ptr)
    munmap(static_cast<void*>(ptr), count * sizeof(T));
}

// Remove NUMA binding from a graph array so its pages can migrate freely.
// Existing pages stay on the remote node; future policy is MPOL_DEFAULT.
// Called once per array at workload start via CSRGraph::UnpinArrays().
template <typename T>
void GraphUnpin(T* ptr, size_t count) {
  if (!ptr || GraphNumaNode() < 0) return;
  mbind(static_cast<void*>(ptr), count * sizeof(T),
        MPOL_DEFAULT, nullptr, 0, 0);
}

#else  // !GAPBS_NUMA ---------------------------------------------------

static inline int GraphNumaNode() { return -1; }

template <typename T> T*   GraphAlloc(size_t count)   { return new T[count]; }
template <typename T> void GraphFree(T* ptr, size_t)  { delete[] ptr; }
template <typename T> void GraphUnpin(T*, size_t)     {}

#endif  // GAPBS_NUMA

#endif  // NUMA_ALLOC_H_
