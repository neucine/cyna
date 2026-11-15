fn take(xs: List<i32>): i32 {
    xs.push(3);
    return xs.len() as i32;
}

fn main(): i32 {
    var xs: List<i32> = list_from<i32>([:]i32[1, 2]);
    var ys = xs;

    ys.push(4);

    if take(ys) == 4 {
        return 42;
    }

    return 1;
}
