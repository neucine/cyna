const std = @import("std");

const compiler = @import("cyna").compiler;
const ast = compiler.ast;
const lexer = compiler.lexer;
const parser = compiler.parser;

test "parser accepts module import pub and distinct declarations" {
    const source =
        \\import std.io;
        \\import app.util as util;
        \\import { Reader as IoReader, write_string } from std.io;
        \\
        \\pub type UserId = distinct i32;
        \\
        \\pub c enum UserState: i32 {
        \\    ready = 0,
        \\}
        \\
        \\pub flags UserFlags: i32 {
        \\    active = 1,
        \\}
        \\
        \\pub enum UserKind: i16 {
        \\    admin = 1,
        \\}
        \\
        \\pub union MaybeUser {
        \\    user: User;
        \\    missing;
        \\}
        \\
        \\pub c union RawBits {
        \\    int_value: i32;
        \\    bool_value: bool;
        \\}
        \\
        \\pub packed struct User {
        \\    pub id: UserId;
        \\
        \\    pub fn matches(self: User, other: UserId): bool {
        \\        return false;
        \\    }
        \\}
        \\
        \\pub c struct Handle {
        \\    pub raw: c_ulong;
        \\
        \\    @concurrency.isolated
        \\    pub fn valid(self: Handle): bool {
        \\        return self.raw != 0;
        \\    }
        \\}
        \\
        \\pub fn main(): i32 {
        \\    return 0;
        \\}
    ;

    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "surface_test", source, tokens);
    defer program.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), program.imports.len);
    try std.testing.expectEqualStrings("std.io", program.imports[0].path);
    try std.testing.expectEqual(@as(usize, 0), program.imports[0].items.len);
    try std.testing.expect(program.imports[0].local_name == null);
    try std.testing.expectEqualStrings("app.util", program.imports[1].path);
    try std.testing.expectEqualStrings("util", program.imports[1].local_name.?);
    try std.testing.expectEqualStrings("std.io", program.imports[2].path);
    try std.testing.expectEqual(@as(usize, 2), program.imports[2].items.len);
    try std.testing.expectEqualStrings("Reader", program.imports[2].items[0].name);
    try std.testing.expectEqualStrings("IoReader", program.imports[2].items[0].local_name.?);
    try std.testing.expectEqualStrings("write_string", program.imports[2].items[1].name);
    try std.testing.expect(program.imports[2].items[1].local_name == null);
    try std.testing.expectEqual(@as(usize, 1), program.aliases.len);
    try std.testing.expect(program.aliases[0].is_pub);
    try std.testing.expect(program.aliases[0].is_distinct);
    try std.testing.expectEqual(@as(usize, 3), program.enums.len);
    try std.testing.expectEqual(ast.EnumLayout.c, program.enums[0].layout);
    try std.testing.expectEqualStrings("i32", program.enums[0].repr_name.?);
    try std.testing.expectEqual(ast.EnumLayout.flags, program.enums[1].layout);
    try std.testing.expectEqualStrings("i32", program.enums[1].repr_name.?);
    try std.testing.expectEqual(ast.EnumLayout.normal, program.enums[2].layout);
    try std.testing.expectEqualStrings("i16", program.enums[2].repr_name.?);
    try std.testing.expectEqual(@as(usize, 2), program.unions.len);
    try std.testing.expectEqual(ast.UnionLayout.normal, program.unions[0].layout);
    try std.testing.expectEqual(ast.UnionLayout.c, program.unions[1].layout);
    try std.testing.expectEqual(@as(usize, 2), program.structs.len);
    try std.testing.expect(program.structs[0].is_pub);
    try std.testing.expectEqual(ast.StructLayout.@"packed", program.structs[0].layout);
    try std.testing.expect(program.structs[0].fields[0].is_pub);
    try std.testing.expect(program.structs[0].methods[0].is_pub);
    try std.testing.expect(program.structs[1].is_pub);
    try std.testing.expectEqual(ast.StructLayout.c, program.structs[1].layout);
    try std.testing.expect(program.structs[1].fields[0].is_pub);
    try std.testing.expect(program.structs[1].methods[0].is_pub);
    try std.testing.expect(program.structs[1].methods[0].is_isolated);
    try std.testing.expectEqual(@as(usize, 1), program.functions.len);
    try std.testing.expect(program.functions[0].is_pub);
    try std.testing.expectEqual(@as(usize, 0), program.tests.len);
}

