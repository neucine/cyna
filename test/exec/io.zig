const std = @import("std");

const helpers = @import("../helpers.zig");

test "print and println support string bool and integer values" {
    const source =
        \\fn main(): i32 {
        \\    print("hello");
        \\    println(true);
        \\    println(42);
        \\    return 42;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "print_basic_values", "native_print_basic_values.cy", source, 42);
}

test "panic is available from the bundled prelude" {
    const link_source =
        \\fn main(): i32 {
        \\    if false {
        \\        panic("unreachable");
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "panic_prelude_native_link", "native_panic_prelude_link.cy", link_source, 0);

    const panic_source =
        \\fn main(): i32 {
        \\    panic("boom");
        \\    return 0;
        \\}
    ;

    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const outcome = try helpers.test_exec.runNativeSourceOutcome(scratch.allocator(), "native_panic_prelude_failure.cy", panic_source);
    try std.testing.expectEqual(helpers.test_exec.NativeRunOutcome{ .exited = 101 }, outcome);
}

test "terminal panic and false assertion end non-void paths" {
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const allocator = scratch.allocator();
    const panic_outcome = try helpers.test_exec.runNativeSourceOutcome(allocator, "native_terminal_panic.cy",
        \\fn fail(): i32 { panic("stopped"); }
        \\fn main(): i32 { return fail(); }
    );
    try std.testing.expectEqual(helpers.test_exec.NativeRunOutcome{ .exited = 101 }, panic_outcome);
    try helpers.expectNativeNamedSourceExitCode(allocator, "conditional_terminal_panic", "native_conditional_terminal_panic.cy",
        \\fn choose(stop: bool): i32 {
        \\    if stop { panic("stopped"); } else { return 42; }
        \\}
        \\fn main(): i32 { return choose(false); }
    , 42);
    try helpers.test_exec.expectNativeSourceFailureMessage(allocator, "native_terminal_assert.cy",
        \\fn fail(): i32 { assert(false); }
        \\fn main(): i32 { return fail(); }
    , "cyna assertion failed");
}

test "println accepts named unsigned integers" {
    const source =
        \\fn main(): i32 {
        \\    const value: u8 = 42;
        \\    println(value);
        \\    return 0;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "println_named_unsigned_int", "native_print_named_unsigned_int.cy", source, 0);
}

test "interpolated strings support projection bool and integer formats" {
    const source =
        \\struct User {
        \\    pub name: string;
        \\    pub id: i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    const user = User { name: "ada", id: 26 };
        \\    const ok = true;
        \\    const msg = $"name={user.name} id={user.id:x}/{user.id:X}/{user.id:b}/{user.id:o} ok={ok} braces=\{\}";
        \\    if msg == "name=ada id=1a/1A/11010/32 ok=true braces={}" {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "interpolated_string_projection_formats", "native_interpolated_string_projection_formats.cy", source, 42);
}

test "numeric plus still works after string plus rejection" {
    const source =
        \\fn main(): i32 {
        \\    if 40 + 2 == 42 {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, "numeric_plus_still_works", "native_numeric_plus_still_works.cy", source, 42);
}
