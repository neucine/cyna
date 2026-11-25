const std = @import("std");

const helpers = @import("../../helpers.zig");

fn expectNamedNative(comptime name: []const u8, source: []const u8, expected: i64) !void {
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, name, "native_" ++ name ++ ".cy", source, expected);
}

test "reordered named arguments fill positional slots and trailing defaults apply" {
    const source =
        \\var trace: i32 = 0;
        \\
        \\fn mark(value: i32): i32 {
        \\    trace = trace * 10 + value;
        \\    return value;
        \\}
        \\
        \\fn combine(first: i32, second: i32 = 2, third: i32 = 3): i32 {
        \\    return first * 100 + second * 10 + third;
        \\}
        \\
        \\fn main(): i32 {
        \\    const result = combine(third = mark(3), first = mark(1));
        \\    if result != 123 {
        \\        return 1;
        \\    }
        \\    return trace;
        \\}
    ;

    // `mark(3)` evaluates first, then `mark(1)`, so the trace reads 31.
    try expectNamedNative("named_reordered_defaults", source, 31);
}

test "omitted trailing defaults and all-named calls agree" {
    const source =
        \\fn combine(first: i32, second: i32 = 2, third: i32 = 3): i32 {
        \\    return first * 100 + second * 10 + third;
        \\}
        \\
        \\fn main(): i32 {
        \\    if combine(1) != 123 {
        \\        return 1;
        \\    }
        \\    if combine(1, 4) != 143 {
        \\        return 2;
        \\    }
        \\    return combine(first = 1, second = 2, third = 3) - 81;
        \\}
    ;

    try expectNamedNative("named_trailing_defaults", source, 42);
}

test "mixed positional and named arguments can skip a middle default" {
    const source =
        \\fn combine(first: i32, second: i32 = 2, third: i32 = 3): i32 {
        \\    return first * 100 + second * 10 + third;
        \\}
        \\
        \\fn main(): i32 {
        \\    if combine(1, third = 3) != 123 {
        \\        return 1;
        \\    }
        \\    if combine(1, 4, third = 5) != 145 {
        \\        return 2;
        \\    }
        \\    return combine(1, second = 4) - 101;
        \\}
    ;

    try expectNamedNative("named_mixed_positional", source, 42);
}

test "reordered owned handoff passes values to the right parameters" {
    const source =
        \\fn total(first: [:]i32, second: [:]i32): i32 {
        \\    return first[0] + second[0];
        \\}
        \\
        \\fn main(): i32 {
        \\    const first: [:]i32 = [40];
        \\    const second: [:]i32 = [2];
        \\    return total(second = second, first = first);
        \\}
    ;

    try expectNamedNative("named_owned_handoff", source, 42);
}

test "borrowed arguments retain their behavior when reordered" {
    const source =
        \\fn add(first: &const i32, second: &const i32): i32 {
        \\    return first + second;
        \\}
        \\
        \\fn main(): i32 {
        \\    var first: i32 = 40;
        \\    var second: i32 = 2;
        \\    return add(second = &second, first = &first);
        \\}
    ;

    try expectNamedNative("named_borrowed_args", source, 42);
}

test "string and bool default values lower at the call site" {
    const source =
        \\fn label(text: string = "ok", loud: bool = false): i32 {
        \\    if text != "ok" {
        \\        return 1;
        \\    }
        \\    if loud {
        \\        return 2;
        \\    }
        \\    return 42;
        \\}
        \\
        \\fn main(): i32 {
        \\    if label() != 42 {
        \\        return 10;
        \\    }
        \\    if label(loud = false) != 42 {
        \\        return 11;
        \\    }
        \\    return label(text = "ok", loud = false);
        \\}
    ;

    try expectNamedNative("named_string_bool_defaults", source, 42);
}

test "namespace functions accept defaults and named arguments" {
    const source =
        \\struct Point {
        \\    x: i32;
        \\
        \\    fn make(base: i32 = 40): i32 {
        \\        return base;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    if Point.make() != 40 {
        \\        return 1;
        \\    }
        \\    return Point.make(base = 42);
        \\}
    ;

    try expectNamedNative("named_namespace_defaults", source, 42);
}

test "reordered owned handoff marks the source unavailable" {
    const source =
        \\fn total(first: [:]i32, second: [:]i32): i32 {
        \\    return first[0] + second[0];
        \\}
        \\
        \\fn main(): i32 {
        \\    var first: [:]i32 = [40];
        \\    const second: [:]i32 = [2];
        \\    const result = total(second = second, first = first);
        \\    return result + first[0];
        \\}
    ;

    try helpers.expectSemanticFailedMessage(
        std.testing.allocator,
        "named_owned_handoff_reuse",
        source,
        "local `first` was handed off or dropped",
    );
}

test "named argument errors are diagnosed" {
    const prefix =
        \\fn combine(first: i32, second: i32 = 2): i32 { return first + second; }
        \\
        \\fn main(): i32 {
    ;
    const suffix =
        \\}
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "named_unknown", prefix ++
        \\    return combine(missing = 1);
    ++ suffix, "unknown named argument");
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "named_duplicate", prefix ++
        \\    return combine(1, first = 2);
    ++ suffix, "same parameter more than once");
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "named_missing", prefix ++
        \\    return combine(second = 2);
    ++ suffix, "missing a required argument");
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "named_positional_after", prefix ++
        \\    return combine(first = 1, 2);
    ++ suffix, "positional arguments must precede named arguments");
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "named_positional_after_mixed", prefix ++
        \\    return combine(second = 2, 1);
    ++ suffix, "positional arguments must precede named arguments");
}

test "defaults must be trailing and literal-shaped" {
    const trailing =
        \\fn bad(first: i32 = 1, second: i32): i32 { return first + second; }
        \\fn main(): i32 { return bad(1); }
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "default_non_trailing", trailing, "trailing suffix");

    const unsupported =
        \\const other: i32 = 1;
        \\fn bad(value: i32 = other): i32 { return value; }
        \\fn main(): i32 { return bad(); }
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "default_unsupported", unsupported, "literal values");
}

test "methods reject named arguments and default parameters" {
    const named =
        \\struct Point {
        \\    x: i32;
        \\
        \\    fn add(self: &const Point, value: i32): i32 { return self.x + value; }
        \\}
        \\
        \\fn main(): i32 {
        \\    const point = Point { x: 40 };
        \\    return point.add(value = 2);
        \\}
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "method_named_rejected", named, "method calls");

    const defaults =
        \\struct Point {
        \\    x: i32;
        \\
        \\    fn add(self: &const Point, value: i32 = 2): i32 { return self.x + value; }
        \\}
        \\
        \\fn main(): i32 {
        \\    const point = Point { x: 40 };
        \\    return point.add(2);
        \\}
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "method_defaults_rejected", defaults, "method parameters cannot declare defaults");
}

test "C ABI declarations reject defaults and named calls" {
    const defaults =
        \\extern c fn gets(value: c_int = 1): c_int;
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "extern_defaults_rejected", defaults, "extern and exported functions");

    const named =
        \\extern c fn gets(value: c_int): c_int;
        \\fn main(): i32 { return gets(value = 1); }
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "extern_named_rejected", named, "C ABI calls");
}
