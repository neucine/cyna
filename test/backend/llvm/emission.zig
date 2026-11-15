const std = @import("std");

test "LLVM hoists fixed local and ABI allocations out of loops" {
    const text = try lowerLlvmText(std.testing.allocator, "llvm_loop_stack.cy",
        \\struct Payload { first: i64; second: i64; third: i64; }
        \\fn identity(value: Payload): Payload { return value; }
        \\fn main(): i32 {
        \\    var index: i32 = 0;
        \\    var answer: i32 = 0;
        \\    while index < 4 {
        \\        const local = identity(Payload { first: 42, second: 0, third: 0 });
        \\        answer = local.first as i32;
        \\        index = index + 1;
        \\    }
        \\    return answer;
        \\}
    );
    defer std.testing.allocator.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var after_terminator = false;
    var allocations: usize = 0;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "define ")) after_terminator = false;
        if (std.mem.indexOf(u8, line, " = alloca ") != null) {
            try std.testing.expect(!after_terminator);
            allocations += 1;
        }
        if (std.mem.startsWith(u8, line, "  br ") or std.mem.startsWith(u8, line, "  ret ")) after_terminator = true;
    }
    try std.testing.expect(allocations > 0);
}
const builtin = @import("builtin");
const cyna = @import("cyna");
const compat = cyna.compat;
const backend_support = @import("support.zig");
const test_exec = backend_support.test_exec;
const lowerLlvmText = backend_support.lowerLlvmText;
const lowerLlvmTextWithTarget = backend_support.lowerLlvmTextWithTarget;
const lowerLlvmFileText = backend_support.lowerLlvmFileText;
const runNativeSourceExitCode = backend_support.runNativeSourceExitCode;
const runNativeSourceExitCodeWithCSources = backend_support.runNativeSourceExitCodeWithCSources;
const runNativeFileExitCode = backend_support.runNativeFileExitCode;

// Public backend facade plus backend tests. The implementation details live
// under src/compiler/backend/llvm/.

test "LLVM emits return constant" {
    const source =
        \\fn main(): i32 {
        \\    return 42;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_return_const.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "define i32 @main()") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ret i32 42") != null);
}

test "LLVM emits param add return" {
    const source =
        \\fn add_one(x: i32): i32 {
        \\    var y = x + 1;
        \\    return y;
        \\}
        \\
        \\fn main(): i32 {
        \\    return add_one(41);
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_add_one.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "define i32 @cyna_fn_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "_add_one(i32 %arg0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "alloca i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "add i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ret i32 %v") != null);
}

test "LLVM emits integer remainder" {
    const source =
        \\fn main(): i32 {
        \\    return 17 % 16;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_int_remainder.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "srem i64 17, 16") != null);
}

test "LLVM emits float arithmetic and comparison" {
    const source =
        \\fn add(a: f64, b: f64): f64 {
        \\    return a + b;
        \\}
        \\
        \\fn main(): i32 {
        \\    if add(40.5, 1.5) == 42.0 {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_float_add.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "define double ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fadd double") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fcmp oeq double") != null);
}

test "LLVM float inequality includes NaN" {
    const source =
        \\fn different(value: f32): bool {
        \\    return value != value;
        \\}
        \\fn main(): i32 {
        \\    if different(1.0 as f32) { return 1; }
        \\    return 0;
        \\}
    ;
    const text = try lowerLlvmText(std.testing.allocator, "llvm_float_nan_inequality.cy", source);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "fcmp une float") != null);
}

test "LLVM emits debug metadata for function source locations" {
    const source =
        \\fn main(): i32 {
        \\    return 42;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_debug_info.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "!llvm.dbg.cu = !{!0}") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "!DICompileUnit(") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "!DISubprogram(name: \"main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "!3 = !DISubroutineType(") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "define i32 @main() !dbg !") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call void asm sideeffect \"\", \"\"(), !dbg !") != null);
}

test "LLVM uses ABI symbol names for extern and export C functions" {
    const source =
        \\extern {
        \\    c("abs") fn c_abs(value: c_int): c_int;
        \\}
        \\
        \\export c("native_add") fn local_add(value: c_int): c_int {
        \\    return c_abs(value) + 1;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_c_abi_symbols.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "declare i32 @abs(i32 %arg0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "define i32 @native_add(i32 %arg0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call i32 @abs(i32 %") != null);
}

test "LLVM suppresses extern declaration when matching C ABI export is present" {
    const source =
        \\extern {
        \\    c("cycor_console_putc") fn platform_putc(ch: c_uchar): void;
        \\}
        \\
        \\export c("cycor_console_putc") fn qemu_putc(ch: c_uchar): void {
        \\}
        \\
        \\export c("call_hook") fn call_hook(): void {
        \\    platform_putc(65 as c_uchar);
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_c_abi_extern_export_pair.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "declare void @cycor_console_putc") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "define void @cycor_console_putc(i8 %arg0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call void @cycor_console_putc(i8 %") != null);
}

test "LLVM gives mixed keyword and attribute ABI spellings one symbol" {
    const source =
        \\@abi("c")
        \\@link.import("cycor_console_putc")
        \\fn platform_putc(ch: c_uchar): void;
        \\
        \\export c("cycor_console_putc") fn qemu_putc(ch: c_uchar): void {
        \\}
        \\
        \\export c("call_hook") fn call_hook(): void {
        \\    platform_putc(65 as c_uchar);
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_mixed_spelling_c_abi_pair.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "declare void @cycor_console_putc") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "define void @cycor_console_putc(i8 %arg0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call void @cycor_console_putc(i8 %") != null);
}

test "LLVM gives C ABI declarations conventional default symbols" {
    const source =
        \\extern {
        \\    c fn host_tick(): c_int;
        \\}
        \\
        \\export c fn local_tick(): c_int {
        \\    return host_tick() + 1;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_default_c_abi_symbols.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "declare i32 @cyna_llvm_default_c_abi_symbols_host_tick()") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "define i32 @cyna_llvm_default_c_abi_symbols_local_tick()") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call i32 @cyna_llvm_default_c_abi_symbols_host_tick()") != null);
}

test "LLVM emits extern global symbol imports" {
    const source =
        \\extern {
        \\    c("answer") const answer_ptr: *i32;
        \\    c("counter") var counter: c_int;
        \\}
        \\
        \\fn main(): i32 {
        \\    counter = 2;
        \\    unchecked {
        \\        return *answer_ptr + (counter as i32);
        \\    }
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_extern_global_symbols.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "@answer = external global i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "@counter = external global i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "store i32 2, ptr @counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "load i32, ptr @answer") != null);
}

test "native executes extern C call through ABI symbol name" {
    const source =
        \\extern {
        \\    c("abs") fn c_abs(value: c_int): c_int;
        \\}
        \\
        \\fn main(): i32 {
        \\    return c_abs(-42) as i32;
        \\}
    ;

    try std.testing.expectEqual(@as(i64, 42), try runNativeSourceExitCode(std.testing.allocator, "native_extern_c_abs.cy", source));
}

test "native executes extern global symbol imports" {
    const source =
        \\extern {
        \\    c("answer") const answer_ptr: *i32;
        \\    c("counter") var counter: c_int;
        \\}
        \\
        \\fn main(): i32 {
        \\    counter = 2;
        \\    unchecked {
        \\        return *answer_ptr + (counter as i32);
        \\    }
        \\}
    ;

    const extra_sources = [_]test_exec.ExtraCSource{
        .{
            .name = "symbols.c",
            .source =
            \\#include <stdint.h>
            \\
            \\int32_t answer = 40;
            \\long long counter = 0;
            ,
        },
    };

    try std.testing.expectEqual(
        @as(i64, 42),
        try runNativeSourceExitCodeWithCSources(std.testing.allocator, "native_extern_global_symbols.cy", source, &extra_sources),
    );
}

test "native executes extern C by-value cstruct call through linked helper" {
    const source =
        \\c struct Point {
        \\    x: c_llong;
        \\    y: c_llong;
        \\}
        \\
        \\extern {
        \\    c("sum_point") fn sum_point(point: Point): c_llong;
        \\}
        \\
        \\fn main(): i32 {
        \\    const point = Point { x: 40, y: 2 };
        \\    return sum_point(point) as i32;
        \\}
    ;
    const c_source =
        \\struct Point {
        \\    long long x;
        \\    long long y;
        \\};
        \\
        \\long long sum_point(struct Point point) {
        \\    return point.x + point.y;
        \\}
    ;

    try std.testing.expectEqual(
        @as(i64, 42),
        try runNativeSourceExitCodeWithCSources(
            std.testing.allocator,
            "native_extern_cstruct_value.cy",
            source,
            &.{.{ .name = "abi_helpers.c", .source = c_source }},
        ),
    );
}

test "native executes extern C raw pointer cstruct call through linked helper" {
    const source =
        \\c struct Box {
        \\    value: c_llong;
        \\}
        \\
        \\extern {
        \\    c("load_box") fn load_box(box: *Box): c_llong;
        \\}
        \\
        \\fn main(): i32 {
        \\    var box = new Box { value: 42 };
        \\    const ptr: *Box = box.ptr();
        \\    return load_box(ptr) as i32;
        \\}
    ;
    const c_source =
        \\struct Box {
        \\    long long value;
        \\};
        \\
        \\long long load_box(const struct Box *box) {
        \\    return box->value;
        \\}
    ;

    try std.testing.expectEqual(
        @as(i64, 42),
        try runNativeSourceExitCodeWithCSources(
            std.testing.allocator,
            "native_extern_cstruct_ptr.cy",
            source,
            &.{.{ .name = "abi_helpers.c", .source = c_source }},
        ),
    );
}

test "native executes exported C by-value cstruct call through linked helper" {
    const source =
        \\c struct Pair {
        \\    left: c_llong;
        \\    right: c_llong;
        \\}
        \\
        \\extern {
        \\    c("call_native_sum") fn call_native_sum(): c_llong;
        \\}
        \\
        \\export c("native_sum") fn native_sum(pair: Pair): c_llong {
        \\    return pair.left + pair.right;
        \\}
        \\
        \\fn main(): i32 {
        \\    return call_native_sum() as i32;
        \\}
    ;
    const c_source =
        \\struct Pair {
        \\    long long left;
        \\    long long right;
        \\};
        \\
        \\long long native_sum(struct Pair pair);
        \\
        \\long long call_native_sum(void) {
        \\    struct Pair pair = { 40, 2 };
        \\    return native_sum(pair);
        \\}
    ;

    try std.testing.expectEqual(
        @as(i64, 42),
        try runNativeSourceExitCodeWithCSources(
            std.testing.allocator,
            "native_export_cstruct_value.cy",
            source,
            &.{.{ .name = "abi_helpers.c", .source = c_source }},
        ),
    );
}

test "LLVM uses native target C integer widths in C ABI signatures and cstruct fields" {
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

    const text = try lowerLlvmText(std.testing.allocator, "llvm_c_abi_host_widths.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "declare i16 @mix(i32 %arg0, i64 %arg1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "alloca { i32, i16 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "define i32 @main()") != null);
}

test "LLVM uses selected target pointer-sized C ABI integer widths" {
    const source =
        \\extern {
        \\    c("take_size") fn take_size(value: c_size_t): c_ulong;
        \\}
        \\
        \\export c("bounce_size") fn bounce_size(value: c_size_t): c_ulong {
        \\    return value as c_ulong;
        \\}
        \\
        \\fn main(): i32 {
        \\    return take_size(1) as i32;
        \\}
    ;

    const text = try lowerLlvmTextWithTarget(std.testing.allocator, "llvm_c_abi_riscv32_widths.cy", source, "riscv32-none-elf");
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "declare i32 @take_size(i32 %arg0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "define i32 @bounce_size(i32 %arg0)") != null);
}

test "LLVM emits packed struct literals and field reads through integer carriers" {
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

    const text = try lowerLlvmText(std.testing.allocator, "llvm_packed_layout_reads.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "define i32 @main()") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "zext i1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "shl i8") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "lshr i8") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "trunc i8") != null);
}

