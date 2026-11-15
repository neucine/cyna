#include "../../../src/runtime/cyna.h"
#include "std_align.h"
#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef enum {
    CYNA_SYNC_OK = 0,
    CYNA_SYNC_INVALID_HANDLE = 1,
    CYNA_SYNC_LOCK_FAILED = 2,
    CYNA_SYNC_UNLOCK_FAILED = 3,
    CYNA_SYNC_DESTROY_FAILED = 4,
    CYNA_SYNC_BUSY = 5,
    CYNA_SYNC_WAIT_FAILED = 6,
    CYNA_SYNC_SIGNAL_FAILED = 7,
    CYNA_SYNC_BROADCAST_FAILED = 8,
} CynaSyncStatus;

typedef enum {
    CYNA_MEMORY_ORDER_RELAXED = 0,
    CYNA_MEMORY_ORDER_ACQUIRE = 1,
    CYNA_MEMORY_ORDER_RELEASE = 2,
    CYNA_MEMORY_ORDER_ACQ_REL = 3,
    CYNA_MEMORY_ORDER_SEQ_CST = 4,
} CynaMemoryOrder;

typedef struct {
    unsigned long raw;
} CynaMutex;

typedef struct {
    unsigned long raw;
} CynaCondvar;

typedef struct {
    unsigned long raw;
} CynaSharedHandle;

typedef struct {
    unsigned long raw;
} CynaArcHandle;

typedef struct {
    unsigned long raw;
} CynaAtomicI32;

typedef struct {
    unsigned long raw;
} CynaAtomicUsize;

typedef struct {
    unsigned long raw;
} CynaAtomicBool;

typedef struct {
    pthread_mutex_t mutex;
    void *ptr;
    const CynaTypeDesc *desc;
} CynaSharedBox;

typedef struct {
    void *ptr;
    const CynaTypeDesc *desc;
    unsigned long ref_count;
} CynaArcBox;

static int cyna_std_sync_is_power_of_two(size_t value) {
    return value != 0 && (value & (value - 1u)) == 0;
}

static void *cyna_std_sync_alloc_payload(size_t size, size_t align) {
    if (align > _Alignof(max_align_t) && (!cyna_std_sync_is_power_of_two(align) || align < sizeof(void *))) return NULL;
    return cyna_std_alloc_aligned(size, align);
}

static void cyna_std_sync_drop_payload(void *payload, const CynaTypeDesc *desc) {
    if (payload == NULL) return;
    if (desc != NULL && desc->drop != NULL) {
        desc->drop(payload, desc);
    }
    cyna_std_free_aligned(payload);
}

static int cyna_std_sync_order(CynaMemoryOrder order) {
    switch (order) {
        case CYNA_MEMORY_ORDER_RELAXED:
            return __ATOMIC_RELAXED;
        case CYNA_MEMORY_ORDER_ACQUIRE:
            return __ATOMIC_ACQUIRE;
        case CYNA_MEMORY_ORDER_RELEASE:
            return __ATOMIC_RELEASE;
        case CYNA_MEMORY_ORDER_ACQ_REL:
            return __ATOMIC_ACQ_REL;
        case CYNA_MEMORY_ORDER_SEQ_CST:
        default:
            return __ATOMIC_SEQ_CST;
    }
}

static int cyna_std_sync_failure_order(CynaMemoryOrder order) {
    switch (order) {
        case CYNA_MEMORY_ORDER_RELEASE:
            return __ATOMIC_RELAXED;
        case CYNA_MEMORY_ORDER_ACQ_REL:
            return __ATOMIC_ACQUIRE;
        default:
            return cyna_std_sync_order(order);
    }
}

CynaMutex cyna_std_sync_mutex_init(void) {
    pthread_mutex_t *mutex = (pthread_mutex_t *)malloc(sizeof(pthread_mutex_t));
    if (mutex == NULL) return (CynaMutex){ .raw = 0 };
    if (pthread_mutex_init(mutex, NULL) != 0) {
        free(mutex);
        return (CynaMutex){ .raw = 0 };
    }
    return (CynaMutex){ .raw = (unsigned long)(uintptr_t)mutex };
}

bool cyna_std_sync_mutex_is_valid(CynaMutex mutex) {
    return mutex.raw != 0;
}

CynaSyncStatus cyna_std_sync_mutex_lock(CynaMutex mutex) {
    pthread_mutex_t *native = (pthread_mutex_t *)(uintptr_t)mutex.raw;
    if (native == NULL) return CYNA_SYNC_INVALID_HANDLE;
    if (pthread_mutex_lock(native) != 0) return CYNA_SYNC_LOCK_FAILED;
    return CYNA_SYNC_OK;
}

