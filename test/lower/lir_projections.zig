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

test "LIR projected locals reuse owner field storage and cleanup" {
    const source =
        \\struct Inner { items: [:]i32; }
        \\struct Outer { inner: Inner; }
        \\fn main(): i32 {
        \\    var owner = Outer { inner: Inner { items: [4, 5] } };
        \\    const field = owner.inner;
        \\    const same = field;
        \\    const items = same.items;
        \\    return items.len() as i32;
        \\}
    ;
    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_projected_local_owner.cy", source);
    defer std.testing.allocator.free(text);
    const main_at = std.mem.indexOf(u8, text, "fn main") orelse return error.MissingMain;
    const next_fn = std.mem.indexOfPos(u8, text, main_at + 1, "\nfn ") orelse text.len;
    const main_body = text[main_at..next_fn];
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, main_body, "  owner owner\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, main_body, "  auto_drop owner"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, main_body, "  projected field\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, main_body, "  projected same\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, main_body, "  projected items\n"));
}

test "LIR lowers optional local take into load clear and return" {
    const source =
        \\fn main(): i32 {
        \\    var value: ?i32 = 42;
        \\    const taken = take value;
        \\    if taken is n {
        \\        return n;
        \\    }
        \\    return 0;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_take_optional_local.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "local#1 taken: ?i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "load %0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "make_none") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "store %0, %") != null);
}

test "LIR lowers optional field take into field pointer clear and return" {
    const source =
        \\struct Profile {
        \\    age: i32;
        \\}
        \\
        \\struct User {
        \\    profile: ?Profile;
        \\}
        \\
        \\fn main(): i32 {
        \\    var user = User { profile: Profile { age: 42 } };
        \\    const taken = take user.profile;
        \\    if taken is profile {
        \\        return profile.age;
        \\    }
        \\    return 0;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_take_optional_field.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "field_ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "make_none") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extract_payload") != null);
}

test "LIR lowers explicit clone of a projected resource field through field pointer path" {
    const source =
        \\struct Inner {
        \\    items: List<i32>;
        \\}
        \\
        \\struct Outer {
        \\    inner: Inner;
        \\}
        \\
        \\fn main(): i32 {
        \\    var outer = Outer {
        \\        inner: Inner { items: list_from<i32>([:]i32 [1, 2, 3]) }
        \\    };
        \\    const copied = outer.inner.items.clone();
        \\    return copied.len() as i32;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_borrowed_projected_field_copy.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "field_ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "_clone(") != null);
}

test "LIR lowers borrowed projected resource index copy through index pointer path" {
    const source =
        \\fn main(names: [1]string): i32 {
        \\    const copied = names[0].clone();
        \\    if copied == "Ada" {
        \\        return 42;
        \\    }
        \\    return 0;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_borrowed_projected_index_copy.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "index_ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_string_from_bytes_into(") != null);
}

test "LIR shares borrowed projected string index materialization" {
    const source =
        \\fn consume(value: string): i32 {
        \\    if value == "Ada" {
        \\        return 42;
        \\    }
        \\    return 1;
        \\}
        \\
        \\fn main(names: [1]string): i32 {
        \\    return consume(names[0]);
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_borrowed_projected_string_index_share.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "index_ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_string_share_into(") != null);
}