test "LLVM emits packed raw-pointer field writes through rebuilt carriers" {
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

    const text = try lowerLlvmText(std.testing.allocator, "llvm_packed_layout_write_supported.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "extract_field") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "lshr i8") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "shl i8") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "store i8") != null);
}

test "LLVM emits mixed int and float arithmetic with coercion" {
    const source =
        \\fn add(a: i32, b: f64): f64 {
        \\    return a + b;
        \\}
        \\
        \\fn main(): i32 {
        \\    if add(40, 2.0) == 42.0 {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_mixed_float_add.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "sitofp i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fadd double") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fcmp oeq double") != null);
}

test "native mixed int and float arithmetic runs" {
    const source =
        \\fn main(): i32 {
        \\    const base: f32 = 20.5;
        \\    if (base + 21) == 41.5 {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    try std.testing.expectEqual(@as(i64, 42), try runNativeSourceExitCode(std.testing.allocator, "native_mixed_float_add.cy", source));
}

test "native list string push keeps stored string alive after local drop and grow" {
    const source =
        \\fn add(names: &List<string>, value: []const u8): void {
        \\    const symbol = string.from(value);
        \\    names.push(symbol);
        \\    drop symbol;
        \\}
        \\
        \\fn contains(names: &List<string>, value: []const u8): bool {
        \\    var index: usize = 0;
        \\    while index < names.len() {
        \\        if names[index].bytes() == value {
        \\            return true;
        \\        }
        \\        index = index + 1;
        \\    }
        \\    return false;
        \\}
        \\
        \\fn main(): i32 {
        \\    var names: List<string> = list<string>();
        \\    add(&names, "java/lang/Object".bytes());
        \\    add(&names, "java/lang/String".bytes());
        \\    add(&names, "java/lang/Class".bytes());
        \\    add(&names, "java/lang/System".bytes());
        \\    add(&names, "[Ljava/lang/String;".bytes());
        \\    if contains(&names, "java/lang/Object".bytes()) {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    try std.testing.expectEqual(@as(i64, 42), try runNativeSourceExitCode(std.testing.allocator, "native_list_string_push_drop_grow.cy", source));
}

test "LLVM emits checked float casts" {
    const source =
        \\fn main(): i32 {
        \\    const raw: f64 = 42.0;
        \\    const narrowed = raw as f32;
        \\    const whole = narrowed as i32;
        \\    const exact = whole as f64;
        \\    if exact == 42.0 {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_float_casts.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "fptrunc double") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fptosi float") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "sitofp i32") != null);
}

test "native checked float casts run" {
    const source =
        \\fn main(): i32 {
        \\    const raw: f64 = 42.0;
        \\    const whole = raw as i32;
        \\    const exact = whole as f64;
        \\    if exact == 42.0 {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    try std.testing.expectEqual(@as(i64, 42), try runNativeSourceExitCode(std.testing.allocator, "native_float_casts.cy", source));
}

test "native checked f32 to int casts run" {
    const source =
        \\fn main(): i32 {
        \\    const raw: f32 = 42.0;
        \\    const whole = raw as i32;
        \\    const exact = whole as f32;
        \\    if exact == 42.0 {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    try std.testing.expectEqual(@as(i64, 42), try runNativeSourceExitCode(std.testing.allocator, "native_f32_to_int_casts.cy", source));
}

test "native fallible float to int cast truncates in-range values" {
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

    try std.testing.expectEqual(@as(i64, 42), try runNativeSourceExitCode(std.testing.allocator, "native_float_casts_fallible.cy", source));
}

test "LLVM emits checked integer and enum casts" {
    const source =
        \\enum Color: i32 {
        \\    red = 42,
        \\    blue = 7,
        \\}
        \\
        \\fn main(): i32 {
        \\    const raw: i64 = 42;
        \\    const small = raw as i32;
        \\    const color = small as Color;
        \\    const exact = color as i32;
        \\    return exact;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_int_enum_casts.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "icmp sge i64") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "icmp sle i64") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "or i1") != null);
}

test "native checked integer and enum casts run" {
    const source =
        \\enum Color: i32 {
        \\    red = 42,
        \\    blue = 7,
        \\}
        \\
        \\fn main(): i32 {
        \\    const raw: i64 = 42;
        \\    const color = raw as Color;
        \\    const exact = color as i32;
        \\    return exact;
        \\}
    ;

    try std.testing.expectEqual(@as(i64, 42), try runNativeSourceExitCode(std.testing.allocator, "native_int_enum_casts.cy", source));
}

test "native fallible integer to enum cast returns none" {
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

    try std.testing.expectEqual(@as(i64, 42), try runNativeSourceExitCode(std.testing.allocator, "native_int_enum_casts_fallible.cy", source));
}

test "LLVM emits optional and union payload casts" {
    const source =
        \\union Token {
        \\    ident: string;
        \\    code: i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    const value: ?i32 = 42;
        \\    const token: Token = .code(value as i32);
        \\    const code = token as? i32;
        \\    if code is value2 {
        \\        return value2;
        \\    }
        \\    return 0;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_optional_union_casts.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "extractvalue { i8, i32 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extractvalue { i64, { ptr, i64 }, i32 }") != null or std.mem.indexOf(u8, text, "extractvalue { i64, i32, { ptr, i64 } }") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "insertvalue { i8, i32 }") != null);
}

test "native optional cast unwrap runs" {
    const source =
        \\fn main(): i32 {
        \\    const value: ?i32 = 42;
        \\    return value as i32;
        \\}
    ;

    try std.testing.expectEqual(@as(i64, 42), try runNativeSourceExitCode(std.testing.allocator, "native_optional_cast.cy", source));
}

test "native fallible optional cast returns none" {
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

    try std.testing.expectEqual(@as(i64, 42), try runNativeSourceExitCode(std.testing.allocator, "native_optional_cast_fallible.cy", source));
}

test "native union payload casts run" {
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

    try std.testing.expectEqual(@as(i64, 42), try runNativeSourceExitCode(std.testing.allocator, "native_union_cast.cy", source));
}

test "native fallible union payload cast returns none" {
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

    try std.testing.expectEqual(@as(i64, 42), try runNativeSourceExitCode(std.testing.allocator, "native_union_cast_fallible.cy", source));
}

test "LLVM emits conditional branch" {
    const source =
        \\fn choose(x: i32): i32 {
        \\    if x > 0 {
        \\        return 1;
        \\    } else {
        \\        return 2;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    return choose(1);
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_if.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "icmp sgt i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "br i1 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "bb1_if_then:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "bb2_if_else:") != null);
}

test "LLVM emits checked error control flow" {
    const source =
        \\enum Status: i32 {
        \\    ok = 0,
        \\    failed,
        \\}
        \\
        \\fn produce(): i32!Status {
        \\    return 42;
        \\}
        \\
        \\fn run(): i32!Status {
        \\    const value = try produce();
        \\    return value;
        \\}
        \\
        \\fn main(): i32 {
        \\    const value = run() catch (status) {
        \\        const ignored = status;
        \\        return 1;
        \\    };
        \\    return value;
        \\}
    ;

    const text = try lowerLlvmTextWithTarget(std.testing.allocator, "llvm_result.cy", source, "aarch64-apple-darwin");
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "define void @cyna_fn_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "sret({ i8, i32, i32, { ptr, i32, i32 } })") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "insertvalue { i8, i32, i32, { ptr, i32, i32 } }") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extractvalue { i8, i32, i32, { ptr, i32, i32 } }") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call void @cyna_fn_") != null);
}

test "LLVM transfers one trace record through try and releases a handled catch" {
    const source =
        \\enum Fault { bad; }
        \\fn inner(): i32!Fault { throw Fault.bad; }
        \\fn middle(): i32!Fault { return try inner(); }
        \\fn main(): i32 { return middle() catch (code) { yield 7; }; }
    ;
    const text = try lowerLlvmText(std.testing.allocator, "llvm_trace_transfer.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "call void @cyna_trace_create_location_abi"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "call void @cyna_trace_append_location_abi"));
    try std.testing.expect(std.mem.count(u8, text, "call void @cyna_trace_release_abi") >= 1);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "call void @cyna_trace_release_root"));
}

test "LLVM emits optional control flow" {
    const source =
        \\fn maybe(pass: bool): ?i32 {
        \\    if pass {
        \\        return 42;
        \\    } else {
        \\        return none;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    const value = maybe(true);
        \\    if value is n {
        \\        return n;
        \\    } else {
        \\        return 1;
        \\    }
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_optional.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "define { i8, i32 } ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "insertvalue { i8, i32 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call { i8, i32 } ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extractvalue { i8, i32 }") != null);
}

test "LLVM emits optional local take as load and clear" {
    const source =
        \\fn main(): i32 {
        \\    var value: ?i32 = 42;
        \\    const taken = take value;
        \\    if taken is n {
        \\        return n;
        \\    }
        \\    return 0;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_take_optional_local.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "alloca { i8, i32 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "load { i8, i32 }, ptr %v0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "insertvalue { i8, i32 } undef, i8 0, 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "store { i8, i32 } %") != null);
}

test "LLVM emits optional field take as field pointer load and clear" {
    const source =
        \\struct Profile {
        \\    age: i32;
        \\}
        \\
        \\struct User {
        \\    profile: ?Profile;
        \\}
        \\
        \\fn main(): i32 {
        \\    var user = User { profile: Profile { age: 42 } };
        \\    const taken = take user.profile;
        \\    if taken is profile {
        \\        return profile.age;
        \\    }
        \\    return 0;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_take_optional_field.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "getelementptr inbounds { { i8, { i32 } } }, ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "load { i8, { i32 } }, ptr %") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "insertvalue { i8, { i32 } } undef, i8 0, 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "store { i8, { i32 } } %") != null);
}

test "LLVM emits Array optional take through list-backed storage" {
    const source =
        \\fn main(): i32 {
        \\    var slots = [:]?i32 [none, none];
        \\    slots[0] = 42;
        \\    const taken = take slots[0];
        \\    if taken is n {
        \\        if slots[0] is none {
        \\            return n;
        \\        }
        \\    }
        \\    return 0;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_take_array_optional.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "@cyna_desc_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "define void @cyna_copy_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "declare ptr @cyna_dense_new(ptr)") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call void @cyna_dense_push_copy") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call void %") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call ptr @cyna_dense_at") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extractvalue { ptr, i64, i64 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "getelementptr inbounds") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call void @cyna_drop_") != null);
}

test "LLVM emits Array params and returns through runtime-array ABI" {
    const source =
        \\fn passthrough(slots: [:]?i32): [:]?i32 {
        \\    return slots;
        \\}
        \\
        \\fn main(): i32 {
        \\    var slots = [:]?i32 [none];
        \\    slots[0] = 42;
        \\    var out = passthrough(slots);
        \\    if out[0] is n {
        \\        return n;
        \\    }
        \\    return 0;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_array_signature_passthrough.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "define { ptr, i64, i64 } ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call { ptr, i64, i64 } ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call ptr @cyna_dense_at") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extractvalue { ptr, i64, i64 }") != null);
}

test "LLVM emits slice map and set function signatures" {
    const source =
        \\fn first(values: []i32): i32 {
        \\    return values[0];
        \\}
        \\
        \\fn make_scores(): Map<string, i32> {
        \\    var scores: Map<string, i32> = map<string, i32>();
        \\    scores["ok"] = 42;
        \\    return scores;
        \\}
        \\
        \\fn make_seen(): Set<i32> {
        \\    var seen: Set<i32> = set<i32>();
        \\    seen.add(42);
        \\    return seen;
        \\}
        \\
        \\fn main(): i32 {
        \\    var values: [1]i32 = [1]i32 [ 42 ];
        \\    var view: []i32 = values[..];
        \\    var seen = make_seen();
        \\    var total: i32 = 0;
        \\    for value in seen {
        \\        total = total + value;
        \\    }
        \\    var scores = make_scores();
        \\    return first(view) + scores["ok"] + total - 42;
        \\}
    ;

    const text = try lowerLlvmTextWithTarget(std.testing.allocator, "llvm_container_signature_mix.cy", source, "aarch64-apple-darwin");
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "define i32 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ptr sret({ { ptr, ptr, i64, i64 }, i64, i64 })") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call void @cyna_fn_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call i32 @cyna_fn_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call i64 @cyna_fn_") != null);
}

test "LLVM emits raw pointer params returns and dereference" {
    const source =
        \\struct User {
        \\    age: i32;
        \\}
        \\
        \\fn keep(ptr: *User): *User {
        \\    return ptr;
        \\}
        \\
        \\fn main(): i32 {
        \\    var user = new User { age: 42 };
        \\    const ptr: *User = user.ptr();
        \\    const again = keep(ptr);
        \\    unchecked {
        \\        return (*again).age;
        \\    }
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_raw_pointer_passthrough.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "define ptr ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call ptr ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "getelementptr inbounds { i32 }, ptr %") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "load i32, ptr %") != null);
}

test "LLVM emits raw pointer writes inside unchecked" {
    const source =
        \\struct User {
        \\    age: i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    var user = new User { age: 1 };
        \\    const user_ptr: *User = user.ptr();
        \\    unchecked {
        \\        *user_ptr = User { age: 40 };
        \\        (*user_ptr).age = 42;
        \\    }
        \\    return user.age;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_raw_pointer_writes.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "store { i32 } %") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "getelementptr inbounds { i32 }, ptr %") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "insertvalue { i32 } undef, i32 42, 0") != null);
}

test "LLVM emits volatile raw pointer loads and stores" {
    const source =
        \\c struct User {
        \\    age: c_int;
        \\}
        \\
        \\export c("touch_user") fn touch(user_ptr: *volatile User): c_int {
        \\    unchecked {
        \\        *user_ptr = User { age: 40 };
        \\        (*user_ptr).age = 42;
        \\        return (*user_ptr).age;
        \\    }
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_volatile_raw_pointer_ops.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "store volatile { i32 } %") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "load volatile { i32 }, ptr %") != null);
}

test "LLVM emits integer to volatile raw pointer reinterpretation" {
    const source =
        \\c struct UartRegs {
        \\    dr: c_uint;
        \\}
        \\
        \\export c("uart0") fn uart0(): *volatile UartRegs {
        \\    unchecked {
        \\        return 0x40001000 as! *volatile UartRegs;
        \\    }
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_int_to_volatile_raw_ptr.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "inttoptr i64 1073745920 to ptr") != null);
}

