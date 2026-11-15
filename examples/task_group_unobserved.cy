import { TaskGroup } from std.thread;

fn worker(value: i32): i32 {
    return value + 1;
}

fn main(): i32 {
    const group = TaskGroup.init(1) catch (init_problem) {
        const ignored = init_problem;
        return 2;
    };
    const task = group.spawn(worker, 41) catch (spawn_problem) {
        const ignored = spawn_problem;
        group.cancel_and_wait();
        return 1;
    };
    const unobserved = task;
    group.finish();
    return 0;
}
