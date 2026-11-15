import { TaskGroup } from std.thread;

fn worker(value: i32): string {
    const ignored = value;
    return string.from("hello".bytes());
}

fn main(): i32 {
    const group = TaskGroup.init(1) catch (init_problem) {
        const ignored = init_problem;
        return 3;
    };
    const task = group.spawn(worker, 1) catch (spawn_problem) {
        const ignored = spawn_problem;
        group.cancel_and_wait();
        return 2;
    };
    const value = task.join() catch (join_problem) {
        const ignored = join_problem;
        group.cancel_and_wait();
        return 1;
    };
    const length = value.len();
    group.finish();
    return length as i32;
}
