pub type UserId = distinct i32;

pub struct Bag {
    pub values: [2]i32;
}

fn bump(bag: &Bag): void {
    bag.values[0] = bag.values[0] + 1;
}

fn main(): i32 {
    var bag = new Bag {
        values: [1, 2]
    };
    const ptr: *Bag = bag.ptr();

    unchecked {
        (*ptr).values[0] = 41;
    }

    bump(bag);

    if bag.values[0] == 42 and true {
        return bag.values[0];
    }

    return 0;
}
