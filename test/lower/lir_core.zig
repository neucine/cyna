const std = @import("std");
const builtin = @import("builtin");

const cyna = @import("cyna");
const compat = cyna.compat;
const compiler = cyna.compiler;
const lexer = compiler.lexer;
const loader = compiler.loader;
const parser = compiler.parser;
const sema = compiler.sema;
const sir = compiler.sir;
const identity = compiler.identity;
const semantic_types = compiler.semantic_types;
const lowerModule = compiler.lower.lowerModule;
const lowerModuleWithOptions = compiler.lower.lowerModuleWithOptions;

const lir_support = @import("lir_support.zig");

test "LIR lowers return constant" {
    const source =
        \\fn main(): i32 {
        \\    return 42;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_return_const.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "fn main() -> i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "const_int 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "return %") != null);
}

test "LIR extracts const slice pointer" {
    const source =
        \\fn first_address(bytes: []const u8): *const u8 { return bytes.ptr; }
        \\fn main(): i32 { return 0; }
    ;
    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_slice_ptr.cy", source);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "extract_slice_ptr") != null);
}

test "LIR rejects a nominal global without canonical type identity" {
    const box_a_id: identity.DeclId = @fromBackingInt(@intCast(0));
    const box_b_id: identity.DeclId = @fromBackingInt(@intCast(1));
    const global_id: identity.DeclId = @fromBackingInt(@intCast(2));
    const structs = [_]sir.StructDecl{
        .{ .decl_id = box_a_id, .module_name = "a", .name = "Box", .layout = .normal, .fields = &.{} },
        .{ .decl_id = box_b_id, .module_name = "b", .name = "Box", .layout = .normal, .fields = &.{} },
    };
    const globals = [_]sir.Global{
        .{
            .decl_id = global_id,
            .module_name = "main",
            .owner = null,
            .name = "box",
            .is_mutable = false,
            .type_id = null,
            .init = null,
        },
    };
    var types = semantic_types.TypeInterner.init(std.testing.allocator);
    defer types.deinit();
    const module = sir.Module{
        .canonical_types = types,
        .globals = &globals,
        .enums = &.{},
        .unions = &.{},
        .structs = &structs,
        .functions = &.{},
    };

    try std.testing.expectError(error.InvalidIdentity, lowerModule(std.testing.allocator, module));
}

test "LIR lowers canonical nominal identity despite short-name collisions" {
    const box_a_id: identity.DeclId = @fromBackingInt(@intCast(0));
    const box_b_id: identity.DeclId = @fromBackingInt(@intCast(1));
    const global_id: identity.DeclId = @fromBackingInt(@intCast(2));
    const structs = [_]sir.StructDecl{
        .{ .decl_id = box_a_id, .module_name = "a", .name = "Box", .layout = .normal, .fields = &.{} },
        .{ .decl_id = box_b_id, .module_name = "b", .name = "Box", .layout = .normal, .fields = &.{} },
    };
    var types = semantic_types.TypeInterner.init(std.testing.allocator);
    defer types.deinit();
    const box_b_type = try types.intern(.{ .nominal = .{ .kind = .@"struct", .decl_id = box_b_id } });
    const globals = [_]sir.Global{
        .{
            .decl_id = global_id,
            .module_name = "main",
            .owner = null,
            .name = "box",
            .is_mutable = false,
            .type_id = box_b_type,
            .init = null,
        },
    };
    const module = sir.Module{
        .canonical_types = types,
        .globals = &globals,
        .enums = &.{},
        .unions = &.{},
        .structs = &structs,
        .functions = &.{},
    };

    const lowered = try lowerModule(std.testing.allocator, module);
    defer lowered.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), lowered.globals.len);
}

test "LIR lowers param load add and return" {
    const source =
        \\fn add_one(x: i32): i32 {
        \\    var y = x + 1;
        \\    return y;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_add_one.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "param_ref 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "int_binop add") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "stack_alloc i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "return %") != null);
}

test "LIR lowers integer remainder" {
    const source =
        \\fn main(): i32 {
        \\    return 17 % 16;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_int_remainder.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "int_binop mod") != null);
}

