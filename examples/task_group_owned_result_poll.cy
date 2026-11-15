import { TaskGroup } from std.thread;

fn worker(value: i32): string {
    const ignored = value;
    return string.from("hello".bytes());
}

fn main(): i32 {
    const group = TaskGroup.init(1) catch (code) {
        const ignored = code;
        return 4;
    };
    const task = group.spawn(worker, 1) catch (code) {
        const ignored = code;
        group.cancel_and_wait();
        return 3;
    };
    var mutable_task = task;
    group.finish();
    const maybe = mutable_task.try_join() catch (code) {
        const ignored = code;
        return 2;
    };
    if maybe is value {
        const length = value.len();
        if length == 5 {
            return 0;
        }
    }
    return 1;
}
