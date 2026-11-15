enum Status: i32 {
    ok = 0,
    failed,
}

fn maybe_ok(pass: bool): void ! Status {
    if pass {
        return;
    } else {
        throw Status.failed;
    }
}

fn work(pass: bool): i32 ! Status {
    try maybe_ok(pass);
    return 42;
}

fn main(): i32 {
    const value = work(true) catch (status) {
        const ignored = status;
        return 1;
    };
    return value;
}
