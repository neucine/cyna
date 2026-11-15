const std = @import("std");

const helpers = @import("../helpers.zig");

test "removed copy operator does not dispatch a reserved-looking method" {
    const source =
        \\struct Box {
        \\    value: string;
        \\
        \\    pub fn __copy(self: &const Box): Box {
        \\        return Box { value: self.value.clone() };
        \\    }
        \\}
        \\
        \\fn main(): void {
        \\    const box = Box { value: string.from("x".bytes()) };
        \\    const copied = copy box;
        \\}
        \\
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try helpers.expectParseFailedMessage(
        arena.allocator(),
        "copy_reserved_method_not_a_hook",
        source,
        "expected `;` after local declaration",
    );
}

test "resource duplication is an ordinary clone method" {
    const source =
        \\struct Box {
        \\    value: string;
        \\
        \\    pub fn clone(self: &const Box): Box {
        \\        return Box { value: self.value.clone() };
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    const box = Box { value: string.from("x".bytes()) };
        \\    const cloned = box.clone();
        \\    return cloned.value.len() as i32;
        \\}
        \\
    ;

    try helpers.expectLoadedSemanticSuccess(std.testing.allocator, "ordinary_clone_method", source);
}
