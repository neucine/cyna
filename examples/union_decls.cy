union Token {
    ident: string;
    eof;
}

c union RawValue {
    int_value: i32;
    flag_value: bool;
}

fn main(): i32 {
    return 42;
}
