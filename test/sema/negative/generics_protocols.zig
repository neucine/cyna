const std = @import("std");

test "generic method admission retains typed keyed and assembly result origins" {
    const sources = [_][]const u8{
        "fn inspect<T>(value: T): i32 { var slots = [;]T { 0: value }; if &slots[0] is item { return item.secret(); } return 0; } fn main(): i32 { return 0; }",
        "fn inspect<T>(): i32 { unchecked { const selected = asm(T) { \"{result}\"; out reg result; }; return selected.secret(); } } fn main(): i32 { return 0; }",
    };
    for (sources) |source| try helpers.expectSemanticFailedMessage(std.testing.allocator, "generic_constructor_origin", source, "generic parameter `T` requires a declared protocol for method `secret`");
}

test "generic method admission retains sequence repeat inference origins" {
    const source =
        \\fn first<U>(values: [2]U): U { return values[0]; }
        \\fn inspect<T>(value: T): i32 { const selected = first([value] ** 2); return selected.secret(); }
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "generic_repeat_origin", source, "generic parameter `T` requires a declared protocol for method `secret`");
}

test "generic method admission retains language associated element origins" {
    for ([_][]const u8{
        "fn inspect<T>(values: &const List<T>): i32 { return values[0].secret(); } fn main(): i32 { return 0; }",
        "fn inspect<T>(values: &const List<T>): i32 { for item in values { return item.secret(); } return 0; } fn main(): i32 { return 0; }",
    }) |source| try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "generic_associated_element_origin", source, "generic parameter `T` requires a declared protocol for method `secret`");
}

test "generic method admission retains generic impl method return origins" {
    const source =
        \\protocol Project { type Item; fn project(self: &const Self): Self.Item; }
        \\struct Holder<Stored> { item: Stored; }
        \\impl<Element> Holder<Element>: Project { type Item = Element; fn project(self: &const Holder<Element>): Element { return self.item; } }
        \\fn inspect<T>(holder: &const Holder<T>): i32 { const item = holder.project(); return item.secret(); }
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "generic_impl_return_origin", source, "generic parameter `T` requires a declared protocol for method `secret`");
}

test "generic method admission rejects undeclared qualified protocol calls" {
    const sources = [_][]const u8{
        "protocol Readable { fn read(self: &const Self): i32; } fn inspect<T>(value: &const T): i32 { return Readable.read(value); } fn main(): i32 { return 0; }",
        "protocol Readable { fn read(self: &const Self): i32; } protocol Other { fn read(self: &const Self): i32; } fn inspect<T: Other>(value: &const T): i32 { return Readable.read(value); } fn main(): i32 { return 0; }",
        "protocol CopyValue { fn duplicate(self: &const Self): Self; } fn inspect<T: CopyValue>(value: &const T): i32 { const duplicated = CopyValue.duplicate(value); return duplicated.secret(); } fn main(): i32 { return 0; }",
    };
    for (sources) |source| try helpers.expectSemanticFailedMessage(std.testing.allocator, "generic_qualified_protocol_authority", source, "requires a declared protocol");
}

test "generic method admission retains result switch payload origins" {
    const sources = [_][]const u8{
        "enum Failure { bad, } fn source<T>(value: T): T!Failure { return value; } fn inspect<T>(value: T): i32 { const item = source(value) catch (reason) { return 0; }; return item.secret(); } fn main(): i32 { return 0; }",
        "fn inspect<T>(value: T): i32 { switch value { .ok(item) => { return item.secret(); } _ => { return 0; } } } fn main(): i32 { return 0; }",
    };
    for (sources) |source| try helpers.expectSemanticFailedMessage(std.testing.allocator, "generic_result_payload_origin", source, "requires a declared protocol");
}

test "generic method admission retains optional and iteration payload origins" {
    const cases = [_][]const u8{
        "fn inspect<T>(value: ?T): i32 { if value is item { return item.secret(); } return 0; } fn main(): i32 { return 0; }",
        "fn inspect<T>(values: []const T): i32 { for item in values { return item.secret(); } return 0; } fn main(): i32 { return 0; }",
        "fn inspect<T>(values: T): i32 { for item in values { return item.secret(); } return 0; } fn main(): i32 { return 0; }",
    };
    for (cases, 0..) |source, index| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "generic_payload_origin_{d}", .{index});
        defer std.testing.allocator.free(path);
        try helpers.expectSemanticFailedMessage(std.testing.allocator, path, source, "requires a declared protocol");
    }
}
const compat = @import("cyna").compat;
const helpers = @import("../../helpers.zig");

