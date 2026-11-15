import { TaskGroup, TaskStatus, try_join_void } from std.thread;
import { AtomicI32, MemoryOrder, SyncStatus } from std.sync;

fn worker(gate: AtomicI32): void {
    while gate.load(MemoryOrder.seq_cst) == 0 {}
}

fn main(): i32 {
    const gate = AtomicI32.init(0);
    if not gate.is_valid() {
        return 5;
    }
    const group = TaskGroup.init(1) catch (code) {
        const ignored = code;
        const cleanup = gate.deinit();
        const ignored_cleanup = cleanup;
        return 4;
    };
    const task = group.spawn(worker, gate) catch (code) {
        const ignored = code;
        group.cancel_and_wait();
        const cleanup = gate.deinit();
        const ignored_cleanup = cleanup;
        return 3;
    };
    var mutable_task = task;
    const first = try_join_void(&mutable_task);
    const release_status = gate.store(1, MemoryOrder.seq_cst);
    group.finish();
    if first != TaskStatus.pending or release_status != SyncStatus.ok {
        const cleanup = gate.deinit();
        const ignored_cleanup = cleanup;
        return 2;
    }
    const second = try_join_void(&mutable_task);
    const third = try_join_void(&mutable_task);
    const cleanup = gate.deinit();
    if second != TaskStatus.ok or third != TaskStatus.invalid or cleanup != SyncStatus.ok {
        return 1;
    }
    return 0;
}
