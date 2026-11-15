const std = @import("std");
const compiler = @import("cyna").compiler;
const sir_type_validation = compiler.sir_type_validation;
const semantic_types = compiler.semantic_types;
const sir = compiler.sir;
const sema = compiler.sema;
const findFunction = sema.findFunction;

test "SIR type validation checks nested type IDs and expression cycles" {
    const allocator = std.testing.allocator;
    var interner = semantic_types.TypeInterner.init(allocator);
    defer interner.deinit();
    const void_type = try interner.intern(.{ .primitive = .void });

    var expr: sir.Expr = .{ .array_default = .{ .len = 1, .item_type_id = void_type } };
    const body = [_]sir.Stmt{.{ .expr = &expr }};
    const functions = [_]sir.Function{.{
        .owner = null,
        .name = "example",
        .params = &.{},
        .return_type_id = void_type,
        .body = &body,
    }};
    try sir_type_validation.validate(allocator, &interner, &.{}, &.{}, &.{}, &functions);

    expr.array_default.item_type_id = @fromBackingInt(@intCast(999));
    try std.testing.expectError(error.SemanticFailed, sir_type_validation.validate(allocator, &interner, &.{}, &.{}, &.{}, &functions));

    expr = .{ .ref_load = &expr };
    try std.testing.expectError(error.SemanticFailed, sir_type_validation.validate(allocator, &interner, &.{}, &.{}, &.{}, &functions));
}

test "finds function" {
    const functions = [_]sir.Function{
        .{ .module_name = "", .owner = null, .name = "main", .params = &.{}, .return_type_id = @fromBackingInt(@intCast(0)), .body = &.{} },
    };
    try std.testing.expect(findFunction(.{ .globals = &.{}, .asm_consts = &.{}, .enums = &.{}, .unions = &.{}, .structs = &.{}, .functions = &functions }, "main") != null);
}