test "generic method admission rejects undeclared concrete methods through local aliases" {
    const prefix =
        \\struct Secret { fn secret(self: &const Secret): i32 { return 42; } }
    ;
    const suffix =
        \\fn main(): i32 { return inspect<Secret>(Secret {}); }
    ;
    for ([_][]const u8{
        "fn inspect<T>(value: T): i32 { return value.secret(); }",
        "fn inspect<T>(value: T): i32 { const alias = value; return alias.secret(); }",
        "fn inspect<T>(value: T): i32 { const alias = &value; return alias.secret(); }",
    }) |body| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}\n{s}", .{ prefix, body, suffix });
        defer std.testing.allocator.free(source);
        try helpers.expectSemanticFailedMessage(std.testing.allocator, "undeclared_generic_method.cy", source, "generic parameter `T` requires a declared protocol for method `secret`");
    }
}

test "generic method admission does not infer an undeclared additional protocol" {
    const source =
        \\protocol Allowed { fn read(self: &const Self): i32; }
        \\protocol Hidden { fn secret(self: &const Self): i32; }
        \\struct Secret {}
        \\impl Secret: Allowed { fn read(self: &const Secret): i32 { return 1; } }
        \\impl Secret: Hidden { fn secret(self: &const Secret): i32 { return 42; } }
        \\fn inspect<T: Allowed>(value: T): i32 { return value.secret(); }
        \\fn main(): i32 { return inspect<Secret>(Secret {}); }
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "undeclared_additional_protocol.cy", source, "requires a declared protocol for method `secret`");
}

test "generic method admission rejects unused unconstrained declarations" {
    const source =
        \\fn unused<T>(value: T): i32 { const alias = &value; return alias.secret(); }
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "unused_generic_method.cy", source, "requires a declared protocol for method `secret`");
}

test "generic method admission follows fields indexing and transparent type aliases" {
    const prefix = "struct Holder<Stored> { item: Stored; } type Container<Element> = Holder<Element>;\n";
    for ([_][]const u8{
        "fn inspect<T>(value: &Holder<T>): i32 { return value.item.secret(); }",
        "fn inspect<T>(value: &Container<T>): i32 { const alias = &value.item; return alias.secret(); }",
        "fn inspect<T>(values: &[1]T): i32 { return values[0].secret(); }",
        "fn inspect<T>(values: []const T): i32 { return values[0].secret(); }",
        "fn inspect<T>(value: *T): i32 { unchecked { return (*value).secret(); } }",
    }) |body| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}\nfn main(): i32 {{ return 0; }}", .{ prefix, body });
        defer std.testing.allocator.free(source);
        try helpers.expectSemanticFailedMessage(std.testing.allocator, "generic_projected_method.cy", source, "generic parameter `T` requires a declared protocol for method `secret`");
    }
}

test "generic method admission does not infer concrete container methods on a bare parameter" {
    const source =
        \\struct Holder<T> {
        \\    view: T;
        \\    fn length(self: Holder<T>): usize { return self.view.len(); }
        \\}
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "generic_concrete_container_method.cy", source, "generic parameter `T` requires a declared protocol for method `len`");
}

test "generic method admission follows explicit inferred and callback return signatures" {
    const prefix =
        \\struct Holder<Stored> { item: Stored; fn get(self: Holder<Stored>): Stored { return self.item; } }
        \\enum Failure { bad, }
        \\fn identity<U>(value: U): U { return value; }
        \\fn wrap<U>(value: U): Holder<U> { return Holder<U> { item: value }; }
    ;
    for ([_][]const u8{
        "fn inspect<T>(value: T): i32 { return identity<T>(value).secret(); }",
        "fn inspect<T>(value: T): i32 { return identity(value).secret(); }",
        "fn inspect<T>(value: T): i32 { const result = identity(value); return result.secret(); }",
        "fn inspect<T>(value: T): i32 { return wrap(value).item.secret(); }",
        "fn inspect<T>(value: &const Holder<T>): i32 { return value.get().secret(); }",
        "fn inspect<T>(action: fn(T): T, value: T): i32 { return action(value).secret(); }",
        "fn inspect<T>(value: T): i32 { const action = fn(item: T): T { return item; }; return action(value).secret(); }",
        "fn inspect<T>(value: T): i32 { const action = fn(item: T) { return item; }; return action(value).secret(); }",
        "fn inspect<T>(value: T): i32 { const action = fn(item: T) { if true { return item; } return item; }; return action(value).secret(); }",
        "fn inspect<T>(value: T): i32 { const action = fn(item: T) { if true { return item; } else { return item; } }; return action(value).secret(); }",
        "fn inspect<T>(value: T): i32 { const action = fn(item: T) { while true { return item; } }; return action(value).secret(); }",
        "fn inspect<T>(values: [1]T): i32 { const action = fn(input: [1]T) { for item in input { return item; } }; return action(values).secret(); }",
        "fn inspect<T>(value: T): i32 { const action = fn(item: T) { using alloc = 0 { return item; } }; return action(value).secret(); }",
        "fn inspect<T>(value: T): i32 { const action = fn(input: T, fallback: T) { return input; }; return action(value, value).secret(); }",
        "fn inspect<T>(): i32 { const action: fn(T): i32 = fn(item) { return item.secret(); }; return 0; }",
        "fn apply<U>(value: U, action: fn(U): i32): i32 { return action(value); } fn inspect<T>(value: T): i32 { return apply(value, fn(item) { return item.secret(); }); }",
        "fn apply<U>(action: fn(U): i32, value: U): i32 { return action(value); } fn inspect<T>(value: T): i32 { return apply(fn(item) { return item.secret(); }, value); }",
    }) |body| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}\nfn main(): i32 {{ return 0; }}", .{ prefix, body });
        defer std.testing.allocator.free(source);
        try helpers.expectSemanticFailedMessage(std.testing.allocator, "generic_return_method.cy", source, "generic parameter `T` requires a declared protocol for method `secret`");
    }
}

