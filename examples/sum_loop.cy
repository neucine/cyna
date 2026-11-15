fn main(): i32 {
    var i: i32 = 0;
    var sum: i32 = 0;

    while i < 10 {
        sum = sum + i;
        i = i + 1;
    }

    if sum == 45 {
        return 42;
    } else {
        return 1;
    }
}
