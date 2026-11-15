fn main(): i32 {
    var xs: List<i32> = list_from<i32>([:]i32[10, 20, 12]);
    const last = xs.pop();

    var scores: Map<string, i32> = map<string, i32>();
    scores["Ada"] = 10;
    scores["Ken"] = 20;

    if last == 12 and xs.len() == 2 and scores.contains("Ada") and not scores.contains("Lin") {
        return 42;
    }

    return 1;
}