test "generic method admission retains declared authority through inferred iterator and allocator returns" {
    const source =
        \\protocol Readable { fn read(self: &const Self): i32; }
        \\fn from_iter<T: Readable>(values: [1]T): i32 {
        \\    const action = fn(input: [1]T) { for item in input { return item; } };
        \\    return action(values).read();
        \\}
        \\fn from_block<T: Readable>(value: T): i32 {
        \\    const action = fn(item: T) { using alloc = 0 { return item; } };
        \\    return action(value).read();
        \\}
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectSemanticSuccess(std.testing.allocator, "generic_declared_inferred_control_flow.cy", source);
}

test "generic method admission checks every inferred callback return origin" {
    const body = "fn inspect<T, U>(left: T, right: U): i32 { const action = fn(a: T, b: U) { if true { return a; } else { return b; } }; return action(left, right).secret(); } fn main(): i32 { return 0; }";
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "generic_alternative_origins.cy", body, "generic parameter `T` requires a declared protocol for method `secret`");
    const one_bound = "protocol Secret { fn secret(self: &const Self): i32; } fn inspect<T: Secret, U>(left: T, right: U): i32 { const action = fn(a: T, b: U) { if true { return a; } else { return b; } }; return action(left, right).secret(); } fn main(): i32 { return 0; }";
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "generic_alternative_one_bound.cy", one_bound, "generic parameter `U` requires a declared protocol for method `secret`");
    const both_bound = "protocol Secret { fn secret(self: &const Self): i32; } fn inspect<T: Secret, U: Secret>(left: T, right: U): i32 { const action = fn(a: T, b: U) { if true { return a; } else { return b; } }; return action(left, right).secret(); } fn main(): i32 { return 0; }";
    try helpers.expectSemanticSuccess(std.testing.allocator, "generic_alternative_both_bound.cy", both_bound);
    const nested = "protocol Secret { fn duplicate(self: &const Self): Self; fn secret(self: &const Self): i32; } fn inspect<T: Secret, U: Secret, V>(first: T, second: U, third: V): i32 { const action = fn(a: T, b: U, c: V) { if true { return a; } else if true { return b; } else { return c; } }; return action(first, second, third).duplicate().secret(); } fn main(): i32 { return 0; }";
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "generic_nested_alternative_origin.cy", nested, "generic parameter `V` requires a declared protocol for method `duplicate`");
    const nested_bound = "protocol Secret { fn duplicate(self: &const Self): Self; fn secret(self: &const Self): i32; } fn inspect<T: Secret, U: Secret, V: Secret>(first: T, second: U, third: V): i32 { const action = fn(a: T, b: U, c: V) { if true { return a; } else if true { return b; } else { return c; } }; return action(first, second, third).duplicate().secret(); } fn main(): i32 { return 0; }";
    try helpers.expectSemanticSuccess(std.testing.allocator, "generic_nested_alternative_bound.cy", nested_bound);
}

