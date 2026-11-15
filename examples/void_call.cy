fn noop(): void {
}

fn early(): void {
    return;
}

fn main(): i32 {
    noop();
    early();
    return 42;
}
