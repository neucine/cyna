# std.thread

`std.thread` provides hosted worker threads and structured task groups.

Available on macOS arm64 and Linux x86-64.

```cyna
import { TaskGroup, TaskStatus, Thread, ThreadError } from std.thread;
```

## Types

### `Thread` and `ThreadId`

`Thread` is an owned worker handle. `ThreadId` identifies a worker.

### `ThreadFailure` and `ThreadOutcome`

`ThreadFailure` holds a `code: ThreadError` and the still-owned `handle:
Thread`. `ThreadOutcome` is a union with `settled` and `retry: ThreadFailure`
cases.

### `Task<R>`

Result interest in admitted work. A task result is separate from task
settlement.

### `TaskGroup`

A bounded admission group. It owns the lifecycle operations for admitted work.

### `TaskContext`

Invocation-local authority passed to context-aware task entries.

## Static functions

Call these through the module or the named type.

| Function | Signature | Description |
| --- | --- | --- |
| `spawn` | `fn spawn<T>(entry: fn (T): void, value: T): Thread ! ThreadError` | Starts a worker with owned input. |
| `current_id` | `fn current_id(): ThreadId` | Returns the current thread's identity. |
| `try_join_void` | `fn try_join_void(task: &Task<void>): TaskStatus` | Polls a void task without consuming it while pending. |
| `TaskGroup.init` | `fn init(capacity: u32): TaskGroup ! TaskGroupError` | Creates a group with room for `capacity` admitted tasks. |

## Instance methods

### `Thread`

| Method | Signature | Description |
| --- | --- | --- |
| `id` | `fn id(self: &const Thread): ThreadId` | Returns the worker's identity. |
| `join` | `fn join(self: Thread): ThreadOutcome` | Waits for completion and consumes the handle. |
| `detach` | `fn detach(self: Thread): ThreadOutcome` | Releases the join obligation and consumes the handle. |

### `ThreadId`

| Method | Signature | Description |
| --- | --- | --- |
| `is_valid` | `fn is_valid(self: ThreadId): bool` | Reports whether the identity is valid. |
| `equals` | `fn equals(self: ThreadId, other: ThreadId): bool` | Compares two identities. |

### `Task<R>`

| Method | Signature | Description |
| --- | --- | --- |
| `cancel` | `fn cancel(self: &const Task<R>): TaskStatus` | Requests cooperative cancellation. |
| `join` | `fn join(self: Task<R>): R ! TaskStatus` | Consumes result interest and waits. |
| `try_join` | `fn try_join(self: &Task<R>): ?R ! TaskStatus` | Returns `none` while pending. |
| `discard` | `fn discard(self: Task<R>): TaskStatus` | Releases result interest without cancelling the work. |

### `TaskGroup`

| Method | Signature | Description |
| --- | --- | --- |
| `spawn` | `fn spawn<T, R>(self: &const TaskGroup, entry: fn (T): R, input: T): Task<R> ! TaskStatus` | Consumes owned input and admits a task. |
| `spawn_context` | `fn spawn_context<T, R>(self: &const TaskGroup, entry: fn (&TaskContext, T): R, input: T): Task<R> ! TaskStatus` | Admits a context-aware task. |
| `finish` | `fn finish(self: TaskGroup): void` | Closes admission and waits for admitted work. |
| `cancel_and_wait` | `fn cancel_and_wait(self: TaskGroup): void` | Closes admission, requests cancellation, and waits. |

### `TaskContext`

| Method | Signature | Description |
| --- | --- | --- |
| `spawn` | `fn spawn<T, R>(self: &const TaskContext, entry: fn (&TaskContext, T): R, input: T): Task<R> ! TaskStatus` | Admits a descendant task. |
| `is_cancelled` | `fn is_cancelled(self: &const TaskContext): bool` | Reports whether cancellation was requested. |

## Errors

| Error | Meaning |
| --- | --- |
| `ThreadError.unsupported` | Threads are unavailable on this target or build. |
| `ThreadError.spawn_failed` | The worker could not be started. |
| `ThreadError.join_failed` | Joining the worker failed. |
| `ThreadError.detach_failed` | Detaching the worker failed. |
| `TaskGroupError.invalid_capacity` | The requested capacity is invalid. |
| `TaskGroupError.no_memory` | The group could not allocate its state. |

`TaskStatus` reports task state: `ok`, `invalid`, `closed`, `no_memory`,
`thread_failed`, `pending`, `cancelled`, and `consumed`.

## Example

```cyna
import { TaskGroup } from std.thread;

fn work(value: i32): i32 {
    return value + 1;
}

fn main(): i32 {
    const group = TaskGroup.init(1 as u32) catch (code) {
        return 1;
    };
    const task = group.spawn(work, 41) catch (code) {
        group.cancel_and_wait();
        return 2;
    };
    const value = task.join() catch (code) {
        group.cancel_and_wait();
        return 3;
    };
    group.finish();
    return value;
}
```

Dropping a `Thread` handle does not join, detach, cancel, or stop the worker.
Keep terminal handles in locals. A `.retry` outcome preserves the handle.

See [Concurrency](concurrency.md) for the full lifetime contract.
