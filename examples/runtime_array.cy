fn main(): i32 {
    var xs = [:]i32[10, 20, 9];

    const view = xs[..];
    return (view.len() as i32) + xs[0] + xs[1] + xs[2];
}
