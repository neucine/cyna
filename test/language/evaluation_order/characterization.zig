const std = @import("std");

const helpers = @import("../../helpers.zig");

test "struct literal fields evaluate in source order while retaining declared layout" {
    const source =
        \\var trace: i32 = 0;
        \\
        \\struct Pair {
        \\    first: i32;
        \\    second: i32;
        \\}
        \\
        \\fn record(value: i32): i32 {
        \\    trace = trace * 10 + value;
        \\    return value;
        \\}
        \\
        \\fn main(): i32 {
        \\    const pair = Pair {
        \\        second: record(2),
        \\        first: record(1),
        \\    };
        \\    const ignored = pair;
        \\    return trace;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(
        std.testing.allocator,
        "struct_literal_source_order",
        "native_struct_literal_source_order.cy",
        source,
        21,
    );
}
