import { TaskGroup, TaskContext } from std.thread;

struct GuestStart {
    thread_id: i32;
    entry_pc: i32;
}

fn child(context: &TaskContext, start: GuestStart): i32 {
    if context.is_cancelled() {
        return 1;
    }
    return start.thread_id + start.entry_pc;
}

fn parent(context: &TaskContext, start: GuestStart): i32 {
    const child_task = context.spawn(child, GuestStart {
        thread_id: start.thread_id + 1,
        entry_pc: start.entry_pc
    }) catch (spawn_problem) {
        const ignored = spawn_problem;
        return 3;
    };
    return child_task.join() catch (join_problem) {
        const ignored = join_problem;
        return 2;
    };
}

fn main(): i32 {
    const group = TaskGroup.init(2) catch (init_problem) {
        const ignored = init_problem;
        return 6;
    };
    const task = group.spawn_context(parent, GuestStart {
        thread_id: 20,
        entry_pc: 21
    }) catch (spawn_problem) {
        const ignored = spawn_problem;
        group.cancel_and_wait();
        return 5;
    };
    group.finish();
    return task.join() catch (join_problem) {
        const ignored = join_problem;
        return 4;
    };
}