test "LIR keeps chained borrowed string bytes projection on field pointer path" {
    const source =
        \\struct Method {
        \\    descriptor: string;
        \\    code: [:]u8;
        \\    handlers: List<i32>;
        \\    return_descriptor: string;
        \\}
        \\
        \\impl Method: Clone {
        \\    fn clone(self: &const Method): Method {
        \\        return Method {
        \\            descriptor: string.from(self.descriptor.bytes()),
        \\            code: self.code.clone(),
        \\            handlers: self.handlers.clone(),
        \\            return_descriptor: string.from(self.return_descriptor.bytes()),
        \\        };
        \\    }
        \\}
        \\
        \\struct Class {
        \\    methods: List<Method>;
        \\
        \\    pub fn clone(self: &Class): Class {
        \\        return Class { methods: self.methods.clone() };
        \\    }
        \\}
        \\
        \\fn sink(value: []const u8): i32 {
        \\    return value.len() as i32;
        \\}
        \\
        \\fn inspect(classes: []Class, class_index: usize): i32 {
        \\    var methods = classes[class_index].methods.view();
        \\    var index: usize = 0;
        \\    while index < methods.len() {
        \\        return sink(methods[index].descriptor.bytes());
        \\    }
        \\    return 0;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_chained_borrowed_string_bytes.cy", source);
    defer std.testing.allocator.free(text);

    const inspect_at = std.mem.indexOf(u8, text, "inspect(") orelse return error.TestUnexpectedResult;
    const next_fn = std.mem.indexOfPos(u8, text, inspect_at + 1, "\nfn ") orelse text.len;
    const inspect_body = text[inspect_at..next_fn];

    try std.testing.expect(std.mem.indexOf(u8, inspect_body, "field_ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, inspect_body, "extract_field") == null);
    try std.testing.expect(std.mem.indexOf(u8, inspect_body, "string_view_owner") == null);
    try std.testing.expect(std.mem.indexOf(u8, inspect_body, "cyna_string_release") == null);
}

test "LIR lowers borrowed projected resource len through place path" {
    const source =
        \\struct Inner {
        \\    items: List<i32>;
        \\}
        \\
        \\struct Outer {
        \\    inner: Inner;
        \\}
        \\
        \\fn main(): i32 {
        \\    var outer = Outer {
        \\        inner: Inner { items: list_from<i32>([:]i32 [1, 2, 3]) }
        \\    };
        \\    return outer.inner.items.len() as i32;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_borrowed_projected_len.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "field_ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dense_len") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "borrowed_projection len_from_place") != null);
}

test "LIR lowers borrowed projected resource push through place path" {
    const source =
        \\struct Inner {
        \\    items: List<i32>;
        \\}
        \\
        \\struct Outer {
        \\    inner: Inner;
        \\}
        \\
        \\fn main(): i32 {
        \\    var outer = Outer {
        \\        inner: Inner { items: list_from<i32>([:]i32 [1, 2, 3]) }
        \\    };
        \\    outer.inner.items.push(4);
        \\    return outer.inner.items.len() as i32;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_borrowed_projected_push.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "field_ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dense_push") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "borrowed_projection push_from_place") != null);
}

test "LIR lowers borrowed projected resource pop through place path" {
    const source =
        \\struct Inner {
        \\    items: List<i32>;
        \\}
        \\
        \\struct Outer {
        \\    inner: Inner;
        \\}
        \\
        \\fn main(): i32 {
        \\    var outer = Outer {
        \\        inner: Inner { items: list_from<i32>([:]i32 [1, 2, 3]) }
        \\    };
        \\    const value = outer.inner.items.pop();
        \\    return value;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_borrowed_projected_pop.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "field_ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dense_pop") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "borrowed_projection pop_from_place") != null);
}

test "LIR lowers borrowed projected resource clear through place path" {
    const source =
        \\struct Inner {
        \\    items: List<i32>;
        \\}
        \\
        \\struct Outer {
        \\    inner: Inner;
        \\}
        \\
        \\fn main(): i32 {
        \\    var outer = Outer {
        \\        inner: Inner { items: list_from<i32>([:]i32 [1, 2, 3]) }
        \\    };
        \\    outer.inner.items.clear();
        \\    return outer.inner.items.len() as i32;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_borrowed_projected_clear.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "field_ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dense_clear") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "borrowed_projection clear_from_place") != null);
}

test "LIR lowers borrowed projected resource reserve through place path" {
    const source =
        \\struct Inner {
        \\    items: List<i32>;
        \\}
        \\
        \\struct Outer {
        \\    inner: Inner;
        \\}
        \\
        \\fn main(): i32 {
        \\    var outer = Outer {
        \\        inner: Inner { items: list_from<i32>([:]i32 [1, 2, 3]) }
        \\    };
        \\    outer.inner.items.reserve(16);
        \\    return outer.inner.items.len() as i32;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_borrowed_projected_reserve.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "field_ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dense_reserve") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_fn_") != null);
}

test "LIR lowers borrowed projected sparse take through place path" {
    const source =
        \\struct Slots {
        \\    ids: [;]i32;
        \\}
        \\
        \\struct Outer {
        \\    slots: Slots;
        \\}
        \\
        \\fn main(): i32 {
        \\    var outer = Outer {
        \\        slots: Slots { ids: [; 8] [] }
        \\    };
        \\    outer.slots.ids.insert(2, 42);
        \\    const value = outer.slots.ids.take(2);
        \\    if value is n {
        \\        return n;
        \\    }
        \\    return 0;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_borrowed_projected_sparse_take.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "field_ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "sparse_take") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "borrowed_projection sparse_take_from_place") != null);
}

test "LIR lowers explicit clone of a union payload resource through place path" {
    const source =
        \\union Token {
        \\    ids: List<i32>;
        \\    eof;
        \\}
        \\
        \\fn main(): i32 {
        \\    const token: Token = .ids(list_from<i32>([:]i32 [1, 2, 3]));
        \\    const copied = token.ids.clone();
        \\    return copied.len() as i32;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_borrowed_union_payload_copy.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "union_payload_ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "_clone(") != null);
}

test "LIR moves optional take payload into capture without copying" {
    const source =
        \\struct Box {
        \\    values: List<i32>;
        \\}
        \\
        \\fn main(): i32 {
        \\    var value: ?Box = Box { values: list_from<i32>([:]i32 [1]) };
        \\    if take value is item {
        \\        drop item;
        \\        return 42;
        \\    }
        \\    return 1;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_take_optional_capture_moves_payload.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "take value: source cleared to none") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "explicit_drop item") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "call cyna_copy_") == null);
}

