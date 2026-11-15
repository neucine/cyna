import { TaskGroup } from std.thread;
import { AtomicI32, MemoryOrder, SyncStatus } from std.sync;

enum Failure {
    bad;
}

fn worker(gate: AtomicI32): i32 ! Failure {
    while gate.load(MemoryOrder.seq_cst) == 0 {}
    throw Failure.bad,
    "delayed failure";
}

fn main(): i32 {
    const gate = AtomicI32.init(0);
    if not gate.is_valid() {
        return 20;
    }
    const group = TaskGroup.init(1) catch (code) {
        const ignored = code;
        const cleanup = gate.deinit();
        const ignored_cleanup = cleanup;
        return 21;
    };
    const task = group.spawn(worker, gate) catch (code) {
        const ignored = code;
        group.cancel_and_wait();
        const cleanup = gate.deinit();
        const ignored_cleanup = cleanup;
        return 22;
    };
    var mutable_task = task;
    const pending = mutable_task.try_join() catch (code) {
        const ignored = code;
        const released = gate.store(1, MemoryOrder.seq_cst);
        const ignored_released = released;
        group.finish();
        const cleanup = gate.deinit();
        const ignored_cleanup = cleanup;
        return 23;
    };
    const released = gate.store(1, MemoryOrder.seq_cst);
    group.finish();
    const cleanup = gate.deinit();
    if pending is value {
        const ignored = value;
        return 24;
    }
    if released != SyncStatus.ok or cleanup != SyncStatus.ok {
        return 25;
    }
    const ready = mutable_task.try_join() catch (code) {
        const ignored = code;
        return 26;
    };
    if ready is result {
        return result catch (code, failure) {
            if code != Failure.bad {
                yield 27;
            }
            if not failure.available {
                yield 28;
            }
            if failure.message != "delayed failure" {
                yield 29;
            }
            yield 0;
        };
    }
    return 30;
}
