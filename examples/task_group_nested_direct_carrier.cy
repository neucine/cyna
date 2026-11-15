import { TaskGroup, Task } from std.thread;

fn produce(value: i32): i32 {
    return value + 1;
}

struct Carrier {
    tasks: [:]Task<i32>;
}

fn consume(input: Carrier): i32 {
    var carrier = input;
    const task = carrier.tasks.pop();
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
    const consumer = target_group.spawn(consume, Carrier {
        tasks: [produced]
    }) catch (code) {
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
