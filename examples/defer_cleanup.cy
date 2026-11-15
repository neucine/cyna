enum Status: i32 {
    ok = 0,
    failed,
}

fn mark(digit: i32): void {
    const ignored: i32 = digit;
    return;
}

fn ok_step(): void ! Status {
    return;
}

fn scope(): i32 ! Status {
    defer mark(2);
    defer mark(4);
    try ok_step();
    return 42;
}

fn main(): i32 {
    const value = scope() catch (status) {
        const ignored = status;
        return 1;
    };
    return value;
}
