fn main(): i32 {
    const cap = 8;
    var slots = [; cap]i32;
    if slots.len() != 0 {
        return 1;
    }
    slots[3] = 42;
    if slots[3] is value {
        if value != 42 {
            return 2;
        }
        return 42;
    }
    return 3;
}
