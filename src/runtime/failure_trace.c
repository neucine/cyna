#include "failure_trace.h"
#ifndef CYNA_FREESTANDING
#include <stdlib.h>
#include <stdio.h>
#endif

#if CYNA_TRACE_SLOTS < 1 || CYNA_TRACE_SLOTS > UINT32_MAX - 1
#error "CYNA_TRACE_SLOTS must fit a nonzero 32-bit slot identifier"
#endif
#if CYNA_TRACE_SITES < 0 || CYNA_TRACE_MESSAGE_BYTES < 0
#error "trace capacities cannot be negative"
#endif
_Static_assert(_Alignof(CynaTraceContext) <= 64, "generated trace context stack alignment is insufficient");

static void copy_bytes(void *destination, const void *source, size_t length) {
    unsigned char *out = destination;
    const unsigned char *in = source;
    for (size_t i = 0; i < length; ++i) out[i] = in[i];
}

static void lock_context(CynaTraceContext *context) {
#ifdef CYNA_FREESTANDING
    (void)context;
#else
    while (atomic_flag_test_and_set_explicit(&context->lock, memory_order_acquire)) { }
#endif
}

static void unlock_context(CynaTraceContext *context) {
#ifdef CYNA_FREESTANDING
    (void)context;
#else
    atomic_flag_clear_explicit(&context->lock, memory_order_release);
#endif
}

static CynaTraceSlot *lookup(CynaTraceContext *context, CynaTraceHandle handle) {
    if (handle.owner != context || handle.slot_plus_one == 0 || handle.slot_plus_one > CYNA_TRACE_SLOTS) return NULL;
    CynaTraceSlot *slot = &context->slots[handle.slot_plus_one - 1];
    if (!slot->live || slot->generation != handle.generation) return NULL;
    return slot;
}

static bool has_live_slots(const CynaTraceContext *context) {
    for (size_t i = 0; i < CYNA_TRACE_SLOTS; ++i) {
        if (context->slots[i].live) return true;
    }
    return false;
}

size_t cyna_trace_context_size(void) { return sizeof(CynaTraceContext); }
size_t cyna_trace_context_align(void) { return _Alignof(CynaTraceContext); }

void cyna_trace_init(CynaTraceContext *context) {
    // Initialization requires exclusive access and no outstanding handles.
#ifdef CYNA_FREESTANDING
    *context = (CynaTraceContext){0};
#else
    *context = (CynaTraceContext){ .lock = ATOMIC_FLAG_INIT };
#endif
    for (size_t i = 0; i < CYNA_TRACE_SLOTS; ++i) context->slots[i].generation = 1;
}

CynaTraceContext *cyna_trace_new(void) {
#ifdef CYNA_FREESTANDING
    return NULL;
#else
    CynaTraceContext *context = malloc(sizeof(*context));
    if (context == NULL) return NULL;
    cyna_trace_init(context);
    context->heap_owned = true;
    return context;
#endif
}

void cyna_trace_release_root(CynaTraceContext *context) {
    if (context == NULL || !context->heap_owned) return;
    lock_context(context);
    context->root_released = true;
    if (context->leases == 0) context->closed = true;
    const bool destroy = context->closed && !has_live_slots(context);
    unlock_context(context);
#ifndef CYNA_FREESTANDING
    if (destroy) free(context);
#else
    (void)destroy;
#endif
}

bool cyna_trace_acquire_lease(CynaTraceContext *context) {
    if (context == NULL) return false;
    lock_context(context);
    bool ok = !context->closed && context->leases != SIZE_MAX;
    if (ok) context->leases++;
    unlock_context(context);
    return ok;
}

void cyna_trace_release_lease(CynaTraceContext *context) {
    if (context == NULL) return;
    lock_context(context);
    // Caller owns a lease; defensive no-op protects the remaining leases.
    if (context->leases != 0) context->leases--;
    if (context->heap_owned && context->root_released && context->leases == 0) context->closed = true;
    const bool destroy = context->heap_owned && context->root_released && context->closed && !has_live_slots(context);
    unlock_context(context);
#ifndef CYNA_FREESTANDING
    if (destroy) free(context);
#else
    (void)destroy;
#endif
}

