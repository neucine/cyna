import { PipelineError, Scored } from model;

pub fn total_points<T: Scored>(items: []const T): i32 ! PipelineError {
    var total: i32 = 0;
    for item in items {
        total = total + item.points();
    }

    if total == 0 {
        throw PipelineError.empty_summary;
    }

    return total;
}

pub fn append<T: Scored>(items: &List<T>, value: T): void {
    items.push(value);
}
