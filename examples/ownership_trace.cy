struct Bag {
    values: List<i32>;
}

fn mark(step: i32): void {
    const ignored = step;
    return;
}

fn count(values: Bag): i32 {
    return values.values.len() as i32;
}

fn main(): i32 {
    defer mark(9);

    var opt: ?Bag = Bag {
        values: [1, 2, 3]
    };
    const taken = take opt;
    drop taken;

    var handoff = Bag {
        values: [4, 5]
    };
    var spare: List<i32> = list_from<i32>([:]i32[8]);

    return count(handoff) + (spare.len() as i32);
}
