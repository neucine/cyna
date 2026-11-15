import { TaskGroup } from std.thread;

fn worker(values: [;]i32): [;]i32 {
    return values;
}

fn main(): i32 {
    const group = TaskGroup.init(1) catch (code) {
        const ignored = code;
        return 4;
    };
    const input: [;]i32 = [; 16] {
        3: 40,
        10: 2
    };
    const task = group.spawn(worker, input) catch (code) {
        const ignored = code;
        group.cancel_and_wait();
        return 3;
    };
    const result = task.join() catch (code) {
        const ignored = code;
        group.cancel_and_wait();
        return 2;
    };
    group.finish();
    if result[3] is first {
        if result[10] is second {
            return first + second;
        }
    }
    return 1;
}
