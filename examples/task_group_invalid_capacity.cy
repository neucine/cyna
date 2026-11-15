import { TaskGroup, TaskGroupError } from std.thread;

fn main(): i32 {
    const group = TaskGroup.init(0) catch (code) {
        if code == TaskGroupError.invalid_capacity {
            return 0;
        }
        return 2;
    };
    group.finish();
    return 1;
}
