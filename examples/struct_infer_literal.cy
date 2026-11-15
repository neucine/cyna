struct Point {
    x: i32;
    y: i32;

    fn make(x: i32, y: i32): Point {
        return {
            x: x,
            y: y
        };
    }
}

fn main(): i32 {
    const p: Point = {
        x: 20,
        y: 22
    };
    return p.x + p.y;
}
