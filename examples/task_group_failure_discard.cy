import { TaskGroup } from std.thread;

enum Failure {
    bad;
}

fn worker(value: i32): i32 ! Failure {
    if value != 0 {
        throw Failure.bad,
        "discarded";
    }
    return 42;
}

fn main(): i32 {
    const group = TaskGroup.init(2) catch (problem) {
        return 10;
    };
    const task = group.spawn(worker, 1) catch (problem) {
        group.cancel_and_wait();
        return 11;
    };
    if task.discard() != .ok {
        group.cancel_and_wait();
        return 12;
    }
    group.finish();
    return 0;
}
