import { SyncStatus } from std.sync;

pub c struct ArcHandle {
    raw: c_ulong;
}

@ownership.shared
pub struct Arc<T> {
    handle: ArcHandle;

    pub fn is_valid(self: Arc<T>): bool {
        return arc_is_valid(self.handle);
    }

    pub fn with<U>(self: Arc<T>, context: U, action: fn (&T, U): void): SyncStatus {
        if not self.is_valid() {
            return SyncStatus.invalid_handle;
        }
        unchecked {
            action(&*self.ptr(), context);
        }
        return SyncStatus.ok;
    }

    pub fn with_result<U, R>(self: Arc<T>, context: U, action: fn (&T, U): R): R ! SyncStatus {
        if not self.is_valid() {
            throw SyncStatus.invalid_handle;
        }
        unchecked {
            return action(&*self.ptr(), context);
        }
    }

    fn ptr(self: Arc<T>): *T {
        unchecked {
            return arc_ptr(self.handle) as! *T;
        }
    }

}

impl<T> Arc<T>: Clone {
    fn clone(self: &const Arc<T>): Arc<T> {
        return Arc<T> {
            handle: arc_retain(self.handle)
        };
    }
}

pub fn arc<T>(value: T): Arc<T> {
    const ignored_value = value;
    return Arc<T> {
        handle: ArcHandle {
            raw: 0
        }
    };
}

@abi("c")
@link.import ("cyna_std_sync_arc_new_boxed")
fn arc_new_boxed(value: *c_void, desc: *c_void): ArcHandle;

@abi("c")
@link.import ("cyna_std_sync_arc_is_valid")
fn arc_is_valid(arc: ArcHandle): bool;

@abi("c")
@link.import ("cyna_std_sync_arc_retain")
fn arc_retain(arc: ArcHandle): ArcHandle;

@abi("c")
@link.import ("cyna_std_sync_arc_release")
fn arc_release(arc: ArcHandle): SyncStatus;

@abi("c")
@link.import ("cyna_std_sync_arc_ptr")
fn arc_ptr(arc: ArcHandle): *c_void;
