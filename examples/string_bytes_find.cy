fn main(): i32 {
    const bytes = "cyna".bytes();
    const found = "cyna".find("yn");
    const missing = "cyna".find("zz");

    if bytes.len() == 4 and bytes[0] == 99 and found != none and missing == none {
        return 42;
    }

    return 1;
}
