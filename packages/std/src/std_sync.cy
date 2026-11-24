pub enum SyncStatus: i32 {
    ok = 0,
    invalid_handle,
    lock_failed,
    unlock_failed,
    destroy_failed,
    busy,
    wait_failed,
    signal_failed,
    broadcast_failed,
}

pub enum MemoryOrder: i32 {
    relaxed = 0,
    acquire,
    release,
    acq_rel,
    seq_cst,
}

@concurrency.shareable
pub c struct Mutex {
    raw: c_size_t;

    @concurrency.isolated
    pub fn init(): Mutex {
        return mutex_init();
    }

    @concurrency.isolated
    pub fn is_valid(self: Mutex): bool {
        return mutex_is_valid(self);
    }

    @concurrency.isolated
    pub fn lock(self: Mutex): SyncStatus {
        return mutex_lock(self);
    }

    @concurrency.isolated
    pub fn try_lock(self: Mutex): SyncStatus {
        return mutex_try_lock(self);
    }

    @concurrency.isolated
    pub fn unlock(self: Mutex): SyncStatus {
        return mutex_unlock(self);
    }

    @concurrency.isolated
    pub fn destroy(self: Mutex): SyncStatus {
        return mutex_destroy(self);
    }

}

@concurrency.shareable
pub c struct Condvar {
    raw: c_size_t;

    @concurrency.isolated
    pub fn init(): Condvar {
        return condvar_init();
    }

    @concurrency.isolated
    pub fn is_valid(self: Condvar): bool {
        return condvar_is_valid(self);
    }

    @concurrency.isolated
    pub fn wait(self: Condvar, mutex: Mutex): SyncStatus {
        return condvar_wait(self, mutex);
    }

    @concurrency.isolated
    pub fn signal(self: Condvar): SyncStatus {
        return condvar_signal(self);
    }

    @concurrency.isolated
    pub fn broadcast(self: Condvar): SyncStatus {
        return condvar_broadcast(self);
    }

    @concurrency.isolated
    pub fn destroy(self: Condvar): SyncStatus {
        return condvar_destroy(self);
    }

}

@concurrency.shareable
pub c struct SharedHandle {
    raw: c_size_t;
}

@concurrency.shareable
pub struct Shared<T> {
    handle: SharedHandle;

    pub fn from_ptr(ptr: *T): Shared<T> {
        unchecked {
            return Shared<T> {
                handle: shared_from_ptr(ptr as! *c_void)
            };
        }
    }

    pub fn from_leaked(value: ^T): Shared<T> {
        unchecked {
            return Shared<T> {
                handle: shared_from_ptr(value.leak() as! *c_void)
            };
        }
    }

    pub fn is_valid(self: Shared<T>): bool {
        return shared_is_valid(self.handle);
    }

    pub fn lock(self: Shared<T>): SyncStatus {
        return shared_lock(self.handle);
    }

    pub fn unlock(self: Shared<T>): SyncStatus {
        return shared_unlock(self.handle);
    }

    pub fn with<U>(self: Shared<T>, context: U, action: fn (&T, U): void): SyncStatus {
        const lock_status = self.lock();
        if lock_status != SyncStatus.ok {
            return lock_status;
        }
        unchecked {
            action(&*self.ptr(), context);
        }
        return self.unlock();
    }

    pub fn with_result<U, R>(self: Shared<T>, context: U, action: fn (&T, U): R): R ! SyncStatus {
        const lock_status = self.lock();
        if lock_status != SyncStatus.ok {
            throw lock_status;
        }
        unchecked {
            const value = action(&*self.ptr(), context);
            const unlock_status = self.unlock();
            if unlock_status != SyncStatus.ok {
                throw unlock_status;
            }
            return value;
        }
    }

    pub fn destroy(self: Shared<T>): SyncStatus {
        return shared_destroy(self.handle);
    }

    fn ptr(self: Shared<T>): *T {
        unchecked {
            return shared_ptr(self.handle) as! *T;
        }
    }

}

pub fn shared<T>(value: T): Shared<T> {
    return share(value);
}

fn share<T>(value: T): Shared<T> {
    const ignored_value = value;
    return Shared<T> {
        handle: SharedHandle {
            raw: 0
        }
    };
}

