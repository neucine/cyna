#ifndef CYNA_FAILURE_TRACE_H
#define CYNA_FAILURE_TRACE_H

// Internal compiler/runtime diagnostic storage. No type here is a Cyna value.
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifndef CYNA_FREESTANDING
#include <stdatomic.h>
#endif

#ifndef CYNA_TRACE_SLOTS
#define CYNA_TRACE_SLOTS 16
#endif
#ifndef CYNA_TRACE_SITES
#define CYNA_TRACE_SITES 8
#endif
#ifndef CYNA_TRACE_MESSAGE_BYTES
#define CYNA_TRACE_MESSAGE_BYTES 96
#endif

// C forbids zero-length arrays. A zero-site build still has one unused cell.
#define CYNA_TRACE_SITE_CELLS ((CYNA_TRACE_SITES) > 0 ? (CYNA_TRACE_SITES) : 1)
#define CYNA_TRACE_MESSAGE_CELLS ((CYNA_TRACE_MESSAGE_BYTES) > 0 ? (CYNA_TRACE_MESSAGE_BYTES) : 1)

typedef struct {
    const char *ptr;
    int64_t len;
} CynaTraceFile;

typedef struct {
    uint32_t generation;
    bool live;
    uint32_t origin;
    CynaTraceFile origin_file;
    uint32_t sites[CYNA_TRACE_SITE_CELLS];
    CynaTraceFile site_files[CYNA_TRACE_SITE_CELLS];
    size_t site_count;
    size_t omitted;
    unsigned char message[CYNA_TRACE_MESSAGE_CELLS];
    size_t message_len;
} CynaTraceSlot;

typedef struct CynaTraceContext {
#ifdef CYNA_FREESTANDING
    // The freestanding runtime has no worker threads or atomic support.
    uint8_t lock_unused;
#else
    atomic_flag lock;
#endif
    bool closed;
    bool heap_owned;
    bool root_released;
    size_t leases;
    CynaTraceSlot slots[CYNA_TRACE_SLOTS];
} CynaTraceContext;

typedef struct {
    const CynaTraceContext *owner;
    uint32_t slot_plus_one; // zero means code-only diagnostics
    uint32_t generation;
} CynaTraceHandle;

typedef struct {
    uint32_t origin;
    CynaTraceFile origin_file;
    uint32_t sites[CYNA_TRACE_SITE_CELLS];
    CynaTraceFile site_files[CYNA_TRACE_SITE_CELLS];
    size_t site_count;
    size_t omitted;
    unsigned char message[CYNA_TRACE_MESSAGE_CELLS];
    size_t message_len;
} CynaTraceSnapshot;

void cyna_trace_init(CynaTraceContext *context);
CynaTraceContext *cyna_trace_new(void);
void cyna_trace_release_root(CynaTraceContext *context);
size_t cyna_trace_context_size(void);
size_t cyna_trace_context_align(void);
bool cyna_trace_acquire_lease(CynaTraceContext *context);
void cyna_trace_release_lease(CynaTraceContext *context);
bool cyna_trace_close(CynaTraceContext *context);
CynaTraceHandle cyna_trace_create(CynaTraceContext *context, uint32_t origin,
                                  const unsigned char *message, size_t message_len);
void cyna_trace_append(CynaTraceContext *context, CynaTraceHandle handle, uint32_t site);
bool cyna_trace_snapshot(CynaTraceContext *context, CynaTraceHandle handle,
                         CynaTraceSnapshot *out);
void cyna_trace_release(CynaTraceContext *context, CynaTraceHandle handle);
bool cyna_trace_available(CynaTraceContext *context, CynaTraceHandle handle);
uint32_t cyna_trace_origin(CynaTraceContext *context, CynaTraceHandle handle);
uint64_t cyna_trace_site_count(CynaTraceContext *context, CynaTraceHandle handle);
uint64_t cyna_trace_omitted(CynaTraceContext *context, CynaTraceHandle handle);

// Pointer arguments keep the generated LLVM boundary independent of the C
// platform's aggregate calling convention.
void cyna_trace_create_abi(CynaTraceHandle *out, CynaTraceContext *context,
                           uint32_t origin, const unsigned char *message, size_t message_len);
void cyna_trace_create_location_abi(CynaTraceHandle *out, CynaTraceContext *context,
                                    uint32_t origin, const char *file, int64_t file_len,
                                    const unsigned char *message, size_t message_len);
void cyna_trace_append_abi(CynaTraceContext *context, const CynaTraceHandle *handle, uint32_t site);
void cyna_trace_append_location_abi(CynaTraceContext *context, const CynaTraceHandle *handle,
                                    uint32_t site, const char *file, int64_t file_len);
void cyna_trace_release_abi(CynaTraceContext *context, const CynaTraceHandle *handle);
void cyna_trace_print_unhandled_abi(uint8_t tag, const CynaTraceHandle *handle);
bool cyna_trace_available_abi(CynaTraceContext *context, const CynaTraceHandle *handle);
uint32_t cyna_trace_origin_abi(CynaTraceContext *context, const CynaTraceHandle *handle);
uint64_t cyna_trace_site_count_abi(CynaTraceContext *context, const CynaTraceHandle *handle);
uint64_t cyna_trace_omitted_abi(CynaTraceContext *context, const CynaTraceHandle *handle);
bool cyna_trace_site_abi(CynaTraceContext *context, const CynaTraceHandle *handle,
                         int64_t index, uint32_t *out);
void cyna_trace_origin_file_abi(CynaTraceFile *out, CynaTraceContext *context,
                                const CynaTraceHandle *handle);
bool cyna_trace_site_file_abi(CynaTraceContext *context, const CynaTraceHandle *handle,
                              int64_t index, CynaTraceFile *out);
size_t cyna_trace_copy_message_abi(CynaTraceContext *context, const CynaTraceHandle *handle,
                                   unsigned char *out, size_t capacity);

#endif