test "LLVM emits volatile packed struct field reads through a volatile load" {
    const source =
        \\packed struct StatusReg {
        \\    ready: u1;
        \\    mode: u3;
        \\    error: u4;
        \\}
        \\
        \\fn read_error(regs: *volatile StatusReg): u8 {
        \\    unchecked {
        \\        return (*regs).error as u8;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    unchecked {
        \\        const regs = 0 as! *volatile StatusReg;
        \\        return read_error(regs) as i32;
        \\    }
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_volatile_packed_field_read.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "load volatile i8, ptr %") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "lshr i8") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "trunc i8") != null);
}

test "LLVM emits volatile packed struct field writes through volatile rebuilt carriers" {
    const source =
        \\packed struct StatusReg {
        \\    ready: u1;
        \\    mode: u3;
        \\    error: u4;
        \\}
        \\
        \\fn poke(regs: *volatile StatusReg): void {
        \\    unchecked {
        \\        (*regs).mode = 4;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    unchecked {
        \\        const regs = 0 as! *volatile StatusReg;
        \\        poke(regs);
        \\    }
        \\    return 0;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_volatile_packed_field_write.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "load volatile i8, ptr %") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "lshr i8") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "shl i8") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "store volatile i8") != null);
}

test "LLVM emits volatile raw pointer to integer reinterpretation" {
    const source =
        \\c struct UartRegs {
        \\    dr: c_uint;
        \\}
        \\
        \\export c("base") fn base(ptr: *volatile UartRegs): c_ulong {
        \\    unchecked {
        \\        return ptr as! c_ulong;
        \\    }
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_volatile_raw_ptr_to_int.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "ptrtoint ptr %") != null);
}