test "generic method admission retains reassigned local origins" {
    const callback = "protocol Secret { fn secret(self: &const Self): i32; } fn inspect<T: Secret, U>(first: T, second: U): i32 { const action = fn(a: T, b: U) { var selected = a; selected = b; return selected; }; return action(first, second).secret(); } fn main(): i32 { return 0; }";
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "generic_callback_reassignment.cy", callback, "generic parameter `U` requires a declared protocol for method `secret`");
    const direct = "protocol Secret { fn secret(self: &const Self): i32; } fn inspect<T: Secret, U>(first: T, second: U): i32 { var selected = first; selected = second; return selected.secret(); } fn main(): i32 { return 0; }";
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "generic_direct_reassignment.cy", direct, "generic parameter `U` requires a declared protocol for method `secret`");
    const branch = "protocol Secret { fn secret(self: &const Self): i32; } fn inspect<T: Secret, U>(first: T, second: U): i32 { const action = fn(a: T, b: U) { var selected = a; if true { selected = b; } return selected; }; return action(first, second).secret(); } fn main(): i32 { return 0; }";
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "generic_branch_reassignment.cy", branch, "generic parameter `U` requires a declared protocol for method `secret`");
    const same_origin = "protocol Secret { fn secret(self: &const Self): i32; } fn inspect<T: Secret>(first: T, second: T): i32 { var selected = first; selected = second; return selected.secret(); } fn main(): i32 { return 0; }";
    try helpers.expectSemanticSuccess(std.testing.allocator, "generic_same_origin_reassignment.cy", same_origin);
}

test "ownership storage on a binder is settled by the lowered body" {
    // The lowering that emits the storage operation records it against the
    // binder's own ownership wrapper, so no syntax walk decides it.
    const leak = "fn inspect<T>(box: ^T): i32 { const raw = box.leak(); return 0; } fn main(): i32 { return 0; }";
    try helpers.expectSemanticSuccess(std.testing.allocator, "generic_binder_leak.cy", leak);
    const pointer = "fn inspect<T>(box: ^T): i32 { const address = box.ptr(); return 0; } fn main(): i32 { return 0; }";
    try helpers.expectSemanticSuccess(std.testing.allocator, "generic_binder_pointer.cy", pointer);
}

test "generic method admission preserves alternative container element origins" {
    const index = "fn inspect<T, U>(left: [1]T, right: [1]U): i32 { const action = fn(a: [1]T, b: [1]U) { if true { return a; } else { return b; } }; return action(left, right)[0].secret(); } fn main(): i32 { return 0; }";
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "generic_alternative_index.cy", index, "generic parameter `T` requires a declared protocol for method `secret`");
    const one_bound = "protocol Secret { fn secret(self: &const Self): i32; } fn inspect<T: Secret, U>(left: [1]T, right: [1]U): i32 { const action = fn(a: [1]T, b: [1]U) { if true { return a; } else { return b; } }; return action(left, right)[0].secret(); } fn main(): i32 { return 0; }";
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "generic_alternative_index_one_bound.cy", one_bound, "generic parameter `U` requires a declared protocol for method `secret`");
    const both_bound = "protocol Secret { fn secret(self: &const Self): i32; } fn inspect<T: Secret, U: Secret>(left: [1]T, right: [1]U): i32 { const action = fn(a: [1]T, b: [1]U) { if true { return a; } else { return b; } }; return action(left, right)[0].secret(); } fn main(): i32 { return 0; }";
    try helpers.expectSemanticSuccess(std.testing.allocator, "generic_alternative_index_both_bound.cy", both_bound);
    const iterate = "fn inspect<T, U>(left: [1]T, right: [1]U): i32 { const action = fn(a: [1]T, b: [1]U) { if true { return a; } else { return b; } }; for item in action(left, right) { return item.secret(); } return 0; } fn main(): i32 { return 0; }";
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "generic_alternative_iterate.cy", iterate, "generic parameter `T` requires a declared protocol for method `secret`");
}

test "generic method admission preserves alternative try and slice payload origins" {
    const attempted = "enum Failure { invalid, } fn source<T>(value: T): T!Failure { return value; } fn inspect<T, U>(left: T, right: U): i32!Failure { const action = fn(a: T, b: U) { if true { return source(a); } else { return source(b); } }; return (try action(left, right)).secret(); } fn main(): i32 { return 0; }";
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "generic_alternative_try.cy", attempted, "generic parameter `T` requires a declared protocol for method `secret`");
    const sliced = "fn inspect<T, U>(left: [1]T, right: [1]U): i32 { const action = fn(a: [1]T, b: [1]U) { if true { return a; } else { return b; } }; return action(left, right)[0..1][0].secret(); } fn main(): i32 { return 0; }";
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "generic_alternative_slice.cy", sliced, "generic parameter `T` requires a declared protocol for method `secret`");
    const bound_try = "enum Failure { invalid, } protocol Secret { fn secret(self: &const Self): i32; } fn source<T>(value: T): T!Failure { return value; } fn inspect<T: Secret, U: Secret>(left: T, right: U): i32!Failure { const action = fn(a: T, b: U) { if true { return source(a); } else { return source(b); } }; return (try action(left, right)).secret(); } fn main(): i32 { return 0; }";
    try helpers.expectSemanticSuccess(std.testing.allocator, "generic_alternative_bound_try.cy", bound_try);
    const bound_slice = "protocol Secret { fn secret(self: &const Self): i32; } fn inspect<T: Secret, U: Secret>(left: [1]T, right: [1]U): i32 { const action = fn(a: [1]T, b: [1]U) { if true { return a; } else { return b; } }; return action(left, right)[0..1][0].secret(); } fn main(): i32 { return 0; }";
    try helpers.expectSemanticSuccess(std.testing.allocator, "generic_alternative_bound_slice.cy", bound_slice);
}

