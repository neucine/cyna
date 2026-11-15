struct Point {
    x: i32;
    y: i32;

    fn sum(self: Point): i32 {
        return self.x + self.y;
    }

    fn add(self: Point, z: i32): i32 {
        return self.sum() + z;
    }
}

fn main(): i32 {
    const p: Point = {
        x: 20,
        y: 20
    };
    return p.add(2);
}
