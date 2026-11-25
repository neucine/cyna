const std = @import("std");

const backend_support = @import("support.zig");

test "LLVM uses selected target C integer widths in C ABI signatures and cstruct fields" {
    const source =
        \\c struct Pair {
        \\    left: c_int;
        \\    right: c_short;
        \\}
        \\
        \\extern {
        \\    c("mix") fn mix(value: c_int, pair: Pair): c_short;
        \\}
        \\
        \\export c("bounce") fn bounce(value: c_uint): c_ulong {
        \\    return value as c_ulong;
        \\}
        \\
        \\fn main(): i32 {
        \\    const pair = Pair { left: 1, right: 2 };
        \\    return mix(1, pair) as i32;
        \\}
    ;

    const text = try backend_support.lowerLlvmText(std.testing.allocator, "llvm_c_abi_host_widths.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "declare i16 @mix(i32 %arg0, i64 %arg1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "define i64 @bounce(i32 %arg0)") != null);
}

test "Windows C callbacks use an adapter for ordinary Cyna functions" {
    const source =
        \\c struct Pair {
        \\    left: c_llong;
        \\    right: c_llong;
        \\}
        \\
        \\type PairCallback = c fn (
        \\    context: *c_void,
        \\    value: Pair,
        \\    count: c_int,
        \\    arguments: *const Pair
        \\): Pair;
        \\
        \\extern {
        \\    c("install") fn install(callback: PairCallback): void;
        \\}
        \\
        \\fn callback(
        \\    context: *c_void,
        \\    value: Pair,
        \\    count: c_int,
        \\    arguments: *const Pair
        \\): Pair {
        \\    const ignored_context = context;
        \\    const ignored_count = count;
        \\    const ignored_arguments = arguments;
        \\    return value;
        \\}
        \\
        \\fn main(): i32 {
        \\    install(callback);
        \\    return 0;
        \\}
    ;

    const text = try backend_support.lowerLlvmTextWithTarget(
        std.testing.allocator,
        "windows_c_callback_adapter.cy",
        source,
        "x86_64-pc-windows-gnu",
    );
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "__cyna_c_abi_adapter_0") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "define { i64, i64 } @cyna_fn_",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "ptr sret({ i64, i64 })",
    ) != null);
}

test "Darwin AArch64 C ABI passes three-float struct as homogeneous aggregate" {
    const source =
        \\c struct Pixel { red: c_float; green: c_float; blue: c_float; }
        \\export c("expose") fn expose(pixel: Pixel, gain: c_float): Pixel {
        \\    return { red: pixel.red * gain, green: pixel.green * gain, blue: pixel.blue * gain };
        \\}
    ;
    const text = try backend_support.lowerLlvmTextWithTarget(std.testing.allocator, "darwin_three_float_pixel.cy", source, "aarch64-apple-darwin");
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "define [3 x float] @expose([3 x float] %abi_arg0, float %arg1)") != null);
}

test "Darwin AArch64 C ABI keeps three-double homogeneous aggregate direct" {
    const source =
        \\c struct Vector { x: c_double; y: c_double; z: c_double; }
        \\export c("bounce_vector") fn bounce_vector(value: Vector): Vector { return value; }
    ;
    const text = try backend_support.lowerLlvmTextWithTarget(std.testing.allocator, "darwin_three_double_vector.cy", source, "aarch64-apple-darwin");
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "define [3 x double] @bounce_vector([3 x double] %abi_arg0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "sret(") == null);
}

test "AArch64 ordinary large aggregate handoff lowers indirectly" {
    const source =
        \\struct Big {
        \\    a: usize;
        \\    b: usize;
        \\    c: usize;
        \\    d: usize;
        \\    e: usize;
        \\    f: usize;
        \\    g: usize;
        \\    h: usize;
        \\}
        \\
        \\fn make(): Big {
        \\    return Big { a: 1, b: 2, c: 3, d: 4, e: 5, f: 6, g: 7, h: 14 };
        \\}
        \\
        \\fn bounce(value: Big): Big {
        \\    return value;
        \\}
        \\
        \\fn sum(value: Big): usize {
        \\    return value.a + value.b + value.c + value.d + value.e + value.f + value.g + value.h;
        \\}
        \\
        \\fn main(): i32 {
        \\    const made = make();
        \\    const bounced = bounce(made);
        \\    return sum(bounced) as i32;
        \\}
    ;

    const text = try backend_support.lowerLlvmTextWithTarget(std.testing.allocator, "aarch64_internal_large_aggregate.cy", source, "aarch64-none-elf");
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "sret({ i64, i64, i64, i64, i64, i64, i64, i64 })") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ptr %abi_arg0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "load { i64, i64, i64, i64, i64, i64, i64, i64 }, ptr %abi_arg0, align 8") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "define { i64, i64, i64, i64, i64, i64, i64, i64 }") == null);
}
