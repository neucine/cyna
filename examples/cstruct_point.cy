c struct Point {
    x: i32;
    y: i32;
}

fn main(): i32 {
    const point = Point {
        x: 40,
        y: 2
    };
    return point.x + point.y;
}
