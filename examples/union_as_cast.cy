union Token {
    ident: string;
    code: i32;
}

fn main(): i32 {
    const token: Token = .code(42);
    return token as i32;
}
