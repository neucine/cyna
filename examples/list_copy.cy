fn main(): i32 {
    var a: List<i32> = list<i32>();
    a.push(1);

    var copied = a.clone();
    var assigned = a;

    assigned.push(2);
    copied.push(3);

    if assigned.len() == 2 and copied.len() == 2 {
        if assigned[1] == 2 and copied[1] == 3 {
            return 42;
        }
    }

    return 1;
}