CynaSyncStatus cyna_std_sync_mutex_try_lock(CynaMutex mutex) {
    pthread_mutex_t *native = (pthread_mutex_t *)(uintptr_t)mutex.raw;
    if (native == NULL) return CYNA_SYNC_INVALID_HANDLE;
    int rc = pthread_mutex_trylock(native);
    if (rc == 0) return CYNA_SYNC_OK;
    if (rc == EBUSY) return CYNA_SYNC_BUSY;
    return CYNA_SYNC_LOCK_FAILED;
}

CynaSyncStatus cyna_std_sync_mutex_unlock(CynaMutex mutex) {
    pthread_mutex_t *native = (pthread_mutex_t *)(uintptr_t)mutex.raw;
    if (native == NULL) return CYNA_SYNC_INVALID_HANDLE;
    if (pthread_mutex_unlock(native) != 0) return CYNA_SYNC_UNLOCK_FAILED;
    return CYNA_SYNC_OK;
}

CynaSyncStatus cyna_std_sync_mutex_destroy(CynaMutex mutex) {
    pthread_mutex_t *native = (pthread_mutex_t *)(uintptr_t)mutex.raw;
    if (native == NULL) return CYNA_SYNC_INVALID_HANDLE;
    if (pthread_mutex_destroy(native) != 0) return CYNA_SYNC_DESTROY_FAILED;
    free(native);
    return CYNA_SYNC_OK;
}

CynaCondvar cyna_std_sync_condvar_init(void) {
    pthread_cond_t *condvar = (pthread_cond_t *)malloc(sizeof(pthread_cond_t));
    if (condvar == NULL) return (CynaCondvar){ .raw = 0 };
    if (pthread_cond_init(condvar, NULL) != 0) {
        free(condvar);
        return (CynaCondvar){ .raw = 0 };
    }
    return (CynaCondvar){ .raw = (unsigned long)(uintptr_t)condvar };
}

bool cyna_std_sync_condvar_is_valid(CynaCondvar condvar) {
    return condvar.raw != 0;
}

CynaSyncStatus cyna_std_sync_condvar_wait(CynaCondvar condvar, CynaMutex mutex) {
    pthread_cond_t *native_condvar = (pthread_cond_t *)(uintptr_t)condvar.raw;
    pthread_mutex_t *native_mutex = (pthread_mutex_t *)(uintptr_t)mutex.raw;
    if (native_condvar == NULL || native_mutex == NULL) return CYNA_SYNC_INVALID_HANDLE;
    if (pthread_cond_wait(native_condvar, native_mutex) != 0) return CYNA_SYNC_WAIT_FAILED;
    return CYNA_SYNC_OK;
}

CynaSyncStatus cyna_std_sync_condvar_signal(CynaCondvar condvar) {
    pthread_cond_t *native = (pthread_cond_t *)(uintptr_t)condvar.raw;
    if (native == NULL) return CYNA_SYNC_INVALID_HANDLE;
    if (pthread_cond_signal(native) != 0) return CYNA_SYNC_SIGNAL_FAILED;
    return CYNA_SYNC_OK;
}

CynaSyncStatus cyna_std_sync_condvar_broadcast(CynaCondvar condvar) {
    pthread_cond_t *native = (pthread_cond_t *)(uintptr_t)condvar.raw;
    if (native == NULL) return CYNA_SYNC_INVALID_HANDLE;
    if (pthread_cond_broadcast(native) != 0) return CYNA_SYNC_BROADCAST_FAILED;
    return CYNA_SYNC_OK;
}

CynaSyncStatus cyna_std_sync_condvar_destroy(CynaCondvar condvar) {
    pthread_cond_t *native = (pthread_cond_t *)(uintptr_t)condvar.raw;
    if (native == NULL) return CYNA_SYNC_INVALID_HANDLE;
    if (pthread_cond_destroy(native) != 0) return CYNA_SYNC_DESTROY_FAILED;
    free(native);
    return CYNA_SYNC_OK;
}

CynaSharedHandle cyna_std_sync_shared_from_ptr(void *ptr) {
    if (ptr == NULL) return (CynaSharedHandle){ .raw = 0 };
    CynaSharedBox *box = (CynaSharedBox *)malloc(sizeof(CynaSharedBox));
    if (box == NULL) return (CynaSharedHandle){ .raw = 0 };
    if (pthread_mutex_init(&box->mutex, NULL) != 0) {
        free(box);
        return (CynaSharedHandle){ .raw = 0 };
    }
    box->ptr = ptr;
    box->desc = NULL;
    return (CynaSharedHandle){ .raw = (unsigned long)(uintptr_t)box };
}

