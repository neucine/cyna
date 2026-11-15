import { TaskGroup, TaskContext } from std.thread;

enum Failure {
    bad;
}

fn child(context: &TaskContext, value: i32): i32 ! Failure {
    if value != 0 {
        throw Failure.bad,
        "nested failure";
    }
    return 42;
}

fn parent(context: &TaskContext, value: i32): i32 ! Failure {
    const child_task = context.spawn(child, value) catch (problem) {
        throw Failure.bad;
    };
    const result = child_task.join() catch (problem) {
        throw Failure.bad;
    };
    return try result;
}

fn main(): i32 {
    const group = TaskGroup.init(2) catch (problem) {
        return 10;
    };
    const task = group.spawn_context(parent, 1) catch (problem) {
        group.cancel_and_wait();
        return 11;
    };
    group.finish();
    const result = task.join() catch (problem) {
        return 12;
    };
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
        if failure.site_count != 1 {
            yield 16;
        }
        if failure.site(0) is line {
            if line != 22 {
                yield 17;
            }
        } else {
            yield 18;
        }
        if failure.message != "nested failure" {
            yield 19;
        }
        yield 0;
    };
}
