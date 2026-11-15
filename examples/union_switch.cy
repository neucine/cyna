union Token {
    ident: string;
    eof;
}

fn score(token: Token): i32 {
    switch token {
        .ident(name) => {
            if name == "answer" {
                return 42;
            }
            return 1;
        }
        .eof => {
            return 0;
        }
    }
}

fn main(): i32 {
    const token: Token = .ident("answer");
    return score(token);
}
