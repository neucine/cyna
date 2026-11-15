type Scores = [3]i32;

fn accept(scores: Scores): i32 {
    return 42;
}

fn main(): i32 {
    const scores = [3]i32[10, 20, 12];
    return accept(scores);
}
