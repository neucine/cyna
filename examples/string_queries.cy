fn main(): i32 {
    const text = "cyna";

    if text.starts_with("cy") and text.ends_with("na") and text.contains("yn") and not text.contains("zz") {
        return 42;
    }

    return 1;
}
