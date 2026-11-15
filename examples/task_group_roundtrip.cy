import { TaskGroup } from std.thread;

fn worker(value: i32): i32 {
    return value + 1;
}

fn main(): i32 {
    const group = TaskGroup.init(2) catch (problem) {
        const ignored = problem;
        return 4;
    };
    const task = group.spawn(worker, 41) catch (spawn_problem) {
        const ignored = spawn_problem;
        group.cancel_and_wait();
        return 3;
    };
    const value = task.join() catch (join_problem) {
        const ignored = join_problem;
        group.cancel_and_wait();
        return 2;
    };
    group.finish();
    return value;
}