test "LIR lowers Array optional take into list-backed slot clear" {
    const source =
        \\fn main(): i32 {
        \\    var slots = [:]?i32 [none, none];
        \\    slots[0] = 42;
        \\    const taken = take slots[0];
        \\    if taken is n {
        \\        if slots[0] is none {
        \\            return n;
        \\        }
        \\    }
        \\    return 0;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_take_array_optional.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "local#0 slots: [:]?i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dense_new") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dense_push") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dense_at") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "make_none") != null);
}

test "LIR lowers projected Array optional take through field path" {
    const source =
        \\struct State {
        \\    slots: [:]?i32;
        \\}
        \\
        \\fn main(): i32 {
        \\    var state = State { slots: [:]?i32 [none, none] };
        \\    state.slots[0] = 42;
        \\    const taken = take state.slots[0];
        \\    if taken is n {
        \\        if state.slots[0] is none {
        \\            return n;
        \\        }
        \\    }
        \\    return 0;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_take_array_optional_field_path.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "local#0 state: State") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "field_ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extract_field") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dense_at") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "make_none") != null);
}

test "LIR lowers mixed index and field Array optional take path" {
    const source =
        \\struct State {
        \\    slots: [:]?i32;
        \\}
        \\
        \\struct Wrapper {
        \\    state: State;
        \\}
        \\
        \\fn main(): i32 {
        \\    var wrappers: [1]Wrapper = [1]Wrapper [
        \\        Wrapper { state: State { slots: [:]?i32 [none, none] } }
        \\    ];
        \\    wrappers[0].state.slots[0] = 42;
        \\    const taken = take wrappers[0].state.slots[0];
        \\    if taken is n {
        \\        if wrappers[0].state.slots[0] is none {
        \\            return n;
        \\        }
        \\    }
        \\    return 0;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_take_array_optional_mixed_path.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "local#0 wrappers: [1]Wrapper") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "index_ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "field_ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extract_field") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dense_at") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "make_none") != null);
}

test "LIR lowers mixed index and field Array optional resource take path" {
    const source =
        \\struct User {
        \\    age: i32;
        \\    scores: List<i32>;
        \\}
        \\
        \\struct State {
        \\    slots: [:]?User;
        \\}
        \\
        \\struct Wrapper {
        \\    state: State;
        \\}
        \\
        \\fn main(): i32 {
        \\    var wrappers: [1]Wrapper = [1]Wrapper [
        \\        Wrapper { state: State { slots: [:]?User [none] } }
        \\    ];
        \\    wrappers[0].state.slots[0] = User { age: 42, scores: list<i32>() };
        \\    const taken = take wrappers[0].state.slots[0];
        \\    if taken is user {
        \\        if wrappers[0].state.slots[0] is none {
        \\            return user.age;
        \\        }
        \\    }
        \\    return 0;
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_take_array_optional_resource_mixed_path.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "taken: ?User") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "type_desc ?User") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dense_new") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dense_drop") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extract_payload") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "make_none") != null);
}

test "LIR hands off resource locals captured by struct literal fields" {
    const source =
        \\struct Holder {
        \\    values: List<i32>;
        \\}
        \\
        \\fn build(): Holder {
        \\    var values: List<i32> = list_from<i32>([:]i32 [1]);
        \\    return Holder { values: values };
        \\}
    ;

    const text = try lir_support.lowerLirText(std.testing.allocator, "lir_handoff_struct_literal_field.cy", source);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "ownership:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "handoff values: source cleanup suppressed") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "auto_drop values at return (") == null);
}

test "LIR lowers indexed writes through borrowed fixed arrays" {
    const source =
        \\fn fill(output: &[8]usize): void { output[0] = 3; output[7] = 5; }
        \\fn main(): i32 {
        \\    var values: [8]usize = [0] ** 8;
        \\    fill(&values);
        \\    return (values[0] + values[7]) as i32;
        \\}
    ;
    const text = try lir_support.lowerLirText(std.testing.allocator, "borrowed_array_write.cy", source);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "index_ptr") != null);
}