test "generic method admission inspects every inferred sequence element origin" {
    const literal = "protocol Secret { fn secret(self: &const Self): i32; } fn inspect<T: Secret, U>(left: T, right: U): i32 { const items = [left, right]; return items[1].secret(); } fn main(): i32 { return 0; }";
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "generic_array_literal_second_origin.cy", literal, "generic parameter `U` requires a declared protocol for method `secret`");
    const repeated = "protocol Secret { fn secret(self: &const Self): i32; } fn inspect<T: Secret, U>(left: T, right: U): i32 { const items = [left, right] ** 2; return items[1].secret(); } fn main(): i32 { return 0; }";
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "generic_repeated_sequence_second_origin.cy", repeated, "generic parameter `U` requires a declared protocol for method `secret`");
    // A typed sequence literal declares its element type, so the element that
    // does not match that binder is settled by the declared element type, not
    // by a protocol requirement on the element binder.
    const typed = "protocol Secret { fn secret(self: &const Self): i32; } fn inspect<T: Secret, U>(left: T, right: U): i32 { const items: [2]T = [left, right]; return items[1].secret(); } fn main(): i32 { return 0; }";
    try helpers.expectSemanticSuccess(std.testing.allocator, "generic_typed_sequence_element_type.cy", typed);
    const both_bound = "protocol Secret { fn secret(self: &const Self): i32; } fn inspect<T: Secret, U: Secret>(left: T, right: U): i32 { const items = [left, right]; return items[1].secret(); } fn main(): i32 { return 0; }";
    try helpers.expectSemanticSuccess(std.testing.allocator, "generic_array_literal_both_bound.cy", both_bound);
    const typed_same = "protocol Secret { fn secret(self: &const Self): i32; } fn inspect<T: Secret>(left: T, right: T): i32 { const items: [2]T = [left, right]; return items[1].secret(); } fn main(): i32 { return 0; }";
    try helpers.expectSemanticSuccess(std.testing.allocator, "generic_typed_sequence_same_origin.cy", typed_same);
}

test "generic method admission does not erase unknown generic projections" {
    for ([_][]const u8{
        "fn inspect<T>(value: T): i32 { return value.item.secret(); }",
        "fn inspect<T>(value: T): i32 { return value[0].secret(); }",
        "fn inspect<T>(value: T): i32 { unchecked { return (*value).secret(); } }",
        "fn inspect<T>(action: T): i32 { return action().secret(); }",
    }) |body| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "{s}\nfn main(): i32 {{ return 0; }}", .{body});
        defer std.testing.allocator.free(source);
        try helpers.expectSemanticFailedMessage(std.testing.allocator, "generic_unknown_projection.cy", source, "generic projection derived from `T` requires a declared protocol for method `secret`");
    }
}

test "generic method admission preserves projections inferred from unknown arguments" {
    const prefix =
        \\struct Box<Element> { item: Element; }
        \\fn extract<U>(value: Box<U>): U { return value.item; }
        \\fn pointed<U>(value: *U): U { unchecked { return *value; } }
    ;
    for ([_][]const u8{
        "fn inspect<T>(value: T): i32 { return extract(value).secret(); }",
        "fn inspect<T>(value: T): i32 { return pointed(value).secret(); }",
    }) |body| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}\nfn main(): i32 {{ return 0; }}", .{ prefix, body });
        defer std.testing.allocator.free(source);
        try helpers.expectSemanticFailedMessage(std.testing.allocator, "generic_inferred_projection.cy", source, "generic projection derived from `T` requires a declared protocol for method `secret`");
    }
}