test "LLVM emits raw pointer indexed field writes inside unchecked" {
    const source =
        \\struct Bag {
        \\    values: [2]i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    var bag = new Bag { values: [1, 2] };
        \\    const ptr: *Bag = bag.ptr();
        \\    unchecked {
        \\        (*ptr).values[0] = 42;
        \\    }
        \\    return bag.values[0];
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_raw_pointer_indexed_field_writes.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "{ [2 x i32] }") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "getelementptr inbounds { [2 x i32] }, ptr %") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "getelementptr inbounds [2 x i32], ptr %") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "store i32 42, ptr %") != null);
}

test "LLVM emits unchecked cunion field reads" {
    const source =
        \\c union Raw {
        \\    int_value: i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    unchecked {
        \\        const ptr = 0 as! *Raw;
        \\        return (*ptr).int_value;
        \\    }
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_cunion_field_read_unchecked.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "define i32 @main()") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extractvalue { i64, i32 } %") != null);
}

test "LLVM emits inline asm inside unchecked" {
    if (builtin.target.cpu.arch != .aarch64) return;

    const source =
        \\fn main(): i32 {
        \\    unchecked {
        \\        asm volatile {
        \\            "add {left}, {right}";
        \\            in left = 40;
        \\            in right = 2;
        \\            clobber memory;
        \\            clobber flags;
        \\            clobber x0;
        \\        }
        \\    }
        \\    return 42;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_inline_asm_unchecked.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "call void asm sideeffect \"add $0, $1\", \"r,r,~{memory},~{cc},~{x0}\"(i64 40, i64 2)") != null);
}

test "LLVM emits inline asm expression result" {
    const source =
        \\fn main(): i32 {
        \\    unchecked {
        \\        const value = asm(i32) {
        \\            "add {result}, {left}, {right}";
        \\            out reg result;
        \\            in reg left = 40;
        \\            in reg right = 2;
        \\        };
        \\        return value;
        \\    }
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_inline_asm_expr.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "= call i32 asm \"add $0, $1, $2\", \"=r,r,r\"(i64 40, i64 2)") != null);
}

test "LLVM emits inline asm expression inout operand" {
    const source =
        \\fn main(): i32 {
        \\    unchecked {
        \\        const value = asm(i32) {
        \\            "add {acc}, {rhs}";
        \\            inout reg acc = 40;
        \\            in reg rhs = 2;
        \\        };
        \\        return value;
        \\    }
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_inline_asm_expr_inout.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "= call i32 asm \"add $0, $1\", \"+r,r\"(i64 40, i64 2)") != null);
}

test "LLVM emits inline asm expression tied input operand" {
    const source =
        \\fn main(): i32 {
        \\    unchecked {
        \\        const value = asm(i32) {
        \\            "add {result}, {seed}";
        \\            out reg result;
        \\            in tied reg seed = 40;
        \\        };
        \\        return value;
        \\    }
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_inline_asm_expr_tied.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "= call i32 asm \"add $0, $1\", \"=r,0\"(i64 40)") != null);
}

test "native executes inline asm inside unchecked" {
    const source =
        \\fn main(): i32 {
        \\    unchecked {
        \\        asm volatile {
        \\            "";
        \\        }
        \\    }
        \\    return 42;
        \\}
    ;

    try std.testing.expectEqual(@as(i64, 42), try runNativeSourceExitCode(std.testing.allocator, "native_inline_asm_unchecked.cy", source));
}

test "LLVM emits top-level globals" {
    const source =
        \\const base: i32 = 40;
        \\const answer: i32 = base + 2;
        \\var counter: i32 = 0;
        \\
        \\fn main(): i32 {
        \\    counter = answer;
        \\    return counter;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_top_level_globals.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "_base = constant i32 40") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "_answer = constant i32 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "_counter = global i32 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "store i32 %v") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "_counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "load i32, ptr @cyna_global_") != null);
}

test "LLVM emits imported public globals across files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "lib");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "lib/math.cy", .data =
        \\
        \\pub const base: i32 = 40;
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\import lib.math;
        \\
        \\const answer: i32 = math.base + 2;
        \\
        \\fn main(): i32 {
        \\    return answer;
        \\}
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(root_path);

    const text = try lowerLlvmFileText(std.testing.allocator, root_path);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "_base = constant i32 40") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "_answer = constant i32 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "load i32, ptr @cyna_global_") != null);
}

test "LLVM emits declarative aggregate globals" {
    const source =
        \\struct Pair {
        \\    left: i32;
        \\    right: i32;
        \\}
        \\
        \\const pair: Pair = Pair { left: 10, right: 32 };
        \\const values: [2]i32 = [1, 42];
        \\
        \\fn main(): i32 {
        \\    return pair.right + values[0];
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_aggregate_globals.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "_pair = constant { i32, i32 } { i32 10, i32 32 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "_values = constant [2 x i32] [i32 1, i32 42]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "getelementptr inbounds { i32, i32 }, ptr @cyna_global_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "load i32, ptr %") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "getelementptr inbounds [2 x i32], ptr @cyna_global_") != null);
}

test "LLVM emits fixed-array struct fields" {
    const source =
        \\struct Bag {
        \\    values: [2]i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    var bag = Bag { values: [1, 2] };
        \\    bag.values[0] = 42;
        \\    return bag.values[0];
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_struct_fixed_array_field.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "{ [2 x i32] }") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "getelementptr inbounds { [2 x i32] }, ptr %") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "getelementptr inbounds [2 x i32], ptr %") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "store i32 42, ptr %") != null);
}

test "LLVM emits projected Array optional take through field path" {
    const source =
        \\struct State {
        \\    slots: [:]?i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    var state = State { slots: [:]?i32 [none, none] };
        \\    state.slots[0] = 42;
        \\    const taken = take state.slots[0];
        \\    if taken is n {
        \\        if state.slots[0] is none {
        \\            return n;
        \\        }
        \\    }
        \\    return 0;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_take_array_optional_field_path.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "{ { ptr, i64, i64 } }") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "getelementptr inbounds { { ptr, i64, i64 } }, ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extractvalue { ptr, i64, i64 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call ptr @cyna_dense_at") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extractvalue { ptr, i64, i64 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call void @cyna_drop_") != null);
}

test "LLVM emits mixed index and field Array optional take path" {
    const source =
        \\struct State {
        \\    slots: [:]?i32;
        \\}
        \\
        \\struct Wrapper {
        \\    state: State;
        \\}
        \\
        \\fn main(): i32 {
        \\    var wrappers: [1]Wrapper = [1]Wrapper [
        \\        Wrapper { state: State { slots: [:]?i32 [none, none] } }
        \\    ];
        \\    wrappers[0].state.slots[0] = 42;
        \\    const taken = take wrappers[0].state.slots[0];
        \\    if taken is n {
        \\        if wrappers[0].state.slots[0] is none {
        \\            return n;
        \\        }
        \\    }
        \\    return 0;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_take_array_optional_mixed_path.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "[1 x { { { ptr, i64, i64 } } }]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "getelementptr inbounds [1 x { { { ptr, i64, i64 } } }], ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "getelementptr inbounds { { { ptr, i64, i64 } } }, ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "getelementptr inbounds { { ptr, i64, i64 } }, ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call ptr @cyna_dense_at") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extractvalue { ptr, i64, i64 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call void @cyna_drop_") != null);
}

test "LLVM emits mixed index and field Array optional resource take path" {
    const source =
        \\struct User {
        \\    age: i32;
        \\    scores: List<i32>;
        \\}
        \\
        \\struct State {
        \\    slots: [:]?User;
        \\}
        \\
        \\struct Wrapper {
        \\    state: State;
        \\}
        \\
        \\fn main(): i32 {
        \\    var wrappers: [1]Wrapper = [1]Wrapper [
        \\        Wrapper { state: State { slots: [:]?User [none] } }
        \\    ];
        \\    wrappers[0].state.slots[0] = User { age: 42, scores: list<i32>() };
        \\    const taken = take wrappers[0].state.slots[0];
        \\    if taken is user {
        \\        if wrappers[0].state.slots[0] is none {
        \\            return user.age;
        \\        }
        \\    }
        \\    return 0;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_take_array_optional_resource_mixed_path.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "@cyna_desc_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "define void @cyna_copy_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "define void @cyna_drop_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call ptr @cyna_dense_new(ptr @cyna_desc_") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "insertvalue { ptr, i64, i64 } undef, ptr null, 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call void @cyna_copy_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call void @cyna_drop_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extractvalue { i8, { i32, { { ptr, i64, i64 }, i64 } } }") != null);
}