bool cyna_trace_close(CynaTraceContext *context) {
    if (context == NULL) return false;
    lock_context(context);
    bool ok = context->leases == 0;
    for (size_t i = 0; ok && i < CYNA_TRACE_SLOTS; ++i) {
        if (context->slots[i].live) ok = false;
    }
    if (ok) context->closed = true;
    unlock_context(context);
    return ok;
}

static CynaTraceFile trace_file(const char *file, int64_t file_len) {
    return file == NULL || file_len <= 0 ? (CynaTraceFile){"", 0} : (CynaTraceFile){file, file_len};
}

static CynaTraceHandle trace_create_with_file(CynaTraceContext *context, uint32_t origin,
                                               CynaTraceFile file,
                                               const unsigned char *message, size_t message_len) {
    CynaTraceHandle none = {0};
    if (context == NULL) return none;
    if (message_len > CYNA_TRACE_MESSAGE_BYTES || (message_len != 0 && message == NULL)) return none;
    lock_context(context);
    if (context->closed) { unlock_context(context); return none; }
    for (size_t i = 0; i < CYNA_TRACE_SLOTS; ++i) {
        CynaTraceSlot *slot = &context->slots[i];
        if (slot->live || slot->generation == 0) continue;
        slot->live = true;
        slot->origin = origin;
        slot->origin_file = file;
        slot->site_count = 0;
        slot->omitted = 0;
        slot->message_len = message_len;
        if (message_len != 0) copy_bytes(slot->message, message, message_len);
        CynaTraceHandle handle = {context, (uint32_t)(i + 1), slot->generation};
        unlock_context(context);
        return handle;
    }
    unlock_context(context);
    return none;
}

CynaTraceHandle cyna_trace_create(CynaTraceContext *context, uint32_t origin,
                                   const unsigned char *message, size_t message_len) {
    return trace_create_with_file(context, origin, trace_file(NULL, 0), message, message_len);
}

static void trace_append_with_file(CynaTraceContext *context, CynaTraceHandle handle,
                                   uint32_t site, CynaTraceFile file) {
    if (context == NULL) return;
    lock_context(context);
    CynaTraceSlot *slot = lookup(context, handle);
    if (slot != NULL) {
        if (slot->site_count < CYNA_TRACE_SITES) {
            slot->sites[slot->site_count] = site;
            slot->site_files[slot->site_count++] = file;
        }
        else if (slot->omitted != SIZE_MAX) slot->omitted++;
    }
    unlock_context(context);
}

void cyna_trace_append(CynaTraceContext *context, CynaTraceHandle handle, uint32_t site) {
    trace_append_with_file(context, handle, site, trace_file(NULL, 0));
}

bool cyna_trace_available(CynaTraceContext *context, CynaTraceHandle handle) {
    if (context == NULL) return false;
    lock_context(context);
    const bool available = lookup(context, handle) != NULL;
    unlock_context(context);
    return available;
}

void cyna_trace_create_abi(CynaTraceHandle *out, CynaTraceContext *context,
                           uint32_t origin, const unsigned char *message, size_t message_len) {
    *out = cyna_trace_create(context, origin, message, message_len);
}

void cyna_trace_create_location_abi(CynaTraceHandle *out, CynaTraceContext *context,
                                    uint32_t origin, const char *file, int64_t file_len,
                                    const unsigned char *message, size_t message_len) {
    *out = trace_create_with_file(context, origin, trace_file(file, file_len), message, message_len);
}

// A result may cross a task boundary. Its live handle owns the context used
// for all subsequent reads, propagation, and retirement.
static CynaTraceContext *trace_handle_owner(CynaTraceContext *context, const CynaTraceHandle *handle) {
    (void)context;
    return handle == NULL || handle->slot_plus_one == 0 ? NULL : (CynaTraceContext *)handle->owner;
}

