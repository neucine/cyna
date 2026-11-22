const std = @import("std");
const compat = @import("cyna").compat;

const helpers = @import("../helpers.zig");
const test_exec = @import("../support.zig");

test "trusted runtime error bridge retains success and error payloads" {
    const source =
        \\import { TaskGroup } from std.thread;
        \\fn main(): i32 {
        \\    const rejected = TaskGroup.init(0 as u32) catch (capacity_problem) {
        \\        const ignored = capacity_problem;
        \\        const group = TaskGroup.init(1 as u32) catch (memory_problem) {
        \\            const ignored_memory = memory_problem;
        \\            return 2;
        \\        };
        \\        group.finish();
        \\        return 42;
        \\    };
        \\    rejected.cancel_and_wait();
        \\    return 1;
        \\}
    ;
    try expectNamedNative("trusted_runtime_result_bridge", source, 42);
}

test "C ABI round trips explicit error adapters with private transport" {
    const source =
        \\enum Status { failed }
        \\fn private_value(fail: bool): c_int!Status {
        \\    if fail { throw Status.failed; }
        \\    return 42;
        \\}
        \\c struct AbiResult {
        \\    tag: u8;
        \\    value: c_int;
        \\    error_code: c_int;
        \\}
        \\
        \\extern {
        \\    c("load_i32") fn load_i32(): AbiResult;
        \\    c("call_exports") fn call_exports(): c_int;
        \\}
        \\
        \\export c("export_i32") fn export_i32(): AbiResult {
        \\    const value = private_value(false) catch (problem) {
        \\        const ignored = problem;
        \\        return AbiResult { tag: 1, value: 0, error_code: 1 };
        \\    };
        \\    return AbiResult { tag: 0, value: value, error_code: 0 };
        \\}
        \\
        \\export c("export_error") fn export_error(): AbiResult {
        \\    const value = private_value(true) catch (problem) {
        \\        const ignored = problem;
        \\        return AbiResult { tag: 1, value: 0, error_code: 1 };
        \\    };
        \\    return AbiResult { tag: 0, value: value, error_code: 0 };
        \\}
        \\fn main(): i32 {
        \\    const loaded = load_i32();
        \\    if loaded.tag != 0 or loaded.value != 40 or loaded.error_code != 0 {
        \\        return 1;
        \\    }
        \\    if call_exports() != 42 {
        \\        return 5;
        \\    }
        \\    return 42;
        \\}
    ;
    const c_source =
        \\#include <stdint.h>
        \\
        \\typedef struct {
        \\    uint8_t is_ok;
        \\    int32_t ok;
        \\    int32_t err;
        \\} CynaResultI32Int;
        \\
        \\CynaResultI32Int export_i32(void);
        \\CynaResultI32Int export_error(void);
        \\
        \\CynaResultI32Int load_i32(void) {
        \\    return (CynaResultI32Int){ .is_ok = 0, .ok = 40, .err = 0 };
        \\}
        \\
        \\int call_exports(void) {
        \\    CynaResultI32Int i32_result = export_i32();
        \\    if (i32_result.is_ok != 0 || i32_result.ok != 42) return 1;
        \\    CynaResultI32Int failed = export_error();
        \\    if (failed.is_ok != 1 || failed.ok != 0 || failed.err != 1) return 2;
        \\    return 42;
        \\}
    ;

    try expectNativeWithCSources(
        "native_explicit_result_adapter.cy",
        source,
        &.{.{ .name = "result_adapter.c", .source = c_source }},
        42,
    );
}

fn expectNamedNative(comptime name: []const u8, source: []const u8, expected: i64) !void {
    try helpers.expectNativeNamedSourceExitCode(std.testing.allocator, name, "native_" ++ name ++ ".cy", source, expected);
}

fn expectNativeWithCSources(path: []const u8, source: []const u8, extra_c_sources: []const test_exec.ExtraCSource, expected: i64) !void {
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    try std.testing.expectEqual(expected, try test_exec.runNativeSourceExitCodeWithCSources(scratch.allocator(), path, source, extra_c_sources));
}

