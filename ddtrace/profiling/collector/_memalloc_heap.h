#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <Python.h>

/* The maximum heap sample size is the maximum value we can store in a heap_tracker_t.allocated_memory */
#define MAX_HEAP_SAMPLE_SIZE UINT32_MAX

[[nodiscard]] bool
memalloc_heap_tracker_init_no_cpython(uint32_t sample_size, size_t code_cache_capacity);
void
memalloc_heap_tracker_deinit_no_cpython(void);

void
memalloc_heap_no_cpython(void);

/* Cheap inline sampling gate: bumps the domain's byte counter and returns true
 * when the threshold is crossed.  Called from every alloc/realloc hook in
 * _memalloc.cpp; the expensive traceback path (memalloc_heap_track_sample_invokes_cpython)
 * is only entered when this returns true.
 *
 * On return true, *allocated_memory_val is set to the domain's accumulated
 * byte count for use as the sample weight.
 *
 * Does NOT make CPython API calls.  Must be called with the GIL held. */
bool
memalloc_heap_sample_check_no_cpython(size_t size, PyMemAllocatorDomain domain, uint64_t* allocated_memory_val);

/* Expensive path: collect traceback, record sample. Only call after
 * memalloc_heap_sample_check_no_cpython returned true. */
void
memalloc_heap_track_sample_invokes_cpython(uint16_t max_nframe,
                                           void* ptr,
                                           size_t size,
                                           PyMemAllocatorDomain domain,
                                           uint64_t allocated_memory_val);

void
memalloc_heap_untrack_no_cpython(void* ptr);

void
memalloc_heap_postfork_child(void);