test "LLVM emits string equality helper call" {
    const source =
        \\fn main(): i32 {
        \\    if "a" == "a" {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_string_eq.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "declare i1 @cyna_string_eq(ptr, i64, ptr, i64)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call i1 @cyna_string_eq") != null);
}

test "LLVM emits string query helper calls" {
    const source =
        \\fn main(): i32 {
        \\    const found = "cyna".find("yn");
        \\    if "cyna".starts_with("cy") and "cyna".ends_with("na") and "cyna".contains("yn") and found != none {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_string_queries.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "declare i1 @cyna_string_starts_with(ptr, i64, ptr, i64)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "declare i1 @cyna_string_ends_with(ptr, i64, ptr, i64)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "declare i1 @cyna_string_contains(ptr, i64, ptr, i64)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "declare void @cyna_string_find_into(ptr, ptr, i64, ptr, i64)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call i1 @cyna_string_starts_with") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call i1 @cyna_string_ends_with") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call i1 @cyna_string_contains") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call void @cyna_string_find_into") != null);
}

test "LLVM emits string.from helper call" {
    const source =
        \\fn main(): i32 {
        \\    const text = string.from("abc".bytes());
        \\    if text == "abc" {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_string_from.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "declare void @cyna_string_from_bytes_into(ptr, ptr)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call void @cyna_string_from_bytes_into") != null);
}

test "LLVM emits debug print helper calls" {
    const source =
        \\fn main(): i32 {
        \\    print("hi");
        \\    println(true);
        \\    println(42);
        \\    return 0;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_debug_print.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "declare void @cyna_std_prelude_print_string({ ptr, i64 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "declare void @cyna_std_prelude_print_bool(i1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "declare void @cyna_std_prelude_print_int(i64") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "declare void @cyna_std_prelude_print_newline()") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call void @cyna_std_prelude_print_string") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call void @cyna_std_prelude_print_bool") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call void @cyna_std_prelude_print_int") != null);
}

test "LLVM backend classifies internal artifact dependencies precisely" {
    const no_deps_source =
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;
    const no_deps = try test_exec.artifactDepsForSource(std.testing.allocator, "deps_none.cy", no_deps_source);
    try std.testing.expect(!no_deps.runtime);
    try std.testing.expect(!no_deps.std);

    const runtime_only_source =
        \\fn main(): i32 {
        \\    var xs: List<i32> = list<i32>();
        \\    xs.push(42);
        \\    return xs[0];
        \\}
    ;
    const runtime_only = try test_exec.artifactDepsForSource(std.testing.allocator, "deps_runtime.cy", runtime_only_source);
    try std.testing.expect(runtime_only.runtime);
    try std.testing.expect(runtime_only.std);

    const interpolation_source =
        \\fn main(): i32 {
        \\    const name = "ada";
        \\    const text = $"hi {name}";
        \\    const ignored = text;
        \\    return 0;
        \\}
    ;
    const interpolation_deps = try test_exec.artifactDepsForSource(std.testing.allocator, "deps_interpolation.cy", interpolation_source);
    try std.testing.expect(interpolation_deps.runtime);
    try std.testing.expect(!interpolation_deps.std);

    const runtime_and_std_source =
        \\fn main(): i32 {
        \\    print("hi");
        \\    return 0;
        \\}
    ;
    const runtime_and_std = try test_exec.artifactDepsForSource(std.testing.allocator, "deps_print.cy", runtime_and_std_source);
    try std.testing.expect(runtime_and_std.runtime);
    try std.testing.expect(runtime_and_std.std);

    const panic_source =
        \\fn main(): i32 {
        \\    if false {
        \\        panic("unreachable");
        \\    }
        \\    return 0;
        \\}
    ;
    const panic_deps = try test_exec.artifactDepsForSource(std.testing.allocator, "deps_panic.cy", panic_source);
    try std.testing.expect(panic_deps.runtime);
    try std.testing.expect(panic_deps.std);

    const dead_panic_source =
        \\fn unused(): void {
        \\    panic("dead");
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;
    const dead_panic_deps = try test_exec.artifactDepsForSource(std.testing.allocator, "deps_dead_panic.cy", dead_panic_source);
    try std.testing.expect(!dead_panic_deps.runtime);
    try std.testing.expect(!dead_panic_deps.std);
}

test "LLVM emission skips unreachable function bodies" {
    const source =
        \\fn unused(): i32 {
        \\    panic("dead");
        \\    return 1;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_dead_function_elision.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "define i32 @main()") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "@unused") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "cyna_std_prelude_panic") == null);
}

test "LLVM emits union capture control flow" {
    const source =
        \\union Token {
        \\    ident: string;
        \\    eof;
        \\}
        \\
        \\fn main(): i32 {
        \\    const token: Token = .ident("answer");
        \\    if token is .ident(name) {
        \\        if name == "answer" {
        \\            return 42;
        \\        }
        \\    }
        \\    return 0;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_union_if.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "{ i64, { ptr, i64 }, i8 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extractvalue { i64, { ptr, i64 }, i8 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call i1 @cyna_string_eq") != null);
}

test "LLVM emits heterogeneous union switch" {
    const source =
        \\union Token {
        \\    ident: string;
        \\    int_lit: i32;
        \\    eof;
        \\}
        \\
        \\fn score(token: Token): i32 {
        \\    switch token {
        \\    .ident(name) => {
        \\        if name == "answer" {
        \\            return 1;
        \\        }
        \\        return 2;
        \\    }
        \\    .int_lit(n) => {
        \\        return n;
        \\    }
        \\    .eof => {
        \\        return 0;
        \\    }
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    return score(.int_lit(42));
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_union_switch_heterogeneous.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "{ i64, { ptr, i64 }, i32, i8 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "insertvalue { i64, { ptr, i64 }, i32, i8 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extractvalue { i64, { ptr, i64 }, i32, i8 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, ", 2") != null);
}

test "LLVM emits struct literals and field access" {
    const source =
        \\struct User {
        \\    age: i32;
        \\    score: i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    const user = User { age: 40, score: 2 };
        \\    return user.age + user.score;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_struct_field.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "{ i32, i32 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "insertvalue { i32, i32 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "getelementptr inbounds { i32, i32 }, ptr %") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "load i32, ptr %") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "add i32") != null);
}

test "LLVM emits field alias mutation through ref params" {
    const source =
        \\struct Header {
        \\    len: i32;
        \\}
        \\
        \\fn set_len(value: &i32): void {
        \\    value = 42;
        \\}
        \\
        \\fn main(): i32 {
        \\    var header = Header { len: 0 };
        \\    set_len(&header.len);
        \\    return header.len;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_field_alias.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "define void ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "getelementptr inbounds { i32 }, ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call void ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "store i32 42, ptr") != null);
}

test "LLVM emits owned field alias mutation through ref params" {
    const source =
        \\struct User {
        \\    age: i32;
        \\}
        \\
        \\fn set_age(value: &i32): void {
        \\    value = 42;
        \\}
        \\
        \\fn main(): i32 {
        \\    var user = new User { age: 0 };
        \\    set_age(&user.age);
        \\    return user.age;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_owned_field_alias.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "define void ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "getelementptr inbounds { i32 }, ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call void ") != null);
}

test "LLVM emits array index alias mutation through ref params" {
    const source =
        \\fn set_value(value: &i32): void {
        \\    value = 42;
        \\}
        \\
        \\fn main(): i32 {
        \\    var values: [2]i32 = [2]i32 [ 0, 1 ];
        \\    set_value(&values[0]);
        \\    return values[0];
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_array_index_alias.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "[2 x i32]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "getelementptr inbounds [2 x i32], ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call void ") != null);
}

test "LLVM emits slice index alias mutation through ref params" {
    const source =
        \\fn set_value(value: &i32): void {
        \\    value = 42;
        \\}
        \\
        \\fn main(): i32 {
        \\    var values: [2]i32 = [2]i32 [ 0, 1 ];
        \\    var window: []i32 = values[..];
        \\    set_value(&window[0]);
        \\    return values[0];
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_slice_index_alias.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "{ ptr, i64 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extractvalue { ptr, i64 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "getelementptr inbounds i32, ptr") != null);
}

test "LLVM emits ranged slice views" {
    const source =
        \\fn main(): i32 {
        \\    var values: [4]i32 = [4]i32 [ 10, 11, 12, 13 ];
        \\    var middle: []i32 = values[1..3];
        \\    var tail: []i32 = values[2..];
        \\    var head: []i32 = values[..2];
        \\    return middle[0] + middle[1] + tail[0] + head[1] - 23;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_slice_range.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "{ ptr, i64 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "sub i64") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "getelementptr inbounds i32, ptr") != null);
}

test "LLVM emits list runtime calls for indexing and slice views" {
    const source =
        \\fn set_value(value: &i32): void {
        \\    value = 42;
        \\}
        \\
        \\fn main(): i32 {
        \\    var xs: List<i32> = list_from<i32>([:]i32 [0, 1]);
        \\    set_value(xs.get_mut(0));
        \\    var view: []i32 = xs.view_mut();
        \\    return view[0];
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_list_runtime.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "declare ptr @cyna_dense_new(ptr)") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "declare ptr @cyna_dense_at(ptr, i64, ptr)") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "declare ptr @cyna_dense_data(ptr)") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "declare i64 @cyna_dense_len(ptr)") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call ptr @cyna_dense_at") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call ptr @cyna_dense_data") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extractvalue { ptr, i64, i64 }") != null);
}

