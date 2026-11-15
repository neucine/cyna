fn main(): i32 {
    var scores: Map<string, i32> = map<string, i32>();
    scores["Ada"] = 10;
    scores["Ken"] = 12;

    var key_count: i32 = 0;
    var keys = scores.keys();
    for name in keys {
        if name == "Ada" or name == "Ken" {
            key_count = key_count + 1;
        }
    }

    var total: i32 = 0;
    var values = scores.values();
    for score in values {
        total = total + score;
    }

    if key_count == 2 and total == 22 {
        return 42;
    }

    return 1;
}
