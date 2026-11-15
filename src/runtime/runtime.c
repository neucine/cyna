#if defined(__linux__) && !defined(CYNA_FREESTANDING) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE 1
#endif

#include "cyna.h"
#include "failure_trace.h"

#ifdef CYNA_FREESTANDING
static void *cyna_memcpy(void *dst, const void *src, size_t len) {
    unsigned char *out = (unsigned char *)dst;
    const unsigned char *in = (const unsigned char *)src;
    size_t i;
    for (i = 0; i < len; i += 1) out[i] = in[i];
    return dst;
}

static int cyna_memcmp(const void *lhs, const void *rhs, size_t len) {
    const unsigned char *a = (const unsigned char *)lhs;
    const unsigned char *b = (const unsigned char *)rhs;
    size_t i;
    for (i = 0; i < len; i += 1) {
        if (a[i] != b[i]) return (int)a[i] - (int)b[i];
    }
    return 0;
}

static void *cyna_memset(void *dst, int value, size_t len) {
    unsigned char *out = (unsigned char *)dst;
    unsigned char byte = (unsigned char)value;
    size_t i;
    for (i = 0; i < len; i += 1) out[i] = byte;
    return dst;
}

#define memcpy cyna_memcpy
#define memcmp cyna_memcmp
#define memset cyna_memset
#else
#if !defined(_WIN32)
#include <dlfcn.h>
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#endif

typedef struct CynaTrackedAlloc CynaTrackedAlloc;
struct CynaTrackedAlloc {
    void *ptr;
    void *raw_ptr;
    size_t size;
    const char *site_file;
    int64_t site_line;
    const char *site_kind;
    void *caller;
    CynaTrackedAlloc *next;
};

typedef struct {
    const char *site_file;
    int64_t site_line;
    const char *site_kind;
    void *caller;
    size_t size;
    int64_t count;
    size_t bytes;
    void *sample_ptr;
} CynaLeakSummary;

typedef struct {
    void *ptr;
    size_t size;
    const char *site_file;
    int64_t site_line;
    const char *site_kind;
    void *alloc_caller;
    void *free_caller;
} CynaFreedAlloc;

typedef struct {
    unsigned char *start;
    unsigned char *cursor;
    unsigned char *end;
} CynaBumpAllocatorState;

#ifndef CYNA_FREESTANDING
static void *cyna_libc_alloc(void *ctx, size_t size) {
    (void)ctx;
    return malloc(size);
}

static void *cyna_libc_realloc(void *ctx, void *ptr, size_t size) {
    (void)ctx;
    return realloc(ptr, size);
}

static void cyna_libc_free(void *ctx, void *ptr) {
    (void)ctx;
    free(ptr);
}
#endif

static CynaTrackedAlloc *cyna_tracked_allocs = NULL;
static int64_t cyna_tracked_alloc_count = 0;
static size_t cyna_tracked_alloc_bytes = 0;
static CynaFreedAlloc cyna_freed_allocs[256];
static size_t cyna_freed_alloc_next = 0;
static int cyna_memory_diagnostics_enabled = -1;
static CynaWriterWriteFn cyna_writer_write = NULL;
static void *cyna_writer_ctx = NULL;
static CynaBumpAllocatorState cyna_bump_allocator_state = { NULL, NULL, NULL };
#ifdef CYNA_FREESTANDING
static CynaAllocator cyna_root_allocator = { NULL, NULL, NULL, NULL };
#else
static CynaAllocator cyna_root_allocator = { NULL, cyna_libc_alloc, cyna_libc_realloc, cyna_libc_free };
#endif

typedef struct {
    uint64_t magic;
    size_t size;
} CynaAllocHeader;

static const uint64_t cyna_alloc_head_magic = 0xc1a7a110ca11ab1eULL;
static const uint64_t cyna_alloc_tail_magic = 0xe11d1eacca11a7c1ULL;

uint8_t cyna_string_eq(const char *lhs_ptr, int64_t lhs_len, const char *rhs_ptr, int64_t rhs_len);
uint8_t cyna_string_starts_with(const char *string_ptr, int64_t string_len, const char *prefix_ptr, int64_t prefix_len);
uint8_t cyna_string_ends_with(const char *string_ptr, int64_t string_len, const char *suffix_ptr, int64_t suffix_len);
uint8_t cyna_string_contains(const char *string_ptr, int64_t string_len, const char *needle_ptr, int64_t needle_len);
CynaOptionalI64 cyna_string_find(const char *string_ptr, int64_t string_len, const char *needle_ptr, int64_t needle_len);
CynaOptionalI64 cyna_string_rfind(const char *string_ptr, int64_t string_len, const char *needle_ptr, int64_t needle_len);
CynaString cyna_string_slice(CynaString value, int64_t start, int64_t end);
static CynaDense *cyna_dense_core_copy(void *list_ptr, const CynaTypeDesc *elem);
static void cyna_dense_core_drop(void *list_ptr, const CynaTypeDesc *elem);
static CynaTrackedAlloc *cyna_track_alloc_find(void *ptr, CynaTrackedAlloc **prev_out);
static void cyna_track_alloc_check_all(void);
static int cyna_runtime_leak_check_suppressed = 0;

static int cyna_runtime_memory_diagnostics_enabled(void) {
#ifdef CYNA_FREESTANDING
    return 1;
#else
    if (cyna_memory_diagnostics_enabled < 0) {
        const char *value = getenv("CYNA_LEAK_DIAGNOSTICS");
        cyna_memory_diagnostics_enabled = (value != NULL && value[0] != '\0' && value[0] != '0') ? 1 : 0;
    }
    return cyna_memory_diagnostics_enabled;
#endif
}

typedef struct {
    CynaString name;
    int32_t kind;
} CynaStdFsRawDirEntry;

static void cyna_abort(void) {
#ifdef CYNA_FREESTANDING
    for (;;) {
    }
#else
    abort();
#endif
}

void cyna_runtime_abort(void) {
    cyna_abort();
}

void cyna_runtime_language_fail(void) {
    cyna_runtime_leak_check_suppressed = 1;
#ifdef CYNA_FREESTANDING
    cyna_abort();
#else
    exit(101);
#endif
}

void cyna_assert_fail(void) {
#ifdef CYNA_FREESTANDING
    cyna_runtime_writer_write("cyna runtime check failed\n", 26);
#else
    fputs("cyna runtime check failed\n", stderr);
    fflush(stderr);
#endif
    cyna_runtime_language_fail();
}

void cyna_runtime_assertion_fail(void) {
#ifdef CYNA_FREESTANDING
    cyna_runtime_writer_write("cyna assertion failed\n", 22);
#else
    fputs("cyna assertion failed\n", stderr);
    fflush(stderr);
#endif
    cyna_runtime_language_fail();
}

