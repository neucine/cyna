import { TaskGroup } from std.thread;

enum Failure {
    bad;
}

fn worker(value: i32): i32 ! Failure {
    if value != 0 {
        throw Failure.bad,
        "worker failed";
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
    const result = task.join() catch (problem) {
        group.cancel_and_wait();
        return 12;
    };
    group.finish();
    const value = result catch (code, failure) {
        if code != Failure.bad {
            yield 13;
        }
        if not failure.available {
            yield 14;
        }
        if failure.origin == 9 {
            if failure.message == "worker failed" {
                yield 0;
            }
        }
        yield 15;
    };
    return value;
}
