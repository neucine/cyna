pub c struct Header {
    len: c_int;
    tag: c_uchar;
}

export c("header_len") fn header_len(header: Header): c_int {
    return header.len;
}

export c("header_tag") fn header_tag(header: *Header): c_uchar {
    unchecked {
        return (*header).tag;
    }
}

fn main(): i32 {
    const header = Header {
        len: 42,
        tag: 2
    };
    return header_len(header) as i32;
}
