import { TaskGroup, TaskStatus, try_join_void } from std.thread;
import { AtomicI32, MemoryOrder, SyncStatus } from std.sync;

struct BlockerInput {
    gate: AtomicI32;
    started: AtomicI32;
}

fn blocker(input: BlockerInput): void {
    const marked = input.started.store(1, MemoryOrder.seq_cst);
    const ignored_marked = marked;
    while input.gate.load(MemoryOrder.seq_cst) == 0 {}
}

fn skipped(value: i32): void {
    const ignored = value;
}

fn main(): i32 {
    const gate = AtomicI32.init(0);
    if not gate.is_valid() {
        return 6;
    }
    const started = AtomicI32.init(0);
    if not started.is_valid() {
        const cleanup = gate.deinit();
        const ignored_cleanup = cleanup;
        return 6;
    }
    const group = TaskGroup.init(1) catch (code) {
        const ignored = code;
        const cleanup = gate.deinit();
        const ignored_cleanup = cleanup;
        const started_cleanup = started.deinit();
        const ignored_started_cleanup = started_cleanup;
        return 5;
    };
    const first = group.spawn(blocker, BlockerInput {
        gate: gate,
        started: started
    }) catch (code) {
        const ignored = code;
        group.cancel_and_wait();
        const cleanup = gate.deinit();
        const ignored_cleanup = cleanup;
        const started_cleanup = started.deinit();
        const ignored_started_cleanup = started_cleanup;
        return 4;
    };
    while started.load(MemoryOrder.seq_cst) == 0 {}
    const second = group.spawn(skipped, 1) catch (code) {
        const ignored = code;
        const release = gate.store(1, MemoryOrder.seq_cst);
        const ignored_release = release;
        first.join() catch (join_code) {
            const ignored_join = join_code;
        };
        group.cancel_and_wait();
        const cleanup = gate.deinit();
        const ignored_cleanup = cleanup;
        const started_cleanup = started.deinit();
        const ignored_started_cleanup = started_cleanup;
        return 3;
    };
    var queued = second;
    const requested = queued.cancel();
    const release = gate.store(1, MemoryOrder.seq_cst);
    first.join() catch (code) {
        const ignored = code;
        group.cancel_and_wait();
        const cleanup = gate.deinit();
        const ignored_cleanup = cleanup;
        const started_cleanup = started.deinit();
        const ignored_started_cleanup = started_cleanup;
        return 2;
    };
    group.finish();
    const polled = try_join_void(&queued);
    const cleanup = gate.deinit();
    const started_cleanup = started.deinit();
    if requested != TaskStatus.ok or release != SyncStatus.ok or
    polled != TaskStatus.cancelled or cleanup != SyncStatus.ok or
    started_cleanup != SyncStatus.ok {
        return 1;
    }
    return 0;
}
