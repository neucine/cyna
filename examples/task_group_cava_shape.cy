import { TaskGroup } from std.thread;

struct GuestStart {
    thread_id: i32;
    entry_pc: i32;
}

fn run_guest(start: GuestStart): i32 {
    return start.thread_id + start.entry_pc;
}

fn main(): i32 {
    const group = TaskGroup.init(2) catch (init_problem) {
        const ignored = init_problem;
        return 5;
    };
    const first = group.spawn(run_guest, GuestStart {
        thread_id: 10,
        entry_pc: 20
    }) catch (first_spawn_problem) {
        const ignored = first_spawn_problem;
        group.cancel_and_wait();
        return 4;
    };
    const second = group.spawn(run_guest, GuestStart {
        thread_id: 3,
        entry_pc: 9
    }) catch (second_spawn_problem) {
        const ignored = second_spawn_problem;
        const ignored_discard = first.discard();
        group.cancel_and_wait();
        return 3;
    };
    const a = first.join() catch (first_join_problem) {
        const ignored = first_join_problem;
        const ignored_discard = second.discard();
        group.cancel_and_wait();
        return 2;
    };
    const b = second.join() catch (second_join_problem) {
        const ignored = second_join_problem;
        group.cancel_and_wait();
        return 1;
    };
    group.finish();
    return a + b;
}
