#include "../../../src/runtime/cyna.h"
#include "std_align.h"
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

typedef enum {
    CYNA_THREAD_UNSUPPORTED = 0,
    CYNA_THREAD_SPAWN_FAILED = 1,
    CYNA_THREAD_JOIN_FAILED = 2,
    CYNA_THREAD_DETACH_FAILED = 3,
} CynaThreadError;

typedef struct {
    unsigned long raw;
} CynaThread;

typedef struct {
    unsigned long raw;
} CynaThreadId;

typedef struct {
    uint8_t is_ok;
    CynaThread ok;
    int32_t err;
} CynaResultThreadThreadError;

typedef struct {
    bool settled;
    int32_t code;
    CynaThread handle;
} CynaThreadOpRaw;

typedef void (*CynaThreadEntry)(void *);
typedef void (*CynaThreadI32Entry)(int32_t);
typedef void (*CynaThreadBoxedEntry)(void *);

typedef struct {
    CynaThreadEntry entry;
    void *ctx;
} CynaThreadStart;

typedef struct {
    CynaThreadI32Entry entry;
    int32_t value;
} CynaThreadI32Start;

typedef struct {
    CynaThreadBoxedEntry entry;
    void *payload;
    const CynaTypeDesc *desc;
} CynaThreadBoxedStart;

static CynaResultThreadThreadError cyna_std_thread_result_thread_ok(CynaThread value) {
    return (CynaResultThreadThreadError){
        .is_ok = 0,
        .ok = value,
        .err = 0,
    };
}

static CynaResultThreadThreadError cyna_std_thread_result_thread_err(CynaThreadError err) {
    return (CynaResultThreadThreadError){
        .is_ok = 1,
        .ok = (CynaThread){ .raw = 0 },
        .err = err,
    };
}

static CynaThreadOpRaw cyna_std_thread_result_void_ok(void) {
    return (CynaThreadOpRaw){
        .settled = true,
        .code = 0,
        .handle = { .raw = 0 },
    };
}

static CynaThreadOpRaw cyna_std_thread_result_void_err(CynaThreadError err, CynaThread thread) {
    return (CynaThreadOpRaw){
        .settled = false,
        .code = err,
        .handle = thread,
    };
}

static void *cyna_std_thread_trampoline(void *arg) {
    CynaThreadStart start = *(CynaThreadStart *)arg;
    free(arg);
    start.entry(start.ctx);
    return NULL;
}

static void *cyna_std_thread_i32_trampoline(void *arg) {
    CynaThreadI32Start start = *(CynaThreadI32Start *)arg;
    free(arg);
    start.entry(start.value);
    return NULL;
}

static int cyna_std_thread_is_power_of_two(size_t value) {
    return value != 0 && (value & (value - 1u)) == 0;
}

static void *cyna_std_thread_alloc_payload(size_t size, size_t align) {
    if (align > _Alignof(max_align_t) && (!cyna_std_thread_is_power_of_two(align) || align < sizeof(void *))) return NULL;
    return cyna_std_alloc_aligned(size, align);
}

static void cyna_std_thread_drop_boxed_payload(void *payload, const CynaTypeDesc *desc) {
    if (payload == NULL) return;
    if (desc != NULL && desc->drop != NULL) {
        desc->drop(payload, desc);
    }
    cyna_std_free_aligned(payload);
}

static void *cyna_std_thread_boxed_trampoline(void *arg) {
    CynaThreadBoxedStart start = *(CynaThreadBoxedStart *)arg;
    free(arg);
    start.entry(start.payload);
    cyna_std_thread_drop_boxed_payload(start.payload, start.desc);
    return NULL;
}

CynaResultThreadThreadError cyna_std_thread_spawn_raw(CynaThreadEntry entry, void *ctx) {
    if (entry == NULL) {
        return cyna_std_thread_result_thread_err(CYNA_THREAD_SPAWN_FAILED);
    }

    CynaThreadStart *start = (CynaThreadStart *)malloc(sizeof(CynaThreadStart));
    if (start == NULL) {
        return cyna_std_thread_result_thread_err(CYNA_THREAD_SPAWN_FAILED);
    }

    start->entry = entry;
    start->ctx = ctx;

    pthread_t thread;
    if (pthread_create(&thread, NULL, cyna_std_thread_trampoline, start) != 0) {
        free(start);
        return cyna_std_thread_result_thread_err(CYNA_THREAD_SPAWN_FAILED);
    }

    return cyna_std_thread_result_thread_ok((CynaThread){ .raw = (unsigned long)(uintptr_t)thread });
}

