union Token {
    ident: string;
    eof;
}

fn main(): i32 {
    const token: Token = .ident("answer");
    if token.ident == "answer" {
        return 42;
    }
    return 0;
}
