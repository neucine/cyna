pub enum TestError {
    failed = 0,
}

pub fn fail(): void ! TestError {
    throw TestError.failed;
}

pub fn expect(value: bool): void ! TestError {
    if value {
        return;
    }
    try fail();
    return;
}

pub fn expect_eq_i32(actual: i32, expected: i32): void ! TestError {
    try expect(actual == expected);
    return;
}

pub fn expect_eq_i64(actual: i64, expected: i64): void ! TestError {
    try expect(actual == expected);
    return;
}

pub fn expect_eq_u8(actual: u8, expected: u8): void ! TestError {
    try expect(actual == expected);
    return;
}

pub fn expect_eq_usize(actual: usize, expected: usize): void ! TestError {
    try expect(actual == expected);
    return;
}

pub fn expect_eq_bool(actual: bool, expected: bool): void ! TestError {
    try expect(actual == expected);
    return;
}

pub fn expect_eq_string(actual: string, expected: string): void ! TestError {
    try expect(actual == expected);
    return;
}

pub fn expect_eq_bytes(actual: []const u8, expected: []const u8): void ! TestError {
    try expect(actual == expected);
    return;
}
