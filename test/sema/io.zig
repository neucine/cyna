const std = @import("std");

const helpers = @import("../helpers.zig");

test "print surface type-checks through bundled std.prelude helpers" {
    const source =
        \\fn main(): i32 {
        \\    print("hello");
        \\    println(42);
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticSuccess(std.testing.allocator, "print_prelude_semantic_success", source);
}

test "interpolated strings reject unsupported hole types" {
    const source =
        \\struct Point {
        \\    pub x: i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    const point = Point { x: 1 };
        \\    const msg = $"point={point}";
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "interpolation_rejects_array", source, "cannot interpolate value of type");
}

test "string plus is rejected in favor of interpolation" {
    const source =
        \\fn main(): i32 {
        \\    const name = "ada";
        \\    const msg = "hello " + name;
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "string_plus_rejected", source, "string concatenation with `+` is not supported");
}

test "print rejects unsupported value types" {
    const source =
        \\fn main(): i32 {
        \\    print([1, 2]);
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailed(std.testing.allocator, "print_rejects_array", source);
}

test "println requires exactly one argument" {
    const source =
        \\fn main(): i32 {
        \\    println();
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "println_arity", source, "builtin `println` expects exactly one argument");
}

test "print rejects format arguments in favor of interpolation" {
    const source =
        \\fn main(): i32 {
        \\    const value = 42;
        \\    print("value=%d", value);
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "print_rejects_format_args", source, "builtin `print` expects exactly one argument; use interpolation for formatted output");
}

test "top-level print name is reserved" {
    const source =
        \\fn print(text: string): void {
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "reserved_print_name", source, "function name `print` is reserved for the builtin print surface");
}