@concurrency.shareable
pub struct Locked<T> {
    shared: Shared<T>;

    pub fn init(value: T): Locked<T> {
        return Locked<T> {
            shared: share(value)
        };
    }

    pub fn is_valid(self: Locked<T>): bool {
        return self.shared.is_valid();
    }

    pub fn with<U>(self: Locked<T>, context: U, action: fn (&T, U): void): SyncStatus {
        const lock_status = self.shared.lock();
        if lock_status != SyncStatus.ok {
            return lock_status;
        }
        unchecked {
            action(&*self.shared.ptr(), context);
        }
        return self.shared.unlock();
    }

    pub fn with_result<U, R>(self: Locked<T>, context: U, action: fn (&T, U): R): R ! SyncStatus {
        const lock_status = self.shared.lock();
        if lock_status != SyncStatus.ok {
            throw lock_status;
        }
        unchecked {
            const value = action(&*self.shared.ptr(), context);
            const unlock_status = self.shared.unlock();
            if unlock_status != SyncStatus.ok {
                throw unlock_status;
            }
            return value;
        }
    }

    pub fn destroy(self: Locked<T>): SyncStatus {
        return self.shared.destroy();
    }

}

pub fn locked<T>(value: T): Locked<T> {
    return Locked<T> {
        shared: share(value)
    };
}

@concurrency.shareable
pub struct ConcurrentList<T> {
    shared: Shared<List<T>>;

    pub fn init(): ConcurrentList<T> {
        var items = List<T> {
            storage: [:]T[],
            capacity: 0
        };
        return ConcurrentList<T> {
            shared: share(items)
        };
    }

    pub fn is_valid(self: ConcurrentList<T>): bool {
        return self.shared.is_valid();
    }

    pub fn len(self: ConcurrentList<T>): usize ! SyncStatus {
        const lock_status = self.shared.lock();
        if lock_status != SyncStatus.ok {
            throw lock_status;
        }
        unchecked {
            const value = (&*self.shared.ptr()).len();
            const unlock_status = self.shared.unlock();
            if unlock_status != SyncStatus.ok {
                throw unlock_status;
            }
            return value;
        }
    }

    pub fn clear(self: ConcurrentList<T>): SyncStatus {
        const lock_status = self.shared.lock();
        if lock_status != SyncStatus.ok {
            return lock_status;
        }
        unchecked {
            var items = &*self.shared.ptr();
            items.clear();
        }
        return self.shared.unlock();
    }

    pub fn push(self: ConcurrentList<T>, value: T): SyncStatus {
        const lock_status = self.shared.lock();
        if lock_status != SyncStatus.ok {
            return lock_status;
        }
        unchecked {
            var items = &*self.shared.ptr();
            items.push(value);
        }
        return self.shared.unlock();
    }

    pub fn push_len(self: ConcurrentList<T>, value: T): usize ! SyncStatus {
        const lock_status = self.shared.lock();
        if lock_status != SyncStatus.ok {
            throw lock_status;
        }
        unchecked {
            var items = &*self.shared.ptr();
            items.push(value);
            const index = items.len() - 1;
            const unlock_status = self.shared.unlock();
            if unlock_status != SyncStatus.ok {
                throw unlock_status;
            }
            return index;
        }
    }

    pub fn with_index<U>(self: ConcurrentList<T>, index: usize, context: U, action: fn (&T, U): void): SyncStatus {
        const lock_status = self.shared.lock();
        if lock_status != SyncStatus.ok {
            return lock_status;
        }
        unchecked {
            const items = &*self.shared.ptr();
            if index < items.len() {
                action(items.get_mut(index), context);
            }
        }
        return self.shared.unlock();
    }

    pub fn with_index_result<U, R>(self: ConcurrentList<T>, index: usize, context: U, action: fn (&T, U): R): R ! SyncStatus {
        const lock_status = self.shared.lock();
        if lock_status != SyncStatus.ok {
            throw lock_status;
        }
        unchecked {
            const items = &*self.shared.ptr();
            if index >= items.len() {
                const ignored_unlock = self.shared.unlock();
                throw SyncStatus.invalid_handle;
            }
            const value = action(items.get_mut(index), context);
            const unlock_status = self.shared.unlock();
            if unlock_status != SyncStatus.ok {
                throw unlock_status;
            }
            return value;
        }
    }

