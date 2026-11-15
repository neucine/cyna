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

test "LIR lowers field alias mutation through ref params" {
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

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_field_alias.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "&i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "field_ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_fn_") != null);
}

test "LIR lowers nested field alias mutation through field pointer chain" {
    const source =
        \\struct Inner {
        \\    age: i32;
        \\}
        \\
        \\struct User {
        \\    inner: Inner;
        \\}
        \\
        \\fn set_age(value: &i32): void {
        \\    value = 42;
        \\}
        \\
        \\fn main(): i32 {
        \\    var user = User { inner: Inner { age: 0 } };
        \\    set_age(&user.inner.age);
        \\    return user.inner.age;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_nested_field_alias.cy", source);
    defer std.testing.allocator.free(text);

    const main_at = std.mem.indexOf(u8, text, "fn main() -> i32") orelse return error.TestUnexpectedResult;
    const next_fn = std.mem.indexOfPos(u8, text, main_at + 1, "\nfn ") orelse text.len;
    const main_body = text[main_at..next_fn];
    var field_ptr_count: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, main_body, offset, "field_ptr")) |pos| {
        field_ptr_count += 1;
        offset = pos + "field_ptr".len;
    }

    try std.testing.expect(field_ptr_count >= 2);
    try std.testing.expect(std.mem.indexOf(u8, main_body, "call cyna_fn_") != null);
}

test "LIR lowers owned field alias mutation through ref params" {
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

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_owned_field_alias.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "make_struct(") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "field_ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_fn_") != null);
}

test "LIR lowers array index alias mutation through ref params" {
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

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_array_index_alias.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "[2]i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "make_array(") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "index_ptr") != null);
}

test "LIR lowers slice index alias mutation through ref params" {
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

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_slice_index_alias.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "[]i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "make_slice") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extract_slice_ptr") != null);
}

test "LIR lowers read-only syntax index aliases without storage field convention" {
    const source =
        \\struct Bag {
        \\    items: [:]i32;
        \\
        \\
        \\    @syntax.index
        \\    fn index(self: &const Bag, index: usize): &const i32 {
        \\        return &self.items[index];
        \\    }
        \\
        \\}
        \\
        \\
        \\
        \\fn read_value(value: &const i32): i32 {
        \\    return value;
        \\}
        \\
        \\fn main(): i32 {
        \\    var bag = Bag { items: [1, 2] };
        \\    const before = bag[1];
        \\    return before + read_value(&bag[0]);
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_syntax_index_alias.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Bag") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_fn_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dense_at") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "load %") != null);
}

test "LIR lowers field projection through read-only syntax index alias" {
    const source =
        \\struct Item { value: i32; }
        \\
        \\struct Bag { items: [:]Item;
        \\    @syntax.index
        \\    fn index(self: &const Bag, index: usize): &const Item {
        \\        return &self.items[index];
        \\    }
        \\
        \\}
        \\
        \\
        \\
        \\fn expose(bag: &const Bag): &const i32 {
        \\    return &bag[0].value;
        \\}
        \\
        \\fn main(): i32 {
        \\    const bag = Bag { items: [Item { value: 42 }] };
        \\    const value: &const i32 = expose(&bag);
        \\    return value;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_syntax_index_readonly_field_alias.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "field_ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dense_at") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_fn_") != null);
}

test "LIR lowers projected global alias through global and field pointers" {
    const source =
        \\struct Item { value: i32; }
        \\
        \\const item: Item = Item { value: 42 };
        \\
        \\fn expose(): &const i32 { return &item.value; }
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_projected_global_alias.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "global_addr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "field_ptr") != null);
}

test "LIR lowers projected raw alias through pointer expression and field projection" {
    const source =
        \\struct Item { value: i32; }
        \\
        \\fn expose(ptr: *Item): &i32 {
        \\    unchecked { return &(*ptr).value; }
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_projected_raw_alias.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "field_ptr") != null);
}
