import { TaskGroup } from std.thread;

struct ImageRequest {
    generation: i32;
    image_id: i32;
}

fn decode(request: ImageRequest): i32 {
    return request.generation * 10 + request.image_id;
}

fn main(): i32 {
    const group = TaskGroup.init(1) catch (init_problem) {
        const ignored = init_problem;
        return 4;
    };
    const old = group.spawn(decode, ImageRequest {
        generation: 1,
        image_id: 1
    }) catch (old_spawn_problem) {
        const ignored = old_spawn_problem;
        group.cancel_and_wait();
        return 3;
    };
    const ignored_cancel = old.cancel();
    const ignored_discard = old.discard();
    const current = group.spawn(decode, ImageRequest {
        generation: 2,
        image_id: 2
    }) catch (current_spawn_problem) {
        const ignored = current_spawn_problem;
        group.cancel_and_wait();
        return 2;
    };
    const value = current.join() catch (join_problem) {
        const ignored = join_problem;
        group.cancel_and_wait();
        return 1;
    };
    group.finish();
    return value;
}
