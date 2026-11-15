fn same(text: string): bool {
    return text == "Cyna";
}

fn main(): i32 {
    const a = "Cyna";
    const b = a;

    if same(a) and same(b) and a.len() == 4 and b.len() == 4 {
        return 42;
    }

    return 1;
}
