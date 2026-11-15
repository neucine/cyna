struct Point {
    x: i32;
    y: i32;
}

fn main(): i32 {
    const p: Point = {
        x: 20,
        y: 22
    };
    return p.x + p.y;
}
