flags Mode: i32 {
    read = 2,
    write = 4,
}

fn main(): i32 {
    const mode: Mode = Mode.read | Mode.write;
    if Mode.read in mode {
        return 42;
    }
    return 0;
}
