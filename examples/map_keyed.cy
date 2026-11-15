fn main(): i32 {
    var scores: Map<string, i32> = map<string, i32>();
    scores["Ada"] = 40;
    scores["Ken"] = 2;

    if scores["Ada"] + scores["Ken"] == 42 {
        return 42;
    }
    return 0;
}