test "LLVM emits list ranged slice views through ordinary view method" {
    const source =
        \\fn main(): i32 {
        \\    var xs: List<i32> = list_from<i32>([:]i32 [10, 11, 12, 13]);
        \\    var middle: []const i32 = xs.view()[1..3];
        \\    return middle[0] + middle[1] - 23;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_list_slice_range.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "call { ptr, i64 } @cyna_fn_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "sub i64") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "getelementptr inbounds i32, ptr") != null);
}

test "LLVM emits short-circuit and control flow" {
    const source =
        \\fn main(): i32 {
        \\    if 1 == 1 and 2 == 2 {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_short_circuit_and.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "bb1_and_rhs:") != null or std.mem.indexOf(u8, text, "and_rhs") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "bb2_and_short:") != null or std.mem.indexOf(u8, text, "and_short") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "br i1 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "store i1 ") != null);
}

test "LLVM emits for loops over array list slice and set" {
    const source =
        \\fn main(): i32 {
        \\    var total: i32 = 0;
        \\
        \\    const fixed: [3]i32 = [1, 2, 3];
        \\    for value in fixed {
        \\        total = total + value;
        \\    }
        \\
        \\    var xs: List<i32> = list_from<i32>([:]i32 [4, 5]);
        \\    for value in xs {
        \\        total = total + value;
        \\    }
        \\
        \\    const view = xs.view();
        \\    for value in view {
        \\        total = total + value;
        \\    }
        \\
        \\    var seen: Set<i32> = set<i32>();
        \\    seen.add(8);
        \\    seen.add(10);
        \\    for value in seen {
        \\        total = total + value;
        \\    }
        \\
        \\    return total;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_for_iteration.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "declare ptr @cyna_dense_new(ptr)") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "declare ptr @cyna_sparse_new(i64, ptr)") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call i64 @cyna_dense_len") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call ptr @cyna_dense_data") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call ptr @cyna_sparse_indices") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call ptr @cyna_runtime_tracked_alloc_site(i64 %") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call i1 @cyna_sparse_get_copy") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "_copy_fn") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extractvalue { ptr, i64, i64 }") != null);
}

test "LLVM emits map iteration through prelude methods and sparse storage" {
    const source =
        \\fn main(): i32 {
        \\    var scores: Map<string, i32> = map<string, i32>();
        \\    scores["Ada"] = 10;
        \\    scores["Ken"] = 12;
        \\
        \\    var key_count: i32 = 0;
        \\    for name in scores.keys() {
        \\        if name == "Ada" or name == "Ken" {
        \\            key_count = key_count + 1;
        \\        }
        \\    }
        \\
        \\    var total: i32 = 0;
        \\    for score in scores.values() {
        \\        total = total + score;
        \\    }
        \\
        \\    return total + key_count;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_map_iteration.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "declare ptr @cyna_sparse_new(i64, ptr)") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "declare void @cyna_sparse_insert_copy(ptr, i64, ptr, ptr)") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call void @cyna_fn_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call ptr @cyna_sparse_indices") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "store i8 0, ptr %") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call i1 @cyna_sparse_get_copy") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "_copy_fn") != null);
}

test "LLVM emits direct map indexed reads through prelude methods" {
    const source =
        \\fn main(): i32 {
        \\    var scores: Map<string, i32> = map<string, i32>();
        \\    scores["Ada"] = 42;
        \\    return scores["Ada"];
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_map_read.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "call i32 @cyna_fn_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call ptr @cyna_sparse_indices") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call i1 @cyna_sparse_get_copy") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "_copy_fn") != null);
}

test "LLVM emits explicit drop for resource locals" {
    const source =
        \\fn main(): i32 {
        \\    var values: List<i32> = list_from<i32>([:]i32 [42]);
        \\    drop values;
        \\    return 42;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_drop_list.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "declare void @cyna_dense_drop(ptr, ptr)") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call void @cyna_drop_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call void @cyna_runtime_tracked_free(ptr %dense_data)") != null);
}

test "LLVM lowers list clear with direct descriptor walk" {
    const source =
        \\fn main(): i32 {
        \\    var values: List<i32> = list_from<i32>([:]i32 [1, 2]);
        \\    values.clear();
        \\    return values.len() as i32;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_list_clear_direct.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "call void @cyna_dense_clear") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dense_clear_loop_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "getelementptr inbounds { i64, i64, i32, ptr, ptr, ptr, ptr, ptr }, ptr @cyna_desc_") != null);
}

test "LLVM lowers sparse clear with direct occupancy walk" {
    const source =
        \\fn main(): i32 {
        \\    var scores: Map<string, i32> = map<string, i32>();
        \\    scores["Ada"] = 42;
        \\    scores.clear();
        \\    return scores.len() as i32;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_sparse_clear_direct.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "call void @cyna_sparse_clear") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "sparse_clear_loop_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "store i8 0, ptr %") != null);
}

test "LLVM emits recursive struct drop through resource fields" {
    const source =
        \\struct Cache {
        \\    values: List<i32>;
        \\}
        \\
        \\fn main(): i32 {
        \\    var cache = Cache { values: list_from<i32>([:]i32 [1, 2]) };
        \\    drop cache;
        \\    return 42;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_drop_struct_resource.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "extractvalue { { ptr, i64, i64 }, i64 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call void @cyna_drop_") != null);
}

test "LLVM emits generated descriptors for checked payload resources" {
    const source =
        \\enum Status: i32 {
        \\    failed = 1,
        \\}
        \\
        \\fn produce(): List<i32>!Status { return list_from<i32>([:]i32 [1, 2]); }
        \\fn main(): i32 {
        \\    var value = produce() catch (status) { return 1; };
        \\    return 42;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_result_desc.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "extractvalue { i8, { { ptr, i64, i64 }, i64 }, i32, { ptr, i32, i32 } }") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "define void @cyna_copy_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ptr @cyna_desc_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call void @cyna_drop_") != null);
}

test "LLVM copies packed struct descriptors through scalar carriers" {
    const source =
        \\packed struct StatusReg {
        \\    mode: u2;
        \\    code: u6;
        \\}
        \\
        \\fn main(): i32 {
        \\    var values: List<StatusReg> = list<StatusReg>();
        \\    values.push(StatusReg { mode: 2, code: 40 });
        \\    return values.len() as i32;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_packed_desc.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "load i8, ptr %src") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "store i8 %value, ptr %dst") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "getelementptr inbounds i8, ptr %dst, i32 0, i32 0") == null);
}

test "LLVM emits generated descriptors for list struct elements" {
    const source =
        \\struct User {
        \\    id: i32;
        \\    name: string;
        \\}
        \\
        \\fn main(): i32 {
        \\    var users: List<User> = list<User>();
        \\    users.push(User { id: 1, name: "Ada" });
        \\    return users.len() as i32;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_list_struct_desc.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "@cyna_desc_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "define void @cyna_copy_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ptr @cyna_desc_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call void @cyna_dense_push_copy") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call ptr @cyna_dense_copy") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call void @cyna_drop_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call ptr @cyna_runtime_tracked_alloc_site(i64 %dense_alloc_bytes") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call void @cyna_runtime_tracked_free(ptr %dense_data)") != null);
}

test "partitioned COFF descriptor helpers use COMDAT groups" {
    const source =
        \\struct User { id: i32; name: string; }
        \\fn main(): i32 {
        \\    var users: List<User> = list<User>();
        \\    users.push(User { id: 1, name: "Ada" });
        \\    return users.len() as i32;
        \\}
    ;

    const text = try test_exec.emitLlvmSourceWithOptions(std.testing.allocator, "coff_descriptors.cy", source, null, .{
        .partitioned = true,
        .coff_comdat = true,
    });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "$cyna_copy_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "$cyna_drop_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, " = comdat any") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, ") comdat {") != null);
}

