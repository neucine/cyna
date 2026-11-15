fn is_cyna(name: string): bool {
    return name == "Cyna";
}

fn main(): i32 {
    const name: string = "Cyna";
    if is_cyna(name) and name != "Other" {
        return 42;
    } else {
        return 1;
    }
}
