fn main(): i32 {
    var xs: List<i32> = list<i32>();
    xs.push(40);
    xs.push(2);

    var scores: Map<string, i32> = map<string, i32>();
    scores["Ada"] = 42;

    var names: Set<string> = set<string>();
    names.add("Ada");

    if xs.len() == 2 and xs[0] + xs[1] == 42 and scores["Ada"] == 42 and names.contains("Ada") {
        return 42;
    }

    return 1;
}
