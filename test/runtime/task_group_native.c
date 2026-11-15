// Build with: cc -std=c11 -Wall -Wextra -Werror -pthread -I. test/runtime/task_group_native.c packages/std/src/std_task_group.c src/runtime/failure_trace.c -o /tmp/cyna-task-group-test
// Run with: /tmp/cyna-task-group-test
#include "../../packages/std/src/std_task_group.h"
#include <assert.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>

// Zig's default build mode defines NDEBUG; these checks must retain their
// expressions because they drive the fixture as well as verify it.
#undef assert
#define assert(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "task group check failed at %s:%d: %s\n", __FILE__, __LINE__, #condition); \
        abort(); \
    } \
} while (0)

typedef struct {
    int value;
    atomic_int *input_drops;
    atomic_int *entries;
    atomic_bool *gate;
} Input;

typedef struct {
    int value;
} Output;

// Private Cyna-facing boxed bridge, distinct from the raw C API in the header.
typedef struct { unsigned long raw; } BoxedTaskHandle;
typedef struct { int32_t status; BoxedTaskHandle handle; } BoxedTaskSpawn;
extern BoxedTaskSpawn cyna_std_thread_task_group_spawn_boxed(
    unsigned long group_raw, CynaTaskEntry entry, void *entry_ctx,
    void *value, const CynaTypeDesc *input_desc, const CynaTypeDesc *result_desc);

static atomic_int result_drops = 0;

static void drop_input(void *value, const CynaTypeDesc *desc) {
    (void)desc;
    Input *input = value;
    atomic_fetch_add(input->input_drops, 1);
}

static void drop_output(void *value, const CynaTypeDesc *desc) {
    (void)desc;
    (void)value;
    atomic_fetch_add(&result_drops, 1);
}

static const CynaTypeDesc input_desc = {
    .size = sizeof(Input), .align = _Alignof(Input), .drop = drop_input,
};
static const CynaTypeDesc output_desc = {
    .size = sizeof(Output), .align = _Alignof(Output), .drop = drop_output,
};

typedef struct {
    CynaTraceContext *context;
    CynaTraceHandle handle;
    int value;
} TraceOutput;

static void drop_trace_output(void *value, const CynaTypeDesc *desc) {
    (void)desc;
    TraceOutput *result = value;
    if (result->context != NULL) cyna_trace_release(result->context, result->handle);
}

static const CynaTypeDesc trace_output_desc = {
    .size = sizeof(TraceOutput), .align = _Alignof(TraceOutput), .drop = drop_trace_output,
};

static void echo_with_trace(void *entry_ctx, void *raw_input, void *raw_result,
                            const atomic_bool *cancelled, CynaTaskContext *task_context) {
    (void)entry_ctx;
    (void)cancelled;
    Input *input = raw_input;
    TraceOutput *result = raw_result;
    result->context = cyna_std_task_context_trace_context(task_context);
    result->handle = result->context == NULL ? (CynaTraceHandle){0} :
        cyna_trace_create(result->context, 7, (const unsigned char *)"worker", 6);
    result->value = input->value;
    atomic_fetch_add(input->entries, 1);
    drop_input(input, &input_desc);
}

static void echo(void *entry_ctx, void *raw_input, void *raw_result, const atomic_bool *cancelled, CynaTaskContext *task_context) {
    (void)entry_ctx;
    (void)cancelled;
    (void)task_context;
    Input *input = raw_input;
    Output *result = raw_result;
    atomic_fetch_add(input->entries, 1);
    while (input->gate != NULL && !atomic_load(input->gate)) sched_yield();
    result->value = input->value;
    drop_input(input, &input_desc); // Models Cyna's by-value parameter cleanup.
}

static Input *make_input(int value, atomic_int *drops, atomic_int *entries, atomic_bool *gate) {
    Input *input = malloc(sizeof(*input));
    assert(input != NULL);
    *input = (Input){ .value = value, .input_drops = drops, .entries = entries, .gate = gate };
    return input;
}

