enum Color: i32 {
    red = 42,
    blue = 7,
}

fn main(): i32 {
    const raw: i64 = 42;
    const color = raw as Color;
    if color == Color.red {
        return 42;
    }
    return 0;
}
