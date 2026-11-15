const std = @import("std");

const helpers = @import("../helpers.zig");

test "cenum requires explicit representation" {
    try helpers.expectParseFailed(std.testing.allocator, "cenum_requires_explicit_representation",
        \\c enum Code {
        \\    ok = 0,
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    );
}

test "flags requires explicit representation" {
    try helpers.expectParseFailed(std.testing.allocator, "flags_requires_explicit_representation",
        \\flags Mode {
        \\    read = 1,
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    );
}

test "reserved keyword local names report a clear parse diagnostic" {
    try helpers.expectParseFailedMessage(std.testing.allocator, "reserved_keyword_local_name",
        \\fn main(): i32 {
        \\    var flags: i32 = 1;
        \\    return flags;
        \\}
    , "reserved keyword `flags` cannot be used as an identifier");
}

test "leading zero decimal integers are rejected" {
    try helpers.expectParseFailed(std.testing.allocator, "leading_zero_decimal_integer",
        \\fn main(): i32 {
        \\    return 0123;
        \\}
    );
}

test "leading zero decimal floats are rejected" {
    try helpers.expectParseFailed(std.testing.allocator, "leading_zero_decimal_float",
        \\fn main(): i32 {
        \\    const value: f64 = 01.5;
        \\    return 0;
        \\}
    );
}

test "invalid prefixed and separated integer literals are rejected" {
    const cases = [_][]const u8{
        "0x",
        "0b",
        "0o",
        "0x_1",
        "0b1010_",
        "0o7__1",
        "0b102",
        "0o8",
        "0xfg",
        "1__2",
    };

    for (cases) |literal| {
        const source = try std.fmt.allocPrint(std.testing.allocator,
            \\fn main(): i32 {{
            \\    return {s};
            \\}}
        , .{literal});
        defer std.testing.allocator.free(source);

        try helpers.expectParseFailed(std.testing.allocator, literal, source);
    }
}
