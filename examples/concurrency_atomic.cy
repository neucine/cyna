import std.thread;
import std.sync;
import { AtomicI32, MemoryOrder, SyncStatus } from std.sync;

struct Work {
    counter: AtomicI32;
    amount: i32;
}

@isolated
fn add(work: Work): void {
    const ignored = work.counter.fetch_add(work.amount, MemoryOrder.seq_cst);
}

fn main(): i32 {
    const counter = AtomicI32.init(0);
    if not counter.is_valid() {
        return 1;
    }

    const first = thread.spawn(add, Work {
        counter: counter,
        amount: 20
    }) catch (first_failure) {
        const ignored = first_failure;
        return 5;
    };
    const second = thread.spawn(add, Work {
        counter: counter,
        amount: 22
    }) catch (second_failure) {
        const ignored = second_failure;
        return 4;
    };
    switch first.join() {
        .settled => {
        }
        .retry(problem) => {
            const ignored = problem;
            return 2;
        }
    }
    switch second.join() {
        .settled => {
        }
        .retry(problem) => {
            const ignored = problem;
            return 3;
        }
    }

    const total = counter.load(MemoryOrder.seq_cst);
    if counter.deinit() != SyncStatus.ok {
        return 6;
    }
    return total;
}
