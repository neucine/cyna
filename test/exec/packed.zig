const std = @import("std");
const helpers = @import("../helpers.zig");

test "packed struct values support literals and field access" {
    const source =
        \\packed struct Header {
        \\    kind: i32;
        \\    len: i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    const header = Header { kind: 40, len: 2 };
        \\    return header.kind + header.len;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "packed_struct_values", "native_packed_struct_values.cy", source, 42);
}

test "packed structs support unusual-width integer fields" {
    const source =
        \\packed struct StatusReg {
        \\    ready: u1;
        \\    mode: u3;
        \\    error: u4;
        \\}
        \\
        \\fn main(): i32 {
        \\    const reg = StatusReg { ready: 1, mode: 2, error: 3 };
        \\    return (reg.ready as i32) + (reg.mode as i32) + (reg.error as i32);
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "packed_struct_unusual_width_fields", "native_packed_struct_unusual_width_fields.cy", source, 6);
}

test "packed structs support int-backed enum fields" {
    const source =
        \\enum Mode: i32 {
        \\    ready = 40,
        \\    error = 2,
        \\}
        \\
        \\packed struct Header {
        \\    left: Mode;
        \\    right: Mode;
        \\}
        \\
        \\fn main(): i32 {
        \\    const header = Header { left: Mode.ready, right: Mode.error };
        \\    return (header.left as i32) + (header.right as i32);
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "packed_struct_enum_fields", "native_packed_struct_enum_fields.cy", source, 42);
}

test "packed structs support nested packed struct fields" {
    const source =
        \\packed struct Inner {
        \\    left: u8;
        \\    right: u8;
        \\}
        \\
        \\packed struct Outer {
        \\    inner: Inner;
        \\    tail: u8;
        \\}
        \\
        \\fn main(): i32 {
        \\    const value = Outer { inner: Inner { left: 20, right: 20 }, tail: 2 };
        \\    return (value.inner.left as i32) + (value.inner.right as i32) + (value.tail as i32);
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "packed_struct_nested_fields", "native_packed_struct_nested_fields.cy", source, 42);
}

test "packed structs support raw int bitcasts with as!" {
    const source =
        \\packed struct StatusReg {
        \\    ready: u1;
        \\    mode: u3;
        \\    error: u4;
        \\}
        \\
        \\fn main(): i32 {
        \\    const raw0 = 53 as u8;
        \\    const reg = raw0 as! StatusReg;
        \\    const raw = reg as! u8;
        \\    const reg2 = raw as! StatusReg;
        \\    return (raw as i32) + (reg2.mode as i32);
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "packed_struct_raw_int_casts", "native_packed_struct_raw_int_casts.cy", source, 55);
}

test "packed raw-pointer field assignment updates the packed carrier" {
    const source =
        \\packed struct StatusReg {
        \\    ready: u1;
        \\    mode: u3;
        \\    error: u4;
        \\}
        \\
        \\fn main(): i32 {
        \\    var reg = new StatusReg { ready: 1, mode: 2, error: 3 };
        \\    const ptr: *StatusReg = reg.ptr();
        \\    unchecked {
        \\        (*ptr).mode = 4;
        \\    }
        \\    return reg.mode as i32;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "packed_struct_raw_field_assign", "native_packed_struct_raw_field_assign.cy", source, 4);
}

test "packed locals support direct field assignment" {
    const source =
        \\packed struct StatusReg {
        \\    ready: u1;
        \\    mode: u3;
        \\    error: u4;
        \\}
        \\
        \\fn main(): i32 {
        \\    var reg = StatusReg { ready: 1, mode: 2, error: 3 };
        \\    reg.mode = 4;
        \\    return reg.mode as i32;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "packed_struct_direct_field_assign", "native_packed_struct_direct_field_assign.cy", source, 4);
}

test "packed ref params support direct field assignment" {
    const source =
        \\packed struct StatusReg {
        \\    ready: u1;
        \\    mode: u3;
        \\    error: u4;
        \\}
        \\
        \\fn set_mode(reg: &StatusReg): void {
        \\    reg.mode = 4;
        \\}
        \\
        \\fn main(): i32 {
        \\    var reg = StatusReg { ready: 1, mode: 2, error: 3 };
        \\    set_mode(&reg);
        \\    return reg.mode as i32;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "packed_struct_ref_param_field_assign", "native_packed_struct_ref_param_field_assign.cy", source, 4);
}

test "nested packed raw-pointer field assignment updates nested carriers" {
    const source =
        \\packed struct Inner {
        \\    left: u8;
        \\    right: u8;
        \\}
        \\
        \\packed struct Outer {
        \\    inner: Inner;
        \\    tail: u8;
        \\}
        \\
        \\fn main(): i32 {
        \\    var value = new Outer { inner: Inner { left: 0, right: 0 }, tail: 21 };
        \\    const ptr: *Outer = value.ptr();
        \\    unchecked {
        \\        (*ptr).inner.left = 1;
        \\        (*ptr).inner.right = 20;
        \\    }
        \\    return (value.inner.left as i32) + (value.inner.right as i32) + (value.tail as i32);
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "packed_struct_nested_raw_field_assign", "native_packed_struct_nested_raw_field_assign.cy", source, 42);
}

test "packed fields support direct nested assignment through containing structs" {
    const source =
        \\packed struct Inner {
        \\    left: u8;
        \\    right: u8;
        \\}
        \\
        \\struct Outer {
        \\    inner: Inner;
        \\}
        \\
        \\fn main(): i32 {
        \\    var outer = Outer { inner: Inner { left: 0, right: 0 } };
        \\    outer.inner.left = 40;
        \\    outer.inner.right = 2;
        \\    return (outer.inner.left as i32) + (outer.inner.right as i32);
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "packed_struct_nested_direct_field_assign", "native_packed_struct_nested_direct_field_assign.cy", source, 42);
}

test "generic packed structs instantiate concrete packed fields" {
    const source =
        \\packed struct Pair<T> {
        \\    left: T;
        \\    right: T;
        \\}
        \\
        \\fn main(): i32 {
        \\    const pair = Pair<u8> { left: 40, right: 2 };
        \\    return (pair.left as i32) + (pair.right as i32);
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "generic_packed_struct_values", "native_generic_packed_struct_values.cy", source, 42);
}
