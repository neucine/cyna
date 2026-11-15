const std = @import("std");

const compiler = @import("cyna").compiler;
const lexer = compiler.lexer;
const parser = compiler.parser;
const parity = @import("targets.zig");
const sema = compiler.sema;

test "C ABI large cstruct boundary follows target aggregate policy" {
    const source =
        \\c struct Big {
        \\    a: c_ulong;
        \\    b: c_ulong;
        \\    c: c_ulong;
        \\}
        \\
        \\export c("bounce") fn bounce(value: Big): Big {
        \\    return value;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    const checks = [_]parity.LlvmCheck{
        .{
            .target = parity.freestanding_64[0],
            .contains = &.{
                "define void @bounce(ptr sret({ i64, i64, i64 }) %retptr, ptr %abi_arg0)",
                "load { i64, i64, i64 }, ptr %abi_arg0, align 8",
            },
            .excludes = &.{"define { i64, i64, i64 } @bounce"},
        },
        .{
            .target = parity.freestanding_64[1],
            .contains = &.{"define { i64, i64, i64 } @bounce({ i64, i64, i64 } %arg0)"},
            .excludes = &.{"sret({ i64, i64, i64 })"},
        },
        .{
            .target = parity.freestanding_64[2],
            .contains = &.{"define { i64, i64, i64 } @bounce({ i64, i64, i64 } %arg0)"},
            .excludes = &.{"sret({ i64, i64, i64 })"},
        },
    };

    try parity.expectLlvmChecks("c_abi_large_cstruct_boundary", source, &checks);
}

test "AArch64 C ABI small cstruct boundary remains direct" {
    const source =
        \\c struct Pair {
        \\    a: c_ulong;
        \\    b: c_ulong;
        \\}
        \\
        \\export c("bounce_pair") fn bounce_pair(value: Pair): Pair {
        \\    return value;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    const checks = [_]parity.LlvmCheck{
        .{
            .target = parity.aarch64[0],
            .contains = &.{"define { i64, i64 } @bounce_pair({ i64, i64 } %arg0)"},
            .excludes = &.{"sret({ i64, i64 })"},
        },
    };

    try parity.expectLlvmChecks("c_abi_small_cstruct_boundary", source, &checks);
}

test "comptime C ABI layout metadata follows selected build target" {
    const source =
        \\fn main(): usize {
        \\    return comptime c_long.size;
        \\}
    ;

    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "comptime_target_layout", source, tokens);
    defer program.deinit(std.testing.allocator);

    {
        const module = try sema.buildSirWithOptions(std.testing.allocator, "comptime_target_layout", program, .{
            .target = parity.pointer_width[1].triple,
        });
        defer module.deinit(std.testing.allocator);
        const main = sema.findFunction(module, "main").?;
        try std.testing.expect(main.body.len == 1);
        const ret = main.body[0].@"return".?;
        try std.testing.expectEqual(@as(i64, 8), ret.int.value);
        try std.testing.expectEqualStrings("usize", ret.int.type_name.?);
    }

    {
        const module = try sema.buildSirWithOptions(std.testing.allocator, "comptime_target_layout", program, .{
            .target = parity.pointer_width[0].triple,
        });
        defer module.deinit(std.testing.allocator);
        const main = sema.findFunction(module, "main").?;
        try std.testing.expect(main.body.len == 1);
        const ret = main.body[0].@"return".?;
        try std.testing.expectEqual(@as(i64, 4), ret.int.value);
        try std.testing.expectEqualStrings("usize", ret.int.type_name.?);
    }
}

test "c_size_t size metadata supplies portable raw pointer stride" {
    const source =
        \\fn main(): usize {
        \\    return comptime c_size_t.size;
        \\}
    ;
    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "c_size_t_stride", source, tokens);
    defer program.deinit(std.testing.allocator);

    for (parity.pointer_width, [_]i64{ 4, 8 }) |target, expected| {
        const module = try sema.buildSirWithOptions(std.testing.allocator, "c_size_t_stride", program, .{
            .target = target.triple,
        });
        defer module.deinit(std.testing.allocator);
        const main = sema.findFunction(module, "main").?;
        try std.testing.expectEqual(expected, main.body[0].@"return".?.int.value);
    }
}

test "module constant comptime C ABI metadata follows selected build target" {
    const source =
        \\pub const long_size: usize = comptime c_long.size;
        \\
        \\fn main(): usize {
        \\    return long_size;
        \\}
    ;

    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "comptime_global_target_layout", source, tokens);
    defer program.deinit(std.testing.allocator);

    {
        const module = try sema.buildSirWithOptions(std.testing.allocator, "comptime_global_target_layout", program, .{
            .target = parity.pointer_width[1].triple,
        });
        defer module.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), module.globals.len);
        try std.testing.expectEqual(@as(i64, 8), module.globals[0].init.?.int.value);
        try std.testing.expectEqualStrings("usize", module.globals[0].init.?.int.type_name.?);
    }

    {
        const module = try sema.buildSirWithOptions(std.testing.allocator, "comptime_global_target_layout", program, .{
            .target = parity.pointer_width[0].triple,
        });
        defer module.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), module.globals.len);
        try std.testing.expectEqual(@as(i64, 4), module.globals[0].init.?.int.value);
        try std.testing.expectEqualStrings("usize", module.globals[0].init.?.int.type_name.?);
    }
}
