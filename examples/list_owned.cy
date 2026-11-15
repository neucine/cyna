fn add_one(xs: List<i32>): i32 {
    xs.push(1);
    return xs.len() as i32;
}

fn add_one_ref(xs: &List<i32>): void {
    xs.push(1);
}

fn main(): i32 {
    var a: List<i32> = list<i32>();
    a.push(1);

    var b = a;

    const local_len = add_one(b.clone());
    add_one_ref(&b);

    if b.len() == 2 and local_len == 2 {
        return 42;
    }

    return 1;
}
