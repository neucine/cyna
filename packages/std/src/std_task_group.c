#include "std_task_group.h"
#include "std_align.h"
#include <pthread.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

struct CynaTask {
    pthread_mutex_t mutex;
    pthread_cond_t ready;
    atomic_uint refs;
    atomic_bool cancelled;
    atomic_bool entry_live;
    bool terminal;
    bool interest;
    bool result_live;
    CynaTaskEntry entry;
    void *entry_ctx;
    void *input;
    void *result;
    const CynaTypeDesc *input_desc;
    const CynaTypeDesc *result_desc;
    CynaTraceContext *trace_context;
    CynaTaskGroup *group;
    CynaTask *next;
};

struct CynaTaskContext {
    CynaTask *task;
};

typedef enum {
    GROUP_OPEN,
    GROUP_DRAINING,
    GROUP_CANCELLING,
} CynaGroupState;

struct CynaTaskGroup {
    pthread_mutex_t mutex;
    pthread_cond_t changed;
    uint32_t capacity;
    uint32_t running;
    uint32_t outstanding;
    CynaGroupState state;
    CynaTask *tasks;
    CynaTraceContext *trace_context;
};

static bool valid_desc(const CynaTypeDesc *desc) {
    return desc != NULL && desc->size >= 0 && desc->align > 0 &&
           ((uint64_t)desc->align & ((uint64_t)desc->align - 1)) == 0;
}

static void *alloc_box(const CynaTypeDesc *desc) {
    size_t size = desc->size > 0 ? (size_t)desc->size : 1;
    return cyna_std_alloc_aligned(size, (size_t)desc->align);
}

static void drop_box(void *value, const CynaTypeDesc *desc) {
    if (value == NULL) return;
    if (desc != NULL && desc->drop != NULL) desc->drop(value, desc);
    cyna_std_free_aligned(value);
}

static void release_task(CynaTask *task) {
    if (atomic_fetch_sub_explicit(&task->refs, 1, memory_order_acq_rel) != 1) return;
    // The terminal path has either transferred or disposed of every value.
    if (task->trace_context != NULL) cyna_trace_release_lease(task->trace_context);
    pthread_cond_destroy(&task->ready);
    pthread_mutex_destroy(&task->mutex);
    free(task);
}

static void *run_task(void *ctx) {
    CynaTask *task = ctx;
    CynaTaskGroup *group = task->group;
    pthread_mutex_lock(&group->mutex);
    while (group->running >= group->capacity &&
           !atomic_load_explicit(&task->cancelled, memory_order_acquire)) {
        pthread_cond_wait(&group->changed, &group->mutex);
    }
    bool skip = atomic_load_explicit(&task->cancelled, memory_order_acquire);
    if (!skip) group->running++;
    pthread_mutex_unlock(&group->mutex);

    if (!skip) {
        // This store is only for terminal bookkeeping; cancellation is
        // cooperative once the entry has begun.
        CynaTaskContext context = { .task = task };
        atomic_store_explicit(&task->entry_live, true, memory_order_release);
        task->entry(task->entry_ctx, task->input, task->result, &task->cancelled, &context);
        atomic_store_explicit(&task->entry_live, false, memory_order_release);
    }
    if (skip) drop_box(task->input, task->input_desc);
    else cyna_std_free_aligned(task->input); // The entry's by-value parameter consumed the value.
    task->input = NULL;

    pthread_mutex_lock(&task->mutex);
    task->result_live = !skip;
    task->terminal = true;
    if (!task->interest) {
        if (task->result_live) drop_box(task->result, task->result_desc);
        else cyna_std_free_aligned(task->result);
        task->result = NULL;
        task->result_live = false;
    }
    pthread_cond_broadcast(&task->ready);
    pthread_mutex_unlock(&task->mutex);

    pthread_mutex_lock(&group->mutex);
    CynaTask **link = &group->tasks;
    while (*link != task) link = &(*link)->next;
    *link = task->next;
    if (!skip) group->running--;
    pthread_mutex_unlock(&group->mutex);

    // Releasing the execution interest can drop the task's trace lease.
    // Settle must not observe outstanding == 0 until that has happened, or a
    // caller can finish the group and still find a live lease when closing.
    release_task(task); // Release the group's execution interest.

    pthread_mutex_lock(&group->mutex);
    group->outstanding--;
    pthread_cond_broadcast(&group->changed);
    pthread_mutex_unlock(&group->mutex);
    return NULL;
}

