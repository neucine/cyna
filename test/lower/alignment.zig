const std = @import("std");

const compiler = @import("cyna").compiler;
const lexer = compiler.lexer;
const parser = compiler.parser;
const sema = compiler.sema;

test "alignment SIR marks projected resource clone receiver as borrowed field" {
    const source =
        \\struct Inner {
        \\    items: [:]i32;
        \\}
        \\
        \\struct Outer {
        \\    inner: Inner;
        \\}
        \\
        \\fn main(): void {
        \\    var outer = Outer {
        \\        inner: Inner { items: [1, 2, 3] }
        \\    };
        \\    const items = outer.inner.items.clone();
        \\}
        \\
    ;

    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "alignment_sir_borrowed_field_dump", source, tokens);
    defer program.deinit(std.testing.allocator);
    const module = try sema.buildSir(std.testing.allocator, "alignment_sir_borrowed_field_dump", program);
    defer module.deinit(std.testing.allocator);

    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    var text_writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &text);
    try module.dump(&text_writer.writer);
    text = text_writer.toArrayList();

    try std.testing.expect(std.mem.indexOf(u8, text.items, "copy_list(") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "borrowed outer.inner.items") != null);
}

test "alignment SIR marks projected resource copy operand as borrowed index" {
    const source =
        \\fn main(views: [:][]i32): void {
        \\    const item = views[0];
        \\}
        \\
    ;

    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "alignment_sir_borrowed_index_dump", source, tokens);
    defer program.deinit(std.testing.allocator);
    const module = try sema.buildSir(std.testing.allocator, "alignment_sir_borrowed_index_dump", program);
    defer module.deinit(std.testing.allocator);

    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    var text_writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &text);
    try module.dump(&text_writer.writer);
    text = text_writer.toArrayList();

    try std.testing.expect(std.mem.indexOf(u8, text.items, "borrowed views[0]") != null);
}

test "alignment SIR keeps nested field aliases as ref paths" {
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
        \\fn main(): void {
        \\    var user = User { inner: Inner { age: 0 } };
        \\    set_age(&user.inner.age);
        \\}
        \\
    ;

    const tokens = try lexer.lexAll(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);
    const program = try parser.parse(std.testing.allocator, "alignment_sir_nested_field_alias_dump", source, tokens);
    defer program.deinit(std.testing.allocator);
    const module = try sema.buildSir(std.testing.allocator, "alignment_sir_nested_field_alias_dump", program);
    defer module.deinit(std.testing.allocator);

    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    var text_writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &text);
    try module.dump(&text_writer.writer);
    text = text_writer.toArrayList();

    try std.testing.expect(std.mem.indexOf(u8, text.items, "&user.inner.age") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "&user.inner)") == null);
}