void cyna_trace_append_abi(CynaTraceContext *context, const CynaTraceHandle *handle, uint32_t site) {
    if (handle != NULL) cyna_trace_append(trace_handle_owner(context, handle), *handle, site);
}

void cyna_trace_append_location_abi(CynaTraceContext *context, const CynaTraceHandle *handle,
                                    uint32_t site, const char *file, int64_t file_len) {
    if (handle != NULL) trace_append_with_file(trace_handle_owner(context, handle), *handle, site, trace_file(file, file_len));
}

void cyna_trace_release_abi(CynaTraceContext *context, const CynaTraceHandle *handle) {
    if (handle != NULL) cyna_trace_release(trace_handle_owner(context, handle), *handle);
}

void cyna_trace_print_unhandled_abi(uint8_t tag, const CynaTraceHandle *handle) {
#ifndef CYNA_FREESTANDING
    if (tag == 0) return;
    CynaTraceSnapshot snapshot;
    if (handle == NULL || !cyna_trace_snapshot(trace_handle_owner(NULL, handle), *handle, &snapshot)) {
        fputs("error: unhandled Cyna failure (trace unavailable)\n", stderr);
        return;
    }
    fputs("error: unhandled Cyna failure", stderr);
    if (snapshot.message_len != 0) fprintf(stderr, ": %.*s", (int)snapshot.message_len, snapshot.message);
    fputc('\n', stderr);
    if (snapshot.origin != 0) {
        fprintf(stderr, "  --> %.*s:%u (throw)\n", (int)snapshot.origin_file.len,
                snapshot.origin_file.ptr == NULL ? "" : snapshot.origin_file.ptr, snapshot.origin);
    }
    for (size_t i = 0; i < snapshot.site_count; ++i) {
        fprintf(stderr, "  --> %.*s:%u (propagated)\n", (int)snapshot.site_files[i].len,
                snapshot.site_files[i].ptr == NULL ? "" : snapshot.site_files[i].ptr, snapshot.sites[i]);
    }
    if (snapshot.omitted != 0) fprintf(stderr, "  = note: %zu propagation site(s) omitted\n", snapshot.omitted);
#else
    (void)tag;
    (void)handle;
#endif
}

bool cyna_trace_available_abi(CynaTraceContext *context, const CynaTraceHandle *handle) {
    return handle != NULL && cyna_trace_available(trace_handle_owner(context, handle), *handle);
}

uint32_t cyna_trace_origin_abi(CynaTraceContext *context, const CynaTraceHandle *handle) {
    return handle == NULL ? 0 : cyna_trace_origin(trace_handle_owner(context, handle), *handle);
}

uint64_t cyna_trace_site_count_abi(CynaTraceContext *context, const CynaTraceHandle *handle) {
    return handle == NULL ? 0 : cyna_trace_site_count(trace_handle_owner(context, handle), *handle);
}

uint64_t cyna_trace_omitted_abi(CynaTraceContext *context, const CynaTraceHandle *handle) {
    return handle == NULL ? 0 : cyna_trace_omitted(trace_handle_owner(context, handle), *handle);
}

bool cyna_trace_site_abi(CynaTraceContext *context, const CynaTraceHandle *handle,
                         int64_t index, uint32_t *out) {
    context = trace_handle_owner(context, handle);
    if (context == NULL || out == NULL || index < 0) return false;
    lock_context(context);
    CynaTraceSlot *slot = lookup(context, *handle);
    const bool found = slot != NULL && (uint64_t)index < slot->site_count;
    if (found) *out = slot->sites[index];
    unlock_context(context);
    return found;
}

void cyna_trace_origin_file_abi(CynaTraceFile *out, CynaTraceContext *context,
                                const CynaTraceHandle *handle) {
    if (out == NULL) return;
    *out = trace_file(NULL, 0);
    context = trace_handle_owner(context, handle);
    if (context == NULL) return;
    lock_context(context);
    CynaTraceSlot *slot = lookup(context, *handle);
    if (slot != NULL) *out = slot->origin_file;
    unlock_context(context);
}