void cyna_runtime_bounds_fail(int64_t index, int64_t length) {
#ifdef CYNA_FREESTANDING
    (void)index;
    (void)length;
    cyna_runtime_writer_write("cyna index out of bounds\n", 25);
#else
    fprintf(stderr, "cyna index out of bounds: index=%lld length=%lld\n", (long long)index, (long long)length);
    fflush(stderr);
#endif
    cyna_runtime_language_fail();
}

void cyna_runtime_capacity_fail(int64_t requested, int64_t capacity) {
#ifdef CYNA_FREESTANDING
    (void)requested;
    (void)capacity;
    cyna_runtime_writer_write("cyna capacity check failed\n", 27);
#else
    fprintf(stderr, "cyna capacity check failed: requested=%lld capacity=%lld\n", (long long)requested, (long long)capacity);
    fflush(stderr);
#endif
    cyna_runtime_language_fail();
}

static void cyna_runtime_default_writer_write(const char *ptr, int64_t len) {
    if (ptr == NULL && len != 0) cyna_abort();
    if (len < 0) cyna_abort();
    if (len == 0) return;
#ifdef CYNA_FREESTANDING
    (void)ptr;
    (void)len;
    return;
#else
    if (fwrite(ptr, 1, (size_t)len, stdout) != (size_t)len) cyna_abort();
    fflush(stdout);
#endif
}

static uint8_t cyna_root_allocator_is_installed(void) {
    return (cyna_root_allocator.alloc != NULL &&
        cyna_root_allocator.realloc != NULL &&
        cyna_root_allocator.free != NULL) ? 1 : 0;
}

static size_t cyna_align_up_size(size_t value, size_t alignment) {
    const size_t mask = alignment - 1u;
    return (value + mask) & ~mask;
}

static void *cyna_bump_alloc(void *ctx, size_t size) {
    CynaBumpAllocatorState *state = (CynaBumpAllocatorState *)ctx;
    if (state == NULL || state->cursor == NULL || state->end == NULL) return NULL;
    const size_t cursor_value = (size_t)(uintptr_t)state->cursor;
    const size_t aligned_value = cyna_align_up_size(cursor_value, sizeof(void *));
    unsigned char *aligned = (unsigned char *)(uintptr_t)aligned_value;
    if (aligned > state->end) return NULL;
    if (size > (size_t)(state->end - aligned)) return NULL;
    state->cursor = aligned + size;
    return aligned;
}

static void *cyna_bump_realloc(void *ctx, void *ptr, size_t size) {
    CynaTrackedAlloc *entry;
    unsigned char *bytes;
    void *new_ptr;
    size_t old_size;
    CynaBumpAllocatorState *state = (CynaBumpAllocatorState *)ctx;
    if (ptr == NULL) return cyna_bump_alloc(ctx, size);
    if (state == NULL || state->cursor == NULL || state->end == NULL) return NULL;
    entry = cyna_track_alloc_find(ptr, NULL);
    if (entry == NULL) return NULL;
    old_size = entry->size;
    if (size <= old_size) return ptr;
    bytes = (unsigned char *)ptr;
    if (bytes + old_size == state->cursor) {
        if (size > (size_t)(state->end - bytes)) return NULL;
        state->cursor = bytes + size;
        return ptr;
    }
    new_ptr = cyna_bump_alloc(ctx, size);
    if (new_ptr == NULL) return NULL;
    memcpy(new_ptr, ptr, old_size);
    return new_ptr;
}

static void cyna_bump_free(void *ctx, void *ptr) {
    (void)ctx;
    (void)ptr;
}

static void *cyna_root_alloc(size_t size) {
    if (!cyna_root_allocator_is_installed()) cyna_abort();
    return cyna_root_allocator.alloc(cyna_root_allocator.ctx, size);
}

static void *cyna_root_realloc(void *ptr, size_t size) {
    if (!cyna_root_allocator_is_installed()) cyna_abort();
    return cyna_root_allocator.realloc(cyna_root_allocator.ctx, ptr, size);
}

static void cyna_root_free(void *ptr) {
    if (!cyna_root_allocator_is_installed()) cyna_abort();
    cyna_root_allocator.free(cyna_root_allocator.ctx, ptr);
}

void cyna_runtime_install_root_allocator(CynaAllocator allocator) {
    if (allocator.alloc == NULL || allocator.realloc == NULL || allocator.free == NULL) cyna_abort();
    cyna_root_allocator = allocator;
}

void cyna_runtime_init_bump_root_allocator(void *start, size_t size) {
    unsigned char *bytes = (unsigned char *)start;
    if (bytes == NULL && size != 0) cyna_abort();
    cyna_bump_allocator_state.start = bytes;
    cyna_bump_allocator_state.cursor = bytes;
    cyna_bump_allocator_state.end = bytes + size;
    cyna_runtime_install_root_allocator((CynaAllocator){
        .ctx = &cyna_bump_allocator_state,
        .alloc = cyna_bump_alloc,
        .realloc = cyna_bump_realloc,
        .free = cyna_bump_free,
    });
}

void cyna_runtime_clear_root_allocator(void) {
    cyna_root_allocator.ctx = NULL;
    cyna_root_allocator.alloc = NULL;
    cyna_root_allocator.realloc = NULL;
    cyna_root_allocator.free = NULL;
    cyna_bump_allocator_state.start = NULL;
    cyna_bump_allocator_state.cursor = NULL;
    cyna_bump_allocator_state.end = NULL;
}

uint8_t cyna_runtime_has_root_allocator(void) {
    return cyna_root_allocator_is_installed();
}

void cyna_std_io_install_writer(CynaWriterWriteFn write_fn, void *ctx) {
    cyna_writer_write = write_fn;
    cyna_writer_ctx = ctx;
}

void cyna_std_io_clear_writer(void) {
    cyna_writer_write = NULL;
    cyna_writer_ctx = NULL;
}

void cyna_runtime_writer_write(const char *ptr, int64_t len) {
    if (ptr == NULL && len != 0) cyna_abort();
    if (len < 0) cyna_abort();
    if (len == 0) return;
    if (cyna_writer_write != NULL) {
        cyna_writer_write(ptr, len, cyna_writer_ctx);
        return;
    }
    cyna_runtime_default_writer_write(ptr, len);
}

static size_t cyna_tracked_raw_size(size_t size) {
    if (size > ((size_t)-1) - sizeof(CynaAllocHeader) - sizeof(uint64_t)) cyna_abort();
    return sizeof(CynaAllocHeader) + size + sizeof(uint64_t);
}

static void cyna_alloc_write_guards(void *raw_ptr, size_t size) {
    CynaAllocHeader *header = (CynaAllocHeader *)raw_ptr;
    unsigned char *user = ((unsigned char *)raw_ptr) + sizeof(CynaAllocHeader);
    header->magic = cyna_alloc_head_magic;
    header->size = size;
    memcpy(user + size, &cyna_alloc_tail_magic, sizeof(cyna_alloc_tail_magic));
}

