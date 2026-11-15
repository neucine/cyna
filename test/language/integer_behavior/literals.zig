const std = @import("std");

const helpers = @import("../../helpers.zig");

test "uncontexted integer literals retain values beyond i32" {
    const source =
        \\fn main(): i32 {
        \\    const value = 2147483648;
        \\    return (value / 51130563) as i32;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(
        std.testing.allocator,
        "uncontexted_integer_literal",
        "native_uncontexted_integer_literal.cy",
        source,
        42,
    );
}

test "uncontexted float literals retain f64 precision" {
    const source =
        \\fn main(): i32 {
        \\    const value = 16777217.0;
        \\    if value > 16777216.0 {
        \\        return 42;
        \\    }
        \\    return 1;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(
        std.testing.allocator,
        "uncontexted_float_literal",
        "native_uncontexted_float_literal.cy",
        source,
        42,
    );
}