test "LIR lowers float arithmetic and comparison" {
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

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_float_add.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "fn cyna_fn_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "float_binop add") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "float_cmp eq") != null);
}

test "LIR lowers mixed int and float arithmetic with coercion" {
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

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_mixed_float_add.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "int_to_float") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "float_binop add") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "float_cmp eq") != null);
}

test "LIR lowers checked float casts" {
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

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_float_casts.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "float_to_float") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "float_to_int") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "int_to_float") != null);
}

test "LIR lowers c_float fixed array literals as 32-bit floats" {
    const source =
        \\fn main(): i32 {
        \\    var rounded: [1]c_float = [0.0];
        \\    return 0;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_c_float_array.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "[1]f32") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[1]f64") == null);
}

test "LIR lowers checked integer and enum casts" {
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

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_int_enum_casts.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "int_cmp ge") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "int_cmp le") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "int_cmp eq") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "int_binop bit_or") != null);
}

test "LIR preserves explicit enum representation width" {
    const source =
        \\enum Mode: i16 {
        \\    ready = 1,
        \\    error = 2,
        \\}
        \\
        \\fn echo(mode: Mode): Mode {
        \\    return mode;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_enum_repr_width.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "fn cyna_fn_") != null);
}

test "LIR checks narrow integer and enum casts at semantic width" {
    const source =
        \\enum Mode: i16 {
        \\    ready = 42,
        \\    error = 7,
        \\}
        \\
        \\fn main(): i32 {
        \\    const raw: i16 = 42;
        \\    const small = raw as i8;
        \\    const mode = raw as Mode;
        \\    return (small as i32) + ((mode as i16) as i32) - 42;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_narrow_enum_cast_width.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "local#2 mode: i16") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "stack_alloc i8") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "int_cmp eq") != null);
}

test "LIR lowers optional and union payload casts" {
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

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_optional_union_casts.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "extract_tag") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extract_payload") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "make_some") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "make_none") != null);
}

test "LIR lowers try into explicit result control flow" {
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
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_try.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_fn_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extract_tag") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extract_result ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extract_result err") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "make_result ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "make_result err") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "cond_br %") != null);
}

test "LIR lowers result switch into explicit control flow" {
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
        \\fn main(): i32 {
        \\    const value = produce() catch (status) {
        \\        const ignored = status;
        \\        return 1;
        \\    };
        \\    return value;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_result_switch.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_fn_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extract_tag") != null);
    try std.testing.expect(std.mem.count(u8, text, "switch_case") >= 2);
    try std.testing.expect(std.mem.indexOf(u8, text, "extract_result ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extract_result err") != null);
}

test "LIR lowers optional capture if into explicit control flow" {
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

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_optional_if.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "fn cyna_fn_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "make_some") != null or std.mem.indexOf(u8, text, "store %0, %") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "make_none") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extract_tag") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extract_payload") != null);
}

test "LIR lowers top-level globals" {
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

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_top_level_globals.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "globals:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "base: i32 = \"cyna_global_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "answer: i32 = \"cyna_global_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "counter: i32 = \"cyna_global_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "global_addr cyna_global_") != null);
}

test "LIR lowers declarative aggregate globals" {
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

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_aggregate_globals.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "pair: Pair = \"cyna_global_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "values: [2]i32 = \"cyna_global_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "global_addr cyna_global_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "index_ptr") != null);
}

test "LIR lowers union capture if into explicit control flow" {
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

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_union_if.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "fn main() -> i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "make_union tag=") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extract_tag") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extract_payload") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "string_cmp eq") != null);
}

test "LIR lowers struct literals and field access" {
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

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_struct_field.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "User") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "make_struct(") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "field_ptr") != null);
}

test "LIR lowers short-circuit and into explicit control flow" {
    const source =
        \\fn main(): i32 {
        \\    if 1 == 1 and 2 == 2 {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_short_circuit_and.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "and_rhs") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "and_short") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "and_cont") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "cond_br %") != null);
}

test "LIR lowers heterogeneous union switch" {
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

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_union_switch_heterogeneous.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Token/*string, i32, void*/") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "make_union tag=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extract_payload %") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "case=1") != null);
}