test "valid C ABI declarations lower when not executed" {
    const source =
        \\extern {
        \\    c("puts") fn puts(text: c_str): c_int;
        \\    c("free") fn free(ptr: ?*c_void): void;
        \\}
        \\
        \\export c("cyna_add") fn cyna_add(a: c_int, b: c_int): c_int {
        \\    return a + b;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 42;
        \\}
    ;

    try expectNamedNative("valid_c_abi_decls_lower", source, 42);
}

test "static string literals adapt to borrowed c_str parameters" {
    const source =
        \\extern c("inspect_c_str") fn inspect_c_str(text: c_str): c_int;
        \\
        \\fn main(): i32 {
        \\    if inspect_c_str("hello") != 42 {
        \\        return 1;
        \\    }
        \\    return 42;
        \\}
    ;
    const c_source =
        \\#include <string.h>
        \\
        \\int inspect_c_str(const char *text) {
        \\    return text != 0 && strcmp(text, "hello") == 0 ? 42 : 1;
        \\}
    ;

    try expectNativeWithCSources("native_c_str_literal.cy", source, &.{.{ .name = "c_str_literal.c", .source = c_source }}, 42);
}

test "C ABI accepts broader scalar names" {
    const source =
        \\export c("mix") fn mix(a: c_uint, b: c_ulong, c: c_short, d: c_ushort, e: c_uchar, f: c_llong, g: c_ullong, h: c_schar, i: c_ptrdiff_t): c_uint {
        \\    return a;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 42;
        \\}
    ;

    try expectNamedNative("c_abi_broader_scalars", source, 42);
}

test "C ABI accepts float scalar names" {
    const source =
        \\export c("mixf") fn mixf(a: c_float, b: c_double): c_double {
        \\    return b;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 42;
        \\}
    ;

    try expectNamedNative("c_abi_float_scalars", source, 42);
}

test "comptime exposes C ABI layout metadata for cstructs" {
    const source =
        \\c struct Pair {
        \\    left: c_int;
        \\    right: c_short;
        \\}
        \\
        \\fn main(): i32 {
        \\    if comptime Pair.size != 8 {
        \\        return 1;
        \\    }
        \\    if comptime Pair.align != 4 {
        \\        return 2;
        \\    }
        \\    if comptime Pair.field.left.offset != 0 {
        \\        return 3;
        \\    }
        \\    if comptime Pair.field.right.offset != 4 {
        \\        return 4;
        \\    }
        \\    return 42;
        \\}
    ;

    try expectNamedNative("comptime_cstruct_layout_metadata", source, 42);
}

test "module constants can use comptime C ABI layout metadata" {
    const source =
        \\c struct Pair {
        \\    left: c_int;
        \\    right: c_short;
        \\}
        \\
        \\pub const pair_size: usize = comptime Pair.size;
        \\pub const pair_align: usize = comptime Pair.align;
        \\pub const right_offset: usize = comptime Pair.field.right.offset;
        \\
        \\fn main(): i32 {
        \\    if pair_size != 8 {
        \\        return 1;
        \\    }
        \\    if pair_align != 4 {
        \\        return 2;
        \\    }
        \\    if right_offset != 4 {
        \\        return 3;
        \\    }
        \\    return 42;
        \\}
    ;

    try expectNamedNative("comptime_cstruct_layout_module_constants", source, 42);
}

