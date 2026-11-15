import { TaskGroup, Task } from std.thread;

fn produce(value: i32): i32 {
    return value + 1;
}

fn consume(input: [:]Task<i32>): i32 {
    var tasks = input;
    const task = tasks.pop();
    return task.join() catch (code) {
        const ignored = code;
        yield 0;
    };
}

fn main(): i32 {
    const source_group = TaskGroup.init(1) catch (code) {
        const ignored = code;
        return 4;
    };
    const target_group = TaskGroup.init(1) catch (code) {
        const ignored = code;
        source_group.cancel_and_wait();
        return 3;
    };
    const produced = source_group.spawn(produce, 41) catch (code) {
        const ignored = code;
        target_group.cancel_and_wait();
        source_group.cancel_and_wait();
        return 2;
    };
    const tasks: [:]Task<i32> = [produced];
    const consumer = target_group.spawn(consume, tasks) catch (code) {
        const ignored = code;
        target_group.cancel_and_wait();
        source_group.cancel_and_wait();
        return 1;
    };
    const result = consumer.join() catch (code) {
        const ignored = code;
        target_group.cancel_and_wait();
        source_group.cancel_and_wait();
        return 1;
    };
    target_group.finish();
    source_group.finish();
    return result;
}
