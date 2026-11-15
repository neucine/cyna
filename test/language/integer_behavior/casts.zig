const std = @import("std");

const helpers = @import("../../helpers.zig");

fn expectNamedNative(comptime name: []const u8, source: []const u8, expected: i64) !void {
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, name, "native_" ++ name ++ ".cy", source, expected);
}

test "`as` performs checked integer narrowing" {
    const source =
        \\fn main(): i32 {
        \\    const big: i64 = 42;
        \\    const small = big as i32;
        \\    return small;
        \\}
    ;

    try expectNamedNative("int_as", source, 42);
}

test "`as?` returns none on failed integer cast" {
    const source =
        \\fn main(): i32 {
        \\    const big: i64 = 1000;
        \\    const small = big as? u8;
        \\    if small is none {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    try expectNamedNative("int_as_fallible", source, 42);
}

test "checked casts respect explicit enum representation width" {
    const source =
        \\enum Mode: i16 {
        \\    ready = 42,
        \\    error = 7,
        \\}
        \\
        \\fn main(): i32 {
        \\    const raw: i16 = 42;
        \\    const mode = raw as Mode;
        \\    const back = mode as i16;
        \\    const small = raw as i8;
        \\    if back == 42 {
        \\        if small == 42 {
        \\            return 42;
        \\        }
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "enum_repr_checked_cast_width", "native_enum_repr_checked_cast_width.cy", source, 42);
}

test "checked integer casts support unusual-width targets" {
    const source =
        \\fn main(): i32 {
        \\    const raw: i64 = 7;
        \\    const small = raw as u3;
        \\    return small as i32;
        \\}
    ;

    try expectNamedNative("int_as_u3", source, 7);
}

test "`as` converts int to float when exactly representable" {
    const source =
        \\fn main(): i32 {
        \\    const raw: i32 = 42;
        \\    const value = raw as f64;
        \\    if value == 42.0 {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    try expectNamedNative("int_as_float", source, 42);
}

test "`as` converts float to int by truncating toward zero" {
    const source =
        \\fn main(): i32 {
        \\    const positive: f64 = 42.9;
        \\    const negative: f64 = -1.9;
        \\    return (positive as i32) + (negative as i32);
        \\}
    ;

    try expectNamedNative("float_as_int_truncates", source, 41);
}

test "`as` converts f64 to f32 when exactly representable" {
    const source =
        \\fn main(): i32 {
        \\    const raw: f64 = 1.5;
        \\    const value = raw as f32;
        \\    if value == 1.5 {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    try expectNamedNative("float_as_float_exact", source, 42);
}

test "`as` traps on failed integer cast" {
    const source =
        \\fn narrow(value: i64): u8 {
        \\    return value as u8;
        \\}
        \\
        \\fn main(): i32 {
        \\    const big: i64 = 1000;
        \\    const narrowed: u8 = narrow(big);
        \\    return 0;
        \\}
    ;

    try helpers.expectNativeFailure(std.testing.allocator, "native_int_as_invalid.cy", source);
}

test "`as` traps on failed unusual-width integer cast" {
    const source =
        \\fn narrow(value: i64): u3 {
        \\    return value as u3;
        \\}
        \\
        \\fn main(): i32 {
        \\    const raw: i64 = 8;
        \\    const small: u3 = narrow(raw);
        \\    return 0;
        \\}
    ;

    try helpers.expectNativeFailure(std.testing.allocator, "native_int_as_u3_invalid.cy", source);
}

test "`as` widens C integer types without trapping" {
    const source =
        \\fn widen(value: c_short): c_int {
        \\    return value as c_int;
        \\}
        \\
        \\fn main(): i32 {
        \\    const raw: c_short = 42;
        \\    if widen(raw) == 42 {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    try expectNamedNative("c_int_as_widen", source, 42);
}

test "`as?` preserves widening for C integer types" {
    const source =
        \\fn widen(value: c_short): ?c_int {
        \\    return value as? c_int;
        \\}
        \\
        \\fn main(): i32 {
        \\    const raw: c_short = 42;
        \\    const widened = widen(raw);
        \\    if widened is value {
        \\        if value == 42 {
        \\            return 42;
        \\        }
        \\    }
        \\    return 0;
        \\}
    ;

    try expectNamedNative("c_int_as_fallible_widen", source, 42);
}

test "`as?` returns none on failed C integer narrowing cast" {
    const source =
        \\fn main(): i32 {
        \\    const raw: c_int = 100000;
        \\    const narrowed = raw as? c_short;
        \\    if narrowed is none {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    try expectNamedNative("c_int_as_fallible_narrow", source, 42);
}

test "`as?` converts in-range float to int by truncating toward zero" {
    const source =
        \\fn main(): i32 {
        \\    const raw: f64 = 42.5;
        \\    const value = raw as? i32;
        \\    if value is converted {
        \\        return converted;
        \\    }
        \\    return 0;
        \\}
    ;

    try expectNamedNative("float_as_int_fallible", source, 42);
}

test "`as?` returns none on out of range float to int cast" {
    const source =
        \\fn main(): i32 {
        \\    const raw: f64 = 2147483648.0;
        \\    const value = raw as? i32;
        \\    if value is none {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    try expectNamedNative("float_as_int_fallible_out_of_range", source, 42);
}

test "`as?` returns none on rounded f32 upper bound float to int cast" {
    const source =
        \\fn main(): i32 {
        \\    const raw: f32 = 2147483648.0;
        \\    const value = raw as? i32;
        \\    if value is none {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    try expectNamedNative("float_as_int_fallible_f32_upper_bound", source, 42);
}

test "`as` traps on inexact float narrowing cast" {
    const source =
        \\fn main(): i32 {
        \\    const raw: f64 = 0.1;
        \\    const value = raw as f32;
        \\    return 0;
        \\}
    ;

    try helpers.expectNativeFailure(std.testing.allocator, "native_float_as_float_inexact.cy", source);
}

test "`as` converts int to enum with validation" {
    const source =
        \\enum Color: i32 {
        \\    red = 42,
        \\    blue = 7,
        \\}
        \\
        \\fn main(): i32 {
        \\    const raw: i64 = 42;
        \\    const color = raw as Color;
        \\    if color == Color.red {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    try expectNamedNative("int_as_enum", source, 42);
}

test "`as?` returns none on invalid enum cast" {
    const source =
        \\enum Color: i32 {
        \\    red = 42,
        \\    blue = 7,
        \\}
        \\
        \\fn main(): i32 {
        \\    const raw: i64 = 5;
        \\    const color = raw as? Color;
        \\    if color is none {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    try expectNamedNative("int_as_enum_fallible", source, 42);
}

test "`as` converts enum to int" {
    const source =
        \\enum Color: i32 {
        \\    red = 42,
        \\}
        \\
        \\fn main(): i32 {
        \\    const raw = Color.red as i32;
        \\    return raw;
        \\}
    ;

    try expectNamedNative("enum_as_int", source, 42);
}

test "`as!` reinterprets same-width signed and unsigned integers" {
    const source =
        \\fn main(): i32 {
        \\    const neg32: i32 = 0 - 1;
        \\    const bits32: u32 = neg32 as! u32;
        \\    const shifted32 = bits32 >> 1;
        \\    const back32: i32 = bits32 as! i32;
        \\
        \\    const neg64: i64 = 0 - 1;
        \\    const bits64: u64 = neg64 as! u64;
        \\    const shifted64 = bits64 >> 63;
        \\    const back64: i64 = bits64 as! i64;
        \\
        \\    if shifted32 == 2147483647 {
        \\        if back32 == neg32 {
        \\            if shifted64 == 1 {
        \\                if back64 == neg64 {
        \\                    return 42;
        \\                }
        \\            }
        \\        }
        \\    }
        \\    return 0;
        \\}
    ;

    try expectNamedNative("int_as_bang_same_width_reinterpret", source, 42);
}

test "`as!` reinterprets same-width integers and floats" {
    const source =
        \\fn main(): i32 {
        \\    const float_bits: u32 = 0x40400000;
        \\    const float_value: f32 = float_bits as! f32;
        \\    const float_back: u32 = float_value as! u32;
        \\
        \\    const double_bits: u64 = 0x4008000000000000;
        \\    const double_value: f64 = double_bits as! f64;
        \\    const double_back: u64 = double_value as! u64;
        \\
        \\    if float_value == 3.0 {
        \\        if float_back == float_bits {
        \\            if double_value == 3.0 {
        \\                if double_back == double_bits {
        \\                    return 42;
        \\                }
        \\            }
        \\        }
        \\    }
        \\    return 0;
        \\}
    ;

    try expectNamedNative("int_float_as_bang_same_width_reinterpret", source, 42);
}

test "`as?` validates flags bitsets" {
    const source =
        \\flags Mode: i32 {
        \\    read = 1,
        \\    write = 2,
        \\}
        \\
        \\fn main(): i32 {
        \\    const raw: i64 = 8;
        \\    const mode = raw as? Mode;
        \\    if mode is none {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    try expectNamedNative("int_as_flags_fallible", source, 42);
}

test "`as` accepts unknown cenum values" {
    const source =
        \\c enum Status: i32 {
        \\    ok = 0,
        \\}
        \\
        \\fn main(): i32 {
        \\    const raw: i64 = 42;
        \\    const status = raw as Status;
        \\    return status as i32;
        \\}
    ;

    try expectNamedNative("int_as_cenum", source, 42);
}

test "`as` unwraps optionals" {
    const source =
        \\fn main(): i32 {
        \\    const value: ?i32 = 42;
        \\    return value as i32;
        \\}
    ;

    try expectNamedNative("optional_as", source, 42);
}

test "`as?` preserves none for optionals" {
    const source =
        \\fn main(): i32 {
        \\    const value: ?i32 = none;
        \\    const result = value as? i32;
        \\    if result is none {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    try expectNamedNative("optional_as_fallible", source, 42);
}

test "`as` traps on none optional unwrap" {
    const source =
        \\fn main(): i32 {
        \\    const value: ?i32 = none;
        \\    return value as i32;
        \\}
    ;

    try helpers.expectNativeFailure(std.testing.allocator, "native_optional_as_invalid.cy", source);
}

test "`as` extracts unique union payload by target type" {
    const source =
        \\union Token {
        \\    ident: string;
        \\    code: i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    const token: Token = .code(42);
        \\    return token as i32;
        \\}
    ;

    try expectNamedNative("union_as_payload", source, 42);
}

test "`as?` returns none on union payload mismatch" {
    const source =
        \\union Token {
        \\    ident: string;
        \\    code: i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    const token: Token = .ident("answer");
        \\    const code = token as? i32;
        \\    if code is none {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    try expectNamedNative("union_as_payload_fallible", source, 42);
}

test "`as` traps on union payload mismatch" {
    const source =
        \\union Token {
        \\    ident: string;
        \\    code: i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    const token: Token = .ident("answer");
        \\    return token as i32;
        \\}
    ;

    try helpers.expectNativeFailure(std.testing.allocator, "native_union_as_payload_invalid.cy", source);
}
