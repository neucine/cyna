const std = @import("std");

const helpers = @import("../helpers.zig");

test "comparison chain with cast does not parse as generic call" {
    try helpers.expectSemanticSuccess(std.testing.allocator, "comparison_chain_cast",
        \\fn sample(source_x: f64, source_y: f64, width: usize, height: usize): bool {
        \\    if source_x < 0.0 or source_y < 0.0
        \\    or source_x > (width - 1) as f64
        \\    or source_y > (height - 1) as f64 {
        \\        return true;
        \\    }
        \\    return false;
        \\}
        \\fn main(): i32 { return 0; }
    );
}

test "enum case shorthand uses the expected enum type" {
    try helpers.expectSemanticSuccess(std.testing.allocator, "enum_case_contextual_shorthand",
        \\enum I2cStatus: i32 {
        \\    ok = 0,
        \\    failed,
        \\}
        \\
        \\fn status(): I2cStatus {
        \\    return .ok;
        \\}
        \\
        \\fn main(): i32 {
        \\    if status() == I2cStatus.ok { return 0; }
        \\    return 1;
        \\}
    );
}

test "enum case shorthand uses the comparison operand type" {
    try helpers.expectSemanticSuccess(std.testing.allocator, "enum_case_comparison_shorthand",
        \\enum I2cStatus: i32 {
        \\    ok = 0,
        \\    failed,
        \\}
        \\
        \\struct I2cResult {
        \\    status: I2cStatus;
        \\}
        \\
        \\fn result(): I2cResult {
        \\    return I2cResult { status: I2cStatus.ok };
        \\}
        \\
        \\fn main(): i32 {
        \\    if result().status == .ok { return 0; }
        \\    return 1;
        \\}
    );
}

test "float remainder is rejected" {
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "float_remainder_rejected",
        \\fn main(): i32 {
        \\    const x = 5.0 % 2.0;
        \\    return 0;
        \\}
    , "`%` requires integer operands");
}

test "float bitwise complement is rejected" {
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "float_bitwise_complement_rejected",
        \\fn main(): i32 {
        \\    const x = ~5.0;
        \\    return 0;
        \\}
    , "bitwise complement requires an int or flags value");
}

test "unsigned unary negation is rejected" {
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "unsigned_unary_negation_rejected",
        \\fn main(): i32 {
        \\    const value: u32 = 5;
        \\    const negated = -value;
        \\    return 0;
        \\}
    , "unary negation requires a signed integer or float operand");
}

test "in does not dispatch a reserved-looking collection method" {
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "in_reserved_method_not_a_hook",
        \\struct Bag {
        \\    pub fn __contains(self: &const Bag, value: i32): bool {
        \\        const ignored = self;
        \\        return value == 42;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    const bag = Bag {};
        \\    if 42 in bag { return 42; }
        \\    return 0;
        \\}
    , "`in` is defined only for flags values");
}

test "protocol conformances are visible while checking constrained generic fields" {
    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "conformance_visible_in_struct_field",
        \\struct Cache {
        \\    seen: Set<i32>;
        \\    scores: Map<string, i32>;
        \\}
        \\
        \\fn main(): i32 {
        \\    var cache = Cache { seen: set<i32>(), scores: map<string, i32>() };
        \\    cache.seen.add(1);
        \\    cache.scores["ok"] = 41;
        \\    return cache.scores["ok"] + (cache.seen.len() as i32);
        \\}
    );
}