CynaTaskGroup *cyna_std_task_group_new(uint32_t capacity) {
    if (capacity == 0) return NULL;
    CynaTaskGroup *group = calloc(1, sizeof(*group));
    if (group == NULL) return NULL;
    if (pthread_mutex_init(&group->mutex, NULL) != 0) { free(group); return NULL; }
    if (pthread_cond_init(&group->changed, NULL) != 0) {
        pthread_mutex_destroy(&group->mutex);
        free(group);
        return NULL;
    }
    group->capacity = capacity;
    return group;
}

bool cyna_std_task_group_bind_trace_context(CynaTaskGroup *group, CynaTraceContext *context) {
    if (group == NULL || context == NULL) return false;
    pthread_mutex_lock(&group->mutex);
    bool bound = group->state == GROUP_OPEN && group->outstanding == 0 &&
                 group->trace_context == NULL && cyna_trace_acquire_lease(context);
    if (bound) group->trace_context = context;
    pthread_mutex_unlock(&group->mutex);
    return bound;
}

CynaTraceContext *cyna_std_task_context_trace_context(const CynaTaskContext *context) {
    if (context == NULL || context->task == NULL ||
        !atomic_load_explicit(&context->task->entry_live, memory_order_acquire)) return NULL;
    return context->task->trace_context;
}

static CynaTaskStatus spawn_in_group(
    CynaTaskGroup *group, CynaTask *parent, CynaTaskEntry entry, void *entry_ctx, void *input,
    const CynaTypeDesc *input_desc, const CynaTypeDesc *result_desc,
    CynaTask **out_task) {
    if (group == NULL || entry == NULL || input == NULL || out_task == NULL ||
        !valid_desc(input_desc) || !valid_desc(result_desc)) return CYNA_TASK_INVALID;
    *out_task = NULL;
    CynaTask *task = calloc(1, sizeof(*task));
    if (task == NULL) return CYNA_TASK_NO_MEMORY;
    task->result = alloc_box(result_desc);
    if (task->result == NULL || pthread_mutex_init(&task->mutex, NULL) != 0) {
        cyna_std_free_aligned(task->result);
        free(task);
        return CYNA_TASK_NO_MEMORY;
    }
    if (pthread_cond_init(&task->ready, NULL) != 0) {
        pthread_mutex_destroy(&task->mutex);
        cyna_std_free_aligned(task->result);
        free(task);
        return CYNA_TASK_NO_MEMORY;
    }
    atomic_init(&task->refs, 2);
    atomic_init(&task->cancelled, false);
    atomic_init(&task->entry_live, false);
    task->interest = true;
    task->entry = entry;
    task->entry_ctx = entry_ctx;
    task->input = input;
    task->input_desc = input_desc;
    task->result_desc = result_desc;
    task->group = group;

    pthread_mutex_lock(&group->mutex);
    if (group->state == GROUP_CANCELLING ||
        (parent == NULL && group->state != GROUP_OPEN) ||
        (parent != NULL && (parent->group != group ||
                            !atomic_load_explicit(&parent->entry_live, memory_order_acquire)))) {
        pthread_mutex_unlock(&group->mutex);
        pthread_cond_destroy(&task->ready);
        pthread_mutex_destroy(&task->mutex);
        cyna_std_free_aligned(task->result);
        free(task);
        return CYNA_TASK_CLOSED;
    }
    task->next = group->tasks;
    if (group->trace_context != NULL && cyna_trace_acquire_lease(group->trace_context)) {
        task->trace_context = group->trace_context;
    }
    group->tasks = task;
    group->outstanding++;
    pthread_t thread;
    if (pthread_create(&thread, NULL, run_task, task) != 0) {
        group->tasks = task->next;
        group->outstanding--;
        if (task->trace_context != NULL) cyna_trace_release_lease(task->trace_context);
        pthread_mutex_unlock(&group->mutex);
        pthread_cond_destroy(&task->ready);
        pthread_mutex_destroy(&task->mutex);
        cyna_std_free_aligned(task->result);
        free(task);
        return CYNA_TASK_THREAD_FAILED;
    }
    pthread_detach(thread);
    pthread_mutex_unlock(&group->mutex);
    *out_task = task;
    return CYNA_TASK_OK;
}

