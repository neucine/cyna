fn set_second(xs: []i32, value: i32): void {
    xs[1] = value;
}

fn main(): i32 {
    var fixed: [3]i32 = [1, 2, 3];
    var xs: List<i32> = list<i32>();
    xs.push(1);
    xs.push(2);

    fixed[0] = 20;
    xs[1] = 10;
    set_second(fixed[..], 12);

    return fixed[0] + fixed[1] + xs[1];
}