static void *cyna_alloc_user_ptr(void *raw_ptr) {
    return ((unsigned char *)raw_ptr) + sizeof(CynaAllocHeader);
}

static int cyna_alloc_guards_ok(const CynaTrackedAlloc *entry) {
    if (entry == NULL || entry->raw_ptr == NULL || entry->ptr == NULL) return 0;
    const CynaAllocHeader *header = (const CynaAllocHeader *)entry->raw_ptr;
    const unsigned char *user = ((const unsigned char *)entry->raw_ptr) + sizeof(CynaAllocHeader);
    uint64_t tail = 0;
    memcpy(&tail, user + entry->size, sizeof(tail));
    return header->magic == cyna_alloc_head_magic &&
        header->size == entry->size &&
        tail == cyna_alloc_tail_magic &&
        entry->ptr == user;
}

static void cyna_record_freed_alloc(const CynaTrackedAlloc *entry, void *free_caller) {
    if (entry == NULL) return;
    CynaFreedAlloc *slot = &cyna_freed_allocs[cyna_freed_alloc_next % (sizeof(cyna_freed_allocs) / sizeof(cyna_freed_allocs[0]))];
    slot->ptr = entry->ptr;
    slot->size = entry->size;
    slot->site_file = entry->site_file;
    slot->site_line = entry->site_line;
    slot->site_kind = entry->site_kind;
    slot->alloc_caller = entry->caller;
    slot->free_caller = free_caller;
    cyna_freed_alloc_next += 1;
}

static const CynaFreedAlloc *cyna_find_recent_freed_alloc(void *ptr) {
    size_t count = cyna_freed_alloc_next;
    const size_t cap = sizeof(cyna_freed_allocs) / sizeof(cyna_freed_allocs[0]);
    if (count > cap) count = cap;
    for (size_t i = 0; i < count; i += 1) {
        const size_t index = (cyna_freed_alloc_next - 1 - i) % cap;
        const CynaFreedAlloc *freed = &cyna_freed_allocs[index];
        if (freed->ptr == ptr) return freed;
    }
    return NULL;
}

#ifndef CYNA_FREESTANDING
static void cyna_report_symbol(const char *label, void *addr) {
#ifndef _WIN32
    Dl_info info;
    if (addr != NULL && dladdr(addr, &info) != 0 && info.dli_sname != NULL) {
        fprintf(stderr, "  %s=%p <%s+%td>\n",
            label,
            addr,
            info.dli_sname,
            (ptrdiff_t)((const char *)addr - (const char *)info.dli_saddr));
        return;
    }
#endif
    fprintf(stderr, "  %s=%p\n", label, addr);
}
#endif

__attribute__((noinline))
void cyna_report_guard_failure(const CynaTrackedAlloc *entry) {
#ifdef CYNA_FREESTANDING
    (void)entry;
#else
    fprintf(stderr, "cyna runtime allocation guard check failed\n");
    if (entry != NULL) {
        uint64_t head = 0;
        size_t header_size = 0;
        uint64_t tail = 0;
        const unsigned char *user = NULL;
        if (entry->raw_ptr != NULL) {
            const CynaAllocHeader *header = (const CynaAllocHeader *)entry->raw_ptr;
            user = ((const unsigned char *)entry->raw_ptr) + sizeof(CynaAllocHeader);
            head = header->magic;
            header_size = header->size;
            memcpy(&tail, user + entry->size, sizeof(tail));
        }
        fprintf(stderr, "  ptr=%p size=%zu kind=%s site=%s:%lld caller=%p\n",
            entry->ptr,
            entry->size,
            entry->site_kind == NULL ? "<unknown>" : entry->site_kind,
            entry->site_file == NULL ? "<unknown>" : entry->site_file,
            (long long)entry->site_line,
            entry->caller);
        fprintf(stderr, "  raw=%p expected_user=%p header_magic=0x%016llx expected=0x%016llx header_size=%zu tail_magic=0x%016llx expected=0x%016llx\n",
            entry->raw_ptr,
            user,
            (unsigned long long)head,
            (unsigned long long)cyna_alloc_head_magic,
            header_size,
            (unsigned long long)tail,
            (unsigned long long)cyna_alloc_tail_magic);
        cyna_report_symbol("alloc_caller", entry->caller);
    }
    fflush(stderr);
#endif
}

__attribute__((noinline))
void cyna_report_untracked_free(void *ptr) {
#ifdef CYNA_FREESTANDING
    (void)ptr;
#else
    fprintf(stderr, "cyna runtime untracked free\n");
    fprintf(stderr, "  ptr=%p\n", ptr);
    const CynaFreedAlloc *freed = cyna_find_recent_freed_alloc(ptr);
    if (freed != NULL) {
        fprintf(stderr, "  recently_freed size=%zu kind=%s site=%s:%lld alloc_caller=%p free_caller=%p\n",
            freed->size,
            freed->site_kind == NULL ? "<unknown>" : freed->site_kind,
            freed->site_file == NULL ? "<unknown>" : freed->site_file,
            (long long)freed->site_line,
            freed->alloc_caller,
            freed->free_caller);
        cyna_report_symbol("recent_alloc_caller", freed->alloc_caller);
        cyna_report_symbol("recent_free_caller", freed->free_caller);
    }
    fflush(stderr);
#endif
}

static void cyna_track_alloc_check_all(void) {
    CynaTrackedAlloc *entry = cyna_tracked_allocs;
    while (entry != NULL) {
        if (!cyna_alloc_guards_ok(entry)) {
            cyna_report_guard_failure(entry);
            cyna_abort();
        }
        entry = entry->next;
    }
}

static void cyna_track_alloc_add(void *ptr, void *raw_ptr, size_t size, const char *site_file, int64_t site_line, const char *site_kind, void *caller) {
    if (ptr == NULL) return;
    CynaTrackedAlloc *entry = (CynaTrackedAlloc *)cyna_root_alloc(sizeof(CynaTrackedAlloc));
    if (entry == NULL) cyna_abort();
    entry->ptr = ptr;
    entry->raw_ptr = raw_ptr;
    entry->size = size;
    entry->site_file = site_file;
    entry->site_line = site_line;
    entry->site_kind = site_kind;
    entry->caller = caller;
    entry->next = cyna_tracked_allocs;
    cyna_tracked_allocs = entry;
    cyna_tracked_alloc_count += 1;
    cyna_tracked_alloc_bytes += size;
}

static CynaTrackedAlloc *cyna_track_alloc_find(void *ptr, CynaTrackedAlloc **prev_out) {
    CynaTrackedAlloc *prev = NULL;
    CynaTrackedAlloc *current = cyna_tracked_allocs;
    while (current != NULL) {
        if (current->ptr == ptr) {
            if (prev_out != NULL) *prev_out = prev;
            return current;
        }
        prev = current;
        current = current->next;
    }
    return NULL;
}

