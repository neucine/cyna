import { TaskGroup } from std.thread;

enum Failure {
    bad;
}

fn worker(value: i32): i32 ! Failure {
    if value != 0 {
        throw Failure.bad,
        "polled failure";
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
    var mutable_task = task;
    group.finish();
    const maybe = mutable_task.try_join() catch (problem) {
        return 12;
    };
    if maybe is result {
        return result catch (code, failure) {
            if code != Failure.bad {
                yield 13;
            }
            if not failure.available {
                yield 14;
            }
            if failure.origin != 9 {
                yield 15;
            }
            if failure.message != "polled failure" {
                yield 16;
            }
            yield 0;
        };
    }
    return 17;
}
