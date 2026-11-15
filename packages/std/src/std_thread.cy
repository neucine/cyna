pub c enum ThreadError: i32 {
    unsupported = 0,
    spawn_failed,
    join_failed,
    detach_failed,
}

pub enum TaskGroupError: i32 {
    invalid_capacity = 0,
    no_memory,
}

pub c enum TaskStatus: i32 {
    ok = 0,
    invalid,
    closed,
    no_memory,
    thread_failed,
    pending,
    cancelled,
    consumed,
}

pub c struct TaskHandle {
    raw: c_ulong;
}

pub c struct TaskJoinRaw {
    status: TaskStatus;
    result: *c_void;
}

pub struct Task<R> {
    handle: TaskHandle;

    // A request, not a join or a TaskGroup settlement.
    pub fn cancel(self: &const Task<R>): TaskStatus {
        return task_cancel_raw(self.handle);
    }

    // Consumes result interest. The owning group may already be settled.
    pub fn join(self: Task<R>): R ! TaskStatus {
        const joined = task_join_raw(self.handle);
        self.handle.raw = 0;
        if joined.status != TaskStatus.ok {
            throw joined.status;
        }
        return task_result_take_impl(self, joined.result);
    }

    // Pending leaves this mutable handle intact; completion consumes it.
    pub fn try_join(self: &Task<R>): ?R ! TaskStatus {
        const joined = task_try_join_raw(self.handle);
        if joined.status == TaskStatus.pending {
            return none;
        }
        self.handle.raw = 0;
        if joined.status != TaskStatus.ok {
            throw joined.status;
        }
        unchecked {
            const value = *(joined.result as! *R);
            task_result_free_raw(joined.result);
            const present: ?R = value;
            return present;
        }
    }

    // Release interest without requesting cancellation of the execution.
    pub fn discard(self: Task<R>): TaskStatus {
        const status = task_discard_raw(self.handle);
        self.handle.raw = 0;
        return status;
    }
}

// Poll a void task. Pending retains result interest; a terminal status consumes it.
// The exact Task<void> parameter prevents discarding a non-void result here.
pub fn try_join_void(task: &Task<void>): TaskStatus {
    const joined = task_try_join_raw(task.handle);
    if joined.status == TaskStatus.pending {
        return TaskStatus.pending;
    }
    task.handle.raw = 0;
    if joined.status == TaskStatus.ok {
        task_result_free_raw(joined.result);
    }
    return joined.status;
}

// Experimental owned-work owner. Callers explicitly finish or cancel work
// according to the library protocol; ownership checks do not settle work.
pub c struct TaskGroup {
    raw: c_ulong;

    // Consumes owned input; failed admission destroys it.
    pub fn spawn<T, R>(self: &const TaskGroup, entry: fn (T): R, input: T): Task<R>!TaskStatus {
        const raw = group_spawn_impl(self.raw, entry, input);
        if raw.status != TaskStatus.ok {
            throw raw.status;
        }
        return Task<R> {
            handle: raw.handle
        };
    }

    // Context-aware entry for recursive guest work. This remains a distinct
    // spelling until the two entry shapes can share one overload safely.
    pub fn spawn_context<T, R>(self: &const TaskGroup, entry: fn (&TaskContext, T): R, input: T): Task<R>!TaskStatus {
        const raw = group_spawn_context_impl(self.raw, entry, input);
        if raw.status != TaskStatus.ok {
            throw raw.status;
        }
        return Task<R> {
            handle: raw.handle
        };
    }

    pub fn init(capacity: u32): TaskGroup ! TaskGroupError {
        return try task_group_init_raw(capacity);
    }

    // Terminal operation: close admission and wait for admitted work.
    pub fn finish(self: TaskGroup): void {
        task_group_finish_raw(self);
    }

    // Terminal operation: request cancellation, then wait for retirement.
    pub fn cancel_and_wait(self: TaskGroup): void {
        task_group_cancel_and_wait_raw(self);
    }
}

pub c struct ThreadId {
    raw: c_ulong;

    pub fn is_valid(self: ThreadId): bool {
        return thread_id_is_valid(self);
    }

    pub fn equals(self: ThreadId, other: ThreadId): bool {
        return thread_id_equals(self, other);
    }
}

@ownership.owned
pub c struct Thread {
    raw: c_ulong;

    pub fn id(self: &const Thread): ThreadId {
        return ThreadId {
            raw: self.raw
        };
    }

    pub fn join(self: Thread): ThreadOutcome {
        const raw = join(self);
        if raw.settled {
            return .settled;
        }
        return .retry(ThreadFailure {
            code: raw.code,
            handle: raw.handle
        });
    }

    pub fn detach(self: Thread): ThreadOutcome {
        const raw = detach(self);
        if raw.settled {
            return .settled;
        }
        return .retry(ThreadFailure {
            code: raw.code,
            handle: raw.handle
        });
    }
}

