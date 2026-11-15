const std = @import("std");
const helpers = @import("../helpers.zig");

test "optional truth narrows the original name and preserves bool conditions" {
    const source =
        \\fn add(value: ?i32): i32 {
        \\    if value { return value + 1; }
        \\    return 0;
        \\}
        \\fn main(): i32 {
        \\    const present: ?i32 = 4;
        \\    const absent: ?i32 = none;
        \\    if true { return add(present) + add(absent); }
        \\    return 0;
        \\}
    ;
    try helpers.expectNativeSourceExitCode(std.testing.allocator, "optional_truth", source, 5);
}

test "not negates bool and optional absence uses is none" {
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "not_optional", "fn main(): i32 { const value: ?i32 = none; if not value { return 1; } return 0; }", "expected bool");
    try helpers.expectParseFailed(std.testing.allocator, "bang_bool", "fn main(): i32 { if !true { return 1; } return 0; }");
    try helpers.expectParseFailed(std.testing.allocator, "bang_optional", "fn main(): i32 { const value: ?i32 = none; if !value { return 1; } return 0; }");
    try helpers.expectNativeSourceExitCode(std.testing.allocator, "not_bool", "fn main(): i32 { if not false { return 1; } return 0; }", 1);
}

test "is none return guard narrows the following scope" {
    const source =
        \\fn add(value: ?i32): i32 {
        \\    if value is none { return 0; }
        \\    return value + 1;
        \\}
        \\fn inspect(value: ?i32): void {
        \\    if value is none { return; }
        \\    assert(value > 0);
        \\}
        \\fn main(): i32 {
        \\    const present: ?i32 = 6;
        \\    const absent: ?i32 = none;
        \\    inspect(present);
        \\    inspect(absent);
        \\    return add(present) + add(absent);
        \\}
    ;
    try helpers.expectNativeSourceExitCode(std.testing.allocator, "is_none_guard", source, 7);
}

test "optional truth and return guard work in loop bodies" {
    const source =
        \\fn read(value: ?i32): i32 {
        \\    var count = 0;
        \\    while count < 1 {
        \\        if value is none { return 0; }
        \\        count = value;
        \\    }
        \\    return count;
        \\}
        \\fn truth(value: ?i32): i32 {
        \\    var count = 0;
        \\    while count < 1 {
        \\        if value { count = value; }
        \\        else { return 0; }
        \\    }
        \\    return count;
        \\}
        \\fn main(): i32 { const value: ?i32 = 4; return read(value) + truth(value); }
    ;
    try helpers.expectNativeSourceExitCode(std.testing.allocator, "optional_loop", source, 8);
}

test "nested optional truth checks narrow each scoped name" {
    const source =
        \\fn main(): i32 {
        \\    const outer: ?i32 = 2;
        \\    if outer {
        \\        const inner: ?i32 = 3;
        \\        if inner { return outer + inner; }
        \\    }
        \\    return 0;
        \\}
    ;
    try helpers.expectNativeSourceExitCode(std.testing.allocator, "optional_nested", source, 5);
}

test "optional borrowed slice returns accept none and narrow to the slice" {
    const source =
        \\fn maybe(value: []const u8): ?[]const u8 {
        \\    if value.len() == 0 { return none; }
        \\    return value;
        \\}
        \\fn main(): i32 {
        \\    const absent = maybe("".bytes());
        \\    if absent is bytes { return 0; }
        \\    const present = maybe("x".bytes());
        \\    if present is bytes { return bytes.len() as i32; }
        \\    return 0;
        \\}
    ;
    try helpers.expectNativeSourceExitCode(std.testing.allocator, "optional_slice", source, 1);
}

test "nonoptional truth and escaped narrowing are rejected" {
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "integer_truth", "fn main(): i32 { const value = 1; if value { return 1; } return 0; }", "expected bool");
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "narrowing_ends", "fn main(): i32 { const value: ?i32 = 1; if value { const x = value + 1; } return value + 1; }", "expected int or float");
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "else_is_absent", "fn main(): i32 { const value: ?i32 = 1; if value { return value; } else { return value + 1; } }", "expected int or float");
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "none_guard_falls_through", "fn main(): i32 { const value: ?i32 = 1; if value is none { const x = 0; } return value + 1; }", "expected int or float");
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "mutable_rebind", "fn main(): i32 { var value: ?i32 = 1; if value { value = 2; } return 0; }", "cannot assign to const local");
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "none_guard_mutable_rebind", "fn main(): i32 { var value: ?i32 = 1; if value is none { return 0; } value = 2; return 0; }", "cannot assign to const local");
}
