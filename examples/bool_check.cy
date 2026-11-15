fn is_answer(x: i32): bool {
    return x == 42;
}

fn main(): i32 {
    const ok: bool = is_answer(42);

    if ok {
        return 42;
    } else {
        return 1;
    }
}