test "parser records thread safety attributes" {
    const source =
        \\@concurrency.shareable
        \\pub struct Mutex {
        \\    raw: c_ulong;
        \\}
        \\
        \\@shared_value
        \\pub struct Arc {
        \\    raw: c_ulong;
        \\}
        \\
        \\@ownership.owned
        \\pub struct Thread {
        \\    raw: c_ulong;
        \\}
        \\
        \\@concurrency.trusted_extern
        \\extern c("tick") fn tick(): void;
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "thread_attrs_parse", source, tokens);
    defer program.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), program.structs.len);
    try std.testing.expect(program.structs[0].is_concurrency_shareable);
    try std.testing.expect(program.structs[1].is_shared_value);
    try std.testing.expect(program.structs[2].is_owned_value);
    try std.testing.expectEqual(@as(usize, 2), program.functions.len);
    try std.testing.expect(program.functions[0].is_extern);
    try std.testing.expect(program.functions[0].is_concurrency_trusted_extern);
}

test "parser accepts test blocks for dedicated test files" {
    const source =
        \\test "smoke" {
        \\    const value: i32 = 1;
        \\    assert(value == 1);
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "parser.test.cy", source, tokens);
    defer program.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), program.tests.len);
    try std.testing.expectEqualStrings("smoke", program.tests[0].name);
    try std.testing.expectEqual(@as(usize, 2), program.tests[0].body.len);
}

test "parser accepts sparse storage type and contextual construction" {
    const source =
        \\fn main(): void {
        \\    var slots: [;]i32 = [; 128];
        \\}
        \\
    ;

    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "sparse_array_parse", source, tokens);
    defer program.deinit(std.testing.allocator);
}

test "parser accepts sparse storage inline literal construction" {
    const source =
        \\fn main(): void {
        \\    var slots: [;]i32 = [; 8] [1, none, 3];
        \\}
        \\
    ;

    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "sparse_array_inline_parse", source, tokens);
    defer program.deinit(std.testing.allocator);
}

test "parser accepts sparse storage keyed literal construction" {
    const source =
        \\fn main(): void {
        \\    var slots: [;]i32 = [; 16] { 3: 40, 10: 2 };
        \\}
        \\
    ;

    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "sparse_array_keyed_parse", source, tokens);
    defer program.deinit(std.testing.allocator);
}

test "parser accepts dynamic sparse storage construction" {
    const source =
        \\fn main(): void {
        \\    const cap = 16;
        \\    var slots = [; cap]i32;
        \\}
        \\
    ;

    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "dynamic_sparse_array_parse", source, tokens);
    defer program.deinit(std.testing.allocator);
}

test "parser accepts dense storage capacity construction" {
    const source =
        \\fn main(): void {
        \\    var buf: [:]i32 = [: 16] [1, 2, 3];
        \\}
        \\
    ;

    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "dense_storage_capacity_parse", source, tokens);
    defer program.deinit(std.testing.allocator);
}

test "parser accepts dynamic dense storage construction" {
    const source =
        \\fn main(): void {
        \\    const cap = 16;
        \\    var buf = [: cap]i32;
        \\}
        \\
    ;

    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "dynamic_dense_storage_parse", source, tokens);
    defer program.deinit(std.testing.allocator);
}

test "parser accepts non-escaping callable parameter types" {
    const source =
        \\fn apply(value: i32, f: (i32) => i32): i32 {
        \\    return f(value);
        \\}
        \\
        \\fn visit_named(value: i32, f: (item: i32) => void): void {
        \\    f(value);
        \\}
    ;

    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "arrow_callable_parse", source, tokens);
    defer program.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), program.functions.len);

    const apply_callable = program.functions[0].params[1].type_name;
    try std.testing.expect(apply_callable.is_arrow_callable);
    try std.testing.expect(!apply_callable.is_function);
    try std.testing.expectEqual(@as(usize, 1), apply_callable.function_params.len);
    try std.testing.expectEqualStrings("i32", apply_callable.function_params[0].name);
    try std.testing.expect(apply_callable.function_return_type != null);
    try std.testing.expectEqualStrings("i32", apply_callable.function_return_type.?.name);

    const visit_callable = program.functions[1].params[1].type_name;
    try std.testing.expect(visit_callable.is_arrow_callable);
    try std.testing.expectEqual(@as(usize, 1), visit_callable.function_params.len);
    try std.testing.expectEqualStrings("i32", visit_callable.function_params[0].name);
    try std.testing.expectEqualStrings("void", visit_callable.function_return_type.?.name);
}