static void cyna_track_alloc_remove(void *ptr) {
    if (ptr == NULL) return;
    CynaTrackedAlloc *prev = NULL;
    CynaTrackedAlloc *entry = cyna_track_alloc_find(ptr, &prev);
    if (entry == NULL) cyna_abort();
    if (!cyna_alloc_guards_ok(entry)) {
        cyna_report_guard_failure(entry);
        cyna_abort();
    }
    if (prev == NULL) {
        cyna_tracked_allocs = entry->next;
    } else {
        prev->next = entry->next;
    }
    cyna_tracked_alloc_count -= 1;
    cyna_tracked_alloc_bytes -= entry->size;
    cyna_root_free(entry);
}

static void *cyna_try_malloc_site(size_t size, const char *site_file, int64_t site_line, const char *site_kind, void *caller) {
    if (!cyna_root_allocator_is_installed()) return NULL;
    if (!cyna_runtime_memory_diagnostics_enabled()) return cyna_root_alloc(size);
    void *raw_ptr = cyna_root_alloc(cyna_tracked_raw_size(size));
    if (raw_ptr == NULL) return NULL;
    CynaTrackedAlloc *entry = (CynaTrackedAlloc *)cyna_root_alloc(sizeof(CynaTrackedAlloc));
    if (entry == NULL) {
        cyna_root_free(raw_ptr);
        return NULL;
    }
    cyna_alloc_write_guards(raw_ptr, size);
    void *ptr = cyna_alloc_user_ptr(raw_ptr);
    entry->ptr = ptr;
    entry->raw_ptr = raw_ptr;
    entry->size = size;
    entry->site_file = site_file;
    entry->site_line = site_line;
    entry->site_kind = site_kind;
    entry->caller = caller;
    entry->next = cyna_tracked_allocs;
    cyna_tracked_allocs = entry;
    cyna_tracked_alloc_count += 1;
    cyna_tracked_alloc_bytes += size;
    return ptr;
}

static void *cyna_xmalloc_site(size_t size, const char *site_file, int64_t site_line, const char *site_kind, void *caller) {
    if (!cyna_runtime_memory_diagnostics_enabled()) {
        (void)site_file;
        (void)site_line;
        (void)site_kind;
        (void)caller;
        void *ptr = cyna_root_alloc(size);
        if (ptr == NULL) cyna_abort();
        return ptr;
    }
    void *raw_ptr = cyna_root_alloc(cyna_tracked_raw_size(size));
    if (raw_ptr == NULL) cyna_abort();
    cyna_alloc_write_guards(raw_ptr, size);
    void *ptr = cyna_alloc_user_ptr(raw_ptr);
    cyna_track_alloc_add(ptr, raw_ptr, size, site_file, site_line, site_kind, caller);
    return ptr;
}

static void *cyna_xrealloc_site(void *ptr, size_t size, const char *site_file, int64_t site_line, const char *site_kind, void *caller) {
    if (ptr == NULL) return cyna_xmalloc_site(size, site_file, site_line, site_kind, caller);
    if (!cyna_runtime_memory_diagnostics_enabled()) {
        (void)site_file;
        (void)site_line;
        (void)site_kind;
        (void)caller;
        void *out = cyna_root_realloc(ptr, size);
        if (out == NULL) cyna_abort();
        return out;
    }
    CynaTrackedAlloc *entry = cyna_track_alloc_find(ptr, NULL);
    if (entry == NULL) cyna_abort();
    if (!cyna_alloc_guards_ok(entry)) {
        cyna_report_guard_failure(entry);
        cyna_abort();
    }
    void *out_raw = cyna_root_realloc(entry->raw_ptr, cyna_tracked_raw_size(size));
    if (out_raw == NULL) cyna_abort();
    cyna_tracked_alloc_bytes -= entry->size;
    cyna_alloc_write_guards(out_raw, size);
    void *out = cyna_alloc_user_ptr(out_raw);
    entry->raw_ptr = out_raw;
    entry->ptr = out;
    entry->size = size;
    entry->site_file = site_file;
    entry->site_line = site_line;
    entry->site_kind = site_kind;
    entry->caller = caller;
    cyna_tracked_alloc_bytes += size;
    return out;
}

static void cyna_xfree(void *ptr) {
    if (ptr == NULL) return;
    if (!cyna_runtime_memory_diagnostics_enabled()) {
        cyna_root_free(ptr);
        return;
    }
    CynaTrackedAlloc *entry = cyna_track_alloc_find(ptr, NULL);
    if (entry == NULL) {
        cyna_report_untracked_free(ptr);
        cyna_abort();
    }
    void *raw_ptr = entry->raw_ptr;
    cyna_record_freed_alloc(entry, __builtin_return_address(0));
    cyna_track_alloc_remove(ptr);
    cyna_root_free(raw_ptr);
}

void *cyna_runtime_tracked_alloc(size_t size) {
    return cyna_xmalloc_site(size, "<unknown>", 0, "runtime.alloc", __builtin_return_address(0));
}

void *cyna_runtime_tracked_realloc(void *ptr, size_t size) {
    return cyna_xrealloc_site(ptr, size, "<unknown>", 0, "runtime.realloc", __builtin_return_address(0));
}

void *cyna_runtime_tracked_alloc_site(size_t size, const char *site_file, int64_t site_line, const char *site_kind) {
    return cyna_xmalloc_site(size, site_file, site_line, site_kind, __builtin_return_address(0));
}

void *cyna_runtime_tracked_realloc_site(void *ptr, size_t size, const char *site_file, int64_t site_line, const char *site_kind) {
    return cyna_xrealloc_site(ptr, size, site_file, site_line, site_kind, __builtin_return_address(0));
}

void cyna_runtime_tracked_free(void *ptr) {
    cyna_xfree(ptr);
}

int64_t cyna_runtime_live_allocation_count(void) {
    if (!cyna_runtime_memory_diagnostics_enabled()) return 0;
    return cyna_tracked_alloc_count;
}

#ifndef CYNA_FREESTANDING
static int cyna_leak_site_matches(const CynaLeakSummary *summary, const CynaTrackedAlloc *entry) {
    return summary->size == entry->size &&
        summary->site_line == entry->site_line &&
        summary->site_file == entry->site_file &&
        summary->site_kind == entry->site_kind &&
        summary->caller == entry->caller;
}

static void cyna_leak_summary_add(CynaLeakSummary *summaries, size_t *summary_count, size_t summary_cap, const CynaTrackedAlloc *entry) {
    size_t i;
    for (i = 0; i < *summary_count; i += 1) {
        if (cyna_leak_site_matches(&summaries[i], entry)) {
            summaries[i].count += 1;
            summaries[i].bytes += entry->size;
            return;
        }
    }
    if (*summary_count >= summary_cap) return;
    summaries[*summary_count] = (CynaLeakSummary){
        .site_file = entry->site_file,
        .site_line = entry->site_line,
        .site_kind = entry->site_kind,
        .caller = entry->caller,
        .size = entry->size,
        .count = 1,
        .bytes = entry->size,
        .sample_ptr = entry->ptr,
    };
    *summary_count += 1;
}

