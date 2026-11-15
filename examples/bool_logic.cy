fn always_false(): bool {
    return false;
}

fn main(): i32 {
    var touched: i32 = 0;
    if true or always_false() {
        if not false and touched == 0 {
            return 42;
        } else {
            return 1;
        }
    } else {
        return 1;
    }
}
