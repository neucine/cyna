import { TaskGroup } from std.thread;

fn main(): i32 {
    const group = TaskGroup.init(2) catch (problem) {
        const ignored = problem;
        return 1;
    };
    group.finish();
    return 0;
}
