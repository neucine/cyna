# Cyna Concurrency

This document is the authority for Cyna's current concurrency contract. The
language's ordinary ownership, alias, and cleanup rules remain defined in
[SPEC.md](spec.md) and [SEMANTICS.md](semantics.md). This page states what the
hosted `std.thread` and `std.sync` APIs mean, what the compiler checks at their
execution boundaries, and the limits of the hosted task facilities. Availability
and gaps are summarized in [STATUS.md](status.md).

## Availability and execution boundaries

`std.thread` and `std.sync` currently ship for `aarch64-apple-darwin`.
Their target scope is recorded in `STATUS.md`; selecting a target without those
modules is rejected during import resolution. Freestanding concurrency requires
a separate board and runtime contract. `volatile` access is not thread
synchronization.

A call to `std.thread.spawn`, `TaskGroup.spawn`, `TaskGroup.spawn_context`, or
`TaskContext.spawn` starts independently progressing work. The compiler checks
the entrypoint and its statically reachable calls for unsynchronized mutable
resources and opaque unsafe boundaries. It also checks the transferred input
and result types. This is an inferred, compiler-recognized boundary: ordinary
named entrypoints need no declaration annotation when the checker can prove
their reachable behavior safe. An unchecked foreign boundary requires explicit
authority from a trusted compiler or standard-library declaration.

Borrowed references, slices, and raw pointers cannot be ordinary owned inputs
to detached-capable work. A worker may outlive the caller's frame. Thread-safe
synchronization handles and supported shared resources can cross the boundary;
an ordinary mutable library container or a nested unsafe resource cannot.
Owned dense `[:]T` and sparse `[;]T` storage can move by value when `T` is
transferable; their borrowed slice views cannot. Moving owned storage does not
make it safe to share mutable access to that storage across workers. Copying a
string may share immutable backing, which the runtime retains safely across
hosted threads. A check at one boundary does not make arbitrary foreign code or
another execution boundary safe.
An immutable module-global string literal, including one in a static struct,
can be copied into a worker through local value aliases; those aliases and the
global remain readable after the worker input is copied. Top-level bindings
must be declarative and copy-valued, so a top-level named union value is
rejected before the concurrency boundary check.
Named unions can cross a boundary when every case payload is transferable;
one borrowed or raw-pointer case makes the whole union ineligible.

## Task APIs for day-to-day work

The hosted `std.thread` module also exposes `TaskGroup`, `Task<R>`, and
`TaskContext`. They are the task-oriented API for hosted work and are separate
from the low-level `Thread` handle. The owned-input subset described here is
stable on the supported hosted target. Other transfer forms are outside this
contract until they have explicit ownership rules and test coverage.

The ordinary flow is to create a `TaskGroup`, submit owned input, keep a
`Task<R>` when its result matters, and explicitly settle the group with
`finish()` or `cancel_and_wait()` before releasing state used by its work.
`Task<R>.join()` retrieves a result; it does not settle the group. Keep the
group handle in the scope that performs its terminal wait, and pass work data
or identities into other owners.
Each direct local `join()` or `discard()` consumes its task handle, and a
second terminal call on that local is rejected. Direct local `finish()` or
`cancel_and_wait()` likewise makes that group local unavailable. Consume a
task or group handle from a local rather than a struct field or indexed place;
keep data or IDs in an aggregate when the handle needs a separate lifetime.
The compiler does not require group settlement on every control-flow path.

The supported task path is to transfer owned, thread-safe input and retrieve
owned results. Scalars, immutable strings, transferable structs and unions,
and owned dense or sparse storage with transferable elements are covered by
the current checks. An owned `Task<R>` can travel inside owned storage when
the application moves it out to a local before joining or discarding it.
Borrowed references and views, raw pointers, and unsynchronized mutable
resources cannot cross the worker boundary as ordinary input. A terminal
task or group handle stored in a field or indexed place cannot be consumed
there; keep that handle in a local and pass data or IDs through the aggregate.
Applications that need shared mutable state can use the supported `std.sync`
handles and protected containers described below.

| Operation | Current effect |
| --- | --- |
| `TaskGroup.init(capacity)` | Create a group that owns admitted executions. |
| `group.spawn(entry, input)` | Consume owned input for a `fn(T): R` entry and return `Task<R>!TaskStatus`; failed admission destroys the input. |
| `group.spawn_context(entry, input)` | Consume owned input for a `fn(&TaskContext, T): R` entry with an invocation-local borrowed context; failed admission destroys the input. |
| `context.spawn(entry, input)` | Consume owned input for a descendant while the group is open or gracefully draining; failed admission destroys the input. |
| `group.finish()` | Consume the group, close root admission, and wait for all admitted work and live descendants. |
| `group.cancel_and_wait()` | Consume the group, close admission, request cancellation, and wait for admitted work to retire. |
| `task.join()` | Consume result interest and return `R!TaskStatus`, preserving the entry's exact `R`. |
| `task.try_join()` | Return `?R!TaskStatus`; a pending result leaves the mutable task handle intact. |
| `try_join_void(&task)` | Poll `Task<void>`; return `pending` without consuming it, or consume it and return the terminal `TaskStatus`. |
| `task.cancel()` | Request cancellation without settling the group or promising prompt interruption. |
| `task.discard()` | Release result interest without cancelling the execution or settling its group. |