test "generic method admission retains Self and associated return authority" {
    const prefix =
        \\protocol Source {
        \\    type Item;
        \\    fn duplicate(self: &const Self): Self;
        \\    fn project(self: &const Self): Self.Item;
        \\    fn secret(self: &const Self): i32;
        \\}
    ;
    const projected = prefix ++ "\nfn inspect<T: Source>(value: &const T): i32 { return value.project().secret(); } fn main(): i32 { return 0; }";
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "generic_associated_return_authority.cy", projected, "generic projection derived from `T` requires a declared protocol for method `secret`");
    const direct = "protocol Duplicate { fn duplicate(self: &const Self): Self; } fn inspect<T: Duplicate>(value: &const T): i32 { return value.duplicate().secret(); } fn main(): i32 { return 0; }";
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "generic_self_return_authority.cy", direct, "generic parameter `T` requires a declared protocol for method `secret`");
}

test "generic nominal protocol dispatch reports ambiguous method before instantiation" {
    const source =
        \\protocol Left { type Item; fn project(self: &const Self): Self.Item; }
        \\protocol Right { type Item; fn project(self: &const Self): Self.Item; }
        \\struct Holder<Element> { item: Element; }
        \\impl<Element> Holder<Element>: Left { type Item = Element; fn project(self: &const Holder<Element>): Element { return self.item; } }
        \\impl<Element> Holder<Element>: Right { type Item = Element; fn project(self: &const Holder<Element>): Element { return self.item; } }
        \\fn inspect<T>(holder: &const Holder<T>): i32 { return holder.project().secret(); }
        \\fn main(): i32 { return 0; }
    ;
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "generic_ambiguous_nominal_method.cy", source, "protocol method call `project` is ambiguous for this type");
}

test "generic method admission preserves inferred arithmetic result origin" {
    const source = "fn inspect<T>(value: T): i32 { const sum = value + value; return sum.secret(); } fn main(): i32 { return 0; }";
    try helpers.expectSemanticFailedMessage(std.testing.allocator, "generic_arithmetic_method.cy", source, "generic parameter `T` requires a declared protocol for method `secret`");
}

