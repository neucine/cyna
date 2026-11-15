import { seed_items } from collect;
import { PipelineError, WorkItem } from model;
import { append, total_points } from score;

const pipeline_bonus: i32 = 1;
var launch_count: i32 = 0;

fn build(): i32 ! PipelineError {
    launch_count = launch_count + 1;

    var slots = seed_items();
    var items: List<WorkItem> = list<WorkItem>();

    const first = take slots[0];
    if first is item {
        append<WorkItem>(&items, item);
    } else {
        throw PipelineError.missing_seed;
    }

    const second = take slots[1];
    if second is item {
        append<WorkItem>(&items, item);
    }

    const third = take slots[3];
    if third is item {
        append<WorkItem>(&items, item);
    }

    const total = try total_points<WorkItem>(items.view());
    const last = items.pop();

    if last.owner != "ops" {
        throw PipelineError.invalid_total;
    }

    if items.len() != 2 {
        throw PipelineError.invalid_total;
    }

    return total + launch_count + pipeline_bonus;
}

fn main(): i32 {
    const value = build() catch (problem) {
        const ignored = problem;
        return 1;
    };
    return value;
}
