# std.sync

`std.sync` provides mutexes, condition variables, atomics, and
mutex-protected containers.

Available on macOS arm64, Linux x86-64, and Windows x86-64.

```cyna
import { AtomicI32, MemoryOrder, Mutex, SyncStatus } from std.sync;
```

## Types

### `Mutex` and `Condvar`

Shareable synchronization primitives. Their fields are private.

### `Shared<T>` and `Locked<T>`

Mutex-protected value wrappers. Access happens through `with` or `with_result`.

### `ConcurrentList<T>` and `ConcurrentSlotMap<T>`

Mutex-protected versions of `List<T>` and `SlotMap<T>`. They are deliberately
limited APIs, not general concurrent collections.

### `AtomicI32`, `AtomicUsize`, `AtomicBool`

Atomic scalar cells with the same load/store/exchange pattern.

### `MemoryOrder`

| Case | Meaning |
| --- | --- |
| `relaxed` | No ordering beyond atomicity. |
| `acquire` | Orders later reads after this operation. |
| `release` | Orders earlier writes before this operation. |
| `acq_rel` | Combines acquire and release. |
| `seq_cst` | Sequentially consistent ordering. |

## Static functions

Call these through the module or the named type.

| Function | Signature | Description |
| --- | --- | --- |
| `Mutex.init` | `fn init(): Mutex` | Creates a mutex. |
| `Condvar.init` | `fn init(): Condvar` | Creates a condition variable. |
| `Shared.from_ptr` | `fn from_ptr(ptr: *T): Shared<T>` | Wraps an existing pointer. |
| `Shared.from_leaked` | `fn from_leaked(value: ^T): Shared<T>` | Wraps a leaked owned value. |
| `Locked.init` | `fn init(value: T): Locked<T>` | Creates a locked value. |
| `ConcurrentList.init` | `fn init(): ConcurrentList<T>` | Creates an empty protected list. |
| `ConcurrentSlotMap.init` | `fn init(): ConcurrentSlotMap<T>` | Creates an empty protected slot map. |
| `AtomicI32.init` | `fn init(value: i32): AtomicI32` | Creates an atomic `i32`. |
| `AtomicUsize.init` | `fn init(value: usize): AtomicUsize` | Creates an atomic `usize`. |
| `AtomicBool.init` | `fn init(value: bool): AtomicBool` | Creates an atomic `bool`. |
| `shared` | `fn shared<T>(value: T): Shared<T>` | Creates a locked value wrapper. |
| `locked` | `fn locked<T>(value: T): Locked<T>` | Creates a scoped locked value. |
| `concurrent_list` | `fn concurrent_list<T>(): ConcurrentList<T>` | Creates an empty protected list. |
| `concurrent_slot_map` | `fn concurrent_slot_map<T>(): ConcurrentSlotMap<T>` | Creates an empty protected slot map. |
| `is_valid` | `fn is_valid(mutex: Mutex): bool` | Reports whether a mutex handle is valid. |
| `atomic_i32_is_valid` | `fn atomic_i32_is_valid(cell: AtomicI32): bool` | Reports whether an atomic `i32` handle is valid. |
| `atomic_usize_is_valid` | `fn atomic_usize_is_valid(cell: AtomicUsize): bool` | Reports whether an atomic `usize` handle is valid. |
| `atomic_bool_is_valid` | `fn atomic_bool_is_valid(cell: AtomicBool): bool` | Reports whether an atomic `bool` handle is valid. |

## Instance methods

### `Mutex`

| Method | Signature | Description |
| --- | --- | --- |
| `is_valid` | `fn is_valid(self: Mutex): bool` | Reports whether the handle is valid. |
| `lock` | `fn lock(self: Mutex): SyncStatus` | Blocks until the mutex is acquired. |
| `try_lock` | `fn try_lock(self: Mutex): SyncStatus` | Acquires without blocking, or returns `busy`. |
| `unlock` | `fn unlock(self: Mutex): SyncStatus` | Releases the mutex. |
| `destroy` | `fn destroy(self: Mutex): SyncStatus` | Destroys the primitive. |

### `Condvar`

| Method | Signature | Description |
| --- | --- | --- |
| `is_valid` | `fn is_valid(self: Condvar): bool` | Reports whether the handle is valid. |
| `wait` | `fn wait(self: Condvar, mutex: Mutex): SyncStatus` | Waits, releasing and reacquiring the mutex. |
| `signal` | `fn signal(self: Condvar): SyncStatus` | Wakes one waiter. |
| `broadcast` | `fn broadcast(self: Condvar): SyncStatus` | Wakes all waiters. |
| `destroy` | `fn destroy(self: Condvar): SyncStatus` | Destroys the primitive. |

### `Shared<T>`

| Method | Signature | Description |
| --- | --- | --- |
| `is_valid` | `fn is_valid(self: Shared<T>): bool` | Reports whether the handle is valid. |
| `lock` | `fn lock(self: Shared<T>): SyncStatus` | Locks the protected value. |
| `unlock` | `fn unlock(self: Shared<T>): SyncStatus` | Unlocks the protected value. |
| `with` | `fn with<U>(self: Shared<T>, context: U, action: fn (&T, U): void): SyncStatus` | Runs a callback while locked. |
| `with_result` | `fn with_result<U, R>(self: Shared<T>, context: U, action: fn (&T, U): R): R ! SyncStatus` | Runs a callback and returns its result. |
| `destroy` | `fn destroy(self: Shared<T>): SyncStatus` | Destroys the wrapper. |

