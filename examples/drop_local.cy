fn main(): i32 {
    var values: List<i32> = list_from<i32>([:]i32[42]);
    drop values;
    return 42;
}