static void cyna_leak_summaries_sort(CynaLeakSummary *summaries, size_t summary_count) {
    size_t i;
    for (i = 1; i < summary_count; i += 1) {
        CynaLeakSummary item = summaries[i];
        size_t j = i;
        while (j > 0 && summaries[j - 1].bytes < item.bytes) {
            summaries[j] = summaries[j - 1];
            j -= 1;
        }
        summaries[j] = item;
    }
}
#endif

void cyna_runtime_assert_no_leaks(void) {
    if (cyna_runtime_leak_check_suppressed) return;
    if (!cyna_runtime_memory_diagnostics_enabled()) return;
    cyna_track_alloc_check_all();
    if (cyna_tracked_alloc_count == 0) return;
#ifdef CYNA_FREESTANDING
    cyna_runtime_writer_write("cyna runtime leak check failed\n", 31);
#else
    fprintf(stderr, "cyna runtime leak check failed: %lld live allocation(s), %zu live byte(s)\n",
        (long long)cyna_tracked_alloc_count, cyna_tracked_alloc_bytes);
    CynaLeakSummary summaries[64];
    size_t summary_count = 0;
    size_t printed = 0;
    for (CynaTrackedAlloc *entry = cyna_tracked_allocs; entry != NULL; entry = entry->next) {
        cyna_leak_summary_add(summaries, &summary_count, 64, entry);
    }
    cyna_leak_summaries_sort(summaries, summary_count);
    fprintf(stderr, "  leak groups by allocation site:\n");
    for (size_t i = 0; i < summary_count; i += 1) {
        fprintf(stderr, "    count=%lld bytes=%zu size=%zu kind=%s site=%s:%lld caller=%p sample=%p\n",
            (long long)summaries[i].count,
            summaries[i].bytes,
            summaries[i].size,
            summaries[i].site_kind == NULL ? "<unknown>" : summaries[i].site_kind,
            summaries[i].site_file == NULL ? "<unknown>" : summaries[i].site_file,
            (long long)summaries[i].site_line,
            summaries[i].caller,
            summaries[i].sample_ptr);
    }
    if (summary_count == 64) {
        fprintf(stderr, "    ... additional leak groups omitted ...\n");
    }
    fprintf(stderr, "  leaked allocation samples:\n");
    for (CynaTrackedAlloc *entry = cyna_tracked_allocs; entry != NULL; entry = entry->next) {
        if (printed >= 32) {
            fprintf(stderr, "    ... additional leaked allocations omitted ...\n");
            break;
        }
        fprintf(stderr, "    ptr=%p size=%zu kind=%s site=%s:%lld caller=%p\n",
            entry->ptr,
            entry->size,
            entry->site_kind == NULL ? "<unknown>" : entry->site_kind,
            entry->site_file == NULL ? "<unknown>" : entry->site_file,
            (long long)entry->site_line,
            entry->caller);
        printed += 1;
    }
    fflush(stderr);
#endif
    cyna_abort();
}

static void cyna_copy_i64(void *dst, const void *src, const CynaTypeDesc *desc) {
    (void)desc;
    memcpy(dst, src, sizeof(int64_t));
}

static void cyna_copy_f32(void *dst, const void *src, const CynaTypeDesc *desc) {
    (void)desc;
    memcpy(dst, src, sizeof(float));
}

static void cyna_copy_f64(void *dst, const void *src, const CynaTypeDesc *desc) {
    (void)desc;
    memcpy(dst, src, sizeof(double));
}

static void cyna_drop_noop(void *value, const CynaTypeDesc *desc) {
    (void)value;
    (void)desc;
}

static uint8_t cyna_eq_i64(const void *lhs, const void *rhs, const CynaTypeDesc *desc) {
    (void)desc;
    return (*(const int64_t *)lhs == *(const int64_t *)rhs) ? 1 : 0;
}

static uint8_t cyna_eq_f32(const void *lhs, const void *rhs, const CynaTypeDesc *desc) {
    (void)desc;
    return (*(const float *)lhs == *(const float *)rhs) ? 1 : 0;
}

static uint8_t cyna_eq_f64(const void *lhs, const void *rhs, const CynaTypeDesc *desc) {
    (void)desc;
    return (*(const double *)lhs == *(const double *)rhs) ? 1 : 0;
}

static uint64_t cyna_hash_i64(const void *value, const CynaTypeDesc *desc) {
    (void)desc;
    uint64_t v = (uint64_t)*(const int64_t *)value;
    v ^= v >> 33;
    v *= 0xff51afd7ed558ccdULL;
    v ^= v >> 33;
    v *= 0xc4ceb9fe1a85ec53ULL;
    v ^= v >> 33;
    return v;
}

static void cyna_copy_bool(void *dst, const void *src, const CynaTypeDesc *desc) {
    (void)desc;
    memcpy(dst, src, 1);
}

static uint8_t cyna_eq_bool(const void *lhs, const void *rhs, const CynaTypeDesc *desc) {
    (void)desc;
    return (*(const uint8_t *)lhs == *(const uint8_t *)rhs) ? 1 : 0;
}

static uint64_t cyna_hash_bool(const void *value, const CynaTypeDesc *desc) {
    (void)desc;
    return *(const uint8_t *)value ? 1u : 0u;
}

static void cyna_copy_u8(void *dst, const void *src, const CynaTypeDesc *desc) {
    (void)desc;
    memcpy(dst, src, 1);
}

static uint8_t cyna_eq_u8(const void *lhs, const void *rhs, const CynaTypeDesc *desc) {
    (void)desc;
    return (*(const uint8_t *)lhs == *(const uint8_t *)rhs) ? 1 : 0;
}

static uint64_t cyna_hash_u8(const void *value, const CynaTypeDesc *desc) {
    (void)desc;
    return (uint64_t)*(const uint8_t *)value;
}

static void cyna_copy_i32(void *dst, const void *src, const CynaTypeDesc *desc) {
    (void)desc;
    memcpy(dst, src, sizeof(int32_t));
}

static uint8_t cyna_eq_i32(const void *lhs, const void *rhs, const CynaTypeDesc *desc) {
    (void)desc;
    return (*(const int32_t *)lhs == *(const int32_t *)rhs) ? 1 : 0;
}

static uint64_t cyna_hash_i32(const void *value, const CynaTypeDesc *desc) {
    (void)desc;
    uint64_t v = (uint32_t)*(const int32_t *)value;
    v ^= v >> 16;
    v *= 0x7feb352dU;
    v ^= v >> 15;
    v *= 0x846ca68bU;
    v ^= v >> 16;
    return v;
}