test "LLVM declares list clone for generated aggregate helpers" {
    const source =
        \\struct User {
        \\    scores: List<i32>;
        \\}
        \\impl User: Clone {
        \\    fn clone(self: &const User): User { return User { scores: self.scores.clone() }; }
        \\}
        \\
        \\fn main(): i32 {
        \\    var users: List<User> = list<User>();
        \\    users.push(User { scores: list_from<i32>([:]i32 [1]) });
        \\    const copied = users.clone();
        \\    return copied[0].scores[0];
        \\}
    ;

    const text = try lowerLlvmTextWithTarget(std.testing.allocator, "llvm_list_copy_decl_for_helpers.cy", source, "aarch64-apple-darwin");
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "declare ptr @cyna_dense_copy(ptr, ptr)") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "_clone(ptr sret") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call ptr @cyna_runtime_tracked_alloc_site(i64 %dense_alloc_bytes") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ptr @cyna_desc_") != null);
}

test "LLVM emits defer calls before return" {
    const source =
        \\enum Status: i32 {
        \\    ok = 0,
        \\    failed,
        \\}
        \\
        \\fn mark(digit: i32): void {
        \\    const ignored = digit;
        \\    return;
        \\}
        \\
        \\fn ok_step(): void!Status {
        \\    return;
        \\}
        \\
        \\fn scope(): i32!Status {
        \\    defer mark(2);
        \\    defer mark(4);
        \\    try ok_step();
        \\    return 42;
        \\}
        \\
        \\fn main(): i32 {
        \\    const value = scope() catch (status) {
        \\        const ignored = status;
        \\        return 1;
        \\    };
        \\    return value;
        \\}
    ;

    const text = try lowerLlvmTextWithTarget(std.testing.allocator, "llvm_defer_order.cy", source, "aarch64-apple-darwin");
    defer std.testing.allocator.free(text);

    const mark4 = std.mem.indexOf(u8, text, "i32 4)") orelse return error.TestUnexpectedResult;
    const mark2 = std.mem.indexOf(u8, text, "i32 2)") orelse return error.TestUnexpectedResult;
    const ret = std.mem.lastIndexOf(u8, text, "store { i8, i32, i32, { ptr, i32, i32 } }") orelse return error.TestUnexpectedResult;
    try std.testing.expect(mark4 < mark2);
    try std.testing.expect(mark2 < ret);
}

test "LLVM drops old owned value before local reassignment" {
    const source =
        \\fn main(): i32 {
        \\    var values: List<i32> = list_from<i32>([:]i32 [1]);
        \\    values = values.clone();
        \\    return 42;
        \\}
    ;

    const text = try lowerLlvmTextWithTarget(std.testing.allocator, "llvm_assign_drop_list.cy", source, "aarch64-apple-darwin");
    defer std.testing.allocator.free(text);

    const rebind_at = std.mem.indexOf(u8, text, "rebind_drop values") orelse return error.TestUnexpectedResult;
    const copy_rel = std.mem.indexOf(u8, text[rebind_at..], "_clone(ptr sret") orelse return error.TestUnexpectedResult;
    const drop_rel = std.mem.indexOf(u8, text[rebind_at + copy_rel ..], "call void @cyna_drop_") orelse return error.TestUnexpectedResult;
    const store_rel = std.mem.indexOf(u8, text[rebind_at + copy_rel + drop_rel ..], "store { { ptr, i64, i64 }, i64 } %") orelse return error.TestUnexpectedResult;
    const copy_at = rebind_at + copy_rel;
    const drop_at = rebind_at + copy_rel + drop_rel;
    const store_at = rebind_at + copy_rel + drop_rel + store_rel;
    try std.testing.expect(copy_at < drop_at);
    try std.testing.expect(drop_at < store_at);
}

test "LLVM auto-drops resource locals before return" {
    const source =
        \\fn main(): i32 {
        \\    var values: List<i32> = list_from<i32>([:]i32 [1]);
        \\    return 42;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_auto_drop_list.cy", source);
    defer std.testing.allocator.free(text);

    const drop_at = std.mem.indexOf(u8, text, "call void @cyna_drop_") orelse return error.TestUnexpectedResult;
    const ret_at = std.mem.lastIndexOf(u8, text, "ret i32 42") orelse return error.TestUnexpectedResult;
    try std.testing.expect(drop_at < ret_at);
}

test "LLVM does not auto-drop handed off return values" {
    const source =
        \\fn build(): List<i32> {
        \\    var values: List<i32> = list_from<i32>([:]i32 [1]);
        \\    return values;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_handoff_return_list.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "call void @cyna_drop_") == null);
}