pub const negatives = [_]struct {
    name: []const u8,
    source: []const u8,
}{
    .{
        .name = "impl_rejects_missing_protocol_method",
        .source =
        \\protocol Writer {
        \\    fn write(self: &Self, bytes: string): i32;
        \\}
        \\
        \\struct FileWriter {}
        \\
        \\impl FileWriter: Writer {}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "impl_rejects_wrong_protocol_receiver_type",
        .source =
        \\protocol Writer {
        \\    fn write(self: &Self, bytes: string): i32;
        \\}
        \\
        \\struct FileWriter {
        \\    total: i32;
        \\}
        \\
        \\impl FileWriter: Writer {
        \\    fn write(self: FileWriter, bytes: string): i32 {
        \\        return self.total;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "generic_constraints_must_name_protocols",
        .source =
        \\struct User {
        \\    id: i32;
        \\}
        \\
        \\fn identity<T: User>(value: T): T {
        \\    return value;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "generic_constraints_reject_unknown_protocols",
        .source =
        \\fn identity<T: Missing>(value: T): T {
        \\    return value;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "generic_constraints_reject_nonconforming_types_at_call_sites",
        .source =
        \\protocol Writer {
        \\    fn write(self: &Self, bytes: string): i32;
        \\}
        \\
        \\struct Blob {}
        \\
        \\fn take<T: Writer>(value: T): i32 {
        \\    return 42;
        \\}
        \\
        \\fn main(): i32 {
        \\    return take(Blob {});
        \\}
        ,
    },
    .{
        .name = "generic_parameters_must_be_unique",
        .source =
        \\fn pair<T, T>(left: T, right: T): T {
        \\    return left;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "generic_parameters_cannot_use_reserved_self_name",
        .source =
        \\fn identity<Self>(value: i32): i32 {
        \\    return value;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "generic_constraints_must_be_plain_protocol_names",
        .source =
        \\protocol Writer {
        \\    fn write(self: &Self, bytes: string): i32;
        \\}
        \\
        \\fn take<T: []Writer>(value: T): i32 {
        \\    return 0;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "generic_constraints_must_resolve_to_known_protocols",
        .source =
        \\fn take<T: Writer>(value: T): i32 {
        \\    return 0;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "generic_methods_cannot_shadow_enclosing_type_params",
        .source =
        \\struct Box<T> {
        \\    value: T;
        \\
        \\    fn wrap<T>(self: Box<T>, value: T): T {
        \\        return value;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "generic_parameters_do_not_accept_type_arguments",
        .source =
        \\fn bad<T>(value: T<i32>): i32 {
        \\    return 0;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "generic_types_require_explicit_type_arguments",
        .source =
        \\struct Box<T> {
        \\    value: T;
        \\}
        \\
        \\fn main(): i32 {
        \\    const box: Box = Box<i32> { value: 42 };
        \\    return box.value;
        \\}
        ,
    },
    .{
        .name = "const_value_generic_requires_value_arg",
        .source =
        \\struct Pool<T, const N: usize> {
        \\    storage: [N]T;
        \\}
        \\
        \\fn main(): i32 {
        \\    const pool: Pool<i32> = Pool<i32> { storage: 42 };
        \\    return 0;
        \\}
        ,
    },
    .{
        .name = "non_generic_functions_reject_explicit_type_args",
        .source =
        \\fn forty_two(): i32 {
        \\    return 42;
        \\}
        \\
        \\fn main(): i32 {
        \\    return forty_two<i32>();
        \\}
        ,
    },
    .{
        .name = "generic_functions_validate_explicit_type_arg_arity",
        .source =
        \\fn identity<T>(value: T): T {
        \\    return value;
        \\}
        \\
        \\fn main(): i32 {
        \\    return identity<i32, i64>(42);
        \\}
        ,
    },
};

test "generic protocol constraints are nominal across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "a.cy",
        .data =
        \\pub protocol Cap {
        \\    fn marker(self: &Self): i32;
        \\}
        \\
        \\pub struct Thing {
        \\    pub value: i32;
        \\}
        \\
        \\impl Thing: Cap {
        \\    fn marker(self: &Thing): i32 {
        \\        return self.value;
        \\    }
        \\}
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "b.cy",
        .data =
        \\pub protocol Cap {
        \\    fn marker(self: &Self): i32;
        \\}
        \\
        \\pub fn take<T: Cap>(value: T): i32 {
        \\    return 0;
        \\}
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "main.cy",
        .data =
        \\import { Thing } from a;
        \\import b;
        \\
        \\fn main(): i32 {
        \\    return b.take(Thing { value: 1 });
        \\}
        ,
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(root_path);
    try helpers.expectModuleSemanticFailedMessage(std.testing.allocator, root_path, "type `a.Thing` does not implement protocol `b.Cap`");
}

test "duplicate impls are rejected by canonical identity across import aliases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "model.cy",
        .data =
        \\pub struct Thing {
        \\    pub value: i32;
        \\}
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "cap.cy",
        .data =
        \\pub protocol Cap {
        \\    fn marker(self: &Self): i32;
        \\}
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "first.cy",
        .data =
        \\import .model as left;
        \\import .cap as contract;
        \\
        \\impl left.Thing: contract.Cap {}
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "second.cy",
        .data =
        \\import .model as right;
        \\import .cap as requirement;
        \\
        \\impl right.Thing: requirement.Cap {}
        ,
    });
    try compat.dirWriteFile(tmp.dir, .{
        .sub_path = "main.cy",
        .data =
        \\import .first;
        \\import .second;
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
        ,
    });

    const root_path = try compat.tmpDirRealpathAlloc(std.testing.allocator, &tmp, "main.cy");
    defer std.testing.allocator.free(root_path);
    try helpers.expectModuleSemanticFailedMessage(std.testing.allocator, root_path, "duplicate impl declaration for the same type and protocol");
}

test "old interface spelling is rejected" {
    const source =
        \\interface Writer {
        \\    fn write(self: &Self): i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectParseFailedMessage(std.testing.allocator, "old_interface_spelling", source, "`interface` has been removed; use `protocol`");
}

test "struct protocol impls cannot borrow inherent methods" {
    const source =
        \\protocol Named {
        \\    fn name(self: &Self): string;
        \\}
        \\struct User {
        \\    fn name(self: &User): string { return "user"; }
        \\}
        \\impl User: Named;
        \\fn main(): i32 { return 0; }
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "bodyless_struct_impl.cy", source, "struct protocol impl must declare its method bodies");
}

test "protocol impl bodies reject undeclared methods" {
    const source =
        \\protocol Named {
        \\    fn name(self: &Self): string;
        \\}
        \\struct User {}
        \\impl User: Named {
        \\    fn name(self: &User): string { return "user"; }
        \\    fn hidden(self: &User): i32 { return 1; }
        \\}
        \\fn main(): i32 { return 0; }
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "impl_extra_method.cy", source, "method `hidden` is not declared by protocol `Named`");
}

test "generic impl heads reject partial specialization" {
    const source =
        \\protocol Named {
        \\    fn name(self: &const Self): i32;
        \\}
        \\struct Box<T> {
        \\    value: T;
        \\}
        \\impl<T> Box<List<T>>: Named {
        \\    fn name(self: &const Box<List<T>>): i32 {
        \\        return 0;
        \\    }
        \\}
        \\fn main(): i32 { return 0; }
    ;

    try helpers.expectLoadedSemanticFailedMessage(
        std.testing.allocator,
        "generic_impl_partial_specialization",
        source,
        "generic impl subject arguments must directly match their declared impl parameters",
    );
}

test "generic impl families cannot overlap" {
    const source =
        \\protocol Named {
        \\    fn name(self: &const Self): i32;
        \\}
        \\struct Box<T> {
        \\    value: T;
        \\}
        \\impl<T> Box<T>: Named {
        \\    fn name(self: &const Box<T>): i32 { return 1; }
        \\}
        \\impl<T: Eq> Box<T>: Named {
        \\    fn name(self: &const Box<T>): i32 { return 2; }
        \\}
        \\fn main(): i32 { return 0; }
    ;

    try helpers.expectLoadedSemanticFailedMessage(
        std.testing.allocator,
        "generic_impl_overlap",
        source,
        "duplicate generic impl declaration for the same type family and protocol",
    );
}

test "generic impl witnesses are checked after concrete substitution" {
    const source =
        \\protocol Named {
        \\    fn name(self: &const Self): i32;
        \\}
        \\struct Box<T> {
        \\    value: T;
        \\}
        \\impl<T> Box<T>: Named {
        \\    fn name(self: &const Box<T>): bool { return true; }
        \\}
        \\fn main(): i32 {
        \\    const value = Box<i32> { value: 1 };
        \\    return 0;
        \\}
    ;

    try helpers.expectLoadedSemanticFailedMessage(
        std.testing.allocator,
        "generic_impl_concrete_signature",
        source,
        "method `name` does not match protocol return type",
    );
}

test "protocol impl requires every associated type binding" {
    const source =
        \\protocol Source {
        \\    type Item;
        \\    fn get(self: &const Self): Self.Item;
        \\}
        \\struct Box { value: i32; }
        \\impl Box: Source {
        \\    fn get(self: &const Box): i32 { return self.value; }
        \\}
        \\fn main(): i32 { return 0; }
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "missing_associated_type.cy", source, "protocol impl is missing associated type `Item`");
}

test "protocol impl rejects undeclared associated type bindings" {
    const source =
        \\protocol Marker { fn mark(self: &const Self): i32; }
        \\struct Box {}
        \\impl Box: Marker {
        \\    type Item = i32;
        \\    fn mark(self: &const Box): i32 { return 0; }
        \\}
        \\fn main(): i32 { return 0; }
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "extra_associated_type.cy", source, "associated type `Item` is not declared by protocol `Marker`");
}

test "protocol set constraints use ampersand" {
    const source =
        \\protocol Readable {
        \\    fn read(self: &Self): i32;
        \\}
        \\
        \\protocol Writable {
        \\    fn write(self: &Self): i32;
        \\}
        \\
        \\fn f<T: Readable + Writable>(value: T): i32 {
        \\    return 0;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectParseFailedMessage(std.testing.allocator, "protocol_set_rejects_plus", source, "protocol constraints use `&`, not `+`");
}

test "protocol set constraints reject conflicting method requirements" {
    const source =
        \\protocol Readable {
        \\    fn action(self: &Self): i32;
        \\}
        \\
        \\protocol Writable {
        \\    fn action(self: &Self): bool;
        \\}
        \\
        \\fn f<T: Readable & Writable>(value: T): i32 {
        \\    return 0;
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "protocol_set_conflicting_method", source, "protocol constraint set has conflicting method requirement `action`");
}

test "user modules cannot declare compiler intrinsics" {
    const source =
        \\@intrinsic("value.eq")
        \\fn value_eq<T>(left: &const T, right: &const T): bool;
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectSemanticFailedMessage(std.testing.allocator, "intrinsic_user_module", source, "intrinsic declarations are only allowed in compiler-owned modules");
}

test "a compiler-looking filename does not grant primitive impl authority" {
    const source =
        \\protocol Eq {
        \\    fn eq(self: &Self, other: &Self): bool;
        \\}
        \\
        \\impl c_int: Eq {
        \\    fn eq(self: &c_int, other: &c_int): bool {
        \\        return self == other;
        \\    }
        \\}
        \\
        \\fn main(): i32 {
        \\    return 0;
        \\}
    ;

    try helpers.expectLoadedSemanticFailedMessage(std.testing.allocator, "std_core", source, "impl target must name a struct or type union owned by this package");
}
