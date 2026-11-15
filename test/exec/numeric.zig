const std = @import("std");
const helpers = @import("../helpers.zig");

test "contextual f32 coefficient converts to c_float without trapping" {
    const source =
        \\fn main(): i32 {
        \\    const coefficient: f32 = 1.660491;
        \\    const rounded = coefficient as c_float;
        \\    const threshold: f32 = 1.66;
        \\    if (rounded as f32) > threshold { return 42; }
        \\    return 1;
        \\}
    ;
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "rounded_c_float_coefficient", "rounded_c_float_coefficient.cy", source, 42);
}

test "same width signedness coercions retain target LIR type" {
    try helpers.expectNativeSourceExitCode(std.testing.allocator, "same_width_target.cy",
        \\fn accept(value: usize): usize { return value; }
        \\fn size(count: i32): usize {
        \\    const padding = (4 - (1 % 4)) % 4;
        \\    return 1 + padding + ((count as usize) * 2);
        \\}
        \\fn main(): i32 {
        \\    const signed = 38;
        \\    const unsigned: usize = signed;
        \\    assert(accept(signed) == unsigned);
        \\    return size(19) as i32;
        \\}
    , 42);
}

test "flags values behave like named constants" {
    const source =
        \\flags Mode: i32 {
        \\    read = 42,
        \\    write = 7,
        \\}
        \\
        \\fn main(): i32 {
        \\    const mode: Mode = Mode.read;
        \\    if mode == Mode.read {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "flags_values", "native_flags_values.cy", source, 42);
}

test "flags values support bitwise operators" {
    const source =
        \\flags Mode: i32 {
        \\    read = 2,
        \\    write = 4,
        \\}
        \\
        \\fn main(): i32 {
        \\    const mode: Mode = Mode.read | Mode.write;
        \\    if Mode.read in mode {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "flags_bitwise", "native_flags_bitwise.cy", source, 42);
}

test "int values support bitwise operators" {
    const source =
        \\fn main(): i32 {
        \\    const value: i32 = (40 | 2) & 42;
        \\    return value;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "int_bitwise", "native_int_bitwise.cy", source, 42);
}

test "int values support xor and complement" {
    const source =
        \\fn main(): i32 {
        \\    const value: i32 = (40 ^ 2) & ~0;
        \\    return value;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "int_bitwise_xor_not", "native_int_bitwise_xor_not.cy", source, 42);
}

test "int values support shift operators" {
    const source =
        \\fn main(): i32 {
        \\    const value: i32 = (21 << 2) >> 1;
        \\    return value;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "int_shift", "native_int_shift.cy", source, 42);
}

test "typed integer arithmetic preserves declared width" {
    const source =
        \\fn main(): i32 {
        \\    const base: i32 = 40;
        \\    const total = base + 2;
        \\    return total;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "typed_int_arithmetic", "native_typed_int_arithmetic.cy", source, 42);
}

test "integer wrapping arithmetic operators wrap declared width" {
    const source =
        \\fn main(): i32 {
        \\    const sum: u8 = 255 +% 1;
        \\    const diff: u8 = 0 -% 214;
        \\    const product: u8 = 16 *% 16;
        \\    return (sum as i32) + (diff as i32) + (product as i32);
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "int_wrapping_arithmetic", "native_int_wrapping_arithmetic.cy", source, 42);
}

test "integer remainder is supported" {
    const source =
        \\fn main(): i32 {
        \\    const x: i32 = 17 % 16;
        \\    return x;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "int_remainder", "native_int_remainder.cy", source, 1);
}

test "signed remainder keeps the dividend sign" {
    const source =
        \\fn main(): i32 {
        \\    return (-5 % 3) + 42;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "signed_remainder_sign", "native_signed_remainder_sign.cy", source, 40);
}

test "unary negation works for values and parenthesized expressions" {
    const source =
        \\fn main(): i32 {
        \\    const value: i32 = 5;
        \\    const negated = -value;
        \\    return -(negated + 37) + 74;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "unary_negation", "native_unary_negation.cy", source, 42);
}

test "widening i32 to usize checks range in widened type" {
    const source =
        \\fn main(): i32 {
        \\    const raw: i32 = 2;
        \\    const len = raw as usize;
        \\    var result: i32 = 0;
        \\    if len == 2 {
        \\        result = 42;
        \\    }
        \\    return result;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "widen_i32_to_usize_range_check", "native_widen_i32_to_usize_range_check.cy", source, 42);
}

test "list len returns usize" {
    const source =
        \\fn main(): i32 {
        \\    var values: List<i32> = list<i32>();
        \\    values.push(1);
        \\    values.push(2);
        \\    const len: usize = values.len();
        \\    var result: i32 = 0;
        \\    if len == 2 {
        \\        result = 42;
        \\    }
        \\    drop values;
        \\    return result;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "list_len_returns_usize", "native_list_len_returns_usize.cy", source, 42);
}

test "set and map len return usize" {
    const source =
        \\fn main(): i32 {
        \\    var names: Set<string> = set<string>();
        \\    names.add("Ada");
        \\    names.add("Ken");
        \\
        \\    var scores: Map<string, i32> = map<string, i32>();
        \\    scores["Ada"] = 10;
        \\    scores["Ken"] = 32;
        \\
        \\    var keys = scores.keys();
        \\    var values = scores.values();
        \\    const set_len: usize = names.len();
        \\    const map_len: usize = scores.len();
        \\    const key_len: usize = keys.len();
        \\    const value_len: usize = values.len();
        \\
        \\    if set_len == 2 and map_len == 2 and key_len == 2 and value_len == 2 {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "set_map_len_returns_usize", "native_set_map_len_returns_usize.cy", source, 42);
}

test "zero usize to i32 cast skips negative lower bound check" {
    const source =
        \\fn main(): i32 {
        \\    const len: usize = 0;
        \\    return len as i32;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "zero_usize_to_i32_cast", "native_zero_usize_to_i32_cast.cy", source, 0);
}

test "remainder by zero traps" {
    const source =
        \\fn main(): i32 {
        \\    return 17 % 0;
        \\}
    ;

    try helpers.expectNativeFailure(std.testing.allocator, "native_int_remainder_divide_by_zero.cy", source);
}

test "prefixed integer literals and separators are supported" {
    const source =
        \\fn main(): i32 {
        \\    const mask: i32 = 0b0010_0000;
        \\    const color: i32 = 0x0800_0000;
        \\    const perms: i32 = 0o2;
        \\    const total = mask + (color / 0x0100_0000) + perms;
        \\    return total;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "prefixed_integer_literals", "native_prefixed_integer_literals.cy", source, 42);
}

test "decimal separators are supported consistently" {
    const source =
        \\fn main(): i32 {
        \\    const value: i32 = 4_2;
        \\    return value;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "decimal_integer_separators", "native_decimal_integer_separators.cy", source, 42);
}

test "float separators are supported consistently" {
    const source =
        \\fn main(): i32 {
        \\    const value: f64 = 4_0.5;
        \\    if value + 1.5 == 42.0 {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "float_separators", "native_float_separators.cy", source, 42);
}

test "typed float arithmetic works with inferred literals" {
    const source =
        \\fn main(): i32 {
        \\    const base: f64 = 40.5;
        \\    const total = base + 1.5;
        \\    if total == 42.0 {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "typed_float_arithmetic", "native_typed_float_arithmetic.cy", source, 42);
}

test "typed f32 comparison works" {
    const source =
        \\fn main(): i32 {
        \\    const lhs: f32 = 4.0;
        \\    const rhs: f32 = 2.0;
        \\    if (lhs / rhs) == 2.0 {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "typed_f32_comparison", "native_typed_f32_comparison.cy", source, 42);
}

test "mixed int and float arithmetic promotes to float" {
    const source =
        \\fn main(): i32 {
        \\    const total = 40 + 1.5;
        \\    if total == 41.5 {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "mixed_int_float_arithmetic", "native_mixed_int_float_arithmetic.cy", source, 42);
}

test "mixed float and int comparison works" {
    const source =
        \\fn main(): i32 {
        \\    const base: f32 = 21.0;
        \\    if (base * 2) == 42 {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "mixed_float_int_comparison", "native_mixed_float_int_comparison.cy", source, 42);
}

test "sets and maps use ordinary contains methods" {
    const source =
        \\fn main(): i32 {
        \\    var names: Set<string> = set<string>();
        \\    names.add("Ada");
        \\    var scores: Map<string, i32> = map<string, i32>();
        \\    scores["Ada"] = 42;
        \\    if names.contains("Ada") and scores.contains("Ada") {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "contains_set_map", "native_contains_set_map.cy", source, 42);
}

test "cenum switch accepts else branch" {
    const source =
        \\c enum Status: i32 {
        \\    ok = 0,
        \\    failed = 1,
        \\}
        \\
        \\fn code(status: Status): i32 {
        \\    switch status {
        \\        Status.ok => {
        \\            return 42;
        \\        }
        \\        Status.failed => {
        \\            return 1;
        \\        }
        \\        _ => {
        \\            return 0;
        \\        }
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    return code(Status.ok);
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "cenum_switch_with_else", "native_cenum_switch_with_else.cy", source, 42);
}

test "enum switch accepts contextual case labels" {
    const source =
        \\enum Status { ok; failed; }
        \\
        \\fn code(status: Status): i32 {
        \\    return switch status {
        \\        .ok => 42;
        \\        .failed => 1;
        \\    };
        \\}
        \\
        \\fn main(): i32 {
        \\    const status = Status.ok;
        \\    switch status {
        \\        .ok => return code(status);
        \\        .failed => return 0;
        \\    }
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "enum_contextual_switch", "native_enum_contextual_switch.cy", source, 42);
}