static uint64_t cyna_hash_f32(const void *value, const CynaTypeDesc *desc) {
    (void)desc;
    uint32_t bits;
    memcpy(&bits, value, sizeof(bits));
    uint64_t v = bits;
    v ^= v >> 16;
    v *= 0x7feb352dU;
    v ^= v >> 15;
    return v;
}

static uint64_t cyna_hash_f64(const void *value, const CynaTypeDesc *desc) {
    (void)desc;
    uint64_t bits;
    memcpy(&bits, value, sizeof(bits));
    bits ^= bits >> 33;
    bits *= 0xff51afd7ed558ccdULL;
    bits ^= bits >> 33;
    return bits;
}

static CynaString cyna_copy_string_value(CynaString value) {
    if (!cyna_string_is_owned(value)) return value;
    CynaStringShared *shared = cyna_string_shared_from_ptr(value.ptr);
    cyna_string_shared_retain(shared);
    return value;
}

static void cyna_drop_string_value(CynaString value) {
    if (!cyna_string_is_owned(value)) return;
    CynaStringShared *shared = cyna_string_shared_from_ptr(value.ptr);
    if (cyna_string_shared_release(shared)) cyna_xfree(shared);
}

static void cyna_copy_string(void *dst, const void *src, const CynaTypeDesc *desc) {
    (void)desc;
    *(CynaString *)dst = cyna_copy_string_value(*(const CynaString *)src);
}

static void cyna_drop_string(void *value, const CynaTypeDesc *desc) {
    (void)desc;
    cyna_drop_string_value(*(const CynaString *)value);
}

static uint8_t cyna_eq_string_desc(const void *lhs, const void *rhs, const CynaTypeDesc *desc) {
    (void)desc;
    const CynaString *a = (const CynaString *)lhs;
    const CynaString *b = (const CynaString *)rhs;
    return cyna_string_eq(a->ptr, a->len, b->ptr, b->len);
}

static uint64_t cyna_hash_string(const void *value, const CynaTypeDesc *desc) {
    (void)desc;
    const CynaString *s = (const CynaString *)value;
    uint64_t hash = 1469598103934665603ULL;
    const int64_t len = cyna_string_logical_len(*s);
    for (int64_t i = 0; i < len; i += 1) {
        hash ^= (uint8_t)s->ptr[i];
        hash *= 1099511628211ULL;
    }
    return hash;
}

const CynaTypeDesc cyna_desc_u8 = {
    1, 1, 0, cyna_copy_u8, cyna_drop_noop, cyna_eq_u8, cyna_hash_u8, NULL
};

const CynaTypeDesc cyna_desc_i32 = {
    sizeof(int32_t), sizeof(int32_t), 0, cyna_copy_i32, cyna_drop_noop, cyna_eq_i32, cyna_hash_i32, NULL
};

const CynaTypeDesc cyna_desc_i64 = {
    sizeof(int64_t), sizeof(int64_t), 0, cyna_copy_i64, cyna_drop_noop, cyna_eq_i64, cyna_hash_i64, NULL
};

const CynaTypeDesc cyna_desc_f32 = {
    sizeof(float), sizeof(float), 0, cyna_copy_f32, cyna_drop_noop, cyna_eq_f32, cyna_hash_f32, NULL
};

const CynaTypeDesc cyna_desc_f64 = {
    sizeof(double), sizeof(double), 0, cyna_copy_f64, cyna_drop_noop, cyna_eq_f64, cyna_hash_f64, NULL
};

const CynaTypeDesc cyna_desc_bool = {
    1, 1, 0, cyna_copy_bool, cyna_drop_noop, cyna_eq_bool, cyna_hash_bool, NULL
};

const CynaTypeDesc cyna_desc_string = {
    sizeof(CynaString), sizeof(void *), 0, cyna_copy_string, cyna_drop_string, cyna_eq_string_desc, cyna_hash_string, NULL
};

static void cyna_reserve_bytes(unsigned char **data, int64_t *cap, int64_t want, int64_t elem_size) {
    if (*cap >= want) return;
    int64_t next = *cap == 0 ? 4 : *cap;
    while (next < want) next *= 2;
    *data = (unsigned char *)cyna_xrealloc_site(*data, (size_t)(next * elem_size), __FILE__, __LINE__, "runtime.dense.grow", __builtin_return_address(0));
    *cap = next;
}

CynaString cyna_runtime_string_new_uninit(int64_t len) {
    if (len < 0) cyna_abort();
    CynaStringShared *shared = (CynaStringShared *)cyna_xmalloc_site(sizeof(CynaStringShared) + (size_t)len, __FILE__, __LINE__, "runtime.string", __builtin_return_address(0));
    cyna_string_shared_ref_init(shared);
    shared->len = len;
    return cyna_string_make_owned(shared->bytes, len);
}

void cyna_trace_message_abi(CynaString *out, CynaTraceContext *context, const CynaTraceHandle *handle) {
    *out = (CynaString){ .ptr = "", .len = 0 };
#if CYNA_TRACE_MESSAGE_BYTES > 0
    if (context == NULL || handle == NULL) return;
    CynaStringShared *shared = (CynaStringShared *)cyna_try_malloc_site(
        sizeof(CynaStringShared) + CYNA_TRACE_MESSAGE_BYTES,
        __FILE__, __LINE__, "runtime.trace.message", __builtin_return_address(0));
    if (shared == NULL) return;
    const size_t length = cyna_trace_copy_message_abi(context, handle,
        (unsigned char *)shared->bytes, CYNA_TRACE_MESSAGE_BYTES);
    if (length == 0) {
        cyna_xfree(shared);
        return;
    }
    cyna_string_shared_ref_init(shared);
    shared->len = (int64_t)length;
    *out = cyna_string_make_owned(shared->bytes, (int64_t)length);
#else
    (void)context;
    (void)handle;
#endif
}

CynaString cyna_string_from_bytes(CynaBytes bytes) {
    if (bytes.len < 0) cyna_abort();
    CynaString out = cyna_runtime_string_new_uninit(bytes.len);
    if (bytes.len != 0) memcpy((char *)out.ptr, bytes.ptr, (size_t)bytes.len);
    return out;
}

void cyna_string_from_bytes_into(CynaString *dst, const CynaBytes *bytes) {
    *dst = cyna_string_from_bytes(*bytes);
}

CynaDense *cyna_dense_from_owned_parts(const CynaTypeDesc *elem_desc, unsigned char *data, int64_t len, int64_t cap) {
    CynaDense *dense = (CynaDense *)cyna_runtime_tracked_alloc_site(sizeof(CynaDense), __FILE__, __LINE__, "runtime.dense.owned");
    if (dense == NULL) return NULL;
    if (elem_desc == NULL) cyna_abort();
    if (len < 0 || cap < len) cyna_abort();
    if (cap == 0 && data != NULL) cyna_abort();
    if (cap != 0 && data == NULL) cyna_abort();
    dense->elem_desc = elem_desc;
    dense->len = len;
    dense->cap = cap;
    dense->data = data;
    return dense;
}

