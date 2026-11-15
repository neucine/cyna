fn set_score(scores: &Map<string, i32>, name: string, score: i32): void {
    scores[name] = score;
}

fn clear_local(scores: Map<string, i32>): i64 {
    var local = scores;
    local.clear();
    return local.len() as i64;
}

fn main(): i32 {
    var scores: Map<string, i32> = map<string, i32>();
    scores["Ada"] = 40;

    var copied = scores.clone();
    var assigned = scores;
    assigned["Ada"] = 1;
    set_score(&assigned, "Ken", 41);

    copied["Ada"] = 2;

    const local_len = clear_local(assigned.clone());

    if assigned["Ada"] == 1 and assigned["Ken"] == 41 and copied["Ada"] == 2 and assigned.len() == 2 and copied.len() == 1 and local_len == 0 {
        return 42;
    }

    return 1;
}