    pub fn with<U>(self: ConcurrentList<T>, context: U, action: fn (&List<T>, U): void): SyncStatus {
        const lock_status = self.shared.lock();
        if lock_status != SyncStatus.ok {
            return lock_status;
        }
        unchecked {
            action(&*self.shared.ptr(), context);
        }
        return self.shared.unlock();
    }

    pub fn with_result<U, R>(self: ConcurrentList<T>, context: U, action: fn (&List<T>, U): R): R ! SyncStatus {
        const lock_status = self.shared.lock();
        if lock_status != SyncStatus.ok {
            throw lock_status;
        }
        unchecked {
            const value = action(&*self.shared.ptr(), context);
            const unlock_status = self.shared.unlock();
            if unlock_status != SyncStatus.ok {
                throw unlock_status;
            }
            return value;
        }
    }

    pub fn destroy(self: ConcurrentList<T>): SyncStatus {
        return self.shared.destroy();
    }

}

pub fn concurrent_list<T>(): ConcurrentList<T> {
    var items = List<T> {
        storage: [:]T[],
        capacity: 0
    };
    return ConcurrentList<T> {
        shared: share(items)
    };
}

@concurrency.shareable
pub struct ConcurrentSlotMap<T> {
    shared: Shared<SlotMap<T>>;

    pub fn init(): ConcurrentSlotMap<T> {
        var items = SlotMap<T> {
            slots: [; 0]T,
            generations: [:]usize[],
            count: 0,
            capacity: 0
        };
        return ConcurrentSlotMap<T> {
            shared: share(items)
        };
    }

    pub fn is_valid(self: ConcurrentSlotMap<T>): bool {
        return self.shared.is_valid();
    }

    pub fn len(self: ConcurrentSlotMap<T>): usize ! SyncStatus {
        const lock_status = self.shared.lock();
        if lock_status != SyncStatus.ok {
            throw lock_status;
        }
        unchecked {
            const value = (&*self.shared.ptr()).len();
            const unlock_status = self.shared.unlock();
            if unlock_status != SyncStatus.ok {
                throw unlock_status;
            }
            return value;
        }
    }

    pub fn contains(self: ConcurrentSlotMap<T>, key: SlotMapKey): bool ! SyncStatus {
        const lock_status = self.shared.lock();
        if lock_status != SyncStatus.ok {
            throw lock_status;
        }
        unchecked {
            const value = (&*self.shared.ptr()).contains(key);
            const unlock_status = self.shared.unlock();
            if unlock_status != SyncStatus.ok {
                throw unlock_status;
            }
            return value;
        }
    }

    pub fn insert(self: ConcurrentSlotMap<T>, value: T): SlotMapKey ! SyncStatus {
        const lock_status = self.shared.lock();
        if lock_status != SyncStatus.ok {
            throw lock_status;
        }
        unchecked {
            var items = &*self.shared.ptr();
            const key = items.insert(value);
            const ignored_unlock_status = self.shared.unlock();
            return key;
        }
    }

    pub fn with<U>(self: ConcurrentSlotMap<T>, context: U, action: fn (&SlotMap<T>, U): void): SyncStatus {
        const lock_status = self.shared.lock();
        if lock_status != SyncStatus.ok {
            return lock_status;
        }
        unchecked {
            action(&*self.shared.ptr(), context);
        }
        return self.shared.unlock();
    }

    pub fn with_result<U, R>(self: ConcurrentSlotMap<T>, context: U, action: fn (&SlotMap<T>, U): R): R ! SyncStatus {
        const lock_status = self.shared.lock();
        if lock_status != SyncStatus.ok {
            throw lock_status;
        }
        unchecked {
            const value = action(&*self.shared.ptr(), context);
            const unlock_status = self.shared.unlock();
            if unlock_status != SyncStatus.ok {
                throw unlock_status;
            }
            return value;
        }
    }

    pub fn destroy(self: ConcurrentSlotMap<T>): SyncStatus {
        return self.shared.destroy();
    }

}

pub fn concurrent_slot_map<T>(): ConcurrentSlotMap<T> {
    var items = SlotMap<T> {
        slots: [; 0]T,
        generations: [:]usize[],
        count: 0,
        capacity: 0
    };
    return ConcurrentSlotMap<T> {
        shared: share(items)
    };
}

