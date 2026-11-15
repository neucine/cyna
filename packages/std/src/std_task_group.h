#ifndef CYNA_STD_TASK_GROUP_H
#define CYNA_STD_TASK_GROUP_H

#include "../../../src/runtime/cyna.h"
#include "../../../src/runtime/failure_trace.h"
#include <stdbool.h>
#include <stdint.h>
#include <stdatomic.h>

typedef struct CynaTaskGroup CynaTaskGroup;
typedef struct CynaTask CynaTask;
typedef struct CynaTaskContext CynaTaskContext;

// The entry writes a fully initialized result when it returns normally.
// It may inspect cancellation, but never owns the group or task handle.
typedef void (*CynaTaskEntry)(void *entry_ctx, void *input, void *result, const atomic_bool *cancelled, CynaTaskContext *task_context);

typedef enum {
    CYNA_TASK_OK = 0,
    CYNA_TASK_INVALID = 1,
    CYNA_TASK_CLOSED = 2,
    CYNA_TASK_NO_MEMORY = 3,
    CYNA_TASK_THREAD_FAILED = 4,
    CYNA_TASK_PENDING = 5,
    CYNA_TASK_CANCELLED = 6,
    CYNA_TASK_CONSUMED = 7,
} CynaTaskStatus;

// A successful spawn transfers input ownership to the task. On failure the
// caller retains input and must dispose of it. Descriptors must outlive work.
CynaTaskGroup *cyna_std_task_group_new(uint32_t capacity);
// Internal trace binding. Call before the first admission. A failed binding
// leaves the group usable with code-only failures.
bool cyna_std_task_group_bind_trace_context(CynaTaskGroup *group, CynaTraceContext *context);
CynaTaskStatus cyna_std_task_group_spawn(
    CynaTaskGroup *group, CynaTaskEntry entry, void *entry_ctx, void *input,
    const CynaTypeDesc *input_desc, const CynaTypeDesc *result_desc,
    CynaTask **out_task);
// task_context is valid only during the entry invocation. A live entry may
// admit children while its group is draining, but never while cancelling.
CynaTaskStatus cyna_std_task_group_spawn_child(
    CynaTaskContext *task_context, CynaTaskEntry entry, void *entry_ctx, void *input,
    const CynaTypeDesc *input_desc, const CynaTypeDesc *result_desc,
    CynaTask **out_task);
bool cyna_std_task_context_is_cancelled(const CynaTaskContext *task_context);
CynaTraceContext *cyna_std_task_context_trace_context(const CynaTaskContext *task_context);

// Both operations block until all admitted work has retired. The group is
// consumed and freed on return; neither operation silently runs on drop.
CynaTaskStatus cyna_std_task_group_finish(CynaTaskGroup *group);
CynaTaskStatus cyna_std_task_group_cancel_and_wait(CynaTaskGroup *group);

// A task handle owns result interest, independent of the group's lifetime.
CynaTaskStatus cyna_std_task_cancel(CynaTask *task);
CynaTaskStatus cyna_std_task_try_join(CynaTask *task, void *out_result);
CynaTaskStatus cyna_std_task_join(CynaTask *task, void *out_result);
CynaTaskStatus cyna_std_task_discard(CynaTask *task);

typedef struct {
    CynaTaskStatus status;
    void *result;
} CynaTaskRawJoin;

// A successful raw join transfers the initialized result allocation to the
// caller. Free the allocation without running its value destructor after
// moving the result into Cyna storage.
CynaTaskRawJoin cyna_std_task_join_boxed(CynaTask *task);
CynaTaskRawJoin cyna_std_task_try_join_boxed(CynaTask *task);
void cyna_std_task_result_free(void *result);

#endif
