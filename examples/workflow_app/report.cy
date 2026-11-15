import { release_boost } from config;
import { Task, WorkflowError } from model;

pub fn count_blocked(tasks: []const Task): i32 {
    var total: i32 = 0;
    for task in tasks {
        if task.blocked {
            total = total + 1;
        }
    }
    return total;
}

pub fn summarize(tasks: []const Task): i32 ! WorkflowError {
    var owners: Set<string> = set<string>();
    var scores: Map<string, i32> = map<string, i32>();

    for task in tasks {
        owners.add(task.owner);

        if task.blocked {
            continue;
        }

        if scores.contains(task.owner) {
            scores[task.owner] = scores[task.owner] + task.score();
        } else {
            scores[task.owner] = task.score();
        }
    }

    if not owners.contains("ops") {
        throw WorkflowError.missing_owner;
    }

    var total: i32 = 0;
    var owners_list = scores.keys();
    for owner in owners_list {
        if owner == "ops" {
            total = total + release_boost;
        }
    }

    var score_values = scores.values();
    for value in score_values {
        total = total + value;
    }

    return total;
}
