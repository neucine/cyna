struct Point {
    x: i32;
    y: i32;

    fn make(x: i32, y: i32): Point {
        return Point {
            x: x,
            y: y
        };
    }

    fn sum(self: Point): i32 {
        return self.x + self.y;
    }
}

fn main(): i32 {
    const p: Point = Point.make(20, 22);
    return Point.sum(p);
}
