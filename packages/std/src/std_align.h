#ifndef CYNA_STD_ALIGN_H
#define CYNA_STD_ALIGN_H

#include <stddef.h>
#include <stdlib.h>

#ifdef _WIN32
#include <malloc.h>

static void *cyna_std_alloc_aligned(size_t size, size_t align) {
    if (align < sizeof(void *)) align = sizeof(void *);
    return _aligned_malloc(size, align);
}

static void cyna_std_free_aligned(void *ptr) {
    _aligned_free(ptr);
}
#else

static void *cyna_std_alloc_aligned(size_t size, size_t align) {
    if (align <= _Alignof(max_align_t)) return malloc(size);
    void *ptr = NULL;
    if (posix_memalign(&ptr, align, size) != 0) return NULL;
    return ptr;
}

static void cyna_std_free_aligned(void *ptr) {
    free(ptr);
}
#endif

#endif