test "imported public module constants can use comptime C ABI layout metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirMakePath(tmp.dir, "lib");
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "lib/layout.cy", .data =
        \\c struct Pair {
        \\    left: c_int;
        \\    right: c_short;
        \\}
        \\
        \\pub const pair_size: usize = comptime Pair.size;
        \\pub const right_offset: usize = comptime Pair.field.right.offset;
    });
    try compat.dirWriteFile(tmp.dir, .{ .sub_path = "main.cy", .data =
        \\import lib.layout;
        \\
        \\const local_size: usize = layout.pair_size;
        \\
        \\fn main(): i32 {
        \\    if local_size != 8 {
        \\        return 1;
        \\    }
        \\    if layout.right_offset != 4 {
        \\        return 2;
        \\    }
        \\    return 42;
        \\}
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(root_path);

    try helpers.expectNativeFileExitCode(std.testing.allocator, root_path, 42);
}

test "native C ABI round trips by-value cstructs and callbacks" {
    const source =
        \\c struct Pair {
        \\    left: c_int;
        \\    right: c_short;
        \\}
        \\
        \\extern {
        \\    c("sum_pair") fn sum_pair(pair: Pair): c_int;
        \\    c("call_native_sum") fn call_native_sum(): c_int;
        \\    c("call_cb") fn call_cb(cb: c fn(c_int): c_int, value: c_int): c_int;
        \\    c("imported_make_pair") fn imported_make_pair(): Pair;
        \\    c("call_make_pair") fn call_make_pair(): c_int;
        \\}
        \\
        \\export c("native_sum") fn native_sum(pair: Pair): c_int {
        \\    if pair.left == 40 {
        \\        if pair.right == 2 {
        \\            return 42;
        \\        }
        \\    }
        \\    return 0;
        \\}
        \\
        \\export c("make_pair") fn make_pair(): Pair {
        \\    return Pair { left: 40, right: 2 };
        \\}
        \\
        \\export c("add_one") fn add_one(value: c_int): c_int {
        \\    return value + 1;
        \\}
        \\
        \\fn main(): i32 {
        \\    const pair = Pair { left: 40, right: 2 };
        \\    if sum_pair(pair) != 42 {
        \\        return 1;
        \\    }
        \\    if call_native_sum() != 42 {
        \\        return 2;
        \\    }
        \\    if call_cb(add_one, 41) != 42 {
        \\        return 3;
        \\    }
        \\    if call_cb(c fn(value) {
        \\        return value + 1;
        \\    }, 41) != 42 {
        \\        return 6;
        \\    }
        \\    const returned = imported_make_pair();
        \\    if returned.left != 40 or returned.right != 2 {
        \\        return 4;
        \\    }
        \\    if call_make_pair() != 42 {
        \\        return 5;
        \\    }
        \\    return 42;
        \\}
    ;
    const c_source =
        \\struct Pair {
        \\    int left;
        \\    short right;
        \\};
        \\
        \\typedef int (*Callback)(int);
        \\
        \\int native_sum(struct Pair pair);
        \\struct Pair make_pair(void);
        \\struct Pair imported_make_pair(void);
        \\
        \\int sum_pair(struct Pair pair) {
        \\    return pair.left + pair.right;
        \\}
        \\
        \\int call_native_sum(void) {
        \\    struct Pair pair = { 40, 2 };
        \\    return native_sum(pair);
        \\}
        \\
        \\int call_cb(Callback cb, int value) {
        \\    return cb(value);
        \\}
        \\
        \\struct Pair imported_make_pair(void) {
        \\    struct Pair pair = { 40, 2 };
        \\    return pair;
        \\}
        \\
        \\int call_make_pair(void) {
        \\    struct Pair pair = make_pair();
        \\    if (pair.left == 40 && pair.right == 2) {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    try expectNativeWithCSources("native_c_abi_roundtrip_group.cy", source, &.{.{ .name = "abi_roundtrip.c", .source = c_source }}, 42);
}

test "native Darwin C ABI round trips a three-float struct" {
    const source =
        \\c struct Pixel { red: c_float; green: c_float; blue: c_float; }
        \\extern c("c_bounce") fn c_bounce(pixel: Pixel): Pixel;
        \\export c("expose_pixel") fn expose_pixel(pixel: Pixel, gain: c_float): Pixel {
        \\    return { red: pixel.red * gain, green: pixel.green * gain, blue: pixel.blue * gain };
        \\}
        \\fn main(): i32 {
        \\    const input: Pixel = { red: -0.5 as c_float, green: 0.25 as c_float, blue: 1.0 as c_float };
        \\    const output = c_bounce(input);
        \\    if output.red == -1.0 and output.green == 0.5 and output.blue == 2.0 { return 42; }
        \\    return 1;
        \\}
    ;
    const c_source =
        \\struct Pixel { float red; float green; float blue; };
        \\struct Pixel expose_pixel(struct Pixel pixel, float gain);
        \\struct Pixel c_bounce(struct Pixel pixel) { return expose_pixel(pixel, 2.0f); }
    ;
    try expectNativeWithCSources("native_three_float_pixel.cy", source, &.{.{ .name = "three_float_pixel.c", .source = c_source }}, 42);
}

test "native C float NaN is unequal to itself" {
    const source =
        \\extern c("make_nan") fn make_nan(): c_float;
        \\fn main(): i32 {
        \\    const sample = make_nan();
        \\    if sample != sample { return 42; }
        \\    return 1;
        \\}
    ;
    const c_source =
        \\#include <math.h>
        \\float make_nan(void) { return NAN; }
    ;
    try expectNativeWithCSources("native_float_nan_inequality.cy", source, &.{.{ .name = "float_nan.c", .source = c_source }}, 42);
}

test "native C ABI uses explicit C-layout adapters for byte payloads" {
    const source =
        \\c enum AbiError: i32 {
        \\    ABI_OK = 0,
        \\    ABI_FAIL = 1,
        \\}
        \\
        \\c struct BytePayload {
        \\    data: [3]u8;
        \\    status: AbiError;
        \\}
        \\
        \\extern {
        \\    c("call_inspect") fn call_inspect(): c_int;
        \\}
        \\
        \\export c("inspect_bytes") fn inspect_bytes(payload: BytePayload): c_int {
        \\    if payload.status == .ABI_OK and payload.data[0] == 65 and payload.data[1] == 66 and payload.data[2] == 67 {
        \\        return 42;
        \\    }
        \\    return 5;
        \\}
        \\
        \\fn main(): i32 {
        \\    if call_inspect() == 42 {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;
    const c_source =
        \\#include <stdint.h>
        \\#include <stddef.h>
        \\
        \\typedef enum AbiError {
        \\    ABI_OK = 0,
        \\    ABI_FAIL = 1,
        \\} AbiError;
        \\
        \\typedef struct BytePayload {
        \\    uint8_t data[3];
        \\    AbiError status;
        \\} BytePayload;
        \\
        \\extern int inspect_bytes(BytePayload payload);
        \\
        \\int call_inspect(void) {
        \\    BytePayload payload = {{ 65, 66, 67 }, ABI_OK};
        \\    return inspect_bytes(payload);
        \\}
    ;

    try expectNativeWithCSources("native_export_explicit_byte_payload.cy", source, &.{.{ .name = "explicit_byte_payload.c", .source = c_source }}, 42);
}

test "C ABI preserves fractional f64 through c_double and struct returns" {
    const source =
        \\c struct Value { payload: c_llong; tag: c_llong; }
        \\extern c("fraction") fn fraction(): c_double;
        \\extern c("number") fn number(value: c_double): Value;
        \\fn main(): i32 {
        \\    const value: f64 = fraction() as f64;
        \\    const result = number(value as c_double);
        \\    if result.tag != 7 { return 1; }
        \\    return result.payload as i32;
        \\}
    ;
    const c_source =
        \\typedef struct { long long payload; long long tag; } Value;
        \\double fraction(void) { return 0.1; }
        \\Value number(double value) { return (Value){value == 0.1 ? 42 : 2, 7}; }
    ;
    try expectNativeWithCSources("fractional_double.cy", source, &.{.{ .name = "fractional_double.c", .source = c_source }}, 42);
}

test "native indexed writes through borrowed fixed arrays update caller storage" {
    const source =
        \\fn fill(output: &[8]usize): void { output[0] = 3; output[7] = 5; }
        \\fn main(): i32 {
        \\    var values: [8]usize = [0] ** 8;
        \\    fill(&values);
        \\    return (values[0] + values[7]) as i32;
        \\}
    ;
    try expectNamedNative("borrowed_fixed_array_write", source, 8);
}