CynaString cyna_string_copy(CynaString value) {
    const int64_t len = cyna_string_logical_len(value);
    CynaString out = cyna_runtime_string_new_uninit(len);
    if (len != 0) memcpy((char *)out.ptr, value.ptr, (size_t)len);
    return out;
}

CynaString cyna_string_share(CynaString value) {
    return cyna_copy_string_value(value);
}

void cyna_string_share_into(CynaString *dst, const CynaString *src) {
    *dst = cyna_copy_string_value(*src);
}

void cyna_string_release(CynaString value) {
    cyna_drop_string_value(value);
}

void cyna_string_release_at(const CynaString *value) {
    cyna_drop_string_value(*value);
}

static void cyna_fmt_copy(char *dst, const char *src, int64_t len) {
    for (int64_t i = 0; i < len; i += 1) {
        dst[i] = src[i];
    }
}

static CynaString cyna_fmt_append_bytes(CynaString acc, const char *ptr, int64_t len) {
    const int64_t acc_len = cyna_string_logical_len(acc);
    CynaString out = cyna_runtime_string_new_uninit(acc_len + len);
    cyna_fmt_copy((char *)out.ptr, acc.ptr, acc_len);
    cyna_fmt_copy((char *)out.ptr + acc_len, ptr, len);
    cyna_string_release(acc);
    return out;
}

static int64_t cyna_fmt_write_unsigned(char *buf, uint64_t value, uint32_t base, _Bool upper) {
    char tmp[65];
    int index = (int)sizeof(tmp);
    do {
        const uint64_t digit = value % (uint64_t)base;
        tmp[index - 1] = (char)(digit < 10u ? ('0' + digit) : ((upper ? 'A' : 'a') + (digit - 10u)));
        value /= (uint64_t)base;
        index -= 1;
    } while (value != 0);
    const int64_t len = (int64_t)(sizeof(tmp) - (size_t)index);
    cyna_fmt_copy(buf, tmp + index, len);
    return len;
}

static int64_t cyna_fmt_write_signed(char *buf, int64_t value) {
    uint64_t magnitude;
    if (value < 0) {
        buf[0] = '-';
        magnitude = (uint64_t)(-(value + 1)) + 1u;
        return 1 + cyna_fmt_write_unsigned(buf + 1, magnitude, 10u, 0);
    }
    magnitude = (uint64_t)value;
    return cyna_fmt_write_unsigned(buf, magnitude, 10u, 0);
}

CynaString cyna_runtime_fmt_empty(void) {
    return cyna_runtime_string_new_uninit(0);
}

CynaString cyna_runtime_fmt_append_string(CynaString acc, CynaString value) {
    return cyna_fmt_append_bytes(acc, value.ptr, cyna_string_logical_len(value));
}

CynaString cyna_runtime_fmt_append_int(CynaString acc, int64_t value, int32_t is_signed, int32_t format) {
    char buf[66];
    int64_t len;
    if (format == 0 && is_signed) {
        len = cyna_fmt_write_signed(buf, value);
    } else {
        const uint32_t base = format == 1 ? 2u : (format == 2 ? 8u : (format == 3 || format == 4 ? 16u : 10u));
        len = cyna_fmt_write_unsigned(buf, (uint64_t)value, base, format == 4);
    }
    return cyna_fmt_append_bytes(acc, buf, len);
}

void cyna_runtime_fmt_empty_into(CynaString *dst) {
    *dst = cyna_runtime_fmt_empty();
}

void cyna_runtime_fmt_append_string_into(CynaString *dst, const CynaString *acc, const CynaString *value) {
    *dst = cyna_runtime_fmt_append_string(*acc, *value);
}

void cyna_runtime_fmt_append_int_into(CynaString *dst, const CynaString *acc, int64_t value, int32_t is_signed, int32_t format) {
    *dst = cyna_runtime_fmt_append_int(*acc, value, is_signed, format);
}

uint8_t cyna_string_eq(const char *lhs_ptr, int64_t lhs_len, const char *rhs_ptr, int64_t rhs_len) {
    lhs_len = (int64_t)(((uint64_t)lhs_len) & ~cyna_string_owned_bit_u64());
    rhs_len = (int64_t)(((uint64_t)rhs_len) & ~cyna_string_owned_bit_u64());
    if (lhs_len != rhs_len) return 0;
    if (lhs_len == 0) return 1;
    return memcmp(lhs_ptr, rhs_ptr, (size_t)lhs_len) == 0 ? 1 : 0;
}

uint8_t cyna_sequence_eq(const void *lhs_ptr, int64_t lhs_len, const void *rhs_ptr, int64_t rhs_len, const CynaTypeDesc *elem_desc) {
    if (lhs_len != rhs_len) return 0;
    if (lhs_len < 0) cyna_abort();
    if (lhs_len == 0) return 1;
    if (lhs_ptr == NULL || rhs_ptr == NULL || elem_desc == NULL || elem_desc->eq == NULL) cyna_abort();
    const unsigned char *lhs = (const unsigned char *)lhs_ptr;
    const unsigned char *rhs = (const unsigned char *)rhs_ptr;
    for (int64_t i = 0; i < lhs_len; i += 1) {
        const void *lhs_elem = lhs + (i * elem_desc->size);
        const void *rhs_elem = rhs + (i * elem_desc->size);
        if (!elem_desc->eq(lhs_elem, rhs_elem, elem_desc)) return 0;
    }
    return 1;
}

uint8_t cyna_sparse_eq(const void *lhs_data, const unsigned char *lhs_occupied, int64_t lhs_len, int64_t lhs_cap, const void *rhs_data, const unsigned char *rhs_occupied, int64_t rhs_len, int64_t rhs_cap, const CynaTypeDesc *elem_desc) {
    if (lhs_len != rhs_len) return 0;
    if (lhs_len < 0 || lhs_cap < lhs_len) cyna_abort();
    if (rhs_len < 0 || rhs_cap < rhs_len) cyna_abort();
    const int64_t max_cap = lhs_cap > rhs_cap ? lhs_cap : rhs_cap;
    if (max_cap == 0) return 1;
    if (elem_desc == NULL || elem_desc->eq == NULL) cyna_abort();
    if ((lhs_cap != 0 && (lhs_data == NULL || lhs_occupied == NULL)) || (rhs_cap != 0 && (rhs_data == NULL || rhs_occupied == NULL))) cyna_abort();
    const unsigned char *lhs = (const unsigned char *)lhs_data;
    const unsigned char *rhs = (const unsigned char *)rhs_data;
    for (int64_t i = 0; i < max_cap; i += 1) {
        const uint8_t lhs_present = (i < lhs_cap && lhs_occupied[i] != 0);
        const uint8_t rhs_present = (i < rhs_cap && rhs_occupied[i] != 0);
        if (lhs_present != rhs_present) return 0;
        if (!lhs_present) continue;
        const void *lhs_elem = lhs + (i * elem_desc->size);
        const void *rhs_elem = rhs + (i * elem_desc->size);
        if (!elem_desc->eq(lhs_elem, rhs_elem, elem_desc)) return 0;
    }
    return 1;
}

