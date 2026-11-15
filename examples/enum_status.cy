enum Status: i32 {
    ok = 0,
    not_found,
    denied,
}

fn good(): Status {
    return Status.ok;
}

fn main(): i32 {
    const status: Status = good();

    if status == Status.ok {
        return 42;
    } else {
        return 1;
    }
}