pub c struct ThreadFailure {
    pub code: ThreadError;
    pub handle: Thread;
}

pub union ThreadOutcome {
    settled;
    retry: ThreadFailure;
}

pub c struct ThreadOpRaw {
    settled: bool;
    code: ThreadError;
    handle: Thread;
}

type RawEntry = c fn (*c_void): void;
type BoxedEntry = c fn (*c_void): void;
type BoxedTaskEntry = c fn (*c_void, *c_void, *c_void, *c_void, *c_void): void;

pub c struct TaskSpawnRaw {
    status: TaskStatus;
    handle: TaskHandle;
}

// Invocation-local authority. Only the runtime trampoline constructs this;
// entries may borrow it but cannot move the borrow into owned child input.
pub c struct TaskContext {
    raw: *c_void;

    pub fn spawn<T, R>(self: &const TaskContext, entry: fn (&TaskContext, T): R, input: T): Task<R>!TaskStatus {
        const raw = task_context_spawn_impl(self.raw, entry, input);
        if raw.status != TaskStatus.ok {
            throw raw.status;
        }
        return Task<R> {
            handle: raw.handle
        };
    }

    pub fn is_cancelled(self: &const TaskContext): bool {
        return task_context_is_cancelled_raw(self.raw);
    }
}

extern c fn spawn_raw(entry: RawEntry, ctx: *c_void): Thread ! ThreadError;
extern c fn task_group_init_raw(capacity: u32): TaskGroup ! TaskGroupError;
extern c fn task_group_finish_raw(group: TaskGroup): void;
extern c fn task_group_cancel_and_wait_raw(group: TaskGroup): void;
extern c fn task_group_spawn_boxed(group_raw: c_ulong, entry: BoxedTaskEntry, entry_ctx: *c_void, value: *c_void, input_desc: *c_void, result_desc: *c_void): TaskSpawnRaw;
extern c fn task_context_spawn_boxed(context_raw: *c_void, entry: BoxedTaskEntry, entry_ctx: *c_void, value: *c_void, input_desc: *c_void, result_desc: *c_void): TaskSpawnRaw;
extern c fn task_context_is_cancelled_raw(context_raw: *c_void): bool;
extern c fn task_cancel_raw(handle: TaskHandle): TaskStatus;
extern c fn task_join_raw(handle: TaskHandle): TaskJoinRaw;
extern c fn task_try_join_raw(handle: TaskHandle): TaskJoinRaw;
extern c fn task_discard_raw(handle: TaskHandle): TaskStatus;
extern c fn task_result_free_raw(result: *c_void): void;
extern c fn unsupported(): Thread ! ThreadError;
extern c fn spawn_i32(entry: fn (i32): void, value: i32): Thread ! ThreadError;
extern c fn spawn_boxed(entry: BoxedEntry, value: *c_void, desc: *c_void): Thread ! ThreadError;
extern c fn current_id_raw(): ThreadId;
extern c fn thread_id_raw(thread: Thread): ThreadId;
extern c fn thread_id_is_valid(id: ThreadId): bool;
extern c fn thread_id_equals(lhs: ThreadId, rhs: ThreadId): bool;
extern c fn join(thread: Thread): ThreadOpRaw;
extern c fn detach(thread: Thread): ThreadOpRaw;

fn group_spawn_impl<T, R>(group_raw: c_ulong, entry: fn (T): R, input: T): TaskSpawnRaw {
    const ignored_group = group_raw;
    const ignored_entry = entry;
    const ignored_input = input;
    return TaskSpawnRaw {
        status: TaskStatus.invalid,
        handle: TaskHandle {
            raw: 0
        }
    };
}

fn group_spawn_context_impl<T, R>(group_raw: c_ulong, entry: fn (&TaskContext, T): R, input: T): TaskSpawnRaw {
    const ignored_group = group_raw;
    const ignored_entry = entry;
    const ignored_input = input;
    return TaskSpawnRaw {
        status: TaskStatus.invalid,
        handle: TaskHandle {
            raw: 0
        }
    };
}

fn task_context_spawn_impl<T, R>(context_raw: *c_void, entry: fn (&TaskContext, T): R, input: T): TaskSpawnRaw {
    const ignored_context = context_raw;
    const ignored_entry = entry;
    const ignored_input = input;
    return TaskSpawnRaw {
        status: TaskStatus.invalid,
        handle: TaskHandle {
            raw: 0
        }
    };
}

fn task_result_take_impl<R>(task: Task<R>, result: *c_void): R ! TaskStatus {
    const ignored_task = task;
    const ignored = result;
    throw TaskStatus.invalid;
}

pub fn current_id(): ThreadId {
    return current_id_raw();
}

pub fn spawn<T>(entry: fn (T): void, value: T): Thread ! ThreadError {
    const ignored_entry = entry;
    const ignored_value = value;
    return unsupported();
}