CynaTaskStatus cyna_std_task_group_spawn(
    CynaTaskGroup *group, CynaTaskEntry entry, void *entry_ctx, void *input,
    const CynaTypeDesc *input_desc, const CynaTypeDesc *result_desc,
    CynaTask **out_task) {
    return spawn_in_group(group, NULL, entry, entry_ctx, input, input_desc, result_desc, out_task);
}

CynaTaskStatus cyna_std_task_group_spawn_child(
    CynaTaskContext *context, CynaTaskEntry entry, void *entry_ctx, void *input,
    const CynaTypeDesc *input_desc, const CynaTypeDesc *result_desc,
    CynaTask **out_task) {
    if (context == NULL || context->task == NULL) return CYNA_TASK_INVALID;
    CynaTask *parent = context->task;
    return spawn_in_group(parent->group, parent, entry, entry_ctx, input, input_desc, result_desc, out_task);
}

bool cyna_std_task_context_is_cancelled(const CynaTaskContext *context) {
    return context != NULL && context->task != NULL &&
           atomic_load_explicit(&context->task->cancelled, memory_order_acquire);
}

static CynaTaskStatus settle_group(CynaTaskGroup *group, bool cancel) {
    if (group == NULL) return CYNA_TASK_INVALID;
    pthread_mutex_lock(&group->mutex);
    group->state = cancel ? GROUP_CANCELLING : GROUP_DRAINING;
    if (cancel) {
        for (CynaTask *task = group->tasks; task != NULL; task = task->next) {
            atomic_store_explicit(&task->cancelled, true, memory_order_release);
        }
        pthread_cond_broadcast(&group->changed);
    }
    while (group->outstanding != 0) pthread_cond_wait(&group->changed, &group->mutex);
    pthread_mutex_unlock(&group->mutex);
    if (group->trace_context != NULL) cyna_trace_release_lease(group->trace_context);
    pthread_cond_destroy(&group->changed);
    pthread_mutex_destroy(&group->mutex);
    free(group);
    return CYNA_TASK_OK;
}

CynaTaskStatus cyna_std_task_group_finish(CynaTaskGroup *group) {
    return settle_group(group, false);
}

CynaTaskStatus cyna_std_task_group_cancel_and_wait(CynaTaskGroup *group) {
    return settle_group(group, true);
}

CynaTaskStatus cyna_std_task_cancel(CynaTask *task) {
    if (task == NULL) return CYNA_TASK_INVALID;
    pthread_mutex_lock(&task->mutex);
    if (!task->interest) { pthread_mutex_unlock(&task->mutex); return CYNA_TASK_CONSUMED; }
    if (!task->terminal) {
        atomic_store_explicit(&task->cancelled, true, memory_order_release);
        // A nonterminal task keeps the group alive. Keep the task lock until
        // after the wakeup so settlement cannot free the group under us.
        CynaTaskGroup *group = task->group;
        pthread_mutex_lock(&group->mutex);
        pthread_cond_broadcast(&group->changed);
        pthread_mutex_unlock(&group->mutex);
    }
    pthread_mutex_unlock(&task->mutex);
    return CYNA_TASK_OK;
}

static CynaTaskStatus receive_task(CynaTask *task, void *out_result, bool wait) {
    if (task == NULL || out_result == NULL) return CYNA_TASK_INVALID;
    pthread_mutex_lock(&task->mutex);
    if (!task->interest) { pthread_mutex_unlock(&task->mutex); return CYNA_TASK_CONSUMED; }
    while (wait && !task->terminal) pthread_cond_wait(&task->ready, &task->mutex);
    if (!task->terminal) { pthread_mutex_unlock(&task->mutex); return CYNA_TASK_PENDING; }
    task->interest = false;
    CynaTaskStatus status = task->result_live ? CYNA_TASK_OK : CYNA_TASK_CANCELLED;
    if (task->result_live) {
        if (task->result_desc->size > 0) memcpy(out_result, task->result, (size_t)task->result_desc->size);
        task->result_live = false;
    }
    cyna_std_free_aligned(task->result);
    task->result = NULL;
    pthread_mutex_unlock(&task->mutex);
    release_task(task);
    return status;
}

