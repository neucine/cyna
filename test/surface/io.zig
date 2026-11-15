const std = @import("std");

const helpers = @import("../helpers.zig");

test "interpolated strings reject non-path holes" {
    const source =
        \\fn main(): i32 {
        \\    const count = 1;
        \\    const msg = $"count={count + 1}";
        \\    return 0;
        \\}
    ;

    try helpers.expectParseFailed(std.testing.allocator, "interpolation_rejects_expression_hole", source);
}
