const std = @import("std");
const helpers = @import("../helpers.zig");

test "comptime evaluates integer literals" {
    const source =
        \\fn main(): i32 {
        \\    return comptime 42;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(
        std.testing.allocator,
        "comptime_integer_literal",
        "native_comptime_integer_literal.cy",
        source,
        42,
    );
}

test "rune literals shape to char and integer targets" {
    const source =
        \\fn main(): i32 {
        \\    const ascii: u8 = 'A';
        \\    const newline: u8 = '\n';
        \\    const han: char = '中';
        \\    const smile: char = '\u{1F600}';
        \\    if ascii == 65 and newline == 10 and han == '中' and smile == '\u{1F600}' {
        \\        return 42;
        \\    }
        \\    return 1;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(
        std.testing.allocator,
        "rune_literals",
        "native_rune_literals.cy",
        source,
        42,
    );
}
