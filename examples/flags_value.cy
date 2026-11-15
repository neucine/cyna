flags Mode: i32 {
    read = 42,
    write = 7,
}

fn main(): i32 {
    const mode: Mode = Mode.read;
    if mode == Mode.read {
        return 42;
    }
    return 0;
}
