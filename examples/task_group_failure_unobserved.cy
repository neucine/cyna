import { TaskGroup } from std.thread;

enum Failure {
    bad;
}

fn worker(value: i32): i32 ! Failure {
    if value != 0 {
        throw Failure.bad,
        "unobserved";
    }
    return 42;
}

fn main(): i32 {
    const group = TaskGroup.init(1) catch (problem) {
        return 10;
    };
    const task = group.spawn(worker, 1) catch (problem) {
        group.cancel_and_wait();
        return 11;
    };
    const unobserved = task;
    group.finish();
    return 0;
}
