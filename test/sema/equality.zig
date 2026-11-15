const std = @import("std");
const helpers = @import("../helpers.zig");

test "sequence equality rejects unsupported element types" {
    const source =
        \\struct Point {
        \\    x: i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    const a: [1]Point = [Point { x: 1 }];
        \\    const b: [1]Point = [Point { x: 1 }];
        \\    if a == b {
        \\        return 1;
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedDiagnostic(
        std.testing.allocator,
        "sequence_equality_rejects_struct_elements",
        source,
        .semantic_invalid,
        "sequence equality requires int, float, bool, string, or enum elements",
    );
}

test "equality rejects unsupported whole-value types" {
    const struct_source =
        \\struct Point {
        \\    x: i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    const a = Point { x: 1 };
        \\    const b = Point { x: 1 };
        \\    if a == b {
        \\        return 1;
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "equality_rejects_struct_values",
        struct_source,
        "equality is not supported for type Point",
    );

    const optional_source =
        \\fn main(): i32 {
        \\    const a: ?i32 = 1;
        \\    const b: ?i32 = 1;
        \\    if a == b {
        \\        return 1;
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "equality_rejects_optional_values",
        optional_source,
        "equality is not supported for type ?i32",
    );
}

test "inline error return rejects whole-value equality" {
    const source =
        \\enum First { bad = 7; }
        \\enum Second { bad = 7; }
        \\fn fail(): i32!First | Second { throw First.bad; }
        \\fn main(): i32 {
        \\    if fail() == fail() { return 1; }
        \\    return 0;
        \\}
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "inline_result_equality", source, "equality is not supported for type i32!First | Second");
}