This result-carrying example is exercised by the native execution suite:

```cyna
import { TaskGroup } from std.thread;

fn worker(value: i32): i32 {
    return value + 1;
}

fn main(): i32 {
    const group = TaskGroup.init(2 as u32) catch (code) { return 4; };
    const task = group.spawn(worker, 41) catch (code) {
        group.cancel_and_wait();
        return 3;
    };
    const value = task.join() catch (code) {
        group.cancel_and_wait();
        return 2;
    };
    group.finish();
    return value;
}
```

An entry returning `T!E` keeps its application error category distinct from
task-level `TaskStatus`. A task handle owns
interest in one result, while the group owns the execution. Dropping or
discarding a task handle does not settle the group. A running context-aware
entry can check `context.is_cancelled()` and admit children through its live
`TaskContext`. During `finish()`, root submissions are closed but live contexts
may still admit descendants. During `cancel_and_wait()`, all new submissions
are rejected. Cancellation is cooperative and cannot forcibly unwind foreign
code.

For an entry returning `T!E`, `join()` or a ready `try_join()` first reports
task settlement with `TaskStatus`; the returned inner value can then be caught
with `catch (code, failure)`. Its trace remains readable after `finish()`,
including after nested `TaskContext.spawn` propagation. Discarded and
unobserved task results retire their traces. `T!E` remains a function return
form; task result types are inferred rather than named with `Task<T!E>`.

`finish()` and `cancel_and_wait()` are explicit standard-library operations.
The compiler does not require either call on every path or infer that a call
has settled external work. The caller must follow the library protocol before
releasing state used by workers. Ownership and thread-transfer checks still
apply to values crossing a concurrency boundary. The implementation does not
provide borrowed `tasks.scope` or a stable general result-carrying thread API.
`Task<void>` uses `try_join_void(&task)` because `?void` is not a language type.
Do not infer complete lifetime or deadlock
proof from successful compilation.

## Low-level `Thread` API

`thread.spawn<T>(entry: fn(T): void, value: T)` returns
`Thread!ThreadError`. On success it starts a worker and hands the
caller an owned `Thread` handle. Passing that handle by value hands it off and
makes the source unavailable. `Thread` is an opaque handle; `ThreadId` is the
separate opaque identity exposed by `thread.current_id()` and `Thread.id()`.

`Thread.join()` blocks for worker completion. `Thread.detach()` releases the
handle's join obligation while allowing the worker to continue. Each consumes
the handle and returns `ThreadOutcome`: `.settled` on success, or
`.retry(ThreadFailure { code, handle })` on terminal operation failure. The
retry case preserves the handle so the caller can choose a further action.
`Thread.join()` does not transfer a worker result.

A handle may leave scope or be explicitly dropped. Neither action implicitly
joins, detaches, cancels, or stops the worker. Code that needs completion before
releasing dependent state must call `join()` and handle its outcome. The type's
owned behavior prevents ordinary duplication, but it does not prove that
every spawned worker has been joined before every dependent resource is freed.
There is no stable borrowed scoped-worker API.

## Sync primitives and protected containers

`std.sync` provides `Mutex`, `Condvar`, `AtomicI32`, `AtomicUsize`, `AtomicBool`,
`MemoryOrder`, and `SyncStatus`. These are opaque handles. Copying one aliases
the same runtime primitive; it does not create a second primitive. Initialize
through the namespace constructors, use the handle methods, and destroy or
deinitialize the primitive only after all threads that may use it have
finished. `Mutex.lock()` blocks; `Mutex.try_lock()` reports `ok`, `busy`, or an
error. `Condvar.wait(mutex)` releases and reacquires the mutex while waiting.
Atomic operations take a `MemoryOrder` where their signatures require it.

The package also provides `Shared<T>`, `Locked<T>`, `ConcurrentList<T>`, and
`ConcurrentSlotMap<T>`. `sync.shared(value)` creates mutex-protected storage;
`sync.locked(value)` keeps manual locking private. Scoped `with` and
`with_result` callbacks access protected values while locked. The concurrent
list supports insertion, length, clearing, and scoped access. The concurrent
slot map supports insertion, membership, length, and scoped access. These are
implemented APIs with deliberately limited operation sets; they do not imply
a general concurrent map or automatic synchronization of arbitrary user
containers. The compiler recognizes trusted synchronization-resource methods
when checking execution boundaries. User-defined types cannot acquire that
trusted status merely by using the same method names.

## Contract precedence

This document describes the current concurrency API and safety boundary.
`SPEC.md` remains authoritative for general language rules and `SEMANTICS.md`
for their semantic model. `STATUS.md` records implementation gaps and target
availability. Proposals, audits, and migration plans in daydream do not
change the public contract until reconciled here, in the compiler, and in
tests.
