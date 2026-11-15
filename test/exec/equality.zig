const std = @import("std");
const helpers = @import("../helpers.zig");

test "sequence equality works for arrays slices dense and sparse storage" {
    const source =
        \\enum Mode: i32 {
        \\    read = 1,
        \\    write,
        \\}
        \\
        \\fn check_fixed_arrays(): i32 {
        \\    const a: [3]i32 = [1, 2, 3];
        \\    const b: [3]i32 = [1, 2, 3];
        \\    const c: [3]i32 = [1, 2, 4];
        \\    if not (a == b) {
        \\        return 1;
        \\    }
        \\    if a == c {
        \\        return 2;
        \\    }
        \\    if a != b {
        \\        return 3;
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn check_slices(): i32 {
        \\    var a: [3]i32 = [1, 2, 3];
        \\    const b: [3]i32 = [1, 2, 3];
        \\    const c: [2]i32 = [1, 2];
        \\    if not (a[..] == b[..]) {
        \\        return 10;
        \\    }
        \\    if a[..] == c[..] {
        \\        return 11;
        \\    }
        \\    if "abc".bytes() != "abc".bytes() {
        \\        return 12;
        \\    }
        \\    if "abc".bytes() == "abd".bytes() {
        \\        return 13;
        \\    }
        \\    var mutable: []i32 = a[..];
        \\    var readonly: []const i32 = b[..];
        \\    if not (mutable == readonly) {
        \\        return 14;
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn check_dense_storage(): i32 {
        \\    const a: [:]i32 = [1, 2, 3];
        \\    const b: [:]i32 = [1, 2, 3];
        \\    const c: [:]i32 = [1, 2];
        \\    const d: [:]i32 = [1, 2, 4];
        \\    if not (a == b) {
        \\        return 20;
        \\    }
        \\    if a == c {
        \\        return 21;
        \\    }
        \\    if a == d {
        \\        return 22;
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn check_sparse_storage(): i32 {
        \\    const a: [;]i32 = [; 8] { 1: 10, 4: 20 };
        \\    const b: [;]i32 = [; 16] { 1: 10, 4: 20 };
        \\    const c: [;]i32 = [; 8] { 1: 10, 5: 20 };
        \\    const d: [;]i32 = [; 8] { 1: 10, 4: 21 };
        \\    if not (a == b) {
        \\        return 30;
        \\    }
        \\    if a == c {
        \\        return 31;
        \\    }
        \\    if a == d {
        \\        return 32;
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn check_string_arrays(): i32 {
        \\    const a: [2]string = ["Ada", "Ken"];
        \\    const b: [2]string = ["Ada", "Ken"];
        \\    const c: [2]string = ["Ada", "Lin"];
        \\    if not (a == b) {
        \\        return 40;
        \\    }
        \\    if a == c {
        \\        return 41;
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn check_enum_arrays(): i32 {
        \\    const a: [2]Mode = [Mode.read, Mode.write];
        \\    const b: [2]Mode = [Mode.read, Mode.write];
        \\    const c: [2]Mode = [Mode.write, Mode.read];
        \\    if not (a == b) {
        \\        return 50;
        \\    }
        \\    if a == c {
        \\        return 51;
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn check_float_sequences(): i32 {
        \\    const a: [3]f64 = [1.5, 2.5, 3.5];
        \\    const b: [3]f64 = [1.5, 2.5, 3.5];
        \\    const c: [3]f64 = [1.5, 2.5, 4.5];
        \\    if not (a == b) {
        \\        return 60;
        \\    }
        \\    if a == c {
        \\        return 61;
        \\    }
        \\    const xs: [:]f32 = [1.25, 2.25];
        \\    const ys: [:]f32 = [1.25, 2.25];
        \\    const zs: [:]f32 = [1.25, 3.25];
        \\    if not (xs == ys) {
        \\        return 62;
        \\    }
        \\    if xs == zs {
        \\        return 63;
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn main(): i32 {
        \\    if check_fixed_arrays() != 0 {
        \\        return check_fixed_arrays();
        \\    }
        \\    if check_slices() != 0 {
        \\        return check_slices();
        \\    }
        \\    if check_dense_storage() != 0 {
        \\        return check_dense_storage();
        \\    }
        \\    if check_sparse_storage() != 0 {
        \\        return check_sparse_storage();
        \\    }
        \\    if check_string_arrays() != 0 {
        \\        return check_string_arrays();
        \\    }
        \\    if check_enum_arrays() != 0 {
        \\        return check_enum_arrays();
        \\    }
        \\    if check_float_sequences() != 0 {
        \\        return check_float_sequences();
        \\    }
        \\    return 42;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(
        std.testing.allocator,
        "sequence_equality_runtime",
        "native_sequence_equality_runtime.cy",
        source,
        42,
    );
}
