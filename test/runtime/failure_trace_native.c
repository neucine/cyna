// Fixed-storage trace context and generated-code ABI contract.
#include "../../src/runtime/failure_trace.h"
#include <assert.h>
#include <pthread.h>
#include <string.h>

#undef assert
#define assert(check) do { if (!(check)) __builtin_trap(); } while (0)

typedef struct { CynaTraceContext *context; CynaTraceHandle handle; uint32_t first; } Worker;
static void *append_sites(void *raw) {
    Worker *worker = raw;
    for (uint32_t i = 0; i < 100; ++i) cyna_trace_append(worker->context, worker->handle, worker->first + i);
    return NULL;
}

int main(void) {
    assert(!cyna_trace_acquire_lease(NULL));
    assert(cyna_trace_create(NULL, 1, NULL, 0).slot_plus_one == 0);
    CynaTraceContext *owned = cyna_trace_new();
    assert(owned != NULL);
    assert(cyna_trace_acquire_lease(owned));
    cyna_trace_release_root(owned);
    CynaTraceHandle owned_handle = cyna_trace_create(owned, 7, NULL, 0);
    assert(owned_handle.slot_plus_one != 0);
    CynaTraceSnapshot owned_view;
    assert(cyna_trace_snapshot(owned, owned_handle, &owned_view));
    cyna_trace_release_lease(owned);
    assert(cyna_trace_snapshot(owned, owned_handle, &owned_view));
    assert(!cyna_trace_acquire_lease(owned));
    cyna_trace_release(owned, owned_handle);
    CynaTraceContext *transferred = cyna_trace_new();
    assert(transferred != NULL);
    CynaTraceHandle transferred_handle = {0};
    cyna_trace_create_location_abi(&transferred_handle, transferred, 29, "worker.cy", 9, NULL, 0);
    assert(transferred_handle.slot_plus_one != 0);
    cyna_trace_release_root(transferred);
    CynaTraceContext receiver;
    cyna_trace_init(&receiver);
    assert(cyna_trace_available_abi(&receiver, &transferred_handle));
    cyna_trace_append_location_abi(&receiver, &transferred_handle, 31, "main.cy", 7);
    assert(cyna_trace_snapshot(transferred, transferred_handle, &owned_view));
    assert(owned_view.site_count == 1 && owned_view.sites[0] == 31);
    cyna_trace_release_abi(&receiver, &transferred_handle);
    assert(cyna_trace_context_size() == sizeof(CynaTraceContext));
    assert(cyna_trace_context_align() == _Alignof(CynaTraceContext));
    CynaTraceContext context;
    cyna_trace_init(&context);
    assert(cyna_trace_acquire_lease(&context));
    const unsigned char first_message[] = "first";
    CynaTraceHandle first = cyna_trace_create(&context, 11, first_message, 5);
    CynaTraceHandle abi_handle = {0};
    cyna_trace_create_abi(&abi_handle, &context, 55, NULL, 0);
    assert(cyna_trace_available_abi(&context, &abi_handle));
    assert(cyna_trace_origin_abi(&context, &abi_handle) == 55);
    cyna_trace_append_abi(&context, &abi_handle, 61);
    uint32_t indexed_site = 0;
    assert(cyna_trace_site_abi(&context, &abi_handle, 0, &indexed_site) && indexed_site == 61);
    assert(!cyna_trace_site_abi(&context, &abi_handle, 1, &indexed_site));
    assert(!cyna_trace_site_abi(&context, &abi_handle, -1, &indexed_site));
    assert(cyna_trace_site_count_abi(&context, &abi_handle) == 1);
    assert(cyna_trace_omitted_abi(&context, &abi_handle) == 0);
    cyna_trace_release_abi(&context, &abi_handle);
    assert(!cyna_trace_available_abi(&context, &abi_handle));
    assert(!cyna_trace_available_abi(&context, &(CynaTraceHandle){0}));
    assert(cyna_trace_origin_abi(&context, &(CynaTraceHandle){0}) == 0);
    assert(cyna_trace_site_count_abi(&context, &(CynaTraceHandle){0}) == 0);
    assert(cyna_trace_omitted_abi(&context, &(CynaTraceHandle){0}) == 0);
    assert(!cyna_trace_site_abi(&context, &(CynaTraceHandle){0}, 0, &indexed_site));
    CynaTraceHandle located = {0};
    cyna_trace_create_location_abi(&located, &context, 12, "origin.cy", 9, NULL, 0);
    assert(cyna_trace_available_abi(&context, &located));
    CynaTraceFile file;
    cyna_trace_origin_file_abi(&file, &context, &located);
    assert(file.len == 9 && memcmp(file.ptr, "origin.cy", 9) == 0);
    cyna_trace_append_location_abi(&context, &located, 14, "caller.cy", 9);
    assert(cyna_trace_site_file_abi(&context, &located, 0, &file));
    assert(file.len == 9 && memcmp(file.ptr, "caller.cy", 9) == 0);
    assert(!cyna_trace_site_file_abi(&context, &located, -1, &file) && file.len == 0);
    assert(!cyna_trace_site_file_abi(&context, &located, 1, &file) && file.len == 0);
    CynaTraceSnapshot located_view;
    assert(cyna_trace_snapshot(&context, located, &located_view));
    assert(located_view.origin_file.len == 9 && located_view.site_files[0].len == 9);
    cyna_trace_release_abi(&context, &located);
    cyna_trace_origin_file_abi(&file, &context, &located);
    assert(file.len == 0);
    assert(!cyna_trace_site_file_abi(&context, &located, 0, &file) && file.len == 0);
    CynaTraceHandle second = cyna_trace_create(&context, 22, (const unsigned char *)"second", 6);
    assert(first.slot_plus_one && second.slot_plus_one && first.slot_plus_one != second.slot_plus_one);
    cyna_trace_append(&context, first, 31);
    cyna_trace_append(&context, second, 41);
    cyna_trace_append(&context, first, 32);
    CynaTraceSnapshot view;
    assert(cyna_trace_snapshot(&context, first, &view));
    assert(view.origin == 11 && view.site_count == 2 && view.sites[0] == 31 && view.sites[1] == 32);
    assert(view.message_len == 5 && memcmp(view.message, "first", 5) == 0);
    unsigned char copied_message[CYNA_TRACE_MESSAGE_CELLS] = {0};
    assert(cyna_trace_copy_message_abi(&context, &first, copied_message, sizeof(copied_message)) == 5);
    assert(memcmp(copied_message, "first", 5) == 0);
    assert(cyna_trace_copy_message_abi(&context, &(CynaTraceHandle){0}, copied_message, sizeof(copied_message)) == 0);
    assert(cyna_trace_snapshot(&context, second, &view));
    assert(view.origin == 22 && view.site_count == 1 && view.sites[0] == 41);
    assert(!cyna_trace_close(&context)); // task group settled, result lease persists
    CynaTraceContext other_context;
    cyna_trace_init(&other_context);
    assert(!cyna_trace_snapshot(&other_context, first, &view));
    cyna_trace_release(&context, second);
    cyna_trace_release(&context, first);
    assert(!cyna_trace_snapshot(&context, first, &view));
    CynaTraceHandle reused = cyna_trace_create(&context, 33, NULL, 0);
    assert(reused.slot_plus_one == first.slot_plus_one && reused.generation != first.generation);
    assert(!cyna_trace_snapshot(&context, first, &view));
    cyna_trace_release(&context, reused);

    CynaTraceHandle handles[CYNA_TRACE_SLOTS];
    for (size_t i = 0; i < CYNA_TRACE_SLOTS; ++i) {
        handles[i] = cyna_trace_create(&context, (uint32_t)i, NULL, 0);
        assert(handles[i].slot_plus_one != 0);
    }
    assert(cyna_trace_create(&context, 99, NULL, 0).slot_plus_one == 0);
    assert(cyna_trace_create(&context, 99, (const unsigned char *)"x", CYNA_TRACE_MESSAGE_BYTES + 1).slot_plus_one == 0);
    for (size_t i = 0; i < CYNA_TRACE_SLOTS; ++i) cyna_trace_release(&context, handles[i]);

    CynaTraceHandle parallel = cyna_trace_create(&context, 44, NULL, 0);
    Worker a = {&context, parallel, 1000}, b = {&context, parallel, 2000};
    pthread_t ta, tb;
    assert(pthread_create(&ta, NULL, append_sites, &a) == 0);
    assert(pthread_create(&tb, NULL, append_sites, &b) == 0);
    assert(pthread_join(ta, NULL) == 0 && pthread_join(tb, NULL) == 0);
    assert(cyna_trace_snapshot(&context, parallel, &view));
    assert(view.site_count == CYNA_TRACE_SITES && view.omitted == 200 - CYNA_TRACE_SITES);
    cyna_trace_release(&context, parallel);
    cyna_trace_release_lease(&context);
    assert(cyna_trace_close(&context));
    assert(!cyna_trace_acquire_lease(&context));
    assert(cyna_trace_create(&context, 55, NULL, 0).slot_plus_one == 0);
    return 0;
}
