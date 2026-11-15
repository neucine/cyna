fn reset(xs: List<i32>): void {
    xs.clear();
}

fn reset_ref(xs: &List<i32>): void {
    xs.clear();
}

fn main(): i32 {
    var xs: List<i32> = list<i32>();
    xs.reserve(4);
    xs.push(1);
    xs.push(2);

    var assigned = xs;
    reset(assigned.clone());
    reset_ref(&assigned);

    if assigned.len() == 0 {
        return 42;
    }

    return 1;
}
