union Token {
    ident: string;
    eof;
}

fn main(): i32 {
    const token: Token = .ident("answer");
    if token is .ident(name) {
        if name == "answer" {
            return 42;
        }
    }
    return 0;
}