CynaSharedHandle cyna_std_sync_share_boxed(const void *value, const CynaTypeDesc *desc) {
    if (value == NULL || desc == NULL || desc->size < 0 || desc->align <= 0) {
        return (CynaSharedHandle){ .raw = 0 };
    }
    CynaSharedBox *box = (CynaSharedBox *)malloc(sizeof(CynaSharedBox));
    if (box == NULL) return (CynaSharedHandle){ .raw = 0 };
    if (pthread_mutex_init(&box->mutex, NULL) != 0) {
        free(box);
        return (CynaSharedHandle){ .raw = 0 };
    }

    size_t payload_size = desc->size == 0 ? 1 : (size_t)desc->size;
    void *payload = cyna_std_sync_alloc_payload(payload_size, (size_t)desc->align);
    if (payload == NULL) {
        pthread_mutex_destroy(&box->mutex);
        free(box);
        return (CynaSharedHandle){ .raw = 0 };
    }

    if (desc->copy != NULL) {
        desc->copy(payload, value, desc);
    } else if (desc->size != 0) {
        memcpy(payload, value, (size_t)desc->size);
    }

    box->ptr = payload;
    box->desc = desc;
    return (CynaSharedHandle){ .raw = (unsigned long)(uintptr_t)box };
}

bool cyna_std_sync_shared_is_valid(CynaSharedHandle shared) {
    return shared.raw != 0;
}

CynaSyncStatus cyna_std_sync_shared_lock(CynaSharedHandle shared) {
    CynaSharedBox *box = (CynaSharedBox *)(uintptr_t)shared.raw;
    if (box == NULL) return CYNA_SYNC_INVALID_HANDLE;
    if (pthread_mutex_lock(&box->mutex) != 0) return CYNA_SYNC_LOCK_FAILED;
    return CYNA_SYNC_OK;
}

CynaSyncStatus cyna_std_sync_shared_unlock(CynaSharedHandle shared) {
    CynaSharedBox *box = (CynaSharedBox *)(uintptr_t)shared.raw;
    if (box == NULL) return CYNA_SYNC_INVALID_HANDLE;
    if (pthread_mutex_unlock(&box->mutex) != 0) return CYNA_SYNC_UNLOCK_FAILED;
    return CYNA_SYNC_OK;
}

CynaSyncStatus cyna_std_sync_shared_destroy(CynaSharedHandle shared) {
    CynaSharedBox *box = (CynaSharedBox *)(uintptr_t)shared.raw;
    if (box == NULL) return CYNA_SYNC_INVALID_HANDLE;
    if (pthread_mutex_destroy(&box->mutex) != 0) return CYNA_SYNC_DESTROY_FAILED;
    if (box->desc != NULL) {
        cyna_std_sync_drop_payload(box->ptr, box->desc);
    }
    free(box);
    return CYNA_SYNC_OK;
}

void *cyna_std_sync_shared_ptr(CynaSharedHandle shared) {
    CynaSharedBox *box = (CynaSharedBox *)(uintptr_t)shared.raw;
    if (box == NULL) return NULL;
    return box->ptr;
}

CynaArcHandle cyna_std_sync_arc_new_boxed(const void *value, const CynaTypeDesc *desc) {
    if (value == NULL || desc == NULL || desc->size < 0 || desc->align <= 0) {
        return (CynaArcHandle){ .raw = 0 };
    }
    CynaArcBox *box = (CynaArcBox *)malloc(sizeof(CynaArcBox));
    if (box == NULL) return (CynaArcHandle){ .raw = 0 };

    size_t payload_size = desc->size == 0 ? 1 : (size_t)desc->size;
    void *payload = cyna_std_sync_alloc_payload(payload_size, (size_t)desc->align);
    if (payload == NULL) {
        free(box);
        return (CynaArcHandle){ .raw = 0 };
    }

    if (desc->copy != NULL) {
        desc->copy(payload, value, desc);
    } else if (desc->size != 0) {
        memcpy(payload, value, (size_t)desc->size);
    }

    box->ptr = payload;
    box->desc = desc;
    __atomic_store_n(&box->ref_count, 1UL, __ATOMIC_RELEASE);
    return (CynaArcHandle){ .raw = (unsigned long)(uintptr_t)box };
}

