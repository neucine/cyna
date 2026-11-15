import { TaskGroup, Task } from std.thread;

fn worker(value: i32): i32 {
    return value + 1;
}

fn await_task(task: Task<i32>): i32 {
    return task.join() catch (join_problem) {
        const ignored = join_problem;
        return 0;
    };
}

fn main(): i32 {
    const group = TaskGroup.init(2) catch (init_problem) {
        const ignored = init_problem;
        return 4;
    };
    const inner = group.spawn(worker, 41) catch (inner_problem) {
        const ignored = inner_problem;
        group.cancel_and_wait();
        return 3;
    };
    const outer = group.spawn(await_task, inner) catch (outer_problem) {
        const ignored = outer_problem;
        group.cancel_and_wait();
        return 2;
    };
    const value = outer.join() catch (join_problem) {
        const ignored = join_problem;
        group.cancel_and_wait();
        return 1;
    };
    group.finish();
    return value;
}
