fn second(xs: []const i32): i32 {
    return xs[1];
}

fn main(): i32 {
    const fixed: [3]i32 = [10, 20, 30];
    var xs: List<i32> = list<i32>();
    xs.push(1);
    xs.push(2);

    return fixed[2] + xs[1] + second(fixed[..]) - 10;
}