bool cyna_trace_site_file_abi(CynaTraceContext *context, const CynaTraceHandle *handle,
                              int64_t index, CynaTraceFile *out) {
    if (out == NULL) return false;
    *out = trace_file(NULL, 0);
    context = trace_handle_owner(context, handle);
    if (context == NULL || index < 0) return false;
    lock_context(context);
    CynaTraceSlot *slot = lookup(context, *handle);
    const bool found = slot != NULL && (uint64_t)index < slot->site_count;
    if (found) *out = slot->site_files[index];
    unlock_context(context);
    return found;
}

size_t cyna_trace_copy_message_abi(CynaTraceContext *context, const CynaTraceHandle *handle,
                                   unsigned char *out, size_t capacity) {
    context = trace_handle_owner(context, handle);
    if (context == NULL || out == NULL) return 0;
    lock_context(context);
    CynaTraceSlot *slot = lookup(context, *handle);
    size_t length = slot == NULL ? 0 : slot->message_len;
    if (length > capacity) length = capacity;
    if (length != 0) copy_bytes(out, slot->message, length);
    unlock_context(context);
    return length;
}

uint32_t cyna_trace_origin(CynaTraceContext *context, CynaTraceHandle handle) {
    if (context == NULL) return 0;
    lock_context(context);
    CynaTraceSlot *slot = lookup(context, handle);
    const uint32_t origin = slot == NULL ? 0 : slot->origin;
    unlock_context(context);
    return origin;
}

uint64_t cyna_trace_site_count(CynaTraceContext *context, CynaTraceHandle handle) {
    if (context == NULL) return 0;
    lock_context(context);
    CynaTraceSlot *slot = lookup(context, handle);
    const uint64_t count = slot == NULL ? 0 : (uint64_t)slot->site_count;
    unlock_context(context);
    return count;
}

uint64_t cyna_trace_omitted(CynaTraceContext *context, CynaTraceHandle handle) {
    if (context == NULL) return 0;
    lock_context(context);
    CynaTraceSlot *slot = lookup(context, handle);
    const uint64_t omitted = slot == NULL ? 0 : (uint64_t)slot->omitted;
    unlock_context(context);
    return omitted;
}

bool cyna_trace_snapshot(CynaTraceContext *context, CynaTraceHandle handle,
                         CynaTraceSnapshot *out) {
    if (context == NULL || out == NULL) return false;
    lock_context(context);
    CynaTraceSlot *slot = lookup(context, handle);
    if (slot == NULL) { unlock_context(context); return false; }
    out->origin = slot->origin;
    out->origin_file = slot->origin_file;
    out->site_count = slot->site_count;
    out->omitted = slot->omitted;
    out->message_len = slot->message_len;
    if (slot->site_count != 0) {
        copy_bytes(out->sites, slot->sites, slot->site_count * sizeof(uint32_t));
        copy_bytes(out->site_files, slot->site_files, slot->site_count * sizeof(CynaTraceFile));
    }
    if (slot->message_len != 0) copy_bytes(out->message, slot->message, slot->message_len);
    unlock_context(context);
    return true;
}

void cyna_trace_release(CynaTraceContext *context, CynaTraceHandle handle) {
    if (context == NULL) return;
    lock_context(context);
    CynaTraceSlot *slot = lookup(context, handle);
    if (slot != NULL) {
        slot->live = false;
        slot->message_len = 0;
        slot->site_count = 0;
        slot->omitted = 0;
        slot->generation++; // wrapping to zero retires the slot
    }
    const bool destroy = context->heap_owned && context->root_released && context->closed && context->leases == 0 && !has_live_slots(context);
    unlock_context(context);
#ifndef CYNA_FREESTANDING
    if (destroy) free(context);
#else
    (void)destroy;
#endif
}