bool cyna_std_sync_arc_is_valid(CynaArcHandle arc) {
    return arc.raw != 0;
}

CynaArcHandle cyna_std_sync_arc_retain(CynaArcHandle arc) {
    CynaArcBox *box = (CynaArcBox *)(uintptr_t)arc.raw;
    if (box == NULL) return (CynaArcHandle){ .raw = 0 };
    __atomic_fetch_add(&box->ref_count, 1UL, __ATOMIC_ACQ_REL);
    return arc;
}

CynaSyncStatus cyna_std_sync_arc_release(CynaArcHandle arc) {
    CynaArcBox *box = (CynaArcBox *)(uintptr_t)arc.raw;
    if (box == NULL) return CYNA_SYNC_INVALID_HANDLE;
    unsigned long previous = __atomic_fetch_sub(&box->ref_count, 1UL, __ATOMIC_ACQ_REL);
    if (previous == 1UL) {
        cyna_std_sync_drop_payload(box->ptr, box->desc);
        free(box);
    }
    return CYNA_SYNC_OK;
}

void *cyna_std_sync_arc_ptr(CynaArcHandle arc) {
    CynaArcBox *box = (CynaArcBox *)(uintptr_t)arc.raw;
    if (box == NULL) return NULL;
    return box->ptr;
}

CynaAtomicI32 cyna_std_sync_atomic_i32_init(int32_t value) {
    int32_t *cell = (int32_t *)malloc(sizeof(int32_t));
    if (cell == NULL) return (CynaAtomicI32){ .raw = 0 };
    __atomic_store_n(cell, value, __ATOMIC_RELAXED);
    return (CynaAtomicI32){ .raw = (unsigned long)(uintptr_t)cell };
}

bool cyna_std_sync_atomic_i32_is_valid_raw(CynaAtomicI32 cell) {
    return cell.raw != 0;
}

CynaSyncStatus cyna_std_sync_atomic_i32_deinit(CynaAtomicI32 cell) {
    int32_t *native = (int32_t *)(uintptr_t)cell.raw;
    if (native == NULL) return CYNA_SYNC_INVALID_HANDLE;
    free(native);
    return CYNA_SYNC_OK;
}

int32_t cyna_std_sync_atomic_i32_load(CynaAtomicI32 cell, CynaMemoryOrder order) {
    int32_t *native = (int32_t *)(uintptr_t)cell.raw;
    if (native == NULL) return 0;
    return __atomic_load_n(native, cyna_std_sync_order(order));
}

CynaSyncStatus cyna_std_sync_atomic_i32_store(CynaAtomicI32 cell, int32_t value, CynaMemoryOrder order) {
    int32_t *native = (int32_t *)(uintptr_t)cell.raw;
    if (native == NULL) return CYNA_SYNC_INVALID_HANDLE;
    __atomic_store_n(native, value, cyna_std_sync_order(order));
    return CYNA_SYNC_OK;
}

int32_t cyna_std_sync_atomic_i32_exchange(CynaAtomicI32 cell, int32_t value, CynaMemoryOrder order) {
    int32_t *native = (int32_t *)(uintptr_t)cell.raw;
    if (native == NULL) return 0;
    return __atomic_exchange_n(native, value, cyna_std_sync_order(order));
}

int32_t cyna_std_sync_atomic_i32_fetch_add(CynaAtomicI32 cell, int32_t value, CynaMemoryOrder order) {
    int32_t *native = (int32_t *)(uintptr_t)cell.raw;
    if (native == NULL) return 0;
    return __atomic_fetch_add(native, value, cyna_std_sync_order(order));
}

bool cyna_std_sync_atomic_i32_compare_exchange(CynaAtomicI32 cell, int32_t expected, int32_t desired, CynaMemoryOrder success, CynaMemoryOrder failure) {
    int32_t *native = (int32_t *)(uintptr_t)cell.raw;
    if (native == NULL) return false;
    return __atomic_compare_exchange_n(native, &expected, desired, false, cyna_std_sync_order(success), cyna_std_sync_failure_order(failure));
}

CynaAtomicUsize cyna_std_sync_atomic_usize_init(size_t value) {
    size_t *cell = (size_t *)malloc(sizeof(size_t));
    if (cell == NULL) return (CynaAtomicUsize){ .raw = 0 };
    __atomic_store_n(cell, value, __ATOMIC_RELAXED);
    return (CynaAtomicUsize){ .raw = (unsigned long)(uintptr_t)cell };
}