CynaResultThreadThreadError cyna_std_thread_unsupported(void) {
    return cyna_std_thread_result_thread_err(CYNA_THREAD_UNSUPPORTED);
}

CynaResultThreadThreadError cyna_std_thread_spawn_i32(CynaThreadI32Entry entry, int32_t value) {
    if (entry == NULL) {
        return cyna_std_thread_result_thread_err(CYNA_THREAD_SPAWN_FAILED);
    }

    CynaThreadI32Start *start = (CynaThreadI32Start *)malloc(sizeof(CynaThreadI32Start));
    if (start == NULL) {
        return cyna_std_thread_result_thread_err(CYNA_THREAD_SPAWN_FAILED);
    }

    start->entry = entry;
    start->value = value;

    pthread_t thread;
    if (pthread_create(&thread, NULL, cyna_std_thread_i32_trampoline, start) != 0) {
        free(start);
        return cyna_std_thread_result_thread_err(CYNA_THREAD_SPAWN_FAILED);
    }

    return cyna_std_thread_result_thread_ok((CynaThread){ .raw = (unsigned long)(uintptr_t)thread });
}

CynaResultThreadThreadError cyna_std_thread_spawn_boxed(CynaThreadBoxedEntry entry, const void *value, const CynaTypeDesc *desc) {
    if (entry == NULL || value == NULL || desc == NULL || desc->size < 0 || desc->align <= 0) {
        return cyna_std_thread_result_thread_err(CYNA_THREAD_SPAWN_FAILED);
    }

    CynaThreadBoxedStart *start = (CynaThreadBoxedStart *)malloc(sizeof(CynaThreadBoxedStart));
    if (start == NULL) {
        return cyna_std_thread_result_thread_err(CYNA_THREAD_SPAWN_FAILED);
    }

    size_t payload_size = desc->size == 0 ? 1 : (size_t)desc->size;
    void *payload = cyna_std_thread_alloc_payload(payload_size, (size_t)desc->align);
    if (payload == NULL) {
        free(start);
        return cyna_std_thread_result_thread_err(CYNA_THREAD_SPAWN_FAILED);
    }

    if (desc->copy != NULL) {
        desc->copy(payload, value, desc);
    } else if (desc->size != 0) {
        memcpy(payload, value, (size_t)desc->size);
    }

    start->entry = entry;
    start->payload = payload;
    start->desc = desc;

    pthread_t thread;
    if (pthread_create(&thread, NULL, cyna_std_thread_boxed_trampoline, start) != 0) {
        cyna_std_thread_drop_boxed_payload(payload, desc);
        free(start);
        return cyna_std_thread_result_thread_err(CYNA_THREAD_SPAWN_FAILED);
    }

    return cyna_std_thread_result_thread_ok((CynaThread){ .raw = (unsigned long)(uintptr_t)thread });
}

CynaThreadId cyna_std_thread_current_id_raw(void) {
    return (CynaThreadId){ .raw = (unsigned long)(uintptr_t)pthread_self() };
}

CynaThreadId cyna_std_thread_thread_id_raw(CynaThread thread) {
    return (CynaThreadId){ .raw = thread.raw };
}

bool cyna_std_thread_thread_id_is_valid(CynaThreadId id) {
    return id.raw != 0;
}

bool cyna_std_thread_thread_id_equals(CynaThreadId lhs, CynaThreadId rhs) {
    return lhs.raw == rhs.raw;
}

CynaThreadOpRaw cyna_std_thread_join(CynaThread thread) {
    if (thread.raw == 0) {
        return cyna_std_thread_result_void_err(CYNA_THREAD_JOIN_FAILED, thread);
    }
    pthread_t native = (pthread_t)(uintptr_t)thread.raw;
    if (pthread_join(native, NULL) != 0) {
        return cyna_std_thread_result_void_err(CYNA_THREAD_JOIN_FAILED, thread);
    }
    return cyna_std_thread_result_void_ok();
}

CynaThreadOpRaw cyna_std_thread_detach(CynaThread thread) {
    if (thread.raw == 0) {
        return cyna_std_thread_result_void_err(CYNA_THREAD_DETACH_FAILED, thread);
    }
    pthread_t native = (pthread_t)(uintptr_t)thread.raw;
    if (pthread_detach(native) != 0) {
        return cyna_std_thread_result_void_err(CYNA_THREAD_DETACH_FAILED, thread);
    }
    return cyna_std_thread_result_void_ok();
}
