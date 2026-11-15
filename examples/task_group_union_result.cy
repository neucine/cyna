import { TaskGroup } from std.thread;

union Payload {
    text: string;
    number: i32;
}

fn worker(input: Payload): Payload {
    switch input {
        .text(value) => {
            return .text(value);
        }
        .number(value) => {
            return .number(value + 1);
        }
    }
}

fn main(): i32 {
    const group = TaskGroup.init(1) catch (code) {
        const ignored = code;
        return 4;
    };
    const input: Payload = .text(string.from("hello".bytes()));
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
    switch result {
        .text(value) => {
            return value.len() as i32;
        }
        .number(value) => {
            return value;
        }
    }
}