@concurrency.shareable
pub c struct AtomicI32 {
    raw: c_size_t;

    @concurrency.isolated
    pub fn init(value: i32): AtomicI32 {
        return atomic_i32_init(value);
    }

    @concurrency.isolated
    pub fn is_valid(self: AtomicI32): bool {
        return atomic_i32_is_valid_raw(self);
    }

    @concurrency.isolated
    pub fn deinit(self: AtomicI32): SyncStatus {
        return atomic_i32_deinit(self);
    }

    @concurrency.isolated
    pub fn load(self: AtomicI32, order: MemoryOrder): i32 {
        return atomic_i32_load(self, order);
    }

    @concurrency.isolated
    pub fn store(self: AtomicI32, value: i32, order: MemoryOrder): SyncStatus {
        return atomic_i32_store(self, value, order);
    }

    @concurrency.isolated
    pub fn exchange(self: AtomicI32, value: i32, order: MemoryOrder): i32 {
        return atomic_i32_exchange(self, value, order);
    }

    @concurrency.isolated
    pub fn fetch_add(self: AtomicI32, value: i32, order: MemoryOrder): i32 {
        return atomic_i32_fetch_add(self, value, order);
    }

    @concurrency.isolated
    pub fn compare_exchange(self: AtomicI32, expected: i32, desired: i32, success: MemoryOrder, failure: MemoryOrder): bool {
        return atomic_i32_compare_exchange(self, expected, desired, success, failure);
    }

}

@concurrency.shareable
pub c struct AtomicUsize {
    raw: c_size_t;

    @concurrency.isolated
    pub fn init(value: usize): AtomicUsize {
        return atomic_usize_init(value);
    }

    @concurrency.isolated
    pub fn is_valid(self: AtomicUsize): bool {
        return atomic_usize_is_valid_raw(self);
    }

    @concurrency.isolated
    pub fn deinit(self: AtomicUsize): SyncStatus {
        return atomic_usize_deinit(self);
    }

    @concurrency.isolated
    pub fn load(self: AtomicUsize, order: MemoryOrder): usize {
        return atomic_usize_load(self, order);
    }

    @concurrency.isolated
    pub fn store(self: AtomicUsize, value: usize, order: MemoryOrder): SyncStatus {
        return atomic_usize_store(self, value, order);
    }

    @concurrency.isolated
    pub fn exchange(self: AtomicUsize, value: usize, order: MemoryOrder): usize {
        return atomic_usize_exchange(self, value, order);
    }

    @concurrency.isolated
    pub fn fetch_add(self: AtomicUsize, value: usize, order: MemoryOrder): usize {
        return atomic_usize_fetch_add(self, value, order);
    }

    @concurrency.isolated
    pub fn compare_exchange(self: AtomicUsize, expected: usize, desired: usize, success: MemoryOrder, failure: MemoryOrder): bool {
        return atomic_usize_compare_exchange(self, expected, desired, success, failure);
    }

}

@concurrency.shareable
pub c struct AtomicBool {
    raw: c_size_t;

    @concurrency.isolated
    pub fn init(value: bool): AtomicBool {
        return atomic_bool_init(value);
    }

    @concurrency.isolated
    pub fn is_valid(self: AtomicBool): bool {
        return atomic_bool_is_valid_raw(self);
    }

    @concurrency.isolated
    pub fn deinit(self: AtomicBool): SyncStatus {
        return atomic_bool_deinit(self);
    }

    @concurrency.isolated
    pub fn load(self: AtomicBool, order: MemoryOrder): bool {
        return atomic_bool_load(self, order);
    }

    @concurrency.isolated
    pub fn store(self: AtomicBool, value: bool, order: MemoryOrder): SyncStatus {
        return atomic_bool_store(self, value, order);
    }

    @concurrency.isolated
    pub fn exchange(self: AtomicBool, value: bool, order: MemoryOrder): bool {
        return atomic_bool_exchange(self, value, order);
    }

    @concurrency.isolated
    pub fn compare_exchange(self: AtomicBool, expected: bool, desired: bool, success: MemoryOrder, failure: MemoryOrder): bool {
        return atomic_bool_compare_exchange(self, expected, desired, success, failure);
    }

}

