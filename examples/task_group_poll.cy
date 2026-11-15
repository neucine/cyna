import { TaskGroup } from std.thread;

fn worker(value: i32): i32 {
    return value + 1;
}

fn main(): i32 {
    const group = TaskGroup.init(1) catch (init_problem) {
        const ignored = init_problem;
        return 4;
    };
    const task = group.spawn(worker, 41) catch (spawn_problem) {
        const ignored = spawn_problem;
        group.cancel_and_wait();
        return 3;
    };
    var mutable_task = task;
    const maybe = mutable_task.try_join() catch (poll_problem) {
        const ignored = poll_problem;
        group.cancel_and_wait();
        return 2;
    };
    if maybe is value {
        group.finish();
        return value;
    }
    const value = mutable_task.join() catch (join_problem) {
        const ignored = join_problem;
        group.cancel_and_wait();
        return 1;
    };
    group.finish();
    return value;
}
