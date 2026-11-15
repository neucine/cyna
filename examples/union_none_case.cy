pub union Choice {
    none;
    reduce: bool;
}

fn empty(): Choice {
    return .none;
}

fn main(): i32 {
    const choice = empty();
    if choice is .none {
        return 42;
    }
    return 1;
}