CynaTaskStatus cyna_std_task_try_join(CynaTask *task, void *out_result) {
    return receive_task(task, out_result, false);
}

CynaTaskStatus cyna_std_task_join(CynaTask *task, void *out_result) {
    return receive_task(task, out_result, true);
}

CynaTaskStatus cyna_std_task_discard(CynaTask *task) {
    if (task == NULL) return CYNA_TASK_INVALID;
    pthread_mutex_lock(&task->mutex);
    if (!task->interest) { pthread_mutex_unlock(&task->mutex); return CYNA_TASK_CONSUMED; }
    task->interest = false;
    if (task->terminal) {
        if (task->result_live) drop_box(task->result, task->result_desc);
        else cyna_std_free_aligned(task->result);
        task->result = NULL;
        task->result_live = false;
    }
    pthread_mutex_unlock(&task->mutex);
    release_task(task);
    return CYNA_TASK_OK;
}

static CynaTaskRawJoin receive_boxed(CynaTask *task, bool wait) {
    if (task == NULL) return (CynaTaskRawJoin){ .status = CYNA_TASK_INVALID };
    pthread_mutex_lock(&task->mutex);
    if (!task->interest) {
        pthread_mutex_unlock(&task->mutex);
        return (CynaTaskRawJoin){ .status = CYNA_TASK_CONSUMED };
    }
    while (wait && !task->terminal) pthread_cond_wait(&task->ready, &task->mutex);
    if (!task->terminal) {
        pthread_mutex_unlock(&task->mutex);
        return (CynaTaskRawJoin){ .status = CYNA_TASK_PENDING };
    }
    task->interest = false;
    void *result = task->result;
    task->result = NULL;
    CynaTaskStatus status = task->result_live ? CYNA_TASK_OK : CYNA_TASK_CANCELLED;
    task->result_live = false;
    pthread_mutex_unlock(&task->mutex);
    if (status != CYNA_TASK_OK) { cyna_std_free_aligned(result); result = NULL; }
    release_task(task);
    return (CynaTaskRawJoin){ .status = status, .result = result };
}

CynaTaskRawJoin cyna_std_task_join_boxed(CynaTask *task) {
    return receive_boxed(task, true);
}

CynaTaskRawJoin cyna_std_task_try_join_boxed(CynaTask *task) {
    return receive_boxed(task, false);
}

void cyna_std_task_result_free(void *result) { cyna_std_free_aligned(result); }

typedef struct { unsigned long raw; } CynaTaskGroupHandle;
typedef struct {
    uint8_t is_ok;
    CynaTaskGroupHandle ok;
    int32_t err;
} CynaResultTaskGroupTaskGroupError;

CynaResultTaskGroupTaskGroupError cyna_std_thread_task_group_init_raw(uint32_t capacity) {
    if (capacity == 0) return (CynaResultTaskGroupTaskGroupError){ .is_ok = 1, .err = 0 };
    CynaTaskGroup *group = cyna_std_task_group_new(capacity);
    if (group == NULL) return (CynaResultTaskGroupTaskGroupError){ .is_ok = 1, .err = 1 };
    return (CynaResultTaskGroupTaskGroupError){ .is_ok = 0, .ok = { .raw = (unsigned long)(uintptr_t)group } };
}

typedef struct { unsigned long raw; } CynaTaskHandle;
typedef struct {
    int32_t status;
    CynaTaskHandle handle;
} CynaTaskSpawnHandle;

