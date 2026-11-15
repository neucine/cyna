type Score = i32;
type Name = string;
type DisplayName = Name;

fn is_cyna(name: DisplayName): bool {
    return name == "Cyna";
}

fn main(): i32 {
    const score: Score = 42;
    const name: DisplayName = "Cyna";
    if is_cyna(name) {
        return score;
    } else {
        return 1;
    }
}