pub fn is_valid(mutex: Mutex): bool {
    return mutex.is_valid();
}

pub fn atomic_i32_is_valid(cell: AtomicI32): bool {
    return cell.is_valid();
}

pub fn atomic_usize_is_valid(cell: AtomicUsize): bool {
    return cell.is_valid();
}

pub fn atomic_bool_is_valid(cell: AtomicBool): bool {
    return cell.is_valid();
}

extern c fn mutex_init(): Mutex;
extern c fn mutex_is_valid(mutex: Mutex): bool;
extern c fn mutex_lock(mutex: Mutex): SyncStatus;
extern c fn mutex_try_lock(mutex: Mutex): SyncStatus;
extern c fn mutex_unlock(mutex: Mutex): SyncStatus;
extern c fn mutex_destroy(mutex: Mutex): SyncStatus;

extern c fn condvar_init(): Condvar;
extern c fn condvar_is_valid(condvar: Condvar): bool;
extern c fn condvar_wait(condvar: Condvar, mutex: Mutex): SyncStatus;
extern c fn condvar_signal(condvar: Condvar): SyncStatus;
extern c fn condvar_broadcast(condvar: Condvar): SyncStatus;
extern c fn condvar_destroy(condvar: Condvar): SyncStatus;

extern c fn shared_from_ptr(ptr: *c_void): SharedHandle;
extern c fn shared_is_valid(shared: SharedHandle): bool;
extern c fn shared_lock(shared: SharedHandle): SyncStatus;
extern c fn shared_unlock(shared: SharedHandle): SyncStatus;
extern c fn shared_destroy(shared: SharedHandle): SyncStatus;
extern c fn shared_ptr(shared: SharedHandle): *c_void;
extern c fn share_boxed(value: *c_void, desc: *c_void): SharedHandle;

extern c fn atomic_i32_init(value: i32): AtomicI32;
extern c fn atomic_i32_is_valid_raw(cell: AtomicI32): bool;
extern c fn atomic_i32_deinit(cell: AtomicI32): SyncStatus;
extern c fn atomic_i32_load(cell: AtomicI32, order: MemoryOrder): i32;
extern c fn atomic_i32_store(cell: AtomicI32, value: i32, order: MemoryOrder): SyncStatus;
extern c fn atomic_i32_exchange(cell: AtomicI32, value: i32, order: MemoryOrder): i32;
extern c fn atomic_i32_fetch_add(cell: AtomicI32, value: i32, order: MemoryOrder): i32;
extern c fn atomic_i32_compare_exchange(cell: AtomicI32, expected: i32, desired: i32, success: MemoryOrder, failure: MemoryOrder): bool;

extern c fn atomic_usize_init(value: usize): AtomicUsize;
extern c fn atomic_usize_is_valid_raw(cell: AtomicUsize): bool;
extern c fn atomic_usize_deinit(cell: AtomicUsize): SyncStatus;
extern c fn atomic_usize_load(cell: AtomicUsize, order: MemoryOrder): usize;
extern c fn atomic_usize_store(cell: AtomicUsize, value: usize, order: MemoryOrder): SyncStatus;
extern c fn atomic_usize_exchange(cell: AtomicUsize, value: usize, order: MemoryOrder): usize;
extern c fn atomic_usize_fetch_add(cell: AtomicUsize, value: usize, order: MemoryOrder): usize;
extern c fn atomic_usize_compare_exchange(cell: AtomicUsize, expected: usize, desired: usize, success: MemoryOrder, failure: MemoryOrder): bool;

extern c fn atomic_bool_init(value: bool): AtomicBool;
extern c fn atomic_bool_is_valid_raw(cell: AtomicBool): bool;
extern c fn atomic_bool_deinit(cell: AtomicBool): SyncStatus;
extern c fn atomic_bool_load(cell: AtomicBool, order: MemoryOrder): bool;
extern c fn atomic_bool_store(cell: AtomicBool, value: bool, order: MemoryOrder): SyncStatus;
extern c fn atomic_bool_exchange(cell: AtomicBool, value: bool, order: MemoryOrder): bool;
extern c fn atomic_bool_compare_exchange(cell: AtomicBool, expected: bool, desired: bool, success: MemoryOrder, failure: MemoryOrder): bool;
