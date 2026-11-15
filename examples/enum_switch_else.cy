enum Status: i32 {
    ok = 0,
    failed,
    unknown,
}

fn code(status: Status): i32 {
    return switch status {
        Status.ok => 1;
        _ => 42;
    };
}

fn main(): i32 {
    return code(Status.unknown);
}
