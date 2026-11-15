struct Bag {
    values: [2]i32;
}

fn main(): i32 {
    var bag = new Bag {
        values: [1, 2]
    };
    const ptr: *Bag = bag.ptr();
    unchecked {
        (*ptr).values[0] = 42;
    }
    return bag.values[0];
}
