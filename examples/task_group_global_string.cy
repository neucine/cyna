import { TaskGroup } from std.thread;

const greeting: string = "hello";
struct Message {
    text: string;
}
const shared_message: Message = {
    text: greeting
};

fn worker(value: Message): i32 {
    return value.text.len() as i32;
}

fn main(): i32 {
    const group = TaskGroup.init(1) catch (code) {
        const ignored = code;
        return 4;
    };
    const task = group.spawn(worker, shared_message) catch (code) {
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
    return result + (shared_message.text.len() as i32);
}