### `Locked<T>`

| Method | Signature | Description |
| --- | --- | --- |
| `is_valid` | `fn is_valid(self: Locked<T>): bool` | Reports whether the handle is valid. |
| `with` | `fn with<U>(self: Locked<T>, context: U, action: fn (&T, U): void): SyncStatus` | Runs a callback while locked. |
| `with_result` | `fn with_result<U, R>(self: Locked<T>, context: U, action: fn (&T, U): R): R ! SyncStatus` | Runs a callback and returns its result. |
| `destroy` | `fn destroy(self: Locked<T>): SyncStatus` | Destroys the wrapper. |

### `ConcurrentList<T>`

| Method | Signature | Description |
| --- | --- | --- |
| `is_valid` | `fn is_valid(self: ConcurrentList<T>): bool` | Reports whether the handle is valid. |
| `len` | `fn len(self: ConcurrentList<T>): usize ! SyncStatus` | Returns the element count. |
| `clear` | `fn clear(self: ConcurrentList<T>): SyncStatus` | Removes all elements. |
| `push` | `fn push(self: ConcurrentList<T>, value: T): SyncStatus` | Appends one element. |
| `push_len` | `fn push_len(self: ConcurrentList<T>, value: T): usize ! SyncStatus` | Appends one element and returns the new length. |
| `with_index` | `fn with_index<U>(self: ConcurrentList<T>, index: usize, context: U, action: fn (&T, U): void): SyncStatus` | Runs a callback on one element. |
| `with_index_result` | `fn with_index_result<U, R>(self: ConcurrentList<T>, index: usize, context: U, action: fn (&T, U): R): R ! SyncStatus` | Runs a callback on one element and returns its result. |
| `with` | `fn with<U>(self: ConcurrentList<T>, context: U, action: fn (&List<T>, U): void): SyncStatus` | Runs a callback on the protected list. |
| `with_result` | `fn with_result<U, R>(self: ConcurrentList<T>, context: U, action: fn (&List<T>, U): R): R ! SyncStatus` | Runs a callback on the protected list and returns its result. |
| `destroy` | `fn destroy(self: ConcurrentList<T>): SyncStatus` | Destroys the container. |

### `ConcurrentSlotMap<T>`

| Method | Signature | Description |
| --- | --- | --- |
| `is_valid` | `fn is_valid(self: ConcurrentSlotMap<T>): bool` | Reports whether the handle is valid. |
| `len` | `fn len(self: ConcurrentSlotMap<T>): usize ! SyncStatus` | Returns the element count. |
| `contains` | `fn contains(self: ConcurrentSlotMap<T>, key: SlotMapKey): bool ! SyncStatus` | Checks whether a key is live. |
| `insert` | `fn insert(self: ConcurrentSlotMap<T>, value: T): SlotMapKey ! SyncStatus` | Inserts a value and returns its key. |
| `with` | `fn with<U>(self: ConcurrentSlotMap<T>, context: U, action: fn (&SlotMap<T>, U): void): SyncStatus` | Runs a callback on the protected map. |
| `with_result` | `fn with_result<U, R>(self: ConcurrentSlotMap<T>, context: U, action: fn (&SlotMap<T>, U): R): R ! SyncStatus` | Runs a callback on the protected map and returns its result. |
| `destroy` | `fn destroy(self: ConcurrentSlotMap<T>): SyncStatus` | Destroys the container. |

### Atomics

All three atomic types provide these methods:

| Method | Signature | Description |
| --- | --- | --- |
| `is_valid` | `fn is_valid(self: AtomicT): bool` | Reports whether the handle is valid. |
| `deinit` | `fn deinit(self: AtomicT): SyncStatus` | Destroys the atomic. |
| `load` | `fn load(self: AtomicT, order: MemoryOrder): T` | Reads the current value. |
| `store` | `fn store(self: AtomicT, value: T, order: MemoryOrder): SyncStatus` | Writes a value. |
| `exchange` | `fn exchange(self: AtomicT, value: T, order: MemoryOrder): T` | Replaces and returns the old value. |
| `compare_exchange` | `fn compare_exchange(self: AtomicT, expected: T, desired: T, success: MemoryOrder, failure: MemoryOrder): bool` | Replaces only when the current value matches. |

`AtomicI32` and `AtomicUsize` also provide `fetch_add(value, order)`.

## Errors

Operations that can fail return `SyncStatus`:

| Status | Meaning |
| --- | --- |
| `ok` | The operation succeeded. |
| `invalid_handle` | The primitive or wrapper is not valid. |
| `lock_failed` | Acquiring the lock failed. |
| `unlock_failed` | Releasing the lock failed. |
| `destroy_failed` | Destroying the primitive failed. |
| `busy` | A non-blocking lock attempt found the mutex held. |
| `wait_failed` | Waiting on a condition variable failed. |
| `signal_failed` | Waking one waiter failed. |
| `broadcast_failed` | Waking all waiters failed. |

## Example

```cyna
import { AtomicI32, MemoryOrder } from std.sync;

fn count(): i32 {
    const counter = AtomicI32.init(40);
    const ignored = counter.fetch_add(2, MemoryOrder.seq_cst);
    const value = counter.load(MemoryOrder.seq_cst);
    const ignored_status = counter.deinit();
    return value;
}
```

Destroy a primitive only after every thread that may use it has finished. For
thread lifecycles, see [std.thread](std-thread.md).
