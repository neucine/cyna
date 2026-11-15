fn inc(x: &i32): void {
    x = x + 1;
}

fn copy_into(dst: &i32, src: &i32): void {
    dst = src;
}

fn main(): i32 {
    var value: i32 = 40;
    var other: i32 = 1;

    inc(&value);
    copy_into(&other, &value);
    inc(&other);

    return other;
}
