import config;
import { Task, WorkflowError } from model;
import { seed_queue } from queue;
import { count_blocked, summarize } from report;

const queue_version: i32 = 1;
var launches: i32 = 0;

fn push_task(tasks: &List<Task>, maybe_task: ?Task): void ! WorkflowError {
    const primary = maybe_task;
    if primary is task {
        tasks.push(task);
        return;
    }
    throw WorkflowError.missing_primary;
}

fn build(): i32 ! WorkflowError {
    launches = launches + 1;

    var slots = seed_queue();
    var tasks: List<Task> = list<Task>();
    try push_task(&tasks, take slots[0]);

    const second = take slots[1];
    if second is task {
        tasks.push(task);
    }

    const third = take slots[3];
    if third is task {
        tasks.push(task);
    }

    const fourth = take slots[4];
    if fourth is task {
        tasks.push(task);
    }

    const blocked = count_blocked(tasks.view());
    const total = try summarize(tasks.view());
    const last = tasks.pop();

    if slots[0] is first_left {
        const ignored = first_left;
        throw WorkflowError.invalid_summary;
    }

    if blocked != 1 {
        throw WorkflowError.invalid_summary;
    }

    if last.owner != "cli" {
        throw WorkflowError.invalid_summary;
    }

    if queue_version != 1 {
        throw WorkflowError.invalid_summary;
    }

    return total + launches;
}

fn main(): i32 {
    const value = build() catch (problem) {
        const ignored = problem;
        return 1;
    };
    return value;
}