// This Cyna-facing primitive consumes the by-value input on every outcome.
// A successful admission moves its bits into owned heap storage; a rejected
// admission destroys the source value before returning the error.
CynaTaskSpawnHandle cyna_std_thread_task_group_spawn_boxed(
    unsigned long group_raw, CynaTaskEntry entry, void *entry_ctx,
    void *value, const CynaTypeDesc *input_desc, const CynaTypeDesc *result_desc) {
    if (value == NULL || !valid_desc(input_desc)) return (CynaTaskSpawnHandle){ .status = CYNA_TASK_INVALID };
    if (entry == NULL || !valid_desc(result_desc) || group_raw == 0) {
        if (input_desc->drop != NULL) input_desc->drop(value, input_desc);
        return (CynaTaskSpawnHandle){ .status = CYNA_TASK_INVALID };
    }
    void *owned = alloc_box(input_desc);
    if (owned == NULL) {
        if (input_desc->drop != NULL) input_desc->drop(value, input_desc);
        return (CynaTaskSpawnHandle){ .status = CYNA_TASK_NO_MEMORY };
    }
    if (input_desc->size > 0) memcpy(owned, value, (size_t)input_desc->size);
    CynaTask *task = NULL;
    CynaTaskStatus status = cyna_std_task_group_spawn(
        (CynaTaskGroup *)(uintptr_t)group_raw, entry, entry_ctx,
        owned, input_desc, result_desc, &task);
    if (status != CYNA_TASK_OK) {
        drop_box(owned, input_desc);
        return (CynaTaskSpawnHandle){ .status = status };
    }
    return (CynaTaskSpawnHandle){ .status = CYNA_TASK_OK, .handle = { .raw = (unsigned long)(uintptr_t)task } };
}

CynaTaskSpawnHandle cyna_std_thread_task_context_spawn_boxed(
    void *context_raw, CynaTaskEntry entry, void *entry_ctx,
    void *value, const CynaTypeDesc *input_desc, const CynaTypeDesc *result_desc) {
    if (value == NULL || !valid_desc(input_desc)) return (CynaTaskSpawnHandle){ .status = CYNA_TASK_INVALID };
    if (entry == NULL || !valid_desc(result_desc) || context_raw == NULL) {
        if (input_desc->drop != NULL) input_desc->drop(value, input_desc);
        return (CynaTaskSpawnHandle){ .status = CYNA_TASK_INVALID };
    }
    void *owned = alloc_box(input_desc);
    if (owned == NULL) {
        if (input_desc->drop != NULL) input_desc->drop(value, input_desc);
        return (CynaTaskSpawnHandle){ .status = CYNA_TASK_NO_MEMORY };
    }
    if (input_desc->size > 0) memcpy(owned, value, (size_t)input_desc->size);
    CynaTask *task = NULL;
    CynaTaskStatus status = cyna_std_task_group_spawn_child(
        context_raw, entry, entry_ctx, owned, input_desc, result_desc, &task);
    if (status != CYNA_TASK_OK) {
        drop_box(owned, input_desc);
        return (CynaTaskSpawnHandle){ .status = status };
    }
    return (CynaTaskSpawnHandle){ .status = CYNA_TASK_OK, .handle = { .raw = (unsigned long)(uintptr_t)task } };
}

bool cyna_std_thread_task_context_is_cancelled_raw(void *context_raw) {
    return cyna_std_task_context_is_cancelled(context_raw);
}

void cyna_std_thread_task_group_finish_raw(CynaTaskGroupHandle handle) {
    if (cyna_std_task_group_finish((CynaTaskGroup *)(uintptr_t)handle.raw) != CYNA_TASK_OK) abort();
}

void cyna_std_thread_task_group_cancel_and_wait_raw(CynaTaskGroupHandle handle) {
    if (cyna_std_task_group_cancel_and_wait((CynaTaskGroup *)(uintptr_t)handle.raw) != CYNA_TASK_OK) abort();
}

typedef struct {
    int32_t status;
    void *result;
} CynaTaskJoinHandle;

CynaTaskJoinHandle cyna_std_thread_task_join_raw(CynaTaskHandle handle) {
    CynaTaskRawJoin value = cyna_std_task_join_boxed((CynaTask *)(uintptr_t)handle.raw);
    return (CynaTaskJoinHandle){ .status = value.status, .result = value.result };
}

CynaTaskJoinHandle cyna_std_thread_task_try_join_raw(CynaTaskHandle handle) {
    CynaTaskRawJoin value = cyna_std_task_try_join_boxed((CynaTask *)(uintptr_t)handle.raw);
    return (CynaTaskJoinHandle){ .status = value.status, .result = value.result };
}

int32_t cyna_std_thread_task_cancel_raw(CynaTaskHandle handle) {
    return cyna_std_task_cancel((CynaTask *)(uintptr_t)handle.raw);
}

int32_t cyna_std_thread_task_discard_raw(CynaTaskHandle handle) {
    return cyna_std_task_discard((CynaTask *)(uintptr_t)handle.raw);
}

void cyna_std_thread_task_result_free_raw(void *result) {
    cyna_std_task_result_free(result);
}