bool cyna_std_sync_atomic_usize_is_valid_raw(CynaAtomicUsize cell) {
    return cell.raw != 0;
}

CynaSyncStatus cyna_std_sync_atomic_usize_deinit(CynaAtomicUsize cell) {
    size_t *native = (size_t *)(uintptr_t)cell.raw;
    if (native == NULL) return CYNA_SYNC_INVALID_HANDLE;
    free(native);
    return CYNA_SYNC_OK;
}

size_t cyna_std_sync_atomic_usize_load(CynaAtomicUsize cell, CynaMemoryOrder order) {
    size_t *native = (size_t *)(uintptr_t)cell.raw;
    if (native == NULL) return 0;
    return __atomic_load_n(native, cyna_std_sync_order(order));
}

CynaSyncStatus cyna_std_sync_atomic_usize_store(CynaAtomicUsize cell, size_t value, CynaMemoryOrder order) {
    size_t *native = (size_t *)(uintptr_t)cell.raw;
    if (native == NULL) return CYNA_SYNC_INVALID_HANDLE;
    __atomic_store_n(native, value, cyna_std_sync_order(order));
    return CYNA_SYNC_OK;
}

size_t cyna_std_sync_atomic_usize_exchange(CynaAtomicUsize cell, size_t value, CynaMemoryOrder order) {
    size_t *native = (size_t *)(uintptr_t)cell.raw;
    if (native == NULL) return 0;
    return __atomic_exchange_n(native, value, cyna_std_sync_order(order));
}

size_t cyna_std_sync_atomic_usize_fetch_add(CynaAtomicUsize cell, size_t value, CynaMemoryOrder order) {
    size_t *native = (size_t *)(uintptr_t)cell.raw;
    if (native == NULL) return 0;
    return __atomic_fetch_add(native, value, cyna_std_sync_order(order));
}

bool cyna_std_sync_atomic_usize_compare_exchange(CynaAtomicUsize cell, size_t expected, size_t desired, CynaMemoryOrder success, CynaMemoryOrder failure) {
    size_t *native = (size_t *)(uintptr_t)cell.raw;
    if (native == NULL) return false;
    return __atomic_compare_exchange_n(native, &expected, desired, false, cyna_std_sync_order(success), cyna_std_sync_failure_order(failure));
}

CynaAtomicBool cyna_std_sync_atomic_bool_init(bool value) {
    bool *cell = (bool *)malloc(sizeof(bool));
    if (cell == NULL) return (CynaAtomicBool){ .raw = 0 };
    __atomic_store_n(cell, value, __ATOMIC_RELAXED);
    return (CynaAtomicBool){ .raw = (unsigned long)(uintptr_t)cell };
}

bool cyna_std_sync_atomic_bool_is_valid_raw(CynaAtomicBool cell) {
    return cell.raw != 0;
}

CynaSyncStatus cyna_std_sync_atomic_bool_deinit(CynaAtomicBool cell) {
    bool *native = (bool *)(uintptr_t)cell.raw;
    if (native == NULL) return CYNA_SYNC_INVALID_HANDLE;
    free(native);
    return CYNA_SYNC_OK;
}

bool cyna_std_sync_atomic_bool_load(CynaAtomicBool cell, CynaMemoryOrder order) {
    bool *native = (bool *)(uintptr_t)cell.raw;
    if (native == NULL) return false;
    return __atomic_load_n(native, cyna_std_sync_order(order));
}

CynaSyncStatus cyna_std_sync_atomic_bool_store(CynaAtomicBool cell, bool value, CynaMemoryOrder order) {
    bool *native = (bool *)(uintptr_t)cell.raw;
    if (native == NULL) return CYNA_SYNC_INVALID_HANDLE;
    __atomic_store_n(native, value, cyna_std_sync_order(order));
    return CYNA_SYNC_OK;
}

bool cyna_std_sync_atomic_bool_exchange(CynaAtomicBool cell, bool value, CynaMemoryOrder order) {
    bool *native = (bool *)(uintptr_t)cell.raw;
    if (native == NULL) return false;
    return __atomic_exchange_n(native, value, cyna_std_sync_order(order));
}

bool cyna_std_sync_atomic_bool_compare_exchange(CynaAtomicBool cell, bool expected, bool desired, CynaMemoryOrder success, CynaMemoryOrder failure) {
    bool *native = (bool *)(uintptr_t)cell.raw;
    if (native == NULL) return false;
    return __atomic_compare_exchange_n(native, &expected, desired, false, cyna_std_sync_order(success), cyna_std_sync_failure_order(failure));
}
