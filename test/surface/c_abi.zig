const std = @import("std");

const compiler = @import("cyna").compiler;
const ast = compiler.ast;
const lexer = compiler.lexer;
const parser = compiler.parser;
const helpers = @import("../helpers.zig");

test "parser accepts C ABI extern and export declarations" {
    const source =
        \\extern {
        \\    pub c("strlen") fn strlen(text: c_str): c_size_t;
        \\    c("puts") fn puts(text: c_str): c_int;
        \\    c("free") fn free(ptr: ?*const c_void): void;
        \\    c("errno") const errno_slot: *c_int;
        \\    c("global_count") var global_count: c_int;
        \\}
        \\
        \\extern c("private_clock") fn private_clock(): c_int;
        \\pub extern c("public_clock") fn public_clock(): c_int;
        \\extern c("errno") const errno_direct: *c_int;
        \\extern c("lookup") fn lookup(out: **const c_char): c_int;
        \\
        \\export c("cyna_add") fn cyna_add(a: c_int, b: c_int): c_int {
        \\    return a + b;
        \\}
        \\
        \\pub export c("cyna_visible") fn cyna_visible(a: c_int): c_int {
        \\    return a;
        \\}
    ;

    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "abi_surface_test", source, tokens);
    defer program.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 8), program.functions.len);
    try std.testing.expectEqual(@as(usize, 3), program.globals.len);
    try std.testing.expect(program.functions[0].is_extern);
    try std.testing.expect(program.functions[0].is_pub);
    try std.testing.expectEqual(ast.CallingConvention.c, program.functions[0].calling_convention);
    try std.testing.expectEqualStrings("strlen", program.functions[0].abi_name.?);
    try std.testing.expect(program.functions[1].is_extern);
    try std.testing.expect(!program.functions[1].is_pub);
    try std.testing.expectEqualStrings("puts", program.functions[1].abi_name.?);
    try std.testing.expect(program.functions[2].is_extern);
    try std.testing.expectEqualStrings("free", program.functions[2].abi_name.?);
    try std.testing.expect(program.functions[2].params[0].type_name.is_raw);
    try std.testing.expect(program.functions[2].params[0].type_name.raw_is_const);
    try std.testing.expect(program.functions[3].is_extern);
    try std.testing.expect(!program.functions[3].is_pub);
    try std.testing.expectEqual(ast.CallingConvention.c, program.functions[3].calling_convention);
    try std.testing.expectEqualStrings("private_clock", program.functions[3].abi_name.?);
    try std.testing.expect(program.functions[4].is_extern);
    try std.testing.expect(program.functions[4].is_pub);
    try std.testing.expectEqualStrings("public_clock", program.functions[4].abi_name.?);
    try std.testing.expect(program.functions[5].params[0].type_name.is_raw);
    try std.testing.expect(program.functions[5].params[0].type_name.raw_target != null);
    try std.testing.expect(program.functions[5].params[0].type_name.raw_target.?.is_raw);
    try std.testing.expect(program.functions[5].params[0].type_name.raw_target.?.raw_is_const);
    try std.testing.expect(program.functions[6].is_export);
    try std.testing.expect(!program.functions[6].is_pub);
    try std.testing.expectEqual(ast.CallingConvention.c, program.functions[6].calling_convention);
    try std.testing.expectEqualStrings("cyna_add", program.functions[6].abi_name.?);
    try std.testing.expect(program.functions[7].is_export);
    try std.testing.expect(program.functions[7].is_pub);
    try std.testing.expectEqualStrings("cyna_visible", program.functions[7].abi_name.?);
    try std.testing.expect(program.globals[0].is_extern);
    try std.testing.expectEqual(ast.CallingConvention.c, program.globals[0].calling_convention);
    try std.testing.expectEqualStrings("errno", program.globals[0].abi_name.?);
    try std.testing.expect(program.globals[0].init == null);
    try std.testing.expect(program.globals[1].is_extern);
    try std.testing.expectEqualStrings("global_count", program.globals[1].abi_name.?);
    try std.testing.expect(program.globals[2].is_extern);
    try std.testing.expectEqualStrings("errno", program.globals[2].abi_name.?);
}

test "parser accepts attribute C ABI import and export declarations" {
    const source =
        \\@abi("c")
        \\@link.import("strlen")
        \\fn strlen(text: c_str): c_size_t;
        \\
        \\@abi("c")
        \\@link.import("errno")
        \\const errno_slot: *c_int;
        \\
        \\@abi("c")
        \\@link.export("cyna_add")
        \\fn add(a: c_int, b: c_int): c_int {
        \\    return a + b;
        \\}
        \\
        \\pub
        \\@abi("c")
        \\@link.export("cyna_visible")
        \\fn visible(a: c_int): c_int {
        \\    return a;
        \\}
        \\
        \\@asm.export("TF_SIZE")
        \\const trap_frame_size: usize = 32;
    ;

    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "attribute_abi_surface_test", source, tokens);
    defer program.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), program.functions.len);
    try std.testing.expectEqual(@as(usize, 1), program.globals.len);
    try std.testing.expectEqual(@as(usize, 1), program.asm_consts.len);
    try std.testing.expect(program.functions[0].is_extern);
    try std.testing.expectEqual(ast.CallingConvention.c, program.functions[0].calling_convention);
    try std.testing.expectEqualStrings("strlen", program.functions[0].abi_name.?);
    try std.testing.expect(program.functions[1].is_export);
    try std.testing.expectEqualStrings("cyna_add", program.functions[1].abi_name.?);
    try std.testing.expect(program.functions[2].is_export);
    try std.testing.expect(program.functions[2].is_pub);
    try std.testing.expectEqualStrings("cyna_visible", program.functions[2].abi_name.?);
    try std.testing.expect(program.globals[0].is_extern);
    try std.testing.expectEqual(ast.CallingConvention.c, program.globals[0].calling_convention);
    try std.testing.expectEqualStrings("errno", program.globals[0].abi_name.?);
    try std.testing.expect(program.globals[0].init == null);
    try std.testing.expectEqualStrings("TF_SIZE", program.asm_consts[0].abi_name.?);
}

test "parser rejects conflicting link attributes" {
    const source =
        \\@abi("c")
        \\@link.import
        \\@link.export
        \\fn bad(): void;
    ;

    try helpers.expectParseFailed(std.testing.allocator, "conflicting_link_attributes", source);
}

test "non-ABI functions cannot declare symbol aliases" {
    const source =
        \\fn helper(): i32 = "helper" {
        \\    return 42;
        \\}
    ;

    try helpers.expectParseFailed(std.testing.allocator, "non_abi_function_symbol_alias", source);
}

test "legacy trailing ABI symbol aliases are rejected" {
    const source =
        \\export c fn local(): void = "external" {
        \\}
    ;

    try helpers.expectParseFailed(std.testing.allocator, "legacy_abi_symbol_alias", source);
}

test "fused C-layout declaration spellings are rejected" {
    const cases = [_]struct { name: []const u8, source: []const u8 }{
        .{ .name = "legacy_cstruct_spelling", .source = "cstruct Value { field: c_int; }" },
        .{ .name = "legacy_cenum_spelling", .source = "cenum Value: c_int { item = 0, }" },
        .{ .name = "legacy_cunion_spelling", .source = "cunion Value { field: c_int; }" },
    };
    for (cases) |case| {
        try helpers.expectParseFailed(std.testing.allocator, case.name, case.source);
    }
}
