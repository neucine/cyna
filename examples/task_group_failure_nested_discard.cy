import { TaskGroup, TaskContext } from std.thread;

enum Failure {
    bad;
}

fn child(context: &TaskContext, value: i32): i32 ! Failure {
    if value != 0 {
        throw Failure.bad,
        "nested discarded";
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
    if task.discard() != .ok {
        group.cancel_and_wait();
        return 12;
    }
    group.finish();
    return 0;
}
