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

test "LIR borrows string bytes receiver loaded from sequence view index place" {
    const source =
        \\struct Pool {
        \\    symbols: List<string>;
        \\
        \\    fn contains(self: &Pool, value: []const u8): bool {
        \\        var index: usize = 0;
        \\        while index < self.symbols.len() {
        \\            if self.symbols[index].bytes() == value {
        \\                return true;
        \\            }
        \\            index = index + 1;
        \\        }
        \\        return false;
        \\    }
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_string_bytes_sequence_view_index_share.cy", source);
    defer std.testing.allocator.free(text);
    // Prelude helpers may share their own strings. Only the receiver path in
    // Pool.contains must borrow without creating an owner.
    const start = std.mem.indexOf(u8, text, "_contains(") orelse return error.TestUnexpectedResult;
    const end = std.mem.indexOfPos(u8, text, start, "\nfn ") orelse text.len;
    const body = text[start..end];
    errdefer std.debug.print("Failing contains LIR:\n{s}\n", .{body});
    try std.testing.expect(std.mem.indexOf(u8, body, "borrowed_projection string_receiver_from_place") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "_index(") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "sequence_cmp eq") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "call cyna_string_share_into(") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "string_view_owner") == null);
}

test "LIR shares string backing for plain value flow" {
    const source =
        \\struct User {
        \\    name: string;
        \\}
        \\
        \\fn same(text: string): bool {
        \\    return text == "Ada";
        \\}
        \\
        \\fn main(): i32 {
        \\    const a = "Ada";
        \\    const b = a;
        \\    const user = User { name: b };
        \\    if same(user.name) {
        \\        return 42;
        \\    }
        \\    return 1;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_string_plain_flow_shares.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_string_share_into(") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_string_copy(") == null);
}

test "LIR lowers explicit string clone to distinct backing copy" {
    const source =
        \\fn main(): i32 {
        \\    const a = "Ada";
        \\    const b = a.clone();
        \\    if a == b {
        \\        return 42;
        \\    }
        \\    return 1;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_string_explicit_copy.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "string_from") != null or std.mem.indexOf(u8, text, "call cyna_string_from") != null);
}

test "LIR stores strings in list through descriptor copy without deep string copy" {
    const source =
        \\fn main(): i32 {
        \\    var names: List<string> = list<string>();
        \\    const ada = "Ada";
        \\    names.push(ada);
        \\    names.push("Ken");
        \\    return names.len() as i32;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_string_list_storage_shares.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "dense_push") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "type_desc string") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_string_share_into(") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_string_release_at(") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_string_copy(") == null);
}

test "LIR stores strings in set and map through descriptor copy without deep string copy" {
    const source =
        \\fn main(): i64 {
        \\    var names: Set<string> = set<string>();
        \\    const ada = "Ada";
        \\    names.add(ada);
        \\    names.add("Ken");
        \\
        \\    var scores: Map<string, string> = map<string, string>();
        \\    scores[ada] = "42";
        \\    scores["Ken"] = ada;
        \\    return (names.len() + scores.len()) as i64;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_string_set_map_storage_shares.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_fn_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "sparse_insert") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "type_desc string") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_string_share_into(") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_string_release_at(") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_string_copy(") == null);
}

test "LIR treats fixed arrays of strings as structural shared values" {
    const source =
        \\fn main(): i32 {
        \\    const ada = "Ada";
        \\    const names: [2]string = [ada, "Ken"];
        \\    const aliases: [2]string = names;
        \\    if aliases[0] == "Ada" {
        \\        return 42;
        \\    }
        \\    return 1;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_string_fixed_array_structural_share.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "[2]string") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "make_array(") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "type_desc [2]string") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_copy_") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_string_share_into(") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_string_release_at(") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_string_copy(") == null);
}
