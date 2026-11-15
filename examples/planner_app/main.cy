import { seed } from backlog;
import { PlannerError, Ticket } from model;
import { build_registry } from report;

const sprint_index: i32 = 1;
var run_count: i32 = 0;

fn build_day(): i32 ! PlannerError {
    run_count = run_count + 1;

    var slots = seed();
    var day: List<Ticket> = list<Ticket>();

    const first = take slots[0];
    if first is focus {
        day.push(focus);
    } else {
        throw PlannerError.missing_focus;
    }

    const second = take slots[3];
    if second is docs {
        day.push(docs);
    }

    const score = try build_registry(day.clone());
    const last = day.pop();

    if slots[0] is still_first {
        const ignored = still_first;
        throw PlannerError.invalid_state;
    }

    if slots[3] is still_second {
        const ignored = still_second;
        throw PlannerError.invalid_state;
    }

    if last.owner != "ops" {
        throw PlannerError.invalid_state;
    }

    if sprint_index != 1 {
        throw PlannerError.invalid_state;
    }

    return score + run_count;
}

fn main(): i32 {
    const value = build_day() catch (problem) {
        const ignored = problem;
        return 1;
    };
    return value;
}
