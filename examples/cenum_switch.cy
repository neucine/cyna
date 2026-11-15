c enum Status: i32 {
    ok = 0,
    failed = 1,
}

fn code(status: Status): i32 {
    return switch status {
        Status.ok => 42;
        Status.failed => 1;
        _ => 0;
    };
}

fn main(): i32 {
    return code(Status.ok);
}