uint8_t cyna_string_starts_with(const char *string_ptr, int64_t string_len, const char *prefix_ptr, int64_t prefix_len) {
    string_len = (int64_t)(((uint64_t)string_len) & ~cyna_string_owned_bit_u64());
    prefix_len = (int64_t)(((uint64_t)prefix_len) & ~cyna_string_owned_bit_u64());
    if (prefix_len > string_len) return 0;
    if (prefix_len == 0) return 1;
    return memcmp(string_ptr, prefix_ptr, (size_t)prefix_len) == 0 ? 1 : 0;
}

uint8_t cyna_string_ends_with(const char *string_ptr, int64_t string_len, const char *suffix_ptr, int64_t suffix_len) {
    string_len = (int64_t)(((uint64_t)string_len) & ~cyna_string_owned_bit_u64());
    suffix_len = (int64_t)(((uint64_t)suffix_len) & ~cyna_string_owned_bit_u64());
    if (suffix_len > string_len) return 0;
    if (suffix_len == 0) return 1;
    return memcmp(string_ptr + (string_len - suffix_len), suffix_ptr, (size_t)suffix_len) == 0 ? 1 : 0;
}

uint8_t cyna_string_contains(const char *string_ptr, int64_t string_len, const char *needle_ptr, int64_t needle_len) {
    string_len = (int64_t)(((uint64_t)string_len) & ~cyna_string_owned_bit_u64());
    needle_len = (int64_t)(((uint64_t)needle_len) & ~cyna_string_owned_bit_u64());
    int64_t i;
    if (needle_len == 0) return 1;
    if (needle_len > string_len) return 0;
    for (i = 0; i <= string_len - needle_len; i += 1) {
        if (memcmp(string_ptr + i, needle_ptr, (size_t)needle_len) == 0) return 1;
    }
    return 0;
}

CynaOptionalI64 cyna_string_find(const char *string_ptr, int64_t string_len, const char *needle_ptr, int64_t needle_len) {
    string_len = (int64_t)(((uint64_t)string_len) & ~cyna_string_owned_bit_u64());
    needle_len = (int64_t)(((uint64_t)needle_len) & ~cyna_string_owned_bit_u64());
    int64_t i;
    if (needle_len == 0) return (CynaOptionalI64){ 1, 0 };
    if (needle_len > string_len) return (CynaOptionalI64){ 0, 0 };
    for (i = 0; i <= string_len - needle_len; i += 1) {
        if (memcmp(string_ptr + i, needle_ptr, (size_t)needle_len) == 0) {
            return (CynaOptionalI64){ 1, i };
        }
    }
    return (CynaOptionalI64){ 0, 0 };
}

CynaOptionalI64 cyna_string_rfind(const char *string_ptr, int64_t string_len, const char *needle_ptr, int64_t needle_len) {
    string_len = (int64_t)(((uint64_t)string_len) & ~cyna_string_owned_bit_u64());
    needle_len = (int64_t)(((uint64_t)needle_len) & ~cyna_string_owned_bit_u64());
    int64_t i;
    if (needle_len == 0) return (CynaOptionalI64){ 1, string_len };
    if (needle_len > string_len) return (CynaOptionalI64){ 0, 0 };
    for (i = string_len - needle_len; i >= 0; i -= 1) {
        if (memcmp(string_ptr + i, needle_ptr, (size_t)needle_len) == 0) {
            return (CynaOptionalI64){ 1, i };
        }
        if (i == 0) break;
    }
    return (CynaOptionalI64){ 0, 0 };
}

CynaString cyna_string_slice(CynaString value, int64_t start, int64_t end) {
    int64_t len = cyna_string_logical_len(value);
    if (start < 0 || end < start || end > len) cyna_abort();
    CynaString out = cyna_runtime_string_new_uninit(end - start);
    if (end != start) memcpy((char *)out.ptr, value.ptr + start, (size_t)(end - start));
    return out;
}

void cyna_string_slice_into(CynaString *dst, const CynaString *value, int64_t start, int64_t end) {
    *dst = cyna_string_slice(*value, start, end);
}

void cyna_string_find_into(CynaOptionalI64 *dst, const char *string_ptr, int64_t string_len, const char *needle_ptr, int64_t needle_len) {
    *dst = cyna_string_find(string_ptr, string_len, needle_ptr, needle_len);
}

void cyna_string_rfind_into(CynaOptionalI64 *dst, const char *string_ptr, int64_t string_len, const char *needle_ptr, int64_t needle_len) {
    *dst = cyna_string_rfind(string_ptr, string_len, needle_ptr, needle_len);
}

static CynaDense *cyna_dense_core_new(const CynaTypeDesc *elem) {
    CynaDense *dense = (CynaDense *)cyna_xmalloc_site(sizeof(CynaDense), __FILE__, __LINE__, "runtime.dense", __builtin_return_address(0));
    dense->elem_desc = elem;
    dense->len = 0;
    dense->cap = 0;
    dense->data = NULL;
    return dense;
}

static CynaDense *cyna_dense_core_copy(void *list_ptr, const CynaTypeDesc *elem) {
    CynaDense *src = (CynaDense *)list_ptr;
    int64_t elem_size = elem->size;
    if (src->elem_desc != elem) cyna_abort();
    CynaDense *dst = cyna_dense_core_new(elem);
    if (src->cap != 0) {
        dst->data = (unsigned char *)cyna_xmalloc_site((size_t)(src->cap * elem_size), __FILE__, __LINE__, "runtime.dense.copy.data", __builtin_return_address(0));
        dst->cap = src->cap;
    }
    if (src->len != 0) {
        for (int64_t i = 0; i < src->len; i += 1) {
            elem->copy(dst->data + ((size_t)i * (size_t)elem_size), src->data + ((size_t)i * (size_t)elem_size), elem);
        }
        dst->len = src->len;
    }
    return dst;
}

static void cyna_dense_core_drop(void *list_ptr, const CynaTypeDesc *elem) {
    CynaDense *dense = (CynaDense *)list_ptr;
    for (int64_t i = 0; i < dense->len; i += 1) {
        elem->drop(dense->data + ((size_t)i * (size_t)elem->size), elem);
    }
    cyna_xfree(dense->data);
    cyna_xfree(dense);
}