test "LLVM emits ownership trace comments" {
    const source =
        \\struct Box {
        \\    values: List<i32>;
        \\}
        \\
        \\fn main(): i32 {
        \\    var value: ?Box = Box { values: list_from<i32>([:]i32 [1]) };
        \\    const taken = take value;
        \\    return 42;
        \\}
    ;

    const text = try lowerLlvmText(std.testing.allocator, "llvm_ownership_trace_comments.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "  ; ownership:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  ;   owner value\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  ;   owner taken\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  ;   take value: source cleared to none\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  ;   auto_drop taken at return (") != null);
}

test "native executes generic function instantiation" {
    const source =
        \\fn identity<T>(value: T): T {
        \\    return value;
        \\}
        \\
        \\fn main(): i32 {
        \\    return identity(42);
        \\}
    ;

    try std.testing.expectEqual(@as(i64, 42), try runNativeSourceExitCode(std.testing.allocator, "native_generic_identity.cy", source));
}

test "native executes declarative top-level globals" {
    const source =
        \\const base: i32 = 40;
        \\const answer: i32 = base + 2;
        \\
        \\fn main(): i32 {
        \\    return answer;
        \\}
    ;

    try std.testing.expectEqual(@as(i64, 42), try runNativeSourceExitCode(std.testing.allocator, "native_top_level_globals.cy", source));
}

test "native executes optional local take" {
    const source =
        \\fn main(): i32 {
        \\    var value: ?i32 = 42;
        \\    const taken = take value;
        \\    if taken is n {
        \\        return n;
        \\    }
        \\    return 0;
        \\}
    ;

    try std.testing.expectEqual(@as(i64, 42), try runNativeSourceExitCode(std.testing.allocator, "native_optional_take.cy", source));
}

test "native executes struct-owned set and map fields" {
    const source =
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
    ;

    try std.testing.expectEqual(@as(i64, 42), try runNativeSourceExitCode(std.testing.allocator, "native_struct_set_map_fields.cy", source));
}

test "native executes imported public globals across files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "lib");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "lib/math.cy", .data =
        \\
        \\pub const base: i32 = 40;
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\import lib.math;
        \\
        \\const answer: i32 = math.base + 2;
        \\
        \\fn main(): i32 {
        \\    return answer;
        \\}
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(root_path);

    try std.testing.expectEqual(@as(i64, 42), try runNativeFileExitCode(std.testing.allocator, root_path));
}

test "native executes projected Array optional take through field path" {
    const source =
        \\struct State {
        \\    slots: [:]?i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    var state = State { slots: [:]?i32 [none, none] };
        \\    state.slots[0] = 42;
        \\    const taken = take state.slots[0];
        \\    if taken is n {
        \\        if state.slots[0] is none {
        \\            return n;
        \\        }
        \\    }
        \\    return 0;
        \\}
    ;

    try std.testing.expectEqual(@as(i64, 42), try runNativeSourceExitCode(std.testing.allocator, "native_take_array_optional_field_path.cy", source));
}

test "native executes mixed index and field Array optional resource take path" {
    const source =
        \\struct User {
        \\    age: i32;
        \\    scores: List<i32>;
        \\}
        \\
        \\struct State {
        \\    slots: [:]?User;
        \\}
        \\
        \\struct Wrapper {
        \\    state: State;
        \\}
        \\
        \\fn main(): i32 {
        \\    var wrappers: [1]Wrapper = [1]Wrapper [
        \\        Wrapper { state: State { slots: [:]?User [none] } }
        \\    ];
        \\    wrappers[0].state.slots[0] = User { age: 42, scores: list<i32>() };
        \\    const taken = take wrappers[0].state.slots[0];
        \\    if taken is user {
        \\        if wrappers[0].state.slots[0] is none {
        \\            return user.age;
        \\        }
        \\    }
        \\    return 0;
        \\}
    ;

    try std.testing.expectEqual(@as(i64, 42), try runNativeSourceExitCode(std.testing.allocator, "native_take_array_optional_resource_mixed_path.cy", source));
}

test "native executes defer before return" {
    const source =
        \\fn mark(value: &i32, digit: i32): void {
        \\    value = value * 10 + digit;
        \\}
        \\
        \\fn main(): i32 {
        \\    var order: i32 = 0;
        \\    defer mark(&order, 2);
        \\    defer mark(&order, 4);
        \\    return order + 0;
        \\}
    ;

    try std.testing.expectEqual(@as(i64, 0), try runNativeSourceExitCode(std.testing.allocator, "native_defer_order.cy", source));
}

test "native executes generic struct method specialization" {
    const source =
        \\struct Box<T> {
        \\    value: T;
        \\
        \\    fn get(self: Box<T>): T {
        \\        return self.value;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    const box: Box<i32> = Box<i32> { value: 42 };
        \\    return box.get();
        \\}
    ;

    try std.testing.expectEqual(@as(i64, 42), try runNativeSourceExitCode(std.testing.allocator, "native_generic_struct_method.cy", source));
}

test "native executes union payload projection" {
    const source =
        \\union Token {
        \\    ident: string;
        \\    eof;
        \\}
        \\
        \\fn main(): i32 {
        \\    const token: Token = .ident("answer");
        \\    if token.ident == "answer" {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    try std.testing.expectEqual(@as(i64, 42), try runNativeSourceExitCode(std.testing.allocator, "native_union_projection.cy", source));
}

test "LLVM emits explicit clone of a union payload through payload pointer path" {
    const source =
        \\union Token {
        \\    ids: List<i32>;
        \\    eof;
        \\}
        \\
        \\fn main(): i32 {
        \\    const token: Token = .ids(list_from<i32>([:]i32 [1, 2, 3]));
        \\    const copied = token.ids.clone();
        \\    return copied.len() as i32;
        \\}
    ;

    const text = try lowerLlvmTextWithTarget(std.testing.allocator, "llvm_borrowed_union_payload_copy.cy", source, "aarch64-apple-darwin");
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "getelementptr inbounds { i64, { { ptr, i64, i64 }, i64 }, i8 }, ptr %") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call void @cyna_fn_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "_clone(ptr sret") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extractvalue") == null or std.mem.indexOf(u8, text, "extractvalue { i64, ptr }") == null);
}

test "native executes borrowed union payload container mutation" {
    const source =
        \\union Token {
        \\    ids: List<i32>;
        \\    eof;
        \\}
        \\
        \\fn main(): i32 {
        \\    var token: Token = .ids(list_from<i32>([:]i32 [1, 2, 3]));
        \\    token.ids.push(4);
        \\    return token.ids.len() as i32;
        \\}
    ;

    try std.testing.expectEqual(@as(i64, 4), try runNativeSourceExitCode(std.testing.allocator, "native_borrowed_union_payload_mutation.cy", source));
}

test "native executes union switch with payload" {
    const source =
        \\union Token {
        \\    ident: string;
        \\    eof;
        \\}
        \\
        \\fn score(token: Token): i32 {
        \\    switch token {
        \\    .ident(name) => {
        \\        if name == "answer" {
        \\            return 42;
        \\        }
        \\        return 1;
        \\    }
        \\    .eof => {
        \\        return 0;
        \\    }
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    const token: Token = .ident("answer");
        \\    return score(token);
        \\}
    ;

    try std.testing.expectEqual(@as(i64, 42), try runNativeSourceExitCode(std.testing.allocator, "native_union_switch_payload.cy", source));
}

test "native executes imported aggregate globals across files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "lib");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "lib/model.cy", .data =
        \\
        \\pub struct Pair {
        \\    pub left: i32;
        \\    pub right: i32;
        \\}
        \\
        \\pub const pair: Pair = Pair { left: 10, right: 32 };
        \\pub const values: [2]i32 = [1, 42];
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\import lib.model;
        \\
        \\fn main(): i32 {
        \\    return model.pair.right + model.values[0];
        \\}
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(root_path);

    try std.testing.expectEqual(@as(i64, 33), try runNativeFileExitCode(std.testing.allocator, root_path));
}

test "native executes generic method explicit type arguments" {
    const source =
        \\struct Box {
        \\    value: i32;
        \\
        \\    fn wrap<T>(self: Box, value: T): T {
        \\        return value;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    const box = Box { value: 1 };
        \\    return box.wrap<i32>(42);
        \\}
    ;

    try std.testing.expectEqual(@as(i64, 42), try runNativeSourceExitCode(std.testing.allocator, "native_generic_method_explicit_type_args.cy", source));
}

test "native executes generic method inferred type arguments" {
    const source =
        \\struct Box {
        \\    value: i32;
        \\
        \\    fn wrap<T>(self: Box, value: T): T {
        \\        return value;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    const box = Box { value: 1 };
        \\    return box.wrap(42);
        \\}
    ;

    try std.testing.expectEqual(@as(i64, 42), try runNativeSourceExitCode(std.testing.allocator, "native_generic_method_infer_type_args.cy", source));
}

test "native executes generic method on generic struct with explicit type arguments" {
    const source =
        \\struct Box<T> {
        \\    value: T;
        \\
        \\    fn pair<U>(self: Box<T>, other: U): U {
        \\        return other;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    const box: Box<i32> = Box<i32> { value: 1 };
        \\    return box.pair<i32>(42);
        \\}
    ;

    try std.testing.expectEqual(@as(i64, 42), try runNativeSourceExitCode(std.testing.allocator, "native_generic_struct_method_explicit_type_args.cy", source));
}

test "native executes generic method on generic struct with inferred type arguments" {
    const source =
        \\struct Box<T> {
        \\    value: T;
        \\
        \\    fn pair<U>(self: Box<T>, other: U): U {
        \\        return other;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    const box: Box<i32> = Box<i32> { value: 1 };
        \\    return box.pair(42);
        \\}
    ;

    try std.testing.expectEqual(@as(i64, 42), try runNativeSourceExitCode(std.testing.allocator, "native_generic_struct_method_infer_type_args.cy", source));
}

test "native executes generic method inference through instantiated generic struct arguments" {
    const source =
        \\struct Box<T> {
        \\    value: T;
        \\}
        \\
        \\struct Wrapper {
        \\    fn unwrap<T>(self: Wrapper, value: Box<T>): T {
        \\        return value.value;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    const wrapper = Wrapper {};
        \\    const value: Box<i32> = Box<i32> { value: 42 };
        \\    return wrapper.unwrap(value);
        \\}
    ;

    try std.testing.expectEqual(@as(i64, 42), try runNativeSourceExitCode(std.testing.allocator, "native_generic_method_nested_arg_infer.cy", source));
}

test "native executes allocator context scoped statement" {
    const source =
        \\fn main(): i32 {
        \\    using alloc = 0 {
        \\        return 42;
        \\    }
        \\}
    ;

    try std.testing.expectEqual(@as(i64, 42), try runNativeSourceExitCode(std.testing.allocator, "native_allocator_context_stmt.cy", source));
}

test "native executes scoped allocator local temporary use" {
    const source =
        \\fn main(): i32 {
        \\    using scoped alloc = 0 {
        \\        const xs: List<i32> = list<i32>();
        \\        if xs.len() == 0 {
        \\            return 42;
        \\        }
        \\    }
        \\    return 0;
        \\}
    ;

    try std.testing.expectEqual(@as(i64, 42), try runNativeSourceExitCode(std.testing.allocator, "native_scoped_allocator_local_use.cy", source));
}

test "native executes allocator context nested container copy" {
    const source =
        \\fn main(): i32 {
        \\    using alloc = 1 {
        \\        const xs: List<i32> = list<i32>();
        \\        using alloc = 2 {
        \\            const ys = xs.clone();
        \\            return ys.len() as i32;
        \\        }
        \\    }
        \\}
    ;

    try std.testing.expectEqual(@as(i64, 0), try runNativeSourceExitCode(std.testing.allocator, "native_allocator_context_nested_copy.cy", source));
}

test "native executes defer on continue" {
    const source =
        \\fn mark(value: &i32, digit: i32): void {
        \\    value = value * 10 + digit;
        \\}
        \\
        \\fn main(): i32 {
        \\    var order: i32 = 0;
        \\    var i: i32 = 0;
        \\    while i < 1 {
        \\        defer mark(&order, 2);
        \\        defer mark(&order, 4);
        \\        i = i + 1;
        \\        continue;
        \\    }
        \\    return order;
        \\}
    ;

    try std.testing.expectEqual(@as(i64, 42), try runNativeSourceExitCode(std.testing.allocator, "native_continue_defer_order.cy", source));
}

test "native executes loop-body resource local before continue" {
    const source =
        \\fn main(): i32 {
        \\    var i: i32 = 0;
        \\    while i < 1 {
        \\        var values: List<i32> = list_from<i32>([:]i32 [42]);
        \\        i = i + 1;
        \\        continue;
        \\    }
        \\    return 42;
        \\}
    ;

    try std.testing.expectEqual(@as(i64, 42), try runNativeSourceExitCode(std.testing.allocator, "native_continue_resource_local.cy", source));
}

test "LLVM nullable C pointers use pointer signatures across targets" {
    const source =
        \\extern c("nullable_source") fn get(): ?*c_void;
        \\export c("nullable_export") fn exposed(value: ?*c_void): ?*c_void { return value; }
        \\fn internal(value: ?*c_void): ?*c_void { return value; }
        \\fn main(): i32 {
        \\    const value = internal(exposed(get()));
        \\    if value is none { return 0; }
        \\    return 1;
        \\}
    ;
    for ([_][]const u8{ "aarch64-apple-darwin", "x86_64-none-elf", "riscv32-none-elf" }) |target| {
        const text = try lowerLlvmTextWithTarget(std.testing.allocator, "nullable_c_targets.cy", source, target);
        defer std.testing.allocator.free(text);
        try std.testing.expect(std.mem.indexOf(u8, text, "declare ptr @nullable_source()") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "define ptr @nullable_export(ptr") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "call ptr @nullable_source()") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "call ptr @nullable_export(ptr") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "define { i8, ptr }") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "icmp ne ptr") != null);
    }
}
