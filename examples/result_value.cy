enum Status: i32 {
    ok = 0,
    failed,
}

fn produce(): i32 ! Status {
    return 42;
}

fn run(): i32 ! Status {
    const value = try produce();
    return value;
}

fn main(): i32 {
    const value = run() catch (status) {
        const ignored = status;
        return 1;
    };
    return value;
}