typedef struct {
    CynaTaskGroup *group;
    atomic_bool done;
} Closing;

static void *cancel_group(void *ctx) {
    Closing *closing = ctx;
    assert(cyna_std_task_group_cancel_and_wait(closing->group) == CYNA_TASK_OK);
    atomic_store(&closing->done, true);
    return NULL;
}

static void *finish_group(void *ctx) {
    Closing *closing = ctx;
    assert(cyna_std_task_group_finish(closing->group) == CYNA_TASK_OK);
    atomic_store(&closing->done, true);
    return NULL;
}

typedef struct {
    atomic_bool started;
    atomic_bool allow_child;
    atomic_bool child_gate;
    atomic_int child_entries;
    atomic_int input_drops;
    atomic_int child_status;
    CynaTask *child;
} DescendantFlow;

static void admit_child(void *entry_ctx, void *raw_input, void *raw_result,
                        const atomic_bool *cancelled, CynaTaskContext *context) {
    (void)cancelled;
    DescendantFlow *flow = entry_ctx;
    Input *parent = raw_input;
    Output *result = raw_result;
    atomic_store(&flow->started, true);
    while (!atomic_load(&flow->allow_child)) sched_yield();
    Input *child_input = make_input(parent->value + 1, &flow->input_drops,
                                    &flow->child_entries, &flow->child_gate);
    CynaTask *child = NULL;
    CynaTaskStatus status = cyna_std_task_group_spawn_child(
        context, echo, NULL, child_input, &input_desc, &output_desc, &child);
    if (status != CYNA_TASK_OK) {
        drop_input(child_input, &input_desc);
        free(child_input);
    }
    flow->child = child;
    atomic_store(&flow->child_status, status);
    result->value = parent->value;
    drop_input(parent, &input_desc);
}

