packed struct Header {
    kind: i32;
    len: i32;
}

fn main(): i32 {
    const header = Header {
        kind: 40,
        len: 2
    };
    return header.kind + header.len;
}
