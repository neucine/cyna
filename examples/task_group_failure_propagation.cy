import { TaskGroup } from std.thread;

enum Failure {
    bad;
}

fn worker(value: i32): i32 ! Failure {
    if value != 0 {
        throw Failure.bad;
    }
    return 42;
}

fn transfer(): i32 ! Failure {
    const group = TaskGroup.init(2) catch (problem) {
        throw Failure.bad;
    };
    const task = group.spawn(worker, 1) catch (problem) {
        group.cancel_and_wait();
        throw Failure.bad;
    };
    const result = task.join() catch (problem) {
        group.cancel_and_wait();
        throw Failure.bad;
    };
    group.finish();
    return try result;
}

fn main(): i32 {
    return transfer() catch (code, failure) {
        if not failure.available {
            yield 1;
        }
        if failure.site_count != 1 {
            yield 2;
        }
        if failure.site(0) is line {
            if line != 27 {
                yield 3;
            }
        } else {
            yield 4;
        }
        yield 0;
    };
}
