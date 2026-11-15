enum Status: i32 {
    ok = 0,
    failed,
}

fn code(status: Status): i32 {
    switch status {
        Status.ok => {
            return 42;
        }
        Status.failed => {
            return 1;
        }
    }

    return 0;
}

fn main(): i32 {
    return code(Status.ok);
}
