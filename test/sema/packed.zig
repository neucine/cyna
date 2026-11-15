const std = @import("std");
const helpers = @import("../helpers.zig");

test "diagnostic distinguishes nested packed field alias rejection" {
    const source =
        \\packed struct Inner {
        \\    age: i32;
        \\}
        \\
        \\struct User {
        \\    inner: Inner;
        \\}
        \\
        \\fn set_age(value: &i32): void {
        \\    value = 42;
        \\}
        \\
        \\fn main(): i32 {
        \\    var user = User { inner: { age: 0 } };
        \\    set_age(&user.inner.age);
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "nested_packed_field_alias_diag", source, "cannot create alias to packed field `age` in safe code");
}

test "diagnostic distinguishes const packed field assignment rejection" {
    const source =
        \\packed struct StatusReg {
        \\    ready: u1;
        \\    mode: u3;
        \\    error: u4;
        \\}
        \\
        \\fn main(): i32 {
        \\    const reg = StatusReg { ready: 1, mode: 2, error: 3 };
        \\    reg.mode = 4;
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "const_packed_field_assign_diag", source, "cannot assign through const local `reg`");
}

test "diagnostic distinguishes packed bool field rejection" {
    const source =
        \\packed struct Header {
        \\    ready: bool;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "packed_bool_field_diag", source, "packed struct field `ready` cannot use `bool`; use `u1` or `i1` for bit fields");
}

test "diagnostic distinguishes packed enum repr rejection" {
    const source =
        \\enum Mode {
        \\    ready = 1,
        \\}
        \\
        \\packed struct Header {
        \\    mode: Mode;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "packed_enum_repr_diag", source, "packed struct field `mode` uses enum `Mode` without an explicit integer representation");
}

test "diagnostic distinguishes packed fixed array rejection" {
    const source =
        \\packed struct Header {
        \\    bytes: [2]u8;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "packed_fixed_array_diag", source, "packed struct field `bytes` cannot use fixed arrays; use integer fields or nested packed structs instead");
}

test "diagnostic distinguishes packed float field rejection" {
    const source =
        \\packed struct Header {
        \\    value: f32;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "packed_float_field_diag", source, "packed struct field `value` cannot use floating-point type `f32`; use an integer, int-backed enum, or nested packed struct");
}

test "diagnostic distinguishes packed pointer-like field rejection" {
    const source =
        \\packed struct Header {
        \\    ptr: *i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "packed_pointer_field_diag", source, "packed struct field `ptr` cannot use pointer-like storage; use an integer, int-backed enum, or nested packed struct");
}

test "diagnostic distinguishes packed non-packed nested struct rejection" {
    const source =
        \\struct Inner {
        \\    value: u8;
        \\}
        \\
        \\packed struct Header {
        \\    inner: Inner;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "packed_nonpacked_struct_diag", source, "packed struct field `inner` must use a nested packed struct; `Inner` is not packed");
}

test "diagnostic distinguishes packed union field rejection" {
    const source =
        \\union Value {
        \\    number: u8;
        \\    eof;
        \\}
        \\
        \\packed struct Header {
        \\    value: Value;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "packed_union_field_diag", source, "packed struct field `value` cannot use `Value`; use an integer, int-backed enum, or nested packed struct");
}

test "diagnostic distinguishes as! explicit-width source requirement" {
    const source =
        \\packed struct StatusReg {
        \\    ready: u1;
        \\    mode: u3;
        \\    error: u4;
        \\}
        \\
        \\fn main(): i32 {
        \\    const reg = 53 as! StatusReg;
        \\    return reg.mode as i32;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "as_bang_requires_explicit_width_source_diag", source, "`as!` integer sources must have an explicit width; cast to `uN`/`iN` first");
}

test "diagnostic distinguishes as! width mismatch int to packed" {
    const source =
        \\packed struct StatusReg {
        \\    ready: u1;
        \\    mode: u3;
        \\    error: u4;
        \\}
        \\
        \\fn main(): i32 {
        \\    const raw: u16 = 53;
        \\    const reg = raw as! StatusReg;
        \\    return reg.mode as i32;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "as_bang_width_mismatch_to_packed_diag", source, "`as!` width mismatch: source `u16` is 16 bits but packed struct `StatusReg` is 8 bits");
}

test "diagnostic distinguishes as! width mismatch int to int" {
    const source =
        \\fn main(): i32 {
        \\    const raw: i32 = 42;
        \\    const bits = raw as! u64;
        \\    return bits as i32;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "as_bang_width_mismatch_int_to_int_diag", source, "`as!` width mismatch: source `i32` is 32 bits but target `u64` is 64 bits");
}

test "diagnostic distinguishes as! width mismatch int to float" {
    const source =
        \\fn main(): i32 {
        \\    const raw: u32 = 0;
        \\    const value = raw as! f64;
        \\    const ignored = value;
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "as_bang_width_mismatch_int_to_float_diag", source, "`as!` width mismatch: source `u32` is 32 bits but target `f64` is 64 bits");
}

test "diagnostic distinguishes as! width mismatch packed to int" {
    const source =
        \\packed struct StatusReg {
        \\    ready: u1;
        \\    mode: u3;
        \\    error: u4;
        \\}
        \\
        \\fn main(): i32 {
        \\    const raw: u8 = 53 as u8;
        \\    const reg = raw as! StatusReg;
        \\    const wide = reg as! u16;
        \\    return wide as i32;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "as_bang_width_mismatch_from_packed_diag", source, "`as!` width mismatch: packed struct `StatusReg` is 8 bits but target `u16` is 16 bits");
}

test "diagnostic distinguishes as! non-packed target rejection" {
    const source =
        \\struct StatusReg {
        \\    raw: u8;
        \\}
        \\
        \\fn main(): i32 {
        \\    const raw: u8 = 53 as u8;
        \\    const reg = raw as! StatusReg;
        \\    return reg.raw as i32;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "as_bang_nonpacked_target_diag", source, "`as!` only supports packed struct/int bit reinterpretation; `StatusReg` is not packed");
}