int main(void) {
    atomic_int input_drops = 0;
    atomic_int entries = 0;
    atomic_bool gate = false;
    CynaTaskGroup *group = cyna_std_task_group_new(1);
    assert(group != NULL);

    CynaTask *first = NULL;
    Input *first_input = make_input(41, &input_drops, &entries, &gate);
    assert(cyna_std_task_group_spawn(group, echo, NULL, first_input, &input_desc, &output_desc, &first) == CYNA_TASK_OK);
    while (atomic_load(&entries) == 0) sched_yield();

    CynaTask *queued = NULL;
    Input *queued_input = make_input(42, &input_drops, &entries, NULL);
    assert(cyna_std_task_group_spawn(group, echo, NULL, queued_input, &input_desc, &output_desc, &queued) == CYNA_TASK_OK);
    assert(cyna_std_task_cancel(queued) == CYNA_TASK_OK);
    assert(cyna_std_task_discard(queued) == CYNA_TASK_OK);

    atomic_store(&gate, true);
    assert(cyna_std_task_group_finish(group) == CYNA_TASK_OK);
    assert(atomic_load(&entries) == 1); // Queued cancellation never entered.
    assert(atomic_load(&input_drops) == 2); // Exactly-once input cleanup.
    Output received = {0};
    assert(cyna_std_task_join(first, &received) == CYNA_TASK_OK);
    assert(received.value == 41); // Handle remains valid after group settlement.

    // Failed admission does not steal the input.
    group = cyna_std_task_group_new(1);
    assert(group != NULL);
    assert(cyna_std_task_group_finish(group) == CYNA_TASK_OK);
    // A null group is rejected; the caller still owns this input.
    Input *rejected = make_input(43, &input_drops, &entries, NULL);
    CynaTask *missing = NULL;
    assert(cyna_std_task_group_spawn(NULL, echo, NULL, rejected, &input_desc, &output_desc, &missing) == CYNA_TASK_INVALID);
    drop_input(rejected, &input_desc);
    free(rejected);
    assert(atomic_load(&input_drops) == 3);

    // The Cyna-facing by-value bridge consumes input even when admission fails.
    atomic_int boxed_failure_drops = 0;
    atomic_int boxed_failure_entries = 0;
    Input boxed_rejected = {
        .value = 43, .input_drops = &boxed_failure_drops,
        .entries = &boxed_failure_entries, .gate = NULL,
    };
    BoxedTaskSpawn failed_boxed = cyna_std_thread_task_group_spawn_boxed(
        0, echo, NULL, &boxed_rejected, &input_desc, &output_desc);
    assert(failed_boxed.status == CYNA_TASK_INVALID);
    assert(atomic_load(&boxed_failure_drops) == 1);
    assert(atomic_load(&boxed_failure_entries) == 0);

    // Dropping the result handle neither cancels work nor loses cleanup.
    group = cyna_std_task_group_new(1);
    assert(group != NULL);
    Input *unobserved = make_input(44, &input_drops, &entries, NULL);
    CynaTask *discarded = NULL;
    assert(cyna_std_task_group_spawn(group, echo, NULL, unobserved, &input_desc, &output_desc, &discarded) == CYNA_TASK_OK);
    assert(cyna_std_task_group_finish(group) == CYNA_TASK_OK);
    assert(cyna_std_task_discard(discarded) == CYNA_TASK_OK);
    assert(atomic_load(&result_drops) == 1);
    assert(atomic_load(&entries) == 2);
    assert(atomic_load(&input_drops) == 4);

    // A non-cooperative running entry is not forcibly unwound; closing waits.
    atomic_bool slow_gate = false;
    group = cyna_std_task_group_new(1);
    assert(group != NULL);
    CynaTask *slow = NULL;
    Input *slow_input = make_input(45, &input_drops, &entries, &slow_gate);
    assert(cyna_std_task_group_spawn(group, echo, NULL, slow_input, &input_desc, &output_desc, &slow) == CYNA_TASK_OK);
    while (atomic_load(&entries) != 3) sched_yield();
    Output slow_result = {0};
    assert(cyna_std_task_try_join(slow, &slow_result) == CYNA_TASK_PENDING);
    Closing closing = { .group = group, .done = false };
    pthread_t closer;
    assert(pthread_create(&closer, NULL, cancel_group, &closing) == 0);
    for (int i = 0; i < 1000; i++) sched_yield();
    assert(!atomic_load(&closing.done));
    atomic_store(&slow_gate, true);
    assert(pthread_join(closer, NULL) == 0);
    assert(atomic_load(&closing.done));
    assert(cyna_std_task_join(slow, &slow_result) == CYNA_TASK_OK);
    assert(slow_result.value == 45);
    assert(atomic_load(&input_drops) == 5);

    // The typed Cyna wrapper receives a result allocation without copying or
    // disposing its value; pending polling retains the same handle.
    atomic_bool boxed_gate = false;
    group = cyna_std_task_group_new(1);
    assert(group != NULL);
    CynaTask *boxed = NULL;
    Input *boxed_input = make_input(46, &input_drops, &entries, &boxed_gate);
    assert(cyna_std_task_group_spawn(group, echo, NULL, boxed_input, &input_desc, &output_desc, &boxed) == CYNA_TASK_OK);
    while (atomic_load(&entries) != 4) sched_yield();
    CynaTaskRawJoin polled = cyna_std_task_try_join_boxed(boxed);
    assert(polled.status == CYNA_TASK_PENDING && polled.result == NULL);
    atomic_store(&boxed_gate, true);
    assert(cyna_std_task_group_finish(group) == CYNA_TASK_OK);
    CynaTaskRawJoin joined = cyna_std_task_join_boxed(boxed);
    assert(joined.status == CYNA_TASK_OK && joined.result != NULL);
    assert(((Output *)joined.result)->value == 46);
    cyna_std_task_result_free(joined.result);
    assert(atomic_load(&result_drops) == 1); // Retrieved value was not dropped.
    assert(atomic_load(&input_drops) == 6);

    // Ready polling transfers the boxed result just like a blocking join.
    group = cyna_std_task_group_new(1);
    assert(group != NULL);
    CynaTask *ready_boxed = NULL;
    Input *ready_input = make_input(47, &input_drops, &entries, NULL);
    assert(cyna_std_task_group_spawn(group, echo, NULL, ready_input, &input_desc, &output_desc, &ready_boxed) == CYNA_TASK_OK);
    assert(cyna_std_task_group_finish(group) == CYNA_TASK_OK);
    CynaTaskRawJoin ready_poll = cyna_std_task_try_join_boxed(ready_boxed);
    assert(ready_poll.status == CYNA_TASK_OK && ready_poll.result != NULL);
    assert(((Output *)ready_poll.result)->value == 47);
    cyna_std_task_result_free(ready_poll.result);
    assert(atomic_load(&result_drops) == 1); // The caller owns the transferred value.
    assert(atomic_load(&input_drops) == 7);

    // Graceful finish closes root admission, but a live guest can start a
    // child. Finish must wait for that child even after the parent retires.
    DescendantFlow flow = {
        .allow_child = false, .child_gate = false, .child_entries = 0,
        .input_drops = 0, .child_status = CYNA_TASK_PENDING, .child = NULL,
    };
    group = cyna_std_task_group_new(2);
    assert(group != NULL);
    CynaTask *parent = NULL;
    Input *parent_input = make_input(70, &flow.input_drops, &entries, NULL);
    assert(cyna_std_task_group_spawn(group, admit_child, &flow, parent_input,
                                     &input_desc, &output_desc, &parent) == CYNA_TASK_OK);
    while (!atomic_load(&flow.started)) sched_yield();
    Closing graceful = { .group = group, .done = false };
    assert(pthread_create(&closer, NULL, finish_group, &graceful) == 0);
    for (;;) {
        atomic_int probe_drops = 0;
        atomic_int probe_entries = 0;
        Input *probe = make_input(1, &probe_drops, &probe_entries, NULL);
        CynaTask *probe_task = NULL;
        CynaTaskStatus probe_status = cyna_std_task_group_spawn(
            group, echo, NULL, probe, &input_desc, &output_desc, &probe_task);
        if (probe_status != CYNA_TASK_OK) {
            assert(probe_status == CYNA_TASK_CLOSED);
            drop_input(probe, &input_desc);
            free(probe);
            break;
        }
        Output probe_result = {0};
        assert(cyna_std_task_join(probe_task, &probe_result) == CYNA_TASK_OK);
        assert(probe_result.value == 1);
    }
    assert(!atomic_load(&graceful.done));
    atomic_store(&flow.allow_child, true);
    while (atomic_load(&flow.child_status) == CYNA_TASK_PENDING) sched_yield();
    assert(atomic_load(&flow.child_status) == CYNA_TASK_OK);
    while (atomic_load(&flow.child_entries) == 0) sched_yield();
    Output parent_result = {0};
    assert(cyna_std_task_join(parent, &parent_result) == CYNA_TASK_OK);
    assert(parent_result.value == 70);
    assert(!atomic_load(&graceful.done));
    atomic_store(&flow.child_gate, true);
    assert(pthread_join(closer, NULL) == 0);
    assert(atomic_load(&graceful.done));
    Output child_result = {0};
    assert(cyna_std_task_join(flow.child, &child_result) == CYNA_TASK_OK);
    assert(child_result.value == 71);
    assert(atomic_load(&flow.input_drops) == 2);

    // Cancellation is different from graceful drain: no descendant may be
    // admitted once cancellation begins, even by a still-running parent.
    DescendantFlow stopping = {
        .allow_child = false, .child_gate = false, .child_entries = 0,
        .input_drops = 0, .child_status = CYNA_TASK_PENDING, .child = NULL,
    };
    group = cyna_std_task_group_new(2);
    assert(group != NULL);
    Input *stopping_input = make_input(80, &stopping.input_drops, &entries, NULL);
    assert(cyna_std_task_group_spawn(group, admit_child, &stopping, stopping_input,
                                     &input_desc, &output_desc, &parent) == CYNA_TASK_OK);
    while (!atomic_load(&stopping.started)) sched_yield();
    Closing cancelling = { .group = group, .done = false };
    assert(pthread_create(&closer, NULL, cancel_group, &cancelling) == 0);
    for (;;) {
        atomic_int probe_drops = 0;
        atomic_int probe_entries = 0;
        Input *probe = make_input(1, &probe_drops, &probe_entries, NULL);
        CynaTask *probe_task = NULL;
        CynaTaskStatus probe_status = cyna_std_task_group_spawn(
            group, echo, NULL, probe, &input_desc, &output_desc, &probe_task);
        if (probe_status != CYNA_TASK_OK) {
            assert(probe_status == CYNA_TASK_CLOSED);
            drop_input(probe, &input_desc);
            free(probe);
            break;
        }
        assert(cyna_std_task_discard(probe_task) == CYNA_TASK_OK);
    }
    atomic_store(&stopping.allow_child, true);
    assert(pthread_join(closer, NULL) == 0);
    assert(atomic_load(&cancelling.done));
    assert(atomic_load(&stopping.child_status) == CYNA_TASK_CLOSED);
    assert(stopping.child == NULL);
    assert(atomic_load(&stopping.input_drops) == 2);
    assert(cyna_std_task_join(parent, &parent_result) == CYNA_TASK_OK);
    // The group lease ends at finish, but task interest and the live record
    // keep the context open until the joined result is dropped.
    CynaTraceContext *owned_trace_context = cyna_trace_new();
    assert(owned_trace_context != NULL);
    group = cyna_std_task_group_new(1);
    assert(group != NULL);
    assert(cyna_std_task_group_bind_trace_context(group, owned_trace_context));
    assert(!cyna_std_task_group_bind_trace_context(group, owned_trace_context));
    Input *traced_input = make_input(91, &input_drops, &entries, NULL);
    CynaTask *traced_task = NULL;
    assert(cyna_std_task_group_spawn(group, echo_with_trace, NULL, traced_input,
                                     &input_desc, &trace_output_desc, &traced_task) == CYNA_TASK_OK);
    assert(cyna_std_task_group_finish(group) == CYNA_TASK_OK);
    cyna_trace_release_root(owned_trace_context);
    TraceOutput traced = {0};
    assert(cyna_std_task_join(traced_task, &traced) == CYNA_TASK_OK);
    assert(traced.value == 91 && traced.context == owned_trace_context);
    CynaTraceSnapshot snapshot;
    assert(cyna_trace_snapshot(owned_trace_context, traced.handle, &snapshot));
    assert(snapshot.origin == 7 && snapshot.message_len == 6);
    drop_trace_output(&traced, &trace_output_desc);

    // Discard invokes the result descriptor, releasing the hidden record.
    CynaTraceContext trace_context;
    cyna_trace_init(&trace_context);
    group = cyna_std_task_group_new(1);
    assert(cyna_std_task_group_bind_trace_context(group, &trace_context));
    traced_input = make_input(92, &input_drops, &entries, NULL);
    assert(cyna_std_task_group_spawn(group, echo_with_trace, NULL, traced_input,
                                     &input_desc, &trace_output_desc, &traced_task) == CYNA_TASK_OK);
    assert(cyna_std_task_group_finish(group) == CYNA_TASK_OK);
    assert(cyna_std_task_discard(traced_task) == CYNA_TASK_OK);
    assert(cyna_trace_close(&trace_context));
    return 0;
}
