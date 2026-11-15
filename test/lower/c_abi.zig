const std = @import("std");

const compiler = @import("cyna").compiler;
const lexer = compiler.lexer;
const parser = compiler.parser;
const sema = compiler.sema;
const lir_support = @import("lir_support.zig");

test "C ABI symbol names are preserved in SIR" {
    const source =
        \\extern c("puts") fn puts(text: c_str): c_int;
        \\extern c("errno") const errno_slot: *c_int;
        \\
        \\export c("cyna_add") fn add(a: c_int, b: c_int): c_int {
        \\    return a + b;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 42;
        \\}
    ;

    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "abi_symbol_cir_test", source, tokens);
    defer program.deinit(std.testing.allocator);
    const module = try sema.buildSir(std.testing.allocator, "abi_symbol_cir_test", program);
    defer module.deinit(std.testing.allocator);

    const puts_fn = sema.findFunction(module, "puts").?;
    try std.testing.expectEqualStrings("puts", puts_fn.abi_name.?);

    const add_fn = sema.findFunction(module, "add").?;
    try std.testing.expectEqualStrings("cyna_add", add_fn.abi_name.?);
    try std.testing.expectEqual(@as(usize, 1), module.globals.len);
    try std.testing.expect(module.globals[0].is_extern);
    try std.testing.expectEqualStrings("errno", module.globals[0].abi_name.?);
    try std.testing.expect(module.globals[0].is_symbol_addr);
    try std.testing.expect(module.globals[0].init == null);
}

test "static string to c_str adaptation lowers as a raw NUL-terminated pointer" {
    const source =
        \\extern c fn inspect(text: c_str): c_int;
        \\
        \\fn main(): i32 {
        \\    const ignored = inspect("hello");
        \\    return 0;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_c_str_literal.cy", source);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "const_c_str \"hello\"") != null);
}
